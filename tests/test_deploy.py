import argparse
import base64
import contextlib
import copy
import http.server
import importlib.util
import io
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.parse


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
SPEC = importlib.util.spec_from_file_location("deploy", ROOT / "deploy.py")
deploy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(deploy)
CONFIG = {"SUBLINKPRO_URL": "https://sublink.example.invalid",
          "SUBLINKPRO_API_KEY": "private-test-key"}
NODE = {"INSTALLATION_ID": "a" * 32, "NODE_NAME": "HK node",
        "SUBSCRIPTION_URL": "https://example.invalid:56666/sub/private-sub-id", "MODE": "nat",
        "VLESS_URI": "vless://00000000-0000-4000-8000-000000000001@example.invalid:443?security=reality&type=tcp&flow=xtls-rprx-vision&sni=www.cloudflare.com&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=abcd&fp=chrome"}
TEMPLATE = {
    "id": 11, "name": "Reference airport", "url": "https://reference.invalid/sub/reference-secret",
    "cronExpr": "0 0 * * *", "enabled": True, "group": "SM", "downloadWithProxy": False,
    "proxyLink": "", "userAgent": "", "requestHeaders": None, "fetchUsageInfo": True,
    "skipTLSVerify": True, "updateAfterDetect": True, "updateAfterDetectProfileId": 1,
    "updateAfterDetectChangedOnly": True, "remark": "reference note", "logo": "",
    "nodeNameWhitelist": "", "nodeNameBlacklist": "", "protocolWhitelist": "", "protocolBlacklist": "",
    "nodeNamePreprocess": '[{"matchMode":"regex","pattern":".+","replacement":"old name","enabled":true}]',
    "deduplicationRule": "", "nodeNameUniquify": True, "nodeNamePrefix": "[SM]",
    "nodeNameIntraUniquify": False, "autoFillCountry": False, "backfillExistingCountry": False,
    "nodeCount": 1, "usageUpload": 123, "lastRunTime": None, "successCount": 1,
}
SS_TEMPLATE = {
    "ID": 917, "Name": "[SM]Reference - local", "NameMode": "remark", "Protocol": "ss",
    "Link": "ss://" + base64.urlsafe_b64encode(b"aes-128-gcm:private-ss-password").decode().rstrip("=")
            + "@127.0.0.1:7896",
    "Group": "SM", "DialerProxyName": "", "Source": "manual", "SourceID": 0,
}


class EnvTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / ".env"

    def write(self, value):
        self.path.write_text(value)
        self.path.chmod(0o600)
        return self.path

    def test_values_are_literal_and_round_trip(self):
        marker = Path(self.temp.name) / "executed"
        value = f"$(touch {marker}); $HOME `id` # quoted = secret"
        config = deploy.read_env(self.write(f"# comment\nOKP_ALI_ACCESS_KEY_SECRET='{value}'\n"))
        encoded = deploy.encode_defaults(config).decode().split("=", 1)[1].strip()
        self.assertEqual(base64.b64decode(encoded).decode(), value)
        self.assertFalse(marker.exists())

    def test_unknown_duplicate_controls_and_malformed_keys_rejected(self):
        for content in ("PATH=/tmp\n", "OKP_TEST_MODE=true\n", "OKP_MODE=nat\nOKP_MODE=public",
                        'OKP_NODE_NAME="unclosed', "not-an-assignment", "OKP_NODE_NAME=a\x00b"):
            with self.subTest(content=content), self.assertRaises(deploy.DeployError):
                deploy.read_env(self.write(content))

    def test_insecure_files_and_links_rejected(self):
        self.write("OKP_MODE=nat")
        self.path.chmod(0o644)
        with self.assertRaises(deploy.DeployError):
            deploy.read_env(self.path)
        self.path.chmod(0o600)
        link = self.path.with_name("link")
        link.symlink_to(self.path)
        with self.assertRaises(deploy.DeployError):
            deploy.read_env(link)
        link.unlink()
        os.link(self.path, link)
        with self.assertRaises(deploy.DeployError):
            deploy.read_env(self.path)

    def test_archive_only_contains_runtime_and_remote_defaults(self):
        config = dict(CONFIG, OKP_ALI_ACCESS_KEY_SECRET="aliyun-secret", OKP_ACME_EMAIL="",
                      OKP_ALI_ACCESS_KEY_ID="", UNTRUSTED="not-forwarded")
        payload = deploy.build_archive(config)
        with tarfile.open(fileobj=io.BytesIO(payload)) as archive:
            names = archive.getnames()
            self.assertIn("project/install.sh", names)
            self.assertNotIn("project/.env", names)
            self.assertNotIn("project/deploy.py", names)
            self.assertTrue(all(name.startswith("project/lib/") or name in {
                "project/bootstrap.sh", "project/install.sh", "project/maintenance.sh",
                "project/one-key-proxy", "project/VERSION", "defaults.env"} for name in names))
            defaults = archive.extractfile("defaults.env").read()
            self.assertIn(b"OKP_ALI_ACCESS_KEY_SECRET=", defaults)
            self.assertIn(b"OKP_ACME_EMAIL=\n", defaults)
            self.assertNotIn(b"OKP_ALI_ACCESS_KEY_ID=", defaults)
            self.assertEqual(archive.getmember("defaults.env").mode, 0o600)
        for key in ("SUBLINKPRO_URL", "SUBLINKPRO_API_KEY"):
            self.assertNotIn(CONFIG[key].encode(), payload)
        self.assertNotIn(b"ENABLE_LOCAL_NODE=", defaults)
        self.assertNotIn(b"not-forwarded", payload)


class InteractiveTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = patch.object(deploy, "ROOT", Path(temporary.name))
        root.start()
        self.addCleanup(root.stop)

    def options(self, **overrides):
        values = dict(action="install", target=None, port=None, identity=None, mode=None, domain=None,
                      no_sync=False, create_local_node=None, local_port=None, password=False)
        values.update(overrides)
        return argparse.Namespace(**values)

    def test_menu_exit_does_not_read_credentials(self):
        with patch.object(deploy.sys.stdin, "isatty", return_value=True), patch("builtins.input", return_value="0"), \
                patch.object(deploy, "read_env") as read_env, contextlib.redirect_stdout(io.StringIO()):
            deploy.main([])
        read_env.assert_not_called()

    def test_menu_requires_a_real_terminal(self):
        with patch.object(deploy.sys.stdin, "isatty", return_value=False), \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            deploy.main([])
        self.assertEqual(error.exception.code, 2)

    def test_wizard_collects_public_deployment_and_local_choice(self):
        args = self.options()
        with patch("builtins.input", side_effect=["root@host", "2222", "3", "public", "hk.example.com", "n"]):
            deploy.configure_interactive(args, CONFIG)
        self.assertEqual(args.target, "root@host")
        self.assertEqual(args.port, 2222)
        self.assertIsNone(args.identity)
        self.assertEqual(args.mode, "public")
        self.assertEqual(args.domain, "hk.example.com")
        self.assertFalse(args.create_local_node)

    def test_wizard_keeps_ssh_config_and_uses_env_default(self):
        args = self.options(action="sync", target="ssh-alias")
        with patch("builtins.input", side_effect=["", "3", ""]):
            deploy.configure_interactive(args, dict(CONFIG, ENABLE_LOCAL_NODE="false"))
        self.assertIsNone(args.port)
        self.assertIsNone(args.identity)
        self.assertFalse(args.create_local_node)

    def test_explicit_choice_is_not_prompted_again(self):
        args = self.options(action="sync", target="ssh-alias", create_local_node=True)
        with patch("builtins.input", side_effect=["", "3"]) as prompt:
            deploy.configure_interactive(args, dict(CONFIG, ENABLE_LOCAL_NODE="false"))
        self.assertEqual(prompt.call_count, 2)
        self.assertTrue(args.create_local_node)

    def test_wizard_validates_ports_and_handles_eof(self):
        args = self.options(action="sync", target="ssh-alias", create_local_node=False)
        with patch("builtins.input", side_effect=["0", "65536", "2200", "3"]), \
                contextlib.redirect_stderr(io.StringIO()):
            deploy.configure_interactive(args, CONFIG)
        self.assertEqual(args.port, 2200)
        with patch("builtins.input", side_effect=EOFError), self.assertRaises(deploy.DeployError):
            deploy.prompt_text("test")

    def test_local_node_config_boolean_is_strict(self):
        self.assertTrue(deploy.local_node_default({}))
        self.assertFalse(deploy.local_node_default({"ENABLE_LOCAL_NODE": "false"}))
        with self.assertRaises(deploy.DeployError):
            deploy.local_node_default({"ENABLE_LOCAL_NODE": "typo"})

    def test_wizard_defaults_to_password_authentication(self):
        args = self.options(action="sync", target="root@host", create_local_node=False)
        with patch("builtins.input", side_effect=["", ""]) as prompt:
            deploy.configure_interactive(args, CONFIG)
        self.assertTrue(args.password)
        self.assertIsNone(args.identity)
        self.assertEqual(prompt.call_count, 2)

    def test_wizard_supports_private_key_and_explicit_password_flag(self):
        args = self.options(action="sync", target="root@host", create_local_node=False)
        with patch("builtins.input", side_effect=["", "2", "~/.ssh/my_key"]):
            deploy.configure_interactive(args, CONFIG)
        self.assertFalse(args.password)
        self.assertEqual(args.identity, "~/.ssh/my_key")
        args = self.options(action="sync", target="root@host", create_local_node=False, password=True)
        with patch("builtins.input", return_value="") as prompt:
            deploy.configure_interactive(args, CONFIG)
        self.assertEqual(prompt.call_count, 1)
        self.assertTrue(args.password)

    def test_password_flag_cannot_be_combined_with_identity(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            deploy.main(["sync", "root@host", "--password", "--identity", "some-key"])
        self.assertEqual(error.exception.code, 2)

    def test_password_login_requires_a_terminal(self):
        with patch.object(deploy, "read_env", return_value=CONFIG), \
                patch.object(deploy.sys.stdin, "isatty", return_value=False), \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            deploy.main(["sync", "root@host", "--password"])
        self.assertEqual(error.exception.code, 2)

    def test_authentication_failure_prevents_upload_and_export(self):
        with patch.object(deploy, "read_env", return_value=CONFIG), \
                patch.object(deploy.sys.stdin, "isatty", return_value=True), \
                patch.object(deploy.shutil, "which", return_value="/usr/bin/ssh"), \
                patch.object(deploy, "SSH") as ssh_class, patch.object(deploy, "install") as install, \
                patch.object(deploy, "export_node") as export, contextlib.redirect_stdout(io.StringIO()):
            ssh = ssh_class.return_value
            ssh.connect.side_effect = deploy.DeployError("authentication failed")
            with self.assertRaises(deploy.DeployError):
                deploy.main(["install", "root@host", "--password", "--no-sync"])
            install.assert_not_called()
            export.assert_not_called()
            ssh.close.assert_called_once_with()
            self.assertTrue(ssh_class.call_args.kwargs["password_login"])


class SSHTests(unittest.TestCase):
    def test_password_authentication_is_terminal_only_and_reused(self):
        ssh = deploy.SSH("root@example.invalid", "/tmp/private", 2222, password_login=True)
        with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"done")) as run:
            ssh.connect()
            ssh.connect()
            ssh.run("upload", data=b"private-deployment-data")
            ssh.run("export")
            ssh.close()
        self.assertEqual(run.call_count, 4)
        command = run.call_args_list[0].args[0]
        options = run.call_args_list[0].kwargs
        self.assertIn("PreferredAuthentications=password,keyboard-interactive", command)
        self.assertIn("PubkeyAuthentication=no", command)
        self.assertIn("PasswordAuthentication=yes", command)
        self.assertIn("BatchMode=no", command)
        self.assertIn("-N", command)
        self.assertIn("-f", command)
        self.assertEqual(command[-2:], ["--", "root@example.invalid"])
        self.assertEqual(options["stdin"], subprocess.DEVNULL)
        self.assertIsNone(options["stderr"])
        self.assertNotIn("input", options)
        self.assertEqual(options["env"]["SSH_ASKPASS_REQUIRE"], "never")
        self.assertFalse(any("StrictHostKeyChecking=no" in item for item in command))
        self.assertNotIn("private-deployment-data", repr(run.call_args_list[0]))
        self.assertEqual(run.call_args_list[1].kwargs["input"], b"private-deployment-data")
        self.assertFalse(ssh.connected)

    def test_authentication_failures_do_not_mark_connection_ready(self):
        ssh = deploy.SSH("root@example.invalid", "/tmp/private", password_login=True)
        with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 255)), \
                self.assertRaises(deploy.DeployError):
            ssh.connect()
        self.assertFalse(ssh.connected)
        with patch.object(subprocess, "run", side_effect=subprocess.TimeoutExpired("ssh", 180)), \
                self.assertRaises(deploy.DeployError):
            ssh.connect()
        self.assertFalse(ssh.connected)

    def test_no_secrets_in_ssh_arguments(self):
        ssh = deploy.SSH("root@example.invalid", "/tmp/private", 2222)
        with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"done")) as run:
            ssh.run("remote-command", data=b"secret-payload")
        args, kwargs = run.call_args
        self.assertNotIn("secret-payload", repr(args))
        self.assertEqual(kwargs["input"], b"secret-payload")
        self.assertIn("ForwardAgent=no", args[0])
        self.assertIn("-T", args[0])

    def test_ssh_failure_does_not_echo_captured_secrets(self):
        ssh = deploy.SSH("root@example.invalid", "/tmp/private")
        with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 1, b"secret", b"secret")):
            with self.assertRaises(deploy.DeployError) as error:
                ssh.run("false")
        self.assertNotIn("secret", str(error.exception))

    def test_targets_cannot_inject_commands_or_options(self):
        for target in ("-oProxyCommand=bad", "host;id", "root@$(id)", "host\ncommand"):
            with self.subTest(target=target), self.assertRaises(deploy.DeployError):
                deploy.SSH(target, "/tmp/private")

    def test_failed_install_cleans_remote_staging(self):
        class FakeSSH:
            calls = []

            def run(self, script, **kwargs):
                self.calls.append((script, kwargs))
                if len(self.calls) == 1:
                    return b"/tmp/one-key-proxy.deploy.ABCDEFGH\n"
                if kwargs.get("interactive"):
                    raise deploy.DeployError("installation failed")
                return b""

        ssh = FakeSSH()
        with self.assertRaises(deploy.DeployError):
            deploy.install(ssh, CONFIG)
        self.assertIn("rm -rf -- /tmp/one-key-proxy.deploy.ABCDEFGH", ssh.calls[-1][0])
        self.assertIn("trap", ssh.calls[-2][0])
        self.assertIn("--defaults-file", ssh.calls[-2][0])

    def test_exports_require_completed_identity_and_valid_uri(self):
        def encode(values):
            return "".join(key + "=" + base64.b64encode(value.encode()).decode() + "\n"
                           for key, value in values.items()).encode()

        self.assertEqual(deploy.parse_export(encode(NODE)), NODE)
        for values in ({}, dict(NODE, INSTALLATION_ID="invalid"), dict(NODE, SUBSCRIPTION_URL="https://invalid"),
                       dict(NODE, PANEL_PASSWORD="secret"), dict(NODE, NODE_NAME="line\nname"),
                       dict(NODE, MODE="other"), dict(NODE, SUBSCRIPTION_URL="http://host/sub/id"),
                       dict(NODE, SUBSCRIPTION_URL="https://user:password@host/sub/id")):
            with self.subTest(values=values), self.assertRaises(deploy.DeployError):
                deploy.parse_export(encode(values))
        with self.assertRaises(deploy.DeployError):
            deploy.parse_export(encode(NODE) + encode(NODE))


class ResumeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        root = patch.object(deploy, "ROOT", self.root)
        root.start()
        self.addCleanup(root.stop)
        self.state = deploy.ResumeState()

    def seed(self, action="install", **options):
        with self.state.locked():
            self.state.start(action, self.root / ".env")
            self.state.capture(**options)

    def args(self, **overrides):
        values = dict(action="install", env_file=self.root / ".env", target=None, port=None, identity=None,
                      password=False, auth_method=None, mode=None, domain=None, name=None, airport_name=None,
                      local_port=None, create_local_node=None, no_sync=False, relay=None)
        values.update(overrides)
        return argparse.Namespace(**values)

    def test_each_input_is_saved_before_the_next_prompt(self):
        args = self.args()
        self.seed()
        with self.state.locked(), patch("builtins.input", side_effect=["root@host", "2222", KeyboardInterrupt]):
            with self.assertRaises(KeyboardInterrupt):
                deploy.configure_interactive(args, CONFIG, self.state)
        saved = deploy.ResumeState().load()["options"]
        self.assertEqual(saved["target"], "root@host")
        self.assertEqual(saved["port"], 2222)
        self.assertNotIn("password", saved)
        self.assertEqual(self.state.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.state.path.stat().st_mode & 0o777, 0o600)

    def test_blank_answers_and_auto_authentication_are_not_asked_again(self):
        self.seed(target="root@host", port=None, password=False, identity=None, auth_method="auto",
                  mode="nat", create_local_node=False)
        args = self.args(**{key: value for key, value in self.state.data["options"].items() if key != "env_file"})
        with self.state.locked(), patch("builtins.input", side_effect=AssertionError("answer was already saved")):
            deploy.configure_interactive(args, CONFIG, self.state)

    def test_key_authentication_choice_survives_cancellation_before_path(self):
        self.seed(target="root@host", port=None)
        args = self.args(target="root@host")
        with self.state.locked(), patch("builtins.input", side_effect=["2", KeyboardInterrupt]):
            with self.assertRaises(KeyboardInterrupt):
                deploy.configure_interactive(args, CONFIG, self.state)
        self.assertEqual(deploy.ResumeState().load()["options"]["auth_method"], "key")

    def test_secrets_and_unknown_fields_are_rejected(self):
        self.seed(target="root@host", password=True)
        before = self.state.path.read_bytes()
        with self.state.locked(), self.assertRaises(deploy.DeployError):
            self.state.capture(password="must-not-persist")
        self.assertEqual(self.state.path.read_bytes(), before)
        self.state.load()
        with self.state.locked(), self.assertRaises(deploy.DeployError):
            self.state.capture(SUBLINKPRO_API_KEY="must-not-persist")
        self.assertEqual(self.state.path.read_bytes(), before)

    def test_bad_permissions_links_and_corrupt_records_are_rejected(self):
        self.seed()
        self.state.path.chmod(0o644)
        with self.assertRaises(deploy.DeployError):
            self.state.load()
        self.state.path.chmod(0o600)
        copy_path = self.state.directory / "copy"
        self.state.path.rename(copy_path)
        self.state.path.symlink_to(copy_path)
        with self.assertRaises((deploy.DeployError, OSError)):
            self.state.load()
        self.state.path.unlink()
        self.state.path.write_text("{broken")
        self.state.path.chmod(0o600)
        with self.assertRaises(deploy.DeployError):
            self.state.load()

    def test_atomic_failure_keeps_the_previous_record(self):
        self.seed(target="root@host")
        before = self.state.path.read_bytes()
        with self.state.locked(), patch.object(deploy.os, "replace", side_effect=OSError("interrupted")):
            with self.assertRaises(OSError):
                self.state.capture(port=2222)
        self.assertEqual(self.state.path.read_bytes(), before)
        self.assertEqual(list(self.state.directory.glob(".pending-*")), [])

    def test_concurrent_writer_is_rejected(self):
        with self.state.locked():
            with self.assertRaises(deploy.DeployError), deploy.ResumeState().locked():
                pass

    def test_main_restores_saved_input_and_clears_only_after_success(self):
        self.seed(target="root@host", port=2222, password=False, auth_method="auto", mode="nat",
                  airport_name="Airport", name="Node", local_port=7900, create_local_node=True)
        with self.state.locked():
            self.state.phase("sync", NODE["INSTALLATION_ID"])
        observed = []

        def fail(args, parser, wizard, checkpoint, resume_sync):
            observed.append((args, resume_sync))
            raise deploy.DeployError("retry later")

        with patch.object(deploy, "run_workflow", side_effect=fail), contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(deploy.DeployError):
            deploy.main(["--resume", "--local-port", "7901"])
        self.assertTrue(self.state.path.exists())
        args, resume_sync = observed[0]
        self.assertEqual((args.target, args.port, args.airport_name, args.name), ("root@host", 2222, "Airport", "Node"))
        self.assertEqual(args.local_port, 7901)
        self.assertTrue(resume_sync)
        with patch.object(deploy, "run_workflow"), contextlib.redirect_stdout(io.StringIO()):
            deploy.main(["--resume"])
        self.assertFalse(self.state.path.exists())

    def test_other_hosts_do_not_inherit_inputs_and_fresh_explicitly_replaces(self):
        self.seed(target="root@old", name="Old node", local_port=7900)
        before = self.state.path.read_bytes()
        with self.assertRaises(deploy.DeployError):
            deploy.main(["install", "root@new"])
        self.assertEqual(self.state.path.read_bytes(), before)
        observed = []
        with patch.object(deploy, "run_workflow", side_effect=lambda args, *rest: observed.append(args)):
            deploy.main(["install", "root@new", "--fresh"])
        self.assertEqual(observed[0].target, "root@new")
        self.assertIsNone(observed[0].name)
        self.assertIsNone(observed[0].local_port)
        self.assertFalse(self.state.path.exists())

    def test_explicit_options_override_cached_authentication_and_local_port(self):
        self.seed(target="root@host", password=True, identity=None, auth_method="password",
                  create_local_node=True, local_port=7900)
        observed = []
        with patch.object(deploy, "run_workflow", side_effect=lambda args, *rest: observed.append(args)), \
                contextlib.redirect_stdout(io.StringIO()):
            deploy.main(["--resume", "--identity", "/new/key", "--no-local-node"])
        self.assertFalse(observed[0].password)
        self.assertEqual(observed[0].identity, "/new/key")
        self.assertIsNone(observed[0].local_port)
        self.assertFalse(observed[0].create_local_node)

    def test_check_leaves_pending_records_untouched(self):
        self.seed(target="root@host")
        before = self.state.path.read_bytes()
        with patch.object(deploy, "run_workflow"):
            deploy.main(["check"])
        self.assertEqual(self.state.path.read_bytes(), before)

    def test_missing_target_can_be_filled_on_retry(self):
        self.seed()
        observed = []
        with patch.object(deploy, "run_workflow", side_effect=lambda args, *rest: observed.append(args)), \
                contextlib.redirect_stdout(io.StringIO()):
            deploy.main(["install", "root@host"])
        self.assertEqual(observed[0].target, "root@host")

    def test_fresh_can_replace_a_corrupt_record(self):
        self.seed()
        self.state.path.write_text("{broken")
        with patch.object(deploy, "run_workflow"):
            deploy.main(["sync", "root@new", "--fresh"])
        self.assertFalse(self.state.path.exists())

    def test_installed_vps_resume_skips_install_and_revalidates_identity(self):
        self.seed(target="root@host", password=False, auth_method="auto", create_local_node=False, no_sync=True)
        with self.state.locked():
            self.state.phase("sync", NODE["INSTALLATION_ID"])
        with patch.object(deploy, "read_env", return_value=CONFIG), patch.object(deploy, "SSH") as ssh, \
                patch.object(deploy.shutil, "which", return_value="ssh"), patch.object(deploy, "install") as install, \
                patch.object(deploy, "export_node", return_value=NODE), contextlib.redirect_stdout(io.StringIO()):
            deploy.main(["--resume"])
        install.assert_not_called()
        ssh.return_value.connect.assert_called_once()
        ssh.return_value.close.assert_called_once()
        self.assertFalse(self.state.path.exists())

    def test_failed_sync_after_install_restores_names_without_reinstalling(self):
        def failed_sync(exported, **kwargs):
            kwargs["on_input"](airport_name="Saved airport", name="Saved node", local_port=7900)
            raise deploy.DeployError("API unavailable")

        with patch.object(deploy, "read_env", return_value=CONFIG), patch.object(deploy, "SSH"), \
                patch.object(deploy.sys.stdin, "isatty", return_value=True), \
                patch.object(deploy.shutil, "which", return_value="ssh"), patch.object(deploy, "install") as install, \
                patch.object(deploy, "export_node", return_value=NODE), \
                patch.object(deploy, "SublinkPro") as client_class, contextlib.redirect_stdout(io.StringIO()), \
                patch.object(deploy, "SingBox"), \
                contextlib.redirect_stderr(io.StringIO()):
            client = client_class.return_value
            client.create_local_node = True
            client.url = CONFIG["SUBLINKPRO_URL"]
            client.sync.side_effect = failed_sync
            with self.assertRaises(deploy.DeployError):
                deploy.main(["install", "root@host"])
            saved = self.state.load()
            self.assertEqual(saved["phase"], "sync")
            self.assertEqual(saved["installation_id"], NODE["INSTALLATION_ID"])
            client.sync.side_effect = None
            client.sync.return_value = "synced"
            deploy.main(["--resume"])
            self.assertEqual(install.call_count, 1)
            self.assertEqual(client.sync.call_args.kwargs["airport_name"], "Saved airport")
            self.assertEqual(client.sync.call_args.kwargs["node_name"], "Saved node")
            self.assertEqual(client.sync.call_args.kwargs["local_port"], 7900)
        self.assertFalse(self.state.path.exists())

    def test_changed_vps_identity_stops_before_sync_and_keeps_record(self):
        self.seed(target="root@host", password=False, auth_method="auto", create_local_node=False)
        with self.state.locked():
            self.state.phase("sync", NODE["INSTALLATION_ID"])
        with patch.object(deploy, "read_env", return_value=CONFIG), patch.object(deploy, "SSH"), \
                patch.object(deploy.shutil, "which", return_value="ssh"), patch.object(deploy, "install") as install, \
                patch.object(deploy, "export_node", return_value=dict(NODE, INSTALLATION_ID="b" * 32)), \
                patch.object(deploy.SublinkPro, "sync") as sync, contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(deploy.DeployError):
            deploy.main(["--resume"])
        install.assert_not_called()
        sync.assert_not_called()
        self.assertEqual(self.state.load()["installation_id"], NODE["INSTALLATION_ID"])


class APIHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.dispatch()

    def do_POST(self):
        self.dispatch()

    def do_PUT(self):
        self.dispatch()

    def do_DELETE(self):
        self.dispatch()

    def dispatch(self):
        state = self.server.state
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path
        content = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.headers.get("Content-Type") == "application/x-www-form-urlencoded":
            fields = {key: value[0] for key, value in urllib.parse.parse_qs(content.decode(), keep_blank_values=True).items()}
        else:
            fields = json.loads(content) if content else None
        state["calls"].append((self.command, path, fields, self.headers.get("X-API-Key")))
        if state.get("redirect"):
            self.send_response(302)
            self.send_header("Location", "/credential-leak")
            self.end_headers()
            return
        code, data = 200, None
        if state.get("reject"):
            code = 500
        elif self.command == "GET" and path == "/api/v1/airports/11":
            data = state["template"]
        elif self.command == "GET" and path == "/api/v1/airports":
            keyword = urllib.parse.parse_qs(parsed.query).get("keyword", [""])[0]
            data = [airport for airport in state["airports"] + [state["template"]]
                    if keyword in airport.get("remark", "") or keyword in airport.get("name", "")]
        elif self.command == "GET" and path == "/api/v1/nodes/get":
            search = urllib.parse.parse_qs(parsed.query).get("search", [""])[0]
            data = [node for node in state["nodes"] + [state["ss_template"]]
                    if search in node["Name"] or search in urllib.parse.unquote(node["Link"])]
        elif self.command == "GET" and path == "/api/v1/tags/node/tags":
            node_id = int(urllib.parse.parse_qs(parsed.query)["nodeId"][0])
            data = [{"name": name} for name in state["tags"].get(node_id, [])]
        elif self.command == "POST" and path == "/api/v1/nodes/batch-update-dialer-proxy":
            for node in state["nodes"]:
                if node["ID"] in fields["ids"]:
                    node["DialerProxyName"] = fields["dialerProxyName"]
        elif self.command == "POST" and path in ("/api/v1/nodes/add", "/api/v1/nodes/update"):
            if not state.get("skip_local"):
                existing = next((n for n in state["nodes"] if n["Link"] == fields.get("oldlink")), None)
                node_id = existing["ID"] if existing else max([917] + [n["ID"] for n in state["nodes"]]) + 1
                node = dict(SS_TEMPLATE, ID=node_id, Name=fields["name"], Link=fields["link"],
                            NameMode=fields["nameMode"], Group=fields["group"], DialerProxyName=fields["dialerProxyName"])
                if existing:
                    existing.update(node)
                else:
                    state["nodes"].append(node)
                state["tags"][node_id] = fields["tags"].split(",") if fields["tags"] else []
            if state.pop("fail_after_local_write", False):
                code = 500
        elif self.command == "POST" and re.fullmatch(r"/api/v1/airports/\d+/pull", path):
            pass
        elif self.command == "DELETE" and path == "/api/v1/nodes/delete":
            node_id = int(urllib.parse.parse_qs(parsed.query)["id"][0])
            state["nodes"] = [node for node in state["nodes"] if node["ID"] != node_id]
        elif self.command == "DELETE" and re.fullmatch(r"/api/v1/airports/\d+", path):
            airport_id = int(path.rsplit("/", 1)[1])
            if urllib.parse.parse_qs(parsed.query).get("deleteNodes") == ["true"]:
                state["nodes"] = [node for node in state["nodes"] if node.get("SourceID") != airport_id]
            state["airports"] = [airport for airport in state["airports"] if airport["id"] != airport_id]
            if state.pop("fail_after_airport_delete", False):
                code = 500
        elif (self.command == "POST" and path == "/api/v1/airports"
              or self.command == "PUT" and re.fullmatch(r"/api/v1/airports/\d+", path)):
            if not state.get("skip"):
                if self.command == "POST":
                    state["airports"].append(dict(fields, id=max([20] + [a["id"] for a in state["airports"]]) + 1))
                else:
                    next(a for a in state["airports"] if a["id"] == int(path.rsplit("/", 1)[1])).update(fields)
            if state.pop("fail_after_write", False):
                code = 500
        else:
            code = 404
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"code": code, "data": data, "msg": "secret response text"}).encode())


class SublinkTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = patch.object(deploy, "ROOT", Path(temporary.name))
        root.start()
        self.addCleanup(root.stop)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), APIHandler)
        self.server.state = {"calls": [], "airports": [], "template": copy.deepcopy(TEMPLATE),
                             "nodes": [], "ss_template": copy.deepcopy(SS_TEMPLATE), "tags": {917: ["stable"]}}
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.cleanup)
        self.client = deploy.SublinkPro(CONFIG)
        # Production config requires HTTPS; only the local test fixture uses plain HTTP.
        self.client.url = "http://127.0.0.1:" + str(self.server.server_port)

    def cleanup(self):
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()

    def test_create_readback_and_repeated_sync(self):
        self.assertIn("airport added", self.client.sync(NODE, airport_name="My airport", node_name="My node", local_port=7897))
        self.assertIn("already up to date", self.client.sync(NODE))
        calls = self.server.state["calls"]
        creates = [fields for method, path, fields, _ in calls if method == "POST" and path == "/api/v1/airports"]
        self.assertEqual(len(creates), 1)
        self.assertTrue(all(key == CONFIG["SUBLINKPRO_API_KEY"] for _, _, _, key in calls))
        self.assertEqual(sum(path == "/api/v1/nodes/add" for _, path, _, _ in calls), 1)
        fields = creates[0]
        self.assertEqual(fields["url"], NODE["SUBSCRIPTION_URL"])
        self.assertEqual(fields["name"], "My airport")
        self.assertEqual(json.loads(fields["nodeNamePreprocess"])[0]["replacement"], "My node")
        self.assertTrue(fields["skipTLSVerify"])
        for field in ("cronExpr", "enabled", "group", "fetchUsageInfo", "updateAfterDetect",
                      "updateAfterDetectProfileId", "updateAfterDetectChangedOnly", "nodeNamePrefix",
                      "nodeNameUniquify", "downloadWithProxy"):
            self.assertEqual(fields[field], TEMPLATE[field])
        self.assertNotIn("id", fields)
        self.assertNotIn("usageUpload", fields)
        self.assertNotIn("successCount", fields)
        self.assertNotIn(TEMPLATE["url"], json.dumps(fields))
        self.assertEqual(self.server.state["template"], TEMPLATE)
        local = self.server.state["nodes"][0]
        self.assertEqual(local["Name"], "[SM]My node - \u672c\u5730")
        self.assertEqual(local["NameMode"], "remark")
        link = urllib.parse.urlsplit(local["Link"])
        self.assertEqual(link.hostname, "127.0.0.1")
        self.assertEqual(link.port, 7897)
        self.assertNotEqual(link.username, urllib.parse.urlsplit(SS_TEMPLATE["Link"]).username)
        self.assertGreaterEqual(len(deploy.SingBox.ss_parameters(local["Link"])[2]), 32)
        self.assertEqual(self.server.state["tags"][918], ["稳定"])
        self.assertEqual(self.server.state["ss_template"], SS_TEMPLATE)

    def test_update_preserves_custom_airport_settings_and_names(self):
        self.client.sync(NODE, airport_name="My airport", node_name="My node", local_port=7897)
        existing = self.server.state["airports"][0]
        existing.update(group="custom group", cronExpr="0 8 * * *", nodeNamePrefix="[CUSTOM]")
        changed = dict(NODE, SUBSCRIPTION_URL=NODE["SUBSCRIPTION_URL"].replace(":56666", ":8443"), NODE_NAME="new")
        self.assertIn("airport updated", self.client.sync(changed))
        fields = [fields for method, _, fields, _ in self.server.state["calls"] if method == "PUT"][0]
        self.assertEqual(fields["group"], "custom group")
        self.assertEqual(fields["cronExpr"], "0 8 * * *")
        self.assertEqual(fields["nodeNamePrefix"], "[CUSTOM]")
        self.assertEqual(fields["name"], "My airport")
        self.assertEqual(json.loads(fields["nodeNamePreprocess"])[0]["replacement"], "My node")
        self.assertTrue(any(path.endswith("/pull") for _, path, _, _ in self.server.state["calls"]))
        self.assertEqual(urllib.parse.urlsplit(self.server.state["nodes"][0]["Link"]).port, 7897)

    def test_rename_and_public_tls_settings_are_automatic(self):
        self.client.sync(NODE, local_port=7897)
        public = dict(NODE, MODE="public", SUBSCRIPTION_URL="https://my-vps.example:2096/sub/new-id")
        self.client.sync(public, airport_name="My renamed airport", node_name="$New node", local_port=7900)
        airport = self.server.state["airports"][0]
        self.assertEqual(airport["name"], "My renamed airport")
        self.assertFalse(airport["skipTLSVerify"])
        self.assertEqual(airport["url"], public["SUBSCRIPTION_URL"])
        self.assertEqual(json.loads(airport["nodeNamePreprocess"])[0]["replacement"], "$$New node")
        self.assertEqual(self.server.state["nodes"][0]["Name"], "[SM]$New node - \u672c\u5730")
        self.assertEqual(urllib.parse.urlsplit(self.server.state["nodes"][0]["Link"]).port, 7900)

    def test_first_import_prompts_for_two_names_and_local_port(self):
        with patch("builtins.input", side_effect=["Airport A", "Node B", "7897"]) as prompt:
            self.client.sync(NODE, interactive=True)
        airport = self.server.state["airports"][0]
        self.assertEqual(prompt.call_count, 3)
        self.assertEqual(airport["name"], "Airport A")
        self.assertEqual(json.loads(airport["nodeNamePreprocess"])[0]["replacement"], "Node B")
        with patch("builtins.input", side_effect=AssertionError("must not prompt on repeated sync")):
            self.client.sync(NODE, interactive=True)

    def test_airport_name_is_checkpointed_before_next_prompt(self):
        saved = {}
        with patch("builtins.input", side_effect=["Saved airport", KeyboardInterrupt]), self.assertRaises(KeyboardInterrupt):
            self.client.sync(NODE, interactive=True, on_input=lambda **values: saved.update(values))
        self.assertEqual(saved, {"airport_name": "Saved airport"})

    def test_names_and_port_are_checkpointed_before_api_write(self):
        saved = {}
        self.server.state["fail_after_write"] = True
        with patch("builtins.input", side_effect=["Saved airport", "Saved node", "7900"]), self.assertRaises(deploy.DeployError):
            self.client.sync(NODE, interactive=True, on_input=lambda **values: saved.update(values))
        self.assertEqual(saved, {"airport_name": "Saved airport", "name": "Saved node", "local_port": 7900})

    def test_uncertain_write_reconciles_on_retry(self):
        self.server.state["fail_after_write"] = True
        with self.assertRaises(deploy.DeployError):
            self.client.sync(NODE, local_port=7897)
        self.assertIn("already up to date", self.client.sync(NODE, local_port=7897))
        self.assertEqual(sum(method == "POST" and path == "/api/v1/airports"
                             for method, path, _, _ in self.server.state["calls"]), 1)

    def test_application_failure_is_not_success_or_secret_output(self):
        self.server.state["reject"] = True
        with self.assertRaises(deploy.DeployError) as error:
            self.client.sync(NODE)
        self.assertNotIn("secret response text", str(error.exception))

    def test_missing_airport_readback_is_not_reported_as_imported(self):
        self.server.state["skip"] = True
        with self.assertRaises(deploy.DeployError):
            self.client.sync(NODE, local_port=7897)

    def test_redirect_does_not_forward_credentials(self):
        self.server.state["redirect"] = True
        with self.assertRaises(deploy.DeployError):
            self.client.sync(NODE)
        self.assertEqual(len(self.server.state["calls"]), 1)

    def test_ambiguous_ownership_cannot_be_modified(self):
        self.client.sync(NODE, local_port=7897)
        existing = self.server.state["airports"][0]
        self.server.state["airports"] = [existing, dict(existing, id=22)]
        with self.assertRaises(deploy.DeployError):
            self.client.sync(NODE)

    def test_creation_uses_builtins_even_when_previous_reference_is_invalid(self):
        self.server.state["template"]["cronExpr"] = None
        self.server.state["ss_template"]["Protocol"] = "socks"
        self.client.sync(NODE, local_port=7900)
        self.assertEqual(self.server.state["airports"][0]["cronExpr"], "0 0 * * *")
        calls = self.server.state["calls"]
        self.assertFalse(any(path == "/api/v1/airports/11" or "nodeId=917" in path for _, path, _, _ in calls))

    def test_local_port_is_required_and_validated_before_writes(self):
        for port in (None, 0, -1, 65536, "not-a-port", "1.5"):
            with self.subTest(port=port), self.assertRaises(deploy.DeployError):
                self.client.sync(NODE, local_port=port)
        self.assertTrue(all(method == "GET" for method, _, _, _ in self.server.state["calls"]))
        for port in (1, 65535):
            self.assertEqual(deploy.SublinkPro.local_port(port), port)
        with patch("builtins.input", side_effect=["", "0", "65536", "7900"]):
            self.assertEqual(deploy.SublinkPro.local_port(None, interactive=True), 7900)

    def test_uncertain_local_write_reuses_node_and_port_on_retry(self):
        self.server.state["fail_after_local_write"] = True
        with self.assertRaises(deploy.DeployError):
            self.client.sync(NODE, local_port=7897)
        self.assertIn("local Shadowsocks node verified", self.client.sync(NODE))
        self.assertEqual(sum(path == "/api/v1/nodes/add" for _, path, _, _ in self.server.state["calls"]), 1)

    def test_local_update_preserves_tags_group_and_dialer(self):
        self.client.sync(NODE, local_port=7897)
        self.server.state["nodes"][0].update(Group="custom", DialerProxyName="local-chain")
        self.server.state["tags"][918] = ["stable", "custom"]
        self.client.sync(NODE, local_port=7901)
        self.assertEqual(self.server.state["nodes"][0]["Group"], "custom")
        self.assertEqual(self.server.state["nodes"][0]["DialerProxyName"], "local-chain")
        self.assertEqual(self.server.state["tags"][918], ["stable", "custom"])

    def test_existing_local_connection_and_name_cannot_be_adopted(self):
        with self.assertRaises(deploy.DeployError):
            self.client.sync(NODE, local_port=7896)
        self.server.state["nodes"] = [dict(SS_TEMPLATE, ID=919, Name="[SM]HK node - \u672c\u5730")]
        with self.assertRaises(deploy.DeployError):
            self.client.sync(NODE, local_port=7900)
        self.assertTrue(all(method == "GET" for method, _, _, _ in self.server.state["calls"]))

    def test_skipped_local_creation_is_not_reported_as_success(self):
        self.server.state["skip_local"] = True
        with self.assertRaises(deploy.DeployError):
            self.client.sync(NODE, local_port=7897)

    def test_new_nodes_have_independent_passwords_and_updates_keep_them(self):
        self.client.sync(NODE, local_port=7897)
        first = self.server.state["nodes"][0]["Link"]
        self.client.sync(dict(NODE, INSTALLATION_ID="b" * 32, NODE_NAME="Other"), local_port=7900)
        second = self.server.state["nodes"][1]["Link"]
        self.assertNotEqual(deploy.SingBox.ss_parameters(first)[2], deploy.SingBox.ss_parameters(second)[2])
        self.client.sync(NODE)
        self.assertEqual(self.server.state["nodes"][0]["Link"], first)

    def test_owned_local_node_must_be_loopback_shadowsocks(self):
        with self.assertRaises(deploy.DeployError):
            self.client.local_ss_link(dict(SS_TEMPLATE, Protocol="socks5"))

    def airport_only_client(self):
        config = dict(CONFIG, ENABLE_LOCAL_NODE="false")
        client = deploy.SublinkPro(config)
        client.url = self.client.url
        return client

    def test_airport_only_sync_needs_no_local_reference_or_port(self):
        client = self.airport_only_client()
        with patch("builtins.input", side_effect=["Airport", "Node"]) as prompt:
            result = client.sync(NODE, interactive=True)
        self.assertEqual(prompt.call_count, 2)
        self.assertIn("local node sync disabled", result)
        self.assertEqual(len(self.server.state["airports"]), 1)
        self.assertEqual(self.server.state["nodes"], [])
        self.assertTrue(all("/airports" in path for _, path, _, _ in self.server.state["calls"]))

    def test_disabling_local_sync_preserves_existing_nodes(self):
        self.client.sync(NODE, local_port=7897)
        existing = copy.deepcopy(self.server.state["nodes"])
        tags = copy.deepcopy(self.server.state["tags"])
        self.server.state["calls"] = []
        self.airport_only_client().sync(NODE, node_name="New name")
        self.assertEqual(self.server.state["nodes"], existing)
        self.assertEqual(self.server.state["tags"], tags)
        self.assertTrue(all("/airports" in path for _, path, _, _ in self.server.state["calls"]))

    def test_disabled_local_sync_does_not_parse_custom_rename_rules(self):
        client = self.airport_only_client()
        client.sync(NODE)
        self.server.state["airports"][0]["nodeNamePreprocess"] = '[{"matchMode":"text","pattern":"a","replacement":"b"}]'
        self.assertIn("already up to date", client.sync(NODE))

    def test_check_respects_cli_override_and_port_enables_local_node(self):
        original_request = deploy.SublinkPro.request

        def fixture_request(client, *args, **kwargs):
            client.url = self.client.url
            return original_request(client, *args, **kwargs)

        for default, flags, expected in (
            ("false", [], False), ("false", ["--local-node"], True),
            ("true", ["--no-local-node"], False), ("false", ["--local-port", "7897"], True),
        ):
            with self.subTest(default=default, flags=flags):
                self.server.state["calls"] = []
                config = dict(CONFIG, ENABLE_LOCAL_NODE=default)
                with patch.object(deploy, "read_env", return_value=config), \
                        patch.object(deploy.SublinkPro, "request", fixture_request), \
                        patch.object(deploy, "SingBox") as box, \
                        contextlib.redirect_stdout(io.StringIO()):
                    deploy.main(["check"] + flags)
                calls = self.server.state["calls"]
                self.assertEqual(box.called, expected)
                self.assertEqual(box.return_value.check.called, expected)
                self.assertTrue(all(method == "GET" for method, _, _, _ in calls))

    def test_conflicting_local_flags_fail_before_any_api_call(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            deploy.main(["check", "--no-local-node", "--local-port", "7897"])
        self.assertEqual(error.exception.code, 2)
        self.assertEqual(self.server.state["calls"], [])

    def test_singbox_and_sublink_resources_can_be_deleted_without_ssh(self):
        from test_deploy_resources import sample_config
        path = deploy.ROOT / "sing-box.json"
        original = sample_config()
        path.write_text(json.dumps(original))
        path.chmod(0o600)
        config = dict(CONFIG, SINGBOX_CONFIG=str(path), SINGBOX_BINARY=sys.executable,
                      SINGBOX_SERVICE_LABEL="test.singbox")
        state = deploy.ResumeState()
        identity = NODE["INSTALLATION_ID"]
        original_request = deploy.SublinkPro.request

        def fixture_request(client, *args, **kwargs):
            client.url = self.client.url
            return original_request(client, *args, **kwargs)

        with patch.object(deploy.sys, "platform", "darwin"), patch.object(deploy.SingBox, "check_payload"), \
                patch.object(deploy.SingBox, "reload"):
            box = deploy.SingBox(config)
            with state.locked():
                registry = deploy.ManagedDeployments(state)
                registry.register(identity, "root@expired.example", deploy.ROOT / ".env", CONFIG["SUBLINKPRO_URL"], "My VPS")
                self.client.sync(NODE, airport_name="My VPS", node_name="My node", local_port=7900,
                                 registry=registry, singbox=box)
                registry.update(identity, status="active")
            self.assertEqual(len(json.loads(path.read_bytes())["inbounds"]), 3)
            record = deploy.ManagedDeployments(state).records[identity]
            self.assertEqual(record["airport_id"], 21)
            self.assertEqual(record["local_node_id"], 918)
            self.server.state["fail_after_airport_delete"] = True
            with patch.object(deploy, "read_env", return_value=config), \
                    patch.object(deploy.SublinkPro, "request", fixture_request), \
                    patch.object(deploy.sys.stdin, "isatty", return_value=True), \
                    patch.object(deploy, "prompt_yes_no", return_value=True) as confirm, patch.object(deploy, "SSH") as ssh, \
                    contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(deploy.DeployError):
                    deploy.main(["remove", identity])
                remaining = deploy.ManagedDeployments(state).records[identity]
                self.assertEqual(remaining["status"], "deleting")
                self.assertIsNone(remaining["singbox"])
                deploy.main(["remove", identity])
                self.assertEqual(confirm.call_count, 1)
            ssh.assert_not_called()
        self.assertEqual(json.loads(path.read_bytes()), original)
        self.assertEqual(self.server.state["airports"], [])
        self.assertEqual(self.server.state["nodes"], [])
        self.assertEqual(deploy.ManagedDeployments(state).records, {})

    def test_singbox_preflight_failure_prevents_remote_creation(self):
        state = deploy.ResumeState()
        with state.locked():
            registry = deploy.ManagedDeployments(state)
            registry.register(NODE["INSTALLATION_ID"], "root@host", deploy.ROOT / ".env", CONFIG["SUBLINKPRO_URL"], "My VPS")
            with patch.object(deploy.SingBox, "plan", side_effect=deploy.DeployError("port conflict")), \
                    self.assertRaises(deploy.DeployError):
                self.client.sync(NODE, local_port=7900, registry=registry, singbox=object.__new__(deploy.SingBox))
        self.assertTrue(all(method == "GET" for method, _, _, _ in self.server.state["calls"]))

    def test_sublink_shared_chain_blocks_deletion(self):
        self.client.sync(NODE, local_port=7900)
        local = self.server.state["nodes"][0]
        self.server.state["nodes"].append(dict(SS_TEMPLATE, ID=999, Name="another chain", DialerProxyName=local["Name"]))
        record = {"airport_id": 21, "local_node_id": local["ID"]}
        with self.assertRaises(deploy.DeployError):
            self.client.deletion_candidates(NODE["INSTALLATION_ID"], record)

    def test_repeated_deletion_reconciles_missing_resources(self):
        self.client.sync(NODE, local_port=7900)
        record = {"airport_id": 21, "local_node_id": 918}
        self.client.remove_deployment(NODE["INSTALLATION_ID"], record, lambda **values: record.update(values))
        self.client.remove_deployment(NODE["INSTALLATION_ID"], record, lambda **values: record.update(values))
        self.assertEqual(record, {"airport_id": None, "local_node_id": None})

    def test_disabled_local_nodes_skip_singbox_even_with_invalid_configuration(self):
        original_request = deploy.SublinkPro.request

        def fixture_request(client, *args, **kwargs):
            client.url = self.client.url
            return original_request(client, *args, **kwargs)

        config = dict(CONFIG, SINGBOX_CONFIG="/does/not/exist")
        with patch.object(deploy, "read_env", return_value=config), \
                patch.object(deploy.SublinkPro, "request", fixture_request), \
                patch.object(deploy, "SingBox") as singbox, contextlib.redirect_stdout(io.StringIO()):
            deploy.main(["check", "--no-local-node"])
        singbox.assert_not_called()

    def test_relay_command_updates_sublink_and_rejects_cycles_without_ssh(self):
        child_id, parent_id = "a" * 32, "b" * 32
        self.server.state["airports"] = [dict(TEMPLATE, id=21, name="Child airport", remark="[okp:" + child_id + "]")]
        self.server.state["template"]["remark"] = "[okp:" + parent_id + "]"
        self.server.state["nodes"] = [
            dict(SS_TEMPLATE, ID=201, Protocol="vless", Name="Child", SourceID=21, Link=NODE["VLESS_URI"]),
            dict(SS_TEMPLATE, ID=101, Protocol="vless", Name="Parent", SourceID=11, Link=NODE["VLESS_URI"]),
        ]
        state = deploy.ResumeState()
        with state.locked():
            registry = deploy.ManagedDeployments(state)
            for key, name, airport, remote in ((child_id, "Child", 21, 201), (parent_id, "Parent", 11, 101)):
                registry.register(key, name, deploy.ROOT / ".env", CONFIG["SUBLINKPRO_URL"], name)
                registry.update(key, airport_id=airport, remote_node_id=remote, kind="adopted", status="active")
        original_request = deploy.SublinkPro.request

        def fixture_request(client, *args, **kwargs):
            client.url = self.client.url
            return original_request(client, *args, **kwargs)

        with patch.object(deploy, "read_env", return_value=CONFIG), \
                patch.object(deploy.SublinkPro, "request", fixture_request), patch.object(deploy, "SSH") as ssh, \
                contextlib.redirect_stdout(io.StringIO()):
            deploy.main(["relay", "Child", "--via", "Parent"])
            self.assertEqual(self.server.state["nodes"][0]["DialerProxyName"], "Parent")
            self.assertEqual(deploy.ManagedDeployments(state).records[child_id]["relay_id"], parent_id)
            with self.assertRaises(deploy.DeployError):
                deploy.main(["relay", "Parent", "--via", "Child"])
            deploy.main(["relay", "Child", "--direct"])
            self.assertEqual(self.server.state["nodes"][0]["DialerProxyName"], "")
            self.assertIsNone(deploy.ManagedDeployments(state).records[child_id]["relay_id"])
            ssh.assert_not_called()

    def test_adopted_manual_remote_and_local_nodes_are_deleted_together(self):
        identity = "c" * 32
        local = dict(SS_TEMPLATE, ID=507, Name="Home local", Link=SS_TEMPLATE["Link"] + "#okp-local:" + identity)
        remote = dict(SS_TEMPLATE, ID=501, Name="Home", Protocol="vless", SourceID=0,
                      Link=NODE["VLESS_URI"] + "#okp-remote:" + identity, DialerProxyName="Parent")
        self.server.state["nodes"] = [local, remote]
        record = {"kind": "adopted", "airport_id": None, "local_node_id": 507, "remote_node_id": 501}
        self.client.remove_deployment(identity, record, lambda **values: record.update(values))
        self.assertEqual(self.server.state["nodes"], [])
        self.assertIsNone(record["remote_node_id"])

    def test_https_credentials_and_clean_url_required(self):
        for url in ("http://example.invalid", "https://user:password@example.invalid",
                    "https://example.invalid?token=secret", "https://example.invalid/#fragment"):
            with self.subTest(url=url), self.assertRaises(deploy.DeployError):
                deploy.SublinkPro(dict(CONFIG, SUBLINKPRO_URL=url))


if __name__ == "__main__":
    unittest.main()
