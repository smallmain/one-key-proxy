"""Optional configuration parts, their prerequisites and resumable completion."""

import getpass
import json
import os
from pathlib import Path
import re
import shlex
import sys
import tempfile

from deploy_links import parse_node_link
from deploy_nodes import NodeManager
from deploy_resources import DeployError, atomic_write

AGENT = '/usr/local/lib/one-key-proxy-relay/entry_management.py'
SOURCE_DIRECTORY = Path(__file__).resolve().parent / 'lib'


def has_source(record):
    return bool(record['airport_id'] or record['remote_node_id'])


def parts(record):
    result = {'节点来源': '已配置' if has_source(record) else '未设置',
            '本地节点': ('待继续' if record['singbox'] and record['singbox']['needs_reload'] else '已启用')
                        if record['singbox'] or record['local_node_id'] else '未启用',
            'SSH 连接': '已配置（执行时验证）' if record['ssh'] else '未设置',
            '3x-ui 管理': '已配置（执行时验证）' if record['server'] else '未设置'}
    for key, label in (('source', '节点来源'), ('local', '本地节点'), ('ssh', 'SSH 连接'), ('server', '3x-ui 管理')):
        if key in record['part_errors']:
            result[label] = '异常：' + record['part_errors'][key]
    return result


def diagnostic(registry, identity, part, error=None):
    errors = dict(registry.records[identity]['part_errors'])
    if error:
        errors[part] = ''.join(c for c in str(error) if ord(c) >= 32 and ord(c) != 127)[:400]
    else:
        errors.pop(part, None)
    registry.update(identity, part_errors=errors)


def missing_entry_parts(record):
    return [label for label, configured in (('节点来源', has_source(record)), ('SSH 连接', record['ssh']),
                                           ('3x-ui 管理', record['server'])) if not configured]


class PartInput:
    fields = {'ssh_target': str, 'ssh_port': int, 'ssh_identity': str, 'ssh_password': bool,
              'panel_url': str, 'api_token': str, 'source_link': str,
              'subscription_url': str, 'insecure_subscription': bool, 'subscription_node': str, 'previous_url': str}
    fields.update(source_type=str, local_port=int, local_link=str)

    def __init__(self, registry, identity, part, on_ssh=None):
        self.registry, self.identity, self.part = registry, identity, part
        self.on_ssh = on_ssh
        self.path = registry.state.directory / ('part-' + part + '-' + identity + '.json')
        self.data = {'version': 1, 'identity': identity, 'part': part,
                     'env_file': registry.records[identity]['env_file'], 'values': {}}
        try:
            fd = registry.state.open_private(self.path, os.O_RDONLY)
        except FileNotFoundError:
            return
        try:
            with os.fdopen(fd, 'r', encoding='utf-8') as stream:
                value = json.loads(stream.read(65537))
            if (set(value) != set(self.data) or type(value['version']) is not int or value['version'] != 1 or value['identity'] != identity
                    or value['part'] != part or value['env_file'] != self.data['env_file']):
                raise ValueError
            self.validate(value['values'])
            self.data = value
        except (ValueError, TypeError, KeyError):
            raise DeployError('配置部分的恢复记录无效。') from None

    @property
    def values(self):
        return self.data['values']

    def validate(self, values):
        if not isinstance(values, dict):
            raise ValueError
        for key, value in values.items():
            if key not in self.fields or (value is None and key not in ('ssh_port', 'ssh_identity')):
                raise ValueError
            if value is not None and type(value) is not self.fields[key]:
                raise ValueError
            if isinstance(value, str) and (len(value) > 4096 or any(ord(c) < 32 or ord(c) == 127 for c in value)):
                raise ValueError
        if values.get('ssh_port') is not None and not 1 <= values['ssh_port'] <= 65535:
            raise ValueError
        if values.get('local_port') is not None and not 1 <= values['local_port'] <= 65535:
            raise ValueError
        if values.get('source_type') not in (None, 'link', 'subscription'):
            raise ValueError

    def capture(self, **values):
        self.values.update(values)
        try:
            self.validate(self.values)
        except ValueError:
            raise DeployError('配置输入无效，未保存。') from None
        atomic_write(self.path, json.dumps(self.data, ensure_ascii=False).encode())
        ssh_values = {key: value for key, value in values.items() if key.startswith('ssh_')}
        if self.on_ssh and ssh_values:
            self.on_ssh(**ssh_values)

    def complete(self):
        self.path.unlink(missing_ok=True)


