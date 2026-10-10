"""Panel inventory, multi-selection and in-workflow updates."""

import contextlib
import json
import re
import shlex
import sys
import tempfile
from pathlib import Path

from deploy_resources import DeployError, ManagedDeployments
from lib.panel_version import (MAX_XRAY_VERSION, MIN_PANEL_VERSION, XRAY_REPOSITORY, latest_release,
                               latest_xray_release, releases, supported, update_available, version, xray_compatible)

SOURCES = Path(__file__).resolve().parent / 'lib'


class PanelUpdateRequired(DeployError):
    def __init__(self, current):
        self.current = current
        super().__init__(f'当前 3x-ui {current} 不满足最低支持版本 {MIN_PANEL_VERSION}。')


def run_helper(ssh, request):
    from deploy_parts import agent_result
    payload = dict(request, sources={name: (SOURCES / name).read_text(encoding='utf-8')
                                   for name in ('panel_version.py', 'panel_maintenance.py', 'entry_management.py')})
    bootstrap = ("import json,sys,types; request=json.loads(sys.stdin.buffer.read(1048577)); "
                 "policy=types.ModuleType('okp_panel_version'); sys.modules[policy.__name__]=policy; "
                 "exec(compile(request['sources']['panel_version.py'],'panel_version.py','exec'),policy.__dict__); "
                 "scope={'__name__':'okp_panel_bootstrap'}; "
                 "exec(compile(request['sources']['panel_maintenance.py'],'panel_maintenance.py','exec'),scope); scope['main'](request)")
    raw = ssh.run('env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root '
                  'python3 -I -c ' + shlex.quote(bootstrap), data=json.dumps(payload).encode(), timeout=1500)
    return agent_result(raw)


def catalog(required=True):
    try:
        return releases()
    except (OSError, ValueError, TypeError):
        if not required:
            print('暂时无法查询官方版本列表；仍可检测面板及恢复中断的更新。', file=sys.stderr)
            return []
        raise DeployError('无法读取官方稳定版本列表；请检查 GitHub 访问后重新检测。') from None


def describe(current, release):
    target = release['tag_name'] if release else None
    if release is None:
        return '未查到同 major 稳定版'
    if version(current)[0] != version(MIN_PANEL_VERSION)[0]:
        return 'major 未受本脚本支持，更新仍保持当前 major'
    if not supported(current):
        return '低于最低支持版本'
    return '可更新' if update_available(current, target) else '已是同 major 最新版'


def compatible_core(required=True):
    try:
        selected = latest_xray_release(releases(XRAY_REPOSITORY))
        if selected is not None:
            return selected['tag_name']
    except (OSError, ValueError, TypeError):
        pass
    if required:
        raise DeployError('无法确定兼容的官方 Xray 版本，请检查 GitHub 访问后重新检测。')
    return None


def recover_pending(ssh, information):
    from deploy import prompt_yes_no
    if information.get('pending'):
        if not sys.stdin.isatty() or not prompt_yes_no('检测到中断的面板更新，立即恢复原版本并继续？', True):
            raise DeployError('面板更新尚未恢复；原流程已保留。')
        information = run_helper(ssh, {'operation': 'panel-recover'})
    return information


