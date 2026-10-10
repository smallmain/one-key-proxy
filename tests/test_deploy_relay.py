import copy
import contextlib
import io
import importlib.util
import json
from pathlib import Path
import tempfile
import sys
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import patch

import test_deploy as fixtures
import test_deploy_nodes as node_fixtures
from deploy_links import parse_node_link
from deploy_nodes import NodeManager
from deploy_relay import RemoteCreation, RemoteRelayManager, default_name
import deploy_relay
from deploy_resources import DeployError, atomic_write, remote_relay_record

SPEC = importlib.util.spec_from_file_location("relay_server", Path(__file__).resolve().parents[1] / "lib/remote_relay.py")
server_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server_module)

CHAIN = "c" * 32
ENTRY = "a" * 32
EXIT = "b" * 32
VLESS, SS, SOCKS = node_fixtures.VLESS, node_fixtures.SS, node_fixtures.SOCKS


class XrayConversionTests(unittest.TestCase):
    def test_reality_credentials_and_flow_survive_conversion(self):
        result = parse_node_link(VLESS).xray_outbound()
        server = result["settings"]["vnext"][0]
        self.assertEqual(server["users"][0]["flow"], "xtls-rprx-vision")
        self.assertEqual(result["streamSettings"]["security"], "reality")
        self.assertEqual(result["streamSettings"]["realitySettings"]["publicKey"], "A" * 43)

    def test_reality_spider_path_is_preserved_without_changing_link_or_fingerprint(self):
        link = parse_node_link(VLESS.replace("#Remote", "&spx=%2Fblog%3Fp%3D10-20%26custom%3Dvalue#Remote"))
        before = (link.link, copy.deepcopy(link.query), link.fingerprint)
        result = link.xray_outbound()
        self.assertEqual(result["streamSettings"]["realitySettings"]["spiderX"], "/blog?p=10-20&custom=value")
        self.assertEqual((link.link, link.query, link.fingerprint), before)
        self.assertEqual(link.outbound()["tls"]["reality"]["public_key"], "A" * 43)
        self.assertNotIn("spiderX", link.outbound()["tls"]["reality"])

    def test_empty_spider_path_uses_xray_default_and_invalid_paths_are_rejected(self):
        result = parse_node_link(VLESS.replace("#Remote", "&spx=#Remote")).xray_outbound()
        self.assertEqual(result["streamSettings"]["realitySettings"]["spiderX"], "/")
        for link in (VLESS.replace("#Remote", "&spx=invalid#Remote"),
                     VLESS.replace("security=reality", "security=tls").replace("#Remote", "&spx=%2F#Remote"),
                     VLESS.replace("#Remote", "&spx=%2F&unknown=private-secret#Remote")):
            with self.assertRaises(DeployError) as error:
                parse_node_link(link).xray_outbound()
            self.assertNotIn("private-secret", str(error.exception))

    def test_socks_and_shadowsocks_preserve_authentication(self):
        socks = parse_node_link(SOCKS).xray_outbound()
        self.assertEqual(socks["protocol"], "socks")
        self.assertEqual(socks["settings"]["servers"][0]["users"], [{"user": "test-user", "pass": "test-password"}])
        self.assertNotIn("users", parse_node_link("socks5://host.example:1080").xray_outbound()["settings"]["servers"][0])
        ss = parse_node_link(SS).xray_outbound()
        self.assertEqual(ss["protocol"], "shadowsocks")
        self.assertEqual(ss["settings"]["servers"][0]["password"], "remote-secret")

    def test_ws_and_grpc_preserve_transport_and_tls(self):
        prefix = VLESS.split("?", 1)[0]
        ws = parse_node_link(prefix + "?type=ws&security=tls&host=ws.example&path=%2Fproxy&sni=tls.example&alpn=h2").xray_outbound()
        self.assertEqual(ws["streamSettings"]["wsSettings"], {"path": "/proxy", "headers": {"Host": "ws.example"}})
        self.assertEqual(ws["streamSettings"]["tlsSettings"], {"serverName": "tls.example", "alpn": ["h2"]})
        grpc = parse_node_link(prefix + "?type=grpc&security=tls&serviceName=proxy").xray_outbound()
        self.assertEqual(grpc["streamSettings"]["grpcSettings"], {"serviceName": "proxy"})

    def test_unsupported_parameters_and_cleartext_vless_are_rejected(self):
        for link in (VLESS.split("?", 1)[0], SS.replace("#SS", "?plugin=obfs#SS"),
                     "ss://none:secret@host.example:443"):
            with self.assertRaises(DeployError):
                parse_node_link(link).xray_outbound()


class FakeXui:
    def __init__(self):
        self.template = {"log": {"loglevel": "warning"}, "outbounds": [
            {"tag": "direct", "protocol": "freedom"}, {"tag": "blocked", "protocol": "blackhole"}],
            "routing": {"domainStrategy": "AsIs", "rules": [
                {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"},
                {"type": "field", "network": "tcp,udp", "outboundTag": "direct"}]}}
        self.original = copy.deepcopy(self.template)
        self.clients = [{"id": "00000000-0000-4000-8000-000000000001", "email": "main", "enable": True}]
        self.calls = []
        self.exit_ok = True
        self.fail_template_once = False
        self.skipped_enable = False
        self.force_enable_on_add = False
        self.private_key = "server-private-key"

    def api(self, method, path, fields=None, *, form=False):
        self.calls.append((method, path, copy.deepcopy(fields), form))
        if path == "/panel/api/xray/":
            return json.dumps({"xraySetting": json.dumps(self.template), "outboundTestUrl": "https://probe.example/check"})
        if path == "/panel/api/xray/update":
            if not form or fields["outboundTestUrl"] != "https://probe.example/check":
                raise AssertionError("Template form or test URL was lost")
            self.template = json.loads(fields["xraySetting"])
            if self.fail_template_once:
                self.fail_template_once = False
                raise server_module.RelayError("application failed after persistence")
            return None
        if path == "/panel/api/inbounds/list":
            return [{"id": 42, "tag": "entry-in", "protocol": "vless", "port": 443,
                     "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {
                         "privateKey": self.private_key, "settings": {"publicKey": "A" * 43},
                         "serverNames": ["www.cloudflare.com"], "shortIds": ["abcd"]}},
                     "settings": json.dumps({"clients": self.clients})}]
        if path == "/panel/api/clients/add":
            self.clients.append(copy.deepcopy(fields["client"]))
            if self.force_enable_on_add:
                self.clients[-1]["enable"] = True
            return None
        if path in ("/panel/api/clients/bulkEnable", "/panel/api/clients/bulkDisable"):
            if self.skipped_enable and path.endswith("bulkEnable"):
                return {"changed": 0, "skipped": [{"email": fields["emails"][0], "reason": "not found"}]}
            for client in self.clients:
                if client["email"] in fields["emails"]:
                    client["enable"] = path.endswith("bulkEnable")
            return {"changed": 1, "skipped": []}
        if path.startswith("/panel/api/clients/del/"):
            self.clients = [client for client in self.clients if client["email"] != path.rsplit("/", 1)[-1]]
            return None
        if path == "/panel/api/server/status":
            return {"xray": {"state": "running", "errorMsg": ""}}
        if path == "/panel/api/server/getConfigJson":
            return copy.deepcopy(self.template)
        if path == "/panel/api/xray/routeTest":
            for rule in self.template["routing"]["rules"]:
                if rule.get("user") == [fields["email"]] and rule.get("inboundTag") == [fields["inboundTag"]]:
                    return {"matched": True, "outboundTag": rule["outboundTag"]}
            return {"matched": True, "outboundTag": "direct"}
        if path == "/panel/api/xray/testOutbound":
            return {"success": self.exit_ok}
        raise AssertionError(path)


class ServerRelayTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name) / "relays"
        self.context = {"installation_id": ENTRY, "version": "v3.9.0", "inbound_id": 42,
                        "inbound_tag": "entry-in", "vless_uri": fixtures.NODE["VLESS_URI"], "inbound_port": 443}
        self.api = FakeXui()
        self.server = server_module.RelayServer(self.context, self.directory, self.api.api)
        self.request = {"operation": "apply", "identity": CHAIN, "installation_id": ENTRY,
                        "outbound": parse_node_link(SOCKS).xray_outbound()}

    def run_request(self, operation="apply"):
        return self.server.run(dict(self.request, operation=operation))

    def test_creation_disables_client_until_route_and_exit_verification(self):
        result = self.run_request()
        paths = [call[1] for call in self.api.calls]
        self.assertLess(paths.index("/panel/api/xray/update"), paths.index("/panel/api/clients/add"))
        self.assertLess(paths.index("/panel/api/xray/routeTest"), paths.index("/panel/api/clients/add"))
        self.assertLess(paths.index("/panel/api/xray/routeTest"), paths.index("/panel/api/clients/bulkEnable"))
        self.assertLess(paths.index("/panel/api/xray/testOutbound"), paths.index("/panel/api/clients/bulkEnable"))
        self.assertFalse(next(call[2]["client"]["enable"] for call in self.api.calls if call[1].endswith("/clients/add")))
        self.assertEqual(self.api.clients[0], {"id": "00000000-0000-4000-8000-000000000001", "email": "main", "enable": True})
        self.assertEqual(self.api.template["outbounds"][0], self.api.original["outbounds"][0])
        rules = self.api.template["routing"]["rules"]
        self.assertEqual(rules[0], self.api.original["routing"]["rules"][0])
        self.assertEqual(rules[1]["user"], ["okp-relay-" + CHAIN])
        self.assertEqual(rules[2], self.api.original["routing"]["rules"][1])
        self.assertIn("okp-remote:" + CHAIN, result["link"])
        self.assertEqual((self.directory / (CHAIN + ".json")).stat().st_mode & 0o777, 0o600)

    def test_retry_does_not_duplicate_clients_or_change_credentials(self):
        first = self.run_request()
        second = self.run_request()
        self.assertEqual(first, second)
        self.assertEqual(len(self.api.clients), 2)
        self.assertEqual(len(self.api.template["outbounds"]), 3)

    def test_failed_exit_test_keeps_client_disabled_and_resumes_same_identity(self):
        self.api.exit_ok = False
        with self.assertRaises(server_module.RelayError):
            self.run_request()
        identity = self.api.clients[-1]["id"]
        self.assertFalse(self.api.clients[-1]["enable"])
        self.assertNotIn("/panel/api/clients/bulkEnable", [call[1] for call in self.api.calls])
        self.api.exit_ok = True
        result = self.run_request()
        self.assertIn(identity, result["link"])
        self.assertTrue(self.api.clients[-1]["enable"])

    def test_failed_creation_can_be_cancelled_without_a_working_exit(self):
        self.api.exit_ok = False
        with self.assertRaises(server_module.RelayError):
            self.run_request()
        self.assertTrue(self.run_request("delete")["deleted"])
        self.assertEqual(self.api.template, self.api.original)
        self.assertEqual(len(self.api.clients), 1)

    def test_template_persistence_failure_rolls_back_and_retains_transaction(self):
        self.api.fail_template_once = True
        with self.assertRaises(server_module.RelayError):
            self.run_request()
        self.assertEqual(self.api.template, self.api.original)
        self.assertEqual(len(self.api.clients), 1)
        self.assertTrue((self.directory / (CHAIN + ".json")).exists())
        self.run_request()

    def test_exit_change_keeps_entry_account_and_default_route(self):
        first = self.run_request()
        self.request["outbound"] = parse_node_link(SS).xray_outbound()
        self.assertEqual(first, self.run_request())
        self.assertEqual(self.api.template["outbounds"][-1]["protocol"], "shadowsocks")
        self.assertEqual(self.api.template["outbounds"][0], self.api.original["outbounds"][0])

    def test_external_user_or_outbound_changes_are_not_overwritten(self):
        self.run_request()
        for mutation in (lambda: self.api.clients[-1].update(flow="changed"),
                         lambda: self.api.template["outbounds"][-1].update(protocol="freedom"),
                         lambda: self.api.template["routing"]["rules"].pop(1)):
            saved_clients, saved_template = copy.deepcopy(self.api.clients), copy.deepcopy(self.api.template)
            mutation()
            before = copy.deepcopy(self.api.template)
            with self.assertRaises(server_module.RelayError):
                self.run_request("inspect")
            self.assertEqual(before, self.api.template)
            self.api.clients, self.api.template = saved_clients, saved_template

    def test_skipped_enable_is_not_reported_as_success(self):
        self.api.skipped_enable = True
        with self.assertRaises(server_module.RelayError):
            self.run_request()
        self.assertFalse(self.api.clients[-1]["enable"])

    def test_unexpected_auto_enabled_account_is_guarded_before_creation(self):
        self.api.force_enable_on_add = True
        with self.assertRaises(server_module.RelayError):
            self.run_request()
        own_rule = next(rule for rule in self.api.template["routing"]["rules"] if rule.get("user") == ["okp-relay-" + CHAIN])
        self.assertEqual(own_rule["outboundTag"], "blocked")
        self.assertTrue(self.run_request("delete")["deleted"])

    def test_concurrent_template_changes_are_not_overwritten(self):
        self.api.template["log"] = {"loglevel": "debug"}
        with self.assertRaises(server_module.RelayError):
            self.server.apply_template(self.api.original, self.api.original, "https://probe.example/check")
        self.assertEqual(self.api.template["log"]["loglevel"], "debug")

    def test_shared_reality_transport_changes_are_detected_without_overwrite(self):
        self.run_request()
        self.api.private_key = "externally-changed-private-key"
        before = copy.deepcopy(self.api.template)
        with self.assertRaises(server_module.RelayError):
            self.run_request("inspect")
        self.assertEqual(self.api.template, before)
        manifest = (self.directory / (CHAIN + ".json")).read_text()
        self.assertNotIn("server-private-key", manifest)
        self.assertNotIn("externally-changed-private-key", manifest)

    def test_delete_only_removes_owned_resources_and_is_retryable(self):
        self.run_request()
        self.assertTrue(self.run_request("delete")["deleted"])
        self.assertEqual(self.api.template, self.api.original)
        self.assertEqual(len(self.api.clients), 1)
        self.assertTrue(self.run_request("delete")["deleted"])

    def test_old_version_and_wrong_installation_stop_before_mutation(self):
        self.context["version"] = "v3.7.0"
        with self.assertRaises(server_module.RelayError):
            self.run_request()
        self.assertEqual(self.api.calls, [])
        self.context["version"] = "v3.9.0"
        self.request["installation_id"] = EXIT
        with self.assertRaises(server_module.RelayError):
            self.run_request()
        self.assertEqual(self.api.calls, [])

    def test_conflicting_policy_order_is_rejected_before_client_creation(self):
        self.api.template["routing"]["rules"].reverse()
        with self.assertRaises(server_module.RelayError):
            self.run_request()
        self.assertEqual(len(self.api.clients), 1)

    def test_custom_blackhole_policy_keeps_priority(self):
        self.api.template["outbounds"][1]["tag"] = "deny-private"
        self.api.template["routing"]["rules"][0]["outboundTag"] = "deny-private"
        self.run_request()
        self.assertEqual(self.api.template["routing"]["rules"][0]["outboundTag"], "deny-private")

    def test_balancer_that_would_capture_new_outbound_is_rejected(self):
        self.api.template["routing"]["balancers"] = [{"tag": "pool", "selector": ["okp-relay-"]}]
        with self.assertRaises(server_module.RelayError):
            self.run_request()
        self.assertEqual(len(self.api.clients), 1)