def agent_result(raw):
    try:
        result = json.loads(raw)
        if not isinstance(result, dict) or type(result.get('ok')) is not bool:
            raise ValueError
        if result['ok'] is False:
            error = result.get('error', '服务器管理操作失败。')
            if not isinstance(error, str) or len(error) > 400 or any(ord(c) < 32 for c in error):
                raise ValueError
            if result.get('code') == 'panel_version_required':
                from deploy_panels import PanelUpdateRequired
                from lib.panel_version import version
                if version(result.get('current')) is None:
                    raise ValueError
                raise PanelUpdateRequired(result['current'])
            raise DeployError(error)
        if not isinstance(result.get('result'), dict):
            raise ValueError
        return result['result']
    except (ValueError, TypeError, KeyError):
        raise DeployError('服务器未返回有效的配置结果，补全进度已保留。') from None


def agent_call(ssh, identity, server, request):
    payload = dict(request, entry_id=identity, installation_id=server['identity'])
    raw = ssh.run('env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root '
                  'python3 -I ' + AGENT, data=json.dumps(payload).encode(), timeout=300)
    return agent_result(raw)


def setup_agent(ssh, identity, server, link, draft):
    from deploy import prompt_text
    values = draft.values
    if server:
        from deploy_credentials import Credentials
        saved = Credentials(draft.registry.state).panel(identity, server)
        if saved:
            for key, value in saved.items():
                if key not in values:
                    draft.capture(**{key: value})
    if 'panel_url' not in values:
        draft.capture(panel_url=prompt_text('3x-ui 面板地址（含访问路径）', required=True))
    if 'api_token' not in values:
        try:
            token = getpass.getpass('3x-ui 管理员 API Token（输入隐藏）: ').strip()
        except EOFError:
            raise DeployError('已取消 API Token 输入，补全进度已保留。') from None
        if not token:
            raise DeployError('管理 API Token 不能为空。')
        draft.capture(api_token=token)
    sources = {name: (SOURCE_DIRECTORY / name).read_text(encoding='utf-8')
               for name in ('entry_management.py', 'remote_relay.py', 'panel_version.py')}
    payload = {'operation': 'setup', 'entry_id': identity, 'expected_identity': server['identity'] if server else None,
               'panel_url': values['panel_url'], 'api_token': values['api_token'], 'link': link.link, 'sources': sources}
    bootstrap = ("import json,sys,types; request=json.loads(sys.stdin.buffer.read(1048577)); "
                 "policy=types.ModuleType('okp_panel_version'); sys.modules[policy.__name__]=policy; "
                 "exec(compile(request['sources']['panel_version.py'],'panel_version.py','exec'),policy.__dict__); "
                 "scope={'__name__':'okp_entry_bootstrap'}; "
                 "exec(compile(request['sources']['entry_management.py'],'entry_management.py','exec'),scope); scope['main'](request)")
    print('正在验证面板 API 和入口节点；沿用已保存的面板地址及 Token。', flush=True)
    raw = ssh.run('env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root '
                  'python3 -I -c ' + shlex.quote(bootstrap), data=json.dumps(payload).encode(), timeout=300)
    return agent_result(raw)