def offer_update(ssh, current, context=None):
    from deploy import prompt_yes_no
    if not sys.stdin.isatty():
        raise PanelUpdateRequired(current)
    context = context or {}
    print('正在检测面板版本及更新条件。', flush=True)
    information = recover_pending(ssh, run_helper(ssh, dict(context, operation='panel-info')))
    current = information['current']
    core_current = information.get('core_current')
    if supported(current) and xray_compatible(core_current):
        return True
    print(f'正在查询 {version(current)[0]}.x 的最新稳定版及兼容 Xray。', flush=True)
    release = latest_release(catalog(), current)
    target = release['tag_name'] if release and update_available(current, release['tag_name']) else current
    print(f'当前面板：{current}；最低支持：{MIN_PANEL_VERSION}；同 major 最新：{release["tag_name"] if release else "未找到"}。')
    if not supported(target):
        print('当前 major 的更新不能满足最低支持要求；请手动处理 major 变更后继续。')
        raise PanelUpdateRequired(current)
    if not information['updatable']:
        raise DeployError(information['reason'])
    core_target = compatible_core()
    print(f'Xray：{core_current or "未识别"} -> {core_target}。')
    action = f'更新面板至 {target} 并配置兼容 Xray' if current != target else '配置兼容 Xray'
    if not prompt_yes_no(f'立即{action}，然后继续当前流程？更新期间代理会短暂中断', True):
        raise PanelUpdateRequired(current)
    print(f'正在更新：3x-ui {current} -> {target}；Xray {core_current or "未识别"} -> {core_target}。')
    result = run_helper(ssh, dict(context, operation='panel-update', current=current, target=target,
                                 core_current=core_current, core_target=core_target))
    if result.get('current') != target or result.get('core_current') != core_target:
        raise DeployError('面板更新结果与选定版本不同，原流程已保留。')
    print(f'面板：{target}；Xray：{core_target}，继续原流程。')
    return True


def retry_after_update(ssh, operation, context=None):
    try:
        return operation()
    except PanelUpdateRequired as error:
        offer_update(ssh, error.current, context() if callable(context) else context)
        return operation()


def preflight(ssh, information=None, context=None):
    information = information or run_helper(ssh, dict(context or {}, operation='panel-info'))
    if (information.get('pending') or not supported(information['current'])
            or not xray_compatible(information.get('core_current'))):
        offer_update(ssh, information['current'], context)


def api_diagnosis(panel, link):
    from lib.entry_management import EntryError, object_value
    from urllib.parse import parse_qsl, urlsplit
    uri = urlsplit(link.link)
    query = dict(parse_qsl(uri.query))
    status = panel('GET', '/panel/api/server/status')
    inbounds = panel('GET', '/panel/api/inbounds/list')
    runtime = object_value(panel('GET', '/panel/api/server/getConfigJson'))
    if not isinstance(status, dict) or not isinstance(inbounds, list):
        raise EntryError('面板返回的诊断数据无效。')
    matches = []
    for inbound in inbounds:
        settings = object_value(inbound.get('settings', {}))
        for client in settings.get('clients', []):
            if client.get('id') == uri.username:
                matches.append((inbound, client))
    if len(matches) != 1:
        raise EntryError('面板中未找到唯一匹配的入口账号，不能使用该面板的诊断结果。')
    inbound, client = matches[0]
    reality = object_value(inbound.get('streamSettings', {})).get('realitySettings', {})
    assembled = [node for node in runtime.get('inbounds', []) if node.get('tag') == inbound.get('tag')]
    active_reality = (assembled[0].get('streamSettings', {}).get('realitySettings', {}) if len(assembled) == 1 else {})
    active_clients = (assembled[0].get('settings', {}).get('clients', []) if len(assembled) == 1 else [])
    def version_text(value):
        if value in (None, ''):
            return '空'
        return value if isinstance(value, str) and re.fullmatch(r'v?\d{1,3}(?:\.\d{1,3}){0,2}', value) else '无法识别'
    xray = status.get('xray', {})
    if not isinstance(xray, dict):
        raise EntryError('面板返回的 Xray 状态无效。')
    return {'panel_version': version_text(status.get('panelVersion')), 'xray_version': version_text(xray.get('version')),
            'xray_running': xray.get('state') == 'running', 'xray_error': bool(xray.get('errorMsg')),
            'inbound_enabled': inbound.get('enable') is True, 'client_enabled': client.get('enable') is True,
            'client_in_runtime': any(node.get('id') == uri.username for node in active_clients),
            'min_client_version': version_text(reality.get('minClientVer')),
            'max_client_version': version_text(reality.get('maxClientVer')),
            'runtime_min_client_version': version_text(active_reality.get('minClientVer')),
            'runtime_max_client_version': version_text(active_reality.get('maxClientVer')),
            'public_key_matches': reality.get('settings', {}).get('publicKey') == query.get('pbk'),
            'short_id_matches': query.get('sid', '') in reality.get('shortIds', []),
            'server_name_matches': query.get('sni') in reality.get('serverNames', [])}


