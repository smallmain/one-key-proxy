#!/usr/bin/env python3
"""Install, add, remove and inspect proxy configurations. Requires Python 3.9+."""

import argparse
import base64
import binascii
import contextlib
import copy
import fcntl
import graphlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from deploy_resources import DeployError, ManagedDeployments, SingBox, configuration_label, is_standalone
from deploy_templates import AIRPORT_DEFAULTS, LOCAL_SS_METHOD, LOCAL_SS_GROUP, LOCAL_SS_TAGS
from deploy_subscription import subscription_export, validate_url
from deploy_links import parse_node_link
from deploy_nodes import NodeManager


ROOT = Path(__file__).resolve().parent
REMOTE_KEYS = frozenset("""
OKP_MODE OKP_PUBLIC_IPV4 OKP_PUBLIC_IPV6 OKP_ENABLE_IPV6
OKP_PANEL_USERNAME OKP_PANEL_PASSWORD OKP_NODE_NAME OKP_REALITY_TARGET
OKP_FQDN OKP_ALI_ACCESS_KEY_ID OKP_ALI_ACCESS_KEY_SECRET OKP_ACME_EMAIL
OKP_PANEL_PORT OKP_NODE_PORT OKP_SUB_PORT OKP_PANEL_MAP OKP_NODE_MAP OKP_SUB_MAP
""".split())
LOCAL_KEYS = frozenset(("SUBLINKPRO_URL", "SUBLINKPRO_API_KEY", "SUBLINKPRO_GROUP",
                        "ENABLE_LOCAL_NODE", "SINGBOX_CONFIG", "SINGBOX_BINARY", "SINGBOX_SERVICE_LABEL"))
EXPORT_KEYS = frozenset(("INSTALLATION_ID", "NODE_NAME", "SUBSCRIPTION_URL", "MODE", "VLESS_URI"))
REMOTE_DIR = re.compile(r"/tmp/one-key-proxy\.deploy\.[A-Za-z0-9]{8,32}")
RESUME_TYPES = {
    "action": str, "env_file": str, "target": str, "port": int, "identity": str,
    "password": bool, "mode": str, "domain": str, "airport_name": str, "name": str,
    "local_port": int, "create_local_node": bool, "no_sync": bool, "auth_method": str,
    "relay": str, "source": str, "subscription_url": str, "insecure_subscription": bool,
    "subscription_node": str,
    "node_link": str, "local_link": str, "same_local": bool, "adopt_node": int,
}


class ResumeState:
    """Private atomic checkpoints; subscription URLs may contain access tokens."""

    def __init__(self, directory=None):
        self.directory = Path(directory) if directory is not None else ROOT / ".deploy-state"
        self.path = self.directory / "pending.json"
        self.data = None

    def check_directory(self):
        info = self.directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise DeployError("恢复目录必须属于当前用户、权限为 0700，且不能是链接。")

    @staticmethod
    def open_private(path, flags):
        fd = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600):
            os.close(fd)
            raise DeployError("恢复文件必须属于当前用户、权限为 0600，且不能是链接。")
        return fd

    @staticmethod
    def validate(data):
        try:
            if (not isinstance(data, dict) or set(data) != {"version", "phase", "installation_id", "options"}
                    or type(data["version"]) is not int or data["version"] != 1
                    or data["phase"] not in ("input", "install", "sync") or not isinstance(data["options"], dict)):
                raise ValueError
            identity = data["installation_id"]
            if identity is not None and (not isinstance(identity, str) or not re.fullmatch(r"[0-9a-fA-F]{32}", identity)):
                raise ValueError
            options = data["options"]
            for key, value in options.items():
                if key not in RESUME_TYPES or (value is not None and type(value) is not RESUME_TYPES[key]):
                    raise ValueError
                if isinstance(value, str) and (len(value) > 4096 or any(ord(c) < 32 or ord(c) == 127 for c in value)):
                    raise ValueError
            if options.get("action") not in ("install", "add", "sync", "edit") or not Path(options["env_file"]).is_absolute():
                raise ValueError
            if options.get("source") not in (None, "ssh", "subscription", "node"):
                raise ValueError
            if options.get("adopt_node") is not None and options["adopt_node"] <= 0:
                raise ValueError
            if options.get("mode") not in (None, "nat", "public"):
                raise ValueError
            if options.get("auth_method") not in (None, "password", "key", "auto"):
                raise ValueError
            for key in ("port", "local_port"):
                if options.get(key) is not None and not 1 <= options[key] <= 65535:
                    raise ValueError
        except (KeyError, ValueError, TypeError):
            raise DeployError("恢复记录格式无效；请检查 .deploy-state/pending.json。") from None

    def load(self):
        if not self.directory.exists() and not self.directory.is_symlink():
            self.data = None
            return None
        self.check_directory()
        try:
            fd = self.open_private(self.path, os.O_RDONLY)
        except FileNotFoundError:
            self.data = None
            return None
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            raw = stream.read(65537)
        try:
            if len(raw) > 65536:
                raise ValueError
            data = json.loads(raw)
        except (ValueError, UnicodeError):
            raise DeployError("恢复记录无法解析；请检查 .deploy-state/pending.json。") from None
        self.validate(data)
        self.data = data
        return data

    @contextlib.contextmanager
    def locked(self):
        self.directory.mkdir(mode=0o700, exist_ok=True)
        self.check_directory()
        fd = self.open_private(self.directory / "lock", os.O_CREAT | os.O_RDWR)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise DeployError("另一个部署流程正在运行，请待其结束后再继续。") from None
            yield self
        finally:
            os.close(fd)

    def save(self):
        self.validate(self.data)
        fd, temporary = tempfile.mkstemp(prefix=".pending-", dir=self.directory)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                json.dump(self.data, stream, ensure_ascii=False, indent=2)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def start(self, action, env_file):
        self.data = {"version": 1, "phase": "input", "installation_id": None,
                     "options": {"action": action, "env_file": str(env_file)}}
        self.save()

    def capture(self, **values):
        self.data["options"].update(values)
        self.save()

    def answered(self, key):
        return key in self.data["options"]

    def phase(self, value, installation_id=None):
        self.data["phase"] = value
        if installation_id is not None:
            self.data["installation_id"] = installation_id
        self.save()

    def complete(self):
        self.path.unlink()
        self.data = None


def local_node_default(config):
    value = config.get("ENABLE_LOCAL_NODE", "true").lower()
    if value not in ("true", "false"):
        raise DeployError("ENABLE_LOCAL_NODE must be true or false.")
    return value == "true"


def prompt_text(label, default=None, *, required=False):
    while True:
        try:
            value = input(label + (f" [{default}]" if default else "") + ": ").strip()
        except EOFError:
            raise DeployError("已取消交互输入。") from None
        value = value or default
        if value or not required:
            return value
        print("此项不能为空。", file=sys.stderr)


def prompt_yes_no(label, default):
    while True:
        value = prompt_text(label + (" [Y/n]" if default else " [y/N]"))
        if value is None:
            return default
        if value.lower() in ("y", "yes", "n", "no", "是", "否"):
            return value.lower() in ("y", "yes", "是")
        print("请输入 y 或 n（是/否）。", file=sys.stderr)


def choose_action(pending=None):
    print("\nOne-Key-Proxy\n  1. 安装配置\n  2. 添加配置\n  3. 删除配置\n  4. 查看配置\n  5. 检查环境\n  0. 退出")
    choices = {"1": "install", "2": "add", "3": "remove", "4": "list", "5": "check", "0": None, "q": None}
    while True:
        value = prompt_text("请选择", "0").lower()
        if value in choices:
            return choices[value]
        print("请输入菜单中的编号。", file=sys.stderr)


def choose_pending(pending):
    phase = {"input": "填写配置", "install": "安装 VPS", "sync": "添加配置"}[pending["phase"]]
    print(f"\n存在未完成的流程（{phase}）。\n  1. 继续上次\n  2. 重新开始\n  0. 返回")
    while True:
        value = prompt_text("请选择", "1")
        if value in ("0", "1", "2"):
            return value


def configure_interactive(args, config, checkpoint=None):
    if args.action == "check":
        return

    def remember(**values):
        vars(args).update(values)
        if checkpoint:
            checkpoint.capture(**values)

    if args.action in ("add", "sync"):
        if not getattr(args, "source", None):
            if getattr(args, "subscription_url", None):
                remember(source="subscription")
            elif args.target:
                remember(source="ssh")
            else:
                while True:
                    value = prompt_text("配置来源（1=SSH，2=订阅地址，3=单条节点链接）", "1")
                    if value in ("1", "2", "3"):
                        remember(source={"1": "ssh", "2": "subscription", "3": "node"}[value])
                        break
        if args.source == "node":
            if not getattr(args, "node_link", None):
                remember(node_link=prompt_text("节点链接", required=True))
            return
        if args.source == "subscription":
            if not getattr(args, "subscription_url", None):
                remember(subscription_url=prompt_text("订阅地址", required=True))
            validate_url(args.subscription_url)
            if getattr(args, "insecure_subscription", None) is None:
                remember(insecure_subscription=prompt_yes_no("订阅是否使用自签名证书（跳过证书校验）", False))
            configure_integration(args, config, checkpoint, remember)
            return

    vars(args).setdefault("auth_method", None)
    if not args.target:
        remember(target=prompt_text("SSH 目标（root@主机或 SSH 配置别名）", required=True))
    if args.port is None and not (checkpoint and checkpoint.answered("port")):
        while True:
            value = prompt_text("SSH 端口（留空使用 SSH 配置）")
            if value is None:
                remember(port=None)
                break
            if re.fullmatch(r"[0-9]{1,5}", value) and 1 <= int(value) <= 65535:
                remember(port=int(value))
                break
            print("SSH 端口必须在 1 到 65535 之间。", file=sys.stderr)
    if args.password:
        remember(auth_method="password")
    elif args.identity:
        remember(auth_method="key")
    elif args.auth_method is None:
        while True:
            method = prompt_text("SSH 登录方式（1=主机密码，2=私钥，3=SSH 配置/agent）", "1")
            if method == "1":
                remember(password=True, identity=None, auth_method="password")
                break
            if method == "2":
                remember(auth_method="key", password=False)
                break
            if method == "3":
                remember(password=False, identity=None, auth_method="auto")
                break
            print("请输入 1、2 或 3。", file=sys.stderr)
    if args.auth_method == "key" and not args.identity:
        remember(identity=prompt_text("SSH 私钥路径", required=True))
    if args.action == "install":
        if args.mode is None:
            default = config.get("OKP_MODE") or "nat"
            if default not in ("nat", "public"):
                default = "nat"
            while True:
                value = prompt_text("VPS 模式（nat=NAT，public=普通 VPS）", default).lower()
                if value in ("nat", "public"):
                    remember(mode=value)
                    break
                print("请输入 nat 或 public。", file=sys.stderr)
        if args.mode == "public" and args.domain is None:
            remember(domain=prompt_text("VPS 完整域名", config.get("OKP_FQDN"), required=True))
    configure_integration(args, config, checkpoint, remember)