def ssh_options(registry, identity, args, draft, *, seed=None):
    from deploy import SSH, prompt_text, prompt_yes_no
    saved, values = registry.records[identity]['ssh'], draft.values
    for key, value in (seed or {}).items():
        if key.startswith('ssh_') and (key not in values or values[key] != value):
            draft.capture(**{key: value})
    target = getattr(args, 'ssh_target', None) or values.get('ssh_target') or (saved['target'] if saved else registry.records[identity]['target'])
    if target.startswith(('adopted:', 'node:', 'subscription:', 'http:', 'https:')):
        target = ''
    if not target:
        target = prompt_text('SSH 地址或 SSH config 别名（默认 root）', required=True)
    draft.capture(ssh_target=target)
    port = getattr(args, 'port', None)
    if port is None:
        port = values.get('ssh_port', saved['port'] if saved else None)
    if 'ssh_port' not in values and saved is None:
        value = prompt_text('SSH 端口', str(port or 22), required=True)
        if not value.isdigit() or not 1 <= int(value) <= 65535:
            raise DeployError('SSH 端口必须在 1-65535 范围内。')
        port = int(value)
    draft.capture(ssh_port=port)
    key = getattr(args, 'identity', None) or values.get('ssh_identity', saved['identity'] if saved else None)
    password = (True if getattr(args, 'password', False) else False if getattr(args, 'identity', None)
                else values.get('ssh_password', saved['password'] if saved else False))
    if 'ssh_password' not in values and saved is None:
        password = prompt_yes_no('SSH 是否使用密码登录（否则使用密钥 / SSH config）', password)
    draft.capture(ssh_password=password)
    if password:
        key = None
    elif 'ssh_identity' not in values and saved is None and not key:
        key = prompt_text('SSH 私钥路径（留空使用 SSH config / agent）') or None
    key = str(Path(key).expanduser().absolute()) if key else None
    draft.capture(ssh_identity=key)
    if password and not sys.stdin.isatty():
        from deploy_credentials import Credentials
        if Credentials(registry.state).ssh(target, port) is None:
            raise DeployError('首次密码登录需从交互终端继续此配置的补全流程。')
    return {'target': target, 'port': port, 'identity': key, 'password': password}


