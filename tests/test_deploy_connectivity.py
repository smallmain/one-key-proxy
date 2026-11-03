import argparse
import contextlib
import copy
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

import test_deploy as fixtures
import deploy_connectivity as connectivity

deploy = fixtures.deploy


def node(identity=1, name="Node", **fields):
    return dict(ID=identity, Name=name, Link=fixtures.NODE["VLESS_URI"], DialerProxyName="", **fields)


class ProxyTests(unittest.TestCase):
    def test_request_forces_proxy_dns_and_disables_curl_configuration_and_bypass(self):
        with patch.object(connectivity.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"200 0.125")) as run:
            self.assertEqual(connectivity.probe_proxy(7896), (200, 125))
        command = run.call_args.args[0]
        self.assertEqual(command[:2], ["curl", "-q"])
        self.assertEqual(command[command.index("--proxy") + 1], "socks5h://127.0.0.1:7896")
        self.assertEqual(command[command.index("--noproxy") + 1], "")
        self.assertEqual(command[command.index("--url") + 1], "https://google.com/")
        self.assertNotIn("--insecure", command)
        self.assertEqual(run.call_args.kwargs["timeout"], connectivity.CHECK_TIMEOUT + 2)

    def test_http_failures_timeouts_and_proxy_errors_do_not_echo_process_output(self):
        for code, stdout in ((0, b"403 0.2"), (28, b"secret"), (97, b"secret"),
                             (0, b"bad response"), (0, b"200 nan")):
            with self.subTest(code=code, stdout=stdout), \
                    patch.object(connectivity.subprocess, "run", return_value=subprocess.CompletedProcess([], code, stdout, b"secret")), \
                    self.assertRaises(deploy.DeployError) as error:
                connectivity.probe_proxy(7896)
            self.assertNotIn("secret", str(error.exception))
        with patch.object(connectivity.subprocess, "run", side_effect=subprocess.TimeoutExpired([], 17)), \
                self.assertRaisesRegex(deploy.DeployError, "超时"):
            connectivity.probe_proxy(7896)

    def test_remote_checks_preserve_chained_relays_and_reality_hint(self):
        entry, middle, exit_node = node(1, "Entry"), node(2, "Middle"), node(3, "Exit")
        middle["DialerProxyName"], exit_node["DialerProxyName"] = "Entry", "Middle"
        exit_node["Link"] += "&support-x25519mlkem768=false"
        before = copy.deepcopy([entry, middle, exit_node])
        outbounds, final = connectivity.node_outbounds(exit_node, before)
        self.assertEqual(final, "check-3")
        self.assertEqual([item["tag"] for item in outbounds], ["check-1", "check-2", "check-3"])
        self.assertNotIn("detour", outbounds[0])
        self.assertEqual([item["detour"] for item in outbounds[1:]], ["check-1", "check-2"])
        self.assertEqual(before, [entry, middle, exit_node])

    def test_missing_ambiguous_cyclic_and_unsupported_relays_fail_without_direct_fallback(self):
        entry, exit_node = node(1, "Entry"), node(2, "Exit")
        exit_node["DialerProxyName"] = "Entry"
        for all_nodes in ([exit_node], [entry, node(3, "Entry"), exit_node],
                          [dict(entry, DialerProxyName="Exit"), exit_node]):
            with self.subTest(all_nodes=all_nodes), self.assertRaises(deploy.DeployError):
                connectivity.node_outbounds(exit_node, all_nodes)
        with self.assertRaises(deploy.DeployError):
            connectivity.node_outbounds(dict(entry, Link="trojan://secret@example.invalid:443"), [entry])

    def test_temporary_proxy_cleans_private_files_and_kills_stuck_process_after_probe_failure(self):
        process = Mock()
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired([], 3), 0]
        connection = Mock()
        connection.__enter__ = Mock(return_value=connection)
        connection.__exit__ = Mock(return_value=False)
        with patch.object(connectivity.shutil, "which", return_value="/bin/sing-box"), \
                patch.object(connectivity.subprocess, "Popen", return_value=process) as start, \
                patch.object(connectivity.socket, "create_connection", return_value=connection):
            with self.assertRaisesRegex(deploy.DeployError, "probe failed"):
                with connectivity.temporary_proxy({}, [{"type": "direct", "tag": "test"}], "test"):
                    path = Path(start.call_args.args[0][-1])
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                    self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
                    self.assertEqual(json.loads(path.read_text())["inbounds"][0]["listen"], "127.0.0.1")
                    raise deploy.DeployError("probe failed")
        process.terminate.assert_called_once()
        process.kill.assert_called_once()
        self.assertFalse(path.parent.exists())

    def test_startup_failure_cleans_files_and_does_not_run_probe(self):
        process = Mock()
        process.poll.return_value = 1
        with patch.object(connectivity.shutil, "which", return_value="/bin/sing-box"), \
                patch.object(connectivity.subprocess, "Popen", return_value=process) as start, \
                patch.object(connectivity, "probe_proxy") as probe, self.assertRaisesRegex(deploy.DeployError, "启动失败"):
            connectivity.probe_node({}, node(), [node()])
        self.assertFalse(Path(start.call_args.args[0][-1]).parent.exists())
        probe.assert_not_called()

    @unittest.skipUnless(shutil.which("sing-box"), "sing-box not installed")
    def test_real_singbox_accepts_generated_vless_client_and_closes_listener(self):
        outbounds, final = connectivity.node_outbounds(node(), [node()])
        with connectivity.temporary_proxy({}, outbounds, final) as port:
            with socket.create_connection(("127.0.0.1", port), timeout=1) as connection:
                connection.sendall(b"\x05\x01\x00")
                self.assertEqual(connection.recv(2), b"\x05\x00")
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", port), timeout=0.2)

    @unittest.skipUnless(all(shutil.which(name) for name in ("sing-box", "curl", "openssl")), "proxy integration tools not installed")
    def test_real_curl_and_singbox_can_complete_a_verified_https_request(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(204)
                self.end_headers()

            def log_message(self, *args):
                pass

        with tempfile.TemporaryDirectory() as directory:
            certificate, key = Path(directory) / "cert.pem", Path(directory) / "key.pem"
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                            "-keyout", str(key), "-out", str(certificate), "-days", "1",
                            "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=10, check=True)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(certificate, key)
            with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
                server.socket = context.wrap_socket(server.socket, server_side=True)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    with patch.object(connectivity, "CHECK_URL", f"https://localhost:{server.server_port}/"), \
                            patch.dict(os.environ, {"CURL_CA_BUNDLE": str(certificate), "NO_PROXY": "*"}), \
                            connectivity.temporary_proxy({}, [{"type": "direct", "tag": "test"}], "test") as port:
                        status, elapsed = connectivity.probe_proxy(port)
                    self.assertEqual(status, 204)
                    self.assertGreaterEqual(elapsed, 0)
                finally:
                    server.shutdown()
                    thread.join(timeout=2)

    def test_local_probe_rejects_missing_routes_and_pending_reload(self):
        inbound, outbound = deploy.SingBox.tags("a" * 32)
        metadata = {"inbound_tag": inbound, "outbound_tag": outbound, "needs_reload": False}
        record = {"singbox": metadata, "local_port": 7896}
        document = {"inbounds": [{"tag": inbound, "type": "socks", "listen": "127.0.0.1", "listen_port": 7896}],
                    "outbounds": [{"tag": outbound}], "route": {"rules": []}}
        with patch.object(connectivity, "SingBox") as box, patch.object(connectivity, "probe_proxy", return_value=(200, 12)) as probe:
            box.return_value.read.return_value = (b"", document)
            with self.assertRaisesRegex(deploy.DeployError, "路由缺失"):
                connectivity.probe_local({}, "a" * 32, record)
            probe.assert_not_called()
            document["route"]["rules"].append({"inbound": [inbound], "outbound": outbound})
            self.assertEqual(connectivity.probe_local({}, "a" * 32, record), (200, 12))
            probe.assert_called_once_with(7896)
            metadata["needs_reload"] = True
            with self.assertRaisesRegex(deploy.DeployError, "重载"):
                connectivity.probe_local({}, "a" * 32, record)


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for patcher in (patch.dict(sys.modules, {"deploy": deploy}), patch.object(deploy, "ROOT", self.root)):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.state = deploy.ResumeState()
        with self.state.locked():
            self.registry = deploy.ManagedDeployments(self.state)
        self.output = io.StringIO()

    def register(self, identity, **fields):
        self.registry.register(identity, "root@host", self.root / (identity + ".env"), fixtures.CONFIG["SUBLINKPRO_URL"], identity[:1])
        self.registry.update(identity, status="active", **fields)

    def test_menu_returns_without_touching_unfinished_deployment(self):
        with self.state.locked():
            self.state.start("install", self.root / ".env")
        before = self.state.path.read_bytes()
        with patch.object(deploy.sys.stdin, "isatty", return_value=True), \
                patch("builtins.input", side_effect=["7", "0"]), \
                patch.object(connectivity, "check_configurations") as check, \
                contextlib.redirect_stdout(self.output):
            deploy.main([])
        self.assertEqual(check.call_args.args[0].action, "check-connectivity")
        self.assertEqual(self.output.getvalue().count("One-Key-Proxy"), 2)
        self.assertEqual(before, self.state.path.read_bytes())

    def test_empty_inventory_needs_no_env_or_dependencies(self):
        with patch.object(deploy, "read_env") as read, patch.object(connectivity.shutil, "which", return_value=None), \
                contextlib.redirect_stdout(self.output):
            deploy.main(["check-connectivity"])
        self.assertIn("暂无受管配置", self.output.getvalue())
        read.assert_not_called()

    def test_every_subscription_node_is_checked_and_failures_do_not_stop_later_configurations(self):
        self.register("a" * 32, airport_id=11)
        self.register("b" * 32, remote_node_id=3)
        before = self.registry.path.read_bytes()
        remote_nodes = [[node(1, "First"), node(2, "Second")], [node(3, "Third")]]
        with patch.object(deploy, "read_env", return_value=fixtures.CONFIG) as read, \
                patch.object(deploy, "SublinkPro") as client, \
                patch.object(connectivity.shutil, "which", return_value="curl"), \
                patch.object(connectivity, "probe_node", side_effect=[deploy.DeployError("超时"), (200, 20), (200, 30)]) as probe, \
                contextlib.redirect_stdout(self.output), self.assertRaises(deploy.DeployError):
            client.return_value.url = fixtures.CONFIG["SUBLINKPRO_URL"]
            client.return_value.remote_nodes.side_effect = remote_nodes
            deploy.main(["check-connectivity"])
        self.assertEqual([call.args[1]["ID"] for call in probe.call_args_list], [1, 2, 3])
        self.assertEqual([call.args[0] for call in read.call_args_list], [str(self.root / (key + ".env")) for key in self.registry.records])
        self.assertIn("通过 2 项，失败 1 项", self.output.getvalue())
        self.assertEqual(before, self.registry.path.read_bytes())
        self.assertFalse(self.state.path.exists())

    def test_unreadable_env_and_missing_source_are_reported_without_stopping(self):
        self.register("a" * 32)
        self.register("b" * 32)
        with patch.object(deploy, "read_env", side_effect=[deploy.DeployError("missing env"), fixtures.CONFIG]), \
                patch.object(deploy, "SublinkPro") as client, \
                patch.object(connectivity.shutil, "which", return_value="curl"), \
                contextlib.redirect_stdout(self.output), self.assertRaises(deploy.DeployError):
            client.return_value.url = fixtures.CONFIG["SUBLINKPRO_URL"]
            client.return_value.remote_nodes.return_value = []
            deploy.main(["check-connectivity"])
        self.assertIn("missing env", self.output.getvalue())
        self.assertIn("暂无远端节点", self.output.getvalue())
        self.assertIn("失败 2 项", self.output.getvalue())

    def test_local_check_still_runs_when_api_fails_and_env_override_is_used(self):
        record = {"env_file": str(self.root / "original.env"), "sublink_url": fixtures.CONFIG["SUBLINKPRO_URL"],
                  "kind": "node", "node_name": "Test", "singbox": {"present": True}, "local_port": 7896}
        args = argparse.Namespace(env_file=self.root / "override.env")
        with patch.object(deploy, "ManagedDeployments") as registry, \
                patch.object(deploy, "read_env", return_value=fixtures.CONFIG) as read, \
                patch.object(deploy, "SublinkPro", side_effect=deploy.DeployError("API unavailable")), \
                patch.object(connectivity.shutil, "which", return_value="curl"), \
                patch.object(connectivity, "probe_local", return_value=(200, 10)) as local, \
                contextlib.redirect_stdout(self.output), self.assertRaises(deploy.DeployError):
            registry.return_value.records = {"a" * 32: record}
            connectivity.check_configurations(args, env_override=True)
        read.assert_called_once_with(args.env_file)
        local.assert_called_once_with(fixtures.CONFIG, "a" * 32, record)
        self.assertIn("通过 1 项，失败 1 项", self.output.getvalue())

    def test_cli_rejects_workflow_flags(self):
        for flags in (["--resume"], ["--fresh"], ["--no-sync"], ["--no-local-node"], ["node-name"],
                      ["--password"], ["--port", "22"], ["--residential"]):
            with self.subTest(flags=flags), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                deploy.main(["check-connectivity"] + flags)


if __name__ == "__main__":
    unittest.main()
