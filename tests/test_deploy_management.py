import argparse
import base64
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import test_deploy as fixtures
import deploy_subscription as subscriptions
from test_deploy_resources import sample_config

deploy = fixtures.deploy
URL = "https://subscription.example/path?token=private-subscription-token"


class MenuTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for patcher in (patch.object(deploy, "ROOT", self.root),
                        patch.object(deploy.sys.stdin, "isatty", return_value=True)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_menu_matches_requested_order_without_global_relay_or_resume(self):
        output = io.StringIO()
        with patch("builtins.input", return_value="0"), contextlib.redirect_stdout(output):
            deploy.choose_action({"phase": "input"})
        self.assertEqual(output.getvalue().strip().splitlines()[1:], [
            "  1. 安装配置", "  2. 添加配置", "  3. 删除配置", "  4. 查看配置", "  5. 检查环境", "  0. 退出"])

    def test_check_returns_to_menu_without_touching_pending(self):
        state = deploy.ResumeState()
        with state.locked():
            state.start("install", self.root / ".env")
            state.capture(target="root@old")
        before = state.path.read_bytes()
        output = io.StringIO()
        with patch("builtins.input", side_effect=["5", "0"]), patch.object(deploy, "run_workflow") as run, \
                contextlib.redirect_stdout(output):
            deploy.main([])
        self.assertEqual(run.call_args.args[0].action, "check")
        self.assertEqual(output.getvalue().count("One-Key-Proxy"), 2)
        self.assertNotIn("继续上次", output.getvalue())
        self.assertEqual(state.path.read_bytes(), before)

    def test_resume_choice_is_inside_install_and_restart_drops_old_fields(self):
        for choice in ("1", "2", "0"):
            with self.subTest(choice=choice):
                state = deploy.ResumeState()
                with state.locked():
                    state.start("install", self.root / ".env")
                    state.capture(target="root@old", name="Old node", local_port=7900)
                output = io.StringIO()
                with patch("builtins.input", side_effect=["1", choice, "0"]), \
                        patch.object(deploy, "run_workflow") as run, contextlib.redirect_stdout(output):
                    deploy.main([])
                if choice == "0":
                    run.assert_not_called()
                    self.assertTrue(state.path.exists())
                else:
                    args = run.call_args.args[0]
                    self.assertEqual(args.target, "root@old" if choice == "1" else None)
                    self.assertEqual(args.name, "Old node" if choice == "1" else None)
                    self.assertFalse(state.path.exists())
                self.assertGreater(output.getvalue().index("继续上次"), output.getvalue().index("0. 退出"))

    def test_configuration_detail_owns_relay_action(self):
        state = deploy.ResumeState()
        identity = "a" * 32
        with state.locked():
            registry = deploy.ManagedDeployments(state)
            registry.register(identity, "root@host", self.root / ".env", fixtures.CONFIG["SUBLINKPRO_URL"], "Node")
            registry.update(identity, status="active")
        with patch("builtins.input", side_effect=["4", "1", "1", "0", "0", "0"]), \
                patch.object(deploy, "manage_relay") as relay, contextlib.redirect_stdout(io.StringIO()):
            deploy.main([])
        self.assertEqual(relay.call_args.args[0].target, identity)
        self.assertIsNone(relay.call_args.args[0].relay)

    def test_subscription_wizard_does_not_ask_ssh_questions(self):
        args = argparse.Namespace(action="add", target=None, source=None, subscription_url=None,
                                  insecure_subscription=None, no_sync=False, create_local_node=None, local_port=None)
        with patch("builtins.input", side_effect=["2", URL, "n", "y"]) as prompt:
            deploy.configure_interactive(args, fixtures.CONFIG)
        self.assertEqual(args.source, "subscription")
        self.assertEqual(args.subscription_url, URL)
        self.assertTrue(args.create_local_node)
        self.assertFalse(any("SSH" in call.args[0] for call in prompt.call_args_list[1:]))


class SubscriptionTests(unittest.TestCase):
    def test_plain_and_base64_select_same_connection(self):
        raw = (fixtures.NODE["VLESS_URI"] + "#Hong%20Kong\n").encode()
        plain = subscriptions.local_candidates(raw)
        self.assertEqual(plain, subscriptions.local_candidates(base64.b64encode(raw).rstrip(b"=")))
        self.assertEqual(plain[0]["name"], "Hong Kong")

    def test_selection_survives_reordering_and_rejects_changed_connection(self):
        first = fixtures.NODE["VLESS_URI"] + "#First"
        second = first.replace("example.invalid", "second.invalid").replace("#First", "#Second")
        saved = {}
        with patch.object(subscriptions, "read_subscription", return_value=(first + "\n" + second).encode()):
            selected = subscriptions.subscription_export(URL, "https://service.invalid", local=True, selected="2",
                                                          on_input=lambda **v: saved.update(v))
        with patch.object(subscriptions, "read_subscription", return_value=(second + "\n" + first).encode()):
            repeated = subscriptions.subscription_export(URL, "https://service.invalid", local=True,
                                                          selected=saved["subscription_node"])
        self.assertEqual(selected, repeated)
        with patch.object(subscriptions, "read_subscription", return_value=first.encode()), \
                self.assertRaises(deploy.DeployError):
            subscriptions.subscription_export(URL, "https://service.invalid", local=True, selected=saved["subscription_node"])

    def test_multiple_nodes_require_selection_before_writes(self):
        raw = (fixtures.NODE["VLESS_URI"] + "\n" + fixtures.NODE["VLESS_URI"].replace("example.invalid", "two.invalid")).encode()
        with patch.object(subscriptions, "read_subscription", return_value=raw), self.assertRaises(deploy.DeployError):
            subscriptions.subscription_export(URL, "https://service.invalid", local=True)

    def test_subscription_identity_is_stable_and_instance_scoped(self):
        first = subscriptions.subscription_export(URL, "https://one.invalid")
        self.assertEqual(first, subscriptions.subscription_export(URL, "https://one.invalid"))
        self.assertNotEqual(first["INSTALLATION_ID"], subscriptions.subscription_export(URL, "https://two.invalid")["INSTALLATION_ID"])

    def test_invalid_subscription_and_url_errors_do_not_echo_tokens(self):
        for value in ("file:///private-token", "https://user:private-token@example.com/sub", "https://host:invalid/sub"):
            with self.assertRaises(deploy.DeployError) as error:
                subscriptions.validate_url(value)
            self.assertNotIn("private-token", str(error.exception))
        for raw in (b"not a subscription", b"ss://invalid", b"\xff"):
            with self.assertRaises(deploy.DeployError):
                subscriptions.local_candidates(raw)


class SubscriptionWorkflowTests(unittest.TestCase):
    setUp = fixtures.SublinkTests.setUp
    cleanup = fixtures.SublinkTests.cleanup

    def fixture_request(self, client, *args, **kwargs):
        client.url = self.client.url
        return self.original_request(client, *args, **kwargs)

    def run_cli(self, arguments, config=None):
        self.original_request = deploy.SublinkPro.request
        with patch.object(deploy, "read_env", return_value=config or dict(fixtures.CONFIG, ENABLE_LOCAL_NODE="false")), \
                patch.object(deploy.SublinkPro, "request", lambda c, *a, **k: self.fixture_request(c, *a, **k)), \
                patch.object(deploy.sys.stdin, "isatty", return_value=False), \
                patch.object(deploy, "SSH") as ssh, contextlib.redirect_stdout(io.StringIO()):
            deploy.main(arguments)
        ssh.assert_not_called()

    def test_url_add_repeats_without_ssh_or_duplicate_airports(self):
        self.run_cli(["add", URL, "--no-local-node", "--airport-name", "URL airport", "--node-name", "URL node"])
        self.run_cli(["add", "--subscription-url", URL, "--no-local-node"])
        self.assertEqual(len(self.server.state["airports"]), 1)
        record = next(iter(deploy.ManagedDeployments(deploy.ResumeState()).records.values()))
        self.assertEqual(record["status"], "active")
        self.assertEqual(record["kind"], "subscription")
        self.assertNotIn("private-subscription-token", json.dumps(record))
        self.assertFalse(deploy.ResumeState().path.exists())

    def test_failed_url_add_preserves_private_input_and_resumes(self):
        self.server.state["fail_after_write"] = True
        with self.assertRaises(deploy.DeployError), contextlib.redirect_stderr(io.StringIO()):
            self.run_cli(["add", URL, "--no-local-node", "--airport-name", "URL airport"])
        state = deploy.ResumeState()
        saved = state.load()
        self.assertEqual(saved["options"]["subscription_url"], URL)
        self.assertEqual(state.path.stat().st_mode & 0o777, 0o600)
        self.run_cli(["--resume"])
        self.assertEqual(len(self.server.state["airports"]), 1)
        self.assertFalse(state.path.exists())

    def test_local_enable_requires_singbox_before_api_mutation(self):
        with self.assertRaisesRegex(deploy.DeployError, "SINGBOX_CONFIG"), contextlib.redirect_stderr(io.StringIO()):
            self.run_cli(["add", URL, "--local-port", "7900"], fixtures.CONFIG)
        self.assertEqual(self.server.state["calls"], [])

    def test_url_add_writes_matching_singbox_and_sublink_local_nodes(self):
        path = deploy.ROOT / "singbox.json"
        original = sample_config()
        path.write_text(json.dumps(original))
        path.chmod(0o600)
        config = dict(fixtures.CONFIG, SINGBOX_CONFIG=str(path), SINGBOX_BINARY=sys.executable,
                      SINGBOX_SERVICE_LABEL="test.singbox")
        with patch.object(subscriptions, "read_subscription", return_value=fixtures.NODE["VLESS_URI"].encode()), \
                patch.object(sys, "platform", "darwin"), patch.object(deploy.SingBox, "check_payload"), \
                patch.object(deploy.SingBox, "reload"):
            self.run_cli(["add", URL, "--airport-name", "Airport", "--node-name", "Local", "--local-port", "7900"], config)
        local = self.server.state["nodes"][0]
        port, method, password = deploy.SingBox.ss_parameters(local["Link"])
        document = json.loads(path.read_text())
        inbound = document["inbounds"][-1]
        self.assertEqual((inbound["listen_port"], inbound["method"], inbound["password"]), (port, method, password))
        self.assertEqual(inbound["tag"], "ss-Local-in")
        self.assertEqual(document["outbounds"][-1]["tag"], "vless-Local-out")
        self.assertEqual(document["route"]["final"], "direct")
        self.assertEqual(document["inbounds"][:-1], original["inbounds"])
        self.assertFalse(deploy.ResumeState().path.exists())
