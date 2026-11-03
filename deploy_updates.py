"""Resumable configuration update stages shared by the menu and CLI."""

import hashlib
import json
import os
from pathlib import Path
import re
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from deploy_links import parse_node_link
from deploy_resources import DeployError, SingBox, atomic_write

LEGACY_TARGET = 'www.cloudflare.com:443'
DEFAULT_TARGET = 'www.tencentcloud.com:443'
STAGES = ('runtime', 'panel', 'reality', 'local')


class ConfigUpdates:
    def __init__(self, registry, remote):
        self.registry, self.remote = registry, remote
        root = Path(__file__).resolve().parent
        paths = [root / name for name in ('bootstrap.sh', 'install.sh', 'maintenance.sh', 'one-key-proxy', 'VERSION')]
        paths += sorted((root / 'lib').glob('*.sh')) + sorted((root / 'lib').glob('*.py'))
        self.sources = {}
        for path in paths:
            if path.is_symlink() or not path.is_file() or path.stat().st_nlink != 1:
                raise DeployError('项目运行文件必须是普通文件。')
            self.sources[path.relative_to(root).as_posix()] = path.read_text(encoding='utf-8')
        self.hashes = {key: hashlib.sha256(value.encode()).hexdigest() for key, value in self.sources.items()}

    def path(self, identity):
        if not re.fullmatch('[0-9a-f]{32}', identity):
            raise DeployError('配置标识无效。')
        return self.registry.state.directory / ('config-update-' + identity + '.json')

    def pending(self, identity):
        try:
            fd = self.registry.state.open_private(self.path(identity), os.O_RDONLY)
        except FileNotFoundError:
            return None
        try:
            with os.fdopen(fd, encoding='utf-8') as stream:
                record = json.loads(stream.read(65537))
            if (set(record) != {'version', 'identity', 'project_identity', 'before_uri', 'phase'}
                    or record['version'] != 1 or record['identity'] != identity
                    or not re.fullmatch('[0-9a-f]{32}', record['project_identity'])
                    or record['phase'] not in STAGES):
                raise ValueError
            parse_node_link(record['before_uri'])
            return record
        except (ValueError, TypeError, KeyError):
            raise DeployError('配置更新恢复记录无效。') from None

    def save(self, journal, phase):
        journal['phase'] = phase
        atomic_write(self.path(journal['identity']), json.dumps(journal).encode())

    def validate_export(self, identity, exported):
        record = self.registry.records[identity]
        if exported['INSTALLATION_ID'].lower() != record['server']['identity']:
            raise DeployError('SSH 目标与原服务器标识不同。')
        current = parse_node_link(exported['VLESS_URI']).server_fingerprint
        if current == record['server']['fingerprint']:
            return
        journal = self.pending(identity)
        if journal and journal['project_identity'] == record['server']['identity']:
            before = parse_node_link(journal['before_uri'])
            uri = urlsplit(journal['before_uri'])
            query = dict(parse_qsl(uri.query))
            if query.get('sni') == 'www.cloudflare.com':
                query['sni'] = 'www.tencentcloud.com'
            migrated = parse_node_link(urlunsplit(uri._replace(query=urlencode(query))))
            if (record['server']['fingerprint'] in (before.server_fingerprint, migrated.server_fingerprint)
                    and current in (before.server_fingerprint, migrated.server_fingerprint)):
                return
        raise DeployError('服务器连接参数与受管记录不符，不能自动更新。')

    def request(self, identity, operation, **fields):
        return dict(operation=operation, project_identity=self.registry.records[identity]['server']['identity'],
                    runtime_hashes=self.hashes, **fields)

    def inspect(self, row):
        identity = row['identity']
        record = self.registry.records[identity]
        if not record['server'] or record['server']['backend'] != 'project':
            row['steps'] = '面板 / 内核（非项目安装）'
            return
        status = self.remote(row['ssh'], self.request(identity, 'config-info'))
        row['config_status'] = status
        pending = self.pending(identity)
        steps = []
        if status['runtime_changed']:
            steps.append('同步运行脚本')
        if row['eligible']:
            steps.append('面板 / 内核')
        if status['migrate']:
            steps.append('REALITY → 腾讯云')
        if steps or pending:
            steps.append('刷新订阅 / 本机节点')
        row['steps'] = '、'.join(steps) or '无需更新'
        dependencies = any(item['remote_relay'] and identity in (
            item['remote_relay']['entry_id'], item['remote_relay']['exit_id'], item['remote_relay']['pending_exit_id'])
            for item in self.registry.records.values())
        if (status['migrate'] and dependencies) or status['migration_blocked']:
            row.update(eligible=False, migration_blocked=True, reason='REALITY 迁移前需清理关联远程中转')
        elif pending or status.get('runtime_pending'):
            row.update(eligible=True, reason='配置更新未完成，可继续')
        elif row.get('updatable') and row.get('core_target') and steps:
            row.update(eligible=True, reason='可更新配置')

    def sync_local(self, identity, exported):
        from deploy import SublinkPro, read_env
        from deploy_nodes import NodeManager
        from deploy_relay import sync_dependents, RemoteRelayManager
        record = self.registry.records[identity]
        if not record['airport_id'] and not record['remote_node_id']:
            return
        config = read_env(record['env_file'])
        enabled = bool(record['singbox'] or record['local_node_id'])
        client = SublinkPro(config, create_local_node=enabled)
        if client.url != record['sublink_url']:
            raise DeployError('配置绑定的 SublinkPro 地址发生变化。')
        box = SingBox(config) if enabled else None
        if record['airport_id']:
            published = dict(exported, INSTALLATION_ID=identity)
            client.sync(published, airport_name=record['airport_name'], node_name=record['node_name'],
                        local_port=record['local_port'] if enabled else None, registry=self.registry,
                        singbox=box, residential=record['residential'])
            RemoteRelayManager(client, self.registry, config).refresh_source(identity)
            expected = parse_node_link(exported['VLESS_URI']).server_fingerprint
            if not any(parse_node_link(node['Link']).server_fingerprint == expected
                       for node in client.remote_nodes(identity, self.registry.records[identity])):
                raise DeployError('订阅拉取完成，但节点尚未使用新的连接参数。')
        else:
            manager = NodeManager(client, self.registry, box)
            pending = manager.pending(identity)
            if pending:
                manager.apply(pending)
            manager.apply(manager.prepare(identity, link=exported['VLESS_URI'],
                local_action='enable' if enabled else 'keep', local_port=record['local_port'] if enabled else None,
                relay_id=record['relay_id']))
        sync_dependents(client, self.registry, config, identity)

    def execute(self, row):
        from deploy import export_node
        identity, ssh = row['identity'], row['ssh']
        project = self.registry.records[identity]['server']
        if not project or project['backend'] != 'project':
            return self.update_panel(row)
        identities = [item for item in row.get('identities', [identity])
                      if self.registry.records[item]['server'] and
                      self.registry.records[item]['server']['backend'] == 'project']
        journals = []
        for item in identities:
            journal = self.pending(item)
            if journal is None:
                exported = export_node(ssh)
                self.validate_export(item, exported)
                journal = dict(version=1, identity=item, project_identity=project['identity'],
                               before_uri=exported['VLESS_URI'], phase='runtime')
                self.save(journal, 'runtime')
            journals.append(journal)
        # Every stage revalidates actual state, including after a lost SSH response.
        for stage in STAGES:
            for journal in journals:
                self.save(journal, stage)
            print(f'{row["name"]}：{dict(runtime="同步运行脚本", panel="更新面板和内核", reality="迁移 REALITY 目标", local="刷新订阅和本机节点")[stage]}。', flush=True)
            if stage == 'runtime':
                self.remote(ssh, self.request(identity, 'config-runtime', runtime_sources=self.sources))
            elif stage == 'panel':
                self.update_panel(row)
            elif stage == 'reality':
                self.remote(ssh, self.request(identity, 'config-migrate'))
            elif stage == 'local':
                exported = export_node(ssh)
                for item in identities:
                    self.validate_export(item, exported)
                    self.sync_local(item, exported)
                    bound = self.registry.records[item]['server']
                    self.registry.update(item, server=dict(bound,
                        fingerprint=parse_node_link(exported['VLESS_URI']).server_fingerprint))
            else:
                raise DeployError('未知配置更新阶段。')
        result = self.remote(ssh, dict(row.get('context', {}), operation='panel-info'))
        if result.get('current') != row['target'] or result.get('core_current') != row['core_target']:
            raise DeployError('最终面板或内核版本发生变化，请重新检测后继续。')
        for item in identities:
            self.path(item).unlink()
        return result

    def update_panel(self, row):
        ssh, context = row['ssh'], row.get('context', {})
        info = self.remote(ssh, dict(context, operation='panel-info'))
        if info.get('pending'):
            info = self.remote(ssh, dict(context, operation='panel-recover'))
        if not info.get('updatable'):
            raise DeployError(info.get('reason') or '当前面板无法自动更新。')
        if info['current'] == row['target'] and info.get('core_current') == row.get('core_target'):
            return info
        if row.get('core_target') is None:
            raise DeployError('无法确定兼容 Xray 版本，请重新检测后继续。')
        result = self.remote(ssh, dict(context, operation='panel-update', current=info['current'],
            target=row['target'], core_current=info.get('core_current'), core_target=row.get('core_target')))
        if result.get('current') != row['target'] or result.get('core_current') != row['core_target']:
            raise DeployError('面板或内核更新结果与选定版本不符。')
        return result
