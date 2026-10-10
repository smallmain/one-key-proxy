"""Shared panel and Xray version policies for the TUI and server helpers."""

import gzip
import http.client
import json
import re
import subprocess
import sys
import urllib.request
import zlib

MIN_PANEL_VERSION = '3.8.0'
# Xray >=26.9.8 requires ML-KEM absent from sing-box REALITY (SagerNet/sing-box#4520).
# Limit the core independently; panel releases can bundle an incompatible Xray.
# Set to None only after the upstream fix and end-to-end REALITY verification.
MAX_XRAY_VERSION = '26.7.28'
REPOSITORY = 'MHSanaei/3x-ui'
XRAY_REPOSITORY = 'XTLS/Xray-core'


def version(value):
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r'v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', value or '')
    return tuple(map(int, match.groups())) if match else None


def detected_version(value=None):
    if version(value) is None:
        try:
            result = subprocess.run(['/usr/local/x-ui/x-ui', '-v'], stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, timeout=30, check=True)
            value = result.stdout.decode().strip()
        except (OSError, subprocess.SubprocessError, UnicodeError):
            raise ValueError('无法识别 3x-ui 版本；请检查服务器面板二进制，未判定为旧版本。') from None
    if version(value) is None:
        raise ValueError('无法识别 3x-ui 版本；请检查服务器面板二进制，未判定为旧版本。')
    return 'v' + '.'.join(map(str, version(value)))


def supported(value):
    parsed = version(value)
    return parsed is not None and parsed[0] == version(MIN_PANEL_VERSION)[0] and parsed >= version(MIN_PANEL_VERSION)


class VersionRequired(Exception):
    def __init__(self, current):
        self.current = current
        super().__init__(f'当前 3x-ui {current}；最低支持版本为 {MIN_PANEL_VERSION}，且需使用相同 major。')


def require_version(current):
    if version(current) is None:
        raise ValueError('无法识别 3x-ui 版本；请检查面板二进制，不能据此判断需要更新。')
    if not supported(current):
        raise VersionRequired(current)


def github_json(path, repository=REPOSITORY):
    request = urllib.request.Request('https://api.github.com/repos/' + repository + path,
                                     headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'one-key-proxy',
                                              'Accept-Encoding': 'gzip'})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=30) as response:
            if response.headers.get('Content-Encoding', '').lower() == 'gzip':
                with gzip.GzipFile(fileobj=response) as stream:
                    data = stream.read(8 * 1024 * 1024 + 1)
            else:
                data = response.read(8 * 1024 * 1024 + 1)
    except (EOFError, zlib.error, http.client.HTTPException):
        raise ValueError('GitHub 压缩版本响应无效。') from None
    if len(data) > 8 * 1024 * 1024:
        raise ValueError('GitHub 版本响应过大。')
    return json.loads(data)


def releases(repository=REPOSITORY):
    result = []
    page_size = 30 if repository == XRAY_REPOSITORY else 100
    for page in range(1, 21):
        path = f'/releases?per_page={page_size}&page={page}'
        batch = github_json(path) if repository == REPOSITORY else github_json(path, repository)
        if not isinstance(batch, list):
            raise ValueError('GitHub 版本列表无效。')
        result.extend(batch)
        if len(batch) < page_size:
            return result
    raise ValueError('GitHub 版本列表未完整读取，无法确定同 major 最新版。')


def latest_release(catalog, current):
    parsed = version(current)
    if parsed is None:
        return None
    candidates = [item for item in catalog if isinstance(item, dict)
                  and item.get('draft') is False and item.get('prerelease') is False
                  and version(item.get('tag_name')) is not None
                  and version(item['tag_name'])[0] == parsed[0]]
    return max(candidates, key=lambda item: version(item['tag_name']), default=None)


def xray_compatible(target):
    parsed = version(target)
    return parsed is not None and (MAX_XRAY_VERSION is None or parsed <= version(MAX_XRAY_VERSION))


def latest_xray_release(catalog):
    # Xray also marks older numeric releases as prereleases; their tags remain usable.
    candidates = [item for item in catalog if isinstance(item, dict) and item.get('draft') is False
                  and xray_compatible(item.get('tag_name'))]
    return max(candidates, key=lambda item: version(item['tag_name']), default=None)


def update_available(current, target):
    before, after = version(current), version(target)
    return before is not None and after is not None and before[0] == after[0] and after > before


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError
        if sys.argv[1] == '--xray':
            release = latest_xray_release(releases(XRAY_REPOSITORY))
        elif version(sys.argv[1]) is not None:
            release = latest_release(releases(), sys.argv[1])
        else:
            raise ValueError
        if release is None:
            raise ValueError
        print(json.dumps(release))
    except (OSError, ValueError, TypeError):
        print('无法查询符合版本策略的官方发布。', file=sys.stderr)
        sys.exit(1)
