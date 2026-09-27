#!/usr/bin/env python3
# caddy-admin - Caddy + Cloudflare 站点的本地管理后端
#
# 只用 Python 标准库，不装任何 pip 包。默认只监听 127.0.0.1，
# 从外部访问请走 SSH 隧道：ssh -L 8848:127.0.0.1:8848 root@你的IP
#
# 它不重新实现任何逻辑：添加/删除站点都是去调 add-site.sh，
# 自己只负责读配置、读证书、查 Cloudflare 记录，然后喂给前端。
import argparse
import datetime
import glob
import json
import os
import re
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

VERSION = "1.0"

HERE = os.path.dirname(os.path.abspath(__file__))
SITES_DIR = os.environ.get("SITES_DIR", "/etc/caddy/sites")
CADDYFILE = os.environ.get("CADDYFILE", "/etc/caddy/Caddyfile")
CF_ENV = os.environ.get("CF_ENV", "/etc/caddy/cf.env")
CF_LIB = os.environ.get("CF_LIB", "/usr/local/lib/caddy/cf.sh")
UI_FILE = os.path.join(HERE, "admin-ui.html")
MOCK = os.environ.get("CADDY_ADMIN_MOCK", "0") == "1"

CF_API = "https://api.cloudflare.com/client/v4"

TG_API = "https://api.telegram.org"
TG_ENV = os.environ.get("TELEGRAM_ENV", "/etc/caddy/telegram.env")
TG_SERVICE = "telegram-bot"
TG_RELOAD_PATH = "/etc/systemd/system/telegram-bot-reload.path"
TG_BOT_FILE = os.environ.get("TG_BOT_FILE", "/usr/local/lib/caddy/telegram-bot.py")

# ---------------- 工具 ----------------


def sh(cmd, timeout=20):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()
    except Exception as exc:  # noqa: BLE001
        return 1, "", str(exc)


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


# ---------------- 站点 ----------------


def parse_conf(path):
    text = ""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        pass
    m = re.search(r"^([A-Za-z0-9_.*-]+)\s*\{", text, re.M)
    domain = m.group(1) if m else os.path.splitext(os.path.basename(path))[0]
    up = re.search(r"reverse_proxy\s+([^\s{]+)", text)
    return {
        "domain": domain,
        "upstream": up.group(1) if up else "",
        "dns01": "dns cloudflare" in text,
        "file": os.path.basename(path),
        "raw": text,
    }


MOCK_SITES = [
    {"domain": "app.example.com", "upstream": "127.0.0.1:8080", "dns01": True,
     "file": "app.example.com.conf", "raw": ""},
    {"domain": "nas.example.com", "upstream": "192.168.1.10:5000", "dns01": True,
     "file": "nas.example.com.conf", "raw": ""},
    {"domain": "wiki.example.com", "upstream": "wiki:3000", "dns01": True,
     "file": "wiki.example.com.conf", "raw": ""},
    {"domain": "git.example.com", "upstream": "127.0.0.1:3000", "dns01": False,
     "file": "git.example.com.conf", "raw": ""},
]


def list_sites():
    if MOCK:
        return list(MOCK_SITES)
    if not os.path.isdir(SITES_DIR):
        return []
    return [parse_conf(p) for p in sorted(glob.glob(os.path.join(SITES_DIR, "*.conf")))]


def add_site(payload):
    domain = (payload.get("domain") or "").strip()
    upstream = (payload.get("upstream") or "").strip()
    if not domain or not upstream:
        return {"ok": False, "bad_request": True, "error": "域名和上游地址都不能为空"}
    if not re.match(r"^[A-Za-z0-9._*-]+\.[A-Za-z]{2,}$", domain):
        return {"ok": False, "bad_request": True, "error": "域名格式不对: %s" % domain}

    cmd = "add-site.sh %s %s" % (shellquote(domain), shellquote(upstream))
    if payload.get("dns01"):
        cmd += " --dns"
    if payload.get("useProxy"):
        cmd += " --proxy"
    if payload.get("noApiDns"):
        cmd += " --no-api-dns"
    if payload.get("ip"):
        cmd += " --ip " + shellquote(str(payload["ip"]))

    if MOCK:
        MOCK_SITES.append({"domain": domain, "upstream": upstream,
                           "dns01": bool(payload.get("dns01")),
                           "file": domain + ".conf", "raw": ""})
        return {"ok": True, "output": "[演示模式] 已模拟添加 " + domain}

    rc, out, err = sh(cmd, timeout=120)
    return {"ok": rc == 0, "output": out, "error": err, "cmd": cmd}


