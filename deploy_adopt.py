"""Explicit, journaled adoption of existing proxy resources."""

import copy
import graphlib
import json
from pathlib import Path
import urllib.parse
import uuid

from deploy_resources import DeployError, ManagedDeployments, SingBox, atomic_write, digest


def node_fields(client, node):
    return {"name": node["Name"], "link": node["Link"], "nameMode": node.get("NameMode") or "link",
            "group": node.get("Group", ""), "dialerProxyName": node.get("DialerProxyName", ""),
            "tags": ",".join(sorted(client.node_tags(node["ID"])))}


def airport_fields(client, airport):
    return dict(client.settings(airport), name=airport["name"], url=airport["url"])


def add_marker(remark, marker):
    if any(line.startswith("[okp:") and line != marker for line in remark.splitlines()):
        raise DeployError("机场已带有其他所有权标识。")
    return remark if marker in remark.splitlines() else ((remark + "\n") if remark else "") + marker


def marked_link(link, marker):
    parsed = urllib.parse.urlsplit(link)
    old = urllib.parse.unquote(parsed.fragment)
    if old.startswith(("okp-local:", "okp-remote:")) and old != marker:
        raise DeployError("节点已带有其他所有权标识。")
    return parsed._replace(fragment=urllib.parse.quote(marker, safe="")).geturl()