class SubscriptionRefreshTests(unittest.TestCase):
    def make_manager(self, *, status="completed", ambiguous=False):
        state = {"pulled": False, "node_reads": 0}
        airport = {"id": 7, "name": "Airport"}

        def request(path, fields=None, *, method=None):
            if path == "airports":
                return [airport]
            if path == "tasks/running":
                return []
            if path == "airports/7/pull":
                state["pulled"] = True
                return None
            if path.startswith("tasks?"):
                rows = [{"id": "old", "type": "sub_update", "trigger": "manual", "name": "Airport", "status": "completed"}]
                if state["pulled"]:
                    rows.append(dict(rows[0], id="new", status=status))
                    if ambiguous:
                        rows.append(dict(rows[0], id="other-new"))
                return {"items": rows}
            if path == "tasks/new":
                return {"id": "new", "type": "sub_update", "trigger": "manual", "name": "Airport", "status": status}
            raise AssertionError(path)

        def nodes():
            state["node_reads"] += 1
            return [{"ID": 1, "SourceID": 7, "Link": SOCKS}]

        client = SimpleNamespace(request=request, all_nodes=nodes, find=lambda _: airport)
        registry = SimpleNamespace(records={EXIT: {"airport_id": 7}})
        return RemoteRelayManager(client, registry, {}), state

    def test_refresh_waits_for_new_task_and_two_stable_node_snapshots(self):
        manager, state = self.make_manager()
        with patch.object(deploy_relay.time, "sleep"), contextlib.redirect_stdout(io.StringIO()):
            manager.refresh_source(EXIT)
        self.assertTrue(state["pulled"])
        self.assertEqual(state["node_reads"], 2)

    def test_failed_or_ambiguous_tasks_do_not_read_old_nodes_as_success(self):
        for status, ambiguous in (("error", False), ("cancelled", False), ("completed", True)):
            manager, state = self.make_manager(status=status, ambiguous=ambiguous)
            with patch.object(deploy_relay.time, "sleep"), contextlib.redirect_stdout(io.StringIO()), self.assertRaises(DeployError):
                manager.refresh_source(EXIT)
            self.assertEqual(state["node_reads"], 0)

    def test_missing_task_capability_stops_before_submitting_a_pull(self):
        manager, state = self.make_manager()
        old_request = manager.client.request
        manager.client.request = lambda path, **kw: {} if path.startswith("tasks") else old_request(path, **kw)
        with self.assertRaises(DeployError):
            manager.refresh_source(EXIT)
        self.assertFalse(state["pulled"])

    def test_timeout_retains_existing_entry_parameters(self):
        manager, state = self.make_manager(status="running")
        with patch.object(deploy_relay.time, "monotonic", side_effect=[0, 61]), \
                contextlib.redirect_stdout(io.StringIO()), self.assertRaises(DeployError):
            manager.refresh_source(EXIT)
        self.assertTrue(state["pulled"])
        self.assertEqual(state["node_reads"], 0)


