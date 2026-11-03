"""Runtime synchronization and managed configuration migrations over the panel transport."""

import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
import uuid

LEGACY_TARGET = 'www.cloudflare.com:443'
DEFAULT_TARGET = 'www.tencentcloud.com:443'
LAUNCHER = Path('/usr/local/bin/one-key-proxy')
REQUIRED = {'bootstrap.sh', 'install.sh', 'maintenance.sh', 'one-key-proxy', 'VERSION',
            'lib/common.sh', 'lib/state.sh', 'lib/config.sh', 'lib/integration.sh'}


def manifest(sources, panel):
    if not isinstance(sources, dict) or not REQUIRED <= sources.keys():
        raise panel.PanelError('运行文件清单不完整。')
    hashes = {}
    for name, source in sources.items():
        if (not isinstance(name, str) or not re.fullmatch(
                r'(?:bootstrap\.sh|install\.sh|maintenance\.sh|one-key-proxy|VERSION|lib/[a-zA-Z0-9_]+\.(?:sh|py))', name)
                or not isinstance(source, str) or len(source.encode()) > 2 * 1024 * 1024):
            raise panel.PanelError('运行文件路径或内容无效。')
        hashes[name] = hashlib.sha256(source.encode()).hexdigest()
    return hashes


def shell(panel, fd, body, *arguments):
    script = '''set -euo pipefail
. /usr/local/lib/one-key-proxy/maintenance.sh
maintenance_require_root
trap 'OKP_OPERATION_LOCK_FD=""; maintenance_cleanup_temp_paths' EXIT
state_init
[[ $(state_get MANAGED_BY) == one-key-proxy ]]
stage_is_done completed
[[ $(state_get INSTALLATION_ID) == "$1" ]]
shift
''' + body
    environment = dict(os.environ, OKP_OPERATION_LOCK_FD=str(fd), OKP_MAINTENANCE_REEXECED='true',
                       OKP_PANEL_UPDATE_RUNNING='true')
    return panel.command(['bash', '-c', script, 'okp-config-update', *arguments], timeout=600,
                         pass_fds=(fd,), env=environment)


def project_info(panel, fd, request):
    identity = request.get('project_identity', '')
    if not re.fullmatch(r'[0-9a-f]{32}', identity) or fd is None:
        raise panel.PanelError('配置更新需要已验证的项目安装标识。')
    raw = shell(panel, fd, '''
for key in REALITY_TARGET; do
    value=$(state_get "$key")
    printf '%s=%s\\n' "$key" "$(_state_encode "$value")"
done
''', identity)
    values = dict(line.split('=', 1) for line in raw.splitlines())
    target = base64.b64decode(values['REALITY_TARGET'], validate=True).decode()
    relay_dir = panel.PROJECT_CONFIG / 'remote-relays'
    blocked = target == LEGACY_TARGET and (relay_dir.is_symlink() or
                                          (relay_dir.exists() and any(relay_dir.glob('*.json'))))
    hashes = request.get('runtime_hashes', {})
    if not isinstance(hashes, dict) or not REQUIRED <= hashes.keys():
        raise panel.PanelError('运行文件摘要清单无效。')
    changed = False
    for name, digest in hashes.items():
        manifest({**{key: '' for key in REQUIRED}, name: ''}, panel)
        if not isinstance(digest, str) or not re.fullmatch('[0-9a-f]{64}', digest):
            raise panel.PanelError('运行文件摘要无效。')
        path = panel.PROJECT / name
        if path.is_symlink() or not path.is_file():
            changed = True
        else:
            changed |= hashlib.sha256(path.read_bytes()).hexdigest() != digest
    changed |= (LAUNCHER.is_symlink() or not LAUNCHER.is_file() or
                hashlib.sha256(LAUNCHER.read_bytes()).hexdigest() != hashes['one-key-proxy'])
    return {'runtime_changed': changed, 'reality_target': target, 'migrate': target == LEGACY_TARGET,
            'migration_blocked': blocked, 'project_identity': identity}


def runtime_journal(panel):
    path = panel.STATE / 'runtime-pending.json'
    if not path.exists():
        return None
    journal = panel.read_private(path)
    token = journal.get('token', '')
    if (set(journal) != {'token', 'project_identity', 'backup', 'old', 'new'}
            or not re.fullmatch('[0-9a-f]{32}', token)
            or not re.fullmatch('[0-9a-f]{32}', journal['project_identity'])
            or journal['backup'] != str(panel.STATE / ('runtime-backup-' + token))
            or journal['old'] != str(panel.PROJECT) + '.old-' + token
            or journal['new'] != str(panel.PROJECT) + '.new-' + token):
        raise panel.PanelError('运行文件更新恢复记录无效。')
    return journal


