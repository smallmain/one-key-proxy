"""Shlii web-protocol client and recoverable product imports.

See SHLII.md for the observed protocol and its verification limits.
"""

import base64
import copy
import getpass
import http.cookiejar
import ipaddress
import json
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

from deploy_credentials import Credentials
from deploy_links import SCHEMES, parse_node_link
from deploy_resources import DeployError, ManagedDeployments, digest, is_standalone

BASE = "https://shlii.io"
MAX_RESPONSE = 2 * 1024 * 1024
DEVICE_FIELDS = {"fingerprint": None, "screen": None, "language": "zh-CN", "timezone": None,
                 "platform": "Unknown", "cpu": None, "memory": None, "canvas": None,
                 "webgl": None, "audio": None, "touch": 0, "userAgent": None}
INSTALL_PORTS = (("面板", "OKP_PANEL_MAP", 2053), ("VLESS", "OKP_NODE_MAP", 443),
                 ("订阅", "OKP_SUB_MAP", 2096))


def text(value, limit=160):
    return "".join(c for c in str(value or "") if ord(c) >= 32 and ord(c) != 127)[:limit]


def identifier(value):
    if type(value) not in (str, int):
        raise DeployError("Shlii 返回了无效的产品或账号标识。")
    value = str(value)
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", value):
        raise DeployError("Shlii 返回了无效的产品或账号标识。")
    return value


def port(value):
    if isinstance(value, str) and value.isdecimal():
        value = int(value)
    return value if type(value) is int and 1 <= value <= 65535 else None


def choose(title, entries):
    from deploy import prompt_text
    print("\n" + title)
    for index, (label, value) in enumerate(entries, 1):
        print(f"  {index}. {text(label, 300)}" + (" [不可用]" if value is None else ""))
    print("  0. 返回")
    while True:
        answer = prompt_text("请选择", "1" if any(v is not None for _, v in entries) else "0")
        if answer == "0":
            raise DeployError("已返回；可从原菜单继续或重新开始。")
        if answer and answer.isdecimal() and 1 <= int(answer) <= len(entries):
            value = entries[int(answer) - 1][1]
            if value is not None:
                return value
        print("请选择可用的编号。", file=sys.stderr)


class ShliiError(DeployError):
    def __init__(self, status, payload=None):
        self.status = status
        self.payload = payload if isinstance(payload, dict) else {}
        code = self.payload.get("code", "")
        self.code = code if isinstance(code, str) and re.fullmatch(r"[A-Z0-9_]{1,100}", code) else ""
        message = {401: "登录状态失效或认证被拒绝", 403: "需要验证或没有访问权限",
                   404: "产品或入口已不可用", 409: "端口冲突，请刷新后重试",
                   429: "请求过于频繁，请稍后继续"}.get(status, "请求失败，请稍后继续")
        super().__init__(f"Shlii：{message}（HTTP {status}" + (f"，{self.code}" if self.code else "") + "）。")


class Store(Credentials):
    def account(self):
        value = self.read(self.state.directory / "shlii-account.json", max_bytes=65536)
        if value is not None:
            try:
                if (set(value) != {"version", "username", "password", "account_id", "token", "device", "cookies"}
                        or any(not isinstance(value[k], str) for k in ("username", "password", "account_id", "token"))
                        or not isinstance(value["cookies"], list) or not isinstance(value["device"], dict)):
                    raise ValueError
                identifier(value["account_id"])
                uuid.UUID(value["device"]["deviceId"])
            except (ValueError, TypeError, KeyError):
                raise DeployError("Shlii 账号记录无效，请核验私有凭据文件。") from None
        return value

    def save_account(self, value):
        self.write(self.state.directory / "shlii-account.json", value)

    def product_path(self, identity):
        if not re.fullmatch(r"[0-9a-f]{32}", identity):
            raise DeployError("Shlii 关联配置标识无效。")
        return self.state.directory / ("shlii-product-" + identity + ".json")

    def product(self, identity):
        value = self.read(self.product_path(identity))
        if value is not None:
            validate_product(value)
        return value

    def save_product(self, identity, product):
        validate_product(product)
        self.write(self.product_path(identity), product)

    def find(self, product, registry):
        found = []
        for identity in registry.records:
            existing = self.product(identity)
            if existing and product_key(existing) == product_key(product):
                found.append(identity)
        if len(found) > 1:
            raise DeployError("该 Shlii 入口关联多个配置，请先核验已有记录。")
        return found[0] if found else None