def remove_site(domain):
    if MOCK:
        MOCK_SITES[:] = [s for s in MOCK_SITES if s["domain"] != domain]
        return {"ok": True, "output": "[演示模式] 已模拟删除 " + domain}
    rc, out, err = sh("add-site.sh --remove " + shellquote(domain), timeout=120)
    return {"ok": rc == 0, "output": out, "error": err}


def shellquote(s):
    return "'" + str(s).replace("'", "'\"'\"'") + "'"


# ---------------- 系统状态 ----------------


def get_status():
    if MOCK:
        return {
            "caddy": "running",
            "version": "v2.11.2 (演示)",
            "mock": True,
            "modules": {"dnsProviderCloudflare": True, "dynamicDns": True},
            "acmeDns": True,
            "dynamicDns": True,
            "siteCount": len(MOCK_SITES),
            "tokenReady": True,
        }
    rc, out, _ = sh("caddy version")
    version = out.split("\n")[0] if rc == 0 else "未安装"
    _, svc, _ = sh("systemctl is-active caddy")
    mods = sh("caddy list-modules")[1] or ""
    has_provider = bool(re.search(r"^dns\.providers\.cloudflare$", mods, re.M))
    has_dynamic = bool(re.search(r"^dynamic_dns$", mods, re.M))
    caddyfile = ""
    try:
        with open(CADDYFILE, encoding="utf-8", errors="replace") as fh:
            caddyfile = fh.read()
    except OSError:
        pass
    return {
        "caddy": svc or "unknown",
        "version": version,
        "mock": False,
        "modules": {"dnsProviderCloudflare": has_provider, "dynamicDns": has_dynamic},
        "acmeDns": "acme_dns cloudflare" in caddyfile,
        "dynamicDns": bool(re.search(r"^dynamic_dns\s*\{", caddyfile, re.M)),
        "siteCount": len(list_sites()),
        "tokenReady": os.path.isfile(CF_ENV),
    }


# ---------------- 证书 ----------------


def parse_expiry(iso_or_ts):
    if not iso_or_ts:
        return None
    try:
        if isinstance(iso_or_ts, (int, float)):
            dt = datetime.datetime.fromtimestamp(iso_or_ts)
        else:
            dt = datetime.datetime.fromisoformat(str(iso_or_ts).replace("Z", "+00:00"))
    except Exception:  # noqa: BLE001
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt


def get_certs():
    if MOCK:
        base = datetime.datetime.now(datetime.timezone.utc)
        data = [
            ("app.example.com", 73),
            ("nas.example.com", 21),
            ("wiki.example.com", 58),
            ("git.example.com", 5),
            ("*.example.com", 44),
        ]
        out = []
        for name, days in data:
            exp = base + datetime.timedelta(days=days)
            out.append({"name": name, "expires": exp.isoformat(), "days": days})
        return out

    rc, out, _ = sh("caddy list-certificates")
    if rc != 0:
        return []
    try:
        raw = json.loads(out)
    except json.JSONDecodeError:
        return []

    now = datetime.datetime.now(datetime.timezone.utc)
    certs = []
    for item in raw:
        names = item.get("names") or item.get("subjects") or []
        exp_raw = item.get("expiration") or item.get("not_after")
        dt = parse_expiry(exp_raw)
        days = int((dt - now).total_seconds() // 86400) if dt else None
        for n in names:
            certs.append({"name": n, "expires": dt.isoformat() if dt else None, "days": days})
    certs.sort(key=lambda c: (c["days"] is None, c["days"]))
    return certs


# ---------------- Cloudflare DNS ----------------


def read_token():
    if MOCK:
        return "mock-token"
    if not os.path.isfile(CF_ENV):
        return ""
    try:
        with open(CF_ENV, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("CF_API_TOKEN="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def cf_get(path, token):
    req = Request(CF_API + path)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    try:
        with urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (HTTPError, URLError, json.JSONDecodeError) as exc:
        return {"success": False, "errors": [{"message": str(exc)}]}


def get_dns(domains):
    if MOCK:
        table = {
            "app.example.com": ("A", "203.0.113.10", True),
            "nas.example.com": ("CNAME", "example.com", True),
            "wiki.example.com": ("CNAME", "example.com", True),
            "git.example.com": ("A", "203.0.113.10", False),
        }
        return [{"domain": d, "type": t, "value": v, "proxied": p, "found": True}
                for d, (t, v, p) in table.items()]

    token = read_token()
    if not token:
        return [{"domain": d, "found": False, "error": "没读到 CF Token"} for d in domains]

    out = []
    for domain in domains:
        parent = ".".join(domain.split(".")[-2:])
        z = cf_get("/zones?name=" + parent, token)
        zone = (z.get("result") or [{}])[0].get("id") if z.get("success") else None
        if not zone:
            out.append({"domain": domain, "found": False,
                        "error": (z.get("errors") or [{}])[0].get("message", "找不到 zone")})
            continue
        r = cf_get("/zones/%s/dns_records?name=%s&per_page=1" % (zone, domain), token)
        rec = (r.get("result") or [None])[0]
        if not rec:
            out.append({"domain": domain, "found": False, "error": "没有这条记录"})
            continue
        out.append({
            "domain": domain,
            "type": rec.get("type"),
            "value": rec.get("content"),
            "proxied": bool(rec.get("proxied")),
            "found": True,
        })
    return out


# ---------------- Telegram 机器人 ----------------
#
# 面板只负责"把 Token 和白名单写进 /etc/caddy/telegram.env"，不碰 systemd：
# admin-api.service 是 ProtectSystem=strict，只放开 /etc/caddy 可写。
# 让服务读到新配置这件事交给 telegram-bot-reload.path —— 它盯着 env 文件，
# 一变就 restart telegram-bot，由 systemd 自己以 root 执行。
# 好处是不用给面板加 /etc/systemd/system 写权限、也不用给它开放 D-Bus，
# 顺带还让你手工编辑 env 文件时也能自动生效。

RE_ID_LIST = re.compile(r"^\d+(\s*,\s*\d+)*$")
RE_TG_TOKEN = re.compile(r"^\d+:[A-Za-z0-9_-]{30,}$")

# 演示模式下的机器人配置（在内存里，写进去再读回来，--mock 能看到完整流程）
MOCK_TG = {"token": "123456789:AAE-demo-token-not-real", "allowed": ["100000001"]}


def tg_call(token, method, params=None, timeout=15):
    """调 Telegram Bot API。Token 只留在这次请求的内存里：
    不进 argv（会出现在 ps 里）、不进日志、不回给前端。"""
    if not token:
        return {"ok": False, "description": "缺少 Token"}
    req = Request("%s/bot%s/%s" % (TG_API, token, method),
                  data=urlencode(params or {}).encode("utf-8"))
    try:
        with urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8", "replace"))
    except HTTPError as exc:
        # Telegram 的 401/400 也是 JSON body，读出来才有可读的错误原因
        try:
            return json.loads(exc.read().decode("utf-8", "replace"))
        except Exception:  # noqa: BLE001
            return {"ok": False, "description": "HTTP %s" % exc.code}
    except (URLError, json.JSONDecodeError, OSError) as exc:
        return {"ok": False, "description": str(exc)}


def tg_read_env():
    token, allowed = "", ""
    if os.path.isfile(TG_ENV):
        try:
            with open(TG_ENV, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if line.startswith("TELEGRAM_BOT_TOKEN="):
                        token = line.split("=", 1)[1].strip()
                    elif line.startswith("TELEGRAM_ALLOWED_IDS="):
                        allowed = line.split("=", 1)[1].strip()
        except OSError:
            pass
    return token, allowed


def tg_state(with_username=True):
    if MOCK:
        tok = MOCK_TG.get("token") or ""
        return {
            "configured": bool(tok), "tokenHint": (tok[:8] + "…（已隐藏）") if tok else "",
            "allowedIds": list(MOCK_TG.get("allowed") or []), "service": "active",
            "pathUnit": True, "botFile": True, "username": "demo_sites_bot",
        }
    token, allowed = tg_read_env()
    _, svc, _ = sh("systemctl is-active " + TG_SERVICE)
    username = ""
    if token and with_username:
        me = tg_call(token, "getMe", timeout=10)
        if me.get("ok"):
            username = (me.get("result") or {}).get("username", "")
    return {
        "configured": bool(token),
        # 只露前 8 位，和 telegram-bot-setup.sh --status 一个口径
        "tokenHint": (token[:8] + "…（已隐藏）") if token else "",
        "allowedIds": [x for x in re.split(r"\s*,\s*", allowed) if x],
        "service": svc or "unknown",
        "pathUnit": os.path.isfile(TG_RELOAD_PATH),
        "botFile": os.path.isfile(TG_BOT_FILE),
        "username": username,
    }


def tg_verify(payload):
    token = (payload.get("token") or "").strip()
    if not token:
        return {"ok": False, "bad_request": True, "error": "先填 Token"}
    if not RE_TG_TOKEN.match(token):
        return {"ok": False, "bad_request": True,
                "error": "Token 格式不对。形如 123456789:AAE-xxxxxxxx，"
                         "数字、冒号、然后一长串字符——整段都要复制"}
    if MOCK:
        return {"ok": True, "username": "demo_sites_bot", "name": "Demo", "id": 100000001}
    r = tg_call(token, "getMe", timeout=15)
    if not r.get("ok"):
        return {"ok": False, "bad_request": True,
                "error": "Token 无效：" + str(r.get("description") or "未知错误")}
    res = r.get("result") or {}
    return {"ok": True, "username": res.get("username", ""),
            "name": res.get("first_name", ""), "id": res.get("id")}


def tg_pair(payload):
    """调 getUpdates 探测"谁给机器人发过消息"。
    不带 offset 调用不会确认消息，所以不影响机器人自己启动时吃掉积压。"""
    token = (payload.get("token") or "").strip() or tg_read_env()[0]
    if not token:
        return {"ok": False, "bad_request": True, "error": "先填 Token"}
    if MOCK:
        return {"ok": True, "serviceRunning": True, "candidates": [
            {"id": "100000002", "username": "demo_user", "name": "Demo User", "text": "/start"},
        ]}
    try:
        wait = int(payload.get("wait") or 12)
    except (TypeError, ValueError):
        wait = 12
    deadline = time.time() + max(0, min(wait, 25))

    found = {}
    while True:
        r = tg_call(token, "getUpdates", {"timeout": 5, "limit": 100}, timeout=20)
        if not r.get("ok"):
            return {"ok": False, "error": "Telegram 返回错误：" + str(r.get("description") or "")}
        for upd in (r.get("result") or []):
            msg = upd.get("message") or upd.get("edited_message") or {}
            who = msg.get("from") or {}
            uid = who.get("id")
            if not uid:
                continue
            seen = found.setdefault(str(uid), {
                "id": str(uid),
                "username": who.get("username") or "",
                "name": " ".join(x for x in [who.get("first_name"), who.get("last_name")] if x),
                "text": (msg.get("text") or "")[:40],
            })
            seen["text"] = seen["text"] or (msg.get("text") or "")[:40]
        if found or time.time() >= deadline:
            break
    return {"ok": True, "candidates": list(found.values()),
            "serviceRunning": sh("systemctl is-active " + TG_SERVICE)[1] == "active"}


def tg_apply(payload):
    token = (payload.get("token") or "").strip()
    if not token:
        token = tg_read_env()[0]
        if not token:
            return {"ok": False, "bad_request": True, "error": "还没有 Token，先填一个"}
    elif not RE_TG_TOKEN.match(token):
        return {"ok": False, "bad_request": True, "error": "Token 格式不对"}

    raw = payload.get("allowedIds")
    if raw is None:
        allowed = tg_read_env()[1]
    elif isinstance(raw, list):
        allowed = ",".join(str(x).strip() for x in raw if str(x).strip())
    else:
        allowed = str(raw).strip()
    allowed = re.sub(r"\s+", "", allowed)
    if allowed and not RE_ID_LIST.match(allowed):
        return {"ok": False, "bad_request": True,
                "error": "授权用户 ID 只能是数字，多个用英文逗号分隔"}

    if MOCK:
        MOCK_TG["token"] = token
        MOCK_TG["allowed"] = [x for x in allowed.split(",") if x]
        return {"ok": True, "output": "[演示模式] 已模拟写入 %s" % TG_ENV, "state": tg_state()}

    if not os.path.isdir(os.path.dirname(TG_ENV)):
        return {"ok": False, "error": "目录 %s 不存在（先跑 setup.sh）" % os.path.dirname(TG_ENV)}

    try:
        # 直接用 O_CREAT|O_TRUNC 打开并给 0o600：模式只在创建时生效，所以补一次 chmod。
        # 不用"写临时文件再 rename"是因为临时文件的创建也会惊动 path 单元，
        # 白白多触发一次重启；而 systemd 的 PathChanged 是在 close 后才触发，直接写安全。
        fd = os.open(TG_ENV, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_IDS=%s\n" % (token, allowed))
        os.chmod(TG_ENV, 0o600)
    except OSError as exc:
        return {"ok": False, "error": "写 %s 失败：%s" % (TG_ENV, exc)}

    # 等 path 单元把服务拉起来（systemd 对 path 触发有约 100ms 节流 + 服务自身启动时间）
    time.sleep(3)
    state = tg_state()
    out = ["已写入 %s（600）" % TG_ENV]
    if not state["pathUnit"]:
        out.append("⚠ 没装 telegram-bot-reload.path，服务不会自动重启。"
                   "在 VPS 上跑一次 domain-autopilot-update，或手动 systemctl restart telegram-bot")
    elif state["service"] != "active":
        out.append("服务当前 %s。若不是 active，看 journalctl -u telegram-bot -n 30" % state["service"])
    else:
        out.append("服务已在运行，配置生效")
    return {"ok": True, "output": "\n".join(out), "state": state}


# ---------------- HTTP ----------------


class Handler(BaseHTTPRequestHandler):
    server_version = "caddy-admin/" + VERSION

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s\n" % (now_iso(), fmt % args))

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _html(self):
        try:
            with open(UI_FILE, "rb") as fh:
                body = fh.read()
        except OSError:
            body = b"<h1>admin-ui.html not found</h1>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except json.JSONDecodeError:
            return {}

    def do_GET(self):
        path = self.path.split("?", 1)[0]

        if path in ("/", "/ui", "/index.html"):
            return self._html()
        if path == "/api/ping":
            return self._json({"ok": True, "version": VERSION, "mock": MOCK, "time": now_iso()})
        if path == "/api/status":
            return self._json(get_status())
        if path == "/api/sites":
            sites = list_sites()
            certs = {c["name"]: c for c in get_certs()}
            for s in sites:
                c = certs.get(s["domain"]) or certs.get("*." + ".".join(s["domain"].split(".")[1:]))
                s["certDays"] = c["days"] if c else None
                s["certExpires"] = c["expires"] if c else None
            return self._json({"sites": sites, "mock": MOCK})
        if path == "/api/certs":
            return self._json({"certs": get_certs()})
        if path == "/api/dns":
            domains = [s["domain"] for s in list_sites()]
            return self._json({"records": get_dns(domains)})
        if path == "/api/telegram":
            return self._json(tg_state())
        if path == "/api/config":
            try:
                with open(CADDYFILE, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                text = "(读不到 %s)" % CADDYFILE
            return self._json({"caddyfile": text})
        return self._json({"ok": False, "error": "not found"}, 404)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        body = self._read_body()
        if path == "/api/sites":
            res = add_site(body)
            # 输入非法 → 400；脚本执行失败 → 500
            code = 200 if res.get("ok") else (400 if res.get("bad_request") else 500)
            return self._json(res, code)
        if path == "/api/refresh":
            rc, out, err = sh("sync-dns.sh --check", timeout=120)
            return self._json({"ok": rc == 0, "output": out, "error": err})
        if path in ("/api/telegram/verify", "/api/telegram/pair", "/api/telegram/apply"):
            fn = {"/api/telegram/verify": tg_verify,
                  "/api/telegram/pair": tg_pair,
                  "/api/telegram/apply": tg_apply}[path]
            res = fn(body)
            code = 200 if res.get("ok") else (400 if res.get("bad_request") else 500)
            return self._json(res, code)
        return self._json({"ok": False, "error": "not found"}, 404)

    def do_DELETE(self):
        path = self.path.split("?", 1)[0]
        if path.startswith("/api/sites/"):
            domain = path[len("/api/sites/"):]
            return self._json(remove_site(domain))
        return self._json({"ok": False, "error": "not found"}, 404)


def main():
    ap = argparse.ArgumentParser(description="Caddy + Cloudflare 本地管理面板后端")
    ap.add_argument("--host", default="127.0.0.1", help="监听地址，默认 127.0.0.1")
    ap.add_argument("--port", type=int, default=8848)
    ap.add_argument("--mock", action="store_true", help="演示模式，不碰真实系统")
    args = ap.parse_args()

    if args.mock:
        global MOCK
        MOCK = True

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    print("caddy-admin %s 已启动: http://%s:%d" % (VERSION, args.host, args.port))
    print("演示模式: %s" % ("开" if MOCK else "关"))
    if args.host == "127.0.0.1":
        print("外部访问: ssh -L %d:127.0.0.1:%d root@你的IP" % (args.port, args.port))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止")


if __name__ == "__main__":
    main()
