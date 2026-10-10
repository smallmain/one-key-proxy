"""Managed server-side proxy chains and their local publication transactions."""

import json
import graphlib
import os
import re
import sys
from pathlib import Path
import tempfile
import time
import urllib.parse
import uuid

from deploy_links import parse_node_link
from deploy_nodes import NodeManager
from deploy_templates import RESIDENTIAL_TAG
from deploy_resources import DeployError, SingBox, atomic_write, digest, is_standalone, remote_relay_record, remote_relay_name as default_name


def is_remote_relay(record):
    return record.get("kind") == "remote-relay"


def entry_candidate(record):
    return not is_remote_relay(record) and record["status"] == "active"


class RemoteCreation:
    fields = {"entry_id": str, "exit_fingerprint": str, "name": str, "auto_name": bool,
              "residential": bool, "enabled": bool, "local_port": int,
              "ssh_target": str, "ssh_port": int, "ssh_identity": str, "ssh_password": bool}

    def __init__(self, registry, exit_id, client, env_file):
        self.registry, self.exit_id, self.client = registry, exit_id, client
        self.env_file = str(Path(env_file).absolute())
        self.path = registry.state.directory / ("remote-create-" + exit_id + ".json")
        self.data = None

    @property
    def values(self):
        return self.data["values"]

    def validate(self, data):
        try:
            if (set(data) != {"version", "identity", "exit_id", "sublink_url", "env_file", "phase", "values"}
                    or type(data["version"]) is not int or data["version"] != 1
                    or data["exit_id"] != self.exit_id or data["sublink_url"] != self.client.url
                    or data["env_file"] != self.env_file or data["phase"] not in ("input", "bind", "confirm", "apply")
                    or not re.fullmatch(r"[0-9a-f]{32}", data["identity"]) or not isinstance(data["values"], dict)):
                raise ValueError
            for key, value in data["values"].items():
                if key not in self.fields or (value is None and key not in ("local_port", "ssh_port", "ssh_identity")):
                    raise ValueError
                if value is not None and type(value) is not self.fields[key]:
                    raise ValueError
                if isinstance(value, str) and (len(value) > 4096 or any(ord(c) < 32 or ord(c) == 127 for c in value)):
                    raise ValueError
            values = data["values"]
            if values.get("entry_id") not in self.registry.records:
                raise ValueError
            if "exit_fingerprint" in values and not re.fullmatch(r"[0-9a-f]{64}", values["exit_fingerprint"]):
                raise ValueError
            for key in ("local_port", "ssh_port"):
                if values.get(key) is not None and not 1 <= values[key] <= 65535:
                    raise ValueError
            if "name" in values and (not values["name"].strip() or len(values["name"]) > 80):
                raise ValueError
            if data["phase"] != "input" and (not {"entry_id", "exit_fingerprint", "name", "auto_name", "residential", "enabled", "local_port"} <= values.keys()
                    or (values["enabled"] and values["local_port"] is None)):
                raise ValueError
        except (ValueError, TypeError, KeyError):
            raise DeployError("远程中转创建草稿无效，请核对受保护的 remote-create 文件。") from None

    def load(self):
        try:
            fd = self.registry.state.open_private(self.path, os.O_RDONLY)
        except FileNotFoundError:
            return None
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            raw = stream.read(65537)
        try:
            if len(raw) > 65536:
                raise ValueError
            data = json.loads(raw)
        except ValueError:
            raise DeployError("远程中转创建草稿无法解析。") from None
        self.validate(data)
        self.data = data
        return data

    def save(self):
        self.validate(self.data)
        atomic_write(self.path, json.dumps(self.data, ensure_ascii=False).encode())

    def start(self, entry_id):
        self.data = {"version": 1, "identity": uuid.uuid4().hex, "exit_id": self.exit_id,
                     "sublink_url": self.client.url, "env_file": self.env_file, "phase": "input", "values": {"entry_id": entry_id}}
        self.save()

    def capture(self, **values):
        self.values.update(values)
        self.save()

    def phase(self, phase):
        self.data["phase"] = phase
        self.save()

    def complete(self):
        self.path.unlink()
        self.data = None


