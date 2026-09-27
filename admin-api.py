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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
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
        return {"ok": False, "error": "域名和上游地址都不能为空"}
    if not re.match(r"^[A-Za-z0-9._*-]+\.[A-Za-z]{2,}$", domain):
        return {"ok": False, "error": "域名格式不对: %s" % domain}

    cmd = "add-site.sh %s %s" % (shellquote(domain), shellquote(upstream))
    if payload.get("dns01"):
        cmd += " --dns"
    if payload.get("noProxy"):
        cmd += " --no-proxy"
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
            return self._json(add_site(body))
        if path == "/api/refresh":
            rc, out, err = sh("sync-dns.sh --check", timeout=120)
            return self._json({"ok": rc == 0, "output": out, "error": err})
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
