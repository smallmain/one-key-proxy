import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

import test_deploy as fixtures
import test_deploy_nodes as node_fixtures
import test_deploy_relay as relay_fixtures
import deploy_parts
from deploy_links import parse_node_link
from deploy_resources import DeployError

spec = importlib.util.spec_from_file_location('entry_agent', fixtures.ROOT / 'lib/entry_management.py')
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)
SERVER_ID = 'e' * 32


class ConfigurationPartTests(unittest.TestCase):
    setUp = node_fixtures.NodeWorkflowTests.setUp
    cleanup = node_fixtures.NodeWorkflowTests.cleanup
    cli = node_fixtures.NodeWorkflowTests.cli
    registry = node_fixtures.NodeWorkflowTests.registry
    record = node_fixtures.NodeWorkflowTests.record
    node = node_fixtures.NodeWorkflowTests.node
    add = node_fixtures.NodeWorkflowTests.add

    def partial(self, name='Pending'):
        self.cli(['add', '--partial', '--node-name', name])
        return self.record(name)

    def part_cli(self, identity, part, answers, *, exported=None, failure=None, edit_args=(), argv=None, handler=None):
        calls, output = [], io.StringIO()

        def run(command, **kwargs):
            if 'python3 -I' not in command:
                return b''
            request = json.loads(kwargs['data'])
            calls.append((command, request))
            if handler:
                return handler(request)
            if failure:
                return json.dumps({'ok': False, 'error': failure}).encode()
            if request['operation'] in ('setup', 'export'):
                result = exported or {'INSTALLATION_ID': SERVER_ID, 'VLESS_URI': node_fixtures.VLESS}
            elif request['operation'] == 'panel-info':
                result = {'current': 'v3.9.0', 'core_current': 'v26.7.28', 'updatable': True, 'reason': None}
            else:
                link = node_fixtures.VLESS.replace(parse_node_link(node_fixtures.VLESS).auth['uuid'], str(uuid.UUID(request['identity'])))
                result = {'link': parse_node_link(link).marked(request['identity']), 'installation_id': SERVER_ID}
            return json.dumps({'ok': True, 'result': result}).encode()

        with patch.dict(sys.modules, {'deploy': fixtures.deploy}), \
                patch.object(fixtures.deploy.sys.stdin, 'isatty', return_value=True), \
                patch('builtins.input', side_effect=answers), \
                patch.object(deploy_parts.getpass, 'getpass', return_value='private-api-token-123456789') as secret, \
                patch.object(fixtures.deploy, 'SSH') as ssh, \
                patch.object(fixtures.deploy, 'export_node', side_effect=fixtures.deploy.SSHExportError('missing runtime', 103)), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            ssh.return_value.run.side_effect = run
            fixtures.deploy.main(argv or ['edit', identity, '--part', part] + list(edit_args))
        return calls, secret, output.getvalue()

    def test_add_partial_and_basic_edit_need_no_published_resources(self):
        identity, record = self.partial()
        self.assertFalse(deploy_parts.has_source(record))
        self.assertEqual(record['status'], 'active')
        self.assertEqual(deploy_parts.missing_entry_parts(record), ['节点来源', 'SSH 连接', '3x-ui 管理'])
        self.assertEqual(self.server.state['calls'], [])
        self.cli(['edit', identity], ['1', 'New name'])
        self.cli(['edit', identity], ['6', 'y'])
        after = self.registry().records[identity]
        self.assertEqual(after['node_name'], 'New name')
        self.assertTrue(after['residential'])
        self.assertEqual(self.server.state['calls'], [])

    def test_tui_add_can_leave_source_unset(self):
        self.cli(['add'], ['4', 'Only metadata', 'n'])
        _, record = self.record('Only metadata')
        self.assertFalse(deploy_parts.has_source(record))

    def test_local_only_config_can_be_enabled_tagged_and_later_gain_a_source(self):
        identity, _ = self.partial()
        self.cli(['edit', identity], ['3', '7903', node_fixtures.SOCKS])
        before = self.registry().records[identity]
        self.assertIsNone(before['remote_node_id'])
        self.assertEqual(before['local_source'], 'custom')
        config = self.path.read_bytes()
        self.cli(['edit', identity], ['6', 'y'])
        self.assertIn('家宽', self.server.state['tags'][before['local_node_id']])
        self.cli(['edit', identity, '--node-link', node_fixtures.VLESS])
        after = self.registry().records[identity]
        self.assertIsNotNone(after['remote_node_id'])
        self.assertEqual(after['local_node_id'], before['local_node_id'])
        self.assertEqual(after['local_port'], 7903)
        self.assertEqual(after['local_source'], 'custom')
        self.assertEqual(self.path.read_bytes(), config)
        self.assertIn('家宽', self.server.state['tags'][after['remote_node_id']])

    def test_ssh_part_does_not_require_a_node_source_or_install_runtime(self):
        identity, _ = self.partial()
        calls, secret, _ = self.part_cli(identity, 'ssh', ['entry.example', '', 'y'])
        record = self.registry().records[identity]
        self.assertEqual(record['ssh']['target'], 'entry.example')
        self.assertIsNone(record['server'])
        self.assertIsNone(record['remote_node_id'])
        self.assertEqual(calls, [])
        secret.assert_not_called()

    def test_server_completion_preserves_source_and_keeps_credentials_out_of_arguments(self):
        identity, before = self.add('Entry', node_fixtures.VLESS)
        nodes_before = copy.deepcopy(self.server.state['nodes'])
        calls, secret, output = self.part_cli(identity, 'server', ['entry.example', '', 'y', 'http://127.0.0.1:54321/prefix/'])
        after = self.registry().records[identity]
        self.assertEqual(after['remote_node_id'], before['remote_node_id'])
        self.assertEqual(after['kind'], before['kind'])
        self.assertEqual(after['server']['backend'], 'standalone')
        self.assertEqual(after['server']['identity'], SERVER_ID)
        self.assertEqual(self.server.state['nodes'], nodes_before)
        self.assertEqual(len(calls), 1)
        command, request = calls[0]
        self.assertNotIn('private-api-token', command)
        self.assertEqual(request['api_token'], 'private-api-token-123456789')
        self.assertEqual(set(request['sources']), {'entry_management.py', 'remote_relay.py', 'panel_version.py'})
        self.assertIn('正在验证面板 API 和入口节点', output)
        self.assertNotIn('private-api-token', output)
        self.assertFalse(deploy_parts.PartInput(self.registry(), identity, 'server').path.exists())
        from deploy_credentials import Credentials
        saved = Credentials(self.registry().state).panel(identity, after['server'])
        self.assertEqual(saved['api_token'], 'private-api-token-123456789')
        self.assertEqual(Credentials(self.registry().state).panel_path(identity).stat().st_mode & 0o777, 0o600)
        secret.assert_called_once()

    def test_failed_server_part_keeps_ssh_and_resumes_without_reentering_token(self):
        identity, _ = self.add('Entry', node_fixtures.VLESS)
        with self.assertRaisesRegex(DeployError, '权限不足'):
            self.part_cli(identity, 'server', ['entry.example', '', 'y', 'http://127.0.0.1:54321/'], failure='API 权限不足')
        record = self.registry().records[identity]
        self.assertIsNotNone(record['ssh'])
        self.assertIsNone(record['server'])
        self.assertIn('权限不足', deploy_parts.parts(record)['3x-ui 管理'])
        draft = deploy_parts.PartInput(self.registry(), identity, 'server')
        self.assertEqual(draft.path.stat().st_mode & 0o777, 0o600)
        self.assertTrue(draft.values['ssh_password'])
        _, secret, _ = self.part_cli(identity, 'server', ['1'])
        secret.assert_not_called()
        self.assertEqual(self.registry().records[identity]['part_errors'], {})

    def test_server_completion_updates_old_panel_and_continues_with_same_inputs(self):
        import deploy_panels
        identity, before = self.add('Entry', node_fixtures.VLESS)
        setups = []
        def handler(request):
            if request['operation'] == 'setup':
                setups.append(request)
                if len(setups) == 1:
                    return json.dumps({'ok': False, 'code': 'panel_version_required', 'current': 'v3.5.0', 'error': '版本过低'}).encode()
                result = {'INSTALLATION_ID': SERVER_ID, 'VLESS_URI': node_fixtures.VLESS}
            elif request['operation'] == 'panel-info':
                result = {'current': 'v3.5.0', 'core_current': 'v26.7.11', 'updatable': True, 'reason': None}
            else:
                self.assertEqual(request['operation'], 'panel-update')
                self.assertEqual(request['target'], 'v3.9.0')
                self.assertEqual(request['core_target'], 'v26.7.28')
                self.assertEqual(request['api_token'], 'private-api-token-123456789')
                result = {'current': 'v3.9.0', 'core_current': 'v26.7.28'}
            return json.dumps({'ok': True, 'result': result}).encode()
        with patch.object(deploy_panels, 'catalog', return_value=[{'tag_name': 'v3.8.0', 'draft': False, 'prerelease': False},
                                                               {'tag_name': 'v3.9.0', 'draft': False, 'prerelease': False}]), \
                patch.object(deploy_panels, 'compatible_core', return_value='v26.7.28'):
            calls, secret, output = self.part_cli(identity, 'server', ['entry.example', '', 'y', 'http://127.0.0.1:54321/prefix/', ''], handler=handler)
        self.assertEqual(len(setups), 2)
        self.assertEqual(setups[0], setups[1])
        self.assertEqual(self.registry().records[identity]['remote_node_id'], before['remote_node_id'])
        self.assertEqual(self.registry().records[identity]['server']['identity'], SERVER_ID)
        secret.assert_called_once()
        self.assertNotIn('private-api-token', output)
        self.assertFalse(deploy_parts.PartInput(self.registry(), identity, 'server').path.exists())

    def test_pending_server_completion_does_not_block_unrelated_name_edit(self):
        identity, _ = self.add('Entry', node_fixtures.VLESS)
        with self.assertRaises(DeployError):
            self.part_cli(identity, 'server', ['entry.example', '', 'y', 'http://127.0.0.1:54321/'], failure='API unavailable')
        self.cli(['edit', identity], ['1', 'Renamed entry'])
        self.assertEqual(self.registry().records[identity]['node_name'], 'Renamed entry')
        self.assertTrue(deploy_parts.PartInput(self.registry(), identity, 'server').path.exists())

    def test_remote_creation_completes_manual_entry_then_returns_to_original_operation(self):
        entry_id, original = self.add('Manual entry', node_fixtures.VLESS)
        exit_id, _ = self.add('Home exit', node_fixtures.SOCKS)
        source_before = copy.deepcopy(self.node(original['remote_node_id']))
        calls, _, output = self.part_cli(entry_id, 'server',
            ['1', 'entry.example', '', 'y', 'http://127.0.0.1:54321/', 'y'],
            argv=['remote-relay', exit_id, '--entry', entry_id, '--name', 'Home exit(Manual entry中转)', '--no-local-node', '--no-residential'])
        registry = self.registry()
        self.assertEqual(registry.records[entry_id]['server']['backend'], 'standalone')
        self.assertEqual(self.node(original['remote_node_id']), source_before)
        self.assertEqual([request['operation'] for _, request in calls], ['setup', 'panel-info', 'apply'])
        chains = [r for r in registry.records.values() if r['kind'] == 'remote-relay']
        self.assertEqual(len(chains), 1)
        self.assertEqual(chains[0]['status'], 'active')
        self.assertIsNone(registry.records[exit_id]['ssh'])
        self.assertIn('已创建远程中转', output)

    def test_ssh_edit_rejects_other_server_and_keeps_original_binding(self):
        identity, _ = self.add('Entry', node_fixtures.VLESS)
        self.part_cli(identity, 'server', ['entry.example', '', 'y', 'http://127.0.0.1:54321/'])
        before = copy.deepcopy(self.registry().records[identity]['ssh'])
        with self.assertRaisesRegex(DeployError, '不是原入口安装'):
            self.part_cli(identity, 'ssh', ['other.example', '', 'y'],
                          exported={'INSTALLATION_ID': 'f' * 32, 'VLESS_URI': node_fixtures.VLESS})
        self.assertEqual(self.registry().records[identity]['ssh'], before)

    def test_remote_exit_with_missing_source_can_fill_it_before_creating(self):
        entry_id, _ = self.add('Manual entry', node_fixtures.VLESS)
        exit_id, _ = self.partial('Empty exit')
        calls, _, _ = self.part_cli(entry_id, 'server',
            ['1', '1', node_fixtures.SOCKS, '1', 'entry.example', '', 'y', 'http://127.0.0.1:54321/', 'y'],
            argv=['remote-relay', exit_id, '--entry', entry_id, '--name', 'Combination', '--no-local-node', '--no-residential'])
        self.assertTrue(deploy_parts.has_source(self.registry().records[exit_id]))
        self.assertEqual([request['operation'] for _, request in calls], ['setup', 'panel-info', 'apply'])
        self.assertEqual(self.registry().records[self.registry().select('Combination')]['status'], 'active')

    def test_local_relay_can_fill_missing_parent_local_outbound(self):
        entry_id, _ = self.add('Local entry', node_fixtures.VLESS)
        exit_id, _ = self.add('Local exit', node_fixtures.SOCKS, 7900)
        with patch.dict(sys.modules, {'deploy': fixtures.deploy}), \
                patch.object(fixtures.deploy.SublinkPro, 'port_available', return_value=True):
            self.cli(['relay', exit_id, '--via', entry_id], ['1', ''])
        registry = self.registry()
        self.assertIsNotNone(registry.records[entry_id]['singbox'])
        self.assertEqual(registry.records[exit_id]['relay_id'], entry_id)
        box = json.loads(self.path.read_bytes())
        outbound = next(o for o in box['outbounds'] if o['tag'] == registry.records[exit_id]['singbox']['outbound_tag'])
        self.assertEqual(outbound['detour'], registry.records[entry_id]['singbox']['outbound_tag'])

    def test_subscription_source_preserves_management_id(self):
        identity, _ = self.partial()
        with patch.dict(sys.modules, {'deploy': fixtures.deploy}):
            self.cli(['edit', identity], ['2', '2', 'https://subscription.example/path', 'n'])
        record = self.registry().records[identity]
        self.assertEqual(record['kind'], 'subscription')
        self.assertIsNotNone(record['airport_id'])
        self.assertEqual(record['node_name'], 'Pending')
        self.assertFalse(deploy_parts.PartInput(self.registry(), identity, 'source').path.exists())

    def test_existing_airport_edits_preserve_imported_node_and_resource_ids(self):
        identity, _ = self.partial()
        with patch.dict(sys.modules, {'deploy': fixtures.deploy}):
            self.cli(['edit', identity, '--part', 'source'], ['2', 'https://subscription.example/path', 'n'])
        registry = self.registry()
        airport_id = registry.records[identity]['airport_id']
        self.server.state['nodes'].append(dict(fixtures.SS_TEMPLATE, ID=501, Name='[SM]Pending',
            Protocol='vless', SourceID=airport_id, Source='airport', Link=node_fixtures.VLESS))
        self.cli(['edit', identity], ['1', 'New node name'])
        self.assertEqual(self.node(501)['SourceID'], airport_id)
        self.assertEqual(self.node(501)['Link'], node_fixtures.VLESS)
        self.assertEqual(self.node(501)['Name'], '[SM]New node name')
        self.cli(['edit', identity], ['3', '7904'])
        before = self.registry().records[identity]
        self.cli(['edit', identity], ['9', 'New airport name'])
        after = self.registry().records[identity]
        self.assertEqual(after['airport_id'], airport_id)
        self.assertEqual(after['local_node_id'], before['local_node_id'])
        self.assertEqual(after['airport_name'], 'New airport name')