def ssh_call(entry, request):
    from deploy import SSH, SSHCommandError, export_node
    from deploy_parts import agent_call
    from deploy_panels import preflight, retry_after_update, recover_pending, run_helper
    binding = entry.get("ssh")
    server = entry["server"]
    request = dict(request)
    if binding is None or server is None:
        raise DeployError("入口缺少 SSH 连接或 3x-ui 管理配置，请从编辑配置补全。")
    if binding["password"] and not sys.stdin.isatty():
        from deploy_credentials import Credentials
        if Credentials().ssh(binding['target'], binding['port']) is None:
            raise DeployError("入口首次密码登录需要交互终端；已有密码可自动复用。")
    with tempfile.TemporaryDirectory(prefix="okp-relay-ssh-", dir="/tmp") as directory:
        ssh = SSH(binding["target"], directory, binding["port"], binding["identity"], password_login=binding["password"])
        try:
            ssh.connect()
            if server["backend"] == "standalone":
                entry_id = request.pop('entry_id')
                if request['operation'] != 'delete':
                    preflight(ssh, context={'entry_id': entry_id, 'installation_id': server['identity']})
                return retry_after_update(ssh, lambda: agent_call(ssh, entry_id, server, request),
                                          {'entry_id': entry_id, 'installation_id': server['identity']})
            probe = "test -f /usr/local/lib/one-key-proxy/lib/remote_relay.py || exit 112"
            try:
                ssh.run(probe)
            except SSHCommandError as error:
                if error.exit_code == 112:
                    raise DeployError("请先在入口服务器更新本项目（one-key-proxy self-update），再配置远程中转。") from None
                raise
            information = None
            if request['operation'] != 'delete':
                information = recover_pending(ssh, run_helper(ssh, {'operation': 'panel-info'}))
            exported = export_node(ssh)
            if (exported["INSTALLATION_ID"].lower() != server["identity"]
                    or parse_node_link(exported["VLESS_URI"]).fingerprint != server["fingerprint"]):
                raise DeployError("SSH 目标与已绑定的入口安装身份不一致。")
            if request['operation'] != 'delete':
                preflight(ssh, information)
            payload = dict(request, installation_id=server["identity"])
            raw = ssh.run("env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root "
                          "/usr/local/bin/one-key-proxy remote-relay", data=json.dumps(payload).encode(), timeout=300)
            try:
                result = json.loads(raw)
                if not isinstance(result, dict):
                    raise ValueError
                return result
            except ValueError:
                raise DeployError("入口未返回有效的远程中转结果；保留操作记录，请重试。") from None
        finally:
            ssh.close()


def bind_entry(registry, identity, client, args, *, creation=None):
    from deploy_parts import complete_part, ensure_entry
    if any(getattr(args, key, None) for key in ("port", "identity", "password")) and registry.records[identity]["server"]:
        complete_part(registry, identity, client, args, "server")
        return True
    return ensure_entry(registry, identity, client, args, creation=creation)


