"""Structured URI handling for standalone proxy nodes."""

import base64
from dataclasses import dataclass, field
import ipaddress
import re
import urllib.parse
import uuid

from deploy_resources import DeployError, digest

SCHEMES = ("vless://", "ss://", "socks5://")


def decode64(value):
    return base64.b64decode(value + "=" * (-len(value) % 4), altchars=b"-_", validate=True).decode("utf-8")


def clean_text(value):
    decoded = urllib.parse.unquote(value, errors="strict")
    if any(ord(c) < 32 or ord(c) == 127 for c in decoded):
        raise ValueError
    return decoded


@dataclass(repr=False)
class NodeLink:
    protocol: str
    host: str
    port: int
    name: str
    link: str = field(repr=False)
    auth: dict = field(repr=False)
    query: dict = field(repr=False)

    @property
    def fingerprint(self):
        try:
            return digest(self.outbound())
        except DeployError:
            pass
        return digest({"protocol": self.protocol, "host": self.host, "port": self.port,
                       "auth": self.auth, "query": self.query})

    def marked(self, identity):
        return urllib.parse.urlsplit(self.link)._replace(fragment="okp-remote:" + identity).geturl()

    def outbound(self):
        result = {"type": {"ss": "shadowsocks", "socks5": "socks"}.get(self.protocol, self.protocol),
                  "server": self.host, "server_port": self.port}
        if self.protocol == "socks5":
            if self.query:
                raise DeployError("SOCKS5 本地出站不支持额外查询参数。")
            return dict(result, version="5", **self.auth)
        if self.protocol == "ss":
            if self.query:
                raise DeployError("本地 Shadowsocks 暂不支持 plugin 等扩展参数；可指定另一条本地出站链接。")
            return dict(result, **self.auth)
        q = self.query
        allowed = {"type", "security", "encryption", "flow", "sni", "fp", "pbk", "sid", "alpn",
                   "allowInsecure", "path", "host", "serviceName"}
        if set(q) - allowed:
            raise DeployError("VLESS 链接包含本地转换尚不支持的参数，请使用受支持的本地出站链接。")
        transport, security, flow = q.get("type", "tcp"), q.get("security", "none"), q.get("flow", "")
        if (transport not in ("tcp", "ws", "grpc") or security not in ("none", "tls", "reality")
                or q.get("encryption", "none") != "none" or flow not in ("", "xtls-rprx-vision")
                or (flow and (transport != "tcp" or security == "none"))
                or (security == "reality" and transport != "tcp")):
            raise DeployError("暂不支持此 VLESS 传输、加密或 flow 组合。")
        if (transport != "ws" and ("path" in q or "host" in q)) or (transport != "grpc" and "serviceName" in q):
            raise DeployError("VLESS 传输参数与传输类型不匹配。")
        result.update(uuid=self.auth["uuid"])
        if flow:
            result["flow"] = flow
        if security == "none" and set(q) & {"sni", "fp", "pbk", "sid", "alpn", "allowInsecure"}:
            raise DeployError("未启用 TLS 的 VLESS 链接不能携带 TLS 参数。")
        if security != "none":
            tls = {"enabled": True, "server_name": q.get("sni") or self.host}
            if "alpn" in q:
                alpn = q["alpn"].split(",")
                if not all(alpn):
                    raise DeployError("ALPN 参数无效。")
                tls["alpn"] = alpn
            if "fp" in q:
                tls["utls"] = {"enabled": True, "fingerprint": q["fp"]}
            if security == "reality":
                if (not q.get("sni") or not re.fullmatch(r"[A-Za-z0-9_-]{43}", q.get("pbk", ""))
                        or not re.fullmatch(r"(?:[0-9a-fA-F]{2}){0,8}", q.get("sid", ""))
                        or "allowInsecure" in q):
                    raise DeployError("REALITY 的 SNI、公钥、Short ID 或证书参数无效。")
                tls["reality"] = {"enabled": True, "public_key": q["pbk"], "short_id": q.get("sid", "")}
                tls.setdefault("utls", {"enabled": True, "fingerprint": "chrome"})
            else:
                if "pbk" in q or "sid" in q:
                    raise DeployError("普通 TLS 不能携带 REALITY 参数。")
                if "allowInsecure" in q:
                    if q["allowInsecure"] not in ("0", "1", "false", "true"):
                        raise DeployError("allowInsecure 参数无效。")
                    tls["insecure"] = q["allowInsecure"] in ("1", "true")
            result["tls"] = tls
        if transport == "ws":
            result["transport"] = {"type": "ws", "path": q.get("path", "/")}
            if "host" in q:
                result["transport"]["headers"] = {"Host": q["host"]}
        elif transport == "grpc":
            result["transport"] = {"type": "grpc", "service_name": q.get("serviceName", "")}
        return result