class RemotePublicationTests(unittest.TestCase):
    setUp = node_fixtures.NodeWorkflowTests.setUp
    cleanup = node_fixtures.NodeWorkflowTests.cleanup
    cli = node_fixtures.NodeWorkflowTests.cli
    registry = node_fixtures.NodeWorkflowTests.registry
    record = node_fixtures.NodeWorkflowTests.record
    node = node_fixtures.NodeWorkflowTests.node
    add = node_fixtures.NodeWorkflowTests.add

    def complete_entry(self, registry, identity=ENTRY):
        link = parse_node_link(VLESS.replace(parse_node_link(VLESS).auth['uuid'], str(uuid.UUID(identity))))
        node_id = max([917] + [n['ID'] for n in self.server.state['nodes']]) + 1
        self.server.state['nodes'].append(dict(fixtures.SS_TEMPLATE, ID=node_id, Protocol='vless',
            Name='[SM]' + registry.records[identity]['node_name'], Link=link.marked(identity), SourceID=0))
        registry.update(identity, remote_node_id=node_id,
                        server={'backend': 'project', 'identity': identity, 'fingerprint': link.fingerprint})

    def create_chain(self, *, local=False, residential=False):
        exit_id, _ = self.add("美国-家宽", SOCKS)
        registry = self.registry()
        with registry.state.locked():
            registry.register(ENTRY, "root@entry", deploy_env := fixtures.deploy.ROOT / ".env", self.client.url, "美国")
            registry.update(ENTRY, status="active", ssh={"target": "root@entry", "port": 22, "identity": None,
                            "password": False})
            self.complete_entry(registry)
            registry.register(CHAIN, "remote-relay:" + CHAIN, deploy_env, self.client.url, "美国-家宽(美国中转)",
                              kind="remote-relay", remote_relay=remote_relay_record(ENTRY, exit_id))
            calls = []

            def transport(entry, request):
                calls.append(copy.deepcopy(request))
                if request["operation"] == "delete":
                    return {"deleted": True}
                link = VLESS.replace(parse_node_link(VLESS).auth['uuid'], str(uuid.UUID(CHAIN)))
                return {"link": parse_node_link(link).marked(CHAIN), "installation_id": ENTRY}

            manager = RemoteRelayManager(self.client, registry, self.config, transport)
            manager.apply(manager.prepare(CHAIN, ENTRY, exit_id, name="美国-家宽(美国中转)",
                          local_action="enable" if local else "keep", local_port=7901 if local else None,
                          residential=residential))
        return manager, calls, exit_id

    def test_combination_name_publication_and_local_ss_only_connects_entry(self):
        manager, calls, exit_id = self.create_chain(local=True)
        record = manager.registry.records[CHAIN]
        self.assertEqual(self.node(record["remote_node_id"])["Name"], "[SM]美国-家宽(美国中转)")
        self.assertEqual(self.node(record["local_node_id"])["Name"], "[SM]美国-家宽(美国中转) - 本地")
        self.assertEqual(self.node(record["remote_node_id"])["DialerProxyName"], "")
        self.assertIn(record["node_name"], manager.registry.dependents(ENTRY))
        self.assertIn(record["node_name"], manager.registry.dependents(exit_id))
        outbound = next(item for item in json.loads(self.path.read_bytes())["outbounds"] if item["tag"] == record["singbox"]["outbound_tag"])
        self.assertEqual(outbound["server"], parse_node_link(VLESS).host)
        self.assertNotIn("detour", outbound)
        self.assertEqual(calls[0]["outbound"]["protocol"], "socks")

    def test_residential_remote_creation_tags_both_published_nodes(self):
        manager, _, _ = self.create_chain(local=True, residential=True)
        record = manager.registry.records[CHAIN]
        for key in ("remote_node_id", "local_node_id"):
            self.assertEqual(set(self.server.state["tags"][record[key]]), {"稳定", "家宽"})

    def test_remote_local_ss_enable_accepts_default_and_edit_can_change_port(self):
        manager, _, _ = self.create_chain()
        with patch.dict(sys.modules, {"deploy": fixtures.deploy}), \
                patch.object(deploy_relay, "ssh_call", side_effect=manager.transport), \
                patch.object(fixtures.deploy.SublinkPro, "port_available", return_value=True):
            self.cli(["edit", CHAIN], ["3", "", "y"])
            before = self.registry().records[CHAIN]
            self.assertEqual(before["local_port"], 7897)
            self.cli(["edit", CHAIN], ["3", "7902", "y"])
        after = self.registry().records[CHAIN]
        self.assertEqual(after["local_port"], 7902)
        self.assertEqual(after["local_node_id"], before["local_node_id"])
        self.assertEqual(after["remote_node_id"], before["remote_node_id"])

    def test_new_remote_combination_selects_local_port_when_omitted(self):
        exit_id, _ = self.add("美国-家宽", SOCKS)
        registry = self.registry()
        registry.register(ENTRY, "root@entry", fixtures.deploy.ROOT / ".env", self.client.url, "美国")
        registry.update(ENTRY, status="active", ssh={"target": "root@entry", "port": 22, "identity": None,
                        "password": False})
        self.complete_entry(registry)

        def transport(entry, request):
            link = VLESS.replace(parse_node_link(VLESS).auth['uuid'], str(uuid.UUID(request['identity'])))
            return {"link": parse_node_link(link).marked(request["identity"]), "installation_id": ENTRY}

        with patch.dict(sys.modules, {"deploy": fixtures.deploy}), patch.object(deploy_relay, "ssh_call", transport), \
                patch.object(fixtures.deploy.SublinkPro, "port_available", return_value=True):
            self.cli(["remote-relay", exit_id, "--entry", ENTRY, "--local-node"])
        combinations = [r for r in self.registry().records.values() if r["kind"] == "remote-relay"]
        self.assertEqual(len(combinations), 1)
        self.assertEqual(combinations[0]["local_port"], 7897)
        self.assertEqual(fixtures.deploy.SingBox.ss_parameters(self.node(combinations[0]["local_node_id"])["Link"])[0], 7897)

    def test_remote_exit_selection_accepts_reality_link_with_spider_path(self):
        identity, _ = self.add("夏威夷家宽", VLESS.replace("#Remote", "&spx=%2F#Remote"))
        manager = RemoteRelayManager(self.client, self.registry(), self.config)
        selected = manager.select_exit(identity)
        self.assertEqual(selected.xray_outbound()["streamSettings"]["realitySettings"]["spiderX"], "/")

    def test_remote_exit_selection_reports_conversion_reason_without_credentials(self):
        identity, _ = self.add("Unsupported", VLESS.replace("#Remote", "&spx=private-secret#Remote"))
        manager = RemoteRelayManager(self.client, self.registry(), self.config)
        with self.assertRaises(DeployError) as error:
            manager.select_exit(identity)
        self.assertIn("spx", str(error.exception))
        self.assertNotIn("private-secret", str(error.exception))

    def test_tui_residential_remote_edit_does_not_contact_entry_or_restart_singbox(self):
        manager, _, _ = self.create_chain(local=True)
        before = self.path.read_bytes()
        self.reload.reset_mock()
        with patch.dict(sys.modules, {"deploy": fixtures.deploy}), \
                patch.object(deploy_relay, "ssh_call", side_effect=AssertionError("tag edits do not need SSH")):
            self.cli(["edit", CHAIN], answers=["5", "y"])
        record = self.registry().records[CHAIN]
        for key in ("remote_node_id", "local_node_id"):
            self.assertEqual(set(self.server.state["tags"][record[key]]), {"稳定", "家宽"})
        self.assertEqual(self.path.read_bytes(), before)
        self.reload.assert_not_called()

    def test_residential_remote_tag_write_can_resume_with_entry_offline(self):
        manager, _, _ = self.create_chain(local=True)
        manager.transport = lambda *_: (_ for _ in ()).throw(AssertionError("entry is offline"))
        self.server.state["fail_tags_once"] = True
        with manager.registry.state.locked():
            with self.assertRaises(DeployError):
                manager.set_residential(CHAIN, True)
            manager.sync(CHAIN)
        record = manager.registry.records[CHAIN]
        self.assertEqual(record["status"], "active")
        for key in ("remote_node_id", "local_node_id"):
            self.assertEqual(set(self.server.state["tags"][record[key]]), {"稳定", "家宽"})

    def test_rename_updates_both_display_names_but_preserves_ids_and_tags(self):
        manager, _, _ = self.create_chain(local=True)
        before = copy.deepcopy(manager.registry.records[CHAIN])
        after = manager.rename(CHAIN, "自定义组合")
        self.assertEqual(after["remote_node_id"], before["remote_node_id"])
        self.assertEqual(after["local_node_id"], before["local_node_id"])
        self.assertEqual(after["remote_relay"], dict(before["remote_relay"], auto_name=False))
        self.assertEqual(after["singbox"]["outbound_tag"], before["singbox"]["outbound_tag"])
        self.assertEqual(self.node(after["remote_node_id"])["Name"], "[SM]自定义组合")
        self.assertEqual(self.node(after["local_node_id"])["Name"], "[SM]自定义组合 - 本地")
        manager.sync(CHAIN)
        self.assertEqual(manager.registry.records[CHAIN]["node_name"], "自定义组合")

    def test_server_failure_retains_local_intent_and_resume_creates_one_node(self):
        manager, _, exit_id = self.create_chain()
        intent = manager.prepare(CHAIN, ENTRY, exit_id)
        old_transport = manager.transport
        manager.transport = lambda *_: (_ for _ in ()).throw(DeployError("offline"))
        with self.assertRaises(DeployError):
            manager.apply(intent)
        self.assertTrue(manager.pending_path(CHAIN).exists())
        manager.transport = old_transport
        old_id = manager.registry.records[CHAIN]["remote_node_id"]
        manager.sync(CHAIN)
        self.assertEqual(manager.registry.records[CHAIN]["remote_node_id"], old_id)
        self.assertFalse(manager.pending_path(CHAIN).exists())

    def test_new_default_name_uses_base_names_without_sublink_prefix(self):
        self.assertEqual(default_name({"node_name": "美国"}, {"node_name": "美国-家宽"}), "美国-家宽(美国中转)")

    def test_combination_cannot_be_overwritten_by_ordinary_add(self):
        manager, _, _ = self.create_chain()
        link = self.node(manager.registry.records[CHAIN]["remote_node_id"])["Link"]
        with self.assertRaises(DeployError):
            self.cli(["add", "--node-link", link, "--node-name", "wrong", "--no-local-node"])

    def test_deleting_either_parent_is_blocked(self):
        manager, _, exit_id = self.create_chain()
        for identity in (ENTRY, exit_id):
            with self.assertRaises(DeployError):
                self.cli(["remove", identity], answers=["y"])
        self.assertEqual(manager.registry.records[CHAIN]["status"], "active")

    def test_exit_edits_push_updated_parameters_without_renaming_combination(self):
        manager, calls, exit_id = self.create_chain()
        with patch.object(deploy_relay, "ssh_call", manager.transport):
            self.cli(["edit", exit_id, "--node-link", SOCKS.replace(":26193", ":26200")])
        self.assertEqual(calls[-1]["outbound"]["settings"]["servers"][0]["port"], 26200)
        self.assertEqual(self.registry().records[CHAIN]["node_name"], "美国-家宽(美国中转)")

    def test_default_exit_rename_updates_combination_local_and_dialer_without_ssh(self):
        manager, _, exit_id = self.create_chain(local=True)
        child_id, child = self.add("Child", SS, extra=["--via", CHAIN])
        before = copy.deepcopy(self.registry().records[CHAIN])
        links = {node["ID"]: node["Link"] for node in self.server.state["nodes"]}
        config_before = self.path.read_bytes()
        self.reload.reset_mock()
        with patch.object(deploy_relay, "ssh_call", side_effect=AssertionError("display names need no SSH")):
            self.cli(["edit", exit_id], ["1", "夏威夷家宽"])
        after = self.registry().records[CHAIN]
        self.assertEqual(after["node_name"], "夏威夷家宽(美国中转)")
        self.assertEqual(self.node(after["remote_node_id"])["Name"], "[SM]夏威夷家宽(美国中转)")
        self.assertEqual(self.node(after["local_node_id"])["Name"], "[SM]夏威夷家宽(美国中转) - 本地")
        self.assertEqual(self.node(child["remote_node_id"])["DialerProxyName"], "[SM]夏威夷家宽(美国中转)")
        self.assertEqual(after["remote_relay"], before["remote_relay"])
        self.assertEqual(after["singbox"], before["singbox"])
        self.assertEqual({node["ID"]: node["Link"] for node in self.server.state["nodes"]}, links)
        self.assertEqual(self.path.read_bytes(), config_before)
        self.reload.assert_not_called()

    def test_entry_name_refresh_updates_defaults_and_preserves_manual_name(self):
        manager, _, exit_id = self.create_chain(local=True)
        registry = self.registry()
        registry.update(ENTRY, node_name="美西")
        nodes = NodeManager(self.client, registry)
        journal = nodes.prepare_related_names(ENTRY, intent={"name": "美西"})
        nodes.apply(journal)
        self.assertEqual(self.registry().records[CHAIN]["node_name"], "美国-家宽(美西中转)")
        manager.registry = self.registry()
        manager.rename(CHAIN, "固定组合")
        registry = self.registry()
        registry.update(ENTRY, node_name="香港")
        nodes = NodeManager(self.client, registry)
        self.assertIsNone(nodes.prepare_related_names(ENTRY, intent={"name": "香港"}))
        with patch.object(deploy_relay, "ssh_call", side_effect=AssertionError("display names need no SSH")):
            self.cli(["edit", exit_id], ["1", "夏威夷家宽"])
        self.assertEqual(self.registry().records[CHAIN]["node_name"], "固定组合")
        self.assertFalse(self.registry().records[CHAIN]["remote_relay"]["auto_name"])

    def test_default_exit_replacement_regenerates_name_but_custom_name_is_preserved(self):
        manager, _, _ = self.create_chain()
        new_exit, _ = self.add("日本", SS)
        manager.registry = self.registry()
        manager.apply(manager.prepare(CHAIN, ENTRY, new_exit))
        self.assertEqual(self.registry().records[CHAIN]["node_name"], "日本(美国中转)")
        manager.rename(CHAIN, "固定组合")
        old_exit = manager.registry.select("美国-家宽")
        manager.apply(manager.prepare(CHAIN, ENTRY, old_exit))
        self.assertEqual(self.registry().records[CHAIN]["node_name"], "固定组合")

    def test_all_default_combinations_follow_exit_rename(self):
        manager, _, exit_id = self.create_chain()
        registry = self.registry()
        second_entry, second_chain = "d" * 32, "e" * 32
        registry.register(second_entry, "root@second", fixtures.deploy.ROOT / ".env", self.client.url, "香港")
        registry.update(second_entry, status="active", ssh={"target": "root@second", "port": 22, "identity": None,
                        "password": False})
        self.complete_entry(registry, second_entry)
        registry.register(second_chain, "remote-relay:" + second_chain, fixtures.deploy.ROOT / ".env", self.client.url,
                          "美国-家宽(香港中转)", kind="remote-relay", remote_relay=remote_relay_record(second_entry, exit_id))

        def transport(entry, request):
            link = VLESS.replace(parse_node_link(VLESS).auth["uuid"], "10000000-0000-4000-8000-000000000001")
            return {"link": parse_node_link(link).marked(second_chain), "installation_id": second_entry}

        second = RemoteRelayManager(self.client, registry, self.config, transport)
        second.apply(second.prepare(second_chain, second_entry, exit_id))
        with patch.object(deploy_relay, "ssh_call", side_effect=AssertionError("display names need no SSH")):
            self.cli(["edit", exit_id], ["1", "新家宽"])
        self.assertEqual(self.registry().records[CHAIN]["node_name"], "新家宽(美国中转)")
        self.assertEqual(self.registry().records[second_chain]["node_name"], "新家宽(香港中转)")

    def test_partial_combination_rename_resumes_original_names_and_blocks_other_edits(self):
        _, _, exit_id = self.create_chain(local=True)
        config_before = self.path.read_bytes()
        original_request = fixtures.deploy.SublinkPro.request
        failed = []

        def request(client, path, fields=None, **kwargs):
            result = original_request(client, path, fields, **kwargs)
            if path == "nodes/update" and parse_node_link(fields["link"]).name == "okp-remote:" + CHAIN and not failed:
                failed.append(True)
                raise DeployError("lost rename response")
            return result

        self.reload.reset_mock()
        with patch.object(fixtures.deploy.SublinkPro, "request", request), \
                patch.object(deploy_relay, "ssh_call", side_effect=AssertionError("display names need no SSH")):
            with self.assertRaisesRegex(DeployError, "lost rename response"):
                self.cli(["edit", exit_id, "--name", "新家宽"])
            self.assertEqual(self.registry().records[CHAIN]["status"], "updating")
            with patch.dict(sys.modules, {"deploy": fixtures.deploy}), self.assertRaisesRegex(DeployError, "参与.*未完成改名"):
                self.cli(["edit", CHAIN, "--name", "Different"])
            self.cli(["edit", exit_id], ["1"])
        after = self.registry().records[CHAIN]
        self.assertEqual(after["node_name"], "新家宽(美国中转)")
        self.assertEqual(self.node(after["remote_node_id"])["Name"], "[SM]新家宽(美国中转)")
        self.assertEqual(self.node(after["local_node_id"])["Name"], "[SM]新家宽(美国中转) - 本地")
        self.assertEqual(after["status"], "active")
        self.assertEqual(self.path.read_bytes(), config_before)
        self.reload.assert_not_called()

    def test_combination_name_conflict_and_external_edit_stop_before_writes(self):
        manager, _, exit_id = self.create_chain(local=True)
        original = copy.deepcopy(self.server.state["nodes"])
        collision = dict(fixtures.SS_TEMPLATE, ID=999, Name="[SM]新家宽(美国中转)")
        self.server.state["nodes"].append(collision)
        self.server.state["calls"].clear()
        with self.assertRaisesRegex(DeployError, "名称已存在"):
            self.cli(["edit", exit_id, "--name", "新家宽"])
        self.assertEqual(self.server.state["nodes"], original + [collision])
        self.assertFalse(any(method != "GET" for method, _, _, _ in self.server.state["calls"]))
        self.server.state["nodes"].remove(collision)
        nodes = NodeManager(self.client, self.registry())
        journal = nodes.prepare(exit_id, name="新家宽")
        chain_id = self.registry().records[CHAIN]["remote_node_id"]
        self.node(chain_id)["Name"] = "External"
        current = copy.deepcopy(self.server.state["nodes"])
        self.server.state["calls"].clear()
        with self.assertRaisesRegex(DeployError, "外部修改"):
            nodes.apply(journal)
        self.assertEqual(self.server.state["nodes"], current)
        self.assertFalse(any(method != "GET" for method, _, _, _ in self.server.state["calls"]))

    def test_exit_local_edits_and_rename_finish_with_entry_offline(self):
        manager, _, exit_id = self.create_chain()
        combination_before = copy.deepcopy(self.registry().records[CHAIN])
        with patch.object(deploy_relay, "ssh_call", side_effect=DeployError("entry offline")) as transport:
            self.cli(["edit", exit_id], ["3", "7902"])
            self.cli(["edit", exit_id], ["5", "2", VLESS])
            self.cli(["edit", exit_id], ["1", "夏威夷家宽"])
            self.cli(["edit", exit_id], ["6", "y"])
            self.cli(["edit", exit_id], ["4", "y"])
        transport.assert_not_called()
        self.assertEqual(self.registry().records[CHAIN], dict(combination_before, node_name="夏威夷家宽(美国中转)"))
        self.assertEqual(self.registry().records[exit_id]["status"], "active")
        self.assertFalse(fixtures.deploy.ResumeState(node_id=exit_id).path.exists())

    def test_exit_local_reload_failure_can_resume_with_entry_offline(self):
        _, _, exit_id = self.create_chain()
        with patch.object(deploy_relay, "ssh_call", side_effect=DeployError("entry offline")) as transport:
            self.reload.side_effect = [DeployError("reload failed"), None]
            with self.assertRaisesRegex(DeployError, "重载失败"):
                self.cli(["edit", exit_id, "--local-port", "7902"])
            self.reload.side_effect = None
            self.cli(["edit", exit_id], ["1"])
        transport.assert_not_called()
        record = self.registry().records[exit_id]
        self.assertEqual(record["status"], "active")
        self.assertEqual(record["local_port"], 7902)
        self.assertFalse(record["singbox"]["needs_reload"])

    def test_exit_connection_update_resumes_remote_sync_after_entry_failure(self):
        manager, calls, exit_id = self.create_chain()
        with patch.object(deploy_relay, "ssh_call", side_effect=DeployError("entry offline")):
            with self.assertRaisesRegex(DeployError, "entry offline"):
                self.cli(["edit", exit_id, "--node-link", SOCKS.replace(":26193", ":26200")])
        self.assertEqual(self.registry().records[exit_id]["status"], "active")
        self.assertEqual(self.registry().records[CHAIN]["status"], "syncing")
        with patch.object(deploy_relay, "ssh_call", manager.transport):
            self.cli(["edit", exit_id], ["1"])
        self.assertEqual(calls[-1]["outbound"]["settings"]["servers"][0]["port"], 26200)
        self.assertEqual(self.registry().records[CHAIN]["status"], "active")
        self.assertFalse(fixtures.deploy.ResumeState(node_id=exit_id).path.exists())

    def test_pending_remote_change_rejects_different_name_without_writes(self):
        manager, _, exit_id = self.create_chain()
        manager.prepare(CHAIN, ENTRY, exit_id, name="Saved name")
        checkpoint_before = manager.pending_path(CHAIN).read_bytes()
        nodes_before = copy.deepcopy(self.server.state["nodes"])
        with patch.dict(sys.modules, {"deploy": fixtures.deploy}), \
                patch.object(deploy_relay, "ssh_call", side_effect=manager.transport) as transport:
            for options in (["--name", "Different name"], ["--local-port", "7909"], ["--local-node"],
                            ["--residential"], ["--subscription-node", "different-fingerprint"]):
                with self.subTest(options=options), self.assertRaisesRegex(DeployError, "继续.*原操作"):
                    self.cli(["edit", CHAIN] + options)
        transport.assert_not_called()
        self.assertEqual(manager.pending_path(CHAIN).read_bytes(), checkpoint_before)
        self.assertEqual(self.server.state["nodes"], nodes_before)
        with patch.dict(sys.modules, {"deploy": fixtures.deploy}), \
                patch.object(deploy_relay, "ssh_call", manager.transport):
            self.cli(["remote-sync", CHAIN])
        self.assertEqual(self.registry().records[CHAIN]["node_name"], "Saved name")

    def test_pending_remote_rename_keeps_saved_name_and_can_retry_same_command(self):
        manager, _, _ = self.create_chain(local=True)
        self.server.state["fail_remote_once"] = True
        with self.assertRaises(DeployError):
            manager.rename(CHAIN, "Saved name")
        nodes_before = copy.deepcopy(self.server.state["nodes"])
        journal_before = NodeManager(self.client, self.registry()).journal_path(CHAIN).read_bytes()
        with patch.dict(sys.modules, {"deploy": fixtures.deploy}), \
                patch.object(deploy_relay, "ssh_call", side_effect=manager.transport) as transport:
            with self.assertRaisesRegex(DeployError, "继续.*原操作"):
                self.cli(["edit", CHAIN, "--name", "Different name"])
            transport.assert_not_called()
            self.assertEqual(self.server.state["nodes"], nodes_before)
            self.assertEqual(NodeManager(self.client, self.registry()).journal_path(CHAIN).read_bytes(), journal_before)
            self.cli(["edit", CHAIN, "--name", "Saved name"])
        record = self.registry().records[CHAIN]
        self.assertEqual(record["node_name"], "Saved name")
        self.assertEqual(self.node(record["local_node_id"])["Name"], "[SM]Saved name - 本地")
        self.assertEqual(record["status"], "active")

    def test_offline_entry_deletion_retains_all_local_resources_and_resumes(self):
        manager, _, _ = self.create_chain(local=True)
        before = copy.deepcopy(manager.registry.records[CHAIN])
        with patch.object(deploy_relay, "ssh_call", side_effect=DeployError("entry offline")), self.assertRaises(DeployError):
            self.cli(["remove", CHAIN], answers=["y"])
        failed = self.registry().records[CHAIN]
        self.assertEqual(failed["status"], "deleting")
        self.assertEqual(failed["remote_node_id"], before["remote_node_id"])
        self.assertEqual(failed["local_node_id"], before["local_node_id"])
        with patch.object(deploy_relay, "ssh_call", manager.transport):
            self.cli(["remove", CHAIN], answers=[])
        self.assertNotIn(CHAIN, self.registry().records)
        self.assertIn(ENTRY, self.registry().records)

    def test_tui_create_rename_and_sync_use_new_remote_branch(self):
        exit_id, _ = self.add("美国-家宽", SOCKS)
        registry = self.registry()
        with registry.state.locked():
            registry.register(ENTRY, "root@entry", fixtures.deploy.ROOT / ".env", self.client.url, "美国")
            registry.update(ENTRY, status="active", ssh={"target": "root@entry", "port": 22,
                            "identity": None, "password": False})
            self.complete_entry(registry)
        calls = []

        def transport(entry, request):
            calls.append(request)
            link = VLESS.replace(parse_node_link(VLESS).auth['uuid'], str(uuid.UUID(request['identity'])))
            return {"link": parse_node_link(link).marked(request["identity"]), "installation_id": ENTRY}

        answers = ["4", "1", "1", "2", "1", "", "n", "n", "y", "0", "3", "1", "2", "组合别名", "3", "0", "0", "0"]
        output = io.StringIO()
        with patch.dict(sys.modules, {"deploy": fixtures.deploy}), patch.object(deploy_relay, "ssh_call", transport), \
                patch.object(fixtures.deploy.sys.stdin, "isatty", return_value=True), \
                patch("builtins.input", side_effect=answers), contextlib.redirect_stdout(output):
            fixtures.deploy.main([])
        registry = self.registry()
        chain = registry.records[registry.select("组合别名")]
        self.assertIn("美国-家宽(美国中转)", output.getvalue())
        self.assertIn("1. 本地中转", output.getvalue())
        self.assertIn("2. 远程中转", output.getvalue())
        self.assertEqual(chain["remote_relay"]["exit_id"], exit_id)
        self.assertEqual(self.node(chain["remote_node_id"])["Name"], "[SM]组合别名")
        self.assertTrue(calls)

    def test_failed_exit_replacement_protects_both_exit_dependencies(self):
        manager, _, old_exit = self.create_chain()
        new_exit, _ = self.add("另一落地", SS)
        manager.registry = self.registry()
        intent = manager.prepare(CHAIN, ENTRY, new_exit)
        original_transport = manager.transport
        manager.transport = lambda *_: (_ for _ in ()).throw(DeployError("offline"))
        with self.assertRaises(DeployError):
            manager.apply(intent)
        self.assertTrue(manager.registry.dependents(old_exit))
        self.assertTrue(manager.registry.dependents(new_exit))
        manager.transport = original_transport
        manager.sync(CHAIN)
        self.assertFalse(manager.registry.dependents(old_exit))
        self.assertTrue(manager.registry.dependents(new_exit))

    def test_cycle_rejected_before_persisting_a_new_intent(self):
        manager, _, _ = self.create_chain()
        exit_id, _ = self.add("循环落地", SS, extra=("--via", CHAIN))
        manager.registry = self.registry()
        with self.assertRaises(DeployError):
            manager.prepare(CHAIN, ENTRY, exit_id)
        self.assertFalse(manager.pending_path(CHAIN).exists())


