import base64
import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import test_deploy as fixtures
import test_deploy_nodes as node_fixtures
import test_deploy_panels as panel_fixtures
import deploy_updates as updates
from deploy_resources import DeployError
from deploy_links import parse_node_link
from lib import config_update as remote


class ConfigWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.fixture = node_fixtures.NodeWorkflowTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.identity, _ = self.fixture.add('update-test', node_fixtures.VLESS)
        self.registry = self.fixture.registry()
        self.before = node_fixtures.VLESS.replace('sni=www.example.com', 'sni=www.cloudflare.com')
        # Use a fixed canonical URI with a legacy target independent of other fixtures.
        self.before = ('vless://00000000-0000-4000-8000-000000000001@node.example:443?'
                       'security=reality&type=tcp&flow=xtls-rprx-vision&sni=www.cloudflare.com'
                       '&fp=chrome&pbk=' + 'a' * 43 + '&sid=abcd')
        self.after = self.before.replace('sni=www.cloudflare.com', 'sni=www.tencentcloud.com')
        self.registry.update(self.identity, server={'backend': 'project', 'identity': self.identity,
            'fingerprint': parse_node_link(self.before).server_fingerprint},
            ssh={'target': 'entry.example', 'port': 22, 'identity': None, 'password': False})
        self.calls = []
        self.live_uri = self.before
        self.live_version = 'v3.9.0'
        self.fail_sync = False
        self.manager = updates.ConfigUpdates(self.registry, self.call)
        self.row = dict(identity=self.identity, identities=[self.identity], name='update-test', ssh=Mock(),
                        target='v3.11.0', core_target='v26.7.28', current='v3.9.0', eligible=True,
                        updatable=True, context={})

    def exported(self, ssh):
        return {'INSTALLATION_ID': self.identity, 'VLESS_URI': self.live_uri}

    def call(self, ssh, request):
        self.calls.append(request['operation'])
        operation = request['operation']
        if operation == 'panel-update':
            self.live_version = request['target']
        if operation == 'config-migrate':
            self.live_uri = self.after
        if operation.startswith('config-'):
            return dict(runtime_changed=True, migrate=self.live_uri == self.before,
                        migration_blocked=False, reality_target='www.cloudflare.com:443')
        return {'current': self.live_version, 'core_current': 'v26.7.28', 'updatable': True}

    def execute(self):
        with patch.object(fixtures.deploy, 'export_node', side_effect=self.exported), \
                patch.dict('sys.modules', {'deploy': fixtures.deploy}), \
                patch.object(self.manager, 'sync_local', side_effect=DeployError('sync failed') if self.fail_sync else None), \
                contextlib.redirect_stdout(io.StringIO()):
            return self.manager.execute(self.row)

    def test_stage_order_refreshes_binding_only_after_local_success(self):
        result = self.execute()
        self.assertEqual(result['current'], 'v3.11.0')
        self.assertEqual(self.calls, ['config-runtime', 'panel-info', 'panel-update', 'config-migrate', 'panel-info'])
        self.assertEqual(self.registry.records[self.identity]['server']['fingerprint'],
                         parse_node_link(self.after).server_fingerprint)
        self.assertIsNone(self.manager.pending(self.identity))

    def test_local_failure_resumes_after_remote_sni_changed_without_repeating_upgrade(self):
        self.fail_sync = True
        with self.assertRaisesRegex(DeployError, 'sync failed'):
            self.execute()
        self.assertEqual(self.manager.pending(self.identity)['phase'], 'local')
        self.assertEqual(self.registry.records[self.identity]['server']['fingerprint'],
                         parse_node_link(self.before).server_fingerprint)
        self.manager.validate_export(self.identity, self.exported(None))
        self.fail_sync = False
        self.calls.clear()
        self.execute()
        self.assertNotIn('panel-update', self.calls)
        self.assertIsNone(self.manager.pending(self.identity))

    def test_pending_migration_does_not_authorize_different_credentials_or_host(self):
        self.fail_sync = True
        with self.assertRaises(DeployError):
            self.execute()
        for changed in (self.after.replace('node.example', 'foreign.example'),
                        self.after.replace('00000000-0000-4000-8000-000000000001',
                                           '00000000-0000-4000-8000-000000000002')):
            with self.assertRaises(DeployError):
                self.manager.validate_export(self.identity, dict(self.exported(None), VLESS_URI=changed))

    def test_current_versions_still_allow_runtime_and_target_updates(self):
        self.row.update(eligible=False, target='v3.9.0', core_current='v26.7.28')
        self.manager.inspect(self.row)
        self.assertTrue(self.row['eligible'])
        self.assertIn('REALITY', self.row['steps'])

    def test_menu_scan_includes_project_migration_when_versions_are_current(self):
        import deploy_panels
        self.live_version = 'v3.11.0'
        with patch.dict('sys.modules', {'deploy': fixtures.deploy}), \
                patch.object(fixtures.deploy, 'export_node', side_effect=self.exported), \
                patch.object(deploy_panels, 'run_helper', side_effect=self.call), \
                contextlib.redirect_stdout(io.StringIO()):
            rows = deploy_panels.scan(self.registry, Mock(), [panel_fixtures.release('v3.11.0')],
                                      'v26.7.28', self.manager)
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]['eligible'])
        self.assertEqual(rows[0]['target'], 'v3.11.0')
        self.assertIn('同步运行脚本', rows[0]['steps'])

    def test_runtime_restore_does_not_require_export_from_a_missing_runtime(self):
        import deploy_panels
        journal = dict(version=1, identity=self.identity, project_identity=self.identity,
                       before_uri=self.before, phase='runtime')
        self.manager.save(journal, 'runtime')
        original = self.call
        def interrupted(ssh, request):
            if request['operation'] == 'config-info':
                return dict(runtime_pending=True, runtime_changed=True, migrate=False,
                            migration_blocked=False, reality_target='待恢复')
            return original(ssh, request)
        self.manager.remote = interrupted
        with patch.dict('sys.modules', {'deploy': fixtures.deploy}), \
                patch.object(fixtures.deploy, 'export_node', side_effect=DeployError('missing runtime')) as export, \
                patch.object(deploy_panels, 'run_helper', side_effect=interrupted), \
                contextlib.redirect_stdout(io.StringIO()):
            rows = deploy_panels.scan(self.registry, Mock(), [panel_fixtures.release('v3.11.0')],
                                      'v26.7.28', self.manager)
        self.assertTrue(rows[0]['eligible'])
        export.assert_not_called()

    def test_remote_dependency_blocks_migration_before_mutation(self):
        self.manager.remote = Mock(return_value=dict(runtime_changed=True, migrate=True,
            migration_blocked=True, reality_target='www.cloudflare.com:443'))
        self.manager.inspect(self.row)
        self.assertFalse(self.row['eligible'])
        self.assertIn('中转', self.row['reason'])

    def test_nonproject_installation_only_updates_panel(self):
        self.registry.update(self.identity, server=None)
        self.execute()
        self.assertEqual(self.calls, ['panel-info', 'panel-update'])
        self.assertIsNone(self.manager.pending(self.identity))

    def test_real_local_sync_preserves_node_ids_and_local_enablement(self):
        identity, before = self.fixture.add('local-enabled', node_fixtures.VLESS.replace('example.invalid', 'local.example'), 7915)
        registry = self.fixture.registry()
        manager = updates.ConfigUpdates(registry, self.call)
        changed = node_fixtures.VLESS.replace('example.invalid', 'local.example').replace('www.cloudflare.com', 'www.tencentcloud.com')
        with patch.dict('sys.modules', {'deploy': fixtures.deploy}):
            manager.sync_local(identity, {'INSTALLATION_ID': identity, 'VLESS_URI': changed})
        after = registry.records[identity]
        self.assertEqual((before['remote_node_id'], before['local_node_id'], before['local_port'], before['node_name']),
                         (after['remote_node_id'], after['local_node_id'], after['local_port'], after['node_name']))
        document = json.loads(self.fixture.path.read_text())
        outbound = next(item for item in document['outbounds'] if item['tag'] == after['singbox']['outbound_tag'])
        self.assertEqual(outbound['tls']['server_name'], 'www.tencentcloud.com')
        self.assertEqual(parse_node_link(self.fixture.node(after['remote_node_id'])['Link']).server_fingerprint,
                         parse_node_link(changed).server_fingerprint)

    def test_same_server_journals_cover_every_managed_alias(self):
        second, _ = self.fixture.add('alias', node_fixtures.VLESS.replace('example.invalid', 'alias.example'))
        self.registry = self.fixture.registry()
        self.registry.update(second, server=copy.deepcopy(self.registry.records[self.identity]['server']),
                             ssh=copy.deepcopy(self.registry.records[self.identity]['ssh']))
        self.manager = updates.ConfigUpdates(self.registry, self.call)
        self.row['identities'].append(second)
        self.fail_sync = True
        with self.assertRaises(DeployError):
            self.execute()
        self.assertIsNotNone(self.manager.pending(second))
        self.manager.validate_export(second, self.exported(None))

    def test_airport_sync_waits_for_fresh_subscription_and_keeps_local_disabled(self):
        self.registry.update(self.identity, airport_id=17, remote_node_id=None, local_node_id=None, singbox=None)
        client = Mock(url=self.registry.records[self.identity]['sublink_url'])
        client.remote_nodes.return_value = [{'Link': self.after}]
        exported = dict(fixtures.NODE, INSTALLATION_ID=self.identity, VLESS_URI=self.after)
        with patch.dict('sys.modules', {'deploy': fixtures.deploy}), \
                patch.object(fixtures.deploy, 'SublinkPro', return_value=client) as constructor, \
                patch('deploy_relay.RemoteRelayManager') as relay, \
                patch('deploy_relay.sync_dependents'), patch.object(updates, 'SingBox') as box:
            self.manager.sync_local(self.identity, exported)
        constructor.assert_called_once_with(self.fixture.config, create_local_node=False)
        box.assert_not_called()
        relay.return_value.refresh_source.assert_called_once_with(self.identity)
        self.assertFalse(client.sync.call_args.kwargs['singbox'])


class RuntimeTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.project, self.state, self.config = root / 'runtime', root / 'state', root / 'config'
        self.launcher = root / 'launcher'
        for path in (self.project, self.state, self.config):
            path.mkdir(mode=0o700)
        self.sources = {name: '# new runtime\n' for name in remote.REQUIRED}
        self.sources['VERSION'] = '0.1.0\n'
        for name in self.sources:
            path = self.project / name
            path.parent.mkdir(exist_ok=True)
            path.write_text('# old runtime\n')
            path.chmod(0o644)
        self.launcher.write_text('# old launcher\n')
        self.launcher.chmod(0o755)
        self.panel = SimpleNamespace(PROJECT=self.project, STATE=self.state, PROJECT_CONFIG=self.config,
            PanelError=DeployError, command=Mock(return_value=''), recover=Mock(),
            read_private=panel_fixtures.maintenance.read_private,
            write_private=panel_fixtures.maintenance.write_private)
        self.request = dict(project_identity='b' * 32, runtime_sources=self.sources,
                            runtime_hashes=remote.manifest(self.sources, self.panel))
        self.patch = patch.object(remote, 'LAUNCHER', self.launcher)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.shell_patch = patch.object(remote, 'shell', side_effect=self.shell)
        self.shell_patch.start()
        self.addCleanup(self.shell_patch.stop)
        self.fail_health = False
        self.target = remote.LEGACY_TARGET

    def shell(self, panel, fd, body, *args):
        if 'for key' in body:
            return 'REALITY_TARGET=' + base64.b64encode(self.target.encode()).decode()
        if self.fail_health:
            raise DeployError('health failed')
        return ''

    def test_runtime_sync_verifies_files_keeps_backup_and_is_idempotent(self):
        result = remote.sync_runtime(self.panel, 9, self.request)
        self.assertFalse(result['runtime_changed'])
        self.assertEqual((self.project / 'maintenance.sh').read_text(), '# new runtime\n')
        self.assertEqual((Path(result['backup']) / 'runtime/maintenance.sh').read_text(), '# old runtime\n')
        self.assertFalse((self.state / 'runtime-pending.json').exists())
        again = remote.sync_runtime(self.panel, 9, self.request)
        self.assertFalse(again['runtime_changed'])
        self.assertNotIn('backup', again)

    def test_health_failure_restores_runtime_and_launcher(self):
        self.fail_health = True
        with self.assertRaises(DeployError):
            remote.sync_runtime(self.panel, 9, self.request)
        self.assertEqual((self.project / 'maintenance.sh').read_text(), '# old runtime\n')
        self.assertEqual(self.launcher.read_text(), '# old launcher\n')
        self.assertFalse((self.state / 'runtime-pending.json').exists())

    def test_runtime_digest_and_path_rejections_precede_mutation(self):
        bad = copy.deepcopy(self.request)
        bad['runtime_sources']['maintenance.sh'] = '# tampered\n'
        with self.assertRaises(DeployError):
            remote.sync_runtime(self.panel, 9, bad)
        for path in ('../outside', 'lib/../../outside', '.env', 'lib/config.env'):
            with self.assertRaises(DeployError):
                remote.manifest(dict(self.sources, **{path: 'data'}), self.panel)
        self.assertEqual((self.project / 'maintenance.sh').read_text(), '# old runtime\n')

    def test_interruption_between_directory_renames_can_be_recovered(self):
        original_replace = remote.os.replace
        def interrupted(source, target):
            if str(source).startswith(str(self.project) + '.new-'):
                raise KeyboardInterrupt
            return original_replace(source, target)
        with patch.object(remote.os, 'replace', side_effect=interrupted), self.assertRaises(KeyboardInterrupt):
            remote.sync_runtime(self.panel, 9, self.request)
        self.assertEqual((self.project / 'maintenance.sh').read_text(), '# old runtime\n')
        self.assertEqual(self.launcher.read_text(), '# old launcher\n')

    def test_custom_reality_target_is_preserved(self):
        self.target = 'custom.example:443'
        result = remote.migrate(self.panel, 9, self.request)
        self.assertTrue(result['custom_target_preserved'])
        self.assertEqual(self.shell_patch.target.shell.call_count, 1)


if __name__ == '__main__':
    unittest.main()
