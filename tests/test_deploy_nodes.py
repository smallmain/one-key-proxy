import base64
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import test_deploy as fixtures
from test_deploy_resources import sample_config
from deploy_links import parse_node_link
from deploy_nodes import NodeManager
from deploy_resources import atomic_write, is_standalone

deploy = fixtures.deploy
VLESS = fixtures.NODE["VLESS_URI"] + "#Remote"
SOCKS = "socks5://test-user:test-password@home.example:26193#Home"
SS = "ss://" + base64.urlsafe_b64encode(b"aes-128-gcm:remote-secret").decode().rstrip("=") + "@ss.example:443#SS"


class NodeLinkTests(unittest.TestCase):
    def test_identity_ignores_fragment_query_order_and_defaults(self):
        first = parse_node_link(VLESS)
        second = parse_node_link(VLESS.replace("type=tcp", "type=raw").replace("#Remote", "#Renamed"))
        self.assertEqual(first.fingerprint, second.fingerprint)
        plain = "vless://00000000-0000-4000-8000-000000000001@EXAMPLE.invalid:443"
        self.assertEqual(parse_node_link(plain).fingerprint,
                         parse_node_link(plain + "?security=none&type=tcp&encryption=none").fingerprint)
        self.assertNotEqual(first.fingerprint, parse_node_link(VLESS.replace(":443", ":8443")).fingerprint)

    def test_shadowsocks_formats_and_percent_encoded_credentials(self):
        encoded = parse_node_link(SS)
        plain = parse_node_link("ss://aes-128-gcm:remote-secret@ss.example:443")
        legacy = parse_node_link("ss://" + base64.urlsafe_b64encode(b"aes-128-gcm:remote-secret@ss.example:443").decode())
        self.assertEqual(encoded.fingerprint, plain.fingerprint)
        self.assertEqual(encoded.fingerprint, legacy.fingerprint)
        special = parse_node_link("socks5://user%40name:pass%3Aword%23x@[2001:db8::1]:1080#IPv6")
        self.assertEqual(special.outbound()["username"], "user@name")
        self.assertEqual(special.outbound()["password"], "pass:word#x")
        self.assertEqual(special.host, "2001:db8::1")
        self.assertEqual(parse_node_link(special.marked("a" * 32)).fingerprint, special.fingerprint)

    def test_supported_local_transports_preserve_parameters(self):
        reality = parse_node_link(VLESS).outbound()
        self.assertEqual(reality["flow"], "xtls-rprx-vision")
        self.assertTrue(reality["tls"]["reality"]["enabled"])
        prefix = "vless://00000000-0000-4000-8000-000000000001@example.invalid:443"
        ws = parse_node_link(prefix + "?security=tls&type=ws&sni=tls.example&host=ws.example&path=%2Fproxy&alpn=h2,http%2F1.1").outbound()
        self.assertEqual(ws["transport"], {"type": "ws", "path": "/proxy", "headers": {"Host": "ws.example"}})
        self.assertEqual(ws["tls"]["alpn"], ["h2", "http/1.1"])
        grpc = parse_node_link(prefix + "?security=tls&type=grpc&serviceName=proxy").outbound()
        self.assertEqual(grpc["transport"]["service_name"], "proxy")
        self.assertEqual(parse_node_link(SOCKS).outbound()["type"], "socks")
        self.assertEqual(parse_node_link(SS).outbound()["type"], "shadowsocks")

    def test_unsupported_local_parameters_are_not_silently_dropped(self):
        for value in (VLESS.replace("#Remote", "&unknown=secret#Remote"),
                      VLESS.replace("type=tcp", "type=xhttp"),
                      SS.replace("#SS", "?plugin=obfs-local#SS")):
            link = parse_node_link(value)
            with self.assertRaises(deploy.DeployError):
                link.outbound()
            self.assertEqual(len(link.fingerprint), 64)

    def test_invalid_links_do_not_echo_credentials(self):
        for link in ("https://private-secret.example", "vless://private-secret@host:443", "socks5://u:private-secret@host:0",
                     "socks5://u:private-secret@host:65536", "socks5://u:private-secret@host:80?extra=x",
                     "socks5://u:private-secret%ZZ@host:80", VLESS + "\n" + SOCKS,
                     VLESS.replace("#Remote", "&security=tls#Remote"), SS.replace("ss.example", "bad%0Ahost")):
            with self.subTest(link=link), self.assertRaises(deploy.DeployError) as error:
                parse_node_link(link)
            self.assertNotIn("private-secret", str(error.exception))