class RemoteCreationTests(unittest.TestCase):
    cleanup = node_fixtures.NodeWorkflowTests.cleanup
    cli = node_fixtures.NodeWorkflowTests.cli
    registry = node_fixtures.NodeWorkflowTests.registry
    record = node_fixtures.NodeWorkflowTests.record
    node = node_fixtures.NodeWorkflowTests.node
    add = node_fixtures.NodeWorkflowTests.add

    def setUp(self):
        node_fixtures.NodeWorkflowTests.setUp(self)
        self.exit_id, _ = self.add("夏威夷家宽", SOCKS)
        registry = self.registry()
        registry.register(ENTRY, "adopted:美国", fixtures.deploy.ROOT / ".env", self.client.url, "美国", kind="adopted")
        registry.update(ENTRY, status="active", airport_id=21)
        self.server.state["airports"].append(dict(fixtures.TEMPLATE, id=21, name="美国", remark="[okp:" + ENTRY + "]"))
        self.server.state["nodes"].append(dict(fixtures.SS_TEMPLATE, ID=501, Protocol="vless", SourceID=21,
                                               Name="[SM]美国", Link=VLESS))
        self.calls = []

    def transport(self, entry, request):
        self.calls.append(copy.deepcopy(request))
        if request["operation"] == "delete":
            return {"deleted": True}
        link = VLESS.replace(parse_node_link(VLESS).auth["uuid"], str(uuid.UUID(request["identity"])))
        return {"link": parse_node_link(link).marked(request["identity"]), "installation_id": ENTRY}

    def draft(self):
        creation = RemoteCreation(self.registry(), self.exit_id, self.client, fixtures.deploy.ROOT / ".env")
        creation.load()
        return creation

    def invoke(self, answers, *, export_error=None, transport=None, extra=(), action="relay"):
        output = io.StringIO()
        answers = iter(answers)

        def answer(prompt):
            if prompt.startswith('请选择') and output.getvalue().endswith('  1. 补全所需配置并继续\n  0. 返回\n'):
                return '1'
            result = next(answers)
            if isinstance(result, BaseException) or (isinstance(result, type) and issubclass(result, BaseException)):
                raise result
            return result
        with patch.dict(sys.modules, {"deploy": fixtures.deploy}), \
                patch.object(fixtures.deploy.sys.stdin, "isatty", return_value=True), \
                patch("builtins.input", side_effect=answer) as input_mock, \
                patch.object(fixtures.deploy, "SSH") as ssh, \
                patch.object(fixtures.deploy, "export_node", return_value=fixtures.NODE, side_effect=export_error), \
                patch.object(deploy_relay, "ssh_call", transport or self.transport), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            fixtures.deploy.main([action, self.exit_id] + list(extra))
        return output.getvalue(), ssh, input_mock

    def fail_binding(self):
        with self.assertRaisesRegex(DeployError, "export failed"):
            self.invoke(["2", "1", "", "y", "y", "7901", "entry.example", "", "y"],
                        export_error=DeployError("export failed"))
        return self.draft()

    def test_binding_failure_retains_all_inputs_and_resumes_from_original_node(self):
        checkpoint = fixtures.deploy.ResumeState()
        with checkpoint.locked():
            checkpoint.start("add", fixtures.deploy.ROOT / ".env")
        unrelated = checkpoint.path.read_bytes()
        before = copy.deepcopy(self.server.state["nodes"])
        creation = self.fail_binding()
        values = creation.values
        self.assertEqual(creation.data["phase"], "bind")
        self.assertEqual(values["entry_id"], ENTRY)
        self.assertEqual(values["name"], "夏威夷家宽(美国中转)")
        self.assertTrue(values["auto_name"])
        self.assertTrue(values["residential"])
        self.assertTrue(values["enabled"])
        self.assertEqual(values["local_port"], 7901)
        self.assertEqual(values["ssh_target"], "entry.example")
        self.assertEqual(values["ssh_port"], 22)
        self.assertTrue(values["ssh_password"])
        self.assertIsNone(values["ssh_identity"])
        self.assertEqual(creation.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(set(values) - set(RemoteCreation.fields), set())
        self.assertEqual(self.server.state["nodes"], before)
        self.assertEqual(len(self.registry().records), 2)
        self.assertEqual(checkpoint.path.read_bytes(), unrelated)
        output, ssh, prompts = self.invoke(["2", "1", "y"])
        self.assertEqual(prompts.call_count, 4)
        self.assertIn("继续上次", output)
        self.assertEqual(ssh.call_args.args[0], "entry.example")
        self.assertTrue(ssh.call_args.kwargs["password_login"])
        record = self.registry().records[creation.data["identity"]]
        self.assertEqual(record["local_port"], 7901)
        self.assertEqual(record["status"], "active")
        for field in ("remote_node_id", "local_node_id"):
            self.assertIn("家宽", self.server.state["tags"][record[field]])
        self.assertFalse(creation.path.exists())
        self.assertEqual(checkpoint.path.read_bytes(), unrelated)

    def test_interrupted_inputs_resume_only_unanswered_options(self):
        with self.assertRaises(KeyboardInterrupt):
            self.invoke(["2", "1", "自定义名称", "n", "y", KeyboardInterrupt])
        creation = self.draft()
        self.assertEqual(creation.data["phase"], "input")
        self.assertNotIn("local_port", creation.values)
        self.assertEqual(creation.values["name"], "自定义名称")
        output, _, prompts = self.invoke(["2", "1", "7902", "entry.example", "", "y", "y"])
        self.assertEqual(prompts.call_count, 8)
        self.assertEqual(self.registry().records[creation.data["identity"]]["node_name"], "自定义名称")
        self.assertIn("已创建", output)

    def test_edit_ssh_keeps_node_options_and_switches_from_password_to_key(self):
        creation = self.fail_binding()
        self.invoke(["2", "1", "n"])
        self.assertTrue(self.registry().records[ENTRY]["ssh"]["password"])
        output, ssh, _ = self.invoke(["2", "2", "new-entry.example", "2222", "n", "~/.ssh/id_ed25519", "y"])
        self.assertEqual(ssh.call_args.args[0], "new-entry.example")
        self.assertEqual(ssh.call_args.args[2], 2222)
        self.assertEqual(ssh.call_args.args[3], str(Path("~/.ssh/id_ed25519").expanduser().absolute()))
        self.assertFalse(ssh.call_args.kwargs["password_login"])
        record = self.registry().records[creation.data["identity"]]
        self.assertEqual(record["node_name"], "夏威夷家宽(美国中转)")
        self.assertEqual(record["local_port"], 7901)
        self.assertIn("已创建", output)

    def test_changed_ssh_server_cannot_replace_the_bound_installation(self):
        self.invoke(["2", "1", "", "n", "n", "entry.example", "", "y", "n"])
        before = copy.deepcopy(self.registry().records[ENTRY]["ssh"])
        with patch.dict(sys.modules, {"deploy": fixtures.deploy}), \
                patch.object(fixtures.deploy.sys.stdin, "isatty", return_value=True), \
                patch("builtins.input", side_effect=["2", "2", "other.example", "", "y"]), \
                patch.object(fixtures.deploy, "SSH"), \
                patch.object(fixtures.deploy, "export_node", return_value=dict(fixtures.NODE, INSTALLATION_ID="d" * 32)), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()), \
                self.assertRaisesRegex(DeployError, "不是原入口安装"):
            fixtures.deploy.main(["relay", self.exit_id])
        self.assertEqual(self.registry().records[ENTRY]["ssh"], before)
        self.assertEqual(len(self.registry().records), 2)

    def test_confirmation_cancel_keeps_draft_without_creating_resources(self):
        self.invoke(["2", "1", "", "n", "n", "entry.example", "", "y", "n"])
        creation = self.draft()
        self.assertEqual(creation.data["phase"], "confirm")
        self.assertEqual(len(self.registry().records), 2)
        self.assertEqual(self.calls, [])
        _, ssh, _ = self.invoke(["2", "1", "y"])
        ssh.assert_not_called()
        self.assertEqual(self.registry().records[creation.data["identity"]]["status"], "active")

    def test_apply_failure_resumes_same_identity_without_repeating_confirmation(self):
        with self.assertRaisesRegex(DeployError, "entry offline"):
            self.invoke(["2", "1", "", "n", "n", "entry.example", "", "y", "y"],
                        transport=lambda *_: (_ for _ in ()).throw(DeployError("entry offline")))
        creation = self.draft()
        self.assertEqual(creation.data["phase"], "apply")
        child_id = creation.data["identity"]
        manager = RemoteRelayManager(self.client, self.registry(), self.config)
        intent = manager.pending_path(child_id).read_bytes()
        for option in ("2", "3"):
            with self.subTest(option=option), self.assertRaisesRegex(DeployError, "菜单选项无效"):
                self.invoke(["2", option])
        with self.assertRaisesRegex(DeployError, "继续原操作"):
            self.invoke([], action="remote-relay", extra=("--local-port", "7999"))
        self.assertEqual(manager.pending_path(child_id).read_bytes(), intent)
        output, ssh, prompts = self.invoke(["2", "1"])
        ssh.assert_not_called()
        self.assertEqual(prompts.call_count, 2)
        self.assertEqual(self.calls[0]["identity"], child_id)
        self.assertEqual(len(self.registry().records), 3)
        self.assertEqual(self.registry().records[child_id]["status"], "active")
        self.assertFalse(creation.path.exists())
        self.assertIn("已创建", output)

    def test_completed_apply_with_lost_final_cleanup_does_not_create_duplicate(self):
        with patch.object(RemoteCreation, "complete", side_effect=DeployError("cleanup failed")), \
                self.assertRaisesRegex(DeployError, "cleanup failed"):
            self.invoke(["2", "1", "", "n", "n", "entry.example", "", "y", "y"])
        creation = self.draft()
        self.assertEqual(self.registry().records[creation.data["identity"]]["status"], "active")
        self.calls.clear()
        self.invoke(["2", "1"])
        self.assertEqual(self.calls, [])
        self.assertEqual(len(self.registry().records), 3)
        self.assertFalse(creation.path.exists())

    def test_deleting_failed_creation_clears_original_node_draft(self):
        with self.assertRaises(DeployError):
            self.invoke(["2", "1", "", "n", "n", "entry.example", "", "y", "y"],
                        transport=lambda *_: (_ for _ in ()).throw(DeployError("offline")))
        creation = self.draft()
        with patch.object(deploy_relay, "ssh_call", self.transport):
            self.cli(["remove", creation.data["identity"]], answers=["y"])
        self.assertFalse(creation.path.exists())
        self.assertEqual(len(self.registry().records), 2)

    def test_saved_draft_strictly_keeps_selected_exit_connection(self):
        creation = self.fail_binding()
        remote_id = self.registry().records[self.exit_id]["remote_node_id"]
        self.node(remote_id)["Link"] = self.node(remote_id)["Link"].replace(":26193", ":26200")
        with self.assertRaisesRegex(DeployError, "落地已变化"):
            self.invoke(["2", "1"])
        self.assertEqual(len(self.registry().records), 2)
        self.assertEqual(self.draft().values, creation.values)

    def test_remote_helper_probe_only_reports_missing_runtime_for_its_own_exit_code(self):
        entry = dict(self.registry().records[ENTRY], ssh={"target": "entry.example", "port": 22,
                     "identity": None, "password": False},
                     server={'backend': 'project', 'identity': ENTRY, 'fingerprint': parse_node_link(VLESS).fingerprint})
        with patch.dict(sys.modules, {"deploy": fixtures.deploy}), \
                patch.object(fixtures.deploy, "SSH") as ssh, \
                patch.object(fixtures.deploy, "export_node", return_value=fixtures.NODE):
            ssh.return_value.run.side_effect = fixtures.deploy.SSHCommandError("denied", 255)
            with self.assertRaises(fixtures.deploy.SSHCommandError):
                deploy_relay.ssh_call(entry, {"operation": "inspect", "identity": CHAIN})
            ssh.return_value.run.side_effect = fixtures.deploy.SSHCommandError("missing", 112)
            with self.assertRaisesRegex(DeployError, "self-update"):
                deploy_relay.ssh_call(entry, {"operation": "inspect", "identity": CHAIN})