def inspect_panel(args, env_override=False):
    from deploy import ResumeState, SSH, SublinkPro, prompt_text, read_env
    from deploy_credentials import Credentials
    from deploy_links import parse_node_link
    from deploy_resources import atomic_write
    from lib.entry_management import EntryError
    registry = ManagedDeployments(ResumeState())
    identity = registry.select(args.target)
    record = registry.records[identity]
    if record['remote_relay']:
        identity = record['remote_relay']['entry_id']
        record = registry.records[identity]
    server = record['server']
    if not server:
        raise DeployError('请先补全此配置的 3x-ui 管理。')
    vault = Credentials(registry.state)
    authentication = vault.panel(identity, server)
    if authentication is None:
        if server['backend'] == 'standalone' and record['ssh']:
            binding = record['ssh']
            print('本地尚未保存面板凭据，正在通过 SSH 取回。', flush=True)
            with tempfile.TemporaryDirectory(prefix='okp-panel-auth-', dir='/tmp') as directory:
                ssh = SSH(binding['target'], directory, binding['port'], binding['identity'], password_login=binding['password'])
                try:
                    ssh.connect()
                    authentication = run_helper(ssh, {'operation': 'panel-credentials', 'entry_id': identity,
                                                     'installation_id': server['identity']})
                finally:
                    ssh.close()
        else:
            if not sys.stdin.isatty():
                raise DeployError('尚未保存此面板的 API 凭据，请从交互菜单进入诊断面板并补全。')
            import getpass
            url = prompt_text('3x-ui 面板地址（含访问路径）', required=True)
            try:
                token = getpass.getpass('3x-ui 管理员 API Token（输入隐藏）: ').strip()
            except EOFError:
                raise DeployError('已取消 API Token 输入。') from None
            authentication = {'panel_url': url, 'api_token': token}
    config = read_env(args.env_file if env_override else record['env_file'])
    client = SublinkPro(config, create_local_node=False)
    if client.url != record['sublink_url']:
        raise DeployError('SublinkPro 实例与此配置不一致。')
    nodes = client.remote_nodes(identity, record)
    if len(nodes) != 1:
        raise DeployError('诊断面板需要唯一的入口节点。')
    link = parse_node_link(nodes[0]['Link'])
    print('正在通过面板 API 读取 Xray 版本及入口配置。', flush=True)
    try:
        report = api_diagnosis(vault.validate_panel(authentication), link)
    except EntryError as error:
        raise DeployError(str(error)) from None
    vault.save_panel(identity, server, authentication)
    report.update(identity=identity, name=record['node_name'])
    atomic_write(registry.state.directory / ('panel-report-' + identity + '.json'), json.dumps(report, ensure_ascii=False).encode())
    print(f"面板：{record['node_name']}；3x-ui：{report['panel_version']}；Xray：{report['xray_version']}")
    print('Xray：' + ('运行中' if report['xray_running'] and not report['xray_error'] else '异常'))
    print(f"REALITY Min Client Ver：{report['min_client_version']}；Max Client Ver：{report['max_client_version']}")
    print(f"运行配置 Min Client Ver：{report['runtime_min_client_version']}；Max Client Ver：{report['runtime_max_client_version']}")
    for key, label in (('inbound_enabled', '入站启用'), ('client_enabled', '原节点账号启用'),
                       ('client_in_runtime', '原节点账号已加入运行配置'), ('public_key_matches', '公钥匹配'),
                       ('short_id_matches', 'Short ID 匹配'), ('server_name_matches', 'SNI 匹配')):
        print(label + '：' + ('是' if report[key] else '否'))
    return report


def candidate_records(registry):
    return [(identity, record) for identity, record in registry.records.items()
            if record['kind'] != 'remote-relay' and record['status'] != 'deleting'
            and (record['server'] or record['ssh'] or (record['airport_id'] and record['kind'] == 'adopted') or record['kind'] == 'deployment'
                 or (registry.state.directory / ('part-server-' + identity + '.json')).exists())]