class RemoteRelayManager:
    def __init__(self, client, registry, config, transport=None):
        self.client, self.registry, self.config = client, registry, config
        self.transport = transport or ssh_call

    def call(self, entry_id, request):
        from deploy_parts import diagnostic
        try:
            entry = self.registry.records[entry_id]
            if request['operation'] != 'delete' and entry['server'] and not any(
                    parse_node_link(node['Link']).fingerprint == entry['server']['fingerprint']
                    for node in self.client.remote_nodes(entry_id, entry)):
                raise DeployError('入口节点来源与服务器管理配置不一致，请先补全或修正入口的 3x-ui 管理。')
            result = self.transport(self.registry.records[entry_id], dict(request, entry_id=entry_id))
        except DeployError as error:
            diagnostic(self.registry, entry_id, "server", error)
            raise
        diagnostic(self.registry, entry_id, "server")
        diagnostic(self.registry, entry_id, "ssh")
        return result

    def pending_path(self, identity):
        return self.registry.state.directory / ("remote-relay-" + identity + ".json")

    def pending(self, identity):
        try:
            fd = self.registry.state.open_private(self.pending_path(identity), os.O_RDONLY)
        except FileNotFoundError:
            return None
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            try:
                result = json.load(stream)
                if (result["identity"] != identity or result["sublink_url"] != self.client.url or result["version"] != 2
                        or type(result["auto_name"]) is not bool):
                    raise ValueError
                return result
            except (ValueError, TypeError, KeyError):
                raise DeployError("远程中转恢复记录无效，请核对受保护备份。") from None

    def select_exit(self, identity, fingerprint=None, selection=None, *, interactive=False):
        from deploy import prompt_text
        record = self.registry.records[identity]
        if record["status"] != "active" or is_remote_relay(record):
            raise DeployError("落地必须是已完成配置的原始节点或订阅，不能是另一组远程中转。")
        candidates = []
        failures = []
        for node in self.client.remote_nodes(identity, record):
            try:
                link = parse_node_link(node["Link"])
                link.xray_outbound()
                candidates.append((node, link))
            except DeployError as error:
                failures.append(str(error))
        if not candidates:
            if not failures:
                raise DeployError("落地尚无远端节点，请先完成 SublinkPro 订阅拉取后重试。")
            reasons = "；".join(list(dict.fromkeys(failures))[:3])
            raise DeployError("落地节点无法转换为 Xray。原因：" + reasons)
        if selection:
            chosen = [pair for pair in candidates if pair[1].fingerprint == selection]
            if not chosen and selection.isdigit() and 1 <= int(selection) <= len(candidates):
                chosen = [candidates[int(selection) - 1]]
        else:
            chosen = [pair for pair in candidates if pair[1].fingerprint == fingerprint]
            if not chosen and len(candidates) == 1 and (not fingerprint or record["kind"] != "subscription"):
                chosen = candidates
        if len(chosen) == 1:
            return chosen[0][1]
        if not interactive:
            raise DeployError("所选订阅落地已变化或不唯一，请在 TUI 重新选择，或指定 --subscription-node。")
        print("选择具体落地节点（连接参数变化时需重新选择）：")
        for index, (node, _) in enumerate(candidates, 1):
            name = "".join(c for c in str(node.get("Name", "")) if ord(c) >= 32 and ord(c) != 127)
            print(f"  {index}. {name}")
        value = prompt_text("落地节点编号（0 返回）", "0")
        if value == "0":
            raise DeployError("已取消落地选择。")
        if not value.isdigit() or not 1 <= int(value) <= len(candidates):
            raise DeployError("落地编号无效。")
        return candidates[int(value) - 1][1]

    def validate_pair(self, identity, entry_id, exit_id):
        if entry_id == exit_id or identity in (entry_id, exit_id):
            raise DeployError("入口和落地不能相同，或引用中转自身。")
        if not entry_candidate(self.registry.records[entry_id]):
            raise DeployError("入口必须是已受管的 VPS。")
        for parent in (entry_id, exit_id):
            if self.registry.records[parent]["sublink_url"] != self.client.url:
                raise DeployError("入口、落地和组合节点必须属于同一 SublinkPro 实例。")
        if is_remote_relay(self.registry.records[exit_id]):
            raise DeployError("当前支持 A → B 单跳中转，落地不能是组合节点。")
        graph = self.registry.graph()
        graph[identity] = list(set(graph.get(identity, []) + [entry_id, exit_id]))
        try:
            tuple(graphlib.TopologicalSorter(graph).static_order())
        except graphlib.CycleError:
            raise DeployError("此远程中转会与现有中转关系形成循环。") from None

    def refresh_source(self, identity, timeout=60):
        record = self.registry.records[identity]
        if not record["airport_id"]:
            return
        airport = self.client.find("[okp:" + identity + "]")
        if airport is None or airport["id"] != record["airport_id"]:
            raise DeployError("落地机场不存在或所有权不匹配。")
        airports = self.client.request("airports")
        if not isinstance(airports, list) or sum(item.get("name") == airport["name"] for item in airports) != 1:
            raise DeployError("机场名称不唯一，无法可靠识别订阅拉取任务。")
        query = "tasks?" + urllib.parse.urlencode({"type": "sub_update", "trigger": "manual", "pageSize": 100})

        def items(value):
            rows = value.get("items") if isinstance(value, dict) else value
            if not isinstance(rows, list) or any(not isinstance(row, dict) or not isinstance(row.get("id"), str) for row in rows):
                raise DeployError("SublinkPro 不支持可靠的拉取任务回读；请更新 SublinkPro 后同步。")
            return rows

        def same_airport(row):
            return row.get("type") == "sub_update" and row.get("name") == airport["name"]

        deadline = time.monotonic() + timeout
        while any(same_airport(row) for row in items(self.client.request("tasks/running"))):
            if time.monotonic() >= deadline:
                raise DeployError("落地订阅仍在更新，请稍后重试同步。")
            time.sleep(.5)
        previous = {row["id"] for row in items(self.client.request(query))}
        self.client.request(f"airports/{airport['id']}/pull", method="POST")
        print("正在刷新落地订阅并等待拉取任务完成。", flush=True)
        task_id = None
        previous_snapshot = None
        while time.monotonic() < deadline:
            if task_id is None:
                found = [row for row in items(self.client.request(query))
                         if row["id"] not in previous and same_airport(row) and row.get("trigger") == "manual"]
                if len(found) > 1:
                    raise DeployError("存在多项同名订阅拉取任务，无法确定本次同步结果。")
                if found:
                    task_id = found[0]["id"]
            if task_id is not None:
                task = self.client.request("tasks/" + urllib.parse.quote(task_id, safe=""))
                if not isinstance(task, dict) or task.get("id") != task_id or not same_airport(task):
                    raise DeployError("订阅拉取任务身份发生变化。")
                status = task.get("status")
                if status in ("error", "cancelled"):
                    raise DeployError("落地订阅拉取失败或已取消；未更新入口出站。")
                if status == "completed":
                    snapshot = []
                    for node in self.client.all_nodes():
                        if node.get("SourceID") != airport["id"]:
                            continue
                        try:
                            fingerprint = parse_node_link(node["Link"]).fingerprint
                        except DeployError:
                            fingerprint = digest(node.get("Link"))
                        snapshot.append((node["ID"], fingerprint))
                    snapshot = sorted(snapshot)
                    running = any(same_airport(row) for row in items(self.client.request("tasks/running")))
                    if not running and previous_snapshot == snapshot:
                        return
                    previous_snapshot = None if running else snapshot
                elif status not in ("pending", "running"):
                    raise DeployError("SublinkPro 返回未知的任务状态。")
            time.sleep(.5)
        raise DeployError("订阅拉取或节点回读尚未完成；未把旧参数作为同步成功，请稍后重试。")

    def prepare(self, identity, entry_id, exit_id, *, name=None, local_action="keep", local_port=None,
                selection=None, interactive=False, residential=None):
        if self.pending(identity):
            raise DeployError("此中转有未完成操作，请先继续原操作。")
        self.validate_pair(identity, entry_id, exit_id)
        record = self.registry.records[identity]
        if not is_remote_relay(record) or record["status"] not in ("active", "syncing"):
            raise DeployError("请先完成组合节点的原操作。")
        source = record["remote_relay"]
        if source["entry_id"] != entry_id:
            raise DeployError("组合节点不能更换入口；请创建另一组远程中转。")
        fingerprint = source["exit_fingerprint"] if source["exit_id"] == exit_id else None
        link = self.select_exit(exit_id, fingerprint, selection, interactive=interactive)
        proposed_name = default_name(self.registry.records[entry_id], self.registry.records[exit_id])
        auto_name = source["auto_name"] if name is None else name == proposed_name
        if auto_name:
            name = proposed_name
        if name is not None:
            name = self.client.custom_name(name, "", "中转名称", False)
        intent = {"version": 2, "identity": identity, "sublink_url": self.client.url, "auto_name": auto_name,
                  "entry_id": entry_id, "exit_id": exit_id, "exit_fingerprint": link.fingerprint,
                  "outbound": link.xray_outbound(), "name": name, "local_action": local_action,
                  "local_port": local_port, "residential": residential}
        atomic_write(self.pending_path(identity), json.dumps(intent, ensure_ascii=False).encode())
        self.registry.update(identity, status="syncing", remote_relay=dict(source, pending_exit_id=exit_id if source["exit_id"] != exit_id else None))
        return intent

    def apply(self, intent):
        identity = intent["identity"]
        record = self.registry.records[identity]
        entry = self.registry.records[intent["entry_id"]]
        if record["sublink_url"] != self.client.url or intent["sublink_url"] != self.client.url:
            raise DeployError("远程中转恢复记录与 SublinkPro 实例不一致。")
        if not is_remote_relay(record) or record["remote_relay"]["entry_id"] != intent["entry_id"]:
            raise DeployError("远程中转恢复记录与入口不一致。")
        box = SingBox(self.config) if intent["local_action"] != "keep" or record["singbox"] else None
        nodes = NodeManager(self.client, self.registry, box)
        journal = nodes.pending(identity)
        if journal is None:
            result = self.call(intent["entry_id"], {"operation": "apply", "identity": identity, "outbound": intent["outbound"]})
            if result.get("installation_id") != entry["server"]["identity"]:
                raise DeployError("远程中转结果的入口身份不一致。")
            link = parse_node_link(result["link"])
            if link.protocol != "vless" or link.name != "okp-remote:" + identity:
                raise DeployError("远程中转未返回有效的专属入口链接。")
            self.registry.update(identity, status="syncing")
            journal = nodes.prepare(identity, link=link.link, name=intent["name"],
                                    local_action=intent["local_action"],
                                    local_port=intent["local_port"] if intent["local_action"] == "enable" else None,
                                    same_local=intent["local_action"] == "enable", relay_id=None, intent=intent,
                                    residential=intent["residential"], auto_name=intent["auto_name"])
        else:
            self.call(intent["entry_id"], {"operation": "inspect", "identity": identity})
        nodes.apply(journal)
        self.registry.update(identity, remote_relay=remote_relay_record(intent["entry_id"], intent["exit_id"],
                             intent["exit_fingerprint"], auto_name=intent["auto_name"]), status="active")
        self.pending_path(identity).unlink()
        return self.registry.records[identity]

    def sync(self, identity, *, selection=None, interactive=False):
        pending = self.pending(identity)
        if pending:
            result = self.apply(pending)
        record = self.registry.records[identity]
        nodes = NodeManager(self.client, self.registry)
        journal = nodes.pending(identity)
        if journal:
            if journal["box"]:
                nodes.box = SingBox(self.config)
            return nodes.apply(journal)
        source = record["remote_relay"]
        self.refresh_source(source["exit_id"])
        if pending:
            current = self.select_exit(source["exit_id"], source["exit_fingerprint"], selection, interactive=interactive)
            if current.fingerprint == source["exit_fingerprint"]:
                return result
            selection = current.fingerprint
        action = "enable" if record["singbox"] or record["local_node_id"] else "keep"
        return self.apply(self.prepare(identity, source["entry_id"], source["exit_id"], local_action=action,
                         local_port=record["local_port"], selection=selection, interactive=interactive))

    def rename(self, identity, name):
        if self.pending(identity):
            raise DeployError("请先继续未完成的远程中转操作，再修改名称。")
        record = self.registry.records[identity]
        manager = NodeManager(self.client, self.registry)
        journal = manager.pending(identity)
        if journal is None:
            journal = manager.prepare(identity, name=name, local_action="keep", auto_name=False,
                                      intent={"name": name, "local_action": "keep", "local_port": record["local_port"]})
        elif journal.get("intent", {}).get("name") != name:
            raise DeployError("此中转有未完成变更，请先继续原操作，再修改名称。")
        return manager.apply(journal)

    def set_residential(self, identity, residential):
        if self.pending(identity):
            raise DeployError("请先继续未完成的远程中转操作，再设置家宽标签。")
        manager = NodeManager(self.client, self.registry)
        if manager.pending(identity):
            raise DeployError("请先继续未完成的节点变更，再设置家宽标签。")
        return manager.apply(manager.prepare_residential(identity, residential))

    def delete_remote(self, identity):
        record = self.registry.records[identity]
        if NodeManager(self.client, self.registry).pending(identity):
            raise DeployError("请先完成本地节点发布事务，再删除远程中转。")
        result = self.call(record["remote_relay"]["entry_id"], {"operation": "delete", "identity": identity})
        if result.get("deleted") is not True:
            raise DeployError("远程中转清理未完成，请重试删除。")

    def creation_for(self, identity):
        record = self.registry.records[identity]
        creation = RemoteCreation(self.registry, record["remote_relay"]["exit_id"], self.client, record["env_file"])
        if creation.load() and creation.data["identity"] == identity:
            return creation
        return None


