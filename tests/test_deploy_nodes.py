import base64
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import sys
import unittest
import urllib.parse
from unittest.mock import patch

import test_deploy as fixtures
from test_deploy_resources import sample_config
from deploy_links import NodeLink, parse_node_link
from deploy_nodes import NodeManager
from deploy_resources import atomic_write, digest, is_standalone

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

    def test_local_reality_accepts_spider_path_with_canonical_fingerprint(self):
        base = parse_node_link(VLESS).outbound()
        for path in ("", "%2F", "%2Fblog%3Fp%3D10-20%26custom%3Dvalue"):
            link = parse_node_link(VLESS.replace("#Remote", "&spx=" + path + "#Remote"))
            before = (link.link, copy.deepcopy(link.query))
            self.assertEqual(link.outbound(), base)
            self.assertEqual(link.fingerprint, digest(base))
            self.assertEqual((link.link, link.query), before)

    def test_local_reality_rejects_invalid_spider_and_unknown_security_parameters(self):
        for link in (VLESS.replace("#Remote", "&spx=private-secret#Remote"),
                     VLESS.replace("security=reality", "security=tls").replace("#Remote", "&spx=%2F#Remote"),
                     VLESS.replace("#Remote", "&spx=%2F&pqv=private-secret#Remote")):
            with self.assertRaises(deploy.DeployError) as error:
                parse_node_link(link).outbound()
            self.assertNotIn("private-secret", str(error.exception))

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
        self.assertEqual(outbound["tag"], deploy.SingBox.tags(record["singbox"]["owner_id"])[1])
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

    def test_name_and_protocol_changes_keep_id_tags_and_name_edit_does_not_reload(self):
        identity, before = self.add(port=7900)
        original = self.path.read_bytes()
        self.reload.reset_mock()
        self.cli(["edit", identity], ["1", "New name"])
        self.assertEqual(self.path.read_bytes(), original)
        self.reload.assert_not_called()
        self.cli(["edit", identity, "--node-link", SS])
        after = self.record("New name")[1]
        self.assertEqual((after["singbox"]["inbound_tag"], after["singbox"]["outbound_tag"]), deploy.SingBox.tags(identity))
        self.assertEqual(after["singbox"]["inbound_tag"], before["singbox"]["inbound_tag"])
        self.assertEqual(after["singbox"]["outbound_tag"], before["singbox"]["outbound_tag"])
        self.assertEqual(json.loads(self.path.read_bytes())["outbounds"][-1]["type"], "shadowsocks")

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

    def test_missing_remote_marker_rejects_cancel_before_changing_status(self):
        parent_id, _ = self.add("Parent", SOCKS, 7901)
        child_id, child = self.add("Child", VLESS, 7902, ["--via", parent_id])
        remote = self.node(child["remote_node_id"])
        remote["Link"] = urllib.parse.urlsplit(remote["Link"])._replace(fragment="Edited").geturl()
        before = self.registry().path.read_bytes()
        config_before = self.path.read_bytes()
        self.server.state["calls"].clear()
        with self.assertRaisesRegex(deploy.DeployError, "所有权标识"):
            self.cli(["relay", child_id, "--direct"])
        self.assertEqual(self.registry().path.read_bytes(), before)
        self.assertEqual(self.path.read_bytes(), config_before)
        self.assertEqual(remote["DialerProxyName"], "[SM]Parent")
        self.assertTrue(all(method == "GET" for method, _, _, _ in self.server.state["calls"]))

    def test_cancel_relay_resumes_after_uncertain_sublink_write(self):
        parent_id, parent = self.add("Parent", SOCKS, 7901)
        child_id, child = self.add("Child", VLESS, 7902, ["--via", parent_id])
        self.server.state["fail_dialer_once"] = True
        with self.assertRaises(deploy.DeployError):
            self.cli(["relay", child_id, "--direct"])
        pending = self.record("Child")[1]
        self.assertEqual(pending["status"], "relaying")
        self.assertIsNone(pending["relay_id"])
        self.assertEqual(self.node(child["remote_node_id"])["DialerProxyName"], "")
        outbound = next(o for o in json.loads(self.path.read_bytes())["outbounds"]
                        if o["tag"] == child["singbox"]["outbound_tag"])
        self.assertEqual(outbound["detour"], parent["singbox"]["outbound_tag"])
        self.cli(["relay", child_id])
        completed = self.record("Child")[1]
        self.assertEqual(completed["status"], "active")
        self.assertIsNone(completed["relay_id"])
        self.assertFalse(completed["singbox"]["needs_reload"])
        outbound = next(o for o in json.loads(self.path.read_bytes())["outbounds"]
                        if o["tag"] == completed["singbox"]["outbound_tag"])
        self.assertNotIn("detour", outbound)
        self.assertEqual(self.node(child["remote_node_id"])["DialerProxyName"], "")

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

    def test_local_ss_reference_blocks_rename_before_writes(self):
        identity, record = self.add(port=7900)
        local_name = self.node(record["local_node_id"])["Name"]
        self.server.state["nodes"].append(dict(fixtures.SS_TEMPLATE, ID=999, Name="External", DialerProxyName=local_name))
        nodes_before = copy.deepcopy(self.server.state["nodes"])
        config_before = self.path.read_bytes()
        self.server.state["calls"].clear()
        with self.assertRaisesRegex(deploy.DeployError, "本地节点.*引用"):
            self.cli(["edit", identity, "--name", "Renamed"])
        self.assertEqual(self.server.state["nodes"], nodes_before)
        self.assertEqual(self.path.read_bytes(), config_before)
        self.assertEqual(self.record()[1]["status"], "active")
        self.assertFalse(any(method != "GET" for method, _, _, _ in self.server.state["calls"]))

    def test_new_local_ss_reference_stops_prepared_rename_before_writes(self):
        identity, record = self.add(port=7900)
        manager = NodeManager(self.client, self.registry(), deploy.SingBox(self.config))
        journal = manager.prepare(identity, name="Renamed", local_action="enable", local_port=7900)
        local_name = self.node(record["local_node_id"])["Name"]
        self.server.state["nodes"].append(dict(fixtures.SS_TEMPLATE, ID=999, Name="External", DialerProxyName=local_name))
        nodes_before = copy.deepcopy(self.server.state["nodes"])
        config_before = self.path.read_bytes()
        self.server.state["calls"].clear()
        with self.assertRaisesRegex(deploy.DeployError, "本地节点.*引用"):
            manager.apply(journal)
        self.assertEqual(self.server.state["nodes"], nodes_before)
        self.assertEqual(self.path.read_bytes(), config_before)
        self.assertIsNotNone(manager.pending(identity))
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
        self.assertFalse(deploy.ResumeState(node_id=identity).path.exists())
        self.assertFalse(any(method != "GET" for method, _, _, _ in self.server.state["calls"]))

    def subscription_draft(self):
        state = deploy.ResumeState()
        with state.locked():
            state.start("add", deploy.ROOT / ".env")
            state.capture(source="subscription")
        return state

    def test_edit_menu_does_not_consume_unrelated_subscription_draft(self):
        identity, _ = self.add()
        state = self.subscription_draft()
        before = state.path.read_bytes()
        self.server.state["calls"].clear()
        self.cli(["edit", identity], ["0"])
        self.assertEqual(state.path.read_bytes(), before)
        self.assertFalse(deploy.ResumeState(node_id=identity).path.exists())
        self.assertFalse(any(method != "GET" for method, _, _, _ in self.server.state["calls"]))

    def test_rename_preserves_unrelated_add_input_and_existing_node_ids(self):
        identity, old = self.add(port=7900)
        state = self.subscription_draft()
        with state.locked():
            state.capture(name="Other airport", local_port=7909)
        before = state.path.read_bytes()
        self.cli(["edit", identity], ["1", "New name"])
        record = self.record("New name")[1]
        self.assertEqual(record["remote_node_id"], old["remote_node_id"])
        self.assertEqual(record["local_node_id"], old["local_node_id"])
        self.assertEqual(record["local_port"], 7900)
        self.assertEqual(state.path.read_bytes(), before)
        self.assertFalse(deploy.ResumeState(node_id=identity).path.exists())

    def test_node_edit_recovery_preserves_unrelated_add_input(self):
        identity, old = self.add()
        state = self.subscription_draft()
        before = state.path.read_bytes()
        self.server.state["fail_remote_once"] = True
        with self.assertRaises(deploy.DeployError):
            self.cli(["edit", identity, "--name", "New name"])
        edit = deploy.ResumeState(node_id=identity)
        self.assertEqual(edit.load()["installation_id"], identity)
        self.assertEqual(edit.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(state.path.read_bytes(), before)
        with self.assertRaises(deploy.DeployError):
            self.cli(["edit", identity, "--name", "Different intent"])
        self.cli(["edit", identity])
        record = self.record("New name")[1]
        self.assertEqual(record["remote_node_id"], old["remote_node_id"])
        self.assertEqual(record["status"], "active")
        self.assertFalse(edit.path.exists())
        self.assertEqual(state.path.read_bytes(), before)

    def test_multiple_pending_edits_require_a_node_for_resume(self):
        first, _ = self.add("First", VLESS)
        second, _ = self.add("Second", SOCKS)
        for identity, name in ((first, "First new"), (second, "Second new")):
            self.server.state["fail_remote_once"] = True
            with self.assertRaises(deploy.DeployError):
                self.cli(["edit", identity, "--name", name])
        second_state = deploy.ResumeState(node_id=second)
        before = second_state.path.read_bytes()
        with self.assertRaisesRegex(deploy.DeployError, "多个未完成"):
            self.cli(["--resume"])
        self.cli(["edit", first, "--resume"])
        self.assertEqual(second_state.path.read_bytes(), before)
        self.cli(["--resume"])
        self.assertFalse(second_state.path.exists())
        self.assertEqual(self.record("First new")[1]["status"], "active")
        self.assertEqual(self.record("Second new")[1]["status"], "active")

    def test_global_edit_checkpoint_is_rejected(self):
        identity, _ = self.add()
        self.server.state["fail_remote_once"] = True
        with self.assertRaises(deploy.DeployError):
            self.cli(["edit", identity, "--name", "New name"])
        edit = deploy.ResumeState(node_id=identity)
        legacy = deploy.ResumeState()
        with legacy.locked():
            legacy.data = copy.deepcopy(edit.load())
            legacy.data["options"]["target"] = "Remote"
            atomic_write(legacy.path, json.dumps(legacy.data).encode())
            edit.complete()
        before = legacy.path.read_bytes()
        with self.assertRaisesRegex(deploy.DeployError, "节点编辑必须"):
            self.cli(["edit", identity])
        self.assertEqual(legacy.path.read_bytes(), before)
        self.assertFalse(edit.path.exists())

    def test_pending_add_for_same_node_still_blocks_edit(self):
        identity, _ = self.add()
        state = deploy.ResumeState()
        with state.locked():
            state.start("add", deploy.ROOT / ".env")
            state.capture(source="node", node_link=VLESS)
            state.phase("sync", identity)
        before = state.path.read_bytes()
        self.server.state["calls"].clear()
        with self.assertRaisesRegex(deploy.DeployError, "此节点的安装或添加尚未完成"):
            self.cli(["edit", identity, "--name", "New name"])
        self.assertEqual(state.path.read_bytes(), before)
        self.assertFalse(self.server.state["calls"])

    def test_fresh_edit_only_replaces_that_nodes_draft(self):
        identity, _ = self.add()
        state = self.subscription_draft()
        before = state.path.read_bytes()
        edit = deploy.ResumeState(node_id=identity)
        with edit.locked():
            edit.start("edit", deploy.ROOT / ".env")
            edit.capture(source="node", target=identity, name="Unfinished input")
        self.cli(["edit", identity, "--fresh", "--name", "New name"])
        self.assertEqual(self.record("New name")[1]["status"], "active")
        self.assertEqual(state.path.read_bytes(), before)
        self.assertFalse(edit.path.exists())

    def edit_draft(self, identity, name="Saved name"):
        state = deploy.ResumeState(node_id=identity)
        with state.locked():
            state.start("edit", deploy.ROOT / ".env")
            state.capture(source="node", target=identity, name=name)
        return state

    def test_interactive_edit_continue_applies_saved_input_without_new_prompt(self):
        identity, _ = self.add()
        self.edit_draft(identity)
        self.cli(["edit", identity], ["1"])
        self.assertEqual(self.record("Saved name")[1]["status"], "active")
        self.assertFalse(deploy.ResumeState(node_id=identity).path.exists())

    def test_interactive_edit_return_preserves_draft_and_resources(self):
        identity, record = self.add()
        state = self.edit_draft(identity)
        before = state.path.read_bytes()
        remote = copy.deepcopy(self.node(record["remote_node_id"]))
        self.server.state["calls"].clear()
        self.cli(["edit", identity], ["0"])
        self.assertEqual(state.path.read_bytes(), before)
        self.assertEqual(self.node(record["remote_node_id"]), remote)
        self.assertFalse(self.server.state["calls"])

    def test_interactive_edit_restart_only_replaces_draft_for_that_node(self):
        identity, _ = self.add()
        global_state = self.subscription_draft()
        before = global_state.path.read_bytes()
        self.edit_draft(identity)
        self.cli(["edit", identity], ["2", "1", "Fresh name"])
        self.assertEqual(self.record("Fresh name")[1]["status"], "active")
        self.assertEqual(global_state.path.read_bytes(), before)
        self.assertFalse(deploy.ResumeState(node_id=identity).path.exists())

    def test_interactive_edit_continues_started_transaction_after_invalid_restart_choice(self):
        identity, _ = self.add()
        self.server.state["fail_remote_once"] = True
        with self.assertRaises(deploy.DeployError):
            self.cli(["edit", identity, "--name", "Saved name"])
        self.cli(["edit", identity], ["2", "1"])
        self.assertEqual(self.record("Saved name")[1]["status"], "active")
        self.assertFalse(deploy.ResumeState(node_id=identity).path.exists())

    def test_validation_failure_can_restart_in_tui_without_resource_changes(self):
        unsupported = VLESS.replace("#Remote", "&unknown=secret#Remote")
        identity, record = self.add(link=unsupported, port=7900, extra=["--local-link", SOCKS])
        global_state = self.subscription_draft()
        global_before = global_state.path.read_bytes()
        nodes_before = copy.deepcopy(self.server.state["nodes"])
        config_before = self.path.read_bytes()
        with self.assertRaisesRegex(deploy.DeployError, "不支持"):
            self.cli(["edit", identity, "--same-local"])
        edit = deploy.ResumeState(node_id=identity)
        self.assertEqual(edit.load()["phase"], "sync")
        self.assertIsNone(NodeManager(self.client, self.registry()).pending(identity))
        self.cli(["edit", identity], ["2", "0"])
        self.assertFalse(edit.path.exists())
        self.assertEqual(self.server.state["nodes"], nodes_before)
        self.assertEqual(self.path.read_bytes(), config_before)
        self.assertEqual(global_state.path.read_bytes(), global_before)
        self.assertEqual(self.record()[1]["local_source"], "custom")

    def test_fresh_cannot_discard_an_applied_node_transaction(self):
        identity, _ = self.add()
        self.server.state["fail_remote_once"] = True
        with self.assertRaises(deploy.DeployError):
            self.cli(["edit", identity, "--name", "Saved name"])
        edit = deploy.ResumeState(node_id=identity)
        checkpoint_before = edit.path.read_bytes()
        journal_path = NodeManager(self.client, self.registry()).journal_path(identity)
        journal_before = journal_path.read_bytes()
        nodes_before = copy.deepcopy(self.server.state["nodes"])
        with self.assertRaisesRegex(deploy.DeployError, "继续.*原操作"):
            self.cli(["edit", identity, "--fresh"])
        self.assertEqual(edit.path.read_bytes(), checkpoint_before)
        self.assertEqual(journal_path.read_bytes(), journal_before)
        self.assertEqual(self.server.state["nodes"], nodes_before)
        self.cli(["edit", identity, "--resume"])
        self.assertEqual(self.record("Saved name")[1]["status"], "active")

    def test_relay_edit_sequence_preserves_credentials_and_routing(self):
        parent_id, parent = self.add("Parent", SOCKS, 7901)
        identity, initial = self.add(port=7900)
        local_link = self.node(initial["local_node_id"])["Link"]
        self.cli(["relay", identity, "--via", parent_id])
        self.cli(["edit", identity], ["5", "2", SS])
        self.cli(["edit", identity], ["1", "Renamed"])
        self.cli(["edit", identity], ["5", "1"])
        self.cli(["edit", identity], ["6", "y"])
        current = self.record("Renamed")[1]
        outbound = next(o for o in json.loads(self.path.read_bytes())["outbounds"] if o["tag"] == current["singbox"]["outbound_tag"])
        self.assertEqual(outbound["type"], "vless")
        self.assertEqual(outbound["detour"], parent["singbox"]["outbound_tag"])
        self.assertEqual(self.node(current["remote_node_id"])["DialerProxyName"], "[SM]Parent")
        self.cli(["relay", identity], ["1", "n"])
        final = self.record("Renamed")[1]
        self.assertEqual(final["status"], "active")
        self.assertIsNone(final["relay_id"])
        self.assertEqual(final["local_source"], "remote")
        self.assertEqual(final["remote_node_id"], initial["remote_node_id"])
        self.assertEqual(final["local_node_id"], initial["local_node_id"])
        self.assertEqual(self.node(final["local_node_id"])["Link"], local_link)
        self.assertEqual(self.node(final["remote_node_id"])["DialerProxyName"], "")
        outbound = next(o for o in json.loads(self.path.read_bytes())["outbounds"] if o["tag"] == final["singbox"]["outbound_tag"])
        self.assertNotIn("detour", outbound)
        for key in ("remote_node_id", "local_node_id"):
            self.assertIn("家宽", self.server.state["tags"][final[key]])
        self.assertFalse(deploy.ResumeState(node_id=identity).path.exists())

    def test_failed_new_node_validation_can_restart_without_unused_registration(self):
        with self.assertRaises(deploy.DeployError):
            self.add("Failed", VLESS, 7896)
        failed_id, _ = self.record("Failed")
        self.assertFalse(self.server.state["nodes"])
        self.cli(["add", "--interactive"], ["2", "3", SS, "Working", "n", "n"])
        self.assertNotIn(failed_id, self.registry().records)
        self.assertEqual(len(self.registry().records), 1)
        self.assertEqual(self.record("Working")[1]["status"], "active")
        self.assertFalse(deploy.ResumeState().path.exists())
        self.assertEqual(json.loads(self.path.read_bytes()), self.original)

    def test_failed_duplicate_add_restart_preserves_existing_configuration(self):
        identity, before = self.add(port=7900)
        config_before = self.path.read_bytes()
        with self.assertRaises(deploy.DeployError):
            self.cli(["add", VLESS, "--local-port", "7896"])
        self.cli(["add", "--interactive"], ["2", "3", SS, "Working", "n", "n", "n"])
        self.assertEqual(self.registry().records[identity], before)
        self.assertEqual(len(self.registry().records), 2)
        self.assertEqual(self.path.read_bytes(), config_before)

    def test_started_add_cannot_discard_transaction_and_resumes_without_duplicates(self):
        self.server.state["fail_remote_once"] = True
        with self.assertRaises(deploy.DeployError):
            self.add("Saved name")
        state = deploy.ResumeState()
        checkpoint_before = state.path.read_bytes()
        nodes_before = copy.deepcopy(self.server.state["nodes"])
        with self.assertRaisesRegex(deploy.DeployError, "继续.*原操作"):
            self.cli(["add", SS, "--name", "Different", "--no-local-node", "--fresh"])
        self.cli(["add", "--interactive"], ["2", "0"])
        self.assertEqual(state.path.read_bytes(), checkpoint_before)
        self.assertEqual(self.server.state["nodes"], nodes_before)
        self.cli(["--resume"])
        self.assertEqual(len(self.registry().records), 1)
        self.assertEqual(self.record("Saved name")[1]["status"], "active")
        self.assertEqual(len(self.server.state["nodes"]), 1)

    def test_scoped_edit_rejects_record_for_different_node(self):
        identity, _ = self.add()
        edit = deploy.ResumeState(node_id=identity)
        with edit.locked():
            edit.start("edit", deploy.ROOT / ".env")
        data = json.loads(edit.path.read_bytes())
        data["installation_id"] = "f" * 32
        atomic_write(edit.path, json.dumps(data).encode())
        with self.assertRaisesRegex(deploy.DeployError, "当前管理 ID 不一致"):
            self.cli(["edit", identity])

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
        self.cli(["add", "--interactive"], ["3", VLESS, "Chosen", "n", "n"])
        record = self.record("Chosen")[1]
        self.assertEqual(record["airport_name"], "")
        self.assertEqual(self.server.state["tags"][record["remote_node_id"]], ["稳定"])

    def test_tui_new_local_node_can_accept_default_port(self):
        with patch.object(deploy.SublinkPro, "port_available", return_value=True):
            self.cli(["add", "--interactive"], ["3", VLESS, "Chosen", "n", "y", "", "1"])
        record = self.record("Chosen")[1]
        self.assertEqual(record["local_port"], 7897)
        self.assertEqual(deploy.SingBox.ss_parameters(self.node(record["local_node_id"])["Link"])[0], 7897)

    def test_cli_new_local_nodes_automatically_select_different_ports(self):
        with patch.object(deploy.SublinkPro, "port_available", return_value=True):
            self.cli(["add", "--node-link", VLESS, "--name", "First", "--local-node"])
            self.cli(["add", "--node-link", SS, "--name", "Second", "--local-node"])
        self.assertEqual(self.record("First")[1]["local_port"], 7897)
        self.assertEqual(self.record("Second")[1]["local_port"], 7898)

    def test_default_port_survives_partial_write_and_resume(self):
        self.server.state["fail_remote_once"] = True
        with patch.object(deploy.SublinkPro, "port_available", return_value=True), self.assertRaises(deploy.DeployError):
            self.cli(["add", "--node-link", VLESS, "--name", "Auto", "--local-node"])
        identity, before = self.record("Auto")
        remote_id = self.client.find_remote_node(identity)["ID"]
        self.assertEqual(deploy.ResumeState().load()["options"]["local_port"], 7897)
        with patch.object(deploy.SublinkPro, "available_local_port", side_effect=AssertionError("saved port must be reused")):
            self.cli(["--resume"])
        after = self.record("Auto")[1]
        self.assertEqual(after["local_port"], 7897)
        self.assertEqual(after["remote_node_id"], remote_id)
        self.assertEqual(len(self.server.state["nodes"]), 2)

    def test_local_port_edit_can_accept_existing_default_without_reload(self):
        identity, before = self.add(port=7900)
        config_before = self.path.read_bytes()
        self.reload.reset_mock()
        with patch.object(deploy.SublinkPro, "available_local_port", side_effect=AssertionError("must keep existing port")):
            self.cli(["edit", identity], ["3", ""])
        self.assertEqual(self.record()[1]["local_node_id"], before["local_node_id"])
        self.assertEqual(self.path.read_bytes(), config_before)
        self.reload.assert_not_called()

    def test_residential_add_tags_remote_and_companion_local_node(self):
        _, record = self.add(port=7900, extra=["--residential"])
        for key in ("remote_node_id", "local_node_id"):
            self.assertEqual(set(self.server.state["tags"][record[key]]), {"稳定", "家宽"})

    def test_tui_add_can_mark_remote_only_node_as_residential(self):
        self.cli(["add", "--interactive"], ["3", VLESS, "Home", "y", "n"])
        record = self.record("Home")[1]
        self.assertEqual(set(self.server.state["tags"][record["remote_node_id"]]), {"稳定", "家宽"})
        self.assertIsNone(record["local_node_id"])

    def test_tui_residential_toggle_preserves_connections_and_other_tags(self):
        identity, record = self.add(port=7900)
        remote_id, local_id = record["remote_node_id"], record["local_node_id"]
        self.server.state["tags"].update({remote_id: ["稳定", "remote-custom"], local_id: ["稳定", "local-custom"]})
        before = copy.deepcopy(self.server.state["nodes"])
        config_before = self.path.read_bytes()
        self.reload.reset_mock()
        original = deploy.prompt_yes_no
        with patch.object(deploy, "prompt_yes_no", wraps=original) as prompt:
            self.cli(["edit", identity], ["6", "y"])
            self.assertFalse(prompt.call_args.args[1])
            self.cli(["edit", identity], ["6", "n"])
            self.assertTrue(prompt.call_args.args[1])
        self.assertEqual(self.server.state["nodes"], before)
        self.assertEqual(set(self.server.state["tags"][remote_id]), {"稳定", "remote-custom"})
        self.assertEqual(set(self.server.state["tags"][local_id]), {"稳定", "local-custom"})
        self.assertEqual(self.path.read_bytes(), config_before)
        self.reload.assert_not_called()

    def test_new_local_node_inherits_existing_residential_setting(self):
        identity, record = self.add(extra=["--residential"])
        self.cli(["edit", identity, "--local-port", "7901"])
        local_id = self.record()[1]["local_node_id"]
        self.assertEqual(set(self.server.state["tags"][local_id]), {"稳定", "家宽"})
        self.assertEqual(self.record()[1]["remote_node_id"], record["remote_node_id"])

    def test_resume_switching_custom_local_outbound_to_reality_link_with_spider(self):
        link = VLESS.replace("#Remote", "&spx=%2Fblog#Remote")
        identity, before = self.add("Home", link, 7900, ["--local-link", SOCKS])
        local_link = self.node(before["local_node_id"])["Link"]
        self.reload.side_effect = [deploy.DeployError("reload failed"), None]
        with self.assertRaises(deploy.DeployError):
            self.cli(["edit", identity, "--same-local"])
        self.reload.side_effect = None
        checkpoint = deploy.ResumeState(node_id=identity)
        self.assertTrue(checkpoint.load()["options"]["same_local"])
        self.assertIsNotNone(NodeManager(self.client, self.registry()).pending(identity))
        self.cli(["edit", identity], ["1"])
        after = self.record("Home")[1]
        self.assertEqual(after["status"], "active")
        self.assertEqual(after["local_source"], "remote")
        self.assertEqual(after["singbox"]["outbound_tag"], before["singbox"]["outbound_tag"])
        self.assertEqual(after["remote_node_id"], before["remote_node_id"])
        self.assertEqual(after["local_node_id"], before["local_node_id"])
        self.assertEqual(self.node(after["local_node_id"])["Link"], local_link)
        outbound = next(o for o in json.loads(self.path.read_bytes())["outbounds"]
                        if o["tag"] == after["singbox"]["outbound_tag"])
        self.assertEqual(outbound["type"], "vless")
        self.assertEqual(outbound["tls"]["reality"], parse_node_link(link).outbound()["tls"]["reality"])
        self.assertNotIn("spiderX", outbound["tls"]["reality"])
        self.assertFalse(checkpoint.path.exists())

    def test_residential_partial_write_resumes_without_replacing_intent(self):
        identity, record = self.add(port=7900)
        self.server.state["fail_tags_once"] = True
        with self.assertRaises(deploy.DeployError):
            self.cli(["edit", identity, "--residential"])
        self.assertEqual(self.record()[1]["status"], "updating")
        self.assertIn("家宽", self.server.state["tags"][record["remote_node_id"]])
        self.assertNotIn("家宽", self.server.state["tags"][record["local_node_id"]])
        with self.assertRaises(deploy.DeployError):
            self.cli(["edit", identity, "--no-residential"])
        self.assertTrue(deploy.ResumeState(node_id=identity).load()["options"]["residential"])
        self.cli(["edit", identity])
        for key in ("remote_node_id", "local_node_id"):
            self.assertEqual(self.record()[1][key], record[key])
            self.assertIn("家宽", self.server.state["tags"][record[key]])
        self.assertEqual(self.record()[1]["status"], "active")

    def test_residential_recovery_does_not_overwrite_external_tag_changes(self):
        identity, record = self.add(port=7900)
        self.server.state["fail_tags_once"] = True
        with self.assertRaises(deploy.DeployError):
            self.cli(["edit", identity, "--residential"])
        self.server.state["tags"][record["local_node_id"]] = ["稳定", "external"]
        self.server.state["calls"].clear()
        with self.assertRaises(deploy.DeployError):
            self.cli(["edit", identity])
        self.assertEqual(self.server.state["tags"][record["local_node_id"]], ["稳定", "external"])
        self.assertTrue(all(method == "GET" for method, _, _, _ in self.server.state["calls"]))

    def test_airport_residential_setting_applies_to_owned_source_nodes_only(self):
        identity = "e" * 32
        self.server.state["airports"] = [dict(fixtures.TEMPLATE, id=21, name="Airport", remark="[okp:" + identity + "]")]
        self.server.state["nodes"] = [dict(fixtures.SS_TEMPLATE, ID=node_id, Protocol="vless", Name=str(node_id),
                                          Link=VLESS, SourceID=source_id) for node_id, source_id in ((501, 21), (502, 21), (503, 22))]
        for node_id in (501, 502, 503):
            self.server.state["tags"][node_id] = ["稳定", "custom"]
        registry = self.registry()
        with registry.state.locked():
            registry.register(identity, "subscription:" + identity, deploy.ROOT / ".env", self.client.url, "Airport")
            registry.update(identity, kind="subscription", airport_id=21, status="active")
        before = copy.deepcopy(self.server.state["nodes"])
        self.cli(["edit", identity, "--residential"])
        for node_id in (501, 502):
            self.assertEqual(set(self.server.state["tags"][node_id]), {"稳定", "custom", "家宽"})
        self.assertEqual(self.server.state["tags"][503], ["稳定", "custom"])
        self.cli(["edit", identity], ["6", "n"])
        for node_id in (501, 502):
            self.assertEqual(set(self.server.state["tags"][node_id]), {"稳定", "custom"})
        self.assertEqual(self.server.state["nodes"], before)

    def test_residential_journal_rejects_changed_airport_source(self):
        identity, _ = self.add()
        registry = self.registry()
        manager = NodeManager(self.client, registry)
        with registry.state.locked():
            journal = manager.prepare_residential(identity, True)
            self.server.state["nodes"][0]["SourceID"] = 99
            self.server.state["calls"].clear()
            with self.assertRaises(deploy.DeployError):
                manager.apply(journal)
        self.assertTrue(all(method == "GET" for method, _, _, _ in self.server.state["calls"]))

    def test_inventory_missing_current_fields_is_rejected(self):
        identity, record = self.add("Home", VLESS, 7900, ["--local-link", SOCKS])
        state = deploy.ResumeState()
        document = json.loads((state.directory / "managed.json").read_text())
        old = document["deployments"][identity]
        old.update(kind="adopted", airport_name="Fake airport")
        old.pop("local_source")
        old.pop("remote_fingerprints")
        atomic_write(state.directory / "managed.json", json.dumps(document).encode())
        with self.assertRaisesRegex(deploy.DeployError, "清单无效"):
            self.registry()