def select_panels(rows):
    from deploy import prompt_text
    eligible = {index for index, row in enumerate(rows, 1) if row.get('eligible')}
    selected = set(eligible)
    while True:
        limit = f'；Xray 兼容上限 {MAX_XRAY_VERSION}' if MAX_XRAY_VERSION else ''
        print(f'\n更新面板（最低支持 {MIN_PANEL_VERSION}{limit}）')
        for index, row in enumerate(rows, 1):
            mark = 'x' if index in selected else ' ' if index in eligible else '-'
            current, target = row.get('current', '未检测'), row.get('target') or '-'
            core = f'；Xray {row.get("core_current") or "未检测"} -> {row.get("core_target") or "-"}'
            print(f'  {index}. [{mark}] {row["name"]}  3x-ui {current} -> {target}{core}  {row["reason"]}')
        value = prompt_text('编号切换勾选（多个用空格或逗号分隔）；a 全选，n 清空，u 更新，r 重新检测，d 编号补全 SSH，0 返回',
                            'u' if selected else '0').lower()
        if value in ('0', 'r'):
            return value, set()
        if re.fullmatch(r'd\s+[1-9]\d*', value):
            index = int(value.split()[1])
            if 1 <= index <= len(rows):
                return 'ssh', {index}
        elif value == 'u':
            if selected:
                return 'update', selected
            print('尚未勾选任何可更新面板。')
        elif value == 'a':
            selected = set(eligible)
        elif value == 'n':
            selected.clear()
        elif re.fullmatch(r'[1-9]\d*(?:[ ,]+[1-9]\d*)*', value):
            indices = set(map(int, re.split(r'[ ,]+', value)))
            if indices <= eligible:
                selected.symmetric_difference_update(indices)
            else:
                print('只能勾选版本已确认且可更新的面板。')
        else:
            print('选择无效。')


class Sessions:
    def __init__(self):
        self.stack, self.connections = contextlib.ExitStack(), {}

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return self.stack.__exit__(*args)

    def connection(self, binding):
        from deploy import SSH
        target = binding['target'] if '@' in binding['target'] else 'root@' + binding['target']
        key = (target, binding['port'] or 22, binding['identity'], binding['password'])
        if key not in self.connections:
            directory = self.stack.enter_context(tempfile.TemporaryDirectory(prefix='okp-panel-ssh-', dir='/tmp'))
            ssh = SSH(binding['target'], directory, binding['port'], binding['identity'], password_login=binding['password'])
            self.stack.callback(ssh.close)
            ssh.connect()
            self.connections[key] = ssh
        return self.connections[key]