def complete_part(registry, identity, client, args, part, *, seed=None, on_ssh=None, edit=False):
    from deploy import SSH, SSHCommandError, SSHExportError, export_node
    if not sys.stdin.isatty():
        raise DeployError('请从交互终端进入该配置的编辑菜单补全 ' + part + '。')
    draft = PartInput(registry, identity, part, on_ssh)
    try:
        if client.url != registry.records[identity]['sublink_url']:
            raise DeployError('SublinkPro 实例与此配置不同，未修改配置。')
        if edit:
            from deploy import prompt_text, prompt_yes_no
            saved = registry.records[identity]['ssh'] or {}
            values = draft.values
            target = values.get('ssh_target', saved.get('target', ''))
            draft.capture(ssh_target=prompt_text('SSH 地址或 SSH config 别名（默认 root）', target, required=True))
            port = prompt_text('SSH 端口', str(values.get('ssh_port') or saved.get('port') or 22), required=True)
            if not port.isdigit() or not 1 <= int(port) <= 65535:
                raise DeployError('SSH 端口必须在 1-65535 范围内。')
            draft.capture(ssh_port=int(port))
            password = prompt_yes_no('SSH 是否使用密码登录', values.get('ssh_password', saved.get('password', False)))
            draft.capture(ssh_password=password)
            key = None if password else prompt_text('SSH 私钥路径（留空使用 SSH config / agent）', values.get('ssh_identity') or saved.get('identity') or '') or None
            draft.capture(ssh_identity=key)
            if part == 'server' and (not registry.records[identity]['server'] or registry.records[identity]['server']['backend'] == 'standalone'):
                draft.capture(panel_url=prompt_text('3x-ui 面板地址（含访问路径）', values.get('panel_url'), required=True))
                token = getpass.getpass('3x-ui 管理员 API Token（输入隐藏）: ').strip()
                if not token:
                    raise DeployError('管理 API Token 不能为空。')
                draft.capture(api_token=token)
        if part == 'server' and not has_source(registry.records[identity]):
            if 'source_link' not in draft.values:
                from deploy import prompt_text
                value = prompt_text('入口节点链接', required=True)
                parse_node_link(value).outbound()
                draft.capture(source_link=value)
            nodes = NodeManager(client, registry)
            journal = nodes.pending(identity) or nodes.prepare(identity, link=draft.values['source_link'], residential=registry.records[identity]['residential'])
            nodes.apply(journal)
        binding = ssh_options(registry, identity, args, draft, seed=seed)
        with tempfile.TemporaryDirectory(prefix='okp-part-ssh-', dir='/tmp') as directory:
            ssh = SSH(binding['target'], directory, binding['port'], binding['identity'], password_login=binding['password'])
            try:
                ssh.connect()
                try:
                    ssh.run('test "$(id -u)" = 0 || exit 101')
                    if part == 'server':
                        ssh.run('command -v python3 >/dev/null 2>&1 || exit 113')
                except SSHCommandError as error:
                    if error.exit_code == 101:
                        raise DeployError('SSH 已连接，但服务器管理需要 root 登录。') from None
                    if error.exit_code == 113:
                        raise DeployError('入口缺少 Python 3，请在服务器安装后继续补全；现有 3x-ui 配置未修改。') from None
                    raise
                if not registry.records[identity]['server']:
                    registry.update(identity, ssh=binding)
                diagnostic(registry, identity, 'ssh')
                if part == 'ssh' and not registry.records[identity]['server']:
                    draft.complete()
                    print('SSH 连接配置已保存。')
                    return
                record = registry.records[identity]
                server = record['server']
                nodes = client.remote_nodes(identity, record)
                if len(nodes) != 1:
                    raise DeployError('服务器管理需要唯一的入口节点，请先明确节点来源。')
                link = parse_node_link(nodes[0]['Link'])
                link.outbound()
                if server and server['backend'] == 'standalone':
                    from deploy_panels import retry_after_update
                    exported = retry_after_update(ssh, lambda: agent_call(ssh, identity, server, {'operation': 'export'}) if part == 'ssh'
                                                  else setup_agent(ssh, identity, server, link, draft),
                                                  {'entry_id': identity, 'installation_id': server['identity']})
                    backend = 'standalone'
                else:
                    try:
                        exported = export_node(ssh)
                        backend = 'project'
                    except SSHExportError as error:
                        if error.exit_code not in (103, 104):
                            raise
                        print('补全现有 3x-ui 管理配置。')
                        from deploy_panels import retry_after_update
                        exported = retry_after_update(ssh, lambda: setup_agent(ssh, identity, server, link, draft),
                            lambda: {key: value for key, value in draft.values.items() if key in ('panel_url', 'api_token')})
                        backend = 'standalone'
                server_id = exported['INSTALLATION_ID'].lower()
                if not re.fullmatch(r'[0-9a-f]{32}', server_id):
                    raise DeployError('服务器管理身份无效。')
                if server and (server['identity'] != server_id or server['backend'] != backend):
                    raise DeployError('新的 SSH 地址不是原入口安装，拒绝重新绑定。')
                if parse_node_link(exported['VLESS_URI']).fingerprint != link.fingerprint:
                    raise DeployError('SSH 服务器导出的节点与选中节点不一致。')
                registry.update(identity, ssh=binding,
                                server={'backend': backend, 'identity': server_id, 'fingerprint': link.fingerprint})
                if backend == 'standalone' and all(key in draft.values for key in ('panel_url', 'api_token')):
                    from deploy_credentials import Credentials
                    Credentials(registry.state).save_panel(identity, registry.records[identity]['server'], draft.values)
                draft.complete()
                diagnostic(registry, identity, part)
                print('SSH 连接配置已保存。' if part == 'ssh' else '3x-ui 管理配置已补全。')
            finally:
                ssh.close()
    except (DeployError, KeyboardInterrupt) as error:
        if isinstance(error, DeployError):
            diagnostic(registry, identity, part, error)
        print('补全进度已保留；从该配置的“编辑配置”继续，或返回原功能继续。', file=sys.stderr)
        raise


