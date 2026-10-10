"""Server-side relay transactions. Invoked under the maintenance operation lock."""

import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import urllib.parse
import uuid

if 'okp_panel_version' not in sys.modules:
    _spec = importlib.util.spec_from_file_location('okp_panel_version', Path(__file__).with_name('panel_version.py'))
    _policy = importlib.util.module_from_spec(_spec)
    sys.modules[_spec.name] = _policy
    _spec.loader.exec_module(_policy)
from okp_panel_version import MIN_PANEL_VERSION, supported


class RelayError(Exception):
    pass


def decode_object(value):
    if isinstance(value, str):
        value = json.loads(value)
    if not isinstance(value, dict):
        raise RelayError("Unexpected 3x-ui configuration response.")
    return value


def private_read(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "r", encoding="utf-8") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 8 * 1024 * 1024):
            raise RelayError("Unsafe relay transaction file.")
        return json.load(stream)


def private_write(path, value):
    fd, temporary = tempfile.mkstemp(prefix=".relay-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


API_BRIDGE = """
set -eu
export OKP_PRODUCTION_MODE=true
runtime=/usr/local/lib/one-key-proxy
. "$runtime/lib/common.sh"
. "$runtime/lib/state.sh"
. "$runtime/lib/config.sh"
. "$runtime/lib/platform.sh"
. "$runtime/lib/3xui.sh"
body=$(cat)
_xui_api_request "$1" "$2" "$body" '' "$3"
"""


def api(method, path, fields=None, *, form=False):
    body = (urllib.parse.urlencode(fields).encode() if form else json.dumps(fields or {}).encode())
    result = subprocess.run(["bash", "-c", API_BRIDGE, "relay-api", method, path, "form" if form else "json"],
                            input=body, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=100, check=False)
    if result.returncode:
        # Upstream error messages may echo proxy credentials.
        raise RelayError("3x-ui API operation failed; the relay transaction is retained for retry.")
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise RelayError("Unexpected 3x-ui API response.") from None


def merge_template(template, email, tag, inbound_tag, outbound, previous_outbound, previous_rule, *, remove=False, guard=None):
    candidate = copy.deepcopy(template)
    outbounds = candidate.get("outbounds")
    routing = candidate.get("routing")
    if not isinstance(outbounds, list) or not isinstance(routing, dict) or not isinstance(routing.get("rules"), list):
        raise RelayError("Unsupported Xray template structure.")
    rules = routing["rules"]
    own_out = [item for item in outbounds if item.get("tag") == tag]
    own_rules = [item for item in rules if email in item.get("user", [])]
    rule = {"type": "field", "inboundTag": [inbound_tag], "user": [email], "outboundTag": tag}
    if len(own_out) > 1 or len(own_rules) > 1:
        raise RelayError("Duplicate relay resources or an externally added user route.")
    if own_out and own_out[0] not in (previous_outbound, outbound):
        raise RelayError("The relay outbound was modified outside this script.")
    if own_rules and own_rules[0] not in (previous_rule, rule, guard):
        raise RelayError("The relay route was modified outside this script.")
    if own_out and outbounds[0] is own_out[0]:
        raise RelayError("The relay outbound was moved to the global default position.")
    if any(item.get("outboundTag") == tag and item not in own_rules for item in rules):
        raise RelayError("An unmanaged route references this relay outbound.")
    if any((item.get("proxySettings") or {}).get("tag") == tag or
           ((item.get("streamSettings") or {}).get("sockopt") or {}).get("dialerProxy") == tag for item in outbounds):
        raise RelayError("An unmanaged outbound references this relay.")
    if any(tag.startswith(selector) for balancer in routing.get("balancers", []) for selector in balancer.get("selector", [])):
        raise RelayError("An existing balancer would select the relay outbound.")
    candidate["outbounds"] = [item for item in outbounds if item not in own_out]
    routing["rules"] = [item for item in rules if item not in own_rules]
    if remove:
        return candidate, rule
    if not candidate["outbounds"]:
        raise RelayError("A pre-existing default outbound is required.")
    candidate["outbounds"].append(copy.deepcopy(outbound))
    rules = routing["rules"]
    # Preserve API and blocking rules ahead of the new per-user route.
    protected_tags = {item.get("tag") for item in outbounds if item.get("protocol") == "blackhole"}
    protected_tags.update(("api", "blocked", "block", (candidate.get("api") or {}).get("tag", "api")))
    protected = [i for i, item in enumerate(rules) if item.get("outboundTag") in protected_tags]
    insertion = max(protected, default=-1) + 1
    for item in rules[:insertion]:
        if item.get("outboundTag") in protected_tags:
            continue
        users = item.get("user")
        inbounds = item.get("inboundTag")
        if (not users or email in users) and (not inbounds or inbound_tag in inbounds):
            raise RelayError("Existing route ordering conflicts with the relay and blocking policies.")
    rules.insert(insertion, rule)
    return candidate, rule


class RelayServer:
    def __init__(self, context, directory, request_api=api):
        self.context, self.directory, self.api = context, Path(directory), request_api
        self.directory.mkdir(mode=0o700, exist_ok=True)
        info = self.directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise RelayError("Unsafe relay state directory.")

    def template(self):
        settings = decode_object(self.api("POST", "/panel/api/xray/"))
        return decode_object(settings["xraySetting"]), settings.get("outboundTestUrl", "")

    def save_template(self, template, test_url):
        self.api("POST", "/panel/api/xray/update", {"xraySetting": json.dumps(template), "outboundTestUrl": test_url}, form=True)
        if self.template()[0] != template:
            raise RelayError("Xray template read-back does not match the transaction.")

    def apply_template(self, original, candidate, test_url):
        if self.template()[0] != original:
            raise RelayError("The Xray template changed during the transaction; no overwrite was attempted.")
        try:
            self.save_template(candidate, test_url)
        except RelayError:
            if self.template()[0] == candidate:
                self.save_template(original, test_url)
            raise

    def client(self, record):
        # Read the whole collection so an absent client can be distinguished from transport errors.
        inbounds = self.api("GET", "/panel/api/inbounds/list")
        if not isinstance(inbounds, list):
            raise RelayError("Unexpected inbound list.")
        owned = [inbound for inbound in inbounds if inbound.get("id") == record["inbound_id"] and inbound.get("tag") == record["inbound_tag"]]
        if len(owned) != 1:
            raise RelayError("The managed entry inbound is missing or ambiguous.")
        inbound = owned[0]
        stream = decode_object(inbound.get("streamSettings", {}))
        uri = urllib.parse.urlsplit(self.context["vless_uri"])
        query = dict(urllib.parse.parse_qsl(uri.query))
        reality = stream.get("realitySettings", {})
        if (inbound.get("protocol") != "vless" or inbound.get("port") != self.context["inbound_port"]
                or stream.get("security") != "reality" or stream.get("network") not in ("tcp", "raw")
                or query.get("pbk") != reality.get("settings", {}).get("publicKey")
                or query.get("sni") not in reality.get("serverNames", []) or query.get("sid", "") not in reality.get("shortIds", [])):
            raise RelayError("The entry transport no longer matches the managed REALITY connection.")
        shared = {"protocol": inbound["protocol"], "port": inbound["port"], "listen": inbound.get("listen"), "streamSettings": stream}
        fingerprint = hashlib.sha256(json.dumps(shared, sort_keys=True).encode()).hexdigest()
        if record.get("entry_hash") is not None and record["entry_hash"] != fingerprint:
            raise RelayError("The shared entry transport was modified outside this script.")
        record["entry_hash"] = fingerprint
        matches = []
        for inbound in inbounds:
            settings = decode_object(inbound.get("settings", {}))
            for client in settings.get("clients", []):
                if client.get("email") == record["email"] or client.get("id") == record["uuid"]:
                    matches.append((inbound, client))
        if not matches:
            return None
        if len(matches) != 1:
            raise RelayError("Relay client ownership is ambiguous.")
        inbound, client = matches[0]
        if (inbound.get("id") != record["inbound_id"] or inbound.get("tag") != record["inbound_tag"]
                or client.get("email") != record["email"] or client.get("id") != record["uuid"]
                or client.get("flow", "") != "xtls-rprx-vision" or client.get("subId") != record["sub_id"]
                or client.get("limitIp", 0) != 0 or client.get("totalGB", 0) != 0 or client.get("expiryTime", 0) != 0):
            raise RelayError("Relay client parameters were modified outside this script.")
        return client

    def set_enabled(self, record, enabled):
        current = self.client(record)
        if current is not None and current.get("enable") is enabled:
            return
        result = self.api("POST", "/panel/api/clients/bulkEnable" if enabled else "/panel/api/clients/bulkDisable",
                          {"emails": [record["email"]]})
        if not isinstance(result, dict) or result.get("skipped"):
            raise RelayError("3x-ui could not change the relay client state.")
        client = self.client(record)
        if client is None or client.get("enable") is not enabled:
            raise RelayError("Relay client state read-back failed.")

    def verify_runtime(self, record, outbound):
        status = self.api("GET", "/panel/api/server/status")
        if not isinstance(status, dict) or status.get("xray", {}).get("state") != "running" or status.get("xray", {}).get("errorMsg"):
            raise RelayError("Xray did not apply a healthy runtime configuration.")
        runtime = decode_object(self.api("GET", "/panel/api/server/getConfigJson"))
        if (not any(item.get("tag") == record["tag"] and item.get("protocol") == outbound["protocol"]
                    for item in runtime.get("outbounds", []))
                or record["pending"]["rule"] not in runtime.get("routing", {}).get("rules", [])):
            raise RelayError("The relay is absent from the assembled runtime configuration.")
        self.verify_route(record, record["tag"])
        test = self.api("POST", "/panel/api/xray/testOutbound", {"outbound": json.dumps(outbound),
                        "allOutbounds": json.dumps(runtime["outbounds"]), "mode": "real"}, form=True)
        if not isinstance(test, dict) or test.get("success") is not True:
            raise RelayError("The exit proxy connection test failed; the relay client remains disabled.")

    def verify_route(self, record, tag):
        route = self.api("POST", "/panel/api/xray/routeTest", {"inboundTag": record["inbound_tag"],
                         "email": record["email"], "ip": "1.1.1.1", "port": "443", "network": "tcp"}, form=True)
        if not isinstance(route, dict) or route.get("matched") is not True or route.get("outboundTag") != tag:
            raise RelayError("The relay user does not route to its assigned outbound.")

    def check_version(self):
        if not supported(self.context.get('version')):
            raise RelayError(f'Remote relay requires supported 3x-ui {MIN_PANEL_VERSION} or newer within the same major.')

    def run(self, request):
        identity = request.get("identity", "")
        if not isinstance(identity, str) or not re.fullmatch(r"[0-9a-f]{32}", identity):
            raise RelayError("Invalid relay identity.")
        if request.get("installation_id") != self.context["installation_id"]:
            raise RelayError("The SSH server is not the bound entry installation.")
        path = self.directory / (identity + ".json")
        try:
            record = private_read(path)
        except FileNotFoundError:
            record = None
        operation = request.get("operation")
        if operation not in ("apply", "delete", "inspect"):
            raise RelayError("Unsupported relay operation.")
        if operation != "delete":
            self.check_version()
        if record is None and operation == "delete":
            # A lost deletion response is safe to retry only when no matching API resources remain.
            template, _ = self.template()
            email, tag = "okp-relay-" + identity, "okp-relay-" + identity
            if any(item.get("tag") == tag for item in template.get("outbounds", [])) or any(
                    email in item.get("user", []) for item in template.get("routing", {}).get("rules", [])):
                raise RelayError("Relay resources exist without their ownership record.")
            for inbound in self.api("GET", "/panel/api/inbounds/list"):
                if any(client.get("email") == email for client in decode_object(inbound["settings"]).get("clients", [])):
                    raise RelayError("Relay client exists without its ownership record.")
            return {"deleted": True}
        if record is None and operation == "inspect":
            raise RelayError("Relay ownership record is missing.")
        if record is None:
            record = {"version": 1, "identity": identity, "installation_id": self.context["installation_id"],
                      "inbound_id": self.context["inbound_id"], "inbound_tag": self.context["inbound_tag"],
                      "uuid": str(uuid.uuid4()), "email": "okp-relay-" + identity,
                      "sub_id": secrets.token_hex(16), "tag": "okp-relay-" + identity,
                      "outbound": None, "rule": None, "pending": None, "phase": "creating", "entry_hash": None}
        if (record["identity"] != identity or record["installation_id"] != self.context["installation_id"]
                or record["inbound_id"] != self.context["inbound_id"] or record["inbound_tag"] != self.context["inbound_tag"]):
            raise RelayError("The managed entry inbound identity changed.")
        template, test_url = self.template()
        if operation == "inspect":
            if record["pending"] is not None or record["phase"] != "active":
                raise RelayError("The remote relay transaction must be resumed first.")
            merge_template(template, record["email"], record["tag"], record["inbound_tag"],
                           record["outbound"], record["outbound"], record["rule"])
            client = self.client(record)
            if (client is None or client.get("enable") is not True or record["outbound"] not in template["outbounds"]
                    or record["rule"] not in template["routing"]["rules"]):
                raise RelayError("Active relay resources were changed outside this script.")
            return self.result(record)
        if operation == "delete":
            if record["phase"] == "active" and (record["outbound"] not in template["outbounds"] or record["rule"] not in template["routing"]["rules"]):
                raise RelayError("Active relay resources were removed outside this script.")
            desired = record["pending"]["outbound"] if record["pending"] else record["outbound"]
            candidate, _ = merge_template(template, record["email"], record["tag"], record["inbound_tag"],
                                           desired, record["outbound"], record["rule"], remove=True,
                                           guard=record["pending"].get("guard") if record["pending"] else None)
            client = self.client(record)
            if record["phase"] == "active" and client is None:
                raise RelayError("Relay client was deleted outside this script.")
            record["phase"] = "deleting"
            private_write(path, record)
            if client is not None:
                self.set_enabled(record, False)
                self.api("POST", "/panel/api/clients/del/" + record["email"])
                if self.client(record) is not None:
                    raise RelayError("Relay client deletion could not be verified.")
            self.apply_template(template, candidate, test_url)
            path.unlink()
            return {"deleted": True}
        outbound = request.get("outbound")
        if (not isinstance(outbound, dict) or outbound.get("protocol") not in ("vless", "shadowsocks", "socks")
                or set(outbound) - {"protocol", "settings", "streamSettings", "tag"}):
            raise RelayError("Unsupported exit outbound configuration.")
        outbound = dict(copy.deepcopy(outbound), tag=record["tag"])
        if record["phase"] == "deleting":
            raise RelayError("Resume remote relay deletion first.")
        if record["pending"] and record["pending"]["outbound"] != outbound:
            raise RelayError("A different relay update is pending; resume the original transaction.")
        client = self.client(record)
        if record["phase"] == "active":
            if client is None or record["outbound"] not in template["outbounds"] or record["rule"] not in template["routing"]["rules"]:
                raise RelayError("Active relay resources were removed outside this script.")
            if record["outbound"] == outbound:
                merge_template(template, record["email"], record["tag"], record["inbound_tag"],
                               outbound, record["outbound"], record["rule"])
                if client.get("enable") is not True:
                    raise RelayError("Relay client was disabled outside this script.")
                return self.result(record)
        candidate, rule = merge_template(template, record["email"], record["tag"], record["inbound_tag"],
                                         outbound, record["outbound"], record["rule"],
                                         guard=record["pending"].get("guard") if record["pending"] else None)
        if record["pending"] is None:
            blocked = next((item.get("tag") for item in template["outbounds"] if item.get("protocol") == "blackhole" and item.get("tag")), None)
            if not blocked:
                raise RelayError("A blackhole outbound is required to protect new relay accounts during creation.")
            record["pending"] = {"outbound": outbound, "rule": rule, "original_template": template,
                                 "candidate_template": candidate, "test_url": test_url,
                                 "guard": dict(rule, outboundTag=blocked)}
        record["phase"] = "applying"
        private_write(path, record)
        if client is None:
            # Guard the identity before any client API call, including unexpected older API behavior.
            guarded = copy.deepcopy(candidate)
            guarded["routing"]["rules"] = [record["pending"]["guard"] if item == rule else item
                                             for item in guarded["routing"]["rules"]]
            self.apply_template(template, guarded, test_url)
            self.verify_route(record, record["pending"]["guard"]["outboundTag"])
            template = guarded
            self.api("POST", "/panel/api/clients/add", {"client": {"id": record["uuid"], "email": record["email"],
                     "subId": record["sub_id"], "flow": "xtls-rprx-vision", "enable": False, "limitIp": 0,
                     "totalGB": 0, "expiryTime": 0, "tgId": 0, "reset": 0, "comment": "one-key-proxy remote relay"},
                     "inboundIds": [record["inbound_id"]]})
            client = self.client(record)
            if client is None or client.get("enable") is not False:
                raise RelayError("Disabled relay client creation failed.")
        self.set_enabled(record, False)
        self.apply_template(template, candidate, test_url)
        self.verify_runtime(record, outbound)
        self.set_enabled(record, True)
        record.update(outbound=outbound, rule=rule, pending=None, phase="active")
        private_write(path, record)
        return self.result(record)

    def result(self, record):
        uri = urllib.parse.urlsplit(self.context["vless_uri"])
        link = uri._replace(netloc=record["uuid"] + "@" + uri.netloc.rsplit("@", 1)[-1],
                            fragment="okp-remote:" + record["identity"]).geturl()
        return {"link": link, "installation_id": record["installation_id"], "email": record["email"],
                "inbound_tag": record["inbound_tag"], "outbound_tag": record["tag"]}


def main():
    os.umask(0o077)
    try:
        if os.getuid() != 0:
            raise RelayError("Remote relay maintenance requires root.")
        context = json.loads(os.environ["OKP_REMOTE_RELAY_CONTEXT"])
        request = json.loads(sys.stdin.buffer.read(128 * 1024 + 1))
        server = RelayServer(context, "/etc/one-key-proxy/remote-relays")
        print(json.dumps(server.run(request), ensure_ascii=False))
    except (RelayError, ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        print(str(error) if isinstance(error, RelayError) else "Remote relay operation failed; its transaction is retained.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