def scan(registry, sessions, available, core_target):
    from deploy_parts import PartInput
    from deploy import export_node
    from deploy_links import parse_node_link
    rows, by_panel = [], {}
    for identity, record in candidate_records(registry):
        row = {'identity': identity, 'name': record['node_name'], 'eligible': False, 'reason': 'SSH 未设置'}
        binding = record['ssh']
        if not binding:
            draft = PartInput(registry, identity, 'server')
            values = draft.values
            if all(key in values for key in ('ssh_target', 'ssh_port', 'ssh_identity', 'ssh_password')):
                binding = {key: values['ssh_' + key] for key in ('target', 'port', 'identity', 'password')}
        if binding:
            try:
                print(f'检测面板：{record["node_name"]}')
                ssh = sessions.connection(binding)
                context = {}
                if record['server'] and record['server']['backend'] == 'standalone':
                    context = {'entry_id': identity, 'installation_id': record['server']['identity']}
                elif record['server'] is None:
                    values = PartInput(registry, identity, 'server').values
                    if values.get('panel_url') and values.get('api_token'):
                        context = {key: values[key] for key in ('panel_url', 'api_token')}
                information = run_helper(ssh, dict(context, operation='panel-info'))
                if not record['server'] and not information.get('api_verified'):
                    context = {}
                if record['server'] and record['server']['backend'] == 'project' and not information.get('pending'):
                    exported = export_node(ssh)
                    if (exported['INSTALLATION_ID'].lower() != record['server']['identity']
                            or parse_node_link(exported['VLESS_URI']).fingerprint != record['server']['fingerprint']):
                        raise DeployError('SSH 目标与此配置原先绑定的服务器不一致，不能更新。')
                current = information['current']
                if version(current) is None:
                    raise DeployError('无法识别面板版本。')
                release = latest_release(available, current)
                target = release['tag_name'] if release and update_available(current, release['tag_name']) else current
                core_current = information.get('core_current')
                core_changed = version(core_current) is not None and version(core_current) != version(core_target)
                row.update(ssh=ssh, current=current, target=target, context=context, core_current=core_current, core_target=core_target,
                           eligible=information['updatable'] and core_target is not None and
                           (update_available(current, target) or core_changed),
                           reason=describe(current, release) if information['updatable'] else information['reason'])
                if information['updatable'] and core_target is None:
                    row['reason'] = '未查到兼容 Xray，暂不能更新'
                elif information['updatable'] and core_changed and not update_available(current, target):
                    row['reason'] = '可调整 Xray' if xray_compatible(core_current) else 'Xray 不兼容，需调整'
                if information.get('pending'):
                    row.update(eligible=True, target=current, pending=True, reason='更新中断，需恢复原版本后重新检测')
                key = information.get('panel_id') or (record['server']['identity'] if record['server'] else
                                                     (binding['target'].removeprefix('root@'), binding['port'] or 22))
                if key in by_panel:
                    by_panel[key]['name'] += ' / ' + row['name']
                    continue
                by_panel[key] = row
            except DeployError as error:
                row['reason'] = str(error)
        rows.append(row)
    return rows


def manage_panels(args):
    from deploy import ResumeState, prompt_yes_no
    from deploy_parts import PartInput, diagnostic, ssh_options
    if not sys.stdin.isatty():
        raise DeployError('更新面板需要交互终端，请从主菜单选择“更新面板”。')
    with ResumeState().locked() as state, Sessions() as sessions:
        registry = ManagedDeployments(state)
        if not candidate_records(registry):
            print('暂无面板配置。')
            return
        available = catalog(required=False)
        core_target = compatible_core(required=False)
        while True:
            rows = scan(registry, sessions, available, core_target)
            action, indices = select_panels(rows)
            if action == '0':
                return
            if action == 'r':
                available = catalog(required=False)
                core_target = compatible_core(required=False)
                continue
            if action == 'ssh':
                row = rows[next(iter(indices)) - 1]
                identity = row['identity']
                draft = PartInput(registry, identity, 'ssh')
                binding = ssh_options(registry, identity, args, draft)
                run_helper(sessions.connection(binding), {'operation': 'panel-info'})
                registry.update(identity, ssh=binding)
                diagnostic(registry, identity, 'ssh')
                draft.complete()
                continue
            selected = [rows[index - 1] for index in sorted(indices)]
            print('将更新：' + '；'.join(row['name'] + ' 3x-ui ' + row['current'] + ' -> ' + row['target']
                  + '，Xray ' + (row.get('core_current') or '未检测') + ' -> ' + (row.get('core_target') or '-') for row in selected))
            if not prompt_yes_no('确认更新所选面板？更新前会备份，期间代理会短暂中断', True):
                continue
            for row in selected:
                try:
                    print(f'正在处理面板：{row["name"]}。')
                    result = run_helper(row['ssh'], dict(row.get('context', {}),
                        operation='panel-recover' if row.get('pending') else 'panel-update',
                        current=row['current'], target=row['target'], core_current=row.get('core_current'), core_target=row.get('core_target')))
                    print(f'{row["name"]}：完成，3x-ui {result["current"]}；Xray {result.get("core_current") or "待重新检测"}。')
                except DeployError as error:
                    print(row['name'] + '：' + str(error), file=sys.stderr)
            return