def sync_dependents(client, registry, config, parent_id):
    for identity, record in list(registry.records.items()):
        source = record.get("remote_relay")
        if source and parent_id in (source["entry_id"], source["exit_id"], source.get("pending_exit_id")):
            print(f"同步关联远程中转：{record['node_name']}")
            RemoteRelayManager(client, registry, config).sync(identity, interactive=sys.stdin.isatty())


def choose_record(registry, title, predicate):
    from deploy import prompt_text
    candidates = [key for key, record in registry.records.items() if predicate(record)]
    if not candidates:
        raise DeployError("没有符合条件的受管配置。")
    for index, key in enumerate(candidates, 1):
        print(f"  {index}. {registry.records[key]['node_name']}")
    choice = prompt_text(title + "（0 返回）", "0")
    if choice == "0":
        return None
    if not choice.isdigit() or not 1 <= int(choice) <= len(candidates):
        raise DeployError("配置编号无效。")
    return candidates[int(choice) - 1]


def edit_creation_ssh(creation, entry):
    from deploy import prompt_text, prompt_yes_no
    values, saved = creation.values, entry.get("ssh") or {}
    target = values.get("ssh_target", saved.get("target", entry["target"]))
    if target.startswith(("adopted:", "node:", "http:", "https:")):
        target = ""
    creation.capture(ssh_target=prompt_text("入口的 SSH 地址或 SSH config 别名", target, required=True))
    port = prompt_text("入口 SSH 端口", str(values.get("ssh_port") or saved.get("port") or 22), required=True)
    if not port.isdigit() or not 1 <= int(port) <= 65535:
        raise DeployError("SSH 端口必须在 1–65535 范围内。")
    creation.capture(ssh_port=int(port))
    password = prompt_yes_no("入口是否使用密码登录（否则使用密钥 / SSH config）",
                             values.get("ssh_password", saved.get("password", False)))
    creation.capture(ssh_password=password, ssh_identity=None if password else values.get("ssh_identity"))
    if not password:
        key = prompt_text("SSH 私钥路径（留空使用 SSH config / agent）",
                          values.get("ssh_identity") or saved.get("identity") or "") or None
        creation.capture(ssh_identity=str(Path(key).expanduser().absolute()) if key else None)
    creation.phase("bind")


