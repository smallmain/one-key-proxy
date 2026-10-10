"""Recoverable standalone-node operations across SublinkPro and sing-box."""

import copy
import graphlib
import json
import os
import urllib.parse
import uuid

from deploy_links import parse_node_link
from deploy_resources import DeployError, SingBoxPlan, atomic_write, is_standalone, remote_relay_name
from deploy_templates import LOCAL_SS_GROUP, LOCAL_SS_TAGS, RESIDENTIAL_TAG, residential_tags


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
            if (len(raw) > 32 * 1024 * 1024 or journal["version"] != 2 or journal["identity"] != identity
                    or journal["sublink_url"] != self.client.url or not isinstance(journal["operations"], list)
                    or not isinstance(journal["after"], dict) or not isinstance(journal["names"], dict)):
                raise ValueError
            for operation in journal["operations"]:
                if (operation["role"] not in ("remote", "local", "dependent", "tag", "rename", "imported", "airport")
                        or (operation["id"] is not None and (type(operation["id"]) is not int or operation["id"] <= 0))):
                    raise ValueError
                if operation["role"] == "tag" and (type(operation.get("source_id")) is not int or operation["source_id"] < 0):
                    raise ValueError
                if operation["role"] == "tag":
                    if (operation["id"] is None or not isinstance(operation.get("before"), dict)
                            or not isinstance(operation.get("after"), dict)
                            or {k: v for k, v in operation["before"].items() if k != "tags"} !=
                               {k: v for k, v in operation["after"].items() if k != "tags"}):
                        raise ValueError
                if operation["role"] == "rename":
                    if (operation["owner_id"] not in journal["names"] or type(operation["local"]) is not bool
                            or operation["id"] is None or not isinstance(operation["before"], dict)
                            or not isinstance(operation["after"], dict)
                            or {k: v for k, v in operation["before"].items() if k != "name"} !=
                               {k: v for k, v in operation["after"].items() if k != "name"}):
                        raise ValueError
            for key, change in journal["names"].items():
                if (key not in self.registry.records or set(change) != {"before", "after_name"}
                        or not isinstance(change["before"], dict) or not isinstance(change["after_name"], str)):
                    raise ValueError
        except (ValueError, KeyError, TypeError):
            raise DeployError("节点变更恢复记录无效，请核验受保护的 node-change 文件。") from None
        return journal

    def save(self, journal):
        atomic_write(self.journal_path(journal["identity"]), json.dumps(journal, ensure_ascii=False).encode())

    def operation_node(self, operation, nodes):
        before, after = operation["before"], operation["after"]
        if operation["role"] == "airport":
            current = self.client.find(operation["marker"])
            actual = dict(self.client.settings(current), name=current["name"], url=current["url"]) if current else None
            if not current or current["id"] != operation["id"] or actual not in (before, after):
                raise DeployError("机场在编辑期间被外部修改，未覆盖。")
            return current, actual
        matches = [node for node in nodes if node["ID"] == operation["id"]] if operation["id"] is not None else [
            node for node in nodes if self.marker(node) == operation["marker"]]
        if len(matches) > 1:
            raise DeployError("节点恢复匹配到多个资源。")
        current = matches[0] if matches else None
        if current and operation["role"] in ("tag", "imported") and current.get("SourceID", 0) != operation["source_id"]:
            raise DeployError("节点标签变更期间来源发生变化，拒绝修改。")
        if current and operation["role"] not in ("dependent", "tag", "imported") and current.get("SourceID", 0) != 0:
            raise DeployError("独立节点变成了机场节点，拒绝修改。")
        actual = self.fields(current) if current else None
        if current is None and before is not None and after is not None:
            raise DeployError("待更新节点已被外部删除。")
        if actual is not None and actual not in (before, after):
            raise DeployError("节点在操作期间被外部修改，未覆盖。")
        return current, actual

    def guard_name_transaction(self, identity):
        for path in self.registry.state.directory.glob("node-change-*.json"):
            owner = path.stem[len("node-change-"):]
            if owner == identity or owner not in self.registry.records or self.registry.records[owner]["sublink_url"] != self.client.url:
                continue
            journal = self.pending(owner)
            if journal and identity in journal["names"]:
                raise DeployError("此节点参与“" + self.registry.records[owner]["node_name"] + "”的未完成改名，请从该配置继续原操作。")

    def prepare_names(self, identity, name, operations, nodes):
        names = {}
        for key, record in self.registry.records.items():
            source = record["remote_relay"]
            if not source or not source["auto_name"] or identity not in (source["entry_id"], source["exit_id"]):
                continue
            entry = dict(self.registry.records[source["entry_id"]])
            exit_node = dict(self.registry.records[source["exit_id"]])
            if source["entry_id"] == identity:
                entry["node_name"] = name
            if source["exit_id"] == identity:
                exit_node["node_name"] = name
            new_name = self.client.custom_name(remote_relay_name(entry, exit_node), "", "中转名称", False)
            if new_name == record["node_name"]:
                continue
            self.guard_name_transaction(key)
            if record["status"] != "active" or self.pending(key) or (self.registry.state.directory / ("remote-relay-" + key + ".json")).exists():
                raise DeployError("关联远程中转仍有未完成操作，请先完成后再改名。")
            remote = self.remote(key)
            if remote is None:
                raise DeployError("关联远程中转的远端节点不存在。")
            local = self.client.find_local_node("okp-local:" + key)
            if record["local_node_id"] and (not local or local["ID"] != record["local_node_id"]):
                raise DeployError("关联远程中转的本地节点缺失或 ID 不匹配。")
            names[key] = {"before": copy.deepcopy(record), "after_name": new_name}
            for node, is_local in ((remote, False), (local, True)):
                if node is None:
                    continue
                before = self.fields(node)
                operations.append({"role": "rename", "owner_id": key, "local": is_local, "id": node["ID"],
                                   "before": before, "after": dict(before, name="[SM]" + new_name + (" - 本地" if is_local else "")),
                                   "marker": self.marker(node)})
        for operation in list(operations):
            before, after = operation["before"], operation["after"]
            if not before or not after or before["name"] == after["name"]:
                continue
            local = operation["role"] == "local" or (operation["role"] == "rename" and operation["local"])
            references = [node for node in nodes if node.get("DialerProxyName") == before["name"]]
            if local and references:
                raise DeployError("本地节点仍有中转引用，需先解除后再改名。")
            if local:
                continue
            owner = operation.get("owner_id", identity)
            allowed = set()
            for child_id, child in self.registry.records.items():
                if child["relay_id"] == owner:
                    if child["status"] != "active":
                        raise DeployError("被引用的节点仍有未完成操作，暂不能改名。")
                    allowed.update(node["ID"] for node in self.client.remote_nodes(child_id, child))
            for node in references:
                if node["ID"] not in allowed:
                    raise DeployError("存在未受管的中转引用，需先解除后再改名。")
                existing = next((op for op in operations if op["id"] == node["ID"]), None)
                if existing:
                    existing["after"]["dialerProxyName"] = after["name"]
                else:
                    fields = self.fields(node)
                    operations.append({"role": "dependent", "id": node["ID"], "before": fields,
                                       "after": dict(fields, dialerProxyName=after["name"]), "marker": None})
        proposed = {node["ID"]: {"name": node["Name"], "dialerProxyName": node.get("DialerProxyName", "")} for node in nodes}
        for index, op in enumerate(operations):
            proposed[op["id"] if op["id"] is not None else -(index + 1)] = op["after"]
        display_names = [fields["name"] for fields in proposed.values() if fields]
        for op in operations:
            if op["after"] and display_names.count(op["after"]["name"]) != 1:
                raise DeployError("改名后的节点名称已存在，未修改配置。")
        try:
            tuple(graphlib.TopologicalSorter({fields["name"]: [fields["dialerProxyName"]] if fields["dialerProxyName"] else []
                                             for fields in proposed.values() if fields}).static_order())
        except graphlib.CycleError:
            raise DeployError("SublinkPro 中转关系会形成循环。") from None
        return names

    def prepare_related_names(self, identity, *, intent):
        self.guard_name_transaction(identity)
        if self.pending(identity):
            raise DeployError("此配置已有未完成变更，请先继续原操作。")
        record = self.registry.records[identity]
        if record["status"] != "active":
            raise DeployError("请先完成此配置的原操作。")
        if not any(source and source["auto_name"] and identity in (source["entry_id"], source["exit_id"])
                   for source in (r["remote_relay"] for r in self.registry.records.values())):
            return None
        operations = []
        names = self.prepare_names(identity, record["node_name"], operations, self.client.all_nodes())
        if not names:
            return None
        journal = {"version": 2, "identity": identity, "sublink_url": self.client.url, "names": names,
                   "operations": operations, "intent": intent, "before_record": copy.deepcopy(record),
                   "box": None, "after": {"status": "active"}}
        backup = self.registry.state.directory / ("node-backup-" + uuid.uuid4().hex + ".json")
        atomic_write(backup, json.dumps(journal, ensure_ascii=False).encode())
        self.save(journal)
        self.registry.update_many({key: {"status": "updating"} for key in [identity, *names]})
        return journal

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
                if record.get("kind") == "remote-relay":
                    raise DeployError("此连接属于远程中转组合节点，请通过远程中转设置管理。")
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
            nodes = self.client.remote_nodes(identity, record)
            selected = [node for node in nodes if node["ID"] == record["remote_node_id"]]
            if len(selected) == 1:
                return selected[0]
            if len(nodes) == 1:
                return nodes[0]
            raise DeployError("机场需要明确关联一个节点；请先补全或同步节点来源。")
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

    def prepare_residential(self, identity, residential, *, intent=None):
        if type(residential) is not bool:
            raise DeployError("家宽设置必须为是或否。")
        self.guard_name_transaction(identity)
        if self.pending(identity):
            raise DeployError("此节点已有未完成变更，请先继续原操作。")
        record = self.registry.records[identity]
        if record["status"] not in ("active", "syncing") or record["sublink_url"] != self.client.url:
            raise DeployError("请先完成当前配置的其他操作，并核对 SublinkPro 实例。")
        nodes = [self.remote(identity)] if is_standalone(record) else self.client.remote_nodes(identity, record)
        nodes = [node for node in nodes if node is not None]
        if not nodes and residential and record["airport_id"]:
            raise DeployError("机场节点尚未拉取，无法添加家宽标签；请稍后继续。")
        if any(node is None for node in nodes):
            raise DeployError("受管远端节点尚不存在。")
        local = self.client.find_local_node("okp-local:" + identity)
        if record["local_node_id"] and (not local or local["ID"] != record["local_node_id"]):
            raise DeployError("本地节点缺失或 ID 不匹配。")
        if local:
            nodes.append(local)
        operations = []
        for node in nodes:
            before = self.fields(node)
            after = dict(before, tags=",".join(residential_tags(
                before["tags"].split(",") if before["tags"] else [], residential)))
            operations.append({"role": "tag", "id": node["ID"], "source_id": node.get("SourceID", 0),
                               "before": before, "after": after, "marker": self.marker(node)})
        journal = {"version": 2, "identity": identity, "sublink_url": self.client.url, "names": {},
                   "operations": operations, "intent": intent or {"residential": residential},
                   "before_record": copy.deepcopy(record), "box": None, "after": {"status": "active", "residential": residential}}
        backup = self.registry.state.directory / ("node-backup-" + uuid.uuid4().hex + ".json")
        atomic_write(backup, json.dumps({"identity": identity, "sublink_url": self.client.url,
                     "record": record, "nodes": [{"id": op["id"], "fields": op["before"]} for op in operations]},
                     ensure_ascii=False).encode())
        self.save(journal)
        self.registry.update(identity, status="updating")
        return journal

    def prepare(self, identity, *, link=None, name=None, local_action="keep", local_port=None,
                local_link=None, same_local=False, relay_id=None, adopt_id=None, intent=None, residential=None, auto_name=None, airport_name=None):
        if residential is not None and type(residential) is not bool:
            raise DeployError("家宽设置必须为是或否。")
        self.guard_name_transaction(identity)
        if self.pending(identity):
            raise DeployError("此节点已有未完成变更，请先继续原操作。")
        record = self.registry.records[identity]
        imported = not is_standalone(record)
        if imported and link is not None:
            raise DeployError("机场节点的连接由订阅提供，请修改订阅地址或同步节点来源。")
        if record["status"] not in ("active", "syncing"):
            raise DeployError("请先完成当前配置的其他操作。")
        remote = self.remote(identity, adopt_id)
        if remote is None and residential is None:
            residential = record["residential"]
        source = parse_node_link(link if link is not None else remote["Link"]) if link is not None or remote else None
        if source is None and local_action == "enable" and local_link is None and not (record["singbox"] and record["local_source"] == "custom"):
            raise DeployError("缺少可用出站；请补全节点来源或设置独立本地出站链接。")
        if adopt_id and remote and parse_node_link(remote["Link"]).fingerprint != source.fingerprint:
            raise DeployError("接管链接与现有节点不匹配。")
        if source and self.matching_nodes(source, remote["ID"] if remote else None):
            raise DeployError("此连接已被其他节点使用，拒绝覆盖或重复创建。")
        if source:
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
        if source and any(n["Name"] == full_name and (not remote or n["ID"] != remote["ID"]) for n in all_nodes):
            raise DeployError("远端节点名称已存在。")
        before = self.fields(remote) if remote else None
        after = dict(before or {"group": LOCAL_SS_GROUP, "tags": LOCAL_SS_TAGS}, name=full_name,
                     nameMode="remark", dialerProxyName=parent_node["Name"] if parent_node else "")
        if source:
            after["link"] = remote["Link"] if imported else source.marked(identity)
        if imported:
            after["nameMode"] = "remark" if renaming else before["nameMode"]
        after["tags"] = ",".join(residential_tags(after["tags"].split(",") if after["tags"] else [], residential))
        operations = ([{"role": "imported" if imported else "remote", "source_id": record["airport_id"] if imported else 0,
                        "id": remote["ID"] if remote else None, "before": before,
                        "after": after, "marker": "okp-remote:" + identity}] if source else [])
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
            if local and fields["name"] != local["Name"] and any(
                    n.get("DialerProxyName") == local["Name"] for n in all_nodes):
                raise DeployError("本地节点仍有中转引用，需先解除后再改名。")
            local_residential = residential if residential is not None or local else RESIDENTIAL_TAG in after["tags"].split(",")
            fields["tags"] = ",".join(residential_tags(fields["tags"].split(",") if fields["tags"] else [], local_residential))
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
            box_plan = self.box.plan(identity, ss_link=fields["link"], metadata=record["singbox"],
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
            if local and (renaming or residential is not None):
                local_before = self.fields(local)
                local_after = dict(local_before, tags=",".join(residential_tags(
                    local_before["tags"].split(",") if local_before["tags"] else [], residential)))
                if renaming:
                    local_after["name"] = "[SM]" + name + " - 本地"
                operations.append({"role": "local", "id": local["ID"], "before": local_before,
                                   "after": local_after, "marker": "okp-local:" + identity})
        names = self.prepare_names(identity, name, operations, all_nodes)
        if imported and (renaming or airport_name is not None):
            airport = self.client.find("[okp:" + identity + "]")
            fields = dict(self.client.settings(airport), name=airport["name"], url=airport["url"])
            updated = dict(fields)
            if renaming:
                updated["nodeNamePreprocess"] = json.dumps([{"matchMode": "regex", "pattern": ".+",
                    "replacement": name.replace("$", "$$"), "enabled": True}], ensure_ascii=False, separators=(",", ":"))
            if airport_name is not None:
                updated["name"] = self.client.custom_name(airport_name, "", "机场名称", False)
            operations.append({"role": "airport", "id": airport["id"], "before": fields,
                               "after": updated, "marker": "[okp:" + identity + "]"})
        journal = {"version": 2, "identity": identity, "sublink_url": self.client.url, "operations": operations, "names": names,
                   "intent": intent or {},
                   "before_record": copy.deepcopy(record), "box": None,
                   "after": {"node_name": name, "airport_name": airport_name or record["airport_name"] if imported else "", "local_port": local_port,
                             "local_source": local_source, "relay_id": relay_id, "status": "active",
                             "remote_fingerprints": [source.fingerprint] if source else []}}
        if auto_name is not None:
            if type(auto_name) is not bool or record["remote_relay"] is None:
                raise DeployError("自动命名设置仅适用于远程中转组合。")
            journal["after"]["remote_relay"] = dict(record["remote_relay"], auto_name=auto_name)
        if residential is not None:
            journal["after"]["residential"] = residential
        if local_action == "disable":
            journal["after"].update(local_node_id=None, singbox=None)
        if box_plan:
            journal["box"] = {"original": box_plan.original.decode(), "payload": box_plan.payload.decode(),
                              "metadata": box_plan.metadata, "hashes": box_plan.hashes, "removed": box_plan.removed}
        changed_existing = [op for op in operations if op["before"] is not None and op["before"] != op["after"]]
        if changed_existing:
            backup = self.registry.state.directory / ("node-backup-" + uuid.uuid4().hex + ".json")
            atomic_write(backup, json.dumps({"identity": identity, "sublink_url": self.client.url,
                         "record": journal["before_record"], "names": names, "nodes": [{"id": op["id"], "fields": op["before"]}
                                                                     for op in changed_existing]}, ensure_ascii=False).encode())
        self.save(journal)
        updates = {key: {"status": "updating"} for key in names}
        updates[identity] = {"status": "updating", "remote_fingerprints": list(dict.fromkeys(
            record["remote_fingerprints"] + ([parse_node_link(remote["Link"]).fingerprint] if remote else []) + ([source.fingerprint] if source else [])))}
        self.registry.update_many(updates)
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
        for key, change in journal["names"].items():
            current = self.registry.records[key]
            expected = dict(change["before"], status=current["status"], node_name=current["node_name"],
                            ssh=current["ssh"], server=current["server"], part_errors=current["part_errors"])
            if current != expected or current["status"] not in ("active", "updating") or current["node_name"] not in (change["before"]["node_name"], change["after_name"]):
                raise DeployError("关联组合在改名期间被外部修改，未覆盖。")
        self.registry.update_many({key: {"status": "updating"} for key in [identity, *journal["names"]]})
        nodes = self.client.all_nodes()
        for operation in journal["operations"]:
            before, after = operation["before"], operation["after"]
            if operation["role"] == "airport":
                continue
            if before and after and before["name"] != after["name"]:
                local = operation["role"] == "local" or (operation["role"] == "rename" and operation["local"])
                allowed = {op["id"] for op in journal["operations"] if op["before"] and op["after"]
                           and op["role"] != "airport"
                           and op["before"]["dialerProxyName"] == before["name"] and op["after"]["dialerProxyName"] == after["name"]}
                if any(n.get("DialerProxyName") == before["name"] and (local or n["ID"] not in allowed) for n in nodes):
                    raise DeployError("本地节点改名期间新增了中转引用，请先处理引用。" if local else "改名期间新增了未登记的中转引用，请先处理引用。")
            if operation["after"] is None and operation["before"] and any(
                    n.get("DialerProxyName") == operation["before"]["name"] for n in nodes):
                raise DeployError("待删除本地节点被其他节点引用。")
        for operation in journal["operations"]:
            self.operation_node(operation, nodes)
        for operation in journal["operations"]:
            before, after = operation["before"], operation["after"]
            nodes = self.client.all_nodes()
            current, actual = self.operation_node(operation, nodes)
            if actual != after:
                if operation["role"] == "airport":
                    self.client.request(f"airports/{operation['id']}", after, method="PUT")
                    self.operation_node(operation, nodes)
                    self.save(journal)
                    continue
                if after is not None and RESIDENTIAL_TAG in after["tags"].split(","):
                    self.client.ensure_tag(RESIDENTIAL_TAG)
                if after is None:
                    self.client.request("nodes/delete?" + urllib.parse.urlencode({"id": current["ID"]}), method="DELETE")
                elif operation["role"] == "tag":
                    self.client.request("tags/node/batch-set", {"nodeIds": [current["ID"]],
                                        "tagNames": after["tags"].split(",") if after["tags"] else []})
                elif operation["role"] == "dependent":
                    self.client.request("nodes/batch-update-dialer-proxy", {"ids": [current["ID"]], "dialerProxyName": after["dialerProxyName"]})
                elif current:
                    self.client.request("nodes/update", dict(after, oldname=current["Name"], oldlink=current["Link"]), form=True)
                else:
                    self.client.request("nodes/add", after, form=True)
            refreshed = self.client.all_nodes()
            if operation["role"] == "airport":
                self.operation_node(operation, refreshed)
                self.save(journal)
                continue
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
        updates = {key: {"node_name": change["after_name"], "status": "active"} for key, change in journal["names"].items()}
        updates[identity] = journal["after"]
        errors = dict(self.registry.records[identity]["part_errors"])
        if any(op["role"] in ("remote", "imported") for op in journal["operations"]):
            errors.pop("source", None)
        if journal["box"]:
            errors.pop("local", None)
        updates[identity]["part_errors"] = errors
        self.registry.update_many(updates)
        self.journal_path(identity).unlink()
        if journal["intent"].get("part") == "local":
            from deploy_parts import PartInput
            PartInput(self.registry, identity, "local").complete()
        return self.registry.records[identity]
