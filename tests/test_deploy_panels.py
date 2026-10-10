import contextlib
import gzip
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
import zipfile
from unittest.mock import Mock, patch

import test_deploy as fixtures
import test_deploy_nodes as node_fixtures
import test_deploy_parts as part_fixtures
import deploy_panels as panels
import deploy_parts
from deploy_resources import DeployError
from lib import panel_version as policy

SPEC = importlib.util.spec_from_file_location('panel_server', fixtures.ROOT / 'lib/panel_maintenance.py')
maintenance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(maintenance)
RELEASE_ASSET = maintenance.release_asset
COMMAND = maintenance.command
CORE_HEALTH = maintenance.core_health


def release(tag, **fields):
    return dict(tag_name=tag, draft=False, prerelease=False, **fields)


class VersionPolicyTests(unittest.TestCase):
    def test_latest_is_numeric_stable_same_major_and_never_downgrades(self):
        catalog = [release('v4.0.0'), release('v3.9.0'), release('v3.10.0'), release('v3.10.0-rc1'),
                   release('v3.8.0'), release('v3.8.1'),
                   release('v2.8.10'), dict(release('v3.11.0'), prerelease=True),
                   dict(release('v3.12.0'), draft=True)]
        self.assertEqual(policy.latest_release(catalog, '3.5.0')['tag_name'], 'v3.10.0')
        self.assertEqual(policy.latest_release(catalog, 'v2.6.0')['tag_name'], 'v2.8.10')
        self.assertTrue(policy.update_available('3.5.0', 'v3.8.0'))
        for target in ('v4.0.0', 'v3.4.0', 'v3.8.1', 'v3.9.0', 'dev-latest', None):
            self.assertFalse(policy.update_available('v3.9.0', target))
        self.assertIsNone(policy.latest_release(catalog, 'unknown'))
        self.assertEqual(policy.latest_release(catalog, '3.9.0')['tag_name'], 'v3.10.0')
        self.assertTrue(policy.update_available('v3.9.0', 'v3.10.0'))
        for value in ('v3.8.0', '3.10.0', 'v3.999.999'):
            self.assertTrue(policy.supported(value))
        for value in ('3.7.0', 'v2.9.0', 'v4.0.0', '3.8.0-beta', None, {}, '03.8.0'):
            self.assertFalse(policy.supported(value))

    def test_core_ceiling_is_independent_of_panel_and_uses_available_numeric_releases(self):
        catalog = [release('v26.9.30'), release('v26.9.8'), release('v26.7.11'),
                   dict(release('v26.7.28'), prerelease=True), release('v26.7.29-beta'),
                   dict(release('v26.7.27'), draft=True)]
        self.assertEqual(policy.latest_xray_release(catalog)['tag_name'], 'v26.7.28')
        self.assertFalse(policy.xray_compatible('26.9.8'))
        self.assertTrue(policy.update_available('3.8.0', 'v3.9.0'))
        with patch.object(policy, 'MAX_XRAY_VERSION', None):
            self.assertEqual(policy.latest_xray_release(catalog)['tag_name'], 'v26.9.30')

    def test_missing_compatible_core_never_falls_back_to_an_incompatible_release(self):
        self.assertIsNone(policy.latest_xray_release([release('v26.9.8'), release('v26.9.30')]))

    def test_release_pagination_does_not_stop_at_a_new_major(self):
        page = [release('v4.0.' + str(index)) for index in range(100)]
        with patch.object(policy, 'github_json', side_effect=[page, [release('v3.9.0'), release('v3.8.0')]]) as fetch:
            selected = policy.latest_release(policy.releases(), 'v3.5.0')
        self.assertEqual(selected['tag_name'], 'v3.9.0')
        self.assertIn('page=2', fetch.call_args.args[0])

    def test_core_catalog_uses_smaller_pages_and_reads_all_of_them(self):
        page = [release('v26.9.' + str(index + 8)) for index in range(30)]
        with patch.object(policy, 'github_json', side_effect=[page, [release('v26.7.28')]]) as fetch:
            selected = policy.latest_xray_release(policy.releases(policy.XRAY_REPOSITORY))
        self.assertEqual(selected['tag_name'], 'v26.7.28')
        self.assertEqual(fetch.call_args.args, ('/releases?per_page=30&page=2', policy.XRAY_REPOSITORY))

    def test_github_responses_accept_plain_and_compressed_json(self):
        payload = json.dumps([release('v3.9.0')]).encode()
        for compressed in (False, True):
            with self.subTest(compressed=compressed):
                response = io.BytesIO(gzip.compress(payload) if compressed else payload)
                response.headers = {'Content-Encoding': 'gzip'} if compressed else {}
                opener = Mock()
                opener.open.return_value = response
                with patch.object(policy.urllib.request, 'build_opener', return_value=opener):
                    self.assertEqual(policy.github_json('/releases'), [release('v3.9.0')])
                request = opener.open.call_args.args[0]
                self.assertEqual(request.get_header('Accept-encoding'), 'gzip')

    def test_compressed_response_limit_applies_after_decompression(self):
        response = io.BytesIO(gzip.compress(b' ' * (8 * 1024 * 1024 + 1)))
        response.headers = {'Content-Encoding': 'gzip'}
        opener = Mock()
        opener.open.return_value = response
        with patch.object(policy.urllib.request, 'build_opener', return_value=opener), \
                self.assertRaisesRegex(ValueError, '响应过大'):
            policy.github_json('/releases')

    def test_truncated_compressed_response_reports_a_version_query_error(self):
        response = io.BytesIO(gzip.compress(b'[]')[:-8])
        response.headers = {'Content-Encoding': 'gzip'}
        opener = Mock()
        opener.open.return_value = response
        with patch.object(policy.urllib.request, 'build_opener', return_value=opener), \
                self.assertRaisesRegex(ValueError, '压缩版本响应无效'):
            policy.github_json('/releases')

    def test_missing_api_version_reads_binary_and_unknown_is_not_reported_as_old(self):
        shared = sys.modules['okp_panel_version']
        with patch.object(shared.subprocess, 'run', return_value=SimpleNamespace(stdout=b'3.9.0\n')):
            self.assertEqual(shared.detected_version(None), 'v3.9.0')
            agent = part_fixtures.EntryAgentTests()
            agent.setUp()
            agent.version = None
            context, _ = part_fixtures.agent.discover(agent.panel, node_fixtures.VLESS)
            self.assertEqual(context['version'], 'v3.9.0')
        with patch.object(shared.subprocess, 'run', side_effect=OSError):
            with self.assertRaisesRegex(ValueError, '未判定为旧版本'):
                shared.detected_version(None)

    def test_version_error_is_structured_and_rejects_invalid_metadata(self):
        response = {'ok': False, 'code': 'panel_version_required', 'current': 'v3.5.0', 'error': '旧版本'}
        with self.assertRaises(panels.PanelUpdateRequired) as error:
            deploy_parts.agent_result(json.dumps(response))
        self.assertEqual(error.exception.current, 'v3.5.0')
        with self.assertRaisesRegex(DeployError, '有效'):
            deploy_parts.agent_result(json.dumps(dict(response, current='private-secret')))


