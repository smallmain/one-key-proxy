"""Local sing-box transactions and persistent deployment ownership records."""

import base64
import copy
from dataclasses import dataclass
import fcntl
import graphlib
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.parse
import uuid
from deploy_templates import SINGBOX_INBOUND, SINGBOX_OUTBOUND


class DeployError(Exception):
    pass


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def atomic_write(path, content):
    fd, temporary = tempfile.mkstemp(prefix=".okp-write-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def is_standalone(record):
    return record.get("kind") in ("node", "remote-relay") or (record.get("airport_id") is None and record.get("remote_node_id") is not None)


def configuration_label(record):
    return record["node_name"] if is_standalone(record) else f"{record['airport_name']} / {record['node_name']}"


def remote_relay_name(entry, exit_node):
    return exit_node["node_name"] + "(" + entry["node_name"] + "中转)"


def remote_relay_record(entry_id, exit_id, fingerprint=None, *, auto_name=True):
    return {"entry_id": entry_id, "exit_id": exit_id, "exit_fingerprint": fingerprint,
            "pending_exit_id": None, "auto_name": auto_name}


class ManagedDeployments:
    def __init__(self, state):
        self.state = state
        self.path = state.directory / "managed.json"
        self.records = {}
        if not state.directory.exists():
            return
        state.check_directory()
        try:
            fd = state.open_private(self.path, os.O_RDONLY)
        except FileNotFoundError:
            return
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            raw = stream.read(2 * 1024 * 1024 + 1)
        try:
            if len(raw) > 2 * 1024 * 1024:
                raise ValueError
            document = json.loads(raw)
            if set(document) != {"version", "deployments"} or document["version"] != 3:
                raise ValueError
            self.records = document["deployments"]
            self.validate()
        except (ValueError, TypeError, KeyError):
            raise DeployError("受管部署清单无效，请检查 .deploy-state/managed.json。") from None

    def validate(self):
        if not isinstance(self.records, dict):
            raise ValueError
        allowed = {"target", "env_file", "sublink_url", "airport_id", "local_node_id", "airport_name",
                   "node_name", "local_port", "singbox", "status", "kind", "remote_node_id", "relay_id",
                   "remote_fingerprints", "local_source", "ssh", "server", "residential", "part_errors", "remote_relay"}
        for identity, record in self.records.items():
            if not re.fullmatch(r"[0-9a-f]{32}", identity) or not isinstance(record, dict) or set(record) != allowed:
                raise ValueError
            for key in ("target", "env_file", "sublink_url", "airport_name", "node_name"):
                if not isinstance(record[key], str) or any(ord(c) < 32 for c in record[key]):
                    raise ValueError
            if not Path(record["env_file"]).is_absolute() or not record["target"] or not record["sublink_url"]:
                raise ValueError
            if record["status"] not in ("syncing", "active", "deleting", "adopting", "relaying", "updating") or record["kind"] not in ("deployment", "adopted", "subscription", "node", "remote-relay"):
                raise ValueError
            if (record["local_source"] not in ("remote", "custom") or not isinstance(record["remote_fingerprints"], list)
                    or any(not isinstance(v, str) or not re.fullmatch(r"[0-9a-f]{64}", v) for v in record["remote_fingerprints"])):
                raise ValueError
            if record["relay_id"] is not None and not re.fullmatch(r"[0-9a-f]{32}", record["relay_id"]):
                raise ValueError
            for key in ("airport_id", "local_node_id", "remote_node_id", "local_port"):
                if record[key] is not None and (type(record[key]) is not int or record[key] <= 0):
                    raise ValueError
            if record["singbox"] is not None:
                SingBox.validate_metadata(identity, record["singbox"])
            if record["ssh"] is not None:
                self.validate_ssh(record["ssh"])
            if type(record["residential"]) is not bool:
                raise ValueError("invalid residential setting")
            if (not isinstance(record["part_errors"], dict) or set(record["part_errors"]) - {"source", "local", "ssh", "server"}
                    or any(not isinstance(v, str) or len(v) > 400 or any(ord(c) < 32 for c in v) for v in record["part_errors"].values())):
                raise ValueError("invalid part diagnostics")
            if record["server"] is not None:
                server = record["server"]
                if (not isinstance(server, dict) or set(server) != {"backend", "identity", "fingerprint"}
                        or server["backend"] not in ("project", "standalone")
                        or not re.fullmatch(r"[0-9a-f]{32}", server["identity"])
                        or not re.fullmatch(r"[0-9a-f]{64}", server["fingerprint"]) or record["ssh"] is None):
                    raise ValueError("invalid server management")
            relay = record["remote_relay"]
            if (record["kind"] == "remote-relay") != (relay is not None):
                raise ValueError("invalid remote relay")
            if relay is not None:
                if (not isinstance(relay, dict) or set(relay) != {"entry_id", "exit_id", "exit_fingerprint", "pending_exit_id", "auto_name"}
                        or type(relay["auto_name"]) is not bool
                        or record["relay_id"] is not None or record["local_source"] != "remote"
                        or any(not isinstance(relay[key], str) or not re.fullmatch(r"[0-9a-f]{32}", relay[key])
                               for key in ("entry_id", "exit_id"))
                        or (relay["exit_fingerprint"] is not None and not re.fullmatch(r"[0-9a-f]{64}", relay["exit_fingerprint"]))):
                    raise ValueError("invalid remote relay")
                if relay["pending_exit_id"] is not None and not re.fullmatch(r"[0-9a-f]{32}", relay["pending_exit_id"]):
                    raise ValueError("invalid pending exit")
        if any(record["relay_id"] is not None and record["relay_id"] not in self.records for record in self.records.values()):
            raise ValueError("missing relay")
        graph = self.graph()
        if any(parent not in self.records for parents in graph.values() for parent in parents):
            raise ValueError("missing remote relay dependency")
        tuple(graphlib.TopologicalSorter(graph).static_order())

    @staticmethod
    def validate_ssh(ssh):
        if (not isinstance(ssh, dict) or set(ssh) != {"target", "port", "identity", "password"}
                or not isinstance(ssh["target"], str) or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.:@\[\]-]*", ssh["target"])
                or (ssh["port"] is not None and (type(ssh["port"]) is not int or not 1 <= ssh["port"] <= 65535))
                or (ssh["identity"] is not None and (not isinstance(ssh["identity"], str) or any(ord(c) < 32 for c in ssh["identity"])))
                or type(ssh["password"]) is not bool):
            raise ValueError("invalid SSH binding")

    def graph(self):
        return {key: ([r["relay_id"]] if r["relay_id"] else []) +
                ([r["remote_relay"]["entry_id"], r["remote_relay"]["exit_id"]] +
                 ([r["remote_relay"]["pending_exit_id"]] if r["remote_relay"].get("pending_exit_id") else [])
                 if r.get("remote_relay") else [])
                for key, r in self.records.items()}

    def save(self):
        try:
            self.validate()
        except (ValueError, TypeError, KeyError):
            raise DeployError("受管部署清单包含无效数据，未保存。") from None
        content = json.dumps({"version": 3, "deployments": self.records}, ensure_ascii=False, indent=2).encode() + b"\n"
        atomic_write(self.path, content)

    def register(self, identity, target, env_file, sublink_url, name, *, kind="deployment", remote_relay=None):
        identity = identity.lower()
        existing = self.records.get(identity)
        if existing and (existing["sublink_url"] != sublink_url or existing["status"] in ("deleting", "adopting", "relaying", "updating")):
            raise DeployError("此部署已绑定其他 SublinkPro 地址或正在删除，拒绝重新登记。")
        if not existing:
            self.records[identity] = {"target": target, "env_file": str(env_file), "sublink_url": sublink_url,
                                      "airport_id": None, "local_node_id": None,
                                      "airport_name": "" if kind in ("node", "remote-relay") else name,
                                      "node_name": name, "local_port": None, "singbox": None, "status": "syncing",
                                      "kind": kind, "remote_node_id": None, "relay_id": None,
                                      "local_source": "remote", "remote_fingerprints": [], "ssh": None, "server": None,
                                      "residential": False, "part_errors": {},
                                      "remote_relay": copy.deepcopy(remote_relay)}
        self.update(identity, target=target, env_file=str(env_file), status="syncing")

    def update(self, identity, **values):
        self.update_many({identity: values})

    def update_many(self, updates):
        for identity, values in updates.items():
            self.records[identity].update(copy.deepcopy(values))
        self.save()

    def forget(self, identity):
        del self.records[identity]
        self.save()
        from deploy_credentials import Credentials
        Credentials(self.state).forget_panel(identity)

    def select(self, value):
        matches = [identity for identity, record in self.records.items()
                   if value in (identity, record["target"], record["airport_name"], record["node_name"])]
        if len(matches) != 1:
            raise DeployError("未找到唯一的受管部署，请使用 list 查看并指定完整安装 ID。")
        return matches[0]

    def validate_relay(self, identity, relay_id):
        if relay_id is not None:
            if relay_id not in self.records or self.records[relay_id]["status"] != "active":
                raise DeployError("中转节点不存在或尚未完成配置。")
            if self.records[identity]["sublink_url"] != self.records[relay_id]["sublink_url"]:
                raise DeployError("中转必须属于同一 SublinkPro 实例。")
        graph = self.graph()
        graph[identity] = [relay_id] if relay_id else []
        try:
            tuple(graphlib.TopologicalSorter(graph).static_order())
        except graphlib.CycleError:
            raise DeployError("中转配置会形成循环或引用自身。") from None

    def dependents(self, identity):
        return [record["node_name"] for record in self.records.values()
                if record["relay_id"] == identity or (record.get("remote_relay") and
                   identity in (record["remote_relay"]["entry_id"], record["remote_relay"]["exit_id"], record["remote_relay"].get("pending_exit_id")))]