def validate_product(value):
    try:
        if (not isinstance(value, dict) or set(value) != {"version", "account_id", "account_name", "kind", "product_id", "selection"}
                or value["version"] != 1 or value["kind"] not in ("instance", "ticket")
                or not isinstance(value["account_name"], str) or text(value["account_name"]) != value["account_name"]
                or not isinstance(value["selection"], dict)):
            raise ValueError
        identifier(value["account_id"])
        identifier(value["product_id"])
        selection = value["selection"]
        if selection and (set(selection) != {"kind", "family", "key"}
                          or selection["kind"] not in ("main", "multi-exit", "forwarding")
                          or selection["family"] not in ("ipv4", "ipv6") or not isinstance(selection["key"], str)
                          or not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", selection["key"])):
            raise ValueError
    except (KeyError, TypeError, ValueError):
        raise DeployError("Shlii 产品关联记录无效。") from None


def product_key(product):
    return [product[k] for k in ("account_id", "kind", "product_id", "selection")]


class Client:
    def __init__(self, store, account=None):
        self.store = store
        self.account = copy.deepcopy(account) if account else {
            "version": 1, "username": "", "password": "", "account_id": "", "token": "",
            "device": dict(DEVICE_FIELDS, deviceId=str(uuid.uuid4())), "cookies": []}
        self.cookies = http.cookiejar.CookieJar()
        self.import_cookies(self.account["cookies"])
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.cookies), NoRedirect())
        self.authenticated = False

    def import_cookies(self, values):
        try:
            for value in values:
                domain = value["domain"]
                if domain not in ("shlii.io", ".shlii.io") or not isinstance(value["value"], str):
                    raise ValueError
                self.cookies.set_cookie(http.cookiejar.Cookie(
                    0, value["name"], value["value"], None, False, domain, domain.startswith("."), domain.startswith("."),
                    value["path"], True, bool(value["secure"]), value.get("expires"), False, None, None,
                    value.get("rest", {})))
        except (KeyError, TypeError, ValueError):
            raise DeployError("Shlii 登录 Cookie 记录无效。") from None

    def persist(self):
        if self.authenticated:
            self.account["cookies"] = [{"name": c.name, "value": c.value, "domain": c.domain,
                                        "path": c.path, "secure": c.secure, "expires": c.expires,
                                        "rest": c._rest} for c in self.cookies]
            self.store.save_account(self.account)

    def raw(self, path, *, method="GET", data=None, plain=False):
        url = urllib.parse.urljoin(BASE + "/", path)
        parsed = urllib.parse.urlsplit(url)
        if (parsed.scheme != "https" or parsed.netloc != "shlii.io" or parsed.username or parsed.fragment
                or (not plain and not parsed.path.startswith("/api/"))):
            raise DeployError("Shlii 返回了非本站的请求地址，未发送登录凭据。")
        headers = {"Accept": "text/plain" if plain else "application/json", "Origin": BASE,
                   "Referer": BASE + "/", "User-Agent": self.account["device"].get("userAgent") or "one-key-proxy/Shlii"}
        if self.account["token"]:
            headers["Authorization"] = "Bearer " + self.account["token"]
        body = json.dumps(data).encode() if data is not None else None
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=30) as response:
                raw = response.read(MAX_RESPONSE + 1)
        except urllib.error.HTTPError as error:
            try:
                with error:
                    payload = json.loads(error.read(65536))
            except (ValueError, UnicodeError):
                payload = None
            raise ShliiError(error.code, payload) from None
        except (urllib.error.URLError, OSError, ValueError):
            raise DeployError("无法连接 Shlii，请检查网络后继续；未回显请求或凭据。") from None
        if len(raw) > MAX_RESPONSE:
            raise DeployError("Shlii 响应过大，未处理。")
        if plain:
            return raw
        try:
            value = json.loads(raw)
            if not isinstance(value, dict):
                raise ValueError
            return value
        except (ValueError, UnicodeError):
            raise DeployError("Shlii 返回了非预期的数据，未修改配置。") from None

    def accept_login(self, result, expected=None):
        token = result.get("token")
        user = result.get("user")
        if not isinstance(token, str) or not token or len(token) > 16384 or any(ord(c) < 32 for c in token):
            raise DeployError("Shlii 登录未返回有效的访问令牌。")
        self.account["token"] = token
        if not isinstance(user, dict) or user.get("id") is None:
            user = self.raw("/api/auth/me").get("user")
        if not isinstance(user, dict) or user.get("id") is None:
            raise DeployError("Shlii 登录后无法确认账号。")
        identity = identifier(user["id"])
        if expected is not None and identity != expected:
            raise DeployError("登录账号与产品关联账号不同，未替换已保存账号。")
        self.account["account_id"] = identity
        self.authenticated = True
        self.persist()

    def login(self, expected=None):
        from deploy import prompt_text, prompt_yes_no
        if not self.account["password"]:
            try:
                self.account["password"] = getpass.getpass("Shlii 密码（输入隐藏）: ")
            except EOFError:
                raise DeployError("已取消 Shlii 密码输入。") from None
            if not self.account["password"] or len(self.account["password"]) > 4096:
                raise DeployError("Shlii 密码不能为空或超过 4096 个字符。")
        fields = {}
        for _ in range(5):
            try:
                self.accept_login(self.raw("/api/auth/login", method="POST", data=dict(
                    fields, username=self.account["username"], password=self.account["password"], device=self.account["device"])), expected)
                return
            except ShliiError as error:
                payload = error.payload
                if error.code == "NEW_DEVICE_VERIFICATION_REQUIRED":
                    methods = [(text(m.get("method")), m.get("method")) for m in payload.get("verificationMethods", [])
                               if isinstance(m, dict) and m.get("method") in ("email", "telegram", "totp")]
                    if not methods:
                        raise DeployError("Shlii 没有返回可用的新设备验证方式。") from None
                    method = choose("选择新设备验证方式", methods) if len(methods) > 1 else methods[0][1]
                    if method != "totp":
                        sent = self.raw("/api/auth/login-device-challenge", method="POST", data={
                            "challengeToken": payload.get("deviceChallengeToken"),
                            "deviceVerificationMethod": method, "device": self.account["device"]})
                        if sent.get("trusted") is True:
                            continue
                    fields.update(deviceVerificationMethod=method, deviceVerificationCode=prompt_text("新设备验证码", required=True))
                elif error.code in ("TWO_FA_REQUIRED", "INVALID_2FA_CODE") or (error.status == 401 and not fields.get("totpCode")
                        and prompt_yes_no("是否输入双重认证验证码", False)):
                    fields["totpCode"] = prompt_text("双重认证验证码", required=True)
                elif error.status in (400, 401, 403) and prompt_yes_no("是否在浏览器中完成 Shlii 登录", True):
                    from deploy_shlii_browser import login_in_browser
                    login_in_browser(self, expected)
                    return
                else:
                    raise
        raise DeployError("Shlii 登录验证未完成，请从原菜单继续。")

    def authenticate(self, expected=None):
        expected = expected or self.account["account_id"] or None
        if self.account["account_id"]:
            try:
                result = self.raw("/api/auth/refresh", method="POST", data={"device": self.account["device"]})
                self.accept_login(result, expected or self.account["account_id"])
                return
            except ShliiError as error:
                if error.status not in (400, 401, 403):
                    raise
        self.login(expected)

    def request(self, path, **kwargs):
        try:
            result = self.raw(path, **kwargs)
        except ShliiError as error:
            # A response rejecting authentication has not applied the operation.
            if error.status != 401 or error.code == "SESSION_INVALIDATED":
                raise
            self.authenticate(self.account["account_id"])
            result = self.raw(path, **kwargs)
        self.persist()
        return result

    def instances(self):
        result, page = [], 1
        while True:
            value = self.request(f"/api/instances?page={page}&pageSize=100")
            items = value.get("instances")
            if not isinstance(items, list) or any(not isinstance(v, dict) for v in items):
                raise DeployError("Shlii 实例列表格式无效。")
            result.extend(items)
            pages = value.get("totalPages", 1)
            if type(pages) is not int or not 1 <= pages <= 1000:
                raise DeployError("Shlii 实例分页信息无效。")
            if page >= pages:
                return result
            page += 1

    def instance(self, product_id):
        value = self.request("/api/instances/" + identifier(product_id)).get("instance")
        if not isinstance(value, dict):
            raise DeployError("Shlii 实例详情格式无效。")
        return value


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def account_client(store, product=None):
    from deploy import prompt_text
    saved = store.account()
    expected = product["account_id"] if product else None
    use_saved = False
    if saved and (expected is None or saved["account_id"] == expected):
        use_saved = choose("确认 Shlii 账号", [("使用 " + text(saved["username"]) + " 账号", "saved"),
                                            ("使用其它账号", "other")]) == "saved"
    if use_saved:
        client = Client(store, saved)
    else:
        if product:
            print("请登录该产品的关联账号：" + text(product["account_name"]))
        client = Client(store)
        client.account["username"] = prompt_text("Shlii 用户名或邮箱", product["account_name"] if product else None, required=True)
        try:
            client.account["password"] = getpass.getpass("Shlii 密码（输入隐藏）: ")
        except EOFError:
            raise DeployError("已取消 Shlii 密码输入。") from None
        if not client.account["password"] or len(client.account["password"]) > 4096:
            raise DeployError("Shlii 密码不能为空或超过 4096 个字符。")
    client.authenticate(expected)
    return client


