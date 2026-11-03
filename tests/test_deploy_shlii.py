import argparse
import base64
import contextlib
import copy
import http.cookiejar
import io
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch
import urllib.error

import test_deploy as fixtures
import deploy_shlii as shlii
import test_deploy_nodes as node_fixtures

deploy = fixtures.deploy
PRODUCT = {"version": 1, "account_id": "7", "account_name": "alice", "kind": "instance",
           "product_id": "42", "selection": {}}
LINK = fixtures.NODE["VLESS_URI"] + "#Hong%20Kong"
INSTANCE = {"id": 42, "name": "Hong Kong", "status": "running", "network_mode": "nat",
            "nat_public_ip": "203.0.113.8", "ssh_port": 22, "ssh_public_port": 12022,
            "port_range_start": 12000, "port_range_end": 12100, "port_limit": 10,
            "port_mappings": [{"protocol": "tcp", "privatePort": 22, "publicPort": 12022}]}


def options(**values):
    defaults = dict(action="add", target=None, source=None, subscription_url=None, port=None, identity=None,
                    password=False, auth_method=None, mode=None, domain=None, no_sync=False, name=None,
                    airport_name=None, create_local_node=None, local_port=None, relay=None, residential=None,
                    provider="shlii", provider_product=None, provider_ready=False, provider_update=False,
                    provider_defaults=None, provider_label=None, env_file=Path("/tmp/.env"), node_link=None,
                    adopt_node=None, part=None, resume=False,
                    insecure_subscription=None, supplied_fields=set())
    return argparse.Namespace(**(defaults | values))


class ShliiTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for patcher in (patch.dict(sys.modules, {"deploy": deploy}), patch.object(deploy, "ROOT", self.root),
                        patch.object(sys.stdin, "isatty", return_value=True)):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.state = deploy.ResumeState()
        with self.state.locked():
            self.state.start("add", self.root / ".env")
        self.store = shlii.Store(self.state)

    def client(self, identity="7"):
        client = shlii.Client(self.store)
        client.account.update(username="alice", password="private-password", account_id=identity, token="private-token")
        return client

    def registry(self, identity="a" * 32, kind="deployment"):
        registry = deploy.ManagedDeployments(self.state)
        registry.register(identity, "root@203.0.113.8", self.root / ".env", fixtures.CONFIG["SUBLINKPRO_URL"], "Keep", kind=kind)
        registry.update(identity, status="active", node_name="Keep", ssh={"target": "root@203.0.113.8",
                        "port": 12022, "password": True, "identity": None})
        return registry

    def test_menu_order_and_vps_preserves_original_fields(self):
        args = options(provider=None, create_local_node=False)
        output = io.StringIO()
        with patch("builtins.input", side_effect=["1", "root@host", "2222", "3"]), contextlib.redirect_stdout(output):
            deploy.configure_interactive(args, fixtures.CONFIG, self.state)
        self.assertEqual((args.source, args.target, args.port, args.auth_method), ("ssh", "root@host", 2222, "auto"))
        self.assertIn("  1. VPS\n  2. Shlii\n  3. 订阅地址\n  4. 节点链接\n  5. 稍后补全", output.getvalue())

    def test_install_menu_routes_shlii_without_ssh_prompts_for_ticket(self):
        args = options(action="install", provider=None)

        def prepared(args, config, checkpoint):
            args.action, args.source, args.node_link = "add", "node", LINK
            args.provider_ready = True

        output = io.StringIO()
        with patch("builtins.input", side_effect=["2"]) as prompt, patch.object(shlii, "configure", side_effect=prepared), \
                contextlib.redirect_stdout(output):
            deploy.configure_interactive(args, fixtures.CONFIG, self.state)
        self.assertEqual(prompt.call_count, 1)
        self.assertEqual((args.source, args.node_link), ("node", LINK))
        self.assertIn("  1. VPS\n  2. Shlii", output.getvalue())

    def test_account_replacement_is_only_after_success_and_identity_matches(self):
        old = self.client()
        old.authenticated = True
        old.persist()
        before = (self.state.directory / "shlii-account.json").read_bytes()
        new = self.client("8")
        new.account["username"] = "bob"
        with self.assertRaises(deploy.DeployError):
            new.accept_login({"token": "different-secret", "user": {"id": 8}}, expected="7")
        self.assertEqual((self.state.directory / "shlii-account.json").read_bytes(), before)
        new.accept_login({"token": "different-secret", "user": {"id": 8}})
        self.assertEqual(self.store.account()["username"], "bob")
        self.assertEqual((self.state.directory / "shlii-account.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(list(self.state.directory.glob("shlii-account*"))), 1)

    def test_refresh_cookie_survives_restart_with_path_and_security_attributes(self):
        client = self.client()
        client.cookies.set_cookie(http.cookiejar.Cookie(0, "refresh", "cookie-secret", None, False, "shlii.io", False,
                                 False, "/api/auth", True, True, None, False, None, None, {"HttpOnly": True}))
        client.authenticated = True
        client.persist()
        restored = shlii.Client(self.store, self.store.account())
        cookie = list(restored.cookies)[0]
        self.assertEqual((cookie.name, cookie.value, cookie.path, cookie.secure), ("refresh", "cookie-secret", "/api/auth", True))
        self.assertEqual(restored.account["device"]["deviceId"], client.account["device"]["deviceId"])

    def test_cookie_and_subscription_origins_are_restricted(self):
        client = self.client()
        with self.assertRaises(deploy.DeployError):
            client.import_cookies([{"domain": "evil.invalid", "value": "secret"}])
        for url in ("https://evil.invalid/sub", "http://shlii.io/sub", "https://shlii.io@evil.invalid/api/test"):
            with patch.object(client.opener, "open") as request, self.assertRaises(deploy.DeployError):
                client.raw(url, plain=True)
            request.assert_not_called()

    def test_http_request_uses_json_bearer_and_does_not_echo_error_body(self):
        client = self.client()
        with patch.object(client.opener, "open", return_value=io.BytesIO(b'{"instances": []}')) as request:
            result = client.raw("/api/instances/42/ports", method="POST", data={"protocol": "tcp", "privatePort": 443})
        wire = request.call_args.args[0]
        self.assertEqual(result, {"instances": []})
        self.assertEqual(wire.get_header("Authorization"), "Bearer private-token")
        self.assertEqual(wire.get_header("Content-type"), "application/json")
        self.assertEqual(json.loads(wire.data), {"protocol": "tcp", "privatePort": 443})
        error = urllib.error.HTTPError(wire.full_url, 403, "private-password", {}, io.BytesIO(
            b'{"code":"DENIED","message":"private-password"}'))
        with patch.object(client.opener, "open", side_effect=error), self.assertRaises(shlii.ShliiError) as raised:
            client.raw("/api/instances")
        self.assertNotIn("private-password", str(raised.exception))

    def test_browser_helper_transfers_credentials_only_over_stdin(self):
        import deploy_shlii_browser as browser
        client = self.client()

        def finish(command, **kwargs):
            child = shlii.Client(self.store, json.loads(kwargs["input"])["account"])
            child.accept_login({"token": "browser-token", "user": {"id": 7}}, "7")
            return Mock(returncode=0)

        with patch.object(Path, "is_file", return_value=True), patch.object(browser.subprocess, "run", side_effect=finish) as run:
            browser.run_browser_helper(client, "7")
        self.assertNotIn("private-password", " ".join(run.call_args.args[0]))
        self.assertNotIn("env", run.call_args.kwargs)
        self.assertEqual(client.account["token"], "browser-token")
        self.assertTrue(client.authenticated)

    def test_product_list_marks_unsupported_protocol_and_ipv6_instances_unavailable(self):
        self.assertIn("tuic", shlii.unavailable({"plan": {"endpoint": {"protocol": "tuic"}}}, "ticket"))
        self.assertEqual(shlii.unavailable({"plan": {"protocols": ["tuic", "vless"]}}, "ticket"), "")
        self.assertEqual(shlii.unavailable({"plan": {"protocols": ["shadowsocks_aes_256_gcm", "vless_tcp_reality_vision"]}}, "ticket"), "")
        self.assertIn("IPv6", shlii.unavailable({"network_mode": "ipv6_only"}, "instance"))

    def test_native_browser_attaches_only_after_user_completed_login(self):
        import deploy_shlii_browser as browser
        events = []
        playwright = Mock()
        playwright.chromium.connect_over_cdp.side_effect = lambda *a, **kw: events.append("attach") or Mock()
        module = types.ModuleType("playwright.sync_api")
        module.Error = type("BrowserError", (Exception,), {})
        module.sync_playwright = lambda: contextlib.nullcontext(playwright)
        process = Mock()
        process.poll.return_value = None
        with patch.dict(sys.modules, {"playwright": types.ModuleType("playwright"), "playwright.sync_api": module}), \
                patch.object(browser, "browser_path", return_value="/path/to/chrome"), \
                patch.object(browser, "wait_for_login", side_effect=lambda: events.append("user-confirmed")), \
                patch.object(browser, "capture_session", side_effect=lambda *a: events.append("captured")), \
                patch.object(browser.subprocess, "Popen", return_value=process) as launch:
            browser.login_in_browser(self.client(), "7")
        self.assertEqual(events, ["user-confirmed", "attach", "captured"])
        command = launch.call_args.args[0]
        self.assertNotIn("--enable-automation", command)
        self.assertTrue(any(v.startswith("--user-data-dir=") for v in command))
        self.assertNotIn("--remote-debugging-port=0", command)
        process.terminate.assert_called_once()

    def test_browser_session_preserves_device_cookie_path_and_canonical_account(self):
        import deploy_shlii_browser as browser
        client = self.client()
        page = Mock(url=shlii.BASE + "/dashboard")
        device_id = "00000000-0000-4000-8000-000000000007"
        page.evaluate.side_effect = [{"deviceId": device_id, "userAgent": "test-browser", "language": "zh-CN", "timezone": "Asia/Shanghai"},
                                    {"status": 200, "payload": {"token": "browser-token", "user": {"id": 7, "username": "alice"}}}]
        context = Mock(pages=[page])
        context.cookies.return_value = [{"name": "refresh", "value": "private-cookie", "domain": "shlii.io", "path": "/api/auth",
                                        "secure": True, "expires": -1, "httpOnly": True, "sameSite": "Lax"}]
        browser.capture_session(client, Mock(contexts=[context]), "7")
        saved = self.store.account()
        self.assertEqual(saved["device"]["deviceId"], device_id)
        self.assertEqual(saved["password"], "private-password")
        self.assertEqual(saved["cookies"][0]["path"], "/api/auth")
        self.assertEqual(saved["device"]["userAgent"], "test-browser")

    def test_browser_login_for_different_account_does_not_save_previous_password(self):
        import deploy_shlii_browser as browser
        client = self.client()
        page = Mock(url=shlii.BASE + "/dashboard")
        page.evaluate.side_effect = [{"deviceId": client.account["device"]["deviceId"]},
                                    {"status": 200, "payload": {"token": "browser-token", "user": {"id": 8, "username": "bob"}}}]
        context = Mock(pages=[page])
        context.cookies.return_value = []
        browser.capture_session(client, Mock(contexts=[context]), None)
        self.assertEqual(self.store.account()["username"], "bob")
        self.assertEqual(self.store.account()["password"], "")

    def test_login_handles_real_two_factor_code_without_persisting_it(self):
        client = self.client("")
        response = {"token": "new-token", "user": {"id": 7}}
        with patch.object(client, "raw", side_effect=[shlii.ShliiError(401, {"code": "TWO_FA_REQUIRED"}), response]) as request, \
                patch("builtins.input", return_value="123456"):
            client.login()
        self.assertEqual(request.call_args.kwargs["data"]["totpCode"], "123456")
        self.assertNotIn("123456", (self.state.directory / "shlii-account.json").read_text())

    def test_new_device_challenge_sends_then_replays_login(self):
        client = self.client("")
        challenge = {"code": "NEW_DEVICE_VERIFICATION_REQUIRED", "deviceChallengeToken": "private-challenge",
                     "verificationMethods": [{"method": "email"}]}
        with patch.object(client, "raw", side_effect=[shlii.ShliiError(403, challenge), {"verificationSent": True},
                         {"token": "new-token", "user": {"id": 7}}]) as request, \
                patch("builtins.input", return_value="654321"):
            client.login()
        self.assertEqual(request.call_args_list[1].args[0], "/api/auth/login-device-challenge")
        self.assertEqual(request.call_args.kwargs["data"]["deviceVerificationCode"], "654321")
        self.assertNotIn("private-challenge", (self.state.directory / "shlii-account.json").read_text())

    def test_turnstile_hands_off_to_browser_and_401_only_retries_once(self):
        client = self.client("")
        with patch.object(client, "raw", side_effect=shlii.ShliiError(400, {"code": "TURNSTILE_TOKEN_MISSING"})), \
                patch("builtins.input", return_value="y"), patch("deploy_shlii_browser.login_in_browser") as browser:
            client.login()
        browser.assert_called_once()
        with patch.object(client, "raw", side_effect=[shlii.ShliiError(401), {"instances": []}]) as raw, \
                patch.object(client, "authenticate") as auth:
            self.assertEqual(client.request("/api/instances"), {"instances": []})
        self.assertEqual(raw.call_count, 2)
        auth.assert_called_once()

    def test_instances_fetch_all_pages_without_returning_partial_results(self):
        client = self.client()
        with patch.object(client, "request", side_effect=[{"instances": [{"id": 1}], "totalPages": 2},
                          {"instances": [{"id": 2}], "totalPages": 2}]) as request:
            self.assertEqual([v["id"] for v in client.instances()], [1, 2])
        self.assertIn("page=2&pageSize=100", request.call_args.args[0])

    def test_mapping_creation_is_confirmed_and_resumes_without_duplicates(self):
        instance = copy.deepcopy(INSTANCE)
        client = Mock()
        client.instance.side_effect = lambda identity: copy.deepcopy(instance)

        def create(path, **kwargs):
            data = kwargs["data"]
            instance["port_mappings"].append({"protocol": "tcp", "privatePort": data["privatePort"], "publicPort": data["publicPort"]})
            if data["privatePort"] == 443:
                raise deploy.DeployError("lost response")
            return {"mapping": data}

        client.request.side_effect = create
        with patch("builtins.input", return_value="n"), contextlib.redirect_stdout(io.StringIO()), self.assertRaises(deploy.DeployError):
            shlii.prepare_ports(client, PRODUCT, instance, self.state)
        client.request.assert_not_called()
        with patch("builtins.input", return_value="y"), contextlib.redirect_stdout(io.StringIO()):
            result = shlii.prepare_ports(client, PRODUCT, instance, self.state)
            shlii.prepare_ports(client, PRODUCT, result, self.state)
        self.assertEqual(client.request.call_count, 3)
        self.assertEqual(len(instance["port_mappings"]), 4)
        self.assertEqual(shlii.mapped_port(result, 22), 12022)

    def test_mapping_limits_and_private_ssh_conflicts_do_not_change_existing_ports(self):
        limited = dict(INSTANCE, port_limit=2)
        client = Mock()
        with self.assertRaises(deploy.DeployError):
            shlii.prepare_ports(client, PRODUCT, limited, self.state)
        client.request.assert_not_called()
        self.assertEqual(shlii.install_ports(dict(INSTANCE, ssh_port=443))[1][2], 444)

    def test_instance_prefills_ipv4_nat_and_password_without_public_mode_guess(self):
        instance = copy.deepcopy(INSTANCE)
        instance["port_mappings"] += [{"protocol": "tcp", "private_port": v, "public_port": p}
                                      for v, p in ((2053, 12000), (443, 12001), (2096, 12002))]
        client = Mock()
        client.instance.return_value = instance
        client.request.return_value = {"rootPassword": "root-secret"}
        result = shlii.instance_input(client, PRODUCT, True, self.state)
        self.assertEqual((result["target"], result["port"], result["mode"]), ("root@203.0.113.8", 12022, "nat"))
        self.assertEqual(result["defaults"]["OKP_NODE_MAP"], "12001:443")
        self.assertEqual(result["password"], "root-secret")
        client.instance.return_value = dict(instance, network_mode="ipv6_only")
        with self.assertRaises(deploy.DeployError):
            shlii.instance_input(client, PRODUCT, True, self.state)

    def ticket_client(self, links, ipv6_links=None):
        client = Mock()

        def request(path, **kwargs):
            if path.endswith("/subscription/reveal"):
                paths = {"ipv4": {"v2raynPath": "/api/airport/sub/private-token"}}
                if ipv6_links is not None:
                    paths["ipv6"] = {"v2raynPath": "/api/airport/sub/private-ipv6-token"}
                return {"subscription": {"paths": paths}}
            if path.endswith("/subscription"):
                return {"subscription": {"usable": True}}
            if path.endswith("/multi-exit"):
                return {"eligible": False, "variants": []}
            if path.endswith("private-ipv6-token"):
                return base64.b64encode("\n".join(ipv6_links).encode())
            if path.endswith("private-token"):
                return base64.b64encode("\n".join(links).encode())
            return {"ticket": {"id": 42, "status": "active", "forwardingAllocations": []}}

        client.request.side_effect = request
        return client

    def test_shadowsocks_ticket_has_usable_ipv4_and_ipv6_entries_without_query(self):
        userinfo = base64.urlsafe_b64encode(b"aes-256-gcm:private-password").decode().rstrip("=")
        ipv4 = "ss://" + userinfo + "@203.0.113.8:443#Wave"
        ipv6 = "ss://" + userinfo + "@[2001:db8::1]:443#Wave"
        entries = shlii.ticket_links(self.ticket_client([ipv4], [ipv6]), dict(PRODUCT, kind="ticket"))
        self.assertEqual(len(entries), 2)
        self.assertEqual([value[0]["family"] for _, value in entries], ["ipv4", "ipv6"])
        for _, (_, raw) in entries:
            outbound = shlii.parse_node_link(raw).outbound()
            self.assertEqual((outbound["type"], outbound["method"]), ("shadowsocks", "aes-256-gcm"))

    def test_ticket_errors_distinguish_malformed_links_from_unsupported_protocols(self):
        entries = shlii.ticket_links(self.ticket_client(["ss://private-secret", "tuic://private-secret"]),
                                    dict(PRODUCT, kind="ticket"))
        self.assertTrue(all(value is None for _, value in entries))
        self.assertIn("链接格式无效（ss）", entries[0][0])
        self.assertIn("暂不支持协议（tuic）", entries[1][0])
        self.assertNotIn("private-secret", repr(entries))

    def test_ticket_selection_survives_reorder_and_connection_changes(self):
        product = dict(PRODUCT, kind="ticket")
        second = LINK.replace("example.invalid", "second.invalid").replace("Hong%20Kong", "Japan")
        client = self.ticket_client([LINK, second, "tuic://unsupported"])
        with patch("builtins.input", return_value="2"), contextlib.redirect_stdout(io.StringIO()):
            selected, link = shlii.select_ticket_link(client, product)
        self.assertEqual(link, second)
        product["selection"] = selected
        changed = second.replace("second.invalid", "new.invalid")
        client = self.ticket_client([changed, LINK])
        self.assertEqual(shlii.select_ticket_link(client, product)[1], changed)
        with self.assertRaises(deploy.DeployError):
            shlii.select_ticket_link(self.ticket_client([LINK]), product)

    def test_unavailable_ticket_does_not_reveal_or_mutate_configuration(self):
        client = Mock()
        client.request.side_effect = [{"ticket": {"status": "active"}}, {"subscription": {"usable": False}}]
        with self.assertRaises(deploy.DeployError):
            shlii.ticket_links(client, dict(PRODUCT, kind="ticket"))
        self.assertEqual(client.request.call_count, 2)

    def test_product_association_deduplicates_by_account_product_and_entry(self):
        registry = self.registry()
        self.store.save_product("a" * 32, PRODUCT)
        self.assertEqual(self.store.find(PRODUCT, registry), "a" * 32)
        self.assertIsNone(self.store.find(dict(PRODUCT, account_id="8"), registry))
        self.state.capture(provider="shlii", provider_product=json.dumps(PRODUCT), provider_ready=True)
        self.state.phase("sync", "a" * 32)
        shlii.bind(self.state)
        registry.forget("a" * 32)
        self.assertIsNone(self.store.product("a" * 32))

    def test_resume_accepts_provider_metadata_but_rejects_arbitrary_remote_defaults(self):
        self.state.capture(provider="shlii", provider_product=json.dumps(PRODUCT), provider_defaults=json.dumps({"OKP_NODE_MAP": "12001:443"}))
        self.assertEqual(deploy.ResumeState().load()["options"]["provider"], "shlii")
        with self.assertRaises(deploy.DeployError):
            self.state.capture(provider_defaults=json.dumps({"SUBLINKPRO_API_KEY": "private"}))

    def test_new_instance_import_persists_product_and_ssh_password_for_resume(self):
        args = options()
        client = Mock()
        result = {"target": "root@203.0.113.8", "port": 12022, "mode": "nat", "password": "root-secret",
                  "defaults": {"OKP_PUBLIC_IPV4": "203.0.113.8"}, "label": "Hong Kong"}
        with patch.object(shlii, "account_client", return_value=client), patch.object(shlii, "select_product", return_value=copy.deepcopy(PRODUCT)), \
                patch.object(shlii, "instance_input", return_value=result):
            shlii.configure(args, fixtures.CONFIG, self.state)
        self.assertEqual(args.target, result["target"])
        self.assertEqual(self.store.ssh(args.target, args.port), "root-secret")
        self.assertNotIn("root-secret", self.state.path.read_text())
        saved = deploy.ResumeState().load()["options"]
        self.assertTrue(saved["provider_ready"])
        self.assertEqual(saved["provider_label"], "Hong Kong")

    def test_update_cancel_keeps_existing_ssh_password_and_metadata(self):
        self.registry()
        self.store.save_product("a" * 32, PRODUCT)
        self.store.save_ssh("root@203.0.113.8", 12022, "old-root-secret")
        args = options(provider_product=json.dumps(PRODUCT))
        with patch.object(shlii, "account_client"), patch.object(shlii, "instance_input", return_value={
                "target": "root@203.0.113.8", "port": 12022, "mode": "nat", "defaults": {}, "password": "new-root-secret", "label": "Changed"}), \
                patch("builtins.input", return_value="n"), contextlib.redirect_stdout(io.StringIO()), self.assertRaises(deploy.DeployError):
            shlii.configure(args, fixtures.CONFIG, self.state)
        self.assertEqual(self.store.ssh("root@203.0.113.8", 12022), "old-root-secret")
        self.assertEqual(deploy.ManagedDeployments(self.state).records["a" * 32]["node_name"], "Keep")

    def test_uninstalled_instance_add_returns_without_install_or_registry(self):
        args = options(target="root@203.0.113.8", source="ssh", provider_ready=True, create_local_node=False,
                       password=False, mode="nat", residential=False, env_file=self.root / ".env", provider_product=json.dumps(PRODUCT))
        args.airport_name, args.name = "Airport", "Node"
        with patch.object(deploy, "read_env", return_value=fixtures.CONFIG), patch.object(deploy, "SSH") as ssh, \
                patch.object(deploy, "configure_resource_names", return_value=None), patch.object(deploy, "export_node",
                side_effect=deploy.SSHExportError("missing state", 104)), patch.object(deploy, "install") as install, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            deploy.run_workflow(args, Mock(), False, self.state)
        install.assert_not_called()
        self.assertFalse(self.state.path.exists())
        self.assertIn("安装配置 → Shlii", output.getvalue())

    def test_stale_nat_address_uses_original_reconfiguration_before_local_sync(self):
        args = options(provider_product=json.dumps(PRODUCT))
        self.state.phase("sync", "a" * 32)
        current = dict(fixtures.NODE, VLESS_URI=LINK.replace("example.invalid", "203.0.113.7"),
                       SUBSCRIPTION_URL="https://203.0.113.7:56666/sub/private-sub-id")
        updated = {k: v.replace("203.0.113.7", "203.0.113.8") for k, v in current.items()}
        client = Mock()
        client.instance.return_value = dict(INSTANCE, port_mappings=[])
        with patch.object(shlii, "account_client", return_value=client), patch.object(deploy, "export_node", return_value=updated), \
                contextlib.redirect_stdout(io.StringIO()):
            ssh = Mock()
            result = shlii.ensure_export(args, self.state, ssh, current)
        ssh.run.assert_called_once_with("/usr/local/bin/one-key-proxy reconfigure address", interactive=True)
        self.assertEqual(result, updated)

    def test_errors_never_echo_server_secrets(self):
        error = shlii.ShliiError(403, {"code": "DENIED", "error": "private-password", "token": "private-token"})
        self.assertNotIn("private-", str(error))
        self.assertIn("DENIED", str(error))


class ImportWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.fixture = node_fixtures.NodeWorkflowTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        patcher = patch.dict(sys.modules, {"deploy": deploy})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.product = dict(PRODUCT, kind="ticket", selection={"kind": "main", "family": "ipv4", "key": "selected"})
        self.client = Mock()

    def import_ticket(self, args, answers, link=LINK):
        with patch.object(shlii, "account_client", return_value=self.client), \
                patch.object(shlii, "select_product", return_value=copy.deepcopy(self.product)), \
                patch.object(shlii, "select_ticket_link", return_value=(self.product["selection"], link)):
            self.fixture.cli(args, answers)

    def test_ticket_import_and_manual_refresh_keep_ids_names_tags_and_local_credentials(self):
        self.import_ticket(["add", "--interactive"], ["2", "Saved name", "y", "y", "7900", "1"])
        identity, before = self.fixture.record("Saved name")
        before_config = json.loads(self.fixture.path.read_text())
        original_local = copy.deepcopy(self.fixture.node(before["local_node_id"]))
        self.assertEqual(shlii.Store(deploy.ResumeState()).product(identity), self.product)
        changed = LINK.replace("example.invalid", "new.invalid")
        self.import_ticket(["shlii-update", identity], ["y"], changed)
        current = self.fixture.registry().records[identity]
        self.assertEqual(current["remote_node_id"], before["remote_node_id"])
        self.assertEqual(current["local_node_id"], before["local_node_id"])
        self.assertEqual(current["node_name"], "Saved name")
        self.assertEqual(current["local_port"], 7900)
        self.assertTrue(current["residential"])
        self.assertEqual(self.fixture.node(current["local_node_id"])["Link"], original_local["Link"])
        self.assertIn("new.invalid", self.fixture.node(current["remote_node_id"])["Link"])
        self.assertEqual(len(self.fixture.registry().records), 1)
        self.assertFalse(deploy.ResumeState(node_id=identity).path.exists())
        self.assertEqual(before_config["inbounds"], json.loads(self.fixture.path.read_text())["inbounds"])

    def test_duplicate_product_with_changed_link_updates_existing_node(self):
        self.import_ticket(["add", "--interactive"], ["2", "Saved name", "n", "n"])
        identity, before = self.fixture.record("Saved name")
        self.import_ticket(["add", "--interactive"], ["2", "y"], LINK.replace("example.invalid", "new.invalid"))
        self.assertEqual(len(self.fixture.registry().records), 1)
        self.assertEqual(self.fixture.record("Saved name")[0], identity)
        self.assertEqual(self.fixture.record("Saved name")[1]["remote_node_id"], before["remote_node_id"])

    def test_interrupted_update_resumes_original_link_without_refetching_provider(self):
        self.import_ticket(["add", "--interactive"], ["2", "Saved name", "n", "n"])
        identity, before = self.fixture.record("Saved name")
        self.fixture.server.state["fail_remote_once"] = True
        with self.assertRaises(deploy.DeployError):
            self.import_ticket(["shlii-update", identity], ["y"], LINK.replace("example.invalid", "new.invalid"))
        with patch.object(shlii, "account_client") as account:
            self.fixture.cli(["edit", identity, "--resume"])
        account.assert_not_called()
        self.assertEqual(self.fixture.registry().records[identity]["status"], "active")
        self.assertEqual(self.fixture.registry().records[identity]["remote_node_id"], before["remote_node_id"])
        self.assertEqual(shlii.Store(deploy.ResumeState()).product(identity), self.product)


if __name__ == "__main__":
    unittest.main()
