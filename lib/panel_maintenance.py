"""Root-only, version-pinned updates of existing systemd 3x-ui installations."""

import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import shlex
import sqlite3
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import uuid
import zipfile

if 'okp_panel_version' not in sys.modules:
    _spec = importlib.util.spec_from_file_location('okp_panel_version', Path(__file__).with_name('panel_version.py'))
    _policy = importlib.util.module_from_spec(_spec)
    sys.modules[_spec.name] = _policy
    _spec.loader.exec_module(_policy)
from okp_panel_version import (MAX_XRAY_VERSION, REPOSITORY, XRAY_REPOSITORY, github_json,
                               latest_xray_release, releases, update_available, version, xray_compatible)

INSTALL = Path('/usr/local/x-ui')
DATABASE = Path('/etc/x-ui')
STATE = Path('/etc/one-key-proxy-panel')
PROJECT = Path('/usr/local/lib/one-key-proxy')
PROJECT_CONFIG = Path('/etc/one-key-proxy')
PROJECT_RESULT = Path('/root/one-key-proxy-result.txt')
PROJECT_LOCK = Path('/run/one-key-proxy/operation.lock')


class PanelError(Exception):
    pass


def command(arguments, *, timeout=60, **kwargs):
    process = None
    try:
        process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True, **kwargs)
        output, _ = process.communicate(timeout=timeout)
    except BaseException as error:
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        if not isinstance(error, (OSError, subprocess.TimeoutExpired)):
            raise
        raise PanelError('面板维护命令失败或超时；已保留恢复记录。') from None
    finally:
        if process is not None:
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    stream.close()
    if process.returncode:
        raise PanelError('面板维护命令执行失败；已保留恢复记录。')
    return output.decode('utf-8', errors='replace').strip()


def binary_version(binary=None):
    try:
        value = command([str(binary or INSTALL / 'x-ui'), '-v'])
    except PanelError:
        raise PanelError('无法读取 3x-ui 二进制版本；未判定为旧版本，未执行更新。') from None
    parsed = version(value)
    if parsed is None:
        raise PanelError('无法识别 3x-ui 二进制版本；未判定为旧版本，未执行更新。')
    return 'v' + '.'.join(map(str, parsed))


def core_binary():
    architecture = {'x86_64': 'amd64', 'aarch64': 'arm64', 'i686': '386', 'i386': '386',
                    'armv7l': 'arm32', 'armv6l': 'arm32', 's390x': 's390x'}.get(platform.machine())
    if architecture is None:
        raise PanelError('当前 CPU 架构不支持自动选择 Xray。')
    return INSTALL / 'bin' / ('xray-linux-' + architecture)


def core_version(binary=None):
    match = re.match(r'Xray (\d+\.\d+\.\d+)(?:\s|$)', command([str(binary or core_binary()), 'version']))
    if not match or version(match[1]) is None:
        raise PanelError('无法验证 Xray 版本，未执行替换。')
    return 'v' + match[1]


def secure_directory(path):
    if path.is_symlink():
        raise PanelError('面板维护目录不安全。')
    path.mkdir(mode=0o700, exist_ok=True)
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise PanelError('面板维护目录权限不安全。')


def read_private(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'r', encoding='utf-8') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise PanelError('面板维护记录不安全。')
        return json.loads(stream.read(65537))


