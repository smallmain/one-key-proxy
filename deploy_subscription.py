"""Read URI/Base64 subscriptions for a local VLESS TCP REALITY Vision outbound."""

import base64
import hashlib
import json
import re
import ssl
import urllib.error
import urllib.parse
import urllib.request
import uuid

from deploy_resources import DeployError, SingBox
from deploy_templates import SINGBOX_OUTBOUND


def validate_url(value):
    try:
        uri = urllib.parse.urlsplit(value)
        if (uri.scheme not in ("https", "http") or not uri.hostname or uri.username or uri.password
                or uri.fragment or len(value) > 4096 or any(c.isspace() or ord(c) < 32 for c in value)):
            raise ValueError
        _ = uri.port
    except (ValueError, TypeError):
        raise DeployError("请输入有效的 HTTP/HTTPS 订阅地址，不支持用户名密码或片段。") from None
    return value


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def read_subscription(url, insecure=False):
    validate_url(url)
    context = ssl.create_default_context()
    if insecure:
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(),
                                        urllib.request.HTTPSHandler(context=context))
    request = urllib.request.Request(url, headers={"User-Agent": "one-key-proxy", "Accept": "text/plain"})
    try:
        with opener.open(request, timeout=20) as response:
            raw = response.read(8 * 1024 * 1024 + 1)
        if len(raw) > 8 * 1024 * 1024:
            raise DeployError("订阅内容超过大小限制。")
        return raw
    except urllib.error.HTTPError as error:
        error.close()
        raise DeployError(f"订阅返回 HTTP {error.code}；请检查地址，重定向需使用最终地址。") from None
    except (OSError, urllib.error.URLError):
        raise DeployError("无法获取订阅，请检查网络和证书；自签名证书可使用 --insecure-subscription。") from None


def local_candidates(raw):
    try:
        content = raw.decode("utf-8-sig").strip()
        if not re.search(r"(?m)^\w+://", content):
            encoded = "".join(content.split())
            content = base64.b64decode(encoded + "=" * (-len(encoded) % 4), altchars=b"-_", validate=True).decode("utf-8-sig")
    except (ValueError, UnicodeError):
        raise DeployError("本地节点需要 URI 列表或 Base64 订阅，且包含 VLESS TCP + REALITY + Vision 节点。") from None
    candidates = {}
    for line in content.splitlines():
        link = line.strip()
        if not link.startswith("vless://"):
            continue
        try:
            outbound = SingBox.vless(SINGBOX_OUTBOUND, link)
            uri = urllib.parse.urlsplit(link)
            # The connection fingerprint survives subscription ordering and display-name changes.
            fingerprint = hashlib.sha256(json.dumps(outbound, sort_keys=True).encode()).hexdigest()
            name = urllib.parse.unquote(uri.fragment) or "订阅节点"
            name = "".join(c for c in name if ord(c) >= 32 and ord(c) != 127).strip()[:80] or "订阅节点"
            candidates[fingerprint] = {"key": fingerprint, "name": name, "link": link}
        except (DeployError, ValueError):
            continue
    if not candidates:
        raise DeployError("订阅中没有支持的本地出站。目前支持 VLESS TCP + REALITY + Vision；也可关闭本地节点只添加机场。")
    return list(candidates.values())


def subscription_export(url, service_url, *, local=False, insecure=False, selected=None, interactive=False,
                        prompt=None, on_input=None):
    validate_url(url)
    identity = uuid.uuid5(uuid.NAMESPACE_URL, "one-key-proxy:" + service_url + "\n" + url).hex
    result = {"INSTALLATION_ID": identity, "SUBSCRIPTION_URL": url, "NODE_NAME": "新订阅",
              "MODE": "public", "SKIP_TLS_VERIFY": insecure, "VLESS_URI": ""}
    if not local:
        return result
    candidates = local_candidates(read_subscription(url, insecure))
    while True:
        match = next((item for item in candidates if item["key"] == selected), None)
        if match is None and selected and selected.isdigit() and 1 <= int(selected) <= len(candidates):
            match = candidates[int(selected) - 1]
        if match is None and selected is None and len(candidates) == 1:
            match = candidates[0]
        if match:
            if on_input:
                on_input(subscription_node=match["key"])
            result.update(NODE_NAME=match["name"], VLESS_URI=match["link"])
            return result
        if selected is not None:
            raise DeployError("所选订阅节点不存在或连接参数已变化，请重新选择 --subscription-node。")
        if not interactive:
            raise DeployError("订阅包含多个可用节点，请使用 --interactive 选择，或用 --subscription-node 指定从 1 开始的序号。")
        for index, item in enumerate(candidates, 1):
            print(f"  {index}. {item['name']}")
        selected = prompt("选择本地节点对应的订阅节点", required=True)