def ensure_entry(registry, identity, client, args, *, creation=None):
    from deploy import prompt_text
    missing = missing_entry_parts(registry.records[identity])
    server = registry.records[identity]['server']
    if server and has_source(registry.records[identity]) and not any(
            parse_node_link(node['Link']).fingerprint == server['fingerprint']
            for node in client.remote_nodes(identity, registry.records[identity])):
        missing.append('3x-ui 管理（节点来源已变化）')
    seed = creation.values if creation else None
    if missing:
        print('入口缺少：' + '、'.join(missing))
        if not sys.stdin.isatty():
            raise DeployError('请从此配置的编辑菜单补全所需配置后重试。')
        print('  1. 补全所需配置并继续\n  0. 返回')
        if prompt_text('请选择', '1') != '1':
            return False
        complete_part(registry, identity, client, args, 'server', seed=seed, on_ssh=creation.capture if creation else None)
    elif creation and any(k in seed and seed[k] != registry.records[identity]['ssh'][field]
                          for k, field in (('ssh_target', 'target'), ('ssh_port', 'port'),
                                           ('ssh_identity', 'identity'), ('ssh_password', 'password'))):
        complete_part(registry, identity, client, args, 'ssh', seed=seed, on_ssh=creation.capture)
    return True


def edit_part(registry, identity, client, args, part):
    from deploy import prompt_text, prompt_yes_no, SingBox, sync_dependents
    record = registry.records[identity]
    if client.url != record['sublink_url']:
        raise DeployError('SublinkPro 实例与此配置不同，未修改配置。')
    if part in ('ssh', 'server'):
        draft = PartInput(registry, identity, part)
        edit = bool(record['ssh'] if part == 'ssh' else record['server']) and not draft.path.exists()
        if draft.path.exists():
            print('此配置部分有未完成输入。\n  1. 继续上次\n  2. 修改设置\n  0. 返回')
            choice = prompt_text('请选择', '1')
            if choice == '0':
                return
            if choice not in ('1', '2'):
                raise DeployError('菜单选项无效。')
            edit = choice == '2'
        return complete_part(registry, identity, client, args, part, edit=edit)
    if part != 'source' or not sys.stdin.isatty():
        raise DeployError('请从编辑配置进入节点来源设置。')
    if record['remote_node_id'] and not record['airport_id']:
        raise DeployError('单条节点来源请直接编辑节点链接，不能替换成机场。')
    from deploy_subscription import subscription_export, validate_url
    from deploy import read_env
    draft = PartInput(registry, identity, part)
    if not record['airport_id']:
        source_type = draft.values.get('source_type') or getattr(args, 'source_type', None)
        if source_type is None:
            choice = prompt_text('节点来源（1=单条节点链接，2=订阅地址）', '1')
            if choice not in ('1', '2'):
                raise DeployError('节点来源选项无效。')
            source_type = 'link' if choice == '1' else 'subscription'
        draft.capture(source_type=source_type)
        if source_type == 'link':
            if 'source_link' not in draft.values:
                value = prompt_text('节点链接', required=True)
                parse_node_link(value)
                draft.capture(source_link=value)
            manager = NodeManager(client, registry, SingBox(read_env(record['env_file'])) if record['singbox'] else None)
            link = parse_node_link(draft.values['source_link'])
            adopt_id = None
            matches = manager.matching_nodes(link)
            if len(matches) == 1 and not manager.marker(matches[0]).startswith('okp-') and not matches[0].get('SourceID'):
                if prompt_yes_no(f"节点已存在于 SublinkPro ID {matches[0]['ID']}，是否关联复用", True):
                    adopt_id = matches[0]['ID']
            journal = manager.pending(identity) or manager.prepare(identity, link=link.link, name=record['node_name'],
                adopt_id=adopt_id, residential=record['residential'])
            manager.apply(journal)
            draft.complete()
            diagnostic(registry, identity, 'source')
            return
    airport = client.find('[okp:' + identity + ']') if record['airport_id'] else None
    if record['airport_id'] and (airport is None or airport['id'] != record['airport_id']):
        raise DeployError('节点来源的机场所有权不匹配。')
    if 'subscription_url' not in draft.values:
        url = prompt_text('订阅地址', airport['url'] if airport else None, required=True)
        validate_url(url)
        draft.capture(subscription_url=url, previous_url=airport['url'] if airport else '')
    if airport and airport['url'] not in (draft.values['previous_url'], draft.values['subscription_url']):
        raise DeployError('订阅地址被外部修改，未覆盖。')
    if 'insecure_subscription' not in draft.values:
        draft.capture(insecure_subscription=prompt_yes_no('订阅是否使用自签名证书', bool(airport and airport.get('skipTLSVerify'))))
    config = read_env(record['env_file'])
    local = bool(record['singbox'] and record['local_source'] == 'remote')
    old_setting = client.create_local_node
    try:
        exported = subscription_export(draft.values['subscription_url'], client.url, local=local,
                                       insecure=draft.values['insecure_subscription'], selected=draft.values.get('subscription_node'),
                                       interactive=True, prompt=prompt_text, on_input=draft.capture)
        exported.update(INSTALLATION_ID=identity, NODE_NAME=record['node_name'])
        client.create_local_node = local
        client.sync(exported, airport_name=record['airport_name'] or record['node_name'],
                    node_name=record['node_name'] if airport is None else None, local_port=record['local_port'],
                    registry=registry, singbox=SingBox(config) if local else None, residential=record['residential'])
        registry.update(identity, kind='subscription' if airport is None else record['kind'], status='active')
        sync_dependents(client, registry, config, identity)
        draft.complete()
        diagnostic(registry, identity, 'source')
        print('节点来源配置已保存。')
    except (DeployError, KeyboardInterrupt) as error:
        if isinstance(error, DeployError):
            diagnostic(registry, identity, 'source', error)
        print('节点来源补全进度已保留，请从编辑配置继续。', file=sys.stderr)
        raise
    finally:
        client.create_local_node = old_setting


