import contextlib
import copy
import fcntl
import io
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import tempfile
import termios
import time
import unittest
from unittest.mock import Mock, patch

import test_deploy as fixtures
import test_deploy_nodes as node_fixtures
from deploy_credentials import Credentials
from deploy_links import parse_node_link
from deploy_resources import DeployError
import deploy_panels
import deploy_ssh_askpass
from lib.entry_management import EntryError


class CredentialTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.state = fixtures.deploy.ResumeState(self.root / '.deploy-state')
        self.vault = Credentials(self.state)
        for patcher in (patch.dict(sys.modules, {'deploy': fixtures.deploy}), patch.object(fixtures.deploy, 'ROOT', self.root)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_password_is_private_preserves_spaces_and_is_bound_to_user_host_port(self):
        password = '  private-password  '
        self.vault.save_ssh('entry.example', None, password)
        self.assertEqual(self.vault.ssh('root@entry.example', 22), password)
        self.assertIsNone(self.vault.ssh('operator@entry.example', 22))
        self.assertIsNone(self.vault.ssh('entry.example', 2222))
        self.assertEqual(self.state.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.vault.ssh_path('entry.example', None).stat().st_mode & 0o777, 0o600)

    def test_noninteractive_login_reuses_password_without_prompt_or_environment_secret(self):
        self.vault.save_ssh('entry.example', 22, 'private-password')
        with patch.object(fixtures.deploy.sys.stdin, 'isatty', return_value=False), \
                patch.object(fixtures.deploy.getpass, 'getpass') as prompt, \
                patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stderr=b'')) as run:
            fixtures.deploy.SSH('entry.example', '/tmp/control', password_login=True).connect()
        prompt.assert_not_called()
        self.assertNotIn('private-password', repr(run.call_args))
        self.assertEqual(run.call_args.kwargs['env']['SSH_ASKPASS_REQUIRE'], 'force')

    def test_new_password_login_requires_hidden_terminal_input(self):
        with patch.object(fixtures.deploy.sys.stdin, 'isatty', return_value=False), \
                patch.object(subprocess, 'run') as run, self.assertRaisesRegex(DeployError, '首次密码登录'):
            fixtures.deploy.SSH('entry.example', '/tmp/control', password_login=True).connect()
        run.assert_not_called()

    def test_rejected_password_is_cleared_but_network_failures_preserve_it(self):
        for message, expected in ((b'Permission denied (password).', None), (b'Connection timed out', 'private-password')):
            self.vault.save_ssh('entry.example', 22, 'private-password')
            with patch.object(fixtures.deploy.sys.stdin, 'isatty', return_value=False), \
                    patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 255, stderr=message)), \
                    self.assertRaises(DeployError):
                fixtures.deploy.SSH('entry.example', '/tmp/control', password_login=True).connect()
            self.assertEqual(self.vault.ssh('entry.example', 22), expected)

    def test_askpass_reads_private_credentials_without_secret_arguments(self):
        self.vault.save_ssh('entry.example', 22, 'private-password')
        environment = dict(os.environ, OKP_SSH_TARGET='entry.example', OKP_SSH_PORT='22',
                           OKP_SSH_CREDENTIAL_DIR=str(self.state.directory))
        result = subprocess.run([sys.executable, str(fixtures.ROOT / 'deploy_ssh_askpass.py'), "root@entry.example's password: "],
                                env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'private-password\n')
        self.assertEqual(result.stderr, b'')

    def test_saved_password_is_not_used_for_password_changes_or_one_time_challenges(self):
        for prompt in ('New password: ', 'Retype new password: ', 'Verification code: '):
            with self.subTest(prompt=prompt), patch.object(sys, 'argv', ['askpass', prompt]), \
                    patch.object(deploy_ssh_askpass, 'Credentials') as vault, \
                    patch('builtins.open'), patch.object(deploy_ssh_askpass.getpass, 'getpass', return_value='user-input') as input_, \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(deploy_ssh_askpass.main(), 0)
                vault.assert_not_called()
                input_.assert_called_once()

    def test_first_host_key_confirmation_uses_real_controlling_terminal(self):
        master, slave = pty.openpty()
        self.addCleanup(lambda: os.close(master) if master is not None else None)
        prompt = 'Are you sure you want to continue connecting (yes/no/[fingerprint])? '

        def prepare_terminal():
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
            signal.signal(signal.SIGHUP, signal.SIG_IGN)

        try:
            child = subprocess.Popen([sys.executable, str(fixtures.ROOT / 'deploy_ssh_askpass.py'), prompt],
                                     stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     start_new_session=True,
                                     preexec_fn=prepare_terminal)
        finally:
            os.close(slave)
        try:
            output = b''
            deadline = time.monotonic() + 10
            while prompt.encode() not in output and time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try:
                        output += os.read(master, 4096)
                    except OSError:
                        break
                if child.poll() is not None:
                    break
            self.assertIn(prompt.encode(), output)
            os.write(master, b'yes\n')
            ready, _, _ = select.select([child.stdout], [], [], 10)
            self.assertTrue(ready, 'Host-key confirmation did not return an answer.')
            answer = child.stdout.readline()
            # macOS can defer a controlling-session leader's exit until the PTY closes.
            os.close(master)
            master = None
            remaining, diagnostic = child.communicate(timeout=10)
            self.assertEqual(child.returncode, 0, diagnostic.decode())
            self.assertEqual(answer + remaining, b'yes\n')
            self.assertEqual(diagnostic, b'')
        finally:
            if master is not None:
                os.close(master)
                master = None
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=10)

    def test_connect_failures_classify_transport_without_echoing_stderr_or_clearing_password(self):
        self.vault.save_ssh('entry.example', 22, 'private-password')
        failures = ((b'Host key verification failed', '主机指纹校验失败'),
                    (b'REMOTE HOST IDENTIFICATION HAS CHANGED\nHost key verification failed', '主机指纹发生变化'),
                    (b'Connection refused', '拒绝连接'),
                    (b'Connection timed out', '连接超时'),
                    (b'Could not resolve hostname', '无法解析'),
                    (b'No route to host', '网络路由'))
        for message, expected in failures:
            with self.subTest(message=message), \
                    patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 255, stderr=message + b' private-password')), \
                    self.assertRaises(DeployError) as error:
                fixtures.deploy.SSH('entry.example', '/tmp/control', password_login=True).connect()
            self.assertIn(expected, str(error.exception))
            self.assertNotIn('private-password', str(error.exception))
            self.assertEqual(self.vault.ssh('entry.example', 22), 'private-password')

    def test_public_or_linked_credentials_are_rejected(self):
        self.vault.save_ssh('entry.example', 22, 'private-password')
        path = self.vault.ssh_path('entry.example', 22)
        path.chmod(0o644)
        with self.assertRaises(DeployError):
            self.vault.ssh('entry.example', 22)
        path.chmod(0o600)
        os.link(path, self.root / 'hardlink')
        with self.assertRaises(DeployError):
            self.vault.ssh('entry.example', 22)

    def test_panel_token_survives_completion_and_is_bound_to_server_identity(self):
        identity, server = 'a' * 32, {'identity': 'b' * 32}
        authentication = {'panel_url': 'https://panel.example/prefix/', 'api_token': 'private-api-token-123456789'}
        self.vault.save_panel(identity, server, authentication)
        self.assertEqual(self.vault.panel(identity, server)['api_token'], authentication['api_token'])
        self.assertEqual(self.vault.panel_path(identity).stat().st_mode & 0o777, 0o600)
        with self.assertRaisesRegex(DeployError, '绑定不一致'):
            self.vault.panel(identity, {'identity': 'c' * 32})
        self.vault.forget_panel(identity)
        self.assertIsNone(self.vault.panel(identity, server))


