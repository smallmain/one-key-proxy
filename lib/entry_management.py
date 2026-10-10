"""Independent management of an existing 3x-ui entry, without installer state."""

import contextlib
import fcntl
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import re
import ssl
import socket
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

if 'okp_panel_version' not in sys.modules:
    _spec = importlib.util.spec_from_file_location('okp_panel_version', Path(__file__).with_name('panel_version.py'))
    _policy = importlib.util.module_from_spec(_spec)
    sys.modules[_spec.name] = _policy
    _spec.loader.exec_module(_policy)
from okp_panel_version import MIN_PANEL_VERSION, VersionRequired, detected_version, require_version

RUNTIME = Path('/usr/local/lib/one-key-proxy-relay')
STATE = Path('/etc/one-key-proxy-relay')


class EntryError(Exception):
    pass


class EntryVersionRequired(EntryError):
    def __init__(self, current):
        self.current = current
        super().__init__(f'当前 3x-ui {current}；最低支持版本为 {MIN_PANEL_VERSION}，且需使用相同 major。')


def panel_url(value):
    try:
        url = urllib.parse.urlsplit(value)
        if (url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password
                or url.query or url.fragment or any(ord(c) <= 32 or ord(c) == 127 for c in value)
                or (url.scheme == 'http' and url.hostname not in ('127.0.0.1', '::1', 'localhost'))
                or (url.port is not None and not 1 <= url.port <= 65535)):
            raise ValueError
        path = url.path.rstrip('/')
        if path.endswith('/panel'):
            path = path[:-6]
        if any(part in ('.', '..') for part in path.split('/')):
            raise ValueError
        return url._replace(path=path).geturl()
    except (TypeError, ValueError):
        raise EntryError('面板地址无效；HTTP 仅允许服务器本机地址，公网地址请使用 HTTPS。') from None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class LoopbackHTTPSConnection(http.client.HTTPSConnection):
    def connect(self):
        self.sock = socket.create_connection(('::1' if self.host == '::1' else '127.0.0.1', self.port), self.timeout)
        self.sock = self._context.wrap_socket(self.sock, server_hostname=self.host)


class LoopbackHTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(LoopbackHTTPSConnection, req, context=self._context)


class Panel:
    def __init__(self, url, token, *, loopback=True):
        self.url = panel_url(url)
        if not isinstance(token, str) or not re.fullmatch(r'[A-Za-z0-9_.-]{16,4096}', token):
            raise EntryError('管理 API Token 格式无效。')
        self.token = token
        handler = LoopbackHTTPSHandler if loopback else urllib.request.HTTPSHandler
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(),
                                                  handler(context=ssl.create_default_context()))

    def __call__(self, method, path, fields=None, *, form=False):
        if method not in ('GET', 'POST') or not re.fullmatch(r'/panel/api/[A-Za-z0-9_./-]+', path) or '..' in path:
            raise EntryError('管理 API 请求路径无效。')
        body = None if method == 'GET' else (urllib.parse.urlencode(fields or {}).encode() if form else json.dumps(fields or {}).encode())
        headers = {'Authorization': 'Bearer ' + self.token, 'Accept': 'application/json',
                   'Content-Type': 'application/x-www-form-urlencoded' if form else 'application/json'}
        request = urllib.request.Request(self.url + path, data=body, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=40) as response:
                raw = response.read(8 * 1024 * 1024 + 1)
                if len(raw) > 8 * 1024 * 1024:
                    raise ValueError
                result = json.loads(raw)
            if not isinstance(result, dict) or result.get('success') is not True:
                raise ValueError
            return result.get('obj')
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                raise EntryError('3x-ui API 认证失败或权限不足，请使用管理员 API Token。') from None
            raise EntryError('3x-ui API 请求失败；未回显面板响应或凭据。') from None
        except (ValueError, OSError, urllib.error.URLError):
            raise EntryError('无法连接或验证 3x-ui API；请检查面板地址、证书和 API Token。') from None


def secure_directory(path, *, mode=0o700):
    if not path.exists() and not path.is_symlink():
        path.mkdir(mode=mode)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o022:
        raise EntryError('管理目录不是当前用户拥有的安全目录。')
    if mode == 0o700 and stat.S_IMODE(info.st_mode) != mode:
        raise EntryError('管理状态目录权限必须为 0700。')


