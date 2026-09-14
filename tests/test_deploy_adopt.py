import base64
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import deploy
from deploy_adopt import adopt_manifest, prepare_adoption
from deploy_resources import ManagedDeployments, SingBox, DeployError
from test_deploy_resources import sample_config


def uri(outbound):
    tls = outbound["tls"]
    return (f"vless://{outbound['uuid']}@{outbound['server']}:{outbound['server_port']}?" +
            urllib.parse.urlencode({"type": "tcp", "security": "reality", "flow": "xtls-rprx-vision",
                                    "sni": tls["server_name"], "pbk": tls["reality"]["public_key"],
                                    "sid": tls["reality"]["short_id"], "fp": "chrome"}))


def fixture():
    base = sample_config()
    hk = dict(base["outbounds"][0], tag="hk-out")
    us = dict(copy.deepcopy(hk), tag="us-out", server="us.example", uuid="00000000-0000-4000-8000-000000000003")
    home_remote = dict(copy.deepcopy(hk), server="home.example", server_port=26192)
    obsolete = dict(copy.deepcopy(hk), tag="old-out", server="obsolete.example")
    inbounds = [dict(base["inbounds"][0], tag=tag, listen_port=port, password=password)
                for tag, port, password in (("old-in", 7897, "old"), ("hk-in", 7896, "hk-pass"),
                                            ("us-in", 7899, "us-pass"), ("home-in", 7898, "home-pass"))]
    box = {"inbounds": inbounds + [base["inbounds"][1]],
           "outbounds": [obsolete, hk, us, {"type": "socks", "tag": "home-out", "server": "home.example",
                                            "server_port": 26193, "detour": "us-out"}, {"type": "direct", "tag": "direct"}],
           "route": {"final": "old-out", "rules": [{"inbound": [f"{name}-in"], "action": "route", "outbound": f"{name}-out"}
                                                    for name in ("hk", "us", "home")] +
                     [{"inbound": ["other-in"], "action": "route", "outbound": "direct"}]}}
    nodes = []
    for ident, name, port, password in ((917, "HK local", 7896, "hk-pass"), (913, "US local", 7899, "us-pass"),
                                       (507, "Home local", 7898, "home-pass")):
        auth = base64.urlsafe_b64encode(f"aes-128-gcm:{password}".encode()).decode().rstrip("=")
        nodes.append({"ID": ident, "Name": name, "Link": f"ss://{auth}@127.0.0.1:{port}", "Protocol": "ss",
                      "NameMode": "remark", "SourceID": 0, "Group": "SM", "DialerProxyName": ""})
    for ident, name, outbound, source, relay in ((918, "HK", hk, 11, ""), (912, "US", us, 10, ""),
                                               (501, "Home", home_remote, 0, "US")):
        nodes.append({"ID": ident, "Name": name, "Link": uri(outbound), "LinkHost": outbound["server"],
                      "NameMode": "remark", "Protocol": "vless", "SourceID": source, "Group": "SM", "DialerProxyName": relay})
    manifest = {"groups": [
        {"name": "HK", "inbound": "hk-in", "outbound": "hk-out", "airport_id": 11, "remote_node_id": 918, "local_node_id": 917, "relay": None},
        {"name": "US", "inbound": "us-in", "outbound": "us-out", "airport_id": 10, "remote_node_id": 912, "local_node_id": 913, "relay": None},
        {"name": "Home", "inbound": "home-in", "outbound": "home-out", "airport_id": None, "remote_node_id": 501, "local_node_id": 507, "relay": "US"},
    ], "remove_inbounds": ["old-in"], "remove_outbounds": ["old-out"], "default_outbound": "direct"}
    return box, nodes, manifest


class MemoryClient(deploy.SublinkPro):
    def __init__(self, nodes):
        self.url = "https://sublink.example"
        self.data = copy.deepcopy(nodes)
        self.airports = {ident: {"id": ident, "name": name, "url": f"https://{name.lower()}.example/sub/id",
                                 **copy.deepcopy(deploy.AIRPORT_DEFAULTS)} for ident, name in ((10, "US Airport"), (11, "HK Airport"))}
        self.fail_once = False

    def all_nodes(self):
        return copy.deepcopy(self.data)

    def node_tags(self, node_id):
        return ["stable"]

    def request(self, path, fields=None, **kwargs):
        if path.startswith("airports/"):
            ident = int(path.split("/")[1])
            if fields is not None:
                self.airports[ident] = dict(fields, id=ident)
            return copy.deepcopy(self.airports[ident])
        if path == "nodes/update":
            node = next(n for n in self.data if n["Name"] == fields["oldname"] and n["Link"] == fields["oldlink"])
            node.update(Name=fields["name"], Link=fields["link"], NameMode=fields["nameMode"], Group=fields["group"],
                        DialerProxyName=fields["dialerProxyName"])
            if self.fail_once:
                self.fail_once = False
                raise DeployError("response lost")
            return None
        raise AssertionError(path)


class AdoptionTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.before, nodes, self.manifest = fixture()
        self.client = MemoryClient(nodes)
        self.path = self.root / "config.json"
        self.path.write_text(json.dumps(self.before))
        self.path.chmod(0o600)
        self.manifest_path = self.root / "adopt.json"
        self.manifest_path.write_text(json.dumps(self.manifest))
        self.manifest_path.chmod(0o600)
        self.config = {"SINGBOX_CONFIG": str(self.path), "SINGBOX_BINARY": sys.executable, "SINGBOX_SERVICE_LABEL": "test"}
        self.state = deploy.ResumeState(self.root / ".deploy-state")
        for patcher in (patch.object(sys, "platform", "darwin"), patch.object(SingBox, "check_payload"),
                        patch.object(SingBox, "reload"), patch.object(deploy, "SublinkPro", return_value=self.client)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def run_adoption(self):
        adopt_manifest(self.config, self.root / ".env", self.manifest_path, self.state)

    def test_adoption_preserves_connections_and_rewrites_all_references(self):
        original_links = {n["ID"]: urllib.parse.urlsplit(n["Link"])._replace(fragment="").geturl() for n in self.client.data}
        self.run_adoption()
        after = json.loads(self.path.read_bytes())
        self.assertEqual(after["route"]["final"], "direct")
        self.assertNotIn("old-in", [n["tag"] for n in after["inbounds"]])
        self.assertNotIn("old-out", [n["tag"] for n in after["outbounds"]])
        self.assertEqual(next(n for n in after["outbounds"] if n["tag"] == "socks-Home-out")["detour"], "vless-US-out")
        self.assertIn({"inbound": ["ss-Home-in"], "action": "route", "outbound": "socks-Home-out"}, after["route"]["rules"])
        self.assertEqual(after["inbounds"][-1], self.before["inbounds"][-1])
        for node in self.client.data:
            self.assertEqual(urllib.parse.urlsplit(node["Link"])._replace(fragment="").geturl(), original_links[node["ID"]])
        records = ManagedDeployments(self.state).records
        self.assertEqual(len(records), 3)
        self.assertTrue(all(r["kind"] == "adopted" and r["status"] == "active" for r in records.values()))
        by_name = {r["node_name"]: (key, r) for key, r in records.items()}
        self.assertEqual(by_name["Home"][1]["relay_id"], by_name["US"][0])
        self.assertEqual(by_name["Home"][1]["remote_node_id"], 501)
        self.assertIsNone(by_name["Home"][1]["airport_id"])
        self.run_adoption()
        self.assertEqual(json.loads(self.path.read_bytes()), after)

    def test_interrupted_api_write_can_resume_without_changing_connection_parameters(self):
        self.client.fail_once = True
        with self.assertRaises(DeployError):
            self.run_adoption()
        self.assertEqual(json.loads(self.path.read_bytes()), self.before)
        self.assertTrue(all(r["status"] == "adopting" for r in ManagedDeployments(self.state).records.values()))
        self.run_adoption()
        self.assertTrue(all(r["status"] == "active" for r in ManagedDeployments(self.state).records.values()))

    def test_external_change_after_interruption_is_not_overwritten(self):
        self.client.fail_once = True
        with self.assertRaises(DeployError):
            self.run_adoption()
        changed = copy.deepcopy(self.before)
        changed["route"]["final"] = "us-out"
        self.path.write_text(json.dumps(changed))
        with self.assertRaises(DeployError):
            self.run_adoption()
        self.assertEqual(json.loads(self.path.read_bytes()), changed)

    def test_unknown_reference_to_removed_outbound_blocks_cleanup(self):
        before = copy.deepcopy(self.before)
        before["outbounds"].append({"type": "socks", "tag": "shared", "server": "x", "server_port": 1, "detour": "old-out"})
        self.path.write_text(json.dumps(before))
        with self.assertRaises(DeployError):
            self.run_adoption()
        self.assertEqual(json.loads(self.path.read_bytes()), before)