def unavailable(item, kind):
    status = str(item.get("displayStatus") or item.get("status") or "").lower()
    if status in ("expired", "deleted", "suspended", "disabled", "terminated", "cancelled", "pending", "creating", "stopped", "error"):
        return "状态 " + text(status)
    if kind == "instance" and item.get("network_mode") in ("ipv6_only", "ipv6_nat"):
        return "暂不支持只有 IPv6 入口的实例"
    if kind == "ticket":
        plan = item.get("plan") if isinstance(item.get("plan"), dict) else {}
        endpoint = plan.get("endpoint") if isinstance(plan.get("endpoint"), dict) else {}
        protocol = endpoint.get("protocol")
        declared = plan.get("protocols")
        if not declared and protocol:
            declared = [protocol]
        if isinstance(declared, list) and declared:
            names = [str(v.get("protocol") if isinstance(v, dict) else v).lower() for v in declared]
            if not any(v in ("vless", "ss", "shadowsocks", "socks5", "socks")
                       or v.startswith(("vless_", "shadowsocks_", "ss_", "socks5_")) for v in names):
                return "暂不支持协议 " + text("、".join(names))
    return ""


def select_product(client):
    kind = choose("选择产品类型", [("实例", "instance"), ("登机牌", "ticket")])
    items = client.instances() if kind == "instance" else client.request("/api/airport/overview").get("tickets")
    if not isinstance(items, list) or any(not isinstance(v, dict) for v in items):
        raise DeployError("Shlii 产品列表格式无效。")
    entries = []
    for item in items:
        reason = unavailable(item, kind)
        name = item.get("name") or (item.get("package") or {}).get("name") or "产品"
        label = f"{text(name)}（{identifier(item.get('id'))}，{text(item.get('status'))}）"
        entries.append((label + ("：" + reason if reason else ""), None if reason else item))
    if not entries:
        raise DeployError("该账号没有此类型的 Shlii 产品，可重新开始选择其它类型或账号。")
    item = choose("选择产品", entries)
    return {"version": 1, "account_id": client.account["account_id"], "account_name": text(client.account["username"]),
            "kind": kind, "product_id": identifier(item["id"]), "selection": {}}