def private_read(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'r', encoding='utf-8') as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 8 * 1024 * 1024):
            raise EntryError('管理文件必须是权限为 0600 的安全普通文件。')
        return json.load(stream)


def write(path, value, *, source=False):
    if path.exists() or path.is_symlink():
        if source:
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o022:
                raise EntryError('管理运行文件不安全，拒绝覆盖。')
        else:
            private_read(path)
    fd, temporary = tempfile.mkstemp(prefix='.entry-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(value if source else json.dumps(value, ensure_ascii=False))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextlib.contextmanager
def locked(directory):
    secure_directory(directory)
    fd = os.open(directory / 'lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600:
            raise EntryError('管理锁文件不安全。')
        deadline = time.monotonic() + 20
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise EntryError('服务器有其他管理操作占用锁，请稍后继续。') from None
                time.sleep(.2)
        yield
    finally:
        os.close(fd)


def object_value(value):
    value = json.loads(value) if isinstance(value, str) else value
    if not isinstance(value, dict):
        raise EntryError('3x-ui 返回了无效的配置结构。')
    return value


def discover(panel, link, previous=None):
    status = panel('GET', '/panel/api/server/status')
    try:
        version = detected_version(status.get('panelVersion') if isinstance(status, dict) else None)
        require_version(version)
    except VersionRequired as error:
        raise EntryVersionRequired(error.current) from None
    except ValueError as error:
        raise EntryError(str(error)) from None
    if status.get('xray', {}).get('state') != 'running' or status.get('xray', {}).get('errorMsg'):
        raise EntryError('入口 Xray 未处于健康运行状态。')
    if not isinstance(panel('GET', '/panel/api/setting/apiTokens'), list):
        raise EntryError('管理 API Token 权限无法确认。')
    uri = urllib.parse.urlsplit(link)
    query = dict(urllib.parse.parse_qsl(uri.query))
    if uri.scheme != 'vless' or query.get('security') != 'reality' or query.get('flow') != 'xtls-rprx-vision':
        raise EntryError('远程中转入口需要 VLESS REALITY Vision 节点。')
    client_id = str(uuid.UUID(uri.username))
    inbounds = panel('GET', '/panel/api/inbounds/list')
    if not isinstance(inbounds, list):
        raise EntryError('无法读取入口入站列表。')
    found = []
    for inbound in inbounds:
        settings = object_value(inbound.get('settings', {}))
        clients = [c for c in settings.get('clients', []) if c.get('id') == client_id]
        if not clients:
            continue
        stream = object_value(inbound.get('streamSettings', {}))
        reality = stream.get('realitySettings', {})
        if (len(clients) != 1 or clients[0].get('enable') is not True or clients[0].get('flow', '') != 'xtls-rprx-vision'
                or inbound.get('enable') is not True or inbound.get('protocol') != 'vless'
                or stream.get('network') not in ('tcp', 'raw') or stream.get('security') != 'reality'
                or reality.get('settings', {}).get('publicKey') != query.get('pbk')
                or query.get('sni') not in reality.get('serverNames', []) or query.get('sid', '') not in reality.get('shortIds', [])):
            raise EntryError('入口节点与面板中的 UUID 或 REALITY 参数不匹配。')
        if type(inbound.get('id')) is not int or not inbound.get('tag') or type(inbound.get('port')) is not int:
            raise EntryError('入口入站缺少稳定的 ID、tag 或端口。')
        found.append((inbound, stream))
    if len(found) != 1:
        raise EntryError('未找到唯一匹配的入口客户端；未修改服务器配置。')
    inbound, stream = found[0]
    shared = {'protocol': inbound['protocol'], 'port': inbound['port'], 'listen': inbound.get('listen'), 'streamSettings': stream}
    shared_hash = hashlib.sha256(json.dumps(shared, sort_keys=True).encode()).hexdigest()
    if previous and (previous['inbound_id'] != inbound['id'] or previous['inbound_tag'] != inbound['tag']
                     or previous['entry_hash'] != shared_hash):
        raise EntryError('已关联的入口入站身份或连接参数发生变化，拒绝重新绑定。')
    template = object_value(panel('POST', '/panel/api/xray/'))
    template = object_value(template['xraySetting'])
    if not template.get('outbounds') or not isinstance(template.get('routing', {}).get('rules'), list):
        raise EntryError('现有 Xray 模板不支持远程中转。')
    if not any(o.get('protocol') == 'blackhole' and o.get('tag') for o in template['outbounds']):
        raise EntryError('现有 Xray 模板缺少 blackhole 出站，无法保护创建中的中转账号。')
    return {'version': version, 'inbound_id': inbound['id'], 'inbound_tag': inbound['tag'],
            'inbound_port': inbound['port'], 'vless_uri': link, 'entry_hash': shared_hash}, {'inbound': inbound, 'template': template}


def entry_path(identity):
    if not isinstance(identity, str) or not re.fullmatch(r'[0-9a-f]{32}', identity):
        raise EntryError('配置管理 ID 无效。')
    return STATE / (identity + '.json')


def exported(context):
    return {'INSTALLATION_ID': context['installation_id'], 'VLESS_URI': context['vless_uri']}


def bootstrap(request):
    path = entry_path(request['entry_id'])
    for parent in (*reversed(RUNTIME.parents), RUNTIME):
        secure_directory(parent, mode=0o755)
    for parent in reversed(STATE.parents):
        secure_directory(parent, mode=0o755)
    with locked(STATE):
        try:
            previous = private_read(path)
        except FileNotFoundError:
            previous = None
        if request.get('expected_identity') and (previous is None or previous['installation_id'] != request['expected_identity']):
            raise EntryError('SSH 目标不是原先绑定的入口服务器。')
        panel = Panel(request['panel_url'], request['api_token'])
        context, snapshot = discover(panel, request['link'], previous)
        context.update(installation_id=previous['installation_id'] if previous else uuid.uuid4().hex,
                       panel_url=panel.url, api_token=panel.token, entry_id=request['entry_id'])
        sources = request['sources']
        if set(sources) != {'entry_management.py', 'remote_relay.py', 'panel_version.py'}:
            raise EntryError('管理组件文件清单无效。')
        for name, source in sources.items():
            if not isinstance(source, str) or len(source) > 256 * 1024:
                raise EntryError('管理组件大小无效。')
            compile(source, name, 'exec')
        backup = STATE / ('backup-' + uuid.uuid4().hex + '.json')
        write(backup, {'entry_id': request['entry_id'], 'before': previous, 'snapshot': snapshot})
        for name, source in sources.items():
            write(RUNTIME / name, source, source=True)
        write(path, context)
        return exported(context)


def run(request):
    with locked(STATE):
        context = private_read(entry_path(request['entry_id']))
        if context['installation_id'] != request['installation_id']:
            raise EntryError('SSH 目标与已保存的服务器管理身份不一致。')
        panel = Panel(context['panel_url'], context['api_token'])
        if request['operation'] == 'export':
            discover(panel, context['vless_uri'], context)
            return exported(context)
        if request['operation'] != 'delete':
            verified, _ = discover(panel, context['vless_uri'], context)
            context['version'] = verified['version']
        spec = importlib.util.spec_from_file_location('okp_remote_relay', RUNTIME / 'remote_relay.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        try:
            server = module.RelayServer(context, STATE / ('relays-' + request['entry_id']), panel)
            return server.run(request)
        except module.RelayError as error:
            raise EntryError(str(error)) from None


def main(request=None):
    os.umask(0o077)
    try:
        if os.getuid() != 0:
            raise EntryError('服务器管理组件需要 root。')
        request = request or json.loads(sys.stdin.buffer.read(1024 * 1024 + 1))
        result = bootstrap(request) if request['operation'] == 'setup' else run(request)
        print(json.dumps({'ok': True, 'result': result}, ensure_ascii=False))
    except (EntryError, ValueError, TypeError, KeyError, OSError, ImportError, AttributeError, IndexError):
        error = sys.exc_info()[1]
        failure = {'ok': False, 'error': str(error) if isinstance(error, EntryError)
                   else '服务器管理操作失败，已保留恢复记录。'}
        if isinstance(error, EntryVersionRequired):
            failure.update(code='panel_version_required', current=error.current)
        print(json.dumps(failure, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
