"""Read-only Google connectivity checks through managed proxy paths."""

import contextlib
import json
import math
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time

from deploy_links import parse_node_link
from deploy_resources import DeployError, SingBox, atomic_write, configuration_label


CHECK_URL = "https://google.com/"
CHECK_TIMEOUT = 15


def probe_proxy(port):
    try:
        result = subprocess.run([
            "curl", "-q", "--silent", "--output", os.devnull,
            "--write-out", "%{http_code} %{time_total}",
            "--proxy", f"socks5h://127.0.0.1:{port}", "--noproxy", "",
            "--connect-timeout", "5", "--max-time", str(CHECK_TIMEOUT),
            "--location", "--max-redirs", "3", "--proto", "=https", "--proto-redir", "=https",
            "--url", CHECK_URL,
        ], capture_output=True, timeout=CHECK_TIMEOUT + 2, check=False)
    except subprocess.TimeoutExpired:
        raise DeployError("访问 google.com 超时。") from None
    except OSError:
        raise DeployError("无法执行 curl，请检查本机是否已安装。") from None
    if result.returncode:
        reason = {7: "无法连接代理端口", 28: "连接或请求超时", 35: "TLS 握手失败",
                  60: "TLS 证书校验失败", 97: "SOCKS5 代理协商失败"}.get(result.returncode, "代理请求失败")
        raise DeployError(f"{reason}（curl {result.returncode}）。")
    try:
        code, elapsed = result.stdout.decode("ascii").split()
        status, duration = int(code), float(elapsed)
        if not 100 <= status <= 599 or not math.isfinite(duration) or duration < 0:
            raise ValueError
    except (ValueError, UnicodeError):
        raise DeployError("curl 返回了无效的检测结果。") from None
    if not 200 <= status < 300:
        raise DeployError(f"google.com 返回 HTTP {status}。")
    return status, round(duration * 1000)


def node_outbounds(node, all_nodes):
    """Retain SublinkPro's dialer chain in the temporary client."""
    outbounds, visiting = [], set()

    def add(current):
        identity = current.get("ID")
        if type(identity) is not int or identity <= 0 or identity in visiting:
            raise DeployError("节点 ID 无效或中转关系形成循环。")
        tag = f"check-{identity}"
        visiting.add(identity)
        outbound = parse_node_link(current.get("Link")).server_outbound()
        outbound["tag"] = tag
        parent = current.get("DialerProxyName", "")
        if parent:
            matches = [item for item in all_nodes if item.get("Name") == parent]
            if len(matches) != 1:
                raise DeployError("中转节点不存在或名称不唯一。")
            outbound["detour"] = add(matches[0])
        outbounds.append(outbound)
        visiting.remove(identity)
        return tag

    final = add(node)
    return outbounds, final