def mappings(instance):
    values = instance.get("port_mappings") or instance.get("portMappings") or []
    if not isinstance(values, list) or any(not isinstance(v, dict) for v in values):
        raise DeployError("Shlii 端口映射格式无效。")
    return [{"private": port(v.get("private_port", v.get("privatePort"))),
             "public": port(v.get("public_port", v.get("publicPort"))),
             "protocol": str(v.get("protocol", "")).lower()} for v in values]


def mapped_port(instance, private):
    found = {v["public"] for v in mappings(instance) if v["private"] == private and v["public"]
             and v["protocol"] in ("tcp", "both", "tcp/udp")}
    if len(found) > 1:
        raise DeployError("Shlii 同一内部端口有多个 TCP 映射，请先在网站明确要使用的映射。")
    return next(iter(found), None)


def install_ports(instance):
    used = {port(instance.get("ssh_port")) or 22}
    result = []
    for label, key, default in INSTALL_PORTS:
        private = default
        while private in used:
            private += 1
        used.add(private)
        result.append((label, key, private))
    return result


def prepare_ports(client, product, instance, checkpoint):
    from deploy import prompt_yes_no
    private_ssh = port(instance.get("ssh_port")) or 22
    needed = [("SSH", None, private_ssh)] + install_ports(instance)
    missing = [(label, private) for label, _, private in needed if not mapped_port(instance, private)
               and not (label == "SSH" and port(instance.get("ssh_public_port")))]
    if not missing:
        return instance
    start, end = port(instance.get("port_range_start")), port(instance.get("port_range_end"))
    used = {v["public"] for v in mappings(instance) if v["public"]}
    used.add(port(instance.get("ssh_public_port")))
    free = [p for p in range(start, end + 1) if p not in used] if start and end and start <= end else []
    limit = instance.get("port_limit")
    if isinstance(limit, str) and limit.isdecimal():
        limit = int(limit)
    if len(free) < len(missing) or (type(limit) is int and limit > 0 and len(mappings(instance)) + len(missing) > limit):
        raise DeployError("Shlii 未提供足够的可用端口；请在网站核验端口范围和映射后继续。")
    print("\n将创建 Shlii TCP 端口映射（外部 -> 内部）：")
    plan = [(label, private, public) for (label, private), public in zip(missing, free)]
    for label, private, public in plan:
        print(f"  {label}: {public} -> {private}")
    if not prompt_yes_no("确认创建这些端口映射", False):
        raise DeployError("未创建端口映射；已保留所选产品。")
    path = "/api/instances/" + product["product_id"]
    # Refetch before every write, including after a timeout on a previous run.
    for label, private, public in plan:
        instance = client.instance(product["product_id"])
        if mapped_port(instance, private):
            continue
        if any(v["public"] == public for v in mappings(instance)):
            raise DeployError("Shlii 端口映射已变化，请继续原流程重新选择可用端口。")
        try:
            client.request(path + "/ports", method="POST", data={"protocol": "tcp", "privatePort": private,
                           "publicPort": public, "remark": "one-key-proxy " + label})
        except DeployError:
            # A lost response does not prove that creation failed.
            if mapped_port(client.instance(product["product_id"]), private) != public:
                raise
        instance = client.instance(product["product_id"])
        if mapped_port(instance, private) != public:
            raise DeployError("Shlii 新建端口映射尚未确认，已停止安装；可稍后继续。")
    return instance