class PanelAPITests(unittest.TestCase):
    def setUp(self):
        self.link = parse_node_link(node_fixtures.VLESS)
        self.inbound = {'id': 7, 'tag': 'entry', 'enable': True, 'protocol': 'vless',
                        'settings': {'clients': [{'id': self.link.auth['uuid'], 'enable': True}]},
                        'streamSettings': {'realitySettings': {'minClientVer': '26.3.27', 'maxClientVer': '',
                            'serverNames': ['www.cloudflare.com'], 'shortIds': ['abcd'], 'settings': {'publicKey': 'A' * 43}}}}

    def test_read_only_diagnosis_reports_version_limits_and_runtime_without_credentials(self):
        panel = Mock(side_effect=[{'panelVersion': '3.9.0', 'xray': {'state': 'running', 'version': '26.9.30', 'errorMsg': ''}},
                                  [self.inbound], {'inbounds': [self.inbound]}])
        report = deploy_panels.api_diagnosis(panel, self.link)
        self.assertEqual(report['min_client_version'], '26.3.27')
        self.assertEqual(report['runtime_min_client_version'], '26.3.27')
        self.assertEqual(report['xray_version'], '26.9.30')
        self.assertTrue(report['client_in_runtime'])
        self.assertTrue(report['public_key_matches'])
        self.assertNotIn(self.link.auth['uuid'], json.dumps(report))
        self.assertTrue(all(call.args[0] == 'GET' for call in panel.call_args_list))

    def test_unrelated_or_duplicate_entry_account_is_rejected(self):
        for entries in ([], [self.inbound, copy.deepcopy(self.inbound)]):
            with self.subTest(count=len(entries)), self.assertRaisesRegex(EntryError, '唯一匹配'):
                deploy_panels.api_diagnosis(Mock(side_effect=[{}, entries, {}]), self.link)

    def test_saved_credentials_diagnose_through_api_without_ssh_and_preserve_pending_work(self):
        fixture = node_fixtures.NodeWorkflowTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        identity, _ = fixture.add('美国', node_fixtures.VLESS)
        registry = fixture.registry()
        server = {'backend': 'standalone', 'identity': 'b' * 32, 'fingerprint': self.link.fingerprint}
        registry.update(identity, server=server, ssh={'target': 'entry.example', 'port': 22, 'identity': None, 'password': True})
        vault = Credentials(registry.state)
        vault.save_panel(identity, server, {'panel_url': 'https://panel.example/', 'api_token': 'private-api-token-123456789'})
        before = registry.path.read_bytes()
        api = Mock(side_effect=[{'panelVersion': '3.9.0', 'xray': {'state': 'running', 'version': '26.9.30'}},
                                [self.inbound], {'inbounds': [self.inbound]}])
        with patch.dict(sys.modules, {'deploy': fixtures.deploy}), patch.object(fixtures.deploy, 'SSH') as ssh, \
                patch.object(Credentials, 'validate_panel', return_value=api), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            api.url, api.token = 'https://panel.example', 'private-api-token-123456789'
            fixtures.deploy.main(['inspect-panel', identity])
        ssh.assert_not_called()
        self.assertEqual(registry.path.read_bytes(), before)
        self.assertNotIn('private-api-token', output.getvalue())
        self.assertNotIn(self.link.auth['uuid'], output.getvalue())
        self.assertIn('Min Client Ver：26.3.27', output.getvalue())
        self.assertTrue((registry.state.directory / ('panel-report-' + identity + '.json')).is_file())


if __name__ == '__main__':
    unittest.main()