def prepare_adoption(client, box, registry, manifest, env_file):
    if not isinstance(manifest, dict) or set(manifest) != {"groups", "remove_inbounds", "remove_outbounds", "default_outbound"}:
        raise DeployError("接管清单格式无效。")
    groups = manifest["groups"]
    if not isinstance(groups, list) or not groups:
        raise DeployError("接管清单缺少分组。")
    _, before = box.read()
    after = copy.deepcopy(before)
    nodes = {node["ID"]: node for node in client.all_nodes()}
    identities = {}
    names = set()
    selected_in, selected_out = set(), set()
    for group in groups:
        if (not isinstance(group, dict) or set(group) != {"name", "inbound", "outbound", "airport_id", "remote_node_id", "local_node_id", "relay"}
                or not isinstance(group["name"], str) or group["name"] in names):
            raise DeployError("接管分组字段或名称无效。")
        names.add(group["name"])
        identity = uuid.uuid5(uuid.NAMESPACE_URL, f"one-key-proxy-adopt:{client.url}:{group['local_node_id']}").hex
        if identity in registry.records:
            raise DeployError("此资源已被登记，请使用已有接管事务重试。")
        identities[group["name"]] = identity
        if group["inbound"] in selected_in or group["outbound"] in selected_out:
            raise DeployError("接管条目不能重复或共享同一个出站。")
        selected_in.add(group["inbound"])
        selected_out.add(group["outbound"])
    records, airport_updates, node_updates, replacements = {}, [], [], {}
    for group in groups:
        name, identity = group["name"], identities[group["name"]]
        inbound = next((i for i in before["inbounds"] if i["tag"] == group["inbound"]), None)
        outbound = next((o for o in before["outbounds"] if o["tag"] == group["outbound"]), None)
        local = nodes.get(group["local_node_id"])
        remote = nodes.get(group["remote_node_id"])
        if not inbound or not outbound or not local or not remote:
            raise DeployError("接管清单中的 sing-box 或 SublinkPro 条目不存在。")
        port, method, password = box.ss_parameters(local["Link"])
        if (inbound.get("type") != "shadowsocks" or inbound.get("listen") != "127.0.0.1"
                or inbound.get("listen_port") != port or inbound.get("method") != method
                or inbound.get("password") != password):
            raise DeployError("本地节点与 sing-box 入站凭据或端口不匹配。")
        if outbound.get("type") == "vless":
            expected = box.vless(outbound, remote["Link"])
            if any(outbound.get(k) != expected.get(k) for k in ("server", "server_port", "uuid", "flow", "tls")):
                raise DeployError("VLESS 出站与 SublinkPro 远端节点不匹配。")
        elif outbound.get("type") != "socks" or remote.get("LinkHost") != outbound.get("server"):
            raise DeployError("仅支持明确关联的 VLESS 或 SOCKS 出口。")
        relay = group["relay"]
        if relay is not None and relay not in identities:
            raise DeployError("接管清单引用未知中转分组。")
        relay_group = next((item for item in groups if item["name"] == relay), None)
        expected_detour = relay_group["outbound"] if relay_group else None
        expected_dialer = nodes[relay_group["remote_node_id"]]["Name"] if relay_group else ""
        if outbound.get("detour") != expected_detour or remote.get("DialerProxyName", "") != expected_dialer:
            raise DeployError("sing-box 与 SublinkPro 的现有中转关系不一致。")
        new_in, new_out = box.named_tags(name, outbound["type"])
        replacements[group["inbound"]] = new_in
        replacements[group["outbound"]] = new_out
        node_before = node_fields(client, local)
        node_updates.append({"id": local["ID"], "before": node_before,
                             "after": dict(node_before, link=marked_link(local["Link"], "okp-local:" + identity), nameMode="remark")})
        airport_name = name
        if group["airport_id"] is not None:
            airport = client.request(f"airports/{group['airport_id']}")
            if remote.get("SourceID") != airport["id"]:
                raise DeployError("远端节点不属于指定机场。")
            airport_name = airport["name"]
            fields = airport_fields(client, airport)
            airport_updates.append({"id": airport["id"], "before": fields,
                                    "after": dict(fields, remark=add_marker(fields["remark"], "[okp:" + identity + "]"))})
        else:
            if remote.get("SourceID", 0) != 0 or remote.get("NameMode") != "remark":
                raise DeployError("手工远端节点需使用备注名称，不能属于机场。")
            fields = node_fields(client, remote)
            node_updates.append({"id": remote["ID"], "before": fields,
                                 "after": dict(fields, link=marked_link(remote["Link"], "okp-remote:" + identity))})
        records[identity] = {"target": "adopted:" + name, "env_file": str(env_file), "sublink_url": client.url,
                             "airport_id": group["airport_id"], "local_node_id": group["local_node_id"],
                             "remote_node_id": group["remote_node_id"], "airport_name": airport_name, "node_name": name,
                             "local_port": port, "kind": "adopted", "status": "adopting", "singbox": None,
                             "relay_id": identities[relay] if relay else None}
    try:
        tuple(graphlib.TopologicalSorter({key: [r["relay_id"]] if r["relay_id"] else [] for key, r in records.items()}).static_order())
    except graphlib.CycleError:
        raise DeployError("接管清单包含中转循环。") from None
    if selected_in.intersection(manifest["remove_inbounds"]) or selected_out.intersection(manifest["remove_outbounds"]):
        raise DeployError("不能同时接管和删除同一条目。")
    after["inbounds"] = [i for i in after["inbounds"] if i["tag"] not in manifest["remove_inbounds"]]
    after["outbounds"] = [o for o in after["outbounds"] if o["tag"] not in manifest["remove_outbounds"]]
    for item in after["inbounds"] + after["outbounds"]:
        item["tag"] = replacements.get(item["tag"], item["tag"])
    after = box.rewrite_references(after, replacements)
    after["route"]["final"] = manifest["default_outbound"]
    if box.references(after, set(manifest["remove_inbounds"] + manifest["remove_outbounds"])):
        raise DeployError("待删除的旧条目仍被其他配置引用。")
    for key in ("inbounds", "outbounds"):
        tags = [item["tag"] for item in after[key]]
        if len(tags) != len(set(tags)):
            raise DeployError("重命名后的 tag 与现有条目冲突。")
    box.check_payload(json.dumps(after, ensure_ascii=False).encode())
    return {"before_config": before, "after_config": after, "airports": airport_updates, "nodes": node_updates,
            "records": records, "done": False, "config_file": str(box.path), "sublink_url": client.url}