def instance_input(client, product, installing, checkpoint):
    instance = client.instance(product["product_id"])
    reason = unavailable(instance, "instance")
    if reason:
        raise DeployError("该 Shlii 实例不可用：" + reason)
    network = instance.get("network_mode") or instance.get("networkMode")
    mode = ("nat" if network in ("nat", "nat_ipv6", "nat_ipv6_nat") else "public"
            if network in ("public", "ipv4", "ipv4_only", "ipv4_ipv6", "dual_stack") else None)
    if installing and mode == "nat":
        instance = prepare_ports(client, product, instance, checkpoint)
    address = instance.get("nat_public_ip") if mode == "nat" else instance.get("ipv4")
    address = address or instance.get("ipv4")
    try:
        address = str(ipaddress.IPv4Address(address)) if address else None
    except (ipaddress.AddressValueError, TypeError):
        address = None
    if not address and instance.get("network_mode") in ("ipv6_only", "ipv6_nat"):
        raise DeployError("暂不支持只有 IPv6 入口的 Shlii 实例。")
    ssh_private = port(instance.get("ssh_port")) or 22
    ssh_port = mapped_port(instance, ssh_private) or port(instance.get("ssh_public_port")) if mode == "nat" else ssh_private
    defaults = {"OKP_PUBLIC_IPV4": address} if address else {}
    if mode == "nat":
        for _, key, private in install_ports(instance):
            external = mapped_port(instance, private)
            if external:
                defaults[key] = f"{external}:{private}"
    try:
        password = client.request("/api/instances/" + product["product_id"] + "/password").get("rootPassword")
    except ShliiError as error:
        if error.status not in (403, 404):
            raise
        password = None
    if not isinstance(password, str) or not 1 <= len(password) <= 4096 or "\0" in password:
        password = None
    return {"target": "root@" + address if address else None, "port": ssh_port,
            "mode": mode, "defaults": defaults, "password": password,
            "label": text(instance.get("name")) or "Shlii 实例 " + product["product_id"]}


