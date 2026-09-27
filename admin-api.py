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
import socket
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, unquote, urlencode
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

# add-site.sh 这类脚本是给终端看的，输出里带 \033[32m 这类 ANSI 色码。
# 原样塞进网页会显示成 "[31m[!!][0m 上游地址不能带路径…"（字面量乱码），出口统一剥掉。
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def strip_ansi(s):
    return ANSI_RE.sub("", s or "")


def sh(cmd, timeout=20):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return (
            p.returncode,
            strip_ansi(p.stdout).strip(),
            strip_ansi(p.stderr).strip(),
        )
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
        "auth": "basic_auth" in text,
        "file": os.path.basename(path),
        "node": "local",
        "raw": text,
    }


MOCK_SITES = [
    {"domain": "app.example.com", "upstream": "127.0.0.1:8080", "dns01": True,
     "auth": False, "file": "app.example.com.conf", "node": "local", "raw": ""},
    {"domain": "nas.example.com", "upstream": "192.168.1.10:5000", "dns01": True,
     "auth": False, "file": "nas.example.com.conf", "node": "local", "raw": ""},
    {"domain": "wiki.example.com", "upstream": "wiki:3000", "dns01": True,
     "auth": False, "file": "wiki.example.com.conf", "node": "local", "raw": ""},
    {"domain": "git.example.com", "upstream": "127.0.0.1:3000", "dns01": False,
     "auth": False, "file": "git.example.com.conf", "node": "local", "raw": ""},
]


def list_sites():
    if MOCK:
        return list(MOCK_SITES)
    if not os.path.isdir(SITES_DIR):
        return []
    return [parse_conf(p) for p in sorted(glob.glob(os.path.join(SITES_DIR, "*.conf")))]


# ---------------- 上游可达性探测 ----------------
#
# 存在的理由：加站点时「在哪台机器上加」这件事，绝大多数情况下不需要用户来选 ——
# 默认就是面板本机。只有当面板本机**连不到**那个上游时才说明选错了地方，
# 那时再提示。所以这里提供一个从面板本机出发的 TCP 探测。
#
# 与 add-site.sh 同一口径：剥掉 scheme 与路径后只看 host:port。
# 带路径是允许的（路径属**访问 URL**，Caddy 原样透传），探测只关心连不连得上。
SCHEME_RE = re.compile(r"^([A-Za-z][A-Za-z0-9+.-]*)://(.*)$")


def parse_upstream(up):
    """把上游拆成 (host, port, loopback)；解析不出来返回 (None, None, False)。"""
    rest = (up or "").strip()
    m = SCHEME_RE.match(rest)
    scheme = m.group(1).lower() if m else ""
    if m:
        rest = m.group(2)
    rest = rest.split("/", 1)[0]
    if rest.startswith("["):                       # IPv6 字面量 [::1]:8080
        host, _, tail = rest[1:].partition("]")
        port = tail[1:] if tail.startswith(":") else ""
    else:
        head, sep, tail = rest.rpartition(":")
        host, port = (head, tail) if sep and tail.isdigit() else (rest, "")
    if not host:
        return None, None, False
    try:
        port = int(port)
    except ValueError:
        port = {"https": 443, "http": 80}.get(scheme, 80)
    low = host.lower()
    loopback = low in ("localhost", "::1") or low.startswith("127.")
    return host, port, loopback


def probe_upstream(up, timeout=3.0):
    """从面板本机探一次 TCP。

    ⚠️ 回环地址的结果**天然有歧义**：探到的可能是面板自己（127.0.0.1:8848 就是本面板），
    所以 loopback 要单独返回，由调用方决定怎么提示 —— 只看 reachable 会漏掉这类误判。

    安全性：这个接口让调用者能用面板的身份去连任意 host:port，是个 SSRF 面。接受它的
    理由是面板本身已有 basic_auth 兜底，而且它本来就拥有「加/删站点」这种更大的能力；
    探测只多暴露「某端口通不通」这一位信息。别把它放到没有鉴权的地方去。
    """
    if re.search(r"\s", up or ""):
        return {"ok": False, "bad_request": True, "error": "上游地址不能含空格"}
    host, port, loopback = parse_upstream(up or "")
    if not host:
        return {"ok": False, "bad_request": True, "error": "看不懂这个上游地址：%s" % up}
    res = {"ok": True, "target": "%s:%s" % ("[%s]" % host if ":" in host else host, port),
           "loopback": loopback}
    t0 = time.time()
    try:
        socket.create_connection((host, port), timeout=timeout).close()
        res["reachable"] = True
        res["ms"] = int((time.time() - t0) * 1000)
    except OSError as exc:
        res["reachable"] = False
        res["error"] = str(exc) or exc.__class__.__name__
    return res


