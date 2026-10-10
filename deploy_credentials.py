"""Private local credentials, separate from public configuration metadata."""

import hashlib
import json
import os
import re

from deploy_resources import DeployError, atomic_write


class Credentials:
    def __init__(self, state=None):
        if state is None:
            from deploy import ResumeState
            state = ResumeState()
        self.state = state

    def read(self, path):
        if not self.state.directory.exists():
            return None
        self.state.check_directory()
        try:
            fd = self.state.open_private(path, os.O_RDONLY)
        except FileNotFoundError:
            return None
        try:
            with os.fdopen(fd, 'r', encoding='utf-8') as stream:
                raw = stream.read(16385)
            if len(raw) > 16384:
                raise ValueError
            value = json.loads(raw)
            if not isinstance(value, dict) or type(value.get('version')) is not int or value['version'] != 1:
                raise ValueError
            return value
        except (ValueError, TypeError, UnicodeError):
            raise DeployError('本地凭据文件无效，请重新设置对应连接；未回显凭据。') from None

    def write(self, path, value):
        self.state.directory.mkdir(mode=0o700, exist_ok=True)
        self.state.check_directory()
        atomic_write(path, json.dumps(value, ensure_ascii=False).encode())

    @staticmethod
    def ssh_key(target, port):
        if not isinstance(target, str) or not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.:@\[\]-]*', target):
            raise DeployError('SSH 凭据目标无效。')
        port = 22 if port is None else port
        if type(port) is not int or not 1 <= port <= 65535:
            raise DeployError('SSH 凭据端口无效。')
        target = target if '@' in target else 'root@' + target
        key = hashlib.sha256(json.dumps([target, port]).encode()).hexdigest()
        return target, port, key

    def ssh_path(self, target, port):
        return self.state.directory / ('ssh-auth-' + self.ssh_key(target, port)[2] + '.json')

    def ssh(self, target, port=None):
        value = self.read(self.ssh_path(target, port))
        if value is None:
            return None
        expected_target, expected_port, _ = self.ssh_key(target, port)
        if (set(value) != {'version', 'target', 'port', 'password'} or value['target'] != expected_target
                or type(value['port']) is not int or value['port'] != expected_port
                or not isinstance(value['password'], str) or not 1 <= len(value['password']) <= 4096
                or '\0' in value['password']):
            raise DeployError('本地 SSH 凭据无效，请重新设置连接。')
        return value['password']

    def save_ssh(self, target, port, password):
        target, port, _ = self.ssh_key(target, port)
        if not isinstance(password, str) or not 1 <= len(password) <= 4096 or '\0' in password:
            raise DeployError('SSH 密码不能为空或超过 4096 个字符。')
        self.write(self.ssh_path(target, port), {'version': 1, 'target': target, 'port': port, 'password': password})

    def forget_ssh(self, target, port=None):
        self.ssh_path(target, port).unlink(missing_ok=True)

    def panel_path(self, identity):
        if not isinstance(identity, str) or not re.fullmatch(r'[0-9a-f]{32}', identity):
            raise DeployError('面板凭据管理 ID 无效。')
        return self.state.directory / ('panel-api-' + identity + '.json')

    def panel(self, identity, server):
        value = self.read(self.panel_path(identity))
        if value is None:
            return None
        if (set(value) != {'version', 'identity', 'installation_id', 'panel_url', 'api_token'}
                or value['identity'] != identity or not server or value['installation_id'] != server['identity']):
            raise DeployError('本地面板凭据与当前服务器绑定不一致，请重新设置 3x-ui 管理。')
        self.validate_panel(value)
        return {key: value[key] for key in ('panel_url', 'api_token')}

    @staticmethod
    def validate_panel(value):
        from lib.entry_management import EntryError, Panel
        try:
            return Panel(value['panel_url'], value['api_token'], loopback=False)
        except (EntryError, KeyError, TypeError):
            raise DeployError('本地面板地址或 API Token 无效；未回显凭据。') from None

    def save_panel(self, identity, server, value):
        if not server or not isinstance(server.get('identity'), str) or not re.fullmatch(r'[0-9a-f]{32}', server['identity']):
            raise DeployError('保存面板凭据需要已验证的服务器绑定。')
        panel = self.validate_panel(value)
        self.write(self.panel_path(identity), {'version': 1, 'identity': identity,
                   'installation_id': server['identity'], 'panel_url': panel.url, 'api_token': panel.token})

    def forget_panel(self, identity):
        self.panel_path(identity).unlink(missing_ok=True)