def decode_links(raw):
    try:
        value = raw.decode("utf-8-sig").strip()
        if "://" not in value:
            compact = "".join(value.split())
            value = base64.b64decode(compact + "=" * (-len(compact) % 4), altchars=b"-_", validate=True).decode("utf-8")
        return [line.strip() for line in value.splitlines() if line.strip()]
    except (ValueError, UnicodeError):
        raise DeployError("Shlii 登机牌不是可读取的节点链接列表。") from None


def ticket_links(client, product):
    path = "/api/airport/tickets/" + product["product_id"]
    ticket = client.request(path).get("ticket")
    if not isinstance(ticket, dict):
        raise DeployError("Shlii 登机牌详情格式无效。")
    reason = unavailable(ticket, "ticket")
    if reason:
        raise DeployError("Shlii 登机牌不可用：" + reason)
    subscription = client.request(path + "/subscription").get("subscription")
    if not isinstance(subscription, dict) or subscription.get("usable") is not True:
        raise DeployError("该 Shlii 登机牌当前不可用，原配置已保留。")
    revealed = client.request(path + "/subscription/reveal", method="POST", data={}).get("subscription")
    if not isinstance(revealed, dict) or not isinstance(revealed.get("paths"), dict):
        raise DeployError("Shlii 未返回可读取的登机牌链接。")
    candidates = []
    for family in ("ipv4", "ipv6"):
        entry = revealed["paths"].get(family) or {}
        if entry.get("v2raynPath"):
            for link in decode_links(client.request(entry["v2raynPath"], plain=True)):
                candidates.append(({"kind": "main", "family": family, "key": ""}, link, "普通入口"))
    variants = client.request(path + "/multi-exit").get("variants", [])
    if not isinstance(variants, list):
        raise DeployError("Shlii 多出口列表格式无效。")
    resources = [("multi-exit", v) for v in variants if isinstance(v, dict) and v.get("status") == "ready"]
    resources += [("forwarding", v) for v in ticket.get("forwardingAllocations", [])
                  if isinstance(v, dict) and v.get("mode") in ("third_party", "owned_ticket", "node_link")
                  and v.get("status") in ("active", "ready")]
    for kind, resource in resources:
        for family in ("ipv4", "ipv6"):
            if family == "ipv6" and not (ticket.get("host") or {}).get("ipv6Available"):
                continue
            selector = {"kind": kind, "family": family, "key": identifier(resource["id"])}
            try:
                result = client.request(path + "/" + kind + "/" + selector["key"] + "/boarding-pass?family=" + family)
            except ShliiError as error:
                if error.status in (403, 404):
                    continue
                raise
            if isinstance(result.get("link"), str):
                candidates.append((selector, result["link"], text(resource.get("name")) or kind))
    entries, keys = [], set()
    for selector, link, label in candidates:
        try:
            parsed = parse_node_link(link)
        except DeployError:
            scheme = text(link.partition(":")[0], 30).lower()
            reason = "链接格式无效" if scheme + "://" in SCHEMES else "暂不支持协议"
            entries.append((label + " " + selector["family"] + "：" + reason + "（" + scheme + "）", None))
            continue
        if selector["kind"] == "main":
            selector["key"] = digest({"name": parsed.name, "protocol": parsed.protocol})
        key = json.dumps(selector, sort_keys=True)
        if key in keys:
            raise DeployError("Shlii 返回了无法稳定区分的同名入口，请在网站为入口设置不同名称。")
        keys.add(key)
        entries.append((label + " " + selector["family"] + " " + text(parsed.name) +
                        f"（{parsed.protocol} {parsed.host}:{parsed.port}）", (selector, link)))
    return entries