def adopt_manifest(config, env_file, manifest_path, state):
    from deploy import SublinkPro
    manifest = json.loads(SingBox.read_private(manifest_path.expanduser().absolute()))
    client, box = SublinkPro(config, create_local_node=False), SingBox(config)
    token = digest({"manifest": manifest, "config_file": str(box.path), "sublink_url": client.url})[:32]
    with state.locked():
        registry = ManagedDeployments(state)
        journal_path = state.directory / f"adoption-{token}.json"
        backup = box.path.parent / f".one-key-proxy-backup-{token}.json"
        if journal_path.exists():
            journal = json.loads(SingBox.read_private(journal_path))
            if journal.get("done"):
                print("此接管事务已完成。")
                return
        else:
            journal = prepare_adoption(client, box, registry, manifest, env_file)
            atomic_write(journal_path, json.dumps(journal, ensure_ascii=False, indent=2).encode())
        current_raw, current = box.read()
        if current not in (journal["before_config"], journal["after_config"]):
            raise DeployError("接管期间 sing-box 配置被外部修改，已保留接管备份。")
        for identity, record in journal["records"].items():
            existing = registry.records.get(identity)
            if existing and existing["kind"] != "adopted":
                raise DeployError("接管 ID 与既有部署冲突。")
            registry.records[identity] = copy.deepcopy(record)
        registry.save()
        for update in journal["airports"]:
            actual = airport_fields(client, client.request(f"airports/{update['id']}"))
            if actual not in (update["before"], update["after"]):
                raise DeployError("接管期间机场配置被外部修改。")
            if actual != update["after"]:
                client.request(f"airports/{update['id']}", update["after"], method="PUT")
            if airport_fields(client, client.request(f"airports/{update['id']}")) != update["after"]:
                raise DeployError("机场接管标识回读不一致。")
        for update in journal["nodes"]:
            actual_node = next((n for n in client.all_nodes() if n["ID"] == update["id"]), None)
            if not actual_node:
                raise DeployError("待接管节点已不存在。")
            actual = node_fields(client, actual_node)
            if actual not in (update["before"], update["after"]):
                raise DeployError("接管期间节点配置被外部修改。")
            if actual != update["after"]:
                client.update_node(actual_node, **update["after"])
            verified = next(n for n in client.all_nodes() if n["ID"] == update["id"])
            if node_fields(client, verified) != update["after"]:
                raise DeployError("节点接管标识回读不一致。")
        if not backup.exists():
            atomic_write(backup, json.dumps(journal["before_config"], ensure_ascii=False, indent=2).encode() + b"\n")
        box.commit(box.rewrite_plan(current_raw, journal["after_config"], backup))
        after = journal["after_config"]
        for identity, record in registry.records.items():
            if identity not in journal["records"]:
                continue
            group = next(g for g in manifest["groups"] if g["name"] == record["node_name"])
            old_type = next(o["type"] for o in journal["before_config"]["outbounds"] if o["tag"] == group["outbound"])
            inbound_tag, outbound_tag = box.named_tags(record["node_name"], old_type)
            inbound = next(i for i in after["inbounds"] if i["tag"] == inbound_tag)
            outbound = next(o for o in after["outbounds"] if o["tag"] == outbound_tag)
            rule = next(r for r in after["route"]["rules"] if r.get("inbound") == [inbound_tag] and r.get("outbound") == outbound_tag)
            record.update(status="active", singbox={"owner_id": identity, "config_file": str(box.path),
                          "inbound_tag": inbound_tag, "outbound_tag": outbound_tag, "backup_file": str(backup),
                          "needs_reload": False, "hashes": {"inbound": [digest(inbound)], "outbound": [digest(outbound)], "rule": [digest(rule)]}})
        registry.save()
        journal["done"] = True
        atomic_write(journal_path, json.dumps(journal, ensure_ascii=False, indent=2).encode())
        print("接管、重命名及旧配置清理完成；已保留受保护的接管备份。")