def require_source(registry, identity, client, args):
    from deploy import prompt_text
    if has_source(registry.records[identity]):
        return True
    label = registry.records[identity]['node_name']
    if not sys.stdin.isatty():
        raise DeployError(label + ' 缺少节点来源，请先从编辑配置补全。')
    print(label + ' 缺少：节点来源\n  1. 补全所需配置并继续\n  0. 返回')
    if prompt_text('请选择', '1') != '1':
        return False
    edit_part(registry, identity, client, args, 'source')
    return True


def require_local(registry, identity, client, config):
    from deploy import prompt_text
    from deploy_resources import SingBox
    if registry.records[identity]['singbox']:
        return True
    if not sys.stdin.isatty():
        raise DeployError(registry.records[identity]['node_name'] + ' 缺少本地节点出站，请先补全本地节点。')
    print(registry.records[identity]['node_name'] + ' 缺少：本地节点出站\n  1. 补全所需配置并继续\n  0. 返回')
    if prompt_text('请选择', '1') != '1':
        return False
    draft = PartInput(registry, identity, 'local')
    if 'local_port' not in draft.values:
        draft.capture(local_port=client.choose_local_port(default=registry.records[identity]['local_port'], interactive=True))
    manager = NodeManager(client, registry, SingBox(config))
    journal = manager.pending(identity) or manager.prepare(identity, local_action='enable', local_port=draft.values['local_port'],
                residential=registry.records[identity]['residential'], intent={'part': 'local', 'local_port': draft.values['local_port']})
    manager.apply(journal)
    draft.complete()
    return True
