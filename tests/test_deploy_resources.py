import fcntl
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import deploy_resources as resources
from deploy import ResumeState


IDENTITY = "a" * 32
VLESS = "vless://00000000-0000-4000-8000-000000000001@new.example:443?security=reality&type=tcp&flow=xtls-rprx-vision&sni=www.cloudflare.com&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=abcd&fp=chrome"
SS = "ss://YWVzLTEyOC1nY206bmV3LXBhc3N3b3Jk@127.0.0.1:7900#managed"


def sample_config():
    return {
        "log": {"level": "error"},
        "inbounds": [
            {"type": "shadowsocks", "tag": "template-in", "listen": "127.0.0.1", "listen_port": 7896,
             "method": "aes-128-gcm", "password": "old-password"},
            {"type": "mixed", "tag": "other-in", "listen": "127.0.0.1", "listen_port": 10810},
        ],
        "outbounds": [
            {"type": "vless", "tag": "template-out", "server": "old.example", "server_port": 1234,
             "uuid": "00000000-0000-4000-8000-000000000002", "flow": "xtls-rprx-vision", "network": "tcp",
             "tls": {"enabled": True, "server_name": "old.example", "utls": {"enabled": True, "fingerprint": "chrome"},
                     "reality": {"enabled": True, "public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "short_id": "aa"}}},
            {"type": "direct", "tag": "direct"},
        ],
        "route": {"final": "direct", "rules": [{"inbound": ["template-in"], "action": "route", "outbound": "template-out"}]},
    }


class SingBoxTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.path = self.root / "config.json"
        self.write(sample_config())
        platform = patch.object(resources.sys, "platform", "darwin")
        platform.start()
        self.addCleanup(platform.stop)
        self.box = resources.SingBox({"SINGBOX_CONFIG": str(self.path), "SINGBOX_BINARY": sys.executable,
                                     "SINGBOX_SERVICE_LABEL": "test.singbox"})
        check = patch.object(self.box, "check_payload")
        self.check = check.start()
        self.addCleanup(check.stop)
        reload = patch.object(self.box, "reload")
        self.reload = reload.start()
        self.addCleanup(reload.stop)

    def write(self, document):
        self.path.write_text(json.dumps(document, indent=2) + "\n")
        self.path.chmod(0o600)

    def install(self):
        plan = self.box.plan(IDENTITY, VLESS, SS)
        return self.box.commit(plan)

    def test_clone_uses_new_credentials_and_preserves_unrelated_configuration(self):
        original = sample_config()
        plan = self.box.plan(IDENTITY, VLESS, SS)
        self.assertEqual(json.loads(self.path.read_bytes()), original)
        metadata = self.box.commit(plan)
        result = json.loads(self.path.read_bytes())
        self.assertEqual(result["inbounds"][:2], original["inbounds"])
        self.assertEqual(result["outbounds"][:2], original["outbounds"])
        self.assertEqual(result["route"]["rules"][1:], original["route"]["rules"])
        self.assertEqual(result["route"]["final"], "direct")
        self.assertEqual(result["inbounds"][-1]["password"], "new-password")
        self.assertEqual(result["inbounds"][-1]["listen_port"], 7900)
        self.assertEqual(result["outbounds"][-1]["server"], "new.example")
        self.assertEqual(result["outbounds"][-1]["tls"]["server_name"], "www.cloudflare.com")
        self.assertFalse(metadata["needs_reload"])
        self.assertNotIn("new-password", json.dumps(metadata))
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertTrue(Path(metadata["backup_file"]).exists())

    def test_repeated_sync_does_not_duplicate_or_restart_unchanged_config(self):
        metadata = self.install()
        self.reload.reset_mock()
        plan = self.box.plan(IDENTITY, VLESS, SS, metadata)
        self.box.commit(plan)
        self.reload.assert_not_called()
        self.assertEqual(len(json.loads(self.path.read_bytes())["inbounds"]), 3)

    def test_new_config_does_not_require_existing_template_entries(self):
        self.write({"inbounds": [], "outbounds": [{"type": "direct", "tag": "direct"}],
                    "route": {"rules": [], "final": "direct"}})
        self.install()
        result = json.loads(self.path.read_bytes())
        self.assertEqual(len(result["inbounds"]), 1)
        self.assertEqual(result["inbounds"][0]["listen"], "127.0.0.1")
        self.assertEqual(result["outbounds"][-1]["type"], "vless")

    def test_foreign_port_collision_stops_before_write(self):
        before = self.path.read_bytes()
        with self.assertRaises(resources.DeployError):
            self.box.plan(IDENTITY, VLESS, SS.replace(":7900", ":7896"))
        self.assertEqual(self.path.read_bytes(), before)

    def test_delete_only_removes_owned_entries_and_is_idempotent(self):
        metadata = self.install()
        plan = self.box.plan(IDENTITY, metadata=metadata, remove=True)
        self.assertIsNone(self.box.commit(plan))
        self.assertEqual(json.loads(self.path.read_bytes()), sample_config())
        self.reload.reset_mock()
        self.box.commit(self.box.plan(IDENTITY, metadata=metadata, remove=True))
        self.reload.assert_not_called()

    def test_shared_detour_prevents_deletion(self):
        metadata = self.install()
        document = json.loads(self.path.read_bytes())
        document["outbounds"].append({"type": "socks", "tag": "shared", "server": "other.example", "server_port": 1080,
                                       "detour": metadata["outbound_tag"]})
        self.write(document)
        before = self.path.read_bytes()
        with self.assertRaises(resources.DeployError):
            self.box.plan(IDENTITY, metadata=metadata, remove=True)
        self.assertEqual(self.path.read_bytes(), before)

    def test_manual_owned_changes_are_not_overwritten(self):
        metadata = self.install()
        document = json.loads(self.path.read_bytes())
        document["outbounds"][-1]["server"] = "manual.example"
        self.write(document)
        with self.assertRaises(resources.DeployError):
            self.box.plan(IDENTITY, VLESS, SS, metadata)

    def test_concurrent_edit_is_not_lost(self):
        plan = self.box.plan(IDENTITY, VLESS, SS)
        modified = sample_config()
        modified["log"]["timestamp"] = True
        self.write(modified)
        with self.assertRaises(resources.DeployError):
            self.box.commit(plan)
        self.assertEqual(json.loads(self.path.read_bytes()), modified)
        self.reload.assert_not_called()

    def test_other_process_config_lock_blocks_commit(self):
        plan = self.box.plan(IDENTITY, VLESS, SS)
        lock = self.root / ".one-key-proxy.lock"
        lock.touch(mode=0o600)
        with lock.open("rb") as stream:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(resources.DeployError):
                self.box.commit(plan)
        self.assertEqual(self.path.read_bytes(), plan.original)

    def test_failed_validation_never_changes_current_file(self):
        before = self.path.read_bytes()
        self.check.side_effect = resources.DeployError("invalid")
        with self.assertRaises(resources.DeployError):
            self.box.plan(IDENTITY, VLESS, SS)
        self.assertEqual(self.path.read_bytes(), before)

    def test_failed_reload_restores_previous_configuration(self):
        before = self.path.read_bytes()
        plan = self.box.plan(IDENTITY, VLESS, SS)
        self.reload.side_effect = [resources.DeployError("failed"), None]
        with self.assertRaises(resources.DeployError):
            self.box.commit(plan)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(self.reload.call_count, 2)

    def test_interrupted_commit_reloads_on_retry(self):
        plan = self.box.plan(IDENTITY, VLESS, SS)
        Path(plan.metadata["backup_file"]).write_bytes(plan.original)
        Path(plan.metadata["backup_file"]).chmod(0o600)
        self.path.write_bytes(plan.payload)
        retried = self.box.plan(IDENTITY, VLESS, SS, plan.metadata)
        self.assertEqual(retried.original, retried.payload)
        self.assertTrue(retried.metadata["needs_reload"])
        self.assertFalse(self.box.commit(retried)["needs_reload"])
        self.reload.assert_called_once()

    def test_interrupted_rollback_cannot_overwrite_unrelated_later_edits(self):
        plan = self.box.plan(IDENTITY, VLESS, SS)
        backup = Path(plan.metadata["backup_file"])
        backup.write_bytes(plan.original)
        backup.chmod(0o600)
        modified = json.loads(plan.payload)
        modified["log"]["timestamp"] = True
        self.write(modified)
        with self.assertRaises(resources.DeployError):
            self.box.plan(IDENTITY, VLESS, SS, plan.metadata)
        self.assertEqual(json.loads(self.path.read_bytes()), modified)

    def test_registry_survives_completion_and_contains_no_proxy_credentials(self):
        state = ResumeState(self.root / ".deploy-state")
        with state.locked():
            state.start("add", self.root / ".env")
            registry = resources.ManagedDeployments(state)
            registry.register(IDENTITY, "root@expired.example", self.root / ".env", "https://sublink.example", "My VPS")
            plan = self.box.plan(IDENTITY, VLESS, SS)
            registry.update(IDENTITY, singbox=plan.metadata)
            registry.update(IDENTITY, singbox=self.box.commit(plan), status="active")
            state.complete()
            restored = resources.ManagedDeployments(state)
            self.assertIn(IDENTITY, restored.records)
            self.assertEqual(restored.select("root@expired.example"), IDENTITY)
            raw = registry.path.read_text()
            self.assertNotIn("new-password", raw)
            self.assertNotIn(VLESS, raw)
            self.assertNotIn("00000000-0000-4000-8000-000000000001", raw)
            self.assertEqual(registry.path.stat().st_mode & 0o777, 0o600)
            restored.forget(IDENTITY)
            self.assertEqual(resources.ManagedDeployments(state).records, {})

    def test_id_tags_and_relay_preserve_protocol_and_children(self):
        plan = self.box.plan(IDENTITY, VLESS, SS)
        metadata = self.box.commit(plan)
        self.assertEqual(metadata["inbound_tag"], "okp-" + IDENTITY + "-in")
        self.assertEqual(metadata["outbound_tag"], "okp-" + IDENTITY + "-out")
        document = json.loads(self.path.read_bytes())
        document["outbounds"].append({"type": "socks", "tag": "socks-home-out", "server": "home.example",
                                       "server_port": 1080, "detour": metadata["outbound_tag"]})
        self.write(document)
        changed = self.box.plan_relay(IDENTITY, metadata, "template-out")
        metadata = self.box.commit(changed)
        current = json.loads(self.path.read_bytes())
        managed = next(o for o in current["outbounds"] if o["tag"] == self.box.tags(IDENTITY)[1])
        self.assertEqual(managed["detour"], "template-out")
        self.assertEqual(next(o for o in current["outbounds"] if o["tag"] == "socks-home-out")["detour"], self.box.tags(IDENTITY)[1])
        self.box.commit(self.box.plan_relay(IDENTITY, metadata, None))
        with self.assertRaises(resources.DeployError):
            self.box.plan(IDENTITY, metadata=metadata, remove=True)

    def test_relay_rejects_self_and_config_cycle(self):
        metadata = self.install()
        with self.assertRaises(resources.DeployError):
            self.box.plan_relay(IDENTITY, metadata, metadata["outbound_tag"])
        document = json.loads(self.path.read_bytes())
        document["outbounds"][0]["detour"] = metadata["outbound_tag"]
        self.write(document)
        with self.assertRaises(resources.DeployError):
            self.box.plan_relay(IDENTITY, metadata, "template-out")

    def test_metadata_requires_id_tags_and_explicit_owner(self):
        metadata = self.install()
        for inbound, outbound in (("ss-Old-in", "vless-Old-out"),
                                  ("okp-" + IDENTITY + "-ss-in", "okp-" + IDENTITY + "-vless-out")):
            with self.subTest(inbound=inbound), self.assertRaises(ValueError):
                self.box.validate_metadata(IDENTITY, dict(metadata, inbound_tag=inbound, outbound_tag=outbound))
        metadata.pop("owner_id")
        with self.assertRaises(ValueError):
            self.box.validate_metadata(IDENTITY, metadata)

    def test_old_inventory_and_resume_versions_are_rejected(self):
        state = ResumeState(self.root / ".deploy-state")
        with state.locked():
            registry = resources.ManagedDeployments(state)
            registry.register(IDENTITY, "root@host", self.root / ".env", "https://sublink.example", "Node")
            document = json.loads(registry.path.read_bytes())
            document["version"] = 1
            resources.atomic_write(registry.path, json.dumps(document).encode())
            with self.assertRaises(resources.DeployError):
                resources.ManagedDeployments(state)
            state.start("add", self.root / ".env")
            checkpoint = dict(state.data, version=1)
            resources.atomic_write(state.path, json.dumps(checkpoint).encode())
            with self.assertRaises(resources.DeployError):
                state.load()

    def test_registry_detects_relay_cycles_and_dependents(self):
        state = ResumeState(self.root / ".deploy-state")
        with state.locked():
            registry = resources.ManagedDeployments(state)
            for identity, name in (("a" * 32, "US"), ("b" * 32, "Home")):
                registry.register(identity, name, self.root / ".env", "https://sublink.example", name)
                registry.update(identity, status="active")
            registry.validate_relay("b" * 32, "a" * 32)
            registry.update("b" * 32, relay_id="a" * 32)
            self.assertEqual(registry.select("US"), "a" * 32)
            self.assertEqual(registry.dependents("a" * 32), ["Home"])
            with self.assertRaises(resources.DeployError):
                registry.validate_relay("a" * 32, "b" * 32)


if __name__ == "__main__":
    unittest.main()