def select_ticket_link(client, product):
    entries = ticket_links(client, product)
    if product["selection"]:
        found = [value for _, value in entries if value and value[0] == product["selection"]]
        if len(found) != 1:
            raise DeployError("原 Shlii 入口已不可用，未自动改用其它入口；请核验后重新选择产品。")
        return found[0]
    usable = [v for _, v in entries if v is not None]
    if not usable:
        for label, _ in entries:
            print("  " + label)
        raise DeployError("该 Shlii 登机牌当前没有可导入的节点链接。")
    return usable[0] if len(usable) == 1 else choose("选择登机牌入口", entries)


def configure(args, config, checkpoint):
    from deploy import prompt_yes_no
    if checkpoint is None:
        raise DeployError("Shlii 导入需要流程恢复记录，请从主菜单操作。")
    store = Store(checkpoint)
    product = json.loads(args.provider_product) if getattr(args, "provider_product", None) else None
    if product:
        validate_product(product)
    client = account_client(store, product)
    if product is None:
        product = select_product(client)
        checkpoint.capture(provider_product=json.dumps(product, ensure_ascii=False))
    registry = ManagedDeployments(checkpoint)
    result = None
    if product["kind"] == "ticket":
        selection, link = select_ticket_link(client, product)
        product["selection"] = selection
        values = {"source": "node", "node_link": link, "action": "edit" if args.action == "edit" else "add"}
    else:
        result = instance_input(client, product, args.action == "install", checkpoint)
        values = {"source": "ssh", "target": result["target"], "mode": result["mode"],
                  "provider_defaults": json.dumps(result["defaults"])}
        if result["port"]:
            values["port"] = result["port"]
        if result["password"]:
            values.update(password=True, identity=None, auth_method="password")
    existing = store.find(product, registry)
    if existing:
        from deploy import SublinkPro
        record = registry.records[existing]
        if record["status"] != "active":
            raise DeployError("该 Shlii 产品已有未完成配置，请先继续原流程。")
        if record["sublink_url"] != SublinkPro(config, create_local_node=False).url:
            raise DeployError("该 Shlii 产品已经关联另一 SublinkPro 实例。")
        print("将更新已有配置：" + text(record["node_name"]))
        if product["kind"] == "ticket":
            from deploy_nodes import NodeManager
            current = NodeManager(SublinkPro(config, create_local_node=False), registry).remote(existing)
            before = parse_node_link(current["Link"]) if current else None
            after = parse_node_link(values["node_link"])
            print("  原节点：" + (f"{before.protocol} {before.host}:{before.port}" if before else "未设置"))
            print(f"  Shlii：{after.protocol} {after.host}:{after.port}（完整凭据不显示）")
            print("  认证信息：" + ("未变化" if before and before.auth == after.auth else "已变化"))
            print("  传输参数：" + ("未变化" if before and before.query == after.query else "已变化"))
        else:
            print("  原 SSH：" + text((record["ssh"] or {}).get("target")) + ":" + str((record["ssh"] or {}).get("port") or 22))
            print("  Shlii SSH：" + text(values["target"]) + ":" + str(values.get("port") or "待补全"))
            old_ssh = record["ssh"]
            previous_password = store.ssh(old_ssh["target"], old_ssh["port"]) if old_ssh and old_ssh["password"] else None
            print("  SSH 密码：" + ("未变化" if result["password"] and previous_password == result["password"]
                  else "采用本次读取值" if result["password"] else "未能读取，沿用原流程补填"))
        if not prompt_yes_no("确认采用 Shlii 连接信息，保留原名称、本地节点、标签和中转设置", False):
            raise DeployError("已取消从 Shlii 更新，原配置未修改。")
        checkpoint.phase("input", existing)
        if product["kind"] == "ticket":
            if checkpoint.node_id:
                values.update(action="edit", target=existing)
            else:
                values.update(action="add", target=None)
        else:
            values["action"] = "add"
        values.update(name=None, airport_name=None, local_port=record["local_port"],
                      create_local_node=bool(record["singbox"] or record["local_node_id"]), residential=None,
                      relay=record["relay_id"] or "")
    if result and result["password"] and result["target"] and result["port"]:
        store.save_ssh(result["target"], result["port"], result["password"])
    if result:
        values["provider_label"] = result["label"]
    values.update(provider_product=json.dumps(product, ensure_ascii=False), provider_ready=True)
    vars(args).update(values)
    checkpoint.capture(**values)


