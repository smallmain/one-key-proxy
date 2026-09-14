"""Recoverable standalone-node operations across SublinkPro and sing-box."""

import copy
import graphlib
import json
import os
import urllib.parse
import uuid

from deploy_links import parse_node_link
from deploy_resources import DeployError, SingBoxPlan, atomic_write, is_standalone
from deploy_templates import LOCAL_SS_GROUP, LOCAL_SS_TAGS


class NodeManager:
    def __init__(self, client, registry, box=None):
        self.client, self.registry, self.box = client, registry, box

    def journal_path(self, identity):
        if identity not in self.registry.records:
            raise DeployError("未找到受管配置。")
        return self.registry.state.directory / ("node-change-" + identity + ".json")

    def pending(self, identity):
        path = self.journal_path(identity)
        try:
            fd = self.registry.state.open_private(path, os.O_RDONLY)
        except FileNotFoundError:
            return None
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            raw = stream.read(32 * 1024 * 1024 + 1)
        try:
            journal = json.loads(raw)
            if (len(raw) > 32 * 1024 * 1024 or journal["version"] != 1 or journal["identity"] != identity
                    or journal["sublink_url"] != self.client.url or not isinstance(journal["operations"], list)
                    or not isinstance(journal["after"], dict)):
                raise ValueError
            for operation in journal["operations"]:
                if (operation["role"] not in ("remote", "local", "dependent")
                        or (operation["id"] is not None and (type(operation["id"]) is not int or operation["id"] <= 0))):
                    raise ValueError
        except (ValueError, KeyError, TypeError):
            raise DeployError("节点变更恢复记录无效，请核验受保护的 node-change 文件。") from None
        return journal

    def save(self, journal):
        atomic_write(self.journal_path(journal["identity"]), json.dumps(journal, ensure_ascii=False).encode())

    def fields(self, node):
        return {"name": node["Name"], "link": node["Link"], "nameMode": node.get("NameMode") or "remark",
                "group": node.get("Group", ""), "dialerProxyName": node.get("DialerProxyName", ""),
                "tags": ",".join(sorted(self.client.node_tags(node["ID"])))}

    @staticmethod
    def marker(node):
        try:
            return urllib.parse.unquote(urllib.parse.urlsplit(node["Link"]).fragment)
        except (KeyError, ValueError, TypeError):
            return ""

    def matching_nodes(self, link, exclude=None):
        matches = []
        for node in self.client.all_nodes():
            if node["ID"] == exclude:
                continue
            try:
                if parse_node_link(node["Link"]).fingerprint == link.fingerprint:
                    matches.append(node)
            except DeployError:
                continue
        return matches

    def resolve(self, link, adopt_id=None):
        matches = self.matching_nodes(link)
        if len(matches) > 1:
            raise DeployError("此连接对应多个 SublinkPro 节点，需先处理重复资源。")
        if not matches:
            if adopt_id:
                raise DeployError("指定接管节点与链接不匹配。")
            return None, None
        node = matches[0]
        for identity, record in self.registry.records.items():
            if record["sublink_url"] != self.client.url:
                continue
            if record["airport_id"] and node.get("SourceID") == record["airport_id"]:
                raise DeployError("此连接已属于受管机场，请管理原机场配置。")
            if is_standalone(record) and record["remote_node_id"] == node["ID"]:
                if self.marker(node) != "okp-remote:" + identity:
                    raise DeployError("已有节点的所有权标识发生变化。")
                if adopt_id:
                    raise DeployError("此节点已经受管，无需再次接管。")
                return identity, None
        if node.get("SourceID", 0) != 0:
            raise DeployError("此连接属于机场，不能作为手工独立节点接管。")
        if self.marker(node).startswith("okp-"):
            raise DeployError("此节点已有其他管理标识，拒绝重新接管。")
        if adopt_id != node["ID"]:
            raise DeployError(f"此连接已存在于未受管节点 ID {node['ID']}；可使用 --adopt-node {node['ID']} 明确接管。")
        return None, node

    def remote(self, identity, adopt_id=None):
        record = self.registry.records[identity]
        if not is_standalone(record):
            raise DeployError("此操作仅用于独立节点，机场请通过添加配置更新。")
        if record["sublink_url"] != self.client.url:
            raise DeployError("SublinkPro 实例与受管记录不同。")
        node = self.client.find_remote_node(identity)
        if not node and adopt_id:
            matches = [n for n in self.client.all_nodes() if n["ID"] == adopt_id and n.get("SourceID", 0) == 0]
            if len(matches) == 1 and not self.marker(matches[0]).startswith("okp-"):
                node = matches[0]
        if record["remote_node_id"] and (not node or node["ID"] != record["remote_node_id"]):
            raise DeployError("远端节点缺失或 ID 与记录不同。")
        if node and record["remote_fingerprints"] and parse_node_link(node["Link"]).fingerprint not in record["remote_fingerprints"]:
            raise DeployError("远端连接参数被外部修改，请核对受管记录与变更备份，避免覆盖。")
        return node

    def validate_native(self, link):
        parsed = self.client.request("nodes/parse-link?" + urllib.parse.urlencode({"link": link.link}))
        if not isinstance(parsed, dict) or parsed.get("protocol") != link.protocol or not isinstance(parsed.get("fields"), dict):
            raise DeployError("SublinkPro 无法正确识别此节点协议。")

    def prepare(self, identity, *, link=None, name=None, local_action="keep", local_port=None,
                local_link=None, same_local=False, relay_id=None, adopt_id=None, intent=None):
        if self.pending(identity):
            raise DeployError("此节点已有未完成变更，请先继续原操作。")
        record = self.registry.records[identity]
        if record["status"] not in ("active", "syncing"):
            raise DeployError("请先完成当前配置的其他操作。")
        remote = self.remote(identity, adopt_id)
        source = parse_node_link(link if link is not None else remote["Link"]) if link is not None or remote else None
        if source is None:
            raise DeployError("新节点必须提供链接。")
        if adopt_id and remote and parse_node_link(remote["Link"]).fingerprint != source.fingerprint:
            raise DeployError("接管链接与现有节点不匹配。")
        if self.matching_nodes(source, remote["ID"] if remote else None):
            raise DeployError("此连接已被其他节点使用，拒绝覆盖或重复创建。")
        self.validate_native(source)
        renaming = name is not None
        name = self.client.custom_name(name, record["node_name"], "节点名称", False)
        self.registry.validate_relay(identity, relay_id)
        parent = self.registry.records[relay_id] if relay_id else None
        parent_node = self.client.relay_node(relay_id, parent) if parent else None
        full_name = "[SM]" + name if renaming or not remote else remote["Name"]
        all_nodes = self.client.all_nodes()
        if parent_node and sum(n["Name"] == parent_node["Name"] for n in all_nodes) != 1:
            raise DeployError("中转节点显示名称不唯一，无法可靠绑定前置代理。")
        if any(n["Name"] == full_name and (not remote or n["ID"] != remote["ID"]) for n in all_nodes):
            raise DeployError("远端节点名称已存在。")
        before = self.fields(remote) if remote else None
        after = dict(before or {"group": LOCAL_SS_GROUP, "tags": LOCAL_SS_TAGS}, name=full_name,
                     link=source.marked(identity), nameMode="remark", dialerProxyName=parent_node["Name"] if parent_node else "")
        operations = [{"role": "remote", "id": remote["ID"] if remote else None, "before": before,
                       "after": after, "marker": "okp-remote:" + identity}]
        if remote and remote["Name"] != full_name:
            owned_dependents = set()
            for child_id, child in self.registry.records.items():
                if child["relay_id"] == identity:
                    if child["status"] != "active":
                        raise DeployError("被引用的节点仍有未完成操作，暂不能改名。")
                    owned_dependents.update(n["ID"] for n in self.client.remote_nodes(child_id, child))
            for node in all_nodes:
                if node.get("DialerProxyName") != remote["Name"]:
                    continue
                if node["ID"] not in owned_dependents:
                    raise DeployError("存在未受管的中转引用，需先解除后再改名。")
                fields = self.fields(node)
                operations.append({"role": "dependent", "id": node["ID"], "before": fields,
                                   "after": dict(fields, dialerProxyName=full_name), "marker": None})
        graph = {n["Name"]: [n["DialerProxyName"]] if n.get("DialerProxyName") else [] for n in all_nodes
                 if not remote or n["ID"] != remote["ID"]}
        graph[full_name] = [parent_node["Name"]] if parent_node else []
        for operation in operations[1:]:
            graph[operation["after"]["name"]] = [full_name]
        try:
            tuple(graphlib.TopologicalSorter(graph).static_order())
        except graphlib.CycleError:
            raise DeployError("SublinkPro 中转关系会形成循环。") from None
        local = self.client.find_local_node("okp-local:" + identity)
        if record["local_node_id"] and (not local or local["ID"] != record["local_node_id"]):
            raise DeployError("本地节点缺失或 ID 不匹配。")
        if local_action not in ("keep", "enable", "disable"):
            raise DeployError("本地节点操作无效。")
        if local_action != "enable" and (local_port is not None or local_link is not None or same_local):
            raise DeployError("修改本地参数时必须启用本地节点。")
        box_plan = None
        local_source = record["local_source"]
        if local_action == "enable":
            if self.box is None:
                raise DeployError("启用本地节点必须同时配置 sing-box。")
            local, fields = self.client.prepare_local_node("okp-local:" + identity, name, local_port, False,
                                                           preserve_name=not renaming)
            fields["tags"] = ",".join(sorted(fields["tags"].split(","))) if fields["tags"] else ""
            if local_link is not None:
                outbound = parse_node_link(local_link).outbound()
                local_source = "custom"
            elif local_source == "custom" and not same_local:
                if not record["singbox"]:
                    raise DeployError("独立本地出站尚无配置，请提供 --local-link 或选择跟随远端。")
                document = self.box.read()[1]
                self.box.owned(document, identity, record["singbox"], allow_references=True)
                outbound = copy.deepcopy(next(o for o in document["outbounds"] if o["tag"] == record["singbox"]["outbound_tag"]))
            else:
                outbound = source.outbound()
                local_source = "remote"
            relay_tag = None
            if parent:
                if not parent["singbox"]:
                    raise DeployError("所选中转没有 sing-box 出站。")
                self.box.owned(self.box.read()[1], relay_id, parent["singbox"], allow_references=True)
                relay_tag = parent["singbox"]["outbound_tag"]
            port = self.client.local_ss_link(dict(local or {"ID": 1, "Name": name, "Protocol": "ss"}, Link=fields["link"])).port
            if outbound.get("server") in ("127.0.0.1", "::1", "localhost") and outbound.get("server_port") == port:
                raise DeployError("本地出站不能连接自身的入站端口。")
            box_plan = self.box.plan(identity, ss_link=fields["link"], metadata=record["singbox"], name=name,
                                     relay_tag=relay_tag, outbound_config=outbound)
            operations.append({"role": "local", "id": local["ID"] if local else None, "before": self.fields(local) if local else None,
                               "after": fields, "marker": "okp-local:" + identity})
            local_port = port
        elif local_action == "disable":
            if local and any(n.get("DialerProxyName") == local["Name"] for n in all_nodes):
                raise DeployError("其他节点仍引用此本地节点，不能关闭。")
            if record["singbox"]:
                if self.box is None:
                    raise DeployError("关闭本地节点需要访问对应 sing-box 配置。")
                box_plan = self.box.plan(identity, metadata=record["singbox"], remove=True)
            if local:
                operations.append({"role": "local", "id": local["ID"], "before": self.fields(local),
                                   "after": None, "marker": "okp-local:" + identity})
            local_source = "remote"
        else:
            local_port = record["local_port"]
        journal = {"version": 1, "identity": identity, "sublink_url": self.client.url, "operations": operations,
                   "intent": intent or {},
                   "before_record": copy.deepcopy(record), "box": None,
                   "after": {"node_name": name, "airport_name": "", "local_port": local_port,
                             "local_source": local_source, "relay_id": relay_id, "status": "active",
                             "remote_fingerprints": [source.fingerprint]}}
        if local_action == "disable":
            journal["after"].update(local_node_id=None, singbox=None)
        if box_plan:
            journal["box"] = {"original": box_plan.original.decode(), "payload": box_plan.payload.decode(),
                              "metadata": box_plan.metadata, "hashes": box_plan.hashes, "removed": box_plan.removed}
        changed_existing = [op for op in operations if op["before"] is not None and op["before"] != op["after"]]
        if changed_existing:
            backup = self.registry.state.directory / ("node-backup-" + uuid.uuid4().hex + ".json")
            atomic_write(backup, json.dumps({"identity": identity, "sublink_url": self.client.url,
                         "record": journal["before_record"], "nodes": [{"id": op["id"], "fields": op["before"]}
                                                                     for op in changed_existing]}, ensure_ascii=False).encode())
        self.save(journal)
        self.registry.update(identity, status="updating", remote_fingerprints=list(dict.fromkeys(
            record["remote_fingerprints"] + ([parse_node_link(remote["Link"]).fingerprint] if remote else []) + [source.fingerprint])))
        return journal

    def apply(self, journal):
        identity = journal["identity"]
        record = self.registry.records[identity]
        if record["sublink_url"] != self.client.url:
            raise DeployError("恢复记录与 SublinkPro 实例不同。")
        if record["status"] not in ("active", "syncing", "updating"):
            raise DeployError("此配置有其他未完成操作，不能恢复节点变更。")
        saved_box = journal["box"]
        if saved_box:
            if self.box is None or saved_box["metadata"]["config_file"] != str(self.box.path):
                raise DeployError("恢复本地节点时 sing-box 配置路径必须与原操作一致。")
            self.box.validate_metadata(identity, saved_box["metadata"])
            if self.box.read()[0] not in (saved_box["original"].encode(), saved_box["payload"].encode()):
                raise DeployError("sing-box 在操作期间被外部修改，未覆盖。")
            self.box.check_payload(saved_box["payload"].encode())
        self.registry.update(identity, status="updating")
        nodes = self.client.all_nodes()
        primary = journal["operations"][0]
        if primary["before"] and primary["before"]["name"] != primary["after"]["name"]:
            allowed = {op["id"] for op in journal["operations"] if op["role"] == "dependent"}
            if any(n.get("DialerProxyName") == primary["before"]["name"] and n["ID"] not in allowed for n in nodes):
                raise DeployError("改名期间新增了未登记的中转引用，请先处理引用。")
        for operation in journal["operations"]:
            if operation["after"] is None and operation["before"] and any(
                    n.get("DialerProxyName") == operation["before"]["name"] for n in nodes):
                raise DeployError("待删除本地节点被其他节点引用。")
        for operation in journal["operations"]:
            before, after = operation["before"], operation["after"]
            nodes = self.client.all_nodes()
            if operation["id"] is not None:
                matches = [n for n in nodes if n["ID"] == operation["id"]]
            else:
                matches = [n for n in nodes if self.marker(n) == operation["marker"]]
            if len(matches) > 1:
                raise DeployError("节点恢复匹配到多个资源。")
            current = matches[0] if matches else None
            if current and operation["role"] != "dependent" and current.get("SourceID", 0) != 0:
                raise DeployError("独立节点变成了机场节点，拒绝修改。")
            actual = self.fields(current) if current else None
            if current is None and before is not None and after is not None:
                raise DeployError("待更新节点已被外部删除。")
            if actual is not None and actual not in (before, after):
                raise DeployError("节点在操作期间被外部修改，未覆盖。")
            if actual != after:
                if after is None:
                    self.client.request("nodes/delete?" + urllib.parse.urlencode({"id": current["ID"]}), method="DELETE")
                elif operation["role"] == "dependent":
                    self.client.request("nodes/batch-update-dialer-proxy", {"ids": [current["ID"]], "dialerProxyName": after["dialerProxyName"]})
                elif current:
                    self.client.request("nodes/update", dict(after, oldname=current["Name"], oldlink=current["Link"]), form=True)
                else:
                    self.client.request("nodes/add", after, form=True)
            refreshed = self.client.all_nodes()
            verified = [n for n in refreshed if n["ID"] == operation["id"]] if operation["id"] else [
                n for n in refreshed if self.marker(n) == operation["marker"]]
            if after is None:
                if verified:
                    raise DeployError("删除后节点仍存在，请继续原操作。")
            else:
                if len(verified) != 1 or self.fields(verified[0]) != after:
                    raise DeployError("节点写入后回读不一致，请继续原操作。")
                operation["id"] = verified[0]["ID"]
                if operation["role"] in ("remote", "local"):
                    key = "remote_node_id" if operation["role"] == "remote" else "local_node_id"
                    self.registry.update(identity, **{key: operation["id"]})
            self.save(journal)
        if saved_box:
            if self.box is None or saved_box["metadata"]["config_file"] != str(self.box.path):
                raise DeployError("恢复本地节点时 sing-box 配置路径必须与原操作一致。")
            self.box.validate_metadata(identity, saved_box["metadata"])
            original, payload = saved_box["original"].encode(), saved_box["payload"].encode()
            current = self.box.read()[0]
            if current not in (original, payload):
                raise DeployError("sing-box 在操作期间被外部修改，未覆盖。")
            plan = SingBoxPlan(current, payload, saved_box["metadata"], saved_box["hashes"], saved_box["removed"])
            self.registry.update(identity, singbox=plan.metadata)
            journal["after"]["singbox"] = self.box.commit(plan)
        self.registry.update(identity, **journal["after"])
        self.journal_path(identity).unlink()
        return self.registry.records[identity]