class EntryAgentTests(unittest.TestCase):
    def setUp(self):
        self.api = relay_fixtures.FakeXui()
        self.api.clients[0]['flow'] = 'xtls-rprx-vision'
        self.version = 'v3.9.0'
        self.inbound_changes = {}

    def panel(self, method, path, fields=None, **kwargs):
        if path == '/panel/api/server/status':
            return {'panelVersion': self.version, 'xray': {'state': 'running', 'errorMsg': ''}}
        if path == '/panel/api/setting/apiTokens':
            return []
        result = self.api.api(method, path, fields, **kwargs)
        if path == '/panel/api/inbounds/list':
            result[0].update(enable=True, **self.inbound_changes)
        return result

    def test_discovery_checks_matching_client_and_reads_only_existing_configuration(self):
        before = copy.deepcopy((self.api.clients, self.api.template))
        context, snapshot = agent.discover(self.panel, node_fixtures.VLESS)
        self.assertEqual(context['inbound_id'], 42)
        self.assertEqual(context['inbound_tag'], 'entry-in')
        self.assertEqual((self.api.clients, self.api.template), before)
        self.assertFalse(any(path.endswith('/update') or '/clients/' in path for _, path, _, _ in self.api.calls))
        self.assertEqual(snapshot['template'], self.api.original)

    def test_discovery_rejects_old_version_wrong_client_and_parameter_drift(self):
        self.version = 'v3.7.0'
        with self.assertRaisesRegex(agent.EntryError, '3.8.0'):
            agent.discover(self.panel, node_fixtures.VLESS)
        self.version = 'v3.9.0'
        link = node_fixtures.VLESS.replace('00000000-0000-4000-8000-000000000001', str(uuid.uuid4()))
        with self.assertRaisesRegex(agent.EntryError, '唯一匹配'):
            agent.discover(self.panel, link)
        context, _ = agent.discover(self.panel, node_fixtures.VLESS)
        context['inbound_tag'] = 'another-entry'
        with self.assertRaisesRegex(agent.EntryError, '身份或连接参数'):
            agent.discover(self.panel, node_fixtures.VLESS, context)

    def test_panel_url_normalization_and_credentials_are_restricted(self):
        self.assertEqual(agent.panel_url('https://panel.example/prefix/panel/'), 'https://panel.example/prefix')
        self.assertEqual(agent.panel_url('http://127.0.0.1:54321/prefix/'), 'http://127.0.0.1:54321/prefix')
        for value in ('http://panel.example', 'https://user:secret@panel.example/', 'https://panel.example/?secret=token'):
            with self.subTest(value=value), self.assertRaises(agent.EntryError) as error:
                agent.panel_url(value)
            self.assertNotIn('secret', str(error.exception))

    def test_bootstrap_is_repeatable_without_reconfiguring_3xui(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime, state = root / 'runtime', root / 'state'
            request = {'entry_id': 'a' * 32, 'expected_identity': None, 'panel_url': 'http://127.0.0.1:54321',
                       'api_token': 'private-token-123456789', 'link': node_fixtures.VLESS,
                       'sources': {name: (fixtures.ROOT / 'lib' / name).read_text() for name in ('entry_management.py', 'remote_relay.py', 'panel_version.py')}}
            original_secure = agent.secure_directory

            def secure(path, **kwargs):
                if path == root or root in path.parents:
                    original_secure(path, **kwargs)

            before = copy.deepcopy((self.api.clients, self.api.template))
            class PanelProxy:
                url = request['panel_url']
                token = request['api_token']
                __call__ = staticmethod(self.panel)

            with patch.object(agent, 'RUNTIME', runtime), patch.object(agent, 'STATE', state), \
                    patch.object(agent, 'secure_directory', secure), patch.object(agent, 'Panel', return_value=PanelProxy()):
                first = agent.bootstrap(request)
                second = agent.bootstrap(request)
                self.assertEqual(first, second)
                self.assertEqual((self.api.clients, self.api.template), before)
                stored = agent.private_read(state / ('a' * 32 + '.json'))
                self.assertEqual(stored['inbound_tag'], 'entry-in')
                self.assertEqual((state / ('a' * 32 + '.json')).stat().st_mode & 0o777, 0o600)
                operation = {'entry_id': request['entry_id'], 'identity': 'c' * 32,
                             'installation_id': first['INSTALLATION_ID'], 'operation': 'apply',
                             'outbound': parse_node_link(node_fixtures.SOCKS).xray_outbound()}
                created = agent.run(operation)
                self.assertEqual(created['installation_id'], first['INSTALLATION_ID'])
                self.assertEqual(self.api.clients[0], before[0][0])
                self.assertEqual(agent.run(dict(operation, operation='inspect')), created)
                self.assertEqual(agent.run(dict(operation, operation='delete')), {'deleted': True})
                self.assertEqual((self.api.clients, self.api.template), before)
                with self.assertRaisesRegex(agent.EntryError, '原先绑定'):
                    agent.bootstrap(dict(request, expected_identity='b' * 32))
                with self.assertRaisesRegex(agent.EntryError, '不一致'):
                    agent.run({'entry_id': 'a' * 32, 'installation_id': 'b' * 32, 'operation': 'export'})

    def test_unsafe_management_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'link').symlink_to(root)
            with self.assertRaises(agent.EntryError):
                agent.secure_directory(root / 'link')


if __name__ == '__main__':
    unittest.main()