def create_remote(args, registry, identity, manager, config_path, config):
    from deploy import prompt_text, prompt_yes_no, local_node_default
    client, interactive = manager.client, sys.stdin.isatty()
    creation = RemoteCreation(registry, identity, client, config_path)
    if creation.load():
        values = creation.values
        changed = any(getattr(args, option, None) is not None and getattr(args, option) != values.get(field)
                      for option, field in (("name", "name"), ("local_port", "local_port"),
                                            ("create_local_node", "enabled"), ("residential", "residential"),
                                            ("port", "ssh_port"), ("identity", "ssh_identity")))
        if getattr(args, "entry", None):
            changed |= registry.select(args.entry) != values.get("entry_id")
        if args.subscription_node is not None:
            changed |= args.subscription_node != values.get("exit_fingerprint")
        if getattr(args, "password", False):
            changed |= values.get("ssh_password") is not True
        if changed:
            raise DeployError("此落地有未完成的远程中转创建，请从该节点的远程中转菜单继续原操作，再提交新参数。")
        if interactive:
            print("此节点有未完成的远程中转创建。\n  1. 继续上次")
            if creation.data["phase"] in ("bind", "confirm"):
                print("  2. 修改 SSH 设置")
            if creation.data["phase"] != "apply":
                print("  3. 重新开始")
            print("  0. 返回")
            choice = prompt_text("请选择", "0")
            if choice == "0":
                return
            if choice == "3" and creation.data["phase"] != "apply":
                creation.complete()
            elif choice == "2" and creation.data["phase"] in ("bind", "confirm"):
                edit_creation_ssh(creation, registry.records[values["entry_id"]])
            elif choice != "1":
                raise DeployError("菜单选项无效。")
    try:
        if creation.data is None:
            entry_id = registry.select(args.entry) if getattr(args, "entry", None) else None
            if entry_id is None:
                if not interactive:
                    raise DeployError("创建远程中转需通过 --entry 指定入口。")
                print("选择受管入口服务器：")
                entry_id = choose_record(registry, "入口服务器", lambda r: entry_candidate(r) and r is not registry.records[identity])
                if entry_id is None:
                    return
            if entry_id == identity:
                raise DeployError("入口和落地不能相同。")
            creation.start(entry_id)
        values, new_identity = creation.values, creation.data["identity"]
        entry_id = values["entry_id"]
        manager.validate_pair(new_identity, entry_id, identity)
        if creation.data["phase"] == "input":
            if "exit_fingerprint" not in values:
                link = manager.select_exit(identity, selection=args.subscription_node, interactive=interactive)
                creation.capture(exit_fingerprint=link.fingerprint)
            proposed = default_name(registry.records[entry_id], registry.records[identity])
            if "name" not in values:
                name = args.name
                if name is None:
                    name = prompt_text("中转名称", proposed, required=True) if interactive else proposed
                name = client.custom_name(name, "", "中转名称", False)
                creation.capture(name=name, auto_name=name == proposed)
            if "residential" not in values:
                residential = args.residential
                if residential is None:
                    residential = prompt_yes_no("该节点是否为家宽", False) if interactive else False
                creation.capture(residential=residential)
            if "enabled" not in values:
                enabled = True if args.local_port is not None else args.create_local_node
                if enabled is None:
                    enabled = prompt_yes_no("是否启用这组远程中转的本地 SS", local_node_default(config)) if interactive else local_node_default(config)
                creation.capture(enabled=enabled)
            if "local_port" not in values:
                port = client.choose_local_port(args.local_port, interactive=interactive) if values["enabled"] else None
                creation.capture(local_port=port)
            creation.phase("bind")
        if creation.data["phase"] in ("bind", "confirm"):
            manager.select_exit(identity, selection=values["exit_fingerprint"])
            if values["auto_name"]:
                creation.capture(name=default_name(registry.records[entry_id], registry.records[identity]))
            if not bind_entry(registry, entry_id, client, args, creation=creation):
                return
            creation.phase("confirm")
            print(f"入口：{registry.records[entry_id]['node_name']}；落地：{registry.records[identity]['node_name']}\n组合名称：{values['name']}")
            if interactive and not prompt_yes_no("确认创建远程中转（共用入口端口，必要时可能短暂重启 Xray）", False):
                print("已保留创建草稿，可从该节点的远程中转菜单继续。")
                return
            creation.phase("apply")
        child = registry.records.get(new_identity)
        if child is None:
            registry.register(new_identity, "remote-relay:" + new_identity, config_path.absolute(), client.url, values["name"],
                              kind="remote-relay", remote_relay=remote_relay_record(entry_id, identity, auto_name=values["auto_name"]))
        elif (not is_remote_relay(child) or child["remote_relay"]["entry_id"] != entry_id
              or child["remote_relay"]["exit_id"] != identity):
            raise DeployError("远程中转创建草稿与已登记的组合节点不一致。")
        pending = manager.pending(new_identity)
        if child is None or child["status"] != "active" or pending:
            intent = pending or manager.prepare(new_identity, entry_id, identity, name=values["name"],
                                               local_action="enable" if values["enabled"] else "keep",
                                               local_port=values["local_port"], selection=values["exit_fingerprint"],
                                               residential=values["residential"])
            manager.apply(intent)
        creation.complete()
        print(f"已创建远程中转：{registry.records[new_identity]['node_name']}；原入口和落地节点均保留。")
    except (DeployError, KeyboardInterrupt):
        if creation.data is not None:
            print("已保留远程中转创建进度；从该节点的‘中转设置 → 远程中转’选择‘继续上次’。", file=sys.stderr)
        raise