def configure_integration(args, config, checkpoint, remember):
    if (not args.no_sync and (config.get("SUBLINKPRO_URL") or config.get("SUBLINKPRO_API_KEY")
                              or args.action in ("add", "sync"))
            and args.create_local_node is None and args.local_port is None):
        remember(create_local_node=prompt_yes_no("是否启用本地节点（sing-box + SublinkPro）", local_node_default(config)))
    if checkpoint and not args.no_sync and getattr(args, "relay", None) is None and not checkpoint.answered("relay"):
        registry = ManagedDeployments(checkpoint)
        choices = [(key, value) for key, value in registry.records.items() if value["status"] == "active"]
        if choices and prompt_yes_no("此节点是否需要其他节点中转", False):
            for index, (_, record) in enumerate(choices, 1):
                print(f"  {index}. {record['node_name']}")
            while True:
                value = prompt_text("选择中转节点", required=True)
                if value.isdigit() and 1 <= int(value) <= len(choices):
                    remember(relay=choices[int(value) - 1][0])
                    break
        else:
            remember(relay="")


def configure_resource_names(args, config, checkpoint, interactive):
    registry = ManagedDeployments(checkpoint)
    service_url = config.get("SUBLINKPRO_URL", "").rstrip("/")
    identity = checkpoint.data["installation_id"]
    if getattr(args, "source", None) == "subscription":
        identity = subscription_export(args.subscription_url, service_url)["INSTALLATION_ID"]
    matches = [record for key, record in registry.records.items()
               if record["status"] == "active" and record["sublink_url"] == service_url
               and (key == identity if identity else record["target"] == args.target)]
    existing = len(matches) == 1
    for option, label in (("airport_name", "机场名称"), ("name", "节点名称")):
        value = getattr(args, option)
        # Omitted names on managed updates stay omitted so live airport settings win.
        if value is None and (existing or not interactive):
            continue
        if value is None:
            default = config.get("OKP_NODE_NAME") if option == "name" and args.action == "install" else None
            while True:
                value = prompt_text(label, default, required=True)
                try:
                    value = SublinkPro.custom_name(value, "", label, False)
                    break
                except DeployError as error:
                    print(str(error), file=sys.stderr)
        else:
            value = SublinkPro.custom_name(value, "", label, False)
        setattr(args, option, value)
        checkpoint.capture(**{option: value})


def read_env(path):
    """Read a deliberately literal dotenv subset, without evaluating shell code."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        raise DeployError("Cannot open .env. Create it from .env.example and chmod 600 it.") from None
    with os.fdopen(fd, "r", encoding="utf-8-sig") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600):
            raise DeployError("The env file must be owned by you, mode 0600, with no links.")
        if info.st_size > 65536:
            raise DeployError("The env file is too large.")
        config = {}
        for number, raw in enumerate(stream, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            key, separator, value = line.partition("=")
            key, value = key.strip(), value.strip()
            if not separator or key not in REMOTE_KEYS | LOCAL_KEYS or key in config:
                raise DeployError(f"Invalid, unsupported or duplicate env key on line {number}.")
            if value.startswith(("'", '"')):
                if len(value) < 2 or value[-1] != value[0]:
                    raise DeployError(f"Unclosed quote on env line {number}.")
                value = value[1:-1]
            if any(ord(char) < 32 or ord(char) == 127 for char in value):
                raise DeployError(f"Control character on env line {number}.")
            config[key] = value
    return config


def encode_defaults(config):
    # Empty credentials still prompt; an explicitly empty ACME email skips its prompt.
    return "".join(
        f"{key}={base64.b64encode(value.encode()).decode()}\n"
        for key, value in sorted(config.items())
        if key in REMOTE_KEYS and (value or key == "OKP_ACME_EMAIL")
    ).encode()


def build_archive(config, root=ROOT):
    """Only runtime source files and allowlisted defaults cross the SSH connection."""
    output = io.BytesIO()
    paths = [Path(name) for name in
             ("bootstrap.sh", "install.sh", "maintenance.sh", "one-key-proxy", "VERSION")]
    paths.extend(path.relative_to(root) for path in sorted((root / "lib").glob("*.sh")))
    with tarfile.open(fileobj=output, mode="w") as archive:
        for relative in paths:
            path = root / relative
            if path.is_symlink() or not path.is_file() or path.stat().st_nlink != 1:
                raise DeployError("Runtime sources must be regular files without links.")
            content = path.read_bytes()
            member = tarfile.TarInfo("project/" + relative.as_posix())
            member.mode = 0o700 if path.suffix == ".sh" or path.name == "one-key-proxy" else 0o600
            member.size = len(content)
            archive.addfile(member, io.BytesIO(content))
        content = encode_defaults(config)
        member = tarfile.TarInfo("defaults.env")
        member.mode, member.size = 0o600, len(content)
        archive.addfile(member, io.BytesIO(content))
    return output.getvalue()


EXPORT_SCRIPT = """
set -eu
[ "$(id -u)" = 0 ] || exit 1
exec 9>/run/one-key-proxy/operation.lock
flock -s -w 10 9 || exit 1
. /usr/local/lib/one-key-proxy/lib/state.sh
[ "$(state_get MANAGED_BY)" = one-key-proxy ] || exit 1
stage_is_done completed || exit 1
for key in INSTALLATION_ID NODE_NAME SUBSCRIPTION_URL MODE VLESS_URI; do
    value=$(state_get "$key") || exit 1
    printf '%s=%s\\n' "$key" "$(_state_encode "$value")"