def parse_node_link(raw):
    try:
        if (not isinstance(raw, str) or not raw or len(raw) > 4096
                or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in raw)
                or re.search(r"%(?![0-9A-Fa-f]{2})", raw)):
            raise ValueError
        uri = urllib.parse.urlsplit(raw)
        if uri.scheme not in ("vless", "ss", "socks5"):
            raise ValueError
        if uri.scheme == "ss" and "@" not in uri.netloc:
            uri = urllib.parse.urlsplit("ss://" + decode64(uri.netloc))._replace(query=uri.query, fragment=uri.fragment)
        if not uri.hostname or not uri.port or not 1 <= uri.port <= 65535 or uri.path not in ("", "/"):
            raise ValueError
        host = uri.hostname
        try:
            host = str(ipaddress.ip_address(host))
        except ValueError:
            host = host.encode("idna").decode().lower()
            if not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", host):
                raise ValueError
        pairs = urllib.parse.parse_qsl(uri.query, keep_blank_values=True, strict_parsing=True, errors="strict")
        if len({key for key, _ in pairs}) != len(pairs):
            raise ValueError
        query = dict(pairs)
        if any(any(ord(c) < 32 or ord(c) == 127 for c in k + v) for k, v in pairs):
            raise ValueError
        authority = f"[{host}]:{uri.port}" if ":" in host else f"{host}:{uri.port}"
        if uri.scheme == "vless":
            if uri.password is not None:
                raise ValueError
            auth = {"uuid": str(uuid.UUID(clean_text(uri.username or "")))}
            authority = auth["uuid"] + "@" + authority
            if query.get("type") == "raw":
                query["type"] = "tcp"
            for key, default in (("type", "tcp"), ("security", "none"), ("encryption", "none"), ("flow", "")):
                if query.get(key) == default:
                    query.pop(key)
        elif uri.scheme == "ss":
            userinfo = clean_text(uri.netloc.rsplit("@", 1)[0])
            if ":" not in userinfo:
                userinfo = decode64(userinfo)
            method, password = userinfo.split(":", 1)
            if not method or not password or any(ord(c) < 32 or ord(c) == 127 for c in userinfo):
                raise ValueError
            auth = {"method": method, "password": password}
            authority = base64.urlsafe_b64encode(userinfo.encode()).decode().rstrip("=") + "@" + authority
        else:
            auth = {}
            if uri.username is not None:
                username, password = clean_text(uri.username), clean_text(uri.password or "")
                if not username or len(username.encode()) > 255 or len(password.encode()) > 255:
                    raise ValueError
                auth = {"username": username, "password": password}
                authority = urllib.parse.quote(username, safe="") + ":" + urllib.parse.quote(password, safe="") + "@" + authority
            if query:
                raise ValueError
        name = clean_text(uri.fragment)
        canonical = urllib.parse.urlunsplit((uri.scheme, authority, "", urllib.parse.urlencode(sorted(query.items())),
                                             urllib.parse.quote(name, safe="")))
        return NodeLink(uri.scheme, host, uri.port, name, canonical, auth, query)
    except (ValueError, UnicodeError, TypeError, OverflowError):
        raise DeployError("节点链接无效；请提供单条 VLESS、Shadowsocks 或 SOCKS5 链接。") from None