class PanelMenuTests(unittest.TestCase):
    def setUp(self):
        self.rows = [dict(name='美国', current='v3.5.0', target='v3.9.0', eligible=True, reason='低于最低支持版本'),
                     dict(name='香港', current='v3.8.0', target='v3.9.0', eligible=True, reason='可更新'),
                     dict(name='美西', current='v3.9.0', eligible=False, reason='已是同 major 最新版'),
                     dict(name='未知', eligible=False, reason='SSH 未设置')]

    def choose(self, answers):
        with patch.dict(sys.modules, {'deploy': fixtures.deploy}), patch('builtins.input', side_effect=answers), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            result = panels.select_panels(self.rows)
        return result, output.getvalue()

    def test_all_updatable_panels_are_selected_by_default(self):
        result, output = self.choose([''])
        self.assertEqual(result, ('update', {1, 2}))
        self.assertIn('[x] 美国', output)
        self.assertIn('[-] 美西', output)
        self.assertIn('SSH 未设置', output)

    def test_multiple_toggle_clear_select_all_and_ineligible_choices(self):
        result, output = self.choose(['3', '1,2', 'u', 'a', '1', 'u'])
        self.assertEqual(result, ('update', {2}))
        self.assertIn('只能勾选', output)
        result, _ = self.choose(['n', '2', 'u'])
        self.assertEqual(result, ('update', {2}))

    def test_return_refresh_and_configure_ssh(self):
        for value, action, selected in [('0', '0', set()), ('r', 'r', set()), ('d 4', 'ssh', {4})]:
            self.assertEqual(self.choose([value])[0], (action, selected))

    def test_in_workflow_update_reuses_ssh_and_retries_once(self):
        ssh = Mock()
        information = {'current': 'v3.5.0', 'core_current': 'v26.7.11', 'updatable': True, 'reason': None}
        operation = Mock(side_effect=[panels.PanelUpdateRequired('v3.5.0'), {'finished': True}])
        context = {'panel_url': 'https://panel.example/prefix', 'api_token': 'private-token-123456789'}
        with patch.dict(sys.modules, {'deploy': fixtures.deploy}), patch.object(sys.stdin, 'isatty', return_value=True), \
                patch('builtins.input', return_value=''), patch.object(panels, 'catalog', return_value=[release('v4.0.0'), release('v3.9.0'), release('v3.8.0')]), \
                patch.object(panels, 'compatible_core', return_value='v26.7.28'), \
                patch.object(panels, 'run_helper', side_effect=[information, {'current': 'v3.9.0', 'core_current': 'v26.7.28'}]) as remote, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(panels.retry_after_update(ssh, operation, context), {'finished': True})
        self.assertEqual(operation.call_count, 2)
        self.assertEqual(remote.call_args.args, (ssh, dict(context, operation='panel-update', current='v3.5.0', target='v3.9.0',
                                                        core_current='v26.7.11', core_target='v26.7.28')))
        self.assertIn('正在检测面板版本及更新条件', output.getvalue())
        self.assertIn('正在查询 3.x 的最新稳定版及兼容 Xray', output.getvalue())
        self.assertNotIn('private-token', output.getvalue())

    def test_decline_and_major_mismatch_leave_original_operation_pending(self):
        for current, answers in [('v3.5.0', ['n']), ('v2.8.0', [])]:
            operation = Mock(side_effect=panels.PanelUpdateRequired(current))
            with patch.dict(sys.modules, {'deploy': fixtures.deploy}), patch.object(sys.stdin, 'isatty', return_value=True), \
                    patch('builtins.input', side_effect=answers), patch.object(panels, 'catalog', return_value=[release('v3.8.0'), release('v3.9.0'), release('v2.9.0')]), \
                    patch.object(panels, 'compatible_core', return_value='v26.7.28'), \
                    patch.object(panels, 'run_helper', return_value={'current': current, 'updatable': True}) as remote, \
                    contextlib.redirect_stdout(io.StringIO()), self.assertRaises(panels.PanelUpdateRequired):
                panels.retry_after_update(Mock(), operation)
            self.assertEqual(operation.call_count, 1)
            self.assertEqual(remote.call_count, 1)

    def test_newer_panels_remain_supported_and_have_no_update_ceiling(self):
        self.assertTrue(policy.supported('v3.9.0'))
        self.assertEqual(panels.describe('v3.9.0', release('v3.10.0')), '可更新')
        self.assertEqual(panels.describe('v3.9.0', release('v3.9.0')), '已是同 major 最新版')

    def test_preflight_offers_core_only_repair_on_a_supported_panel(self):
        ssh = Mock()
        information = {'current': 'v3.9.0', 'core_current': 'v26.9.30', 'updatable': True}
        with patch.dict(sys.modules, {'deploy': fixtures.deploy}), patch.object(sys.stdin, 'isatty', return_value=True), \
                patch('builtins.input', return_value=''), patch.object(panels, 'catalog', return_value=[release('v3.9.0')]), \
                patch.object(panels, 'compatible_core', return_value='v26.7.28'), \
                patch.object(panels, 'run_helper', side_effect=[information, {'current': 'v3.9.0', 'core_current': 'v26.7.28'}]) as remote, \
                contextlib.redirect_stdout(io.StringIO()):
            panels.preflight(ssh, information)
        self.assertEqual(remote.call_args.args[1]['target'], 'v3.9.0')
        self.assertEqual(remote.call_args.args[1]['core_target'], 'v26.7.28')

    def test_helper_sources_work_under_isolated_python_without_files_installed(self):
        def run(script, *, data, timeout):
            command = shlex.split(script)
            command[command.index('python3')] = sys.executable
            command[-1] = 'import os; os.getuid=lambda:1000; ' + command[-1]
            result = subprocess.run(command, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            return result.stdout
        ssh = Mock()
        ssh.run.side_effect = run
        with self.assertRaisesRegex(DeployError, 'root SSH'):
            panels.run_helper(ssh, {'operation': 'panel-info'})


class PanelUpdateServerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.install, self.database, self.state = self.root / 'x-ui', self.root / 'database', self.root / 'state'
        self.install.mkdir()
        (self.install / 'bin').mkdir()
        (self.install / 'x-ui').write_text('v3.5.0')
        (self.install / 'bin/xray-linux-amd64').write_text('Xray 26.7.11')
        (self.install / 'bin/custom.json').write_text('keep-custom')
        (self.install / 'bin/config.json').write_text('original-config')
        self.database.mkdir()
        with contextlib.closing(sqlite3.connect(self.database / 'x-ui.db')) as connection, connection:
            connection.execute('CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)')
            connection.executemany('INSERT INTO settings VALUES (?,?)', [('webBasePath', '/prefix/'), ('apiToken', 'private-token')])
            connection.execute('CREATE TABLE clients (uuid TEXT, port INTEGER)')
            connection.execute('INSERT INTO clients VALUES (?,?)', ('original-uuid', 443))
        self.original_database = (self.database / 'x-ui.db').read_bytes()
        self.events, self.fail_health, self.migrate = [], False, False
        self.project = self.root / 'project-runtime'
        self.project.mkdir()
        self.project_config, self.project_result = self.root / 'project-config', self.root / 'result.txt'
        self.project_lock = self.root / 'run/one-key-proxy/operation.lock'
        for patcher in (patch.object(maintenance, 'INSTALL', self.install), patch.object(maintenance, 'DATABASE', self.database),
                        patch.object(maintenance, 'STATE', self.state), patch.object(maintenance, 'PROJECT', self.project),
                        patch.object(maintenance, 'PROJECT_CONFIG', self.project_config), patch.object(maintenance, 'PROJECT_RESULT', self.project_result),
                        patch.object(maintenance, 'PROJECT_LOCK', self.project_lock), patch.object(maintenance, 'command', side_effect=self.command),
                        patch.object(maintenance.platform, 'machine', return_value='x86_64'),
                        patch.object(maintenance, 'healthy', side_effect=self.healthy),
                        patch.object(maintenance, 'core_health', side_effect=self.core_health),
                        patch.object(maintenance, 'releases', return_value=[release('v26.9.30'), dict(release('v26.7.28'), prerelease=True)]),
                        patch.object(maintenance, 'github_json', return_value=self.core_release()),
                        patch.object(maintenance, 'release_asset', return_value=('https://github.com/release', 'a' * 64, 'b' * 40, 'amd64')),
                        patch.object(maintenance, 'download', side_effect=self.download)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def command(self, arguments, **kwargs):
        self.events.append(arguments)
        if arguments[-1] == '-v':
            return Path(arguments[0]).read_text()
        if arguments[-1] == 'version':
            return Path(arguments[0]).read_text()
        if arguments[0] == 'systemctl':
            if '--property=ExecStart' in arguments:
                return '{ path=' + str(self.install / 'x-ui') + ' ; argv[]=' + str(self.install / 'x-ui') + ' ; }'
            return ''
        if arguments[-1] == 'migrate' and self.migrate:
            with contextlib.closing(sqlite3.connect(self.database / 'x-ui.db')) as connection, connection:
                connection.execute("INSERT INTO settings VALUES ('new-schema', 'ok')")
        return ''

    def healthy(self, expected):
        self.assertEqual((self.install / 'x-ui').read_text(), expected)
        if expected == 'v3.9.0' and self.fail_health:
            raise maintenance.PanelError('health failure')

    def core_health(self, expected, request, context):
        self.assertEqual(maintenance.core_version(), expected)

    def core_release(self, name='Xray-linux-64.zip'):
        return dict(release('v26.7.28', assets=[dict(name=name, digest='sha256:' + 'c' * 64,
                    browser_download_url='https://github.com/XTLS/Xray-core/releases/download/v26.7.28/' + name)]), prerelease=True)

    def download(self, url, path, expected):
        if url.endswith('.zip'):
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('xray', b'Xray 26.7.28')
            return
        with tarfile.open(path, 'w:gz') as archive:
            for name, data in [('x-ui/x-ui', b'v3.9.0'), ('x-ui/bin/xray-linux-amd64', b'Xray 26.9.30'),
                               ('x-ui/bin/config.json', b'upstream-default')]:
                member = tarfile.TarInfo(name)
                member.mode, member.size = 0o755, len(data)
                archive.addfile(member, io.BytesIO(data))

    def request(self):
        return {'current': 'v3.5.0', 'target': 'v3.9.0'}

    def assert_original(self):
        self.assertEqual((self.install / 'x-ui').read_text(), 'v3.5.0')
        self.assertEqual((self.install / 'bin/xray-linux-amd64').read_text(), 'Xray 26.7.11')
        self.assertEqual((self.database / 'x-ui.db').read_bytes(), self.original_database)
        self.assertFalse((self.state / 'pending.json').exists())

    def test_update_preserves_settings_clients_custom_files_and_private_backup(self):
        self.migrate = True
        result = maintenance.update(self.request())
        self.assertEqual(result['current'], 'v3.9.0')
        self.assertEqual(result['core_current'], 'v26.7.28')
        self.assertEqual((self.install / 'bin/custom.json').read_text(), 'keep-custom')
        self.assertEqual((self.install / 'bin/config.json').read_text(), 'original-config')
        self.assertEqual((self.install / 'bin/xray-linux-amd64').read_text(), 'Xray 26.7.28')
        with contextlib.closing(sqlite3.connect(self.database / 'x-ui.db')) as connection:
            self.assertEqual(connection.execute('SELECT * FROM clients').fetchall(), [('original-uuid', 443)])
            values = dict(connection.execute('SELECT * FROM settings'))
            self.assertEqual(values['apiToken'], 'private-token')
            self.assertEqual(values['webBasePath'], '/prefix/')
        backup = Path(result['backup'])
        self.assertEqual(backup.stat().st_mode & 0o777, 0o700)
        self.assertEqual((backup / 'database/x-ui.db').read_bytes(), self.original_database)
        self.assertFalse((self.state / 'pending.json').exists())
        self.assertLess(self.events.index(['systemctl', 'stop', 'x-ui.service']), self.events.index([str(self.install / 'x-ui'), 'migrate']))

    def test_installation_accepts_existing_archive_ownership_modes_and_hardlinks(self):
        self.install.chmod(0o775)
        (self.install / 'bin').chmod(0o775)
        (self.install / 'bin/custom.json').chmod(0o664)
        (self.database / 'x-ui.db').chmod(0o664)
        os.link(self.install / 'bin/custom.json', self.install / 'bin/custom-copy.json')
        with patch.object(maintenance.os, 'getuid', return_value=-1):
            information = maintenance.info()
        self.assertTrue(information['updatable'], information['reason'])
        self.assertEqual(information['current'], 'v3.5.0')
        self.assertEqual(self.install.stat().st_mode & 0o777, 0o775)
        self.assertEqual((self.install / 'bin/custom.json').stat().st_mode & 0o777, 0o664)
        self.assertEqual((self.install / 'bin/custom.json').stat().st_nlink, 2)
        self.assert_original()

    def test_update_accepts_group_writable_existing_installation(self):
        self.install.chmod(0o775)
        (self.install / 'bin').chmod(0o775)
        (self.install / 'bin/custom.json').chmod(0o664)
        (self.database / 'x-ui.db').chmod(0o664)
        result = maintenance.update(self.request())
        self.assertEqual(result['current'], 'v3.9.0')
        self.assertEqual((self.install / 'bin/custom.json').read_text(), 'keep-custom')
        self.assertEqual((self.install / 'bin/custom.json').stat().st_mode & 0o777, 0o664)
        self.assertEqual((self.database / 'x-ui.db').read_bytes(), self.original_database)

    def test_core_restore_keeps_panel_database_and_preserves_replaced_core(self):
        identity = 'c' * 32
        self.state.mkdir(mode=0o700)
        backup = self.state / ('backup-' + identity)
        backup.mkdir(mode=0o700)
        maintenance.shutil.copytree(self.install, backup / 'installation')
        binary = self.install / 'bin/xray-linux-amd64'
        binary.write_text('Xray 26.9.30')
        with patch.object(maintenance.platform, 'machine', return_value='x86_64'):
            result = maintenance.restore_core({'backup_id': identity, 'current_core': '26.9.30'})
        self.assertEqual(result['current_core'], '26.7.11')
        self.assertEqual(result['panel_version'], 'v3.5.0')
        self.assertEqual(binary.read_text(), 'Xray 26.7.11')
        saved = Path(result['backup']) / binary.name
        self.assertEqual(saved.read_text(), 'Xray 26.9.30')
        self.assertEqual(saved.stat().st_mode & 0o777, 0o600)
        self.assert_original()

    def test_failed_core_restore_puts_previous_core_back_without_touching_database(self):
        identity = 'c' * 32
        self.state.mkdir(mode=0o700)
        backup = self.state / ('backup-' + identity)
        backup.mkdir(mode=0o700)
        maintenance.shutil.copytree(self.install, backup / 'installation')
        binary = self.install / 'bin/xray-linux-amd64'
        binary.write_text('Xray 26.9.30')
        with patch.object(maintenance.platform, 'machine', return_value='x86_64'), \
                patch.object(maintenance, 'panel_health', side_effect=maintenance.PanelError('health failure')), \
                self.assertRaisesRegex(maintenance.PanelError, '已回退'):
            maintenance.restore_core({'backup_id': identity, 'current_core': '26.9.30'})
        self.assertEqual(binary.read_text(), 'Xray 26.9.30')
        self.assertEqual((self.install / 'x-ui').read_text(), 'v3.5.0')
        self.assertEqual((self.database / 'x-ui.db').read_bytes(), self.original_database)

    def test_nested_link_is_reported_before_any_update_changes(self):
        link = self.install / 'bin/linked-database'
        link.symlink_to(self.database / 'x-ui.db')
        with self.assertRaisesRegex(maintenance.PanelError, '链接或特殊文件') as error:
            maintenance.update(self.request())
        self.assertIn(str(link), str(error.exception))
        self.assertFalse(any(arguments[:2] == ['systemctl', 'stop'] for arguments in self.events))
        self.assert_original()

    def test_updater_private_directory_still_protects_backups_and_progress(self):
        self.state.mkdir(mode=0o777)
        self.state.chmod(0o777)
        with self.assertRaises(maintenance.PanelError):
            maintenance.update(self.request())
        self.assertFalse(any(arguments[:2] == ['systemctl', 'stop'] for arguments in self.events))
        self.assert_original()

    def test_startup_failure_restores_original_program_and_database(self):
        self.fail_health, self.migrate = True, True
        with self.assertRaisesRegex(maintenance.PanelError, '已恢复原版本'):
            maintenance.update(self.request())
        self.assert_original()

    def test_partial_backup_is_never_used_to_replace_live_database(self):
        original = maintenance.shutil.copytree
        def interrupted(source, destination, **kwargs):
            if source == self.database:
                Path(destination).mkdir()
                (Path(destination) / 'x-ui.db').write_bytes(b'incomplete backup')
                raise KeyboardInterrupt
            return original(source, destination, **kwargs)
        with patch.object(maintenance.shutil, 'copytree', side_effect=interrupted), \
                self.assertRaisesRegex(maintenance.PanelError, '已恢复原版本'):
            maintenance.update(self.request())
        self.assert_original()

    def test_cross_major_downgrade_and_changed_current_fail_before_stopping_service(self):
        for request in (dict(self.request(), target='v4.0.0'), dict(self.request(), target='v3.4.0'),
                        dict(self.request(), current='v3.6.0')):
            with self.assertRaises(maintenance.PanelError):
                maintenance.update(request)
        self.assertFalse(any(arguments[:2] == ['systemctl', 'stop'] for arguments in self.events))
        self.assert_original()

    def test_server_refuses_incompatible_core_before_download_or_service_changes(self):
        for target in ('v26.9.8', 'v26.9.30', 'dev-latest'):
            with self.subTest(target=target), self.assertRaisesRegex(maintenance.PanelError, 'Xray 版本超出兼容范围'):
                maintenance.update(dict(self.request(), core_target=target))
        maintenance.release_asset.assert_not_called()
        maintenance.download.assert_not_called()
        self.assertFalse(any(arguments[:2] == ['systemctl', 'stop'] for arguments in self.events))
        self.assert_original()

    def test_core_only_adjustment_preserves_panel_and_database_without_migration(self):
        (self.install / 'x-ui').write_text('v3.9.0')
        (self.install / 'bin/xray-linux-amd64').write_text('Xray 26.9.30')
        result = maintenance.update({'current': 'v3.9.0', 'target': 'v3.9.0', 'core_current': 'v26.9.30', 'core_target': 'v26.7.28'})
        self.assertEqual(result['current'], 'v3.9.0')
        self.assertEqual(result['core_current'], 'v26.7.28')
        self.assertEqual((self.install / 'x-ui').read_text(), 'v3.9.0')
        self.assertEqual((self.database / 'x-ui.db').read_bytes(), self.original_database)
        self.assertFalse(any(arguments[-1] == 'migrate' for arguments in self.events))
        self.assertEqual((Path(result['backup']) / 'installation/bin/xray-linux-amd64').read_text(), 'Xray 26.9.30')

    def test_failed_core_health_restores_panel_core_and_database(self):
        with patch.object(maintenance, 'core_health', side_effect=maintenance.PanelError('core not running')), \
                self.assertRaisesRegex(maintenance.PanelError, '已恢复原版本'):
            maintenance.update(self.request())
        self.assert_original()

    def test_incompatible_existing_config_is_refused_before_stopping_service(self):
        def check(arguments, **kwargs):
            if '-test' in arguments:
                raise maintenance.PanelError('configuration unsupported')
            return self.command(arguments, **kwargs)
        with patch.object(maintenance, 'command', side_effect=check), \
                self.assertRaisesRegex(maintenance.PanelError, 'configuration unsupported'):
            maintenance.update(self.request())
        self.assertFalse(any(arguments[:2] == ['systemctl', 'stop'] for arguments in self.events))
        self.assert_original()

    def test_changed_core_is_refused_before_service_changes(self):
        with self.assertRaisesRegex(maintenance.PanelError, 'Xray 版本已发生变化'):
            maintenance.update(dict(self.request(), core_current='v26.9.30'))
        maintenance.download.assert_not_called()
        self.assert_original()

    def test_download_or_core_binary_mismatch_never_stops_the_service(self):
        for failure in ('download', 'version'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory(dir=self.root) as directory:
                def wrong_core(url, path, expected):
                    with zipfile.ZipFile(path, 'w') as archive:
                        archive.writestr('xray', 'Xray 26.9.30')
                with patch.object(maintenance, 'download', side_effect=maintenance.PanelError('download failed') if failure == 'download' else wrong_core), \
                        self.assertRaises(maintenance.PanelError):
                    maintenance.update(self.request())
        self.assertFalse(any(arguments[:2] == ['systemctl', 'stop'] for arguments in self.events))
        self.assert_original()

    def test_core_assets_require_official_url_digest_and_matching_architecture(self):
        for machine, name in [('x86_64', '64'), ('i686', '32'), ('aarch64', 'arm64-v8a'), ('armv7l', 'arm32-v7a'), ('armv6l', 'arm32-v6'), ('s390x', 's390x')]:
            with self.subTest(machine=machine), tempfile.TemporaryDirectory(dir=self.root) as directory, \
                    patch.object(maintenance.platform, 'machine', return_value=machine), \
                    patch.object(maintenance, 'github_json', return_value=self.core_release('Xray-linux-' + name + '.zip')):
                _, target = maintenance.prepare_core(Path(directory))
                self.assertEqual(target, 'v26.7.28')
        for field, value in [('digest', None), ('browser_download_url', 'https://attacker.invalid/core.zip')]:
            metadata = self.core_release()
            metadata['assets'][0][field] = value
            with tempfile.TemporaryDirectory(dir=self.root) as directory, patch.object(maintenance, 'github_json', return_value=metadata), \
                    self.assertRaisesRegex(maintenance.PanelError, '资产地址或 SHA-256'):
                maintenance.prepare_core(Path(directory))

    def test_core_health_requires_the_selected_running_api_version(self):
        statuses = [{'xray': {'version': '26.9.30', 'state': 'running'}},
                    {'xray': {'version': '26.7.28', 'state': 'running'}}]
        (self.install / 'bin/xray-linux-amd64').write_text('Xray 26.7.28')
        with patch.object(maintenance, 'panel_status', side_effect=statuses) as status, patch.object(maintenance.time, 'sleep'):
            CORE_HEALTH('v26.7.28', {}, {'panel_url': 'https://panel.example'})
        self.assertEqual(status.call_count, 2)

    def test_recovery_after_interruption_between_directory_renames(self):
        original_replace = maintenance.os.replace
        def interrupt_replace(source, destination):
            if str(source).startswith(str(self.install) + '.okp-new-'):
                raise SystemExit('simulated interruption')
            return original_replace(source, destination)
        with patch.object(maintenance.os, 'replace', side_effect=interrupt_replace), \
                patch.object(maintenance, 'restore', side_effect=maintenance.PanelError('interrupted cleanup')), \
                self.assertRaisesRegex(maintenance.PanelError, '自动恢复未完成'):
            maintenance.update(self.request())
        self.assertFalse(self.install.exists())
        self.assertTrue(maintenance.info()['pending'])
        with maintenance.locked():
            maintenance.recover()
        self.assert_original()

    def test_project_state_and_result_restore_when_final_validation_fails(self):
        (self.project / 'maintenance.sh').write_text('trusted')
        self.project_config.mkdir()
        (self.project_config / 'state.env').write_text('old-project-state')
        self.project_result.write_text('old-result')
        def project_state(fd, phase, *args):
            self.assertIsInstance(fd, int)
            if phase == 'finish':
                (self.project_config / 'state.env').write_text('new-project-state')
                self.project_result.write_text('new-result')
                raise maintenance.PanelError('project final validation failed')
        with patch.object(maintenance, 'project_state', side_effect=project_state), \
                self.assertRaisesRegex(maintenance.PanelError, '已恢复原版本'):
            maintenance.update(self.request())
        self.assert_original()
        self.assertEqual((self.project_config / 'state.env').read_text(), 'old-project-state')
        self.assertEqual(self.project_result.read_text(), 'old-result')

    def test_asset_archive_rejects_traversal_links_and_duplicates(self):
        for names in (['../x-ui/x-ui'], ['/x-ui/x-ui'], ['x-ui/x-ui', 'x-ui/x-ui']):
            with tempfile.TemporaryDirectory(dir=self.root) as directory:
                root = Path(directory)
                path = root / 'unsafe.tar.gz'
                with tarfile.open(path, 'w:gz') as archive:
                    for name in names:
                        member = tarfile.TarInfo(name)
                        member.size = 1
                        archive.addfile(member, io.BytesIO(b'x'))
                with self.assertRaises(maintenance.PanelError):
                    maintenance.unpack(path, root / 'output')
        path = self.root / 'link.tar.gz'
        with tarfile.open(path, 'w:gz') as archive:
            member = tarfile.TarInfo('x-ui/link')
            member.type, member.linkname = tarfile.SYMTYPE, '/etc/x-ui'
            archive.addfile(member)
        with self.assertRaises(maintenance.PanelError):
            maintenance.unpack(path, self.root / 'output')

    def test_timed_out_maintenance_command_is_terminated_and_reaped(self):
        path = self.root / 'child.pid'
        script = 'import os,time; from pathlib import Path; Path(' + repr(str(path)) + ').write_text(str(os.getpid())); time.sleep(60)'
        with self.assertRaisesRegex(maintenance.PanelError, '超时'):
            COMMAND([sys.executable, '-c', script], timeout=.3)
        pid = int(path.read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_external_database_is_refused_without_changes(self):
        with self.assertRaises(maintenance.PanelError):
            maintenance.database_environment([('XUI_DB_TYPE', 'postgres')])
        maintenance.database_environment([('XUI_DB_TYPE', 'sqlite'), ('XUI_DB_FOLDER', str(self.database))])
        self.assert_original()

    def test_api_version_can_be_detected_when_installation_cannot_be_auto_updated(self):
        with patch.object(maintenance, 'panel_status', return_value={'panelVersion': '3.9.0'}), \
                patch.object(maintenance, 'binary_version', side_effect=maintenance.PanelError('非标准安装')):
            information = maintenance.info({}, {'panel_url': 'https://panel.example', 'api_token': 'private-token'})
        self.assertEqual(information['current'], 'v3.9.0')
        self.assertFalse(information['updatable'])
        self.assertEqual(information['reason'], '非标准安装')

    def test_release_identity_digest_and_download_url_are_checked(self):
        asset = dict(name='x-ui-linux-amd64.tar.gz', digest='sha256:' + 'a' * 64,
                     browser_download_url='https://github.com/MHSanaei/3x-ui/releases/download/v3.9.0/x-ui-linux-amd64.tar.gz')
        with patch.object(maintenance.platform, 'machine', return_value='x86_64'), \
                patch.object(maintenance, 'github_json', side_effect=[release('v3.9.0', assets=[asset]), {'sha': 'b' * 40}]):
            self.assertEqual(RELEASE_ASSET('v3.9.0')[1], 'a' * 64)
        for changed in (dict(asset, digest=''), dict(asset, browser_download_url='https://attacker.invalid/release')):
            with patch.object(maintenance.platform, 'machine', return_value='x86_64'), \
                    patch.object(maintenance, 'github_json', return_value=release('v3.9.0', assets=[changed])), \
                    self.assertRaises(maintenance.PanelError):
                RELEASE_ASSET('v3.9.0')


class PanelWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.fixture = node_fixtures.NodeWorkflowTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)

    def test_latest_panel_is_selectable_for_outdated_or_incompatible_core_only(self):
        identity, _ = self.fixture.add('美国', node_fixtures.VLESS)
        registry = self.fixture.registry()
        registry.update(identity, ssh={'target': 'entry.example', 'port': 22, 'identity': None, 'password': False})
        for current, target, eligible in [('v26.9.30', 'v26.7.28', True), ('v26.7.11', 'v26.7.28', True),
                                         ('v26.7.28', 'v26.7.28', False), ('v26.9.30', None, False)]:
            with self.subTest(current=current, target=target), patch.object(panels, 'run_helper', return_value={
                    'current': 'v3.9.0', 'core_current': current, 'updatable': True, 'panel_id': 'shared-panel'}), \
                    contextlib.redirect_stdout(io.StringIO()):
                rows = panels.scan(registry, Mock(), [release('v3.9.0')], target)
            self.assertEqual(rows[0]['eligible'], eligible)
            self.assertEqual(rows[0]['target'], 'v3.9.0')
            self.assertEqual(rows[0]['core_target'], target)

    def test_main_menu_updates_one_shared_panel_and_preserves_other_progress(self):
        first, _ = self.fixture.add('美国', node_fixtures.VLESS)
        second, _ = self.fixture.add('美国备用', node_fixtures.VLESS.replace('00000000-0000-4000-8000-000000000001',
                                                                      '00000000-0000-4000-8000-000000000002'))
        registry = self.fixture.registry()
        binding = {'target': 'entry.example', 'port': 22, 'identity': None, 'password': False}
        for identity in (first, second):
            registry.update(identity, ssh=binding)
        registry.register('c' * 32, 'root@other', fixtures.deploy.ROOT / '.env', self.fixture.client.url, '美西')
        registry.update('c' * 32, status='active')
        before = registry.path.read_bytes()
        state = fixtures.deploy.ResumeState()
        with state.locked():
            state.start('add', fixtures.deploy.ROOT / '.env')
            state.capture(target='root@unrelated')
        pending = state.path.read_bytes()
        def remote(ssh, request):
            if request['operation'] == 'panel-info':
                return {'current': 'v3.5.0', 'core_current': 'v26.7.11', 'updatable': True, 'reason': None, 'panel_id': 'shared-panel'}
            self.assertEqual(request['operation'], 'panel-update')
            self.assertEqual(request['target'], 'v3.9.0')
            self.assertEqual(request['core_target'], 'v26.7.28')
            return {'current': 'v3.9.0', 'core_current': 'v26.7.28'}
        with patch.dict(sys.modules, {'deploy': fixtures.deploy}), patch.object(sys.stdin, 'isatty', return_value=True), \
                patch.object(fixtures.deploy, 'SSH') as ssh, patch('builtins.input', side_effect=['5', '', '', '0']), \
                patch.object(panels, 'catalog', return_value=[release('v3.8.0'), release('v3.9.0'), release('v4.0.0')]), \
                patch.object(panels, 'compatible_core', return_value='v26.7.28'), \
                patch.object(panels, 'run_helper', side_effect=remote) as call, \
                contextlib.redirect_stdout(io.StringIO()) as output, contextlib.redirect_stderr(io.StringIO()):
            fixtures.deploy.main([])
        self.assertEqual([args[0][1]['operation'] for args in call.call_args_list], ['panel-info', 'panel-info', 'panel-update'])
        ssh.return_value.connect.assert_called_once()
        ssh.return_value.close.assert_called_once()
        self.assertIn('[x] 美国 / 美国备用', output.getvalue())
        self.assertIn('美西  3x-ui 未检测', output.getvalue())
        self.assertEqual(registry.path.read_bytes(), before)
        self.assertEqual(state.path.read_bytes(), pending)


if __name__ == '__main__':
    unittest.main()