def add_site(payload):
    domain = (payload.get("domain") or "").strip()
    upstream = (payload.get("upstream") or "").strip()
    if not domain or not upstream:
        return {"ok": False, "bad_request": True, "error": "域名和上游地址都不能为空"}
    if not re.match(r"^[A-Za-z0-9._*-]+\.[A-Za-z]{2,}$", domain):
        return {"ok": False, "bad_request": True, "error": "域名格式不对: %s" % domain}
    # 上游含空格必须先拦掉：Caddy 会把空格分隔的几段当成多个上游做负载均衡
    # （配置校验通过、只有访问时随机 502）；远端更直接 —— 空格会让节点侧的白名单
    # agent 拆出多余 token 而报「不支持的选项」。
    if re.search(r"\s", upstream):
        return {"ok": False, "bad_request": True, "error": "上游地址不能含空格"}

    node = find_node(payload.get("node"))
    if node is None:
        return {"ok": False, "bad_request": True,
                "error": "没有这个节点：%s（先在节点列表里加一个）" % (payload.get("node") or "")}

    flags = []
    if payload.get("dns01"):
        flags.append("--dns")
    if payload.get("useProxy"):
        flags.append("--proxy")
    if payload.get("noApiDns"):
        flags.append("--no-api-dns")
    if payload.get("ip"):
        ip = str(payload["ip"]).strip()
        if not RE_IPV4.match(ip):
            return {"ok": False, "bad_request": True, "error": "源站 IP 格式不对：%s" % ip}
        flags += ["--ip", ip]

    # Basic 认证的用户名/密码。密码不回显（见下面的 shown），因为它从 payload 明文来，
    # 回给前端就等于进了浏览器历史和面板日志。
    auth_user = (payload.get("authUser") or "").strip()
    auth_pass = payload.get("authPass") or ""
    if auth_user or auth_pass:
        if not auth_user or not auth_pass:
            return {"ok": False, "bad_request": True,
                    "error": "Basic 认证的用户名和密码要一起填"}
        if re.search(r"[\s:]", auth_user):
            return {"ok": False, "bad_request": True, "error": "用户名里不能有空格或冒号"}
        if re.search(r"\s", auth_pass):
            return {"ok": False, "bad_request": True,
                    "error": "密码里不能有空格（远端是要过 SSH 命令行传的）"}
        flags += ["--auth", "%s:%s" % (auth_user, auth_pass)]

    if MOCK:
        MOCK_SITES.append({"domain": domain, "upstream": upstream,
                           "dns01": bool(payload.get("dns01")),
                           "auth": bool(auth_user),
                           "file": domain + ".conf", "node": node["name"], "raw": ""})
        return {"ok": True, "node": node["name"],
                "output": "[演示模式] 已在节点 %s 上模拟添加 %s" % (node["name"], domain)}

    if node["local"]:
        cmd = "add-site.sh " + " ".join(shellquote(a) for a in [domain, upstream] + flags)
        rc, out, err = sh(cmd, timeout=180)
    else:
        rc, out, err = run_on_node(node, " ".join(["add", domain, upstream] + flags),
                                   timeout=max(180, NODE_SSH_TIMEOUT + 120))

    res = {"ok": rc == 0, "output": out, "error": err, "node": node["name"]}
    if auth_user:
        res["cmd"] = "add-site.sh %s %s --auth %s:****（密码已隐去）" % (domain, upstream, auth_user)
    return res


def remove_site(node_name, domain):
    node = find_node(node_name)
    if node is None:
        return {"ok": False, "bad_request": True,
                "error": "没有这个节点：%s" % (node_name or "")}
    if MOCK:
        MOCK_SITES[:] = [s for s in MOCK_SITES
                         if not (s["domain"] == domain and s.get("node", "local") == node["name"])]
        return {"ok": True, "output": "[演示模式] 已在节点 %s 上模拟删除 %s"
                % (node["name"], domain)}
    if node["local"]:
        rc, out, err = sh("add-site.sh --remove " + shellquote(domain), timeout=180)
    else:
        rc, out, err = run_on_node(node, "remove " + domain,
                                   timeout=max(180, NODE_SSH_TIMEOUT + 120))
    return {"ok": rc == 0, "output": out, "error": err, "node": node["name"]}


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
#
# caddy **没有** list-certificates 这类查询子命令（`caddy help` 里没有这个），
# 所以证书信息只能直接读它的存储目录。布局：
#   <data>/certificates/<issuer>/<name>/<name>.crt     同目录还有 .json 元数据
# 默认 data 目录是 /var/lib/caddy/.local/share/caddy。
CERT_BASES = [p for p in [
    os.environ.get("CADDY_CERT_DIR", ""),
    "/var/lib/caddy/.local/share/caddy/certificates",
] if p]