def manage_remote(args, env_override=False, *, registry=None, exit_id=None):
    from deploy import ResumeState, ManagedDeployments, SublinkPro, read_env, prompt_text, prompt_yes_no
    if registry is None:
        with ResumeState().locked() as state:
            return manage_remote(args, env_override, registry=ManagedDeployments(state), exit_id=exit_id)
    interactive = sys.stdin.isatty()
    identity = registry.select(args.target) if args.target and exit_id is None else exit_id
    if identity is None:
        if not interactive:
            raise DeployError("请指定落地节点或组合节点。")
        identity = choose_record(registry, "选择落地或远程中转", lambda r: r["status"] == "active" or is_remote_relay(r))
        if identity is None:
            return
    record = registry.records[identity]
    config_path = Path(args.env_file) if env_override else Path(record["env_file"])
    config = read_env(config_path)
    client = SublinkPro(config, create_local_node=False)
    if record["sublink_url"] != client.url:
        raise DeployError("SublinkPro 实例与选中配置不一致。")
    manager = RemoteRelayManager(client, registry, config)
    NodeManager(client, registry).guard_name_transaction(identity)
    if is_remote_relay(record):
        if getattr(args, "entry", None) and registry.select(args.entry) != record["remote_relay"]["entry_id"]:
            raise DeployError("组合节点不能更换入口；请选择新入口创建另一组远程中转。")
        if any(getattr(args, key, None) for key in ("port", "identity", "password")):
            bind_entry(registry, record["remote_relay"]["entry_id"], client, args)
        if record["status"] == "deleting":
            raise DeployError("此中转正在删除，请继续删除流程。")
        pending_remote = manager.pending(identity)
        pending_node = NodeManager(client, registry).pending(identity)
        if pending_remote or pending_node:
            saved = pending_node["intent"] if pending_node else pending_remote
            saved = (pending_remote or {}) | saved
            changed = any(getattr(args, key, None) is not None and getattr(args, key) != saved.get(key)
                          for key in ("name", "local_port", "residential"))
            if args.exit_node is not None:
                changed |= registry.select(args.exit_node) != saved.get("exit_id", record["remote_relay"]["exit_id"])
            if args.subscription_node is not None:
                changed |= args.subscription_node != saved.get("exit_fingerprint", record["remote_relay"]["exit_fingerprint"])
            if args.create_local_node is not None:
                action = saved.get("local_action", "keep")
                enabled = action == "enable" or (action == "keep" and bool(record["singbox"] or record["local_node_id"]))
                changed |= args.create_local_node != enabled
            if changed:
                raise DeployError("此中转有未完成变更，请先从该中转的设置继续原操作，再提交新参数。")
            print("继续上次未完成的远程中转变更。")
            manager.sync(identity, interactive=interactive)
        elif args.name is not None and args.exit_node is None and args.local_port is None and args.create_local_node is None and args.residential is None:
            manager.rename(identity, args.name)
        elif args.residential is not None and args.name is None and args.exit_node is None and args.local_port is None and args.create_local_node is None:
            manager.set_residential(identity, args.residential)
        elif args.action == "remote-sync":
            manager.sync(identity, selection=args.subscription_node, interactive=interactive)
        else:
            source = record["remote_relay"]
            exit_node = getattr(args, "exit_node", None)
            local_action = "enable" if record["singbox"] else "keep"
            local_port = args.local_port or record["local_port"]
            if args.create_local_node is True:
                local_action = "enable"
                local_port = client.choose_local_port(local_port, interactive=interactive)
            elif args.create_local_node is False:
                if not interactive or not prompt_yes_no("确认删除这组中转的本地 SS 和 sing-box 资源", False):
                    raise DeployError("已取消关闭本地节点。")
                local_action = "disable"
            elif exit_node is None and args.local_port is None and args.name is None and args.residential is None:
                if not interactive:
                    manager.sync(identity, selection=args.subscription_node)
                    return
                print("  1. 更换落地节点\n  2. 修改名称\n  3. 启用 / 修改本地 SS\n  4. 关闭本地 SS\n  5. 设置是否为家宽\n  0. 返回")
                choice = prompt_text("请选择", "0")
                if choice == "0":
                    return
                if choice == "2":
                    manager.rename(identity, prompt_text("中转名称", record["node_name"], required=True))
                    print("远程中转名称已更新。")
                    return
                if choice == "5":
                    current = RESIDENTIAL_TAG in client.node_tags(record["remote_node_id"])
                    manager.set_residential(identity, prompt_yes_no("该节点是否为家宽", current))
                    print("远程中转家宽标签已更新。")
                    return
                if choice == "1":
                    selected = choose_record(registry, "选择新的落地", lambda r: r["status"] == "active" and not is_remote_relay(r))
                    if selected is None:
                        return
                    exit_node = selected
                elif choice == "3":
                    local_action = "enable"
                    local_port = client.choose_local_port(default=record["local_port"], interactive=True, prompt=True)
                elif choice == "4":
                    if not prompt_yes_no("确认删除本地 SS 和 sing-box 资源，保留远程中转", False):
                        return
                    local_action = "disable"
                else:
                    raise DeployError("菜单选项无效。")
            elif args.local_port is not None:
                local_action = "enable"
            new_exit = registry.select(exit_node) if exit_node else source["exit_id"]
            if interactive and not prompt_yes_no("确认应用远程中转变更（必要时可能短暂重启入口 Xray）", False):
                return
            manager.apply(manager.prepare(identity, source["entry_id"], new_exit, name=args.name, local_action=local_action,
                          local_port=local_port, selection=args.subscription_node, interactive=interactive, residential=args.residential))
        print(f"远程中转已配置：{registry.records[identity]['node_name']}。")
        return
    if record["status"] != "active":
        raise DeployError("请先完成落地节点的原操作。")
    from deploy_parts import require_source
    if not require_source(registry, identity, client, args):
        return
    if args.action == "remote-sync" or getattr(args, "exit_node", None):
        raise DeployError("remote-sync / --exit-node 用于已有远程中转组合节点。")
    create_remote(args, registry, identity, manager, config_path, config)