def recover_runtime(panel, identity):
    journal = runtime_journal(panel)
    if journal is None:
        return
    if journal['project_identity'] != identity:
        raise panel.PanelError('运行文件恢复记录不属于所选服务器。')
    backup, old, new = (Path(journal[key]) for key in ('backup', 'old', 'new'))
    for path in (backup, old, new, panel.PROJECT, LAUNCHER):
        if path.is_symlink():
            raise panel.PanelError('运行文件恢复路径不安全。')
    if not (backup / 'runtime/maintenance.sh').is_file() or not (backup / 'launcher').is_file():
        raise panel.PanelError('运行文件恢复备份不完整。')
    if old.exists():
        if panel.PROJECT.exists():
            shutil.rmtree(panel.PROJECT)
        os.replace(old, panel.PROJECT)
    elif not panel.PROJECT.exists():
        shutil.copytree(backup / 'runtime', panel.PROJECT)
    else:
        # The swap may have completed just before the transport disappeared.
        shutil.rmtree(panel.PROJECT)
        shutil.copytree(backup / 'runtime', panel.PROJECT)
    shutil.copy2(backup / 'launcher', LAUNCHER)
    if new.exists():
        shutil.rmtree(new)
    (panel.STATE / 'runtime-pending.json').unlink()


def sync_runtime(panel, fd, request):
    recover_runtime(panel, request['project_identity'])
    panel.recover()
    status = project_info(panel, fd, request)
    sources = request['runtime_sources']
    if manifest(sources, panel) != request['runtime_hashes']:
        raise panel.PanelError('运行文件与预览摘要不一致。')
    if not status['runtime_changed']:
        return status
    for path in (panel.PROJECT, *panel.PROJECT.rglob('*'), LAUNCHER):
        info = path.lstat()
        if (not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode))
                or info.st_uid != os.getuid() or info.st_mode & 0o022
                or (stat.S_ISREG(info.st_mode) and info.st_nlink != 1)):
            raise panel.PanelError('现有运行文件含不安全的文件或权限。')
    token = uuid.uuid4().hex
    backup = panel.STATE / ('runtime-backup-' + token)
    new, old = Path(str(panel.PROJECT) + '.new-' + token), Path(str(panel.PROJECT) + '.old-' + token)
    backup.mkdir(mode=0o700)
    shutil.copytree(panel.PROJECT, backup / 'runtime')
    shutil.copy2(LAUNCHER, backup / 'launcher')
    new.mkdir(mode=0o755)
    try:
        for name, source in sources.items():
            path = new / name
            path.parent.mkdir(mode=0o755, exist_ok=True)
            path.write_text(source, encoding='utf-8')
            path.chmod(0o755 if name.endswith('.sh') or name == 'one-key-proxy' else 0o644)
            if name.endswith('.sh') or name == 'one-key-proxy':
                panel.command(['sh' if name == 'bootstrap.sh' else 'bash', '-n', str(path)])
            elif name.endswith('.py'):
                compile(source, name, 'exec')
        panel.write_private(panel.STATE / 'runtime-pending.json', dict(token=token,
            project_identity=request['project_identity'], backup=str(backup), old=str(old), new=str(new)))
        os.replace(panel.PROJECT, old)
        os.replace(new, panel.PROJECT)
        with tempfile.NamedTemporaryFile(dir=LAUNCHER.parent, delete=False) as temporary:
            temporary.write(sources['one-key-proxy'].encode())
            launcher_temp = Path(temporary.name)
        launcher_temp.chmod(0o755)
        os.replace(launcher_temp, LAUNCHER)
        shell(panel, fd, '_okp_i_load_saved_config >/dev/null\n', request['project_identity'])
        (panel.STATE / 'runtime-pending.json').unlink()
        shutil.rmtree(old)
    except BaseException:
        recover_runtime(panel, request['project_identity'])
        if new.exists():
            shutil.rmtree(new)
        raise
    return dict(project_info(panel, fd, request), backup=str(backup))


def migrate(panel, fd, request):
    status = project_info(panel, fd, request)
    if status['migration_blocked']:
        raise panel.PanelError('REALITY 迁移前需要清理受管远程中转。')
    if status['reality_target'] not in (LEGACY_TARGET, DEFAULT_TARGET):
        return dict(status, custom_target_preserved=True)
    shell(panel, fd, '''
_okp_i_load_config
[[ $REALITY_TARGET == www.cloudflare.com:443 || $REALITY_TARGET == www.tencentcloud.com:443 ]]
maintenance_read() { [[ $1 == REALITY_TARGET ]] || return 1; REALITY_TARGET=www.tencentcloud.com:443; }
maintenance_confirm() { [[ $1 == '确认更换 REALITY 目标？' ]]; }
_okp_i_reconfigure_reality >/dev/null
''', request['project_identity'])
    return project_info(panel, fd, request)


def handle(request, panel):
    with panel.locked() as fd:
        pending = runtime_journal(panel)
        if request['operation'] == 'config-info':
            if pending:
                if pending['project_identity'] != request.get('project_identity'):
                    raise panel.PanelError('运行文件恢复记录不属于所选服务器。')
                return {'runtime_pending': True, 'runtime_changed': True, 'migrate': False,
                        'migration_blocked': False, 'reality_target': '待恢复'}
            return project_info(panel, fd, request)
        if request['operation'] == 'config-runtime':
            return sync_runtime(panel, fd, request)
        if pending:
            raise panel.PanelError('请先恢复运行文件更新。')
        if request['operation'] == 'config-migrate':
            return migrate(panel, fd, request)
        raise panel.PanelError('配置更新操作无效。')