def cert_expiry(path):
    """读一张证书的到期时间。没有 caddy 命令可用，只能借 openssl。"""
    q = shellquote(path)
    rc, out, _ = sh("openssl x509 -in %s -noout -enddate -dateopt iso_8601" % q)
    if rc == 0 and "notAfter=" in out:
        # openssl 3.x 给的是 "2026-12-26 03:10:45Z"（是空格不是 T），
        # fromisoformat 在 3.11 之前不认空格，统一换成 T
        return parse_expiry(out.split("notAfter=", 1)[1].strip().replace(" ", "T", 1))
    # 更老的 openssl 不认 -dateopt，退回默认的 "Dec 26 03:10:45 2026 GMT"
    rc, out, _ = sh("openssl x509 -in %s -noout -enddate" % q)
    if rc == 0 and "notAfter=" in out:
        raw = out.split("notAfter=", 1)[1].strip().replace(" GMT", "")
        try:
            return datetime.datetime.strptime(raw, "%b %d %H:%M:%S %Y").replace(
                tzinfo=datetime.timezone.utc)
        except ValueError:
            return None
    return None


def cert_names(crt):
    """证书覆盖的域名。优先读 Caddy 写的 .json 元数据（能拿到泛域名），退化到目录名。"""
    try:
        with open(crt[:-4] + ".json", encoding="utf-8") as fh:
            sans = (json.load(fh) or {}).get("sans") or []
        if sans:
            return [str(x) for x in sans]
    except (OSError, json.JSONDecodeError, AttributeError):
        pass
    return [os.path.basename(os.path.dirname(crt))]


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

    now = datetime.datetime.now(datetime.timezone.utc)
    certs, seen = [], set()
    for base in CERT_BASES:
        if not os.path.isdir(base):
            continue
        for crt in sorted(glob.glob(os.path.join(base, "*", "*", "*.crt"))):
            dt = cert_expiry(crt)
            days = int((dt - now).total_seconds() // 86400) if dt else None
            for n in cert_names(crt):
                if n in seen:
                    continue
                seen.add(n)
                certs.append({"name": n,
                              "expires": dt.isoformat() if dt else None,
                              "days": days})
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


# ---------------- 节点（多机纳管） ----------------
#
# 面板本身只「住」在一台机器上（默认 127.0.0.1:8848），但可以管多台。模型很简单：
#
#     站点 = 节点 + 域名 + 上游
#
#   · local  就是面板所在的这台，直接本机调 add-site.sh
#   · 其余节点通过 ssh 连过去，对方 authorized_keys 里的 command= 会强制把会话
#     交给 node-agent.sh，只放行 list / add / remove / certs / status 五个动作
#
# 凭据只有一把：面板自己生成的 ed25519 私钥（NODES_KEY）。节点侧只放公钥，
# 而且带 command= 限制 —— 所以这把私钥即使泄漏，能做的事也被锁在那五个动作里，
# 不会升级成「所有被纳管机器的 root」。
#
# ⚠️ 两个和 systemd 沙箱有关的坑：
#   1. admin-api.service 是 ProtectSystem=strict + ReadWritePaths=/etc/caddy，
#      所以 nodes.json 和密钥必须落在 /etc/caddy 下面，放别处写不进去。
#   2. 同一个单元里还有 ProtectHome=yes，$HOME 不可用 —— ssh 不能靠 ~/.ssh，
#      所以下面显式给 HOME=/etc/caddy/nodes 和 UserKnownHostsFile。

NODES_FILE = os.environ.get("NODES_FILE", "/etc/caddy/nodes.json")
NODES_KEY = os.environ.get("NODES_KEY", "/etc/caddy/nodes/nodes_ed25519")
NODES_KNOWN_HOSTS = os.environ.get("NODES_KNOWN_HOSTS", "/etc/caddy/nodes/known_hosts")
NODE_SSH_TIMEOUT = int(os.environ.get("NODE_SSH_TIMEOUT", "8"))

RE_NODE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$")
RE_IPV4 = re.compile(r"^[0-9]{1,3}(\.[0-9]{1,3}){3}$")

MOCK_NODES = [
    {"name": "demo-node", "host": "203.0.113.84", "port": 22, "user": "root"},
]


def _read_nodes():
    if MOCK:
        return [dict(n) for n in MOCK_NODES]
    try:
        with open(NODES_FILE, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return []
    if not isinstance(data, list):
        return []
    return [n for n in data if isinstance(n, dict) and n.get("name") and n.get("host")]


def _write_nodes(nodes):
    if MOCK:
        MOCK_NODES[:] = nodes
        return
    d = os.path.dirname(NODES_FILE)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    fd = os.open(NODES_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(nodes, fh, ensure_ascii=False, indent=2)
    os.chmod(NODES_FILE, 0o600)


def ensure_node_key():
    """面板的节点私钥 —— 只在缺失时生成一次。返回公钥文本（拿不到就空串）。
    这是幂等的：已经存在就只读公钥，不会重新生成（否则所有节点都要重授权）。"""
    if MOCK:
        return "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDEMOonlyNotARealKeypanel panel@domain-autopilot"
    if not os.path.isfile(NODES_KEY):
        d = os.path.dirname(NODES_KEY)
        try:
            if d and not os.path.isdir(d):
                os.makedirs(d, exist_ok=True)
            if d:
                os.chmod(d, 0o700)
        except OSError:
            return ""
        rc, _, _ = sh("ssh-keygen -t ed25519 -N '' -C panel@domain-autopilot -f %s -q"
                      % shellquote(NODES_KEY), timeout=20)
        if rc != 0:
            return ""
    try:
        os.chmod(NODES_KEY, 0o600)
    except OSError:
        pass
    try:
        with open(NODES_KEY + ".pub", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def find_node(name):
    """按名字取节点。空 / "local" 都当本机；找不到返回 None。"""
    if not name or name == "local":
        return {"name": "local", "host": "127.0.0.1", "local": True}
    for n in _read_nodes():
        if n.get("name") == name:
            node = dict(n)
            node["local"] = False
            return node
    return None


def all_nodes():
    return [{"name": "local", "host": "127.0.0.1", "local": True}] + \
           [dict(n, local=False) for n in _read_nodes()]


def node_ssh(node, remote):
    """拼 ssh 命令行。remote 会原样落到对方的 $SSH_ORIGINAL_COMMAND 里，
    由 node-agent.sh 白名单解析 —— 所以 remote 只能是我们自己构造的固定形态，
    绝不接受前端传来的任意字符串。"""
    return ("HOME=/etc/caddy/nodes ssh -i %s -p %s"
            " -o BatchMode=yes -o IdentitiesOnly=yes"
            " -o StrictHostKeyChecking=accept-new"
            " -o UserKnownHostsFile=%s"
            " -o PasswordAuthentication=no -o ConnectionAttempts=1"
            " -o ConnectTimeout=%d -o ServerAliveInterval=15 -o ServerAliveCountMax=3"
            " %s@%s %s"
            % (shellquote(NODES_KEY), shellquote(str(node.get("port") or 22)),
               shellquote(NODES_KNOWN_HOSTS), NODE_SSH_TIMEOUT,
               shellquote(node.get("user") or "root"),
               shellquote(node["host"]),
               shellquote(remote)))


def run_on_node(node, remote, timeout=30):
    if node.get("local"):
        return 1, "", "内部错误：local 节点不该走 ssh"
    return sh(node_ssh(node, remote), timeout=timeout)


def node_list_sites(node):
    """返回 (sites, error)。sites 为 None 表示这个节点够不着。"""
    if MOCK:
        if node.get("local"):
            return [dict(s, node="local") for s in MOCK_SITES], ""
        return ([{"domain": "demo.example.com", "upstream": "127.0.0.1:8080",
                  "dns01": True, "auth": True, "file": "demo.example.com.conf",
                  "node": node["name"], "raw": ""}], "")
    if node.get("local"):
        return list_sites(), ""
    rc, out, err = run_on_node(node, "list", timeout=NODE_SSH_TIMEOUT + 10)
    if rc != 0:
        return None, err or out or "ssh 连接失败"
    sites = []
    for line in out.splitlines():
        # ⚠️ 这里只能用 >= 2，不能要求 3 段。
        # 原因：sh() 会对整段 stdout 做一次 .strip()，而它只作用于**字符串末尾** ——
        # 也就是只吃掉最后一行的收尾空白。node-agent 的 list 在「站点没有标记」时
        # 第三个字段为空，行尾就带一个 TAB；如果这行恰好是最后一行，TAB 被 strip 掉，
        # split 只剩 2 段，于是这个站点被静默丢弃（表现为随机少一个站点，极难查）。
        parts = line.split("\t")
        if len(parts) < 2 or not parts[0].strip():
            continue
        flags = parts[2] if len(parts) > 2 else ""
        sites.append({
            "domain": parts[0].strip(),
            "upstream": parts[1].strip(),
            "dns01": "dns01" in flags,
            "auth": "auth" in flags,
            "file": parts[0].strip() + ".conf",
            "node": node["name"],
            "raw": "",
        })
    return sites, ""


def list_all_sites():
    """聚合所有节点的站点，并附带每个节点的可达性报告。"""
    out, reports = [], []
    for n in all_nodes():
        sites, err = node_list_sites(n)
        reports.append({
            "name": n["name"], "host": n.get("host"), "local": bool(n.get("local")),
            "ok": sites is not None, "error": err or "", "count": len(sites or []),
        })
        out.extend(sites or [])
    return out, reports


def parse_openssl_date(raw):
    """解析 openssl -enddate 的默认输出：Dec 26 03:10:45 2026 GMT"""
    if not raw:
        return None
    txt = re.sub(r"\s+", " ", raw.strip().replace(" GMT", "")).strip()
    try:
        return datetime.datetime.strptime(txt, "%b %d %H:%M:%S %Y").replace(
            tzinfo=datetime.timezone.utc)
    except ValueError:
        return None


def get_all_certs():
    """跨节点汇总证书。远端读不到就跳过该节点 —— 证书到期只是告警信息，
    不该因为某台机器暂时不通就让整个面板的数据区空掉。"""
    if MOCK:
        return get_certs()
    now = datetime.datetime.now(datetime.timezone.utc)
    out = []
    for n in all_nodes():
        if n.get("local"):
            out.extend(get_certs())
            continue
        rc, res, _ = run_on_node(n, "certs", timeout=NODE_SSH_TIMEOUT + 10)
        if rc != 0:
            continue
        for line in (res or "").splitlines():
            parts = line.split("\t")
            if len(parts) < 2 or not parts[0].strip():
                continue
            dt = parse_openssl_date(parts[1])
            days = int((dt - now).total_seconds() // 86400) if dt else None
            out.append({"name": parts[0].strip(),
                        "expires": dt.isoformat() if dt else None,
                        "days": days, "node": n["name"]})
    out.sort(key=lambda c: (c["days"] is None, c["days"]))
    return out


def node_status(node):
    if node.get("local"):
        st = get_status()
        return {"ok": True, "info": {"caddy": st.get("caddy"), "version": st.get("version"),
                                     "hostname": "local(本机)",
                                     "sites": st.get("siteCount")}}
    rc, out, err = run_on_node(node, "status", timeout=NODE_SSH_TIMEOUT + 10)
    if rc != 0:
        return {"ok": False, "error": err or out or "ssh 连接失败"}
    info = {}
    for line in out.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            info[k.strip()] = v.strip()
    return {"ok": True, "info": info}


def node_add(payload):
    name = (payload.get("name") or "").strip()
    host = (payload.get("host") or "").strip()
    user = (payload.get("user") or "root").strip()
    try:
        port = int(payload.get("port") or 22)
    except (TypeError, ValueError):
        return {"ok": False, "bad_request": True, "error": "端口要是数字"}
    if not name or not host:
        return {"ok": False, "bad_request": True, "error": "节点名和主机地址都要填"}
    if name == "local":
        return {"ok": False, "bad_request": True, "error": "local 是保留名，代表本机"}
    if not RE_NODE_NAME.match(name):
        return {"ok": False, "bad_request": True,
                "error": "节点名只能用字母数字和 . _ -（不超过 32 位）"}
    if re.search(r"\s", host):
        return {"ok": False, "bad_request": True, "error": "主机地址不能含空格"}
    if not 1 <= port <= 65535:
        return {"ok": False, "bad_request": True, "error": "端口超出 1-65535"}
    if re.search(r"[\s@:]", user):
        return {"ok": False, "bad_request": True, "error": "用户名不能含空格、@ 或冒号"}
    ok_host = (re.match(r"^[A-Za-z0-9]([A-Za-z0-9_.-]*[A-Za-z0-9])?$", host)
               or RE_IPV4.match(host)
               or re.match(r"^\[?[0-9a-fA-F:]+\]?$", host))
    if not ok_host:
        return {"ok": False, "bad_request": True, "error": "主机地址格式不对"}

    entry = {"name": name, "host": host, "port": port, "user": user}
    nodes = _read_nodes()
    for i, n in enumerate(nodes):
        if n.get("name") == name:
            nodes[i] = entry
            _write_nodes(nodes)
            return {"ok": True, "output": "已更新节点 %s" % name,
                    "publicKey": ensure_node_key()}
    nodes.append(entry)
    _write_nodes(nodes)
    return {"ok": True, "output": "已添加节点 %s" % name, "publicKey": ensure_node_key()}


def node_remove(name):
    nodes = _read_nodes()
    left = [n for n in nodes if n.get("name") != name]
    if len(left) == len(nodes):
        return {"ok": False, "bad_request": True, "error": "没有这个节点：%s" % name}
    _write_nodes(left)
    return {"ok": True,
            "output": "已从面板移除节点 %s\n"
                      "注意：对方 authorized_keys 里的那把公钥不会自动删，要自己去清掉" % name}


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

    def _query(self):
        if "?" not in self.path:
            return {}
        return dict(parse_qsl(self.path.split("?", 1)[1], keep_blank_values=True))

    def do_GET(self):
        path = self.path.split("?", 1)[0]

        if path in ("/", "/ui", "/index.html"):
            return self._html()
        if path == "/api/ping":
            return self._json({"ok": True, "version": VERSION, "mock": MOCK, "time": now_iso()})
        if path == "/api/status":
            return self._json(get_status())
        if path == "/api/nodes":
            nodes = all_nodes()
            for n in nodes:
                n["keyReady"] = os.path.isfile(NODES_KEY) if not MOCK else True
            return self._json({
                "nodes": nodes,
                "publicKey": ensure_node_key(),
                "keyPath": NODES_KEY,
                "nodesFile": NODES_FILE,
                "mock": MOCK,
            })
        if path == "/api/sites":
            sites, reports = list_all_sites()
            certs = {c["name"]: c for c in get_all_certs()}
            for s in sites:
                c = certs.get(s["domain"]) or certs.get("*." + ".".join(s["domain"].split(".")[1:]))
                s["certDays"] = c["days"] if c else None
                s["certExpires"] = c["expires"] if c else None
            return self._json({"sites": sites, "nodes": reports, "mock": MOCK})
        if path == "/api/certs":
            return self._json({"certs": get_all_certs()})
        if path == "/api/probe":
            # 只探「面板本机」这个视角。节点不是 local 时前端不调它 ——
            # 那时用户已经明确指定了机器，可达性取决于那台机器，本机探出来没意义。
            #
            # 注意「探不通」不是错误：它是正常结果（ok=true + reachable=false），
            # 只有参数本身不对才回 400。
            up = self._query().get("upstream") or ""
            if not up.strip():
                return self._json({"ok": False, "bad_request": True,
                                   "error": "缺 upstream 参数"}, 400)
            res = probe_upstream(up)
            code = 200 if res.get("ok") else (400 if res.get("bad_request") else 500)
            return self._json(res, code)
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
        if path == "/api/nodes":
            res = node_add(body)
            code = 200 if res.get("ok") else (400 if res.get("bad_request") else 500)
            return self._json(res, code)
        m = re.match(r"^/api/nodes/([^/]+)/test$", path)
        if m:
            name = unquote(m.group(1))
            node = find_node(name)
            if node is None:
                return self._json({"ok": False, "bad_request": True,
                                   "error": "没有这个节点：%s" % name}, 400)
            res = node_status(node)
            return self._json(res, 200 if res.get("ok") else 500)
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
        if path.startswith("/api/nodes/"):
            res = node_remove(unquote(path[len("/api/nodes/"):]))
            code = 200 if res.get("ok") else (400 if res.get("bad_request") else 500)
            return self._json(res, code)
        if path.startswith("/api/sites/"):
            domain = unquote(path[len("/api/sites/"):])
            # 站点归属哪个节点靠 query 带过来：/api/sites/xxx?node=chuncheon
            # 不带就是本机，兼容老前端。
            node_name = self._query().get("node") or "local"
            return self._json(remove_site(node_name, domain))
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