@dataclass
class SingBoxPlan:
    original: bytes
    payload: bytes
    metadata: dict
    hashes: dict
    removed: bool = False
    rewrite: bool = False


class SingBox:
    def __init__(self, config):
        raw_path = config.get("SINGBOX_CONFIG", "")
        if not raw_path:
            raise DeployError("请配置 SINGBOX_CONFIG。")
        self.path = Path(raw_path).expanduser().absolute()
        self.binary = config.get("SINGBOX_BINARY") or "sing-box"
        self.label = config.get("SINGBOX_SERVICE_LABEL", "")
        if not shutil.which(self.binary):
            raise DeployError("找不到 SINGBOX_BINARY 指定的 sing-box。")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", self.label):
            raise DeployError("请配置有效的 SINGBOX_SERVICE_LABEL（macOS LaunchAgent）。")
        if sys.platform != "darwin":
            raise DeployError("当前自动 sing-box 集成使用 macOS launchd。")

    @staticmethod
    def tags(identity):
        if not re.fullmatch(r"[0-9a-f]{32}", identity):
            raise DeployError("安装标识无效。")
        return f"okp-{identity}-in", f"okp-{identity}-out"

    @staticmethod
    def validate_metadata(identity, metadata):
        inbound, outbound = SingBox.tags(identity)
        keys = {"config_file", "inbound_tag", "outbound_tag", "hashes", "needs_reload", "backup_file"}
        if not isinstance(metadata, dict) or set(metadata) != keys | {"owner_id"}:
            raise ValueError("invalid sing-box ownership")
        if (metadata["owner_id"] != identity or metadata["inbound_tag"] != inbound or metadata["outbound_tag"] != outbound
                or not Path(metadata["config_file"]).is_absolute() or type(metadata["needs_reload"]) is not bool
                or set(metadata["hashes"]) != {"inbound", "outbound", "rule"}):
            raise ValueError("invalid sing-box ownership")
        for values in metadata["hashes"].values():
            if not isinstance(values, list) or not values or any(not re.fullmatch(r"[0-9a-f]{64}", v) for v in values):
                raise ValueError("invalid sing-box fingerprints")
        backup = Path(metadata["backup_file"])
        if (backup.parent != Path(metadata["config_file"]).parent
                or not re.fullmatch(r"\.one-key-proxy-backup-[0-9a-f]{32}\.json", backup.name)):
            raise ValueError("invalid backup path")

    @staticmethod
    def read_private(path):
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid()
                    or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 8 * 1024 * 1024):
                raise DeployError("sing-box 配置/备份必须是当前用户拥有的 0600 普通文件。")
            return stream.read()

    def read(self):
        parent = self.path.parent.lstat()
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o022:
            raise DeployError("sing-box 配置目录权限不安全。")
        raw = self.read_private(self.path)
        try:
            document = json.loads(raw)
            if not isinstance(document, dict) or not isinstance(document.get("route"), dict):
                raise ValueError
            for key in ("inbounds", "outbounds"):
                items = document[key]
                if not isinstance(items, list) or any(not isinstance(item, dict) for item in items):
                    raise ValueError
                tags = [item.get("tag") for item in items]
                if any(not isinstance(tag, str) for tag in tags) or len(tags) != len(set(tags)):
                    raise ValueError
            if (not isinstance(document["route"].get("rules", []), list)
                    or any(not isinstance(rule, dict) for rule in document["route"].get("rules", []))):
                raise ValueError
        except (ValueError, TypeError, KeyError):
            raise DeployError("sing-box 配置需要有效 JSON 及唯一的入站/出站 tag。") from None
        return raw, document

    @staticmethod
    def templates(document=None):
        return copy.deepcopy(SINGBOX_INBOUND), copy.deepcopy(SINGBOX_OUTBOUND)

    def check_payload(self, payload):
        fd, temporary = tempfile.mkstemp(prefix=".okp-check-", suffix=".json", dir=self.path.parent)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(payload)
            try:
                result = subprocess.run([self.binary, "check", "-c", temporary], capture_output=True, timeout=30, check=False)
            except (OSError, subprocess.TimeoutExpired):
                raise DeployError("无法执行 sing-box 配置检查。") from None
            if result.returncode:
                raise DeployError("sing-box 配置检查失败，未替换当前配置。")
        finally:
            os.unlink(temporary)

    def check(self):
        raw, _ = self.read()
        self.check_payload(raw)

    @staticmethod
    def vless(template, link):
        try:
            uri = urllib.parse.urlsplit(link)
            values = urllib.parse.parse_qs(uri.query, strict_parsing=True)
            if any(len(v) != 1 for v in values.values()):
                raise ValueError
            query = {k: v[0] for k, v in values.items()}
            identity = str(uuid.UUID(urllib.parse.unquote(uri.username or "")))
            if (uri.scheme != "vless" or not uri.hostname or not uri.port or uri.password
                    or query.get("security") != "reality" or query.get("type", "tcp") not in ("tcp", "raw")
                    or query.get("flow") != "xtls-rprx-vision" or not query.get("sni") or not query.get("pbk")
                    or not re.fullmatch(r"[0-9a-fA-F]{0,16}", query.get("sid", ""))):
                raise ValueError
        except (ValueError, TypeError):
            raise DeployError("VLESS 链接必须是本项目的 TCP + REALITY + Vision 配置。") from None
        result = copy.deepcopy(template)
        result.update(server=uri.hostname, server_port=uri.port, uuid=identity, flow=query["flow"], network="tcp")
        result.pop("transport", None)
        result["tls"] = {"enabled": True, "server_name": query["sni"],
                         "utls": {"enabled": True, "fingerprint": query.get("fp", "chrome")},
                         "reality": {"enabled": True, "public_key": query["pbk"], "short_id": query.get("sid", "")}}
        return result

    @staticmethod
    def ss_parameters(link):
        try:
            uri = urllib.parse.urlsplit(link)
            if uri.scheme != "ss" or uri.hostname != "127.0.0.1" or not uri.port or uri.query:
                raise ValueError
            auth = urllib.parse.unquote(uri.netloc.rsplit("@", 1)[0])
            if ":" not in auth:
                auth = base64.b64decode(auth + "=" * (-len(auth) % 4), altchars=b"-_", validate=True).decode()
            method, password = auth.split(":", 1)
            if not method or not password:
                raise ValueError
            return uri.port, method, password
        except (ValueError, UnicodeError):
            raise DeployError("本地 SS 节点参数无法转换为 sing-box 入站。") from None

    @staticmethod
    def references(value, tags, key=""):
        if isinstance(value, dict):
            return any(SingBox.references(v, tags, k) for k, v in value.items())
        if isinstance(value, list):
            return any(SingBox.references(v, tags, key) for v in value)
        return key in ("inbound", "outbound", "outbounds", "detour", "final", "default") and isinstance(value, str) and value in tags

    def owned(self, document, identity, metadata, allow_references=False):
        inbound, outbound = (metadata["inbound_tag"], metadata["outbound_tag"]) if metadata else self.tags(identity)
        if metadata:
            self.validate_metadata(identity, metadata)
            if metadata["config_file"] != str(self.path):
                raise DeployError("sing-box 配置路径与受管记录不一致。")
        items = {"inbound": next((i for i in document["inbounds"] if i["tag"] == inbound), None),
                 "outbound": next((o for o in document["outbounds"] if o["tag"] == outbound), None)}
        rules = [r for r in document["route"].get("rules", [])
                 if r.get("inbound") == [inbound] and r.get("outbound") == outbound]
        if len(rules) > 1:
            raise DeployError("受管 sing-box 路由不唯一。")
        items["rule"] = rules[0] if rules else None
        for role, item in items.items():
            if item is not None and (not metadata or digest(item) not in metadata["hashes"][role]):
                raise DeployError("受管 sing-box 条目已被外部修改，拒绝覆盖或删除。")
        remainder = copy.deepcopy(document)
        remainder["inbounds"] = [i for i in document["inbounds"] if i["tag"] != inbound]
        remainder["outbounds"] = [o for o in document["outbounds"] if o["tag"] != outbound]
        remainder["route"]["rules"] = [r for r in document["route"].get("rules", []) if r not in rules]
        if not allow_references and self.references(remainder, {inbound, outbound}):
            raise DeployError("其他 sing-box 配置仍引用此部署，需先解除共享/链式引用。")
        return remainder

    def plan(self, identity, vless_link=None, ss_link=None, metadata=None, remove=False, relay_tag=None,
             outbound_config=None):
        original, document = self.read()
        candidate = self.owned(document, identity, metadata, allow_references=not remove)
        if metadata and metadata["needs_reload"] and Path(metadata["backup_file"]).exists():
            try:
                previous = json.loads(self.read_private(Path(metadata["backup_file"])))
                previous_remainder = self.owned(previous, identity, metadata, allow_references=not remove)
            except (ValueError, TypeError, KeyError, AttributeError):
                raise DeployError("未完成事务的 sing-box 备份无效，请先核验备份。") from None
            if previous_remainder != candidate:
                raise DeployError("未完成事务后，其他 sing-box 配置发生变化；请先核验，避免回滚覆盖手动修改。")
        inbound_tag, outbound_tag = self.tags(identity)
        if remove:
            if metadata is None:
                raise DeployError("缺少 sing-box 所有权记录。")
            expected = {}
        else:
            inbound, outbound = self.templates(document)
            port, method, password = self.ss_parameters(ss_link)
            if any(i.get("listen_port") == port for i in candidate["inbounds"]):
                raise DeployError("本地端口已被其他 sing-box 入站使用。")
            inbound.update(tag=inbound_tag, listen_port=port, method=method, password=password)
            outbound = copy.deepcopy(outbound_config) if outbound_config is not None else self.vless(outbound, vless_link)
            if outbound.get("type") not in ("vless", "socks", "shadowsocks"):
                raise DeployError("本地出站协议不受支持。")
            outbound.pop("detour", None)
            outbound["tag"] = outbound_tag
            if relay_tag:
                if relay_tag == outbound_tag or not any(o["tag"] == relay_tag for o in candidate["outbounds"]):
                    raise DeployError("sing-box 中转出站不存在或指向自身。")
                outbound["detour"] = relay_tag
            if any(i["tag"] == inbound_tag for i in candidate["inbounds"]) or any(o["tag"] == outbound_tag for o in candidate["outbounds"]):
                raise DeployError("管理 ID 对应的 sing-box 标签已存在。")
            rule = {"inbound": [inbound_tag], "action": "route", "outbound": outbound_tag}
            in_position = next((i for i, item in enumerate(document["inbounds"]) if item["tag"] == inbound_tag), len(candidate["inbounds"]))
            out_position = next((i for i, item in enumerate(document["outbounds"]) if item["tag"] == outbound_tag), len(candidate["outbounds"]))
            rule_position = next((i for i, item in enumerate(document["route"].get("rules", []))
                                  if item.get("inbound") == [inbound_tag] and item.get("outbound") == outbound_tag), 0)
            candidate["inbounds"].insert(in_position, inbound)
            candidate["outbounds"].insert(out_position, outbound)
            candidate["route"]["rules"].insert(rule_position, rule)
            expected = {"inbound": digest(inbound), "outbound": digest(outbound), "rule": digest(rule)}
        payload = json.dumps(candidate, ensure_ascii=False, indent=2).encode() + b"\n"
        changed = candidate != document
        if not changed:
            payload = original
        hashes = copy.deepcopy(metadata["hashes"]) if metadata else {k: [] for k in expected}
        for key, value in expected.items():
            hashes[key] = list(dict.fromkeys(hashes[key] + [value]))
        pending = bool(metadata and metadata["needs_reload"])
        backup = metadata["backup_file"] if pending else str(self.path.parent / f".one-key-proxy-backup-{uuid.uuid4().hex}.json")
        resource = {"config_file": str(self.path), "inbound_tag": inbound_tag, "outbound_tag": outbound_tag,
                    "hashes": hashes, "needs_reload": changed or pending, "backup_file": backup, "owner_id": identity}
        self.check_payload(payload)
        return SingBoxPlan(original, payload, resource, expected, remove)

    def plan_relay(self, identity, metadata, relay_tag):
        original, document = self.read()
        remainder = self.owned(document, identity, metadata, allow_references=True)
        if metadata["needs_reload"] and Path(metadata["backup_file"]).exists():
            previous = json.loads(self.read_private(Path(metadata["backup_file"])))
            if self.owned(previous, identity, metadata, allow_references=True) != remainder:
                raise DeployError("未完成的中转变更后有其他手动修改，请先核验备份。")
        candidate = copy.deepcopy(document)
        outbound = next(o for o in candidate["outbounds"] if o["tag"] == metadata["outbound_tag"])
        if relay_tag:
            if relay_tag == outbound["tag"] or not any(o["tag"] == relay_tag for o in candidate["outbounds"]):
                raise DeployError("中转出站无效。")
            outbound["detour"] = relay_tag
        else:
            outbound.pop("detour", None)
        try:
            tuple(graphlib.TopologicalSorter({o["tag"]: [o["detour"]] if o.get("detour") else []
                                             for o in candidate["outbounds"]}).static_order())
        except graphlib.CycleError:
            raise DeployError("sing-box 中转存在循环。") from None
        payload = json.dumps(candidate, ensure_ascii=False, indent=2).encode() + b"\n" if candidate != document else original
        resource = copy.deepcopy(metadata)
        resource["hashes"]["outbound"] = list(dict.fromkeys(resource["hashes"]["outbound"] + [digest(outbound)]))
        resource["needs_reload"] = payload != original or resource["needs_reload"]
        if not metadata["needs_reload"]:
            resource["backup_file"] = str(self.path.parent / f".one-key-proxy-backup-{uuid.uuid4().hex}.json")
        hashes = {"outbound": digest(outbound),
                  "inbound": digest(next(i for i in candidate["inbounds"] if i["tag"] == resource["inbound_tag"])),
                  "rule": digest(next(r for r in candidate["route"]["rules"] if r.get("inbound") == [resource["inbound_tag"]]
                                      and r.get("outbound") == resource["outbound_tag"]))}
        self.check_payload(payload)
        return SingBoxPlan(original, payload, resource, hashes)

    @staticmethod
    def rewrite_references(value, replacements, key=""):
        if isinstance(value, dict):
            return {k: SingBox.rewrite_references(v, replacements, k) for k, v in value.items()}
        if isinstance(value, list):
            return [SingBox.rewrite_references(v, replacements, key) for v in value]
        if key in ("inbound", "outbound", "outbounds", "detour", "final", "default") and isinstance(value, str):
            return replacements.get(value, value)
        return value

    def rewrite_plan(self, original, candidate, backup_file):
        payload = json.dumps(candidate, ensure_ascii=False, indent=2).encode() + b"\n"
        self.check_payload(payload)
        return SingBoxPlan(original, payload, {"backup_file": str(backup_file), "needs_reload": True}, {}, rewrite=True)

    def reload(self):
        service = f"gui/{os.getuid()}/{self.label}"
        try:
            result = subprocess.run(["launchctl", "kickstart", "-k", service], capture_output=True, timeout=20, check=False)
            if result.returncode:
                raise DeployError("无法重启 sing-box LaunchAgent。")
            for _ in range(15):
                time.sleep(0.2)
                status = subprocess.run(["launchctl", "print", service], capture_output=True, timeout=5, check=False)
                if status.returncode == 0 and re.search(rb"\bstate = running\b", status.stdout):
                    return
        except (OSError, subprocess.TimeoutExpired):
            pass
        raise DeployError("sing-box 重载后未恢复运行。")

    def commit(self, plan):
        fd = os.open(self.path.parent / ".one-key-proxy.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
                raise DeployError("sing-box 配置锁权限无效。")
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise DeployError("另一个流程正在更新 sing-box，请稍后重试。") from None
            return self.commit_locked(plan)
        finally:
            os.close(fd)

    def commit_locked(self, plan):
        if self.read_private(self.path) != plan.original:
            raise DeployError("sing-box 配置在准备期间被修改，请重试。")
        changed = plan.payload != plan.original
        backup = Path(plan.metadata["backup_file"])
        if changed:
            if not backup.exists():
                atomic_write(backup, plan.original)
            atomic_write(self.path, plan.payload)
        if plan.metadata["needs_reload"]:
            try:
                self.reload()
            except DeployError:
                if self.read_private(self.path) != plan.payload:
                    raise DeployError("重载失败且配置被外部修改，未回滚；请检查受保护的备份。") from None
                rollback = self.read_private(backup) if backup.exists() else plan.original
                atomic_write(self.path, rollback)
                try:
                    self.reload()
                except DeployError:
                    raise DeployError("已回滚配置，但 sing-box 仍未恢复运行，请检查 LaunchAgent。") from None
                raise DeployError("sing-box 重载失败，已回滚原配置；可重试同步。") from None
        if self.read_private(self.path) != plan.payload:
            raise DeployError("sing-box 配置回读不一致，请检查后重试。")
        if plan.removed or plan.rewrite:
            return None
        resource = copy.deepcopy(plan.metadata)
        resource.update(needs_reload=False, hashes={key: [value] for key, value in plan.hashes.items()})
        return resource