class NodeWorkflowTests(unittest.TestCase):
    cleanup = fixtures.SublinkTests.cleanup

    def setUp(self):
        fixtures.SublinkTests.setUp(self)
        self.path = deploy.ROOT / "singbox.json"
        self.original = sample_config()
        atomic_write(self.path, json.dumps(self.original).encode())
        self.config = dict(fixtures.CONFIG, ENABLE_LOCAL_NODE="false", SINGBOX_CONFIG=str(self.path),
                           SINGBOX_BINARY=sys.executable, SINGBOX_SERVICE_LABEL="test.singbox")
        original_init = deploy.SublinkPro.__init__

        def initialize(client, config, **kwargs):
            original_init(client, config, **kwargs)
            client.url = self.client.url

        self.reload = None
        for patcher in (patch.object(deploy, "read_env", side_effect=lambda _: self.config.copy()),
                        patch.object(deploy.SublinkPro, "__init__", initialize),
                        patch.object(sys, "platform", "darwin"), patch.object(deploy.SingBox, "check_payload"),
                        patch.object(deploy.SingBox, "reload")):
            value = patcher.start()
            self.addCleanup(patcher.stop)
            self.reload = value

    def cli(self, args, answers=None):
        with patch.object(deploy.sys.stdin, "isatty", return_value=answers is not None), \
                patch("builtins.input", side_effect=answers or AssertionError("unexpected prompt")), \
                patch.object(deploy, "SSH") as ssh, contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            deploy.main(args)
        ssh.assert_not_called()

    def registry(self):
        return deploy.ManagedDeployments(deploy.ResumeState())

    def record(self, name="Remote"):
        registry = self.registry()
        identity = registry.select(name)
        return identity, registry.records[identity]

    def node(self, node_id):
        return next(n for n in self.server.state["nodes"] if n["ID"] == node_id)

    def add(self, name="Remote", link=VLESS, port=None, extra=()):
        self.cli(["add", "--node-link", link, "--node-name", name] +
                 (["--local-port", str(port)] if port else ["--no-local-node"]) + list(extra))
        return self.record(name)

    def test_add_and_duplicate_keep_one_remote_node_without_airport(self):
        identity, record = self.add()
        self.cli(["add", VLESS.replace("#Remote", "#Different"), "--no-local-node"])
        repeated_id, repeated = self.record()
        self.assertEqual(identity, repeated_id)
        self.assertEqual(record["remote_node_id"], repeated["remote_node_id"])
        self.assertIsNone(repeated["airport_id"])
        self.assertEqual(repeated["airport_name"], "")
        self.assertEqual(repeated["kind"], "node")
        self.assertEqual(len(self.server.state["nodes"]), 1)
        self.assertFalse(any("/airports" in path for _, path, _, _ in self.server.state["calls"]))
        self.assertNotIn(VLESS.split("@", 1)[0], json.dumps(repeated))
        self.assertFalse(deploy.ResumeState().path.exists())

    def test_matching_local_credentials_and_protocol_specific_outbound(self):
        _, record = self.add("SS", SS, 7900)
        local = self.node(record["local_node_id"])
        port, method, password = deploy.SingBox.ss_parameters(local["Link"])
        document = json.loads(self.path.read_text())
        inbound, outbound = document["inbounds"][-1], document["outbounds"][-1]
        self.assertEqual((inbound["listen_port"], inbound["method"], inbound["password"]), (port, method, password))
        self.assertEqual((outbound["type"], outbound["password"]), ("shadowsocks", "remote-secret"))
        self.assertEqual(outbound["tag"], "ss-SS-out")
        self.assertNotIn("remote-secret", json.dumps(record))

    def test_edit_link_and_names_retains_ids_and_local_password(self):
        identity, before = self.add(port=7900)
        local_password = deploy.SingBox.ss_parameters(self.node(before["local_node_id"])["Link"])[2]
        self.cli(["edit", identity, "--node-link", VLESS.replace("example.invalid", "new.example"), "--name", "Renamed"])
        _, after = self.record("Renamed")
        self.assertEqual((before["remote_node_id"], before["local_node_id"]), (after["remote_node_id"], after["local_node_id"]))
        self.assertEqual(self.node(after["remote_node_id"])["Name"], "[SM]Renamed")
        self.assertEqual(self.node(after["local_node_id"])["Name"], "[SM]Renamed - 本地")
        self.assertEqual(deploy.SingBox.ss_parameters(self.node(after["local_node_id"])["Link"])[2], local_password)
        self.assertEqual(json.loads(self.path.read_text())["outbounds"][-1]["server"], "new.example")
        self.assertEqual(before["singbox"]["outbound_tag"], after["singbox"]["outbound_tag"])

    def test_independent_local_outbound_survives_remote_changes(self):
        identity, _ = self.add("Home", VLESS, 7900, ["--local-link", SOCKS])
        self.cli(["edit", identity, "--node-link", VLESS.replace("example.invalid", "new.example")])
        _, record = self.record("Home")
        outbound = json.loads(self.path.read_text())["outbounds"][-1]
        self.assertEqual((outbound["type"], outbound["server"], outbound["server_port"]), ("socks", "home.example", 26193))
        self.assertEqual(record["local_source"], "custom")
        self.cli(["edit", identity, "--same-local"])
        self.assertEqual(json.loads(self.path.read_text())["outbounds"][-1]["server"], "new.example")
        self.assertEqual(self.record("Home")[1]["local_source"], "remote")

    def test_disable_removes_only_local_resources_and_can_reenable(self):
        identity, before = self.add(port=7900)
        self.cli(["edit", identity, "--no-local-node"], ["y"])
        record = self.record()[1]
        self.assertIsNone(record["local_node_id"])
        self.assertIsNone(record["singbox"])
        self.assertIsNone(record["local_port"])
        self.assertEqual(record["remote_node_id"], before["remote_node_id"])
        self.assertEqual(json.loads(self.path.read_text()), self.original)
        self.cli(["edit", identity, "--local-port", "7901"])
        self.assertEqual(self.record()[1]["local_port"], 7901)

    def test_add_no_local_node_keeps_existing_local_resources(self):
        _, before = self.add(port=7900)
        raw = self.path.read_bytes()
        self.cli(["add", VLESS, "--no-local-node"])
        after = self.record()[1]
        self.assertEqual(before["local_node_id"], after["local_node_id"])
        self.assertEqual(self.path.read_bytes(), raw)

    def test_relay_rename_updates_dependents_and_prevents_parent_delete(self):
        parent_id, parent = self.add("Parent", SOCKS, 7901)
        child_id, child = self.add("Child", VLESS, 7902, ["--via", parent_id])
        self.assertEqual(self.node(child["remote_node_id"])["DialerProxyName"], "[SM]Parent")
        self.assertEqual(json.loads(self.path.read_text())["outbounds"][-1]["detour"], parent["singbox"]["outbound_tag"])
        self.cli(["edit", parent_id, "--name", "Upstream"])
        self.assertEqual(self.node(child["remote_node_id"])["DialerProxyName"], "[SM]Upstream")
        with self.assertRaises(deploy.DeployError):
            self.cli(["remove", parent_id], ["y"])
        with self.assertRaises(deploy.DeployError):
            self.cli(["edit", parent_id, "--via", child_id])

    def test_uncertain_remote_write_is_reconciled_with_same_id(self):
        self.server.state["fail_remote_once"] = True
        with self.assertRaises(deploy.DeployError):
            self.add(port=7900)
        pending = deploy.ResumeState().load()
        identity = pending["installation_id"]
        self.assertEqual(self.registry().records[identity]["status"], "updating")
        self.assertEqual(deploy.ResumeState().path.stat().st_mode & 0o777, 0o600)
        self.cli(["--resume"])
        self.assertEqual(self.record()[0], identity)
        self.assertEqual(len(self.server.state["nodes"]), 2)
        self.assertFalse(list(deploy.ResumeState().directory.glob("node-change-*.json")))

    def test_reload_failure_rolls_back_and_resume_finishes(self):
        self.reload.side_effect = [deploy.DeployError("reload failed"), None]
        with self.assertRaises(deploy.DeployError):
            self.add(port=7900)
        self.assertEqual(json.loads(self.path.read_text()), self.original)
        self.reload.side_effect = None
        self.cli(["--resume"])
        self.assertEqual(self.record()[1]["status"], "active")
        self.assertEqual(len(json.loads(self.path.read_text())["inbounds"]), 3)

    def test_new_parameters_cannot_replace_an_inflight_transaction(self):
        self.server.state["fail_remote_once"] = True
        with self.assertRaises(deploy.DeployError):
            self.add()
        with self.assertRaises(deploy.DeployError):
            self.cli(["--resume", "--name", "Unapplied"])
        self.assertEqual(deploy.ResumeState().load()["options"]["name"], "Remote")
        self.cli(["--resume"])
        self.assertEqual(self.record()[1]["node_name"], "Remote")

    def test_foreign_changes_stop_recovery_before_further_writes(self):
        self.server.state["fail_remote_once"] = True
        with self.assertRaises(deploy.DeployError):
            self.add(port=7900)
        document = json.loads(self.path.read_text())
        document["log"]["timestamp"] = True
        atomic_write(self.path, json.dumps(document).encode())
        self.server.state["calls"] = []
        with self.assertRaises(deploy.DeployError):
            self.cli(["--resume"])
        self.assertFalse(any(method != "GET" for method, _, _, _ in self.server.state["calls"]))
        self.assertEqual(json.loads(self.path.read_text()), document)

    def test_foreign_api_edits_are_not_overwritten_during_recovery(self):
        self.server.state["fail_remote_once"] = True
        with self.assertRaises(deploy.DeployError):
            self.add()
        self.server.state["nodes"][0]["Name"] = "External edit"
        self.server.state["calls"] = []
        with self.assertRaises(deploy.DeployError):
            self.cli(["--resume"])
        self.assertEqual(self.server.state["nodes"][0]["Name"], "External edit")
        self.assertFalse(any(method != "GET" for method, _, _, _ in self.server.state["calls"]))

    def test_unmanaged_relay_reference_blocks_rename_before_writes(self):
        identity, _ = self.add("Parent", SOCKS)
        self.server.state["nodes"].append(dict(fixtures.SS_TEMPLATE, ID=999, Name="External", DialerProxyName="[SM]Parent"))
        self.server.state["calls"] = []
        with self.assertRaises(deploy.DeployError):
            self.cli(["edit", identity, "--name", "New parent"])
        self.assertFalse(any(method != "GET" for method, _, _, _ in self.server.state["calls"]))

    def test_uncertain_local_deletion_can_resume(self):
        identity, before = self.add(port=7900)
        self.server.state["fail_node_delete_once"] = True
        with self.assertRaises(deploy.DeployError):
            self.cli(["edit", identity, "--no-local-node"], ["y"])
        self.assertFalse(any(n["ID"] == before["local_node_id"] for n in self.server.state["nodes"]))
        self.cli(["--resume"])
        self.assertIsNone(self.record()[1]["singbox"])
        self.assertEqual(json.loads(self.path.read_text()), self.original)

    def test_leaving_edit_menu_does_not_create_pending_changes(self):
        identity, _ = self.add()
        self.server.state["calls"] = []
        self.cli(["edit", identity], ["0"])
        self.assertFalse(deploy.ResumeState().path.exists())
        self.assertFalse(any(method != "GET" for method, _, _, _ in self.server.state["calls"]))

    def test_unmanaged_node_requires_explicit_adoption(self):
        original = dict(fixtures.SS_TEMPLATE, ID=800, Protocol="vless", Name="Existing", Link=VLESS)
        self.server.state["nodes"] = [original]
        with self.assertRaises(deploy.DeployError):
            self.cli(["add", VLESS, "--no-local-node"])
        self.assertEqual(original["Link"], VLESS)
        self.cli(["--resume", "--adopt-node", "800"])
        record = self.record()[1]
        self.assertEqual(record["remote_node_id"], 800)
        self.assertEqual(record["kind"], "adopted")
        self.assertTrue(is_standalone(record))
        self.assertTrue(NodeManager.marker(self.node(800)).startswith("okp-remote:"))

    def test_deleting_independent_node_does_not_touch_airports(self):
        identity, _ = self.add(port=7900)
        self.server.state["calls"] = []
        self.cli(["remove", identity], ["y"])
        self.assertNotIn(identity, self.registry().records)
        self.assertEqual(self.server.state["nodes"], [])
        self.assertEqual(json.loads(self.path.read_text()), self.original)
        self.assertFalse(any("airports" in path for _, path, _, _ in self.server.state["calls"]))

    def test_node_file_is_private_and_does_not_become_an_ssh_target(self):
        path = deploy.ROOT / "private-link.txt"
        atomic_write(path, VLESS.encode())
        self.cli(["add", "--node-file", str(path), "--no-local-node"])
        self.assertEqual(self.record()[1]["kind"], "node")
        path.chmod(0o644)
        with self.assertRaises(deploy.DeployError):
            self.cli(["add", "--node-file", str(path), "--no-local-node"])

    def test_port_conflict_and_unknown_local_options_fail_before_writes(self):
        with self.assertRaises(deploy.DeployError):
            self.add(port=7896)
        self.assertFalse(any(method != "GET" for method, _, _, _ in self.server.state["calls"]))
        with self.assertRaises(deploy.DeployError):
            self.cli(["add", VLESS.replace("#Remote", "&unknown=1#Remote"), "--fresh", "--local-port", "7900"])
        self.assertEqual(self.server.state["nodes"], [])

    def test_standalone_wizard_collects_only_node_details(self):
        self.cli(["add", "--interactive"], ["3", VLESS, "Chosen", "n"])
        self.assertEqual(self.record("Chosen")[1]["airport_name"], "")

    def test_legacy_adopted_socks_metadata_migrates_without_changing_ids(self):
        identity, record = self.add("Home", VLESS, 7900, ["--local-link", SOCKS])
        state = deploy.ResumeState()
        document = json.loads((state.directory / "managed.json").read_text())
        old = document["deployments"][identity]
        old.update(kind="adopted", airport_name="Fake airport")
        old.pop("local_source")
        old.pop("remote_fingerprints")
        atomic_write(state.directory / "managed.json", json.dumps(document).encode())
        migrated = self.registry().records[identity]
        self.assertEqual(migrated["local_source"], "custom")
        self.assertEqual(migrated["airport_name"], "")
        self.assertEqual(migrated["remote_node_id"], record["remote_node_id"])
        self.cli(["edit", identity, "--local-port", "7901"])
        self.assertEqual(json.loads(self.path.read_text())["outbounds"][-1]["server_port"], 26193)