@contextlib.contextmanager
def temporary_proxy(config, outbounds, final):
    binary = shutil.which(config.get("SINGBOX_BINARY") or "sing-box")
    if not binary:
        raise DeployError("远端检测需要 sing-box，请安装或配置 SINGBOX_BINARY。")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    with tempfile.TemporaryDirectory(prefix="okp-connectivity-") as directory:
        path = Path(directory) / "config.json"
        atomic_write(path, json.dumps({
            "log": {"disabled": True},
            "inbounds": [{"type": "socks", "tag": "check-in", "listen": "127.0.0.1", "listen_port": port}],
            "outbounds": outbounds, "route": {"final": final},
        }).encode())
        process = subprocess.Popen([binary, "run", "-c", str(path)], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 5
            while True:
                if process.poll() is not None:
                    raise DeployError("临时 sing-box 启动失败，请检查节点参数及内核兼容性。")
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise DeployError("等待临时 sing-box 代理端口超时。") from None
                    time.sleep(0.05)
            yield port
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def probe_node(config, node, all_nodes):
    outbounds, final = node_outbounds(node, all_nodes)
    with temporary_proxy(config, outbounds, final) as port:
        return probe_proxy(port)


def probe_local(config, identity, record):
    metadata = record["singbox"]
    if metadata["needs_reload"]:
        raise DeployError("本地配置尚未完成重载，请先继续原操作。")
    box = SingBox(config)
    _, document = box.read()
    box.owned(document, identity, metadata, allow_references=True)
    inbound = next((item for item in document["inbounds"] if item["tag"] == metadata["inbound_tag"]), None)
    if (not any(item["tag"] == metadata["outbound_tag"] for item in document["outbounds"])
            or not any(rule.get("inbound") == [metadata["inbound_tag"]] and rule.get("outbound") == metadata["outbound_tag"]
                       for rule in document["route"].get("rules", []))):
        raise DeployError("受管本地出站或路由缺失。")
    if (not inbound or inbound.get("type") != "socks" or inbound.get("listen") != "127.0.0.1"
            or inbound.get("listen_port") != record["local_port"] or inbound.get("users")):
        raise DeployError("受管本地 SOCKS5 端口缺失或与记录不一致。")
    return probe_proxy(record["local_port"])


def check_configurations(args, env_override=False):
    from deploy import ManagedDeployments, ResumeState, SublinkPro, read_env

    registry = ManagedDeployments(ResumeState())
    if not registry.records:
        print("暂无受管配置。")
        return
    if not shutil.which("curl"):
        raise DeployError("检查连通性需要 curl，请先安装。")
    passed = failed = 0

    def report(label, operation):
        nonlocal passed, failed
        print(f"  {label}：检测中...", flush=True)
        try:
            status, elapsed = operation()
        except (DeployError, OSError, UnicodeError) as error:
            failed += 1
            reason = str(error) if isinstance(error, DeployError) else "本地文件或进程操作失败。"
            print(f"  {label}：失败，{reason}", flush=True)
        else:
            passed += 1
            print(f"  {label}：通过（HTTP {status}，{elapsed} ms）", flush=True)

    print(f"检测目标：{CHECK_URL}（每次请求最多 {CHECK_TIMEOUT} 秒）", flush=True)
    for index, (identity, record) in enumerate(registry.records.items(), 1):
        print(f"\n[{index}/{len(registry.records)}] {configuration_label(record)}", flush=True)
        try:
            config = read_env(args.env_file if env_override else record["env_file"])
        except (DeployError, OSError, UnicodeError) as error:
            failed += 1
            print("  失败，" + (str(error) if isinstance(error, DeployError) else "无法读取配置文件。"), flush=True)
            continue

        def check_remote():
            client = SublinkPro(config, create_local_node=False)
            if client.url != record["sublink_url"]:
                raise DeployError("SublinkPro 地址与受管记录不一致。")
            nodes = client.remote_nodes(identity, record)
            if not nodes:
                raise DeployError("暂无远端节点，请先完成节点来源配置或订阅拉取。")
            all_nodes = client.all_nodes() if any(node.get("DialerProxyName") for node in nodes) else nodes
            return nodes, all_nodes

        try:
            nodes, all_nodes = check_remote()
        except (DeployError, OSError, UnicodeError) as error:
            failed += 1
            reason = str(error) if isinstance(error, DeployError) else "读取远端节点失败。"
            print(f"  远端节点：失败，{reason}", flush=True)
        else:
            for node in nodes:
                # Node names are remote data; do not print terminal control characters.
                name = "".join(char for char in str(node.get("Name", "未命名")) if char.isprintable())
                report("远端 " + name, lambda: probe_node(config, node, all_nodes))
        if record["singbox"]:
            report(f"本地 SOCKS5 127.0.0.1:{record['local_port']}", lambda: probe_local(config, identity, record))
    print(f"\n连通性检查完成：通过 {passed} 项，失败 {failed} 项。")
    if failed:
        raise DeployError("部分配置未通过连通性检查。")