done
"""


def parse_export(document):
    result = {}
    try:
        for line in document.decode("ascii").splitlines():
            key, value = line.split("=", 1)
            if key not in EXPORT_KEYS or key in result:
                raise ValueError
            result[key] = base64.b64decode(value, validate=True).decode("utf-8")
        if result.keys() != EXPORT_KEYS:
            raise ValueError
        if not re.fullmatch(r"[0-9a-fA-F]{32}", result["INSTALLATION_ID"]):
            raise ValueError
        if any(ord(char) < 32 or ord(char) == 127 for value in result.values() for char in value):
            raise ValueError
        if not result["NODE_NAME"] or len(result["NODE_NAME"]) > 80:
            raise ValueError
        uri = urllib.parse.urlsplit(result["SUBSCRIPTION_URL"])
        if (uri.scheme != "https" or not uri.hostname or uri.username or uri.password
                or not re.fullmatch(r"/sub/[A-Za-z0-9_-]+", uri.path)
                or uri.query or uri.fragment or any(char.isspace() for char in result["SUBSCRIPTION_URL"])
                or result["MODE"] not in ("nat", "public")):
            raise ValueError
        _ = uri.port
        vless = urllib.parse.urlsplit(result["VLESS_URI"])
        if vless.scheme != "vless" or not vless.hostname or not vless.username or not vless.port:
            raise ValueError
    except (ValueError, UnicodeError, binascii.Error):
        raise DeployError("VPS did not return a valid completed deployment. No airport was imported.") from None
    return result


class SSH:
    def __init__(self, target, socket_dir, port=None, identity=None, *, password_login=False):
        if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.:@\[\]-]*", target):
            raise DeployError("Invalid SSH target. Use root@host or an SSH config alias.")
        if password_login and identity:
            raise DeployError("Choose either password login or an explicit SSH identity.")
        self.target = target
        self.password_login = password_login
        self.connected = False
        self.options = [
            "ssh", "-o", "ControlMaster=auto", "-o", "ControlPersist=60",
            "-o", f"ControlPath={socket_dir}/ssh.sock", "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
            "-o", "ClearAllForwardings=yes", "-o", "RemoteCommand=none",
        ]
        if port:
            if not 1 <= port <= 65535:
                raise DeployError("SSH port must be between 1 and 65535.")
            self.options += ["-p", str(port)]
        if identity:
            self.options += ["-i", str(Path(identity).expanduser())]
        if password_login:
            self.options += [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no", "-o", "PasswordAuthentication=yes",
                "-o", "KbdInteractiveAuthentication=yes", "-o", "BatchMode=no",
                "-o", "NumberOfPasswordPrompts=3",
            ]

    def connect(self):
        if self.connected:
            return
        # OpenSSH reads passwords from the terminal before -f backgrounds the master.
        # Authenticate without a remote command or deployment data on standard input.
        environment = dict(os.environ)
        if self.password_login:
            environment["SSH_ASKPASS_REQUIRE"] = "never"
        try:
            result = subprocess.run(self.options + ["-N", "-f", "--", self.target],
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                    stderr=None, env=environment, timeout=180, check=False)
        except subprocess.TimeoutExpired:
            raise DeployError("SSH 登录超时，请重试。") from None
        if result.returncode:
            raise DeployError("SSH 登录失败，请检查主机、用户名、密码或密钥，以及服务端允许的认证方式。")
        self.connected = True

    def run(self, script, *, data=None, interactive=False, timeout=60):
        command = self.options + ["-tt" if interactive else "-T", "--", self.target, script]
        try:
            result = subprocess.run(command, input=data, check=False,
                                    stdout=None if interactive else subprocess.PIPE,
                                    stderr=None if interactive else subprocess.PIPE,
                                    timeout=None if interactive else timeout)
        except subprocess.TimeoutExpired:
            raise DeployError("SSH operation timed out. Check VPS connectivity and retry.") from None
        if result.returncode:
            raise DeployError("SSH operation failed. Check SSH login, root access and remote prerequisites.")
        return result.stdout

    def close(self):
        try:
            subprocess.run(self.options + ["-O", "exit", "--", self.target],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False)
        except (OSError, subprocess.TimeoutExpired):
            pass
        self.connected = False


def install(ssh, config):
    archive = build_archive(config)
    directory = ssh.run(
        'set -eu; [ "$(id -u)" = 0 ]; command -v tar >/dev/null; '
        'umask 077; mktemp -d /tmp/one-key-proxy.deploy.XXXXXXXX'
    ).decode().strip()
    if not REMOTE_DIR.fullmatch(directory):
        raise DeployError("SSH returned an unexpected staging path.")
    try:
        ssh.run(f"umask 077; tar -xf - -C {shlex.quote(directory)}", data=archive, timeout=120)
        # Remote cleanup also runs on terminal disconnect. Defaults are outside the runtime tree.
        script = (
            "set -eu; "
            f"trap {shlex.quote('rm -rf -- ' + shlex.quote(directory))} EXIT; "
            "trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM; "
            f"sh {directory}/project/bootstrap.sh --local-project {directory}/project "
            f"--defaults-file {directory}/defaults.env"
        )
        ssh.run("sh -c " + shlex.quote(script), interactive=True)
    finally:
        try:
            ssh.run(f"rm -rf -- {shlex.quote(directory)}", timeout=20)
        except DeployError:
            print("Warning: could not confirm remote staging cleanup; remove " + directory,
                  file=sys.stderr)


def export_node(ssh):
    command = "env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root "
    return parse_export(ssh.run(command + "bash -c " + shlex.quote(EXPORT_SCRIPT)))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class SublinkPro:
    def __init__(self, config, *, create_local_node=None):
        self.url = config.get("SUBLINKPRO_URL", "").rstrip("/")
        self.key = config.get("SUBLINKPRO_API_KEY", "")
        self.group = config.get("SUBLINKPRO_GROUP")
        self.create_local_node = local_node_default(config) if create_local_node is None else create_local_node
        try:
            parsed = urllib.parse.urlsplit(self.url)
            valid = (parsed.scheme == "https" and parsed.hostname and not parsed.username
                     and not parsed.password and not parsed.query and not parsed.fragment
                     and not any(char.isspace() for char in self.url))
            _ = parsed.port
        except ValueError:
            valid = False
        if not valid or not self.key:
            raise DeployError("Set both SUBLINKPRO_URL (HTTPS) and SUBLINKPRO_API_KEY in .env.")
        if any(ord(char) < 33 or ord(char) > 126 for char in self.key):
            raise DeployError("SUBLINKPRO_API_KEY must contain printable ASCII without whitespace.")
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, path, fields=None, *, method=None, form=False):
        headers = {"X-API-Key": self.key, "Accept": "application/json"}
        data = None
        if fields is not None:
            data = urllib.parse.urlencode(fields).encode() if form else json.dumps(fields, ensure_ascii=False).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
        request = urllib.request.Request(
            self.url + "/api/v1/" + path,
            data=data, headers=headers, method=method,
        )
        try:
            with self.opener.open(request, timeout=20) as response:
                content = response.read(8 * 1024 * 1024 + 1)
                if len(content) > 8 * 1024 * 1024:
                    raise DeployError("SublinkPro response exceeded the size limit.")
                document = json.loads(content)
        except urllib.error.HTTPError as error:
            error.close()
            raise DeployError(f"SublinkPro returned HTTP {error.code}; verify the URL and API key.") from None
        except (OSError, urllib.error.URLError, ValueError):
            raise DeployError("SublinkPro request failed; check connectivity, TLS and API compatibility.") from None
        if not isinstance(document, dict) or document.get("code") != 200:
            # API messages can echo links and credentials. Do not print the response body.
            raise DeployError("SublinkPro rejected the request; check permissions or conflicting airports/nodes.")
        return document.get("data")

    @staticmethod
    def settings(airport):
        if (not isinstance(airport, dict) or type(airport.get("id")) is not int or airport["id"] <= 0
                or not isinstance(airport.get("name"), str) or not airport["name"]
                or not isinstance(airport.get("url"), str) or not airport["url"]
                or not isinstance(airport.get("cronExpr"), str) or not airport["cronExpr"]):
            raise DeployError("Unexpected SublinkPro airport configuration.")
        result = {key: copy.deepcopy(airport.get(key, default)) for key, default in AIRPORT_DEFAULTS.items()}
        if result["requestHeaders"] is None:
            result["requestHeaders"] = []
        if any(type(result[key]) is not type(default) for key, default in AIRPORT_DEFAULTS.items()):
            raise DeployError("Unexpected field types in SublinkPro airport configuration.")
        return result

    def nodes(self, search):
        data = self.request("nodes/get?" + urllib.parse.urlencode({"search": search, "protocol": "ss"}))
        if data is None:
            return []
        if not isinstance(data, list) or any(not isinstance(node, dict) for node in data):
            raise DeployError("Unexpected SublinkPro node list format.")
        return data

    @staticmethod
    def local_ss_link(node):
        try:
            raw = node.get("Link")
            if not isinstance(raw, str) or any(ord(char) < 32 or ord(char) == 127 for char in raw):
                raise ValueError
            uri = urllib.parse.urlsplit(raw)
            if (type(node.get("ID")) is not int or node["ID"] <= 0 or not isinstance(node.get("Name"), str)
                    or node.get("Protocol") != "ss" or uri.scheme != "ss" or uri.hostname != "127.0.0.1"
                    or not uri.username or not uri.port or node.get("SourceID", 0) != 0
                    or node.get("Source", "manual") not in ("", "manual")
                    or not isinstance(node.get("Group", ""), str)
                    or not isinstance(node.get("DialerProxyName", ""), str)):
                raise ValueError
        except (KeyError, TypeError, ValueError):
            raise DeployError("Local nodes must be manual SIP002 Shadowsocks nodes at 127.0.0.1.") from None
        return uri

    def find_local_node(self, marker):
        matches = []
        for node in self.nodes(marker):
            try:
                fragment = urllib.parse.unquote(urllib.parse.urlsplit(node.get("Link", "")).fragment)
            except (ValueError, TypeError):
                continue
            if fragment == marker:
                matches.append(node)
        if len(matches) > 1:
            raise DeployError("Multiple local nodes match this installation; resolve the conflict in SublinkPro.")
        if matches:
            self.local_ss_link(matches[0])
        return matches[0] if matches else None

    def node_tags(self, node_id):
        tags = self.request("tags/node/tags?" + urllib.parse.urlencode({"nodeId": node_id}))
        if tags is None:
            tags = []
        if not isinstance(tags, list) or any(not isinstance(tag, dict) or not isinstance(tag.get("name"), str)
                                             for tag in tags):
            raise DeployError("Unexpected node tag response.")
        names = [tag["name"] for tag in tags]
        if any(not name.strip() or name != name.strip() or "," in name for name in names):
            raise DeployError("Node tags cannot be preserved through the update API.")
        return names

    @staticmethod
    def local_port(value, default=None, interactive=False):
        if value is None and default is not None:
            return default
        while True:
            if value is None:
                if not interactive:
                    raise DeployError("First local-node import requires --local-port (1-65535).")
                try:
                    value = input("Surge 设备的本地 Shadowsocks 端口（1-65535）: ").strip()
                except EOFError:
                    raise DeployError("Port input cancelled; retry sync with --local-port.") from None
            if re.fullmatch(r"[0-9]{1,5}", str(value)) and 1 <= int(value) <= 65535:
                return int(value)
            if not interactive:
                raise DeployError("Local Shadowsocks port must be between 1 and 65535.")
            print("请输入 1 到 65535 之间的整数。", file=sys.stderr)
            value = None

    @staticmethod
    def airport_node_name(fields, default):
        raw = fields["nodeNamePreprocess"]
        if not raw:
            return default
        try:
            rules = json.loads(raw)
            if not isinstance(rules, list) or len(rules) != 1 or not isinstance(rules[0], dict):
                raise ValueError
            rule = rules[0]
            if (rule.get("matchMode") != "regex" or rule.get("pattern") != ".+"
                    or rule.get("enabled") is not True
                    or not re.fullmatch(r"(?:[^$]|\$\$)*", rule["replacement"])):
                raise ValueError
            return rule["replacement"].replace("$$", "$")
        except (ValueError, TypeError, KeyError, IndexError):
            raise DeployError("Cannot derive the local node name from custom preprocessing; supply --node-name.") from None

    def prepare_local_node(self, marker, name, port, interactive, on_input=None, preserve_name=False):
        existing = self.find_local_node(marker)
        if existing:
            uri = self.local_ss_link(existing)
        else:
            auth = base64.urlsafe_b64encode(f"{LOCAL_SS_METHOD}:{secrets.token_urlsafe(32)}".encode()).decode().rstrip("=")
            uri = urllib.parse.urlsplit(f"ss://{auth}@127.0.0.1:1")
        port = self.local_port(port, uri.port if existing else None, interactive)
        if on_input:
            on_input(local_port=port)
        # Updates retain credentials; new nodes receive independent random passwords.
        netloc = uri.netloc.rsplit("@", 1)[0] + f"@127.0.0.1:{port}"
        link = uri._replace(netloc=netloc, fragment=urllib.parse.quote(marker, safe="")).geturl()
        connection = urllib.parse.urlsplit(link)._replace(fragment="").geturl()
        for node in self.nodes("127.0.0.1"):
            if existing and node.get("ID") == existing["ID"]:
                continue
            try:
                other = urllib.parse.urlsplit(node.get("Link", ""))
                same_connection = (other._replace(fragment="").geturl() == connection or
                                   (other.hostname == "127.0.0.1" and other.port == port))
            except (ValueError, TypeError):
                continue
            if same_connection:
                raise DeployError("This local Shadowsocks connection already exists; choose an unused local port.")
        name = existing["Name"] if existing and preserve_name else "[SM]" + name + " - \u672c\u5730"
        conflicts = [node for node in self.nodes(name)
                     if node.get("Name") == name and (not existing or node.get("ID") != existing["ID"])]
        if conflicts:
            raise DeployError("The local node name already exists; choose a different node name.")
        fields = {"name": name, "link": link, "nameMode": "remark",
                  "group": existing.get("Group", "") if existing else LOCAL_SS_GROUP,
                  "dialerProxyName": existing.get("DialerProxyName", "") if existing else "",
                  "tags": ",".join(self.node_tags(existing["ID"])) if existing else LOCAL_SS_TAGS}
        return existing, fields

    def sync_local_node(self, marker, existing, fields):
        changed = not existing or any(existing.get(key) != fields[field] for key, field in
                                     (("Name", "name"), ("Link", "link"), ("NameMode", "nameMode")))
        if changed:
            payload = dict(fields)
            if existing:
                payload.update(oldname=existing["Name"], oldlink=existing["Link"])
            self.request("nodes/update" if existing else "nodes/add", payload, form=True)
        verified = self.find_local_node(marker)
        if (not verified or (existing and verified["ID"] != existing["ID"])
                or any(verified.get(key) != fields[field] for key, field in
                       (("Name", "name"), ("Link", "link"), ("NameMode", "nameMode"),
                        ("Group", "group"), ("DialerProxyName", "dialerProxyName")))
                or set(self.node_tags(verified["ID"])) != set(fields["tags"].split(",") if fields["tags"] else [])):
            raise DeployError("Local node sync could not be verified; retry sync to reconcile it.")
        return verified

    def all_nodes(self):
        nodes = self.request("nodes/get")
        if not isinstance(nodes, list) or any(not isinstance(node, dict) for node in nodes):
            raise DeployError("无法读取 SublinkPro 节点列表。")
        return nodes

    def find_remote_node(self, identity):
        matches = []
        for node in self.all_nodes():
            try:
                if urllib.parse.unquote(urllib.parse.urlsplit(node.get("Link", "")).fragment) == "okp-remote:" + identity:
                    matches.append(node)
            except ValueError:
                pass
        if len(matches) > 1:
            raise DeployError("远端节点所有权标识不唯一。")
        if matches and matches[0].get("SourceID", 0) != 0:
            raise DeployError("手工远端节点的来源发生变化。")
        return matches[0] if matches else None

    def remote_nodes(self, identity, record):
        if record["airport_id"]:
            airport = self.find("[okp:" + identity + "]")
            if not airport or airport["id"] != record["airport_id"]:
                raise DeployError("受管机场不存在或身份不匹配。")
            return [node for node in self.all_nodes() if node.get("SourceID") == airport["id"]]
        node = self.find_remote_node(identity)
        if not node or node["ID"] != record.get("remote_node_id"):
            raise DeployError("受管远端节点不存在或身份不匹配。")
        return [node]

    def relay_node(self, identity, record):
        nodes = self.remote_nodes(identity, record)
        selected = [node for node in nodes if node.get("ID") == record.get("remote_node_id")]
        if len(selected) == 1:
            return selected[0]
        if len(nodes) != 1:
            raise DeployError("中转部署没有唯一的远端节点，请先核验机场节点。")
        return nodes[0]

    def apply_relay(self, identity, record, relay_node, wait=False):
        nodes = self.remote_nodes(identity, record)
        deadline = time.monotonic() + (25 if wait and relay_node else 0)
        while not nodes and time.monotonic() < deadline:
            time.sleep(1)
            nodes = self.remote_nodes(identity, record)
        if not nodes:
            if relay_node:
                raise DeployError("机场节点尚未拉取，无法设置中转；稍后重试同步。")
            return
        name = relay_node["Name"] if relay_node else ""
        all_nodes = self.all_nodes()
        ids = {node["ID"] for node in nodes}
        graph = {node["Name"]: ([name] if name else []) if node["ID"] in ids else
                 ([node["DialerProxyName"]] if node.get("DialerProxyName") else []) for node in all_nodes}
        try:
            tuple(graphlib.TopologicalSorter(graph).static_order())
        except graphlib.CycleError:
            raise DeployError("SublinkPro 链式代理会形成循环。") from None
        if any(node.get("DialerProxyName", "") != name for node in nodes):
            self.request("nodes/batch-update-dialer-proxy", {"ids": sorted(ids), "dialerProxyName": name})
        verified = self.remote_nodes(identity, record)
        if {node["ID"] for node in verified} != ids or any(node.get("DialerProxyName", "") != name for node in verified):
            raise DeployError("SublinkPro 中转设置回读不一致，请重试。")

    def update_node(self, original, **changes):
        fields = {"oldname": original["Name"], "oldlink": original["Link"], "name": original["Name"],
                  "link": original["Link"], "nameMode": original.get("NameMode") or "remark",
                  "group": original.get("Group", ""), "dialerProxyName": original.get("DialerProxyName", ""),
                  "tags": ",".join(self.node_tags(original["ID"]))}
        fields.update(changes)
        self.request("nodes/update", fields, form=True)

    def deletion_candidates(self, identity, record):
        airport = None if is_standalone(record) else self.find("[okp:" + identity + "]")
        node = self.find_local_node("okp-local:" + identity)
        remote = self.find_remote_node(identity) if record.get("remote_node_id") and not record["airport_id"] else None
        for found, key, id_key in ((airport, "airport_id", "id"), (node, "local_node_id", "ID")):
            if found and record[key] is not None and found[id_key] != record[key]:
                raise DeployError("SublinkPro 资源 ID 与受管记录不一致，拒绝删除。")
        if remote and remote["ID"] != record["remote_node_id"]:
            raise DeployError("远端节点 ID 与记录不一致。")
        nodes = self.request("nodes/get")
        if not isinstance(nodes, list) or any(not isinstance(n, dict) for n in nodes):
            raise DeployError("无法核验 SublinkPro 节点依赖。")
        deleting = [n for n in nodes if (airport and n.get("SourceID") == airport["id"])
                    or (node and n.get("ID") == node["ID"]) or (remote and n.get("ID") == remote["ID"])]
        names = {n.get(key) for n in deleting for key in ("Name", "EffectiveName", "LinkName") if n.get(key)}
        ids = {n.get("ID") for n in deleting}
        if any(n.get("ID") not in ids and n.get("DialerProxyName") in names for n in nodes):
            raise DeployError("其他 SublinkPro 节点仍通过链式代理引用此部署，需先解除引用。")
        return airport, node

    def remove_deployment(self, identity, record, on_removed):
        airport, node = self.deletion_candidates(identity, record)
        if node:
            self.request("nodes/delete?" + urllib.parse.urlencode({"id": node["ID"]}), method="DELETE")
        if self.find_local_node("okp-local:" + identity) is not None:
            raise DeployError("本地节点删除后仍存在，可重试删除流程。")
        on_removed(local_node_id=None)
        if airport:
            self.request(f"airports/{airport['id']}?deleteNodes=true", method="DELETE")
        if not is_standalone(record) and self.find("[okp:" + identity + "]") is not None:
            raise DeployError("机场删除后仍存在，可重试删除流程。")
        on_removed(airport_id=None)
        remote = self.find_remote_node(identity) if record.get("remote_node_id") else None
        if remote:
            if remote["ID"] != record["remote_node_id"]:
                raise DeployError("远端节点身份不一致。")
            self.request("nodes/delete?" + urllib.parse.urlencode({"id": remote["ID"]}), method="DELETE")
            if self.find_remote_node(identity) is not None:
                raise DeployError("远端节点删除后仍存在。")
        if "remote_node_id" in record:
            on_removed(remote_node_id=None)

    def find(self, marker):
        data = self.request("airports?" + urllib.parse.urlencode({"keyword": marker}))
        if not isinstance(data, list) or any(not isinstance(airport, dict) for airport in data):
            raise DeployError("Unexpected SublinkPro airport list format.")
        matches = [airport for airport in data if isinstance(airport.get("remark"), str)
                   and marker in airport["remark"].splitlines()]
        if len(matches) > 1:
            raise DeployError("Multiple airports match this installation; resolve the conflict in SublinkPro.")
        if matches:
            self.settings(matches[0])
        return matches[0] if matches else None

    @staticmethod
    def custom_name(value, default, label, interactive):
        display_label = {"Airport name": "机场名称", "Node name": "节点名称"}.get(label, label)
        if value is None:
            try:
                value = (input(f"{display_label} [{default}]: ").strip() or default) if interactive else default
            except EOFError:
                raise DeployError("Name input cancelled. Supply --airport-name and --node-name to sync again.") from None
        if not value.strip() or len(value) > 80 or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise DeployError(f"{label} must contain 1-80 characters without control characters.")
        return value.strip()

    def sync(self, exported, *, airport_name=None, node_name=None, local_port=None, interactive=False, on_input=None,
             registry=None, singbox=None, relay_requested=False):
        if not self.create_local_node and local_port is not None:
            raise DeployError("Local node sync is disabled; omit --local-port or enable --local-node.")
        marker = "[okp:" + exported["INSTALLATION_ID"].lower() + "]"
        airport = self.find(marker)
        fields = self.settings(airport) if airport else copy.deepcopy(AIRPORT_DEFAULTS)
        if airport:
            airport_name = self.custom_name(airport_name, airport["name"], "Airport name", False)
        else:
            airport_name = self.custom_name(airport_name, exported["NODE_NAME"], "Airport name", interactive)
            if on_input:
                on_input(airport_name=airport_name)
            node_name = self.custom_name(node_name, exported["NODE_NAME"], "Node name", interactive)
            fields["remark"] = marker
        if node_name is not None:
            node_name = self.custom_name(node_name, exported["NODE_NAME"], "Node name", False)
            if on_input:
                on_input(name=node_name)
            fields["nodeNamePreprocess"] = json.dumps([
                {"matchMode": "regex", "pattern": ".+", "replacement": node_name.replace("$", "$$"),
                 "enabled": True}
            ], ensure_ascii=False, separators=(",", ":"))
        fields.update(name=airport_name, url=exported["SUBSCRIPTION_URL"],
                      skipTLSVerify=exported.get("SKIP_TLS_VERIFY", exported["MODE"] == "nat"))
        if self.group is not None:
            fields["group"] = self.group
        if on_input:
            on_input(airport_name=airport_name)
        local_marker = "okp-local:" + exported["INSTALLATION_ID"].lower()
        identity = exported["INSTALLATION_ID"].lower()
        relay_id = registry.records[identity]["relay_id"] if registry else None
        relay_node = self.relay_node(relay_id, registry.records[relay_id]) if relay_id else None
        relay_tag = None
        if relay_id and singbox:
            if not registry.records[relay_id]["singbox"]:
                raise DeployError("所选中转尚无 sing-box 出站。")
            singbox.owned(singbox.read()[1], relay_id, registry.records[relay_id]["singbox"], allow_references=True)
            relay_tag = registry.records[relay_id]["singbox"]["outbound_tag"]
        singbox_plan = None
        if self.create_local_node:
            local_name = self.custom_name(self.airport_node_name(fields, exported["NODE_NAME"]),
                                          exported["NODE_NAME"], "Node name", False)
            local_node, local_fields = self.prepare_local_node(local_marker, local_name, local_port, interactive, on_input)
            if singbox:
                if registry is None:
                    raise DeployError("sing-box 同步需要持久资源清单。")
                singbox_plan = singbox.plan(identity, exported["VLESS_URI"], local_fields["link"],
                                           registry.records[identity]["singbox"], name=local_name, relay_tag=relay_tag)
        if registry:
            values = {"airport_name": airport_name}
            if node_name is not None:
                values["node_name"] = node_name
            if self.create_local_node:
                values["local_port"] = urllib.parse.urlsplit(local_fields["link"]).port
            registry.update(identity, **values)
        changed = not airport or any(airport.get(key) != value for key, value in fields.items())
        if changed:
            if airport:
                self.request(f"airports/{airport['id']}", fields, method="PUT")
            else:
                self.request("airports", fields)
        verified = self.find(marker)
        actual = dict(self.settings(verified), name=verified["name"], url=verified["url"]) if verified else {}
        if (not verified or (airport and verified["id"] != airport["id"])
                or any(actual.get(key) != value for key, value in fields.items())):
            raise DeployError("SublinkPro sync could not be verified; run sync again to reconcile it.")
        if registry:
            registry.update(identity, airport_id=verified["id"])
        # Creation of an enabled airport starts a fetch in SublinkPro. Updates do not.
        if airport or not fields["enabled"]:
            self.request(f"airports/{verified['id']}/pull", method="POST")
        if self.create_local_node:
            verified_node = self.sync_local_node(local_marker, local_node, local_fields)
            if registry:
                registry.update(identity, local_node_id=verified_node["ID"])
        if registry and (relay_id or relay_requested):
            self.apply_relay(identity, registry.records[identity], relay_node, wait=True)
        if singbox_plan:
            registry.update(identity, singbox=singbox_plan.metadata)
            registry.update(identity, singbox=singbox.commit(singbox_plan))
        action = "updated" if airport and changed else "already up to date" if airport else "added"
        local_status = "local Shadowsocks node verified" if self.create_local_node else "local node sync disabled"
        if singbox_plan:
            local_status += "; sing-box configuration applied"
        return (f"SublinkPro airport {action}; {local_status}; "
                "subscription fetch queued (completion is asynchronous).")


def run_workflow(args, parser, wizard, checkpoint=None, resume_sync=False):
    if args.action == "edit":
        registry = ManagedDeployments(checkpoint)
        identity = checkpoint.data["installation_id"] or registry.select(args.target)
        if not getattr(args, "env_override", False):
            args.env_file = Path(registry.records[identity]["env_file"])
    config = read_env(args.env_file)
    if wizard and args.action != "edit":
        configure_interactive(args, config, checkpoint)
    if args.action == "edit" or getattr(args, "source", None) == "node":
        run_node_workflow(args, config, checkpoint, wizard)
        return
    if args.password and args.action != "check" and not sys.stdin.isatty():
        parser.error("password login requires an interactive terminal")
    client = None
    if not args.no_sync and (args.action in ("add", "sync") or config.get("SUBLINKPRO_URL")
                             or config.get("SUBLINKPRO_API_KEY")):
        client = SublinkPro(config, create_local_node=args.create_local_node)
    singbox = SingBox(config) if client and client.create_local_node else None
    if args.action == "check":
        if not shutil.which("ssh"):
            raise DeployError("找不到 OpenSSH 客户端。")
        if client:
            client.request("airports")
            if singbox:
                singbox.check()
                print("sing-box 配置校验通过。")
            print("本地 .env、OpenSSH 和 SublinkPro API 认证检查通过。")
        else:
            print("本地 .env 和 OpenSSH 检查通过；未启用 SublinkPro。")
        return
    if client:
        args.create_local_node = client.create_local_node
        configure_resource_names(args, config, checkpoint, sys.stdin.isatty())
    for option, key in ((args.mode, "OKP_MODE"), (args.domain, "OKP_FQDN"), (args.name, "OKP_NODE_NAME")):
        if option is not None:
            if any(ord(char) < 32 or ord(char) == 127 for char in option):
                raise DeployError("Installation overrides cannot contain control characters.")
            config[key] = option
    if getattr(args, "source", None) == "subscription":
        checkpoint.capture(**{key: str(args.env_file) if key == "env_file" else getattr(args, key, None)
                              for key in RESUME_TYPES})
        checkpoint.phase("sync")
        exported = subscription_export(args.subscription_url, client.url, local=client.create_local_node,
                                       insecure=bool(args.insecure_subscription), selected=args.subscription_node,
                                       interactive=sys.stdin.isatty(), prompt=prompt_text, on_input=checkpoint.capture)
        if checkpoint.data["installation_id"] and checkpoint.data["installation_id"] != exported["INSTALLATION_ID"]:
            raise DeployError("订阅地址与恢复记录不同，请使用 --fresh 开始新流程。")
        checkpoint.phase("sync", exported["INSTALLATION_ID"])
        apply_configuration(args, client, singbox, exported, checkpoint,
                            "subscription:" + exported["INSTALLATION_ID"][:12], kind="subscription")
        return
    if not args.target:
        parser.error("install requires an SSH target; add requires an SSH target or subscription URL")
    if not shutil.which("ssh"):
        raise DeployError("OpenSSH client (ssh) is required on this computer.")
    run_install = args.action == "install" and not resume_sync
    if run_install and not sys.stdin.isatty():
        raise DeployError("Run install from an interactive terminal; installation requires confirmation.")
    checkpoint.capture(**{key: str(args.env_file) if key == "env_file" else getattr(args, key, None)
                           for key in RESUME_TYPES})
    checkpoint.phase("install" if run_install else "sync")
    expected_identity = checkpoint.data["installation_id"]
    with tempfile.TemporaryDirectory(prefix="okp-ssh-", dir="/tmp") as socket_dir:
        ssh = SSH(args.target, socket_dir, args.port, args.identity, password_login=args.password)
        try:
            print("正在连接 SSH，请按提示确认主机指纹并完成登录。", flush=True)
            if args.password:
                print("SSH 将在主机验证后提示输入密码，输入不回显。", flush=True)
            ssh.connect()
            if run_install:
                print("Uploading local runtime sources and installation defaults...", flush=True)
                install(ssh, config)
            exported = export_node(ssh)
            if expected_identity and exported["INSTALLATION_ID"].lower() != expected_identity.lower():
                raise DeployError("VPS 安装标识与恢复记录不同。请核实主机，或用 --fresh 开始新流程。")
            checkpoint.phase("sync", exported["INSTALLATION_ID"])
            checkpoint.capture(mode=exported["MODE"])
            if client:
                apply_configuration(args, client, singbox, exported, checkpoint, args.target)
            else:
                print("VPS deployment verified; SublinkPro sync is disabled.")
        finally:
            ssh.close()


def apply_configuration(args, client, singbox, exported, checkpoint, target, *, kind="deployment"):
    registry = ManagedDeployments(checkpoint)
    identity = exported["INSTALLATION_ID"].lower()
    registry.register(identity, target, args.env_file, client.url, exported["NODE_NAME"])
    if kind == "subscription":
        registry.update(identity, kind=kind)
    if args.relay is not None:
        relay_id = registry.select(args.relay) if args.relay else None
        registry.validate_relay(identity, relay_id)
        registry.update(identity, relay_id=relay_id)
        checkpoint.capture(relay=relay_id or "")
    print(client.sync(exported, airport_name=args.airport_name, node_name=args.name, local_port=args.local_port,
                      interactive=sys.stdin.isatty(), on_input=checkpoint.capture,
                      registry=registry, singbox=singbox, relay_requested=args.relay is not None))
    registry.update(identity, status="active")


def node_edit_options(record):
    print(f"\n编辑独立节点：{record['node_name']}\n  1. 修改名称\n  2. 更换远端节点链接"
          "\n  3. 启用 / 修改本地节点\n  4. 关闭本地节点\n  5. 修改本地出站链接\n  0. 返回")
    while True:
        choice = prompt_text("请选择", "0")
        if choice == "0":
            return None
        if choice == "1":
            return {"name": prompt_text("节点名称", record["node_name"], required=True)}
        if choice == "2":
            return {"node_link": prompt_text("新的远端节点链接", required=True)}
        if choice == "3":
            value = prompt_text("本地 Shadowsocks 端口", str(record["local_port"]) if record["local_port"] else None, required=True)
            return {"create_local_node": True, "local_port": SublinkPro.local_port(value)}
        if choice == "4":
            return {"create_local_node": False}
        if choice == "5":
            mode = prompt_text("本地出站（1=跟随远端节点，2=独立链接）", "2" if record["local_source"] == "custom" else "1")
            if mode == "1":
                return {"create_local_node": True, "same_local": True, "local_link": None}
            if mode == "2":
                return {"create_local_node": True, "same_local": False,
                        "local_link": prompt_text("本地出站链接", required=True)}


def run_node_workflow(args, config, checkpoint, wizard):
    if args.no_sync or args.airport_name is not None or args.subscription_url or args.password or args.identity or args.port:
        raise DeployError("独立节点不使用机场名称、订阅地址或 SSH 参数。")
    interactive = sys.stdin.isatty()
    registry = ManagedDeployments(checkpoint)
    client = SublinkPro(config, create_local_node=False)
    manager = NodeManager(client, registry)

    def remember(**values):
        vars(args).update(values)
        checkpoint.capture(**values)

    identity = checkpoint.data["installation_id"]
    if args.action == "edit":
        identity = identity or registry.select(args.target)
        if not is_standalone(registry.records[identity]):
            raise DeployError("edit 用于独立节点；机场通过添加配置更新。")
    record = registry.records.get(identity) if identity else None
    journal = manager.pending(identity) if record else None
    if journal:
        intent = journal.get("intent", {})
        changed = [key for key in getattr(args, "supplied_fields", set()) & intent.keys()
                   if key not in ("action", "target", "env_file", "source") and getattr(args, key, None) != intent[key]]
        if changed:
            checkpoint.capture(**intent)
            raise DeployError("此节点有未完成事务；请先用 --resume 完成原操作，再提交新参数。")
        if journal["box"]:
            manager.box = SingBox(config)
        checkpoint.phase("sync", identity)
        print("继续上次未完成的节点变更。")
        manager.apply(journal)
        print("独立节点配置已完成。")
        return
    if args.action == "edit" and not record:
        raise DeployError("未找到要编辑的配置。")
    edit_keys = ("name", "node_link", "local_port", "create_local_node", "local_link", "same_local", "relay")
    if args.action == "edit" and (wizard or not any(getattr(args, key, None) is not None for key in edit_keys)):
        if not interactive:
            raise DeployError("请提供要编辑的名称、链接、本地节点或中转参数。")
        changes = node_edit_options(record)
        if changes is None:
            return
        remember(**changes)
    source = parse_node_link(args.node_link) if args.node_link else None
    if args.action == "add" and not record:
        if source is None:
            raise DeployError("请提供 --node-link 或从菜单输入单条节点链接。")
        try:
            found_id, _ = manager.resolve(source, args.adopt_node)
        except DeployError:
            matches = manager.matching_nodes(source)
            if (not interactive or args.adopt_node or len(matches) != 1 or matches[0].get("SourceID", 0) != 0
                    or manager.marker(matches[0]).startswith("okp-")):
                raise
            if not prompt_yes_no(f"连接已存在于未受管节点 ID {matches[0]['ID']}，是否接管", False):
                raise DeployError("未接管已有节点。") from None
            remember(adopt_node=matches[0]["ID"])
            found_id, _ = manager.resolve(source, args.adopt_node)
        if found_id:
            identity = found_id
            record = registry.records[identity]
            print(f"此连接已受管，将更新现有配置：{record['node_name']}")
        else:
            identity = identity or uuid.uuid4().hex
        checkpoint.phase("input", identity)
    if record and record["status"] not in ("active", "syncing"):
        raise DeployError("此配置的其他操作尚未完成，请先恢复原操作。")
    if args.name is None and not record:
        default = source.name if source and not source.name.startswith("okp-") and len(source.name) <= 80 else None
        if not interactive and not default:
            raise DeployError("链接没有备注名称，请提供 --node-name。")
        value = prompt_text("节点名称", default, required=True) if interactive else default
        remember(name=client.custom_name(value, "", "节点名称", False))
    elif args.name is not None:
        remember(name=client.custom_name(args.name, "", "节点名称", False))
    enabled = bool(record and (record["singbox"] or record["local_node_id"]))
    if args.local_port is not None or args.local_link is not None or args.same_local:
        remember(create_local_node=True)
    if args.create_local_node is None and not record:
        remember(create_local_node=prompt_yes_no("是否启用本地节点（sing-box + SublinkPro）", local_node_default(config))
                 if interactive else local_node_default(config))
    if args.action == "edit" and args.create_local_node is False:
        local_action = "disable"
        if enabled:
            if not interactive:
                raise DeployError("关闭并删除本地配置需要交互终端确认。")
            print(f"将删除本地 SS 节点 {record['local_node_id'] or '-'} 及其 sing-box 入站、出站和路由；保留远端节点。")
            if not prompt_yes_no("确认关闭本地节点", False):
                raise DeployError("已取消关闭本地节点。")
    else:
        local_action = "enable" if args.create_local_node is True or (args.create_local_node is None and enabled) else "keep"
    if local_action == "enable":
        manager.box = SingBox(config)
        if args.local_port is None:
            remember(local_port=client.local_port(None, record["local_port"] if record else None, interactive))
        if not record and interactive and args.local_link is None and args.same_local is None:
            while True:
                choice = prompt_text("本地出站（1=跟随远端节点，2=独立链接）", "1")
                if choice in ("1", "2"):
                    remember(same_local=choice == "1")
                    if choice == "2":
                        remember(local_link=prompt_text("本地出站链接", required=True))
                    break
    elif local_action == "disable" and record["singbox"]:
        manager.box = SingBox(config)
    if args.relay is None and not record:
        choices = [(key, r) for key, r in registry.records.items()
                   if key != identity and r["status"] == "active" and r["sublink_url"] == client.url]
        if interactive and choices and prompt_yes_no("此节点是否需要中转", False):
            for index, (_, r) in enumerate(choices, 1):
                print(f"  {index}. {r['node_name']}")
            while True:
                value = prompt_text("选择中转节点", required=True)
                if value.isdigit() and 1 <= int(value) <= len(choices):
                    remember(relay=choices[int(value) - 1][0])
                    break
        else:
            remember(relay="")
    relay_id = record["relay_id"] if record and args.relay is None else registry.select(args.relay) if args.relay else None
    if not record:
        registry.register(identity, "node:" + identity, args.env_file, client.url, args.name)
        registry.update(identity, kind="adopted" if args.adopt_node else "node", airport_name="",
                        remote_node_id=args.adopt_node)
    if args.local_link is not None:
        parse_node_link(args.local_link).outbound()
    checkpoint.capture(**{key: str(args.env_file) if key == "env_file" else getattr(args, key, None) for key in RESUME_TYPES})
    checkpoint.phase("sync", identity)
    journal = manager.prepare(identity, link=args.node_link, name=args.name, local_action=local_action,
                              local_port=args.local_port if local_action == "enable" else None,
                              local_link=args.local_link, same_local=bool(args.same_local), relay_id=relay_id,
                              adopt_id=args.adopt_node, intent=copy.deepcopy(checkpoint.data["options"]))
    record = manager.apply(journal)
    print(f"独立节点已配置：{record['node_name']}；本地端口：{record['local_port'] or '未启用'}。")


def manage_deployments(args, env_override=False):
    if args.no_sync or args.create_local_node is not None or args.local_port is not None:
        raise DeployError("list/remove 不接受同步开关；删除范围由受管资源清单确定。")
    checkpoint = ResumeState()
    if args.action == "list":
        if args.interactive:
            view_configurations(args, env_override)
            return
        registry = ManagedDeployments(checkpoint)
        if not registry.records:
            print("暂无受管配置；安装或添加成功后会保留资源清单。")
        for identity, record in registry.records.items():
            relay = registry.records[record["relay_id"]]["node_name"] if record["relay_id"] else "直连"
            kind = "独立节点" if is_standalone(record) else "机场订阅"
            print(f"{identity}  {configuration_label(record)}  [{kind}, {record['status']}]  中转: {relay}")
        return
    if not sys.stdin.isatty():
        raise DeployError("删除操作需要交互终端，以确认要删除的部署。")
    with checkpoint.locked():
        registry = ManagedDeployments(checkpoint)
        if not registry.records:
            print("暂无可删除的受管部署。")
            return
        if args.target:
            identity = registry.select(args.target)
        else:
            identities = list(registry.records)
            for index, key in enumerate(identities, 1):
                record = registry.records[key]
                print(f"  {index}. {configuration_label(record)} / {record['target']} [{record['status']}]")
            while True:
                value = prompt_text("选择要删除的部署（0 退出）", "0")
                if value == "0":
                    return
                if value.isdigit() and 1 <= int(value) <= len(identities):
                    identity = identities[int(value) - 1]
                    break
        record = registry.records[identity]
        if record["status"] in ("adopting", "updating"):
            raise DeployError("接管或节点编辑尚未完成，请先恢复原事务。")
        if registry.dependents(identity):
            raise DeployError("其他受管节点仍通过此节点中转：" + "、".join(registry.dependents(identity)))
        config = read_env(args.env_file if env_override else Path(record["env_file"]))
        client = SublinkPro(config, create_local_node=False)
        if client.url != record["sublink_url"]:
            raise DeployError("SublinkPro 地址与受管记录不同，拒绝删除。")
        if is_standalone(record) and NodeManager(client, registry).pending(identity):
            raise DeployError("此节点有未完成变更，请先进入该配置继续节点变更。")
        singbox = SingBox(config) if record["singbox"] else None
        plan = singbox.plan(identity, metadata=record["singbox"], remove=True) if singbox else None
        airport, node = client.deletion_candidates(identity, record)
        print(f"配置：{configuration_label(record)} / {record['target']}")
        if not is_standalone(record):
            print(f"将清理机场及其导入节点：{airport['id'] if airport else '已不存在'}")
        print(f"本地 SS 节点：{node['ID'] if node else '未创建或已不存在'}")
        if record["remote_node_id"] and not record["airport_id"]:
            print(f"将清理已接管的手工远端节点：{record['remote_node_id']}")
        if plan:
            print(f"sing-box：{plan.metadata['inbound_tag']} -> {plan.metadata['outbound_tag']}")
        if record["status"] != "deleting" and not prompt_yes_no("确认删除上述受管资源", False):
            return
        registry.update(identity, status="deleting")
        if plan:
            registry.update(identity, singbox=plan.metadata)
            registry.update(identity, singbox=singbox.commit(plan))
        client.remove_deployment(identity, record, lambda **values: registry.update(identity, **values))
        registry.forget(identity)
        pending = checkpoint.load()
        if pending and pending["installation_id"] and pending["installation_id"].lower() == identity:
            checkpoint.complete()
        print("已删除对应的 sing-box 和 SublinkPro 资源；未连接或卸载 VPS。")


def view_configurations(args, env_override=False):
    while True:
        registry = ManagedDeployments(ResumeState())
        entries = list(registry.records)
        if not entries:
            print("暂无受管配置。")
            return
        for index, key in enumerate(entries, 1):
            record = registry.records[key]
            relay = registry.records[record["relay_id"]]["node_name"] if record["relay_id"] else "否"
            kind = "独立节点" if is_standalone(record) else "机场订阅"
            print(f"  {index}. {configuration_label(record)} [{kind}, {record['status']}]  中转：{relay}")
        value = prompt_text("选择配置（0 返回）", "0")
        if value == "0":
            return
        if not value.isdigit() or not 1 <= int(value) <= len(entries):
            continue
        identity = entries[int(value) - 1]
        while True:
            registry = ManagedDeployments(ResumeState())
            record = registry.records.get(identity)
            if not record:
                break
            relay = registry.records[record["relay_id"]]["node_name"] if record["relay_id"] else "否（直连）"
            kind = "独立节点" if is_standalone(record) else "机场订阅"
            print(f"\n类型：{kind}")
            if not is_standalone(record):
                print(f"机场：{record['airport_name']}\nSublinkPro 机场 ID：{record['airport_id'] or '-'}")
            print(f"节点：{record['node_name']}\n状态：{record['status']}"
                  f"\n来源：{record['target']}\n管理 ID：{identity}"
                  f"\nSublinkPro 远端节点 ID：{record['remote_node_id'] or '-'}"
                  f"\nSublinkPro 本地节点 ID：{record['local_node_id'] or '-'}"
                  f"\n本地节点：{'启用' if record['local_node_id'] or record['singbox'] else '未启用'}"
                  f"\n本地端口：{record['local_port'] or '-'}\n是否中转：{relay}")
            if record["singbox"]:
                print(f"sing-box：{record['singbox']['inbound_tag']} -> {record['singbox']['outbound_tag']}")
                print("本地出站：" + ("独立配置" if record["local_source"] == "custom" else "跟随远端节点"))
            print("  1. 中转设置\n  2. 删除此配置")
            if is_standalone(record):
                print("  3. 继续节点变更" if record["status"] == "updating" else "  3. 编辑此节点")
            print("  0. 返回")
            value = prompt_text("请选择", "0")
            if value == "0":
                break
            selected = argparse.Namespace(**(vars(args) | {"target": identity, "relay": None}))
            if value == "1":
                manage_relay(selected, env_override)
            elif value == "2":
                selected.action = "remove"
                manage_deployments(selected, env_override)
            elif value == "3" and is_standalone(record):
                options = ["edit", identity]
                if env_override:
                    options += ["--env-file", str(args.env_file)]
                main(options)


def manage_relay(args, env_override=False):
    checkpoint = ResumeState()
    with checkpoint.locked():
        registry = ManagedDeployments(checkpoint)
        if not registry.records:
            raise DeployError("暂无受管节点。")
        entries = list(registry.records)
        if args.target:
            identity = registry.select(args.target)
        else:
            if not sys.stdin.isatty():
                raise DeployError("请指定要配置的节点。")
            for index, key in enumerate(entries, 1):
                print(f"  {index}. {registry.records[key]['node_name']}")
            while True:
                choice = prompt_text("选择需要配置的节点", required=True)
                if choice.isdigit() and 1 <= int(choice) <= len(entries):
                    identity = entries[int(choice) - 1]
                    break
        record = registry.records[identity]
        if record["status"] not in ("active", "relaying"):
            raise DeployError("请先完成该节点的安装、同步、接管或删除流程。")
        if args.relay is None and record["status"] == "relaying":
            relay_id = record["relay_id"]
            print("继续上次未完成的中转设置。")
        elif args.relay is None:
            if not sys.stdin.isatty():
                raise DeployError("请使用 --via 指定中转，或 --direct 取消中转。")
            if prompt_yes_no("此节点是否需要中转", record["relay_id"] is not None):
                candidates = [key for key in entries if key != identity and registry.records[key]["status"] == "active"]
                if not candidates:
                    raise DeployError("没有可用的其他中转节点。")
                for index, key in enumerate(candidates, 1):
                    print(f"  {index}. {registry.records[key]['node_name']}")
                while True:
                    choice = prompt_text("选择中转节点", required=True)
                    if choice.isdigit() and 1 <= int(choice) <= len(candidates):
                        relay_id = candidates[int(choice) - 1]
                        break
            else:
                relay_id = None
        else:
            relay_id = registry.select(args.relay) if args.relay else None
        registry.validate_relay(identity, relay_id)
        config = read_env(args.env_file if env_override else Path(record["env_file"]))
        client = SublinkPro(config, create_local_node=False)
        if client.url != record["sublink_url"]:
            raise DeployError("SublinkPro 实例与记录不匹配。")
        if is_standalone(record) and NodeManager(client, registry).pending(identity):
            raise DeployError("此节点有未完成变更，请先继续原操作。")
        parent = registry.records[relay_id] if relay_id else None
        relay_node = client.relay_node(relay_id, parent) if parent else None
        box = SingBox(config) if record["singbox"] else None
        if box and parent and not parent["singbox"]:
            raise DeployError("中转节点没有 sing-box 出站。")
        if box and parent:
            box.owned(box.read()[1], relay_id, parent["singbox"], allow_references=True)
        tag = parent["singbox"]["outbound_tag"] if box and parent else None
        plan = box.plan_relay(identity, record["singbox"], tag) if box else None
        registry.update(identity, relay_id=relay_id, status="relaying")
        client.apply_relay(identity, record, relay_node)
        if plan:
            registry.update(identity, singbox=plan.metadata)
            registry.update(identity, singbox=box.commit(plan))
        registry.update(identity, status="active")
        print(f"{record['node_name']}：" + (f"经由 {parent['node_name']} 中转" if parent else "直连"))


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(description=__doc__, argument_default=argparse.SUPPRESS)
    parser.add_argument("action", nargs="?", choices=("install", "add", "sync", "edit", "check", "list", "remove", "relay", "adopt"), default=None)
    parser.add_argument("target", nargs="?", help="SSH target, subscription URL for add, or managed ID/name", default=None)
    parser.add_argument("--subscription-url", help="add a subscription without SSH")
    node_input = parser.add_mutually_exclusive_group()
    node_input.add_argument("--node-link", help="standalone VLESS, Shadowsocks or SOCKS5 link")
    node_input.add_argument("--node-file", type=Path, help="read a node link from a private 0600 file")
    local_input = parser.add_mutually_exclusive_group()
    local_input.add_argument("--local-link", help="independent local outbound link")
    local_input.add_argument("--same-local", action="store_true", help="make the local outbound follow the remote node")
    parser.add_argument("--adopt-node", type=int, help="explicitly adopt an existing manual SublinkPro node ID")
    parser.add_argument("--subscription-node", help="local outbound selection: 1-based node index or saved fingerprint")
    parser.add_argument("--insecure-subscription", action="store_true", help="allow a self-signed subscription certificate")
    parser.add_argument("--env-file", type=Path)
    parser.add_argument("--port", type=int, help="SSH port")
    auth_group = parser.add_mutually_exclusive_group()
    auth_group.add_argument("--identity", help="SSH private key file")
    auth_group.add_argument("--password", action="store_true",
                            help="prompt for the host password in the terminal (no password value argument)")
    parser.add_argument("--mode", choices=("public", "nat"))
    parser.add_argument("--domain", help="override OKP_FQDN for this installation")
    parser.add_argument("--airport-name", help="SublinkPro airport name; prompted before deployment on first import")
    parser.add_argument("--node-name", "--name", dest="name",
                        help="node name for the installer and airport node renaming rule")
    parser.add_argument("--local-port", type=int, help="Surge device's local Shadowsocks port (1-65535)")
    local_group = parser.add_mutually_exclusive_group()
    local_group.add_argument("--local-node", dest="create_local_node", action="store_true",
                             help="configure the local node in both sing-box and SublinkPro")
    local_group.add_argument("--no-local-node", dest="create_local_node", action="store_false",
                             help="add: keep existing local resources; edit: remove local resources after confirmation")
    parser.add_argument("--interactive", action="store_true", help="prompt for deployment options")
    parser.add_argument("--no-sync", action="store_true", help="install without SublinkPro sync")
    relay_group = parser.add_mutually_exclusive_group()
    relay_group.add_argument("--via", "--relay", dest="relay", help="use another managed node as relay")
    relay_group.add_argument("--direct", dest="relay", action="store_const", const="", help="disable relay")
    resume_group = parser.add_mutually_exclusive_group()
    resume_group.add_argument("--resume", action="store_true", help="continue the saved unfinished workflow")
    resume_group.add_argument("--fresh", action="store_true", help="start a new workflow, replacing saved input")
    supplied = {key: value for key, value in vars(parser.parse_args(argv)).items() if value is not None}
    if "node_file" in supplied:
        fd = ResumeState.open_private(supplied.pop("node_file").expanduser(), os.O_RDONLY)
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            supplied["node_link"] = stream.read(4097).strip()
        parse_node_link(supplied["node_link"])
    if supplied.get("action") == "sync":
        supplied["action"] = "add"
    if (supplied.get("action") == "add" and "://" in supplied.get("target", "")
            and not supplied["target"].startswith(("https://", "http://"))):
        if "node_link" in supplied:
            parser.error("supply the node link only once")
        supplied["node_link"] = supplied.pop("target")
    if supplied.get("action") == "add" and supplied.get("target", "").startswith(("https://", "http://")):
        if "subscription_url" in supplied:
            parser.error("supply the subscription URL only once")
        supplied["subscription_url"] = supplied.pop("target")
    if "subscription_url" in supplied:
        if "node_link" in supplied:
            parser.error("node links and subscription URLs are different sources")
        if supplied.get("action") not in (None, "add") or supplied.get("target"):
            parser.error("--subscription-url is for add and cannot be combined with an SSH target")
        supplied["source"] = "subscription"
        if not supplied.get("resume"):
            supplied["action"] = "add"
    if "node_link" in supplied or supplied.get("action") == "edit":
        if supplied.get("action") not in (None, "add", "edit") or (supplied.get("target") and supplied.get("action") != "edit"):
            parser.error("node links are for add/edit and cannot use an SSH target")
        supplied["source"] = "node"
        if supplied.get("action") is None and not supplied.get("resume"):
            supplied["action"] = "add"
    defaults = dict(action=None, target=None, env_file=ROOT / ".env", port=None, identity=None, password=False,
                    mode=None, domain=None, airport_name=None, name=None, local_port=None, create_local_node=None,
                    interactive=False, no_sync=False, resume=False, fresh=False, auth_method=None, relay=None,
                    source=None, subscription_url=None, insecure_subscription=None, subscription_node=None,
                    node_link=None, local_link=None, same_local=None, adopt_node=None)
    args = argparse.Namespace(**(defaults | supplied))
    args.supplied_fields = set(supplied)
    args.env_override = "env_file" in supplied
    wizard = args.interactive or (args.action is None and not args.resume) or (
        args.action in ("install", "add") and not args.target and not args.subscription_url and not args.node_link and not args.resume)
    if wizard and not sys.stdin.isatty():
        parser.error("interactive mode requires a terminal; supply an action and SSH target")
    if supplied.get("local_port") is not None and supplied.get("create_local_node") is False:
        parser.error("--local-port cannot be used with --no-local-node")
    if supplied.get("create_local_node") is False and (args.local_link is not None or args.same_local):
        parser.error("local outbound options require local nodes")
    if args.action == "edit" and not args.target and not args.resume:
        parser.error("edit requires a managed configuration ID or name")
    if args.action is None and not args.resume:
        while True:
            action = choose_action()
            if action is None:
                return
            try:
                main([action] + argv + ([] if "--interactive" in argv else ["--interactive"]))
            except (DeployError, OSError, UnicodeError) as error:
                print(str(error) if isinstance(error, DeployError) else "本地文件或进程操作失败。", file=sys.stderr)
            except KeyboardInterrupt:
                print("已返回主菜单；未完成的流程仍可继续。", file=sys.stderr)
    if args.action == "adopt":
        if not args.target or args.resume or args.fresh:
            parser.error("adopt requires a manifest path")
        from deploy_adopt import adopt_manifest
        adopt_manifest(read_env(args.env_file), Path(args.env_file).expanduser().absolute(), Path(args.target), ResumeState())
        return
    if args.action == "relay":
        if args.resume or args.fresh:
            parser.error("repeat relay directly to retry")
        manage_relay(args, "env_file" in supplied)
        return
    if args.action in ("list", "remove"):
        if args.resume or args.fresh:
            parser.error("repeat list/remove directly instead of --resume/--fresh")
        manage_deployments(args, "env_file" in supplied)
        return
    if args.action == "check":
        if args.resume or args.fresh:
            parser.error("check cannot be combined with --resume or --fresh")
        if args.local_port is not None:
            SublinkPro.local_port(args.local_port)
            args.create_local_node = True
        run_workflow(args, parser, False)
        return
    checkpoint = ResumeState()
    with checkpoint.locked():
        pending = None if args.fresh else checkpoint.load()
        if pending and wizard and not args.resume:
            choice = choose_pending(pending)
            if choice == "0":
                return
            if choice == "2":
                args.fresh = True
                pending = None
            else:
                args.action = None
                supplied.pop("action", None)
        if args.resume and not pending:
            raise DeployError("没有未完成的流程可恢复。")
        if pending and not args.fresh:
            previous = pending["options"]
            same_target = args.target is None or previous.get("target") is None or args.target == previous["target"]
            previous_action = "add" if previous["action"] == "sync" else previous["action"]
            same_action = args.action is None or args.action == previous_action or (
                pending["phase"] == "sync" and "edit" not in (args.action, previous_action))
            same_env = "env_file" not in supplied or str(args.env_file.expanduser().absolute()) == previous["env_file"]
            same_source = "source" not in supplied or previous.get("source", "ssh") in (None, supplied["source"])
            same_url = "subscription_url" not in supplied or supplied["subscription_url"] == previous.get("subscription_url")
            if not (same_target and same_action and same_env and same_source and same_url):
                raise DeployError("已有另一项未完成流程。使用 --resume 继续，或 --fresh 开始新流程。")
            args.resume = True
            merged = previous | {key: value for key, value in supplied.items() if key in RESUME_TYPES}
        else:
            merged = {key: value for key, value in supplied.items() if key in RESUME_TYPES}
        if "identity" in supplied:
            merged.update(password=False, auth_method="key")
        if "password" in supplied:
            merged.update(identity=None, auth_method="password")
        if supplied.get("create_local_node") is False:
            merged["local_port"] = None
            merged["local_link"] = None
            merged["same_local"] = None
        if supplied.get("same_local"):
            merged["local_link"] = None
        if "local_link" in supplied:
            merged["same_local"] = False
        if "local_port" in supplied:
            merged["create_local_node"] = True
        vars(args).update(merged)
        if args.action == "sync":
            args.action = "add"
        args.env_file = Path(args.env_file).expanduser().absolute()
        if args.action not in ("install", "add", "edit"):
            parser.error("install, add or edit is required")
        if args.action in ("add", "edit") and args.no_sync:
            parser.error("--no-sync cannot be used with add/edit")
        if args.source in ("subscription", "node") and (args.port or args.identity or args.password or (args.target and args.action != "edit")):
            parser.error("subscription and standalone-node operations cannot use SSH options")
        if args.source != "node" and (args.node_link or args.local_link or args.same_local or args.adopt_node):
            parser.error("node link options require a standalone node source")
        if args.adopt_node is not None and (args.adopt_node <= 0 or args.action != "add"):
            parser.error("--adopt-node requires add and a positive node ID")
        if args.subscription_url:
            validate_url(args.subscription_url)
        if args.port is not None and not 1 <= args.port <= 65535:
            parser.error("SSH port must be between 1 and 65535")
        if args.local_port is not None:
            SublinkPro.local_port(args.local_port)
        resume_sync = bool(args.resume and pending["phase"] == "sync" and pending["installation_id"])
        if not args.resume:
            checkpoint.start(args.action, args.env_file)
        checkpoint.capture(**(merged | {"action": args.action, "env_file": str(args.env_file)}))
        if args.resume:
            print("已恢复上次填写的信息。", flush=True)
            wizard = wizard or (sys.stdin.isatty() and pending["phase"] == "input")
        try:
            run_workflow(args, parser, wizard, checkpoint, resume_sync)
        except (Exception, KeyboardInterrupt):
            print("流程未完成，已保留输入；运行 python3 deploy.py --resume 可继续。", file=sys.stderr)
            raise
        checkpoint.complete()


if __name__ == "__main__":
    try:
        main()
    except (DeployError, OSError, UnicodeError) as error:
        # Unexpected OS errors may contain sensitive paths; only our errors are rendered.
        print("Error: " + (str(error) if isinstance(error, DeployError)
                           else "Local file or process operation failed."), file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("已取消。运行 python3 deploy.py --resume 可继续未完成的流程。", file=sys.stderr)
        sys.exit(130)