def ensure_export(args, checkpoint, ssh, exported):
    """Use the existing server reconfiguration flow when advertised NAT data is stale."""
    from deploy import export_node
    if exported["MODE"] != "nat":
        return exported
    product = json.loads(args.provider_product)
    store = Store(checkpoint)
    saved = store.account()
    client = Client(store, saved) if saved and saved["account_id"] == product["account_id"] else account_client(store, product)
    client.authenticated = True
    instance = client.instance(product["product_id"])
    address = instance.get("nat_public_ip") or instance.get("ipv4")
    try:
        address = str(ipaddress.IPv4Address(address))
    except (ValueError, TypeError):
        return exported

    def changes(value):
        node = urllib.parse.urlsplit(value["VLESS_URI"])
        subscription = urllib.parse.urlsplit(value["SUBSCRIPTION_URL"])
        public_ports = {v["public"] for v in mappings(instance) if v["protocol"] in ("tcp", "both", "tcp/udp")}
        return (node.hostname != address or subscription.hostname != address,
                bool(public_ports) and (node.port not in public_ports or subscription.port not in public_ports))

    host_changed, ports_changed = changes(exported)
    if host_changed or ports_changed:
        print("服务器仍发布旧的地址或端口，将进入原有重配流程；请按以下 Shlii 信息填写并确认：")
        print("  公网 IPv4：" + address)
        for mapping in mappings(instance):
            if mapping["public"] and mapping["private"]:
                print(f"  {mapping['protocol']} {mapping['public']} -> {mapping['private']}")
        scope = "all" if host_changed and ports_changed else "address" if host_changed else "ports"
        ssh.run("/usr/local/bin/one-key-proxy reconfigure " + scope, interactive=True)
        exported = export_node(ssh)
        if exported["INSTALLATION_ID"] != checkpoint.data["installation_id"] or any(changes(exported)):
            raise DeployError("服务器发布信息尚未与 Shlii 一致，已停止本地更新；请完成原重配流程后继续。")
    return exported


def bind(checkpoint):
    if not checkpoint or not checkpoint.data or not checkpoint.data["options"].get("provider_product"):
        return
    identity = checkpoint.data["installation_id"]
    if identity and identity in ManagedDeployments(checkpoint).records:
        Store(checkpoint).save_product(identity, json.loads(checkpoint.data["options"]["provider_product"]))


def update_options(identity, state):
    registry = ManagedDeployments(state)
    record = registry.records[identity]
    product = Store(state).product(identity)
    if product is None or record["status"] != "active":
        raise DeployError("该配置未关联 Shlii 或仍有未完成操作。")
    return {"action": "edit" if is_standalone(record) else "add", "target": identity if is_standalone(record) else record["target"],
            "env_file": Path(record["env_file"]), "source": "node" if is_standalone(record) else "ssh", "provider": "shlii",
            "provider_product": json.dumps(product, ensure_ascii=False), "provider_update": True, "interactive": True}
