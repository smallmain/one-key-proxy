"""Optional browser assistance for Shlii login challenges."""

import copy
import contextlib
import json
from pathlib import Path
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import urllib.parse

from deploy_resources import DeployError
from deploy_shlii import BASE, DEVICE_FIELDS, ShliiError


def run_browser_helper(client, expected):
    python = Path(__file__).resolve().parent / ".venv-shlii/bin/python"
    if not python.is_file() or python.absolute() == Path(sys.executable).absolute():
        raise DeployError("浏览器辅助登录需要 Playwright：运行 python3 -m venv .venv-shlii，再运行 "
                          ".venv-shlii/bin/python -m pip install -r requirements-shlii.txt；随后继续原流程。")
    payload = json.dumps({"directory": str(client.store.state.directory), "account": client.account, "expected": expected}).encode()
    try:
        result = subprocess.run([str(python), str(Path(__file__).resolve())], input=payload,
                                stdout=subprocess.DEVNULL, timeout=660, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise DeployError("Shlii 浏览器辅助登录未完成，已保留原账号和流程。") from None
    if result.returncode:
        raise DeployError("Shlii 浏览器辅助登录未完成，已保留原账号和流程。")
    saved = client.store.account()
    if not saved or (expected is not None and saved["account_id"] != expected):
        raise DeployError("Shlii 浏览器登录后未能核对账号。")
    client.account = saved
    client.cookies.clear()
    client.import_cookies(saved["cookies"])
    client.authenticated = True


def browser_path(playwright):
    paths = ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
             "/Applications/Chromium.app/Contents/MacOS/Chromium"]
    paths += [shutil.which(name) for name in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser")]
    paths.append(playwright.chromium.executable_path)
    for path in paths:
        if path and Path(path).is_file():
            return path
    raise DeployError("找不到 Chrome；请运行 .venv-shlii/bin/python -m playwright install chromium 后继续。")


def wait_for_login():
    try:
        with open("/dev/tty", "r", encoding="utf-8") as reader, open("/dev/tty", "w", encoding="utf-8") as writer:
            writer.write("请在普通 Chrome 窗口完成 Cloudflare 验证及 Shlii 登录。完成后在终端按回车，输入 0 返回：\n")
            writer.flush()
            ready, _, _ = select.select([reader], [], [], 600)
            answer = reader.readline() if ready else ""
            if not answer or answer.strip() == "0":
                raise DeployError("浏览器登录未确认，已保留原账号和流程。")
    except OSError:
        raise DeployError("浏览器登录确认需要交互终端，请从原菜单继续。") from None


def capture_session(client, browser, expected):
    contexts = browser.contexts
    pages = [(context, page) for context in contexts for page in context.pages
             if urllib.parse.urlsplit(page.url).scheme == "https" and urllib.parse.urlsplit(page.url).netloc == "shlii.io"]
    if not pages:
        raise DeployError("浏览器中没有 Shlii 页面，未读取其它网站的登录状态。")
    context, page = pages[0]
    values = page.evaluate("""() => ({deviceId: localStorage.getItem('device_id'),
        userAgent: navigator.userAgent, language: navigator.language,
        platform: /Mac/.test(navigator.platform) ? 'Mac' : /Win/.test(navigator.platform) ? 'Windows' : /Linux/.test(navigator.platform) ? 'Linux' : 'Unknown',
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone})""")
    candidate = copy.deepcopy(client.account)
    device = dict(DEVICE_FIELDS, **values)
    if not device.get("deviceId"):
        raise DeployError("网页登录尚未建立 Shlii 设备标识，请完成登录后继续。")
    candidate["device"] = device
    result = page.evaluate("""async device => {
        const response = await fetch('/api/auth/refresh', {method: 'POST', credentials: 'include',
            headers: {'Content-Type': 'application/json'}, body: JSON.stringify({device})});
        let payload = null; try { payload = await response.json(); } catch {}
        if (response.ok && payload && payload.token && !payload.user) {
            const me = await fetch('/api/auth/me', {credentials: 'include', headers: {Authorization: 'Bearer ' + payload.token}});
            if (me.ok) payload.user = (await me.json()).user;
        }
        return {status: response.status, payload};
    }""", device)
    if result["status"] != 200:
        raise ShliiError(result["status"], result.get("payload"))
    user = (result.get("payload") or {}).get("user") or {}
    names = [v for v in (user.get("username"), user.get("email")) if isinstance(v, str) and v]
    if candidate["username"] and names and candidate["username"].casefold() not in [v.casefold() for v in names]:
        candidate["password"] = ""
    candidate["username"] = (user.get("username") or user.get("email")) or candidate["username"]
    client.account = candidate
    client.cookies.clear()
    client.import_cookies([{"name": c["name"], "value": c["value"], "domain": c["domain"], "path": c["path"],
                           "secure": c["secure"], "expires": int(c["expires"]) if c["expires"] > 0 else None,
                           "rest": {"HttpOnly": c["httpOnly"], "SameSite": c["sameSite"]}}
                          for c in context.cookies([BASE, BASE + "/api/auth/refresh"])
                          if c["domain"] in ("shlii.io", ".shlii.io")])
    client.accept_login(result["payload"], expected)


def login_in_browser(client, expected=None):
    try:
        from playwright.sync_api import Error, sync_playwright
    except ImportError:
        return run_browser_helper(client, expected)
    process = None
    try:
        with sync_playwright() as playwright, tempfile.TemporaryDirectory(prefix="okp-shlii-browser-") as profile:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                debug_port = listener.getsockname()[1]
            process = subprocess.Popen([browser_path(playwright), "--user-data-dir=" + profile,
                                        "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=" + str(debug_port),
                                        "--no-first-run", "--no-default-browser-check", BASE + "/login"],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                # Attach only after the user finishes verification in the ordinary browser.
                wait_for_login()
                if process.poll() is not None:
                    raise DeployError("Shlii 登录窗口已关闭，未替换原账号。")
                browser = playwright.chromium.connect_over_cdp("http://127.0.0.1:" + str(debug_port), timeout=15000)
                try:
                    capture_session(client, browser, expected)
                finally:
                    with contextlib.suppress(Exception):
                        browser.close()
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
    except Error:
        raise DeployError("无法接收 Shlii 浏览器登录状态，请确认已完成网页登录后继续。") from None


if __name__ == "__main__":
    try:
        from deploy import ResumeState
        from deploy_shlii import Client, Store
        raw = sys.stdin.buffer.read(131073)
        if len(raw) > 131072:
            raise ValueError
        value = json.loads(raw)
        login_in_browser(Client(Store(ResumeState(value["directory"])), value["account"]), value["expected"])
    except (DeployError, OSError, ValueError, TypeError, KeyError) as error:
        print(str(error) if isinstance(error, DeployError) else "Shlii 浏览器辅助登录失败。", file=sys.stderr)
        sys.exit(1)