def write_private(path, value):
    if path.exists() or path.is_symlink():
        read_private(path)
    fd, temporary = tempfile.mkstemp(prefix='.panel-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(value, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextlib.contextmanager
def locked():
    secure_directory(STATE.parent)
    secure_directory(STATE)
    fd = os.open(STATE / 'lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600:
            raise PanelError('面板维护锁不安全。')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise PanelError('已有面板更新正在执行，请稍后重新检测。') from None
        with contextlib.ExitStack() as stack:
            project_fd = None
            if (PROJECT / 'maintenance.sh').is_file():
                secure_directory(PROJECT)
                project_info = (PROJECT / 'maintenance.sh').lstat()
                if (not stat.S_ISREG(project_info.st_mode) or project_info.st_uid != os.getuid()
                        or project_info.st_nlink != 1 or project_info.st_mode & 0o022):
                    raise PanelError('项目维护入口权限不安全。')
                secure_directory(PROJECT_LOCK.parent.parent)
                secure_directory(PROJECT_LOCK.parent)
                inherited = os.environ.get('OKP_OPERATION_LOCK_FD', '')
                if inherited.isdigit() and Path('/proc/self/fd/' + inherited).exists() and os.readlink('/proc/self/fd/' + inherited) == str(PROJECT_LOCK):
                    project_fd = int(inherited)
                else:
                    project_fd = os.open(PROJECT_LOCK, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
                    stack.callback(os.close, project_fd)
                info = os.fstat(project_fd)
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1
                        or stat.S_IMODE(info.st_mode) != 0o600):
                    raise PanelError('项目操作锁不安全。')
                try:
                    fcntl.flock(project_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise PanelError('服务器上已有项目维护操作，请稍后更新面板。') from None
            relay_lock = Path('/etc/one-key-proxy-relay/lock')
            if relay_lock.exists():
                relay_fd = os.open(relay_lock, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
                stack.callback(os.close, relay_fd)
                relay_info = os.fstat(relay_fd)
                if (not stat.S_ISREG(relay_info.st_mode) or relay_info.st_uid != os.getuid()
                        or relay_info.st_nlink != 1 or stat.S_IMODE(relay_info.st_mode) != 0o600):
                    raise PanelError('服务器管理锁不安全。')
                try:
                    fcntl.flock(relay_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise PanelError('入口有远程中转操作正在执行，请稍后更新面板。') from None
            yield project_fd
    finally:
        os.close(fd)


def database_environment(values):
    for name, value in values:
        if ((name == 'XUI_DB_TYPE' and value not in ('', 'sqlite'))
                or (name == 'XUI_DB_FOLDER' and value not in ('', str(DATABASE)))
                or (name == 'XUI_DB_DSN' and value)):
            raise PanelError('自定义数据库安装暂不支持自动更新，请使用原安装工具更新。')


def installation():
    if INSTALL.is_symlink() or (INSTALL / 'x-ui').is_symlink():
        raise PanelError('当前面板安装路径不支持自动更新。')
    unit = command(['systemctl', 'show', 'x-ui.service', '--property=ExecStart', '--value'])
    if not re.search(r'(?:path=|\s)' + re.escape(str(INSTALL / 'x-ui')) + r'(?:\s|\s*;)', unit):
        raise PanelError('自动更新要求 systemd 的 x-ui.service 使用 /usr/local/x-ui/x-ui。')
    environment = command(['systemctl', 'show', 'x-ui.service', '--property=Environment', '--value'])
    database_environment([tuple(item.split('=', 1)) for item in shlex.split(environment) if '=' in item])
    for path in (Path('/etc/default/x-ui'), Path('/etc/sysconfig/x-ui'), Path('/etc/conf.d/x-ui')):
        if path.exists():
            for line in path.read_text().splitlines():
                match = re.match(r'^\s*(?:export\s+)?(XUI_DB_(?:TYPE|FOLDER|DSN))\s*=\s*(.*)$', line)
                if match:
                    value = shlex.split(match[2], comments=True)
                    database_environment([(match[1], value[0] if len(value) == 1 else match[2])])
    if DATABASE.is_symlink() or not (DATABASE / 'x-ui.db').is_file() or (DATABASE / 'x-ui.db').is_symlink():
        raise PanelError('未找到标准 SQLite 数据库，当前安装不能自动更新。')
    for folder in (INSTALL, DATABASE):
        for item in (folder, *folder.rglob('*')):
            info = item.lstat()
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                path = ''.join(c for c in str(item) if ord(c) >= 32 and ord(c) != 127)[:180]
                raise PanelError('安装目录含不支持备份的链接或特殊文件：' + path)


def info(request=None, context=None):
    try:
        machine = Path('/etc/machine-id').read_text().strip()
    except FileNotFoundError:
        machine = ''
    panel_id = hashlib.sha256((machine + str(INSTALL)).encode()).hexdigest() if re.fullmatch(r'[0-9a-f]{32}', machine) else None
    if (STATE / 'pending.json').exists():
        journal = read_journal()
        return {'current': journal['current'], 'updatable': True, 'reason': '更新中断，需要恢复',
                'pending': True, 'panel_id': panel_id}
    api_current = None
    if context:
        try:
            status = panel_status(request, context)
            parsed = version(status.get('panelVersion'))
            if parsed is not None:
                api_current = 'v' + '.'.join(map(str, parsed))
        except PanelError:
            pass
    current = api_current or binary_version()
    try:
        if context and context.get('entry_id') and api_current is None:
            raise PanelError('已绑定面板的管理 API 暂不可用，无法确认更新目标；请先修复 3x-ui 管理配置。')
        if api_current and binary_version() != api_current:
            raise PanelError('管理 API 与本机标准安装版本不一致，请使用对应面板的原安装工具更新。')
        installation()
        core_current = core_version()
        error = None
    except PanelError as problem:
        error = str(problem)
    return {'current': current, 'core_current': core_current if error is None else None,
            'updatable': error is None, 'reason': error,
            'panel_id': panel_id, 'api_verified': api_current is not None}


def release_asset(tag):
    if version(tag) is None:
        raise PanelError('目标面板版本无效。')
    release = github_json('/releases/tags/' + tag)
    if release.get('tag_name') != tag or release.get('draft') is not False or release.get('prerelease') is not False:
        raise PanelError('目标必须是官方稳定版。')
    architecture = {'x86_64': 'amd64', 'aarch64': 'arm64', 'i686': '386', 'i386': '386',
                    'armv7l': 'armv7', 'armv6l': 'armv6', 's390x': 's390x'}.get(platform.machine())
    if architecture is None:
        raise PanelError('当前 CPU 架构不支持自动更新。')
    name = 'x-ui-linux-' + architecture + '.tar.gz'
    assets = [asset for asset in release.get('assets', []) if asset.get('name') == name]
    expected_url = f'https://github.com/{REPOSITORY}/releases/download/{tag}/{name}'
    if len(assets) != 1 or assets[0].get('browser_download_url') != expected_url:
        raise PanelError('官方发布文件无效。')
    digest = assets[0].get('digest', '')
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
        raise PanelError('官方发布未提供有效 SHA-256，未执行更新。')
    commit = github_json('/commits/' + tag).get('sha', '')
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise PanelError('官方版本 commit 无效。')
    return expected_url, digest[7:], commit, architecture


def panel_context(request):
    entry_id = request.get('entry_id')
    if entry_id is not None:
        if not isinstance(entry_id, str) or not re.fullmatch(r'[0-9a-f]{32}', entry_id):
            raise PanelError('面板管理 ID 无效。')
        context = read_private(Path('/etc/one-key-proxy-relay') / (entry_id + '.json'))
        if context.get('installation_id') != request.get('installation_id'):
            raise PanelError('SSH 目标与此配置原先绑定的服务器不一致，不能更新。')
        return context
    if 'panel_url' in request or 'api_token' in request:
        return {'panel_url': request['panel_url'], 'api_token': request['api_token']}
    return None


def panel_status(request, context):
    scope = {'__name__': 'okp_panel_health'}
    exec(compile(request['sources']['entry_management.py'], 'entry_management.py', 'exec'), scope)
    try:
        return scope['Panel'](context['panel_url'], context['api_token'])('GET', '/panel/api/server/status')
    except scope['EntryError']:
        raise PanelError('原面板 API 地址或 Token 未通过验证。') from None


def panel_health(request, context, expected):
    if context is None:
        return
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        try:
            status = panel_status(request, context)
            if (version(status.get('panelVersion')) == version(expected)
                    and status.get('xray', {}).get('state') == 'running' and not status.get('xray', {}).get('errorMsg')):
                return
        except PanelError:
            pass
        time.sleep(1)
    raise PanelError('面板更新后原 API 地址、Token 或 Xray 健康检查失败。')


def download(url, path, expected):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    digest, size = hashlib.sha256(), 0
    with opener.open(url, timeout=60) as response, path.open('xb') as stream:
        if not response.geturl().startswith('https://'):
            raise PanelError('发布文件下载未使用 HTTPS。')
        while True:
            data = response.read(1024 * 1024)
            if not data:
                break
            size += len(data)
            if size > 512 * 1024 * 1024:
                raise PanelError('发布文件过大。')
            digest.update(data)
            stream.write(data)
    if digest.hexdigest() != expected:
        raise PanelError('发布文件 SHA-256 校验失败，未执行更新。')


def prepare_core(directory, target=None):
    if target is None:
        selected = latest_xray_release(releases(XRAY_REPOSITORY))
        if selected is None:
            raise PanelError('未找到符合兼容策略的官方 Xray，未执行更新。')
        target = selected['tag_name']
    if not xray_compatible(target):
        raise PanelError(f'Xray 版本超出兼容范围（当前上限 {MAX_XRAY_VERSION}），未执行更新。')
    target = 'v' + '.'.join(map(str, version(target)))
    release = github_json('/releases/tags/' + target, XRAY_REPOSITORY)
    if release.get('tag_name') != target or release.get('draft') is not False:
        raise PanelError('Xray 目标不是有效的官方数字版本。')
    architecture = {'x86_64': '64', 'aarch64': 'arm64-v8a', 'i686': '32', 'i386': '32',
                    'armv7l': 'arm32-v7a', 'armv6l': 'arm32-v6', 's390x': 's390x'}.get(platform.machine())
    if architecture is None:
        raise PanelError('当前 CPU 架构不支持自动选择 Xray。')
    name = 'Xray-linux-' + architecture + '.zip'
    url = f'https://github.com/{XRAY_REPOSITORY}/releases/download/{target}/{name}'
    assets = [item for item in release.get('assets', []) if item.get('name') == name]
    if (len(assets) != 1 or assets[0].get('browser_download_url') != url
            or not re.fullmatch(r'sha256:[0-9a-f]{64}', assets[0].get('digest') or '')):
        raise PanelError('官方 Xray 资产地址或 SHA-256 无效，未执行更新。')
    archive, binary = directory / 'core.zip', directory / 'xray'
    download(url, archive, assets[0]['digest'][7:])
    with zipfile.ZipFile(archive) as stream:
        members = [item for item in stream.infolist() if item.filename == 'xray']
        if (len(members) != 1 or members[0].file_size > 256 * 1024 * 1024
                or stat.S_IFMT(members[0].external_attr >> 16) not in (0, stat.S_IFREG)):
            raise PanelError('官方 Xray 压缩包缺少有效内核。')
        with stream.open(members[0]) as source, binary.open('xb') as output:
            shutil.copyfileobj(source, output)
    binary.chmod(0o755)
    if core_version(binary) != target:
        raise PanelError('Xray 二进制版本与选定版本不一致，未执行更新。')
    return binary, target


def core_health(expected, request, context):
    if core_version() != expected:
        raise PanelError('替换后的 Xray 版本不符合选定版本。')
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        try:
            if context:
                status = panel_status(request, context).get('xray', {})
                if (version(status.get('version')) == version(expected) and status.get('state') == 'running'
                        and not status.get('errorMsg')):
                    return
            else:
                pid = command(['systemctl', 'show', 'x-ui.service', '--property=MainPID', '--value'])
                if pid.isdigit() and int(pid) > 0:
                    installed = core_binary().stat()
                    for child in Path('/proc/' + pid + '/task/' + pid + '/children').read_text().split():
                        try:
                            running = os.stat('/proc/' + child + '/exe')
                            if (running.st_dev, running.st_ino) == (installed.st_dev, installed.st_ino):
                                return
                        except FileNotFoundError:
                            continue
        except (OSError, PanelError):
            pass
        time.sleep(1)
    raise PanelError('选定的 Xray 未通过运行检查。')


def unpack(archive, destination):
    total, names = 0, set()
    with tarfile.open(archive, 'r:gz') as stream:
        members = stream.getmembers()
        if len(members) > 20000:
            raise PanelError('面板发布文件包含过多项目。')
        for member in members:
            path = Path(member.name)
            if (path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != 'x-ui'
                    or member.name in names or not (member.isfile() or member.isdir()) or member.mode & 0o6000):
                raise PanelError('面板发布压缩包路径或文件类型不安全。')
            names.add(member.name)
            total += member.size
            if total > 1024 * 1024 * 1024:
                raise PanelError('面板发布文件解压后过大。')
        for member in members:
            target = destination / member.name
            if member.isdir():
                target.mkdir(mode=0o755, parents=True, exist_ok=True)
            else:
                target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                with stream.extractfile(member) as source, target.open('xb') as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)
    binary = destination / 'x-ui' / 'x-ui'
    if not binary.is_file():
        raise PanelError('官方发布缺少面板二进制。')
    binary.chmod(0o755)


def overlay(package, destination):
    mutable_suffixes = {'.json', '.db', '.env', '.pem', '.crt', '.key', '.yaml', '.yml'}
    def preserve(directory, names):
        relative = Path(directory).relative_to(package)
        return [name for name in names if (destination / relative / name).is_file()
                and Path(name).suffix in mutable_suffixes]
    shutil.copytree(package, destination, dirs_exist_ok=True, ignore=preserve)


def restore_core(request):
    identity = request.get('backup_id', '')
    if not isinstance(identity, str) or not re.fullmatch(r'[0-9a-f]{32}', identity):
        raise PanelError('Xray 恢复需要有效的面板升级备份 ID。')
    with locked():
        if (STATE / 'pending.json').exists():
            raise PanelError('请先恢复未完成的面板更新，再恢复 Xray。')
        installation()
        context = panel_context(request)
        binary = core_binary()
        backup = STATE / ('backup-' + identity)
        secure_directory(backup)
        original = backup / 'installation' / 'bin' / binary.name
        if not original.is_file() or original.is_symlink():
            raise PanelError('升级备份中未找到原 Xray 内核。')
        current, target = core_version(binary).removeprefix('v'), core_version(original).removeprefix('v')
        if not xray_compatible(target):
            raise PanelError('备份中的 Xray 超出兼容范围，未执行恢复。')
        if current != request.get('current_core'):
            raise PanelError('Xray 版本已发生变化，未执行恢复。')
        panel_version = binary_version()
        recovery = STATE / ('core-backup-' + uuid.uuid4().hex)
        recovery.mkdir(mode=0o700)
        saved = recovery / binary.name
        shutil.copy2(binary, saved)
        saved.chmod(0o600)
        incoming = binary.with_name('.okp-core-' + uuid.uuid4().hex)
        def replace(source):
            shutil.copy2(source, incoming)
            incoming.chmod(0o755)
            os.replace(incoming, binary)
        try:
            command(['systemctl', 'stop', 'x-ui.service'])
            replace(original)
            command(['systemctl', 'start', 'x-ui.service'])
            healthy(panel_version)
            panel_health(request, context, panel_version)
            if core_version(binary).removeprefix('v') != target:
                raise PanelError('恢复后的 Xray 版本不符合备份。')
        except BaseException:
            try:
                command(['systemctl', 'stop', 'x-ui.service'])
                replace(saved)
                command(['systemctl', 'start', 'x-ui.service'])
                healthy(panel_version)
            except Exception:
                raise PanelError('Xray 恢复失败且回退未完成，原内核保留在 /etc/one-key-proxy-panel。') from None
            raise PanelError('Xray 恢复失败，已回退至操作前的内核；面板数据库未修改。') from None
        finally:
            incoming.unlink(missing_ok=True)
        return {'current_core': target, 'panel_version': panel_version, 'backup': str(recovery)}


def healthy(expected):
    if binary_version() != expected:
        raise PanelError('面板更新后版本核验失败。')
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        try:
            command(['systemctl', 'is-active', '--quiet', 'x-ui.service'])
            pid = command(['systemctl', 'show', 'x-ui.service', '--property=MainPID', '--value'])
            running = os.stat('/proc/' + pid + '/exe') if pid.isdigit() and int(pid) > 0 else None
            installed = (INSTALL / 'x-ui').stat()
            if running and (running.st_dev, running.st_ino) == (installed.st_dev, installed.st_ino):
                with contextlib.closing(sqlite3.connect('file:' + str(DATABASE / 'x-ui.db') + '?mode=ro', uri=True)) as connection:
                    if connection.execute('PRAGMA quick_check').fetchone() != ('ok',):
                        raise PanelError('面板数据库校验失败。')
                return
        except (PanelError, OSError):
            pass
        time.sleep(1)
    raise PanelError('面板更新后启动或数据库检查失败。')


def restore_directory(source, destination, backup, name):
    incoming, failed = backup / (name + '-restore'), backup / (name + '-failed')
    if incoming.exists():
        shutil.rmtree(incoming)
    shutil.copytree(source, incoming)
    if destination.exists():
        if failed.exists():
            shutil.rmtree(failed)
        os.replace(destination, failed)
    os.replace(incoming, destination)


def restore(journal):
    command(['systemctl', 'stop', 'x-ui.service'])
    old, backup = Path(journal['old']), Path(journal['backup'])
    if old.exists():
        if INSTALL.exists():
            shutil.rmtree(INSTALL)
        os.replace(old, INSTALL)
    database_backup = backup / 'database'
    if journal['backup_ready']:
        if not database_backup.is_dir() or database_backup.is_symlink():
            raise PanelError('面板数据库备份缺失，未恢复数据库。')
        restore_directory(database_backup, DATABASE, backup, 'database')
        if journal['project']:
            restore_directory(backup / 'project', PROJECT_CONFIG, backup, 'project')
            result_backup = backup / 'result'
            if result_backup.exists():
                shutil.copy2(result_backup, PROJECT_RESULT)
    command(['systemctl', 'start', 'x-ui.service'])
    healthy(journal['current'])
    if Path(journal['new']).exists():
        shutil.rmtree(journal['new'])
    (STATE / 'pending.json').unlink()


def read_journal():
    journal = read_private(STATE / 'pending.json')
    identity = journal.get('identity', '')
    if (not re.fullmatch(r'[0-9a-f]{32}', identity)
            or set(journal) != {'identity', 'current', 'target', 'old', 'new', 'backup', 'backup_ready', 'project'}
            or type(journal['backup_ready']) is not bool
            or type(journal['project']) is not bool
            or version(journal['current']) is None or version(journal['target']) is None
            or journal['old'] != str(INSTALL) + '.okp-old-' + identity
            or journal['new'] != str(INSTALL) + '.okp-new-' + identity
            or journal['backup'] != str(STATE / ('backup-' + identity))):
        raise PanelError('面板更新恢复记录无效，拒绝修改服务。')
    for key in ('old', 'new', 'backup'):
        if Path(journal[key]).is_symlink():
            raise PanelError('面板更新恢复路径不安全。')
    return journal


def recover():
    try:
        journal = read_journal()
    except FileNotFoundError:
        return
    restore(journal)


def project_state(project_fd, phase, tag='', commit='', digest=''):
    # Child state operations share the held operation lock; their cleanup must not unlock it.
    script = '''set -euo pipefail
. /usr/local/lib/one-key-proxy/maintenance.sh
maintenance_require_root
trap 'OKP_OPERATION_LOCK_FD=""; maintenance_cleanup_temp_paths' EXIT
state_init
[[ $(state_get MANAGED_BY) == one-key-proxy ]]
okp_hook_settle_pending_xui_update
trap 'OKP_OPERATION_LOCK_FD=""; maintenance_cleanup_temp_paths' EXIT
if [[ $1 == finish ]]; then
    state_set_many XUI_VERSION "$2" XUI_RELEASE_COMMIT "$3" XUI_RELEASE_ASSET_SHA256 "$4"
fi
if [[ $1 == finish || $1 == core-finish ]]; then
    okp_hook_diagnostics
    _okp_i_write_result
fi
'''
    environment = dict(os.environ, OKP_OPERATION_LOCK_FD=str(project_fd), OKP_MAINTENANCE_REEXECED='true',
                       OKP_PANEL_UPDATE_RUNNING='true')
    command(['bash', '-c', script, 'okp-panel-state', phase, tag, commit, digest], timeout=300,
            pass_fds=(project_fd,), env=environment)


def update(request):
    with locked() as project_fd:
        recover()
        context = panel_context(request)
        if project_fd is not None:
            project_state(project_fd, 'prepare')
        installation()
        current, target = binary_version(), request.get('target', '')
        if request.get('current') != current:
            raise PanelError('面板版本已发生变化，请重新检测后选择更新。')
        panel_changed = current != target
        if panel_changed and not update_available(current, target):
            raise PanelError('只允许更新至当前 major 的更新稳定版本，不能跨 major 或降级。')
        if request.get('core_target') is not None and not xray_compatible(request['core_target']):
            raise PanelError(f'Xray 版本超出兼容范围（当前上限 {MAX_XRAY_VERSION}），未执行更新。')
        core_current = core_version()
        if request.get('core_current') is not None and version(request['core_current']) != version(core_current):
            raise PanelError('Xray 版本已发生变化，请重新检测后选择更新。')
        url, digest, commit, architecture = release_asset(target) if panel_changed else ('', '', '', '')
        identity = uuid.uuid4().hex
        backup = STATE / ('backup-' + identity)
        backup.mkdir(mode=0o700)
        journal = {'identity': identity, 'current': current, 'target': target,
                   'old': str(INSTALL) + '.okp-old-' + identity,
                   'new': str(INSTALL) + '.okp-new-' + identity, 'backup': str(backup),
                   'backup_ready': False, 'project': project_fd is not None}
        with tempfile.TemporaryDirectory(prefix='release-', dir=STATE) as directory:
            directory = Path(directory)
            core, core_target = prepare_core(directory, request.get('core_target'))
            if not panel_changed and core_current == core_target:
                healthy(target)
                core_health(core_target, request, context)
                backup.rmdir()
                return {'current': current, 'core_current': core_target, 'already_current': True}
            if (INSTALL / 'bin/config.json').is_file():
                command([str(core), 'run', '-test', '-config', str(INSTALL / 'bin/config.json')], timeout=60)
            if panel_changed:
                archive = directory / 'release.tar.gz'
                download(url, archive, digest)
                unpack(archive, directory)
                package = directory / 'x-ui'
                if binary_version(package / 'x-ui') != target:
                    raise PanelError('发布二进制版本与选定版本不一致。')
                if architecture in ('armv6', 'armv7'):
                    (package / 'bin' / ('xray-linux-' + architecture)).rename(package / 'bin' / 'xray-linux-arm32')
            write_private(STATE / 'pending.json', journal)
            try:
                command(['systemctl', 'stop', 'x-ui.service'])
                shutil.copytree(DATABASE, backup / 'database')
                shutil.copytree(INSTALL, backup / 'installation')
                if journal['project']:
                    shutil.copytree(PROJECT_CONFIG, backup / 'project')
                    if PROJECT_RESULT.exists():
                        shutil.copy2(PROJECT_RESULT, backup / 'result')
                ready = dict(journal, backup_ready=True)
                write_private(STATE / 'pending.json', ready)
                journal = ready
                shutil.copytree(INSTALL, journal['new'])
                if panel_changed:
                    overlay(package, Path(journal['new']))
                shutil.copy2(core, Path(journal['new']) / 'bin' / core_binary().name)
                os.replace(INSTALL, journal['old'])
                os.replace(journal['new'], INSTALL)
                if panel_changed:
                    command([str(INSTALL / 'x-ui'), 'migrate'], timeout=120)
                command(['systemctl', 'start', 'x-ui.service'])
                healthy(target)
                panel_health(request, context, target)
                core_health(core_target, request, context)
                if journal['project']:
                    project_state(project_fd, 'finish' if panel_changed else 'core-finish', target, commit, digest)
            except BaseException:
                try:
                    restore(journal)
                except Exception:
                    raise PanelError('面板更新失败且自动恢复未完成；请重新进入更新面板恢复，备份保留在 /etc/one-key-proxy-panel。') from None
                raise PanelError('面板更新失败，已恢复原版本和数据库；备份已保留。') from None
            (STATE / 'pending.json').unlink()
            shutil.rmtree(journal['old'])
        return {'current': target, 'core_current': core_target, 'backup': str(backup)}


def main(request=None):
    os.umask(0o077)
    try:
        if os.getuid() != 0:
            raise PanelError('面板更新需要 root SSH 登录。')
        request = request or json.loads(sys.stdin.buffer.read(1024 * 1024 + 1))
        def interrupted(*_):
            raise PanelError('面板更新被中断。')
        for name in ('SIGHUP', 'SIGTERM', 'SIGINT'):
            signal.signal(getattr(signal, name), interrupted)
        operation = request.get('operation')
        if operation == 'panel-info':
            result = info(request, panel_context(request))
            result['pending'] = (STATE / 'pending.json').exists()
        elif operation == 'panel-credentials':
            context = panel_context(request)
            if not context or not request.get('entry_id'):
                raise PanelError('取回面板凭据需要已验证的入口绑定。')
            result = {key: context[key] for key in ('panel_url', 'api_token')}
        elif operation == 'panel-core-restore':
            result = restore_core(request)
        elif operation == 'panel-update':
            result = update(request)
        elif operation == 'panel-recover':
            with locked():
                recover()
                result = info()
        else:
            raise PanelError('面板维护操作无效。')
        print(json.dumps({'ok': True, 'result': result}, ensure_ascii=False))
    except (PanelError, ValueError, KeyError, TypeError, OSError, sqlite3.Error, zipfile.BadZipFile) as error:
        print(json.dumps({'ok': False, 'error': str(error) if isinstance(error, PanelError)
                          else '面板维护失败，请检查 SSH、GitHub 访问和服务器运行环境。'}, ensure_ascii=False))


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--prepare-core':
        try:
            directory = Path(sys.argv[2])
            secure_directory(directory)
            binary, target = prepare_core(directory)
            print(json.dumps({'binary': str(binary), 'version': target}))
        except (PanelError, OSError, ValueError, zipfile.BadZipFile) as error:
            print(str(error) if isinstance(error, PanelError) else 'Xray 准备失败，请检查 GitHub 访问。', file=sys.stderr)
            sys.exit(1)
    else:
        main()
