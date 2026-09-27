#!/usr/bin/env python3
# telegram-bot.py - domain-autopilot 的 Telegram 交互入口
#
# 用 Telegram 加站点，不用再开 SSH 隧道去开网页面板。对你的日常用法
# （只要一个域名 + 一个上游地址）来说，比面板少好几步。
#
# 用法（装好后）：
#   /add                        交互式：先问域名，再问上游，回显确认后执行
#   /add oci.example.com 127.0.0.1:8787     一行式，直接进确认
#   /list                       列出现有站点
#   /cancel                     放弃当前这次添加
#
# 三条设计原则（改代码时别违反）：
#   1. 不重新实现任何逻辑 —— 只拼 `add-site.sh <域名> <上游>` 去调它，
#      和 admin-api.py（网页面板）走完全相同的路径，行为天然一致。
#      所以改 add-site.sh 的行为，机器人这边自动跟着变。
#   2. 只用标准库（urllib.request 长轮询），不在 VPS 上装任何 Python 包。
#      VPS 上只有 python3 一个运行时，装依赖会引入 apt/pip 的额外失败面。
#   3. 白名单鉴权。只有 TELEGRAM_ALLOWED_IDS 里的用户能操作。
#      未授权用户发消息时只回他自己的 ID（方便首次配置），绝不执行动作。
#
# 配置：/etc/caddy/telegram.env（600），由 telegram-bot-setup.sh 生成
#   TELEGRAM_BOT_TOKEN=123456:ABC-DEF...
#   TELEGRAM_ALLOWED_IDS=123456789,987654321
#
# 环境变量：
#   TELEGRAM_API_BASE   默认 https://api.telegram.org（自建反代时可改）
#   ADD_SITE_BIN        默认 /usr/local/bin/add-site.sh
#   SITES_DIR           默认 /etc/caddy/sites

import html
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API_BASE = os.environ.get("TELEGRAM_API_BASE", "https://api.telegram.org").rstrip("/")
ADD_SITE_BIN = os.environ.get("ADD_SITE_BIN", "/usr/local/bin/add-site.sh")
SITES_DIR = os.environ.get("SITES_DIR", "/etc/caddy/sites")
TOKEN = (os.environ.get("TELEGRAM_BOT_TOKEN") or "").strip()
ALLOWED = [x.strip() for x in (os.environ.get("TELEGRAM_ALLOWED_IDS") or "").split(",") if x.strip()]

POLL_TIMEOUT = 25          # getUpdates 长轮询秒数
HTTP_TIMEOUT = POLL_TIMEOUT + 15
ADD_SITE_TIMEOUT = 180     # add-site.sh 会建 DNS、校验、reload，给足时间
MAX_MSG = 3900             # Telegram 上限 4096，留点余量

ANSI = re.compile(r"\x1b\[[0-9;]*m")

# 域名：至少两段，允许 xn-- 国际化写法。故意严格 —— 这个值要传给 subprocess，
# 虽然我们用参数列表（不走 shell）不担心注入，但脏输入会让 add-site.sh 写出坏配置。
RE_DOMAIN = re.compile(
    r"^(?=.{1,253}$)(?!-)[A-Za-z0-9-]{1,63}(?<!-)"
    r"(?:\.(?!-)[A-Za-z0-9-]{1,63}(?<!-))+$"
)
# 上游：host:port / scheme://host:port / unix//path。允许 IPv6 加方括号。
# 用正则 + 一个函数而不是单条正则 —— 因为「无端口」这种错只有结合是否有 scheme
# 才能判定（https://backend 合法、127.0.0.1 不合法，Caddy 会报缺端口）。
RE_UNIX = re.compile(r"^unix//\S+$")
RE_UPSTREAM = re.compile(
    r"^(?:(?P<scheme>[a-z][a-z0-9+.\-]*)://)?"
    r"(?P<host>\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9_.\-]+)"
    r"(?::(?P<port>\d{1,5}))?$"
)


def valid_upstream(u):
    u = (u or "").strip()
    if not u or re.search(r"\s", u):
        return False
    if RE_UNIX.match(u):
        return True
    m = RE_UPSTREAM.match(u)
    if not m:
        return False
    if m.group("port"):
        return 1 <= int(m.group("port")) <= 65535
    # 没写端口就必须写 scheme（Caddy 才能推出默认端口）；裸 127.0.0.1 会被 Caddy 拒
    return bool(m.group("scheme"))

STATE = {}                 # chat_id -> {"step": ..., "domain": ..., "upstream": ...}


def log(msg):
    print("[%s] %s" % (time.strftime("%F %T"), msg), flush=True)


def strip_ansi(s):
    return ANSI.sub("", s or "")


def esc(s):
    return html.escape(s or "", quote=False)


def truncate(s, limit=MAX_MSG):
    s = s or ""
    if len(s) <= limit:
        return s
    return s[: limit - 30] + "\n…（输出过长已截断）"


# ---------------------------------------------------------------- Telegram API

def api(method, **params):
    """调一次 Bot API。返回 result；失败返回 None 并打日志（不抛，机器人要能扛住抖动）。"""
    url = "%s/bot%s/%s" % (API_BASE, TOKEN, method)
    data = urllib.parse.urlencode(params, doseq=True).encode("utf-8")
    req = urllib.request.Request(url, data=data)
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            payload = json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", "replace")[:300]
        except Exception:
            pass
        log("API %s 失败 HTTP %s %s" % (method, e.code, body))
        return None
    except Exception as e:                                   # 网络抖动、超时
        log("API %s 网络异常: %s" % (method, e))
        return None
    if not payload.get("ok"):
        log("API %s 返回错误: %s" % (method, payload.get("description")))
        return None
    return payload.get("result")


def send(chat_id, text, keyboard=None, reply_to=None):
    params = {
        "chat_id": chat_id,
        "text": truncate(text),
        "parse_mode": "HTML",
        "disable_web_page_preview": "true",
    }
    if reply_to:
        params["reply_to_message_id"] = reply_to
    if keyboard:
        params["reply_markup"] = json.dumps(keyboard)
    res = api("sendMessage", **params)
    return res.get("message_id") if isinstance(res, dict) else None


def edit(chat_id, message_id, text, keyboard=None):
    params = {
        "chat_id": chat_id,
        "message_id": message_id,
        "text": truncate(text),
        "parse_mode": "HTML",
        "disable_web_page_preview": "true",
    }
    if keyboard:
        params["reply_markup"] = json.dumps(keyboard)
    else:
        params["reply_markup"] = json.dumps({"inline_keyboard": []})
    api("editMessageText", **params)


def typing(chat_id):
    api("sendChatAction", chat_id=chat_id, action="typing")


# ---------------------------------------------------------------- 业务动作

def sh(args, timeout=20):
    """跑外部命令。只用参数列表，绝不拼 shell 字符串。"""
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "命令超时（%ss）" % timeout
    except FileNotFoundError:
        return 127, "找不到命令：%s" % args[0]
    except Exception as e:
        return 1, "执行失败：%s" % e


def list_sites():
    """直接读 /etc/caddy/sites/*.conf —— 与 admin-api.py 的 parse_conf 同源同口径。"""
    out = []
    try:
        names = sorted(os.listdir(SITES_DIR))
    except OSError as e:
        return None, str(e)
    for name in names:
        if not name.endswith(".conf"):
            continue
        path = os.path.join(SITES_DIR, name)
        domain, upstream, mode = name[:-5], "", "?"
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        m = re.search(r"^\s*reverse_proxy\s+(\S+)", text, re.M)
        if m:
            upstream = m.group(1)
        mode = "DNS-01" if "dns cloudflare" in text else "HTTP-01"
        out.append({"domain": domain, "upstream": upstream, "mode": mode})
    return out, None


def check_origin(domain, tries=9, delay=5):
    """证书签发是异步的，直接问源站拿状态码（绕过 DNS 传播和本机代理）。"""
    args = [
        "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
        "--max-time", "8",
        "--resolve", "%s:443:127.0.0.1" % domain,
        "https://%s/" % domain,
    ]
    last = ""
    for i in range(tries):
        rc, out = sh(args, timeout=15)
        last = (out or "").strip()
        if rc == 0 and last.isdigit() and last != "000":
            return last, i + 1
        time.sleep(delay)
    return (last or "无响应"), tries


def do_add(chat_id, domain, upstream, ack_id):
    typing(chat_id)
    edit(chat_id, ack_id, "⏳ <b>正在添加…</b>\n\n域名：<code>%s</code>\n上游：<code>%s</code>"
         "\n\n正在建 DNS 记录、写 Caddy 配置并热加载，约 10~40 秒。"
         % (esc(domain), esc(upstream)))

    rc, output = sh([ADD_SITE_BIN, domain, upstream], timeout=ADD_SITE_TIMEOUT)
    output = strip_ansi(output).strip()

    if rc != 0:
        tail = "\n".join(output.splitlines()[-12:]) or "（无输出）"
        edit(chat_id, ack_id,
             "❌ <b>添加失败</b>（退出码 %s）\n\n域名：<code>%s</code>\n上游：<code>%s</code>\n\n"
             "<b>add-site.sh 输出：</b>\n<pre>%s</pre>\n\n"
             "常见原因：域名写错 / Cloudflare 里没有这个域 / 上游服务没在跑。"
             % (rc, esc(domain), esc(upstream), esc(tail)))
        return

    typing(chat_id)
    edit(chat_id, ack_id, "✅ 配置已写入，正在等证书签发…\n\n域名：<code>%s</code>" % esc(domain))

    code, rounds = check_origin(domain)

    if code.startswith("2") or code.startswith("3"):
        head = "✅ <b>站点已就绪</b>"
        note = "证书已签发，源站应答正常。"
    elif code == "502" or code == "503":
        head = "🟡 <b>站点已配置，但上游连不上</b>"
        note = ("Caddy 和证书都没问题，是 <code>%s</code> 这个上游服务当前没响应。"
                "确认服务在跑、端口没写错。" % esc(upstream))
    elif code == "000" or not code.isdigit():
        head = "🟡 <b>站点已配置，但 HTTPS 还没起来</b>"
        note = ("等了 %s 轮仍未拿到有效响应。可能是证书还在签发，或域名的 DNS 还没指向这台机器。"
                "稍等 1~2 分钟再访问看看。" % rounds)
    else:
        head = "🟡 <b>站点已配置</b>（源站返回 %s）" % esc(code)
        note = "上游活着，但这个状态码不是正常的 2xx/3xx，去上游查一下。"

    edit(chat_id, ack_id,
         "%s\n\n域名：<code>%s</code>\n上游：<code>%s</code>\n\n%s\n\n"
         "打开：https://%s\n全部站点：/list"
         % (head, esc(domain), esc(upstream), note, esc(domain)))


# ---------------------------------------------------------------- 消息处理

def help_text():
    return (
        "<b>domain-autopilot</b>\n"
        "加站点只需域名 + 上游地址，DNS、证书、反代全自动。\n\n"
        "<b>/add</b> — 加一个站点（交互式，一步步问）\n"
        "　　　也可以一行写完：<code>/add oci.example.com 127.0.0.1:8787</code>\n"
        "<b>/list</b> — 列出现有站点\n"
        "<b>/cancel</b> — 放弃当前这次添加\n"
        "<b>/help</b> — 看这条帮助\n\n"
        "上游写法：<code>127.0.0.1:8787</code>、<code>192.168.1.10:3000</code>，"
        "带 <code>http://</code> 也行，但别带路径。\n"
        "默认只建灰云（仅 DNS）记录直连源站，不开 Cloudflare 代理。"
    )


def ask_domain(chat_id, reply_to=None):
    STATE[chat_id] = {"step": "domain"}
    send(chat_id, "请输入<b>域名</b>（例如 <code>oci.example.com</code>）\n\n/cancel 放弃",
         reply_to=reply_to)


def handle_add(chat_id, args, reply_to):
    if len(args) >= 2:
        domain, upstream = args[0].strip().lower(), args[1].strip()
        err = validate(domain, upstream)
        if err:
            send(chat_id, "⚠️ %s" % esc(err), reply_to=reply_to)
            return
        confirm(chat_id, domain, upstream, reply_to)
        return
    if len(args) == 1:
        domain = args[0].strip().lower()
        if not RE_DOMAIN.match(domain):
            send(chat_id, "⚠️ 域名格式不对：<code>%s</code>" % esc(domain),
                 reply_to=reply_to)
            return
        STATE[chat_id] = {"step": "upstream", "domain": domain}
        send(chat_id, "域名：<code>%s</code>\n\n请输入<b>上游地址</b>"
                      "（例如 <code>127.0.0.1:8787</code>）" % esc(domain),
             reply_to=reply_to)
        return
    ask_domain(chat_id, reply_to)


def validate(domain, upstream):
    domain = (domain or "").strip().lower()
    upstream = (upstream or "").strip()
    if not RE_DOMAIN.match(domain):
        return "域名格式不对：%s\n要写完整域名，例如 oci.example.com（不要带 http:// 和斜杠）" % domain
    if not upstream:
        return "上游地址不能为空"
    if not valid_upstream(upstream):
        return ("上游地址格式不对：%s\n"
                "只支持 scheme://主机:端口，不能带路径、不要结尾斜杠；"
                "主机后面要写端口（如 127.0.0.1:8787）" % upstream)
    return None


def confirm(chat_id, domain, upstream, reply_to=None):
    STATE[chat_id] = {"step": "confirm", "domain": domain, "upstream": upstream}
    kb = {"inline_keyboard": [[
        {"text": "✅ 确认添加", "callback_data": "do_add"},
        {"text": "❌ 取消", "callback_data": "do_cancel"},
    ]]}
    send(chat_id,
         "请确认：\n\n域名：<code>%s</code>\n上游：<code>%s</code>\n\n"
         "将自动完成：建 Cloudflare DNS 记录（灰云，直连源站）→ 写 Caddy 配置 → 签 Let's Encrypt 证书。"
         % (esc(domain), esc(upstream)),
         keyboard=kb, reply_to=reply_to)


def show_list(chat_id, reply_to=None):
    sites, err = list_sites()
    if err:
        send(chat_id, "读取 %s 失败：%s" % (esc(SITES_DIR), esc(err)), reply_to=reply_to)
        return
    if not sites:
        send(chat_id, "还没有任何站点。用 /add 加第一个。", reply_to=reply_to)
        return
    lines = ["<b>现有站点（%d 个）</b>\n" % len(sites)]
    for s in sites:
        lines.append("• <code>%s</code> → <code>%s</code>　<i>%s</i>"
                     % (esc(s["domain"]), esc(s["upstream"] or "?"), esc(s["mode"])))
    lines.append("\n加站点：/add")
    send(chat_id, "\n".join(lines), reply_to=reply_to)


def handle_message(msg):
    chat_id = msg["chat"]["id"]
    sender = msg.get("from") or {}
    uid = str(sender.get("id", ""))
    text = (msg.get("text") or "").strip()

    # 群聊里只看 @用户名 触发的，或直接私聊
    if msg["chat"].get("type") != "private":
        send(chat_id, "请私聊我使用。")
        return

    if uid not in ALLOWED:
        who = sender.get("username") and "@" + sender["username"] or sender.get("first_name", "")
        log("未授权访问 chat=%s uid=%s %s" % (chat_id, uid, who))
        if not ALLOWED:
            # 首次配置引导：白名单是空的，把 ID 回给他，让他写进 telegram.env
            send(chat_id,
                 "⚠️ 这个机器人还没配置授权用户。\n\n"
                 "你的 Telegram ID 是：\n<code>%s</code>\n\n"
                 "把这行写进 <code>/etc/caddy/telegram.env</code>：\n"
                 "<code>TELEGRAM_ALLOWED_IDS=%s</code>\n\n"
                 "然后 <code>systemctl restart telegram-bot</code> 即可使用。"
                 % (esc(uid), esc(uid)))
        else:
            send(chat_id, "⛔ 无权限。你的 ID：<code>%s</code>\n如需开通，让管理员把它加进白名单。"
                 % esc(uid))
        return

    if text.startswith("/"):
        parts = text.split()
        cmd = parts[0].split("@")[0].lower()
        args = parts[1:]

        if cmd in ("/start", "/help"):
            STATE.pop(chat_id, None)
            send(chat_id, help_text())
        elif cmd == "/add":
            handle_add(chat_id, args, None)
        elif cmd == "/list":
            show_list(chat_id)
        elif cmd == "/cancel":
            STATE.pop(chat_id, None)
            send(chat_id, "已取消。")
        else:
            send(chat_id, "不认识的命令 <code>%s</code>\n\n%s" % (esc(cmd), help_text()))
        return

    st = STATE.get(chat_id)
    if not st:
        send(chat_id, "我不太明白。用 /add 加站点，/help 看用法。")
        return

    step = st.get("step")
    if step == "domain":
        domain = text.lower()
        if not RE_DOMAIN.match(domain):
            send(chat_id, "⚠️ 域名格式不对：<code>%s</code>\n\n再发一次，"
                          "例如 <code>oci.example.com</code>（/cancel 放弃）" % esc(domain))
            return
        st["domain"] = domain
        st["step"] = "upstream"
        send(chat_id, "域名：<code>%s</code>\n\n请输入<b>上游地址</b>"
                      "（例如 <code>127.0.0.1:8787</code>）" % esc(domain))
    elif step == "upstream":
        upstream = text.strip()
        err = validate(st.get("domain", ""), upstream)
        if err:
            send(chat_id, "⚠️ %s\n\n再发一次（/cancel 放弃）" % esc(err))
            return
        confirm(chat_id, st["domain"], upstream)
    elif step == "confirm":
        send(chat_id, "上一条还等你点按钮确认呢 —— 点「✅ 确认添加」或「❌ 取消」。")
    else:
        STATE.pop(chat_id, None)


def handle_callback(cb):
    uid = str((cb.get("from") or {}).get("id", ""))
    msg = cb.get("message") or {}
    chat_id = (msg.get("chat") or {}).get("id")
    msg_id = msg.get("message_id")
    data = cb.get("data") or ""
    api("answerCallbackQuery", callback_query_id=cb["id"])

    if uid not in ALLOWED:
        log("未授权 callback uid=%s" % uid)
        return
    if chat_id is None or msg_id is None:
        return

    st = STATE.get(chat_id) or {}
    if data == "do_cancel":
        STATE.pop(chat_id, None)
        edit(chat_id, msg_id, "已取消，什么都没改。")
        return

    if data == "do_add":
        domain, upstream = st.get("domain"), st.get("upstream")
        if not domain or not upstream:
            edit(chat_id, msg_id, "这次添加已经过期了，请重新 /add。")
            return
        STATE.pop(chat_id, None)
        do_add(chat_id, domain, upstream, msg_id)


# ---------------------------------------------------------------- 主循环

def main():
    if not TOKEN:
        log("缺少 TELEGRAM_BOT_TOKEN。配置在 /etc/caddy/telegram.env，"
            "或先跑 telegram-bot-setup.sh")
        return 1

    me = api("getMe")
    if not me:
        log("Token 无效或网络不通（api.telegram.org）。先自检："
            "curl -s https://api.telegram.org/bot<token>/getMe")
        return 1
    log("机器人已就绪：@%s (id=%s)" % (me.get("username"), me.get("id")))
    if not ALLOWED:
        log("⚠️ TELEGRAM_ALLOWED_IDS 为空 —— 任何人发消息都只会收到自己的 ID，"
            "不会执行任何动作。去 telegram.env 里补上你的 ID 再重启。")
    else:
        log("授权用户：%s" % ", ".join(ALLOWED))

    # 关键：启动时把积压的旧消息一次性吃掉，避免重启后重放历史指令，
    # 造成重复执行 add-site.sh（重复加同一个站点会覆盖配置、白跑一次签发）。
    backlog = api("getUpdates", offset=-1, timeout=0)
    offset = 0
    if isinstance(backlog, list) and backlog:
        offset = backlog[-1]["update_id"] + 1
        log("跳过 %d 条积压消息，从 offset=%s 开始" % (len(backlog), offset))

    while True:
        try:
            updates = api("getUpdates", offset=offset, timeout=POLL_TIMEOUT,
                          allowed_updates=json.dumps(["message", "callback_query"]))
        except KeyboardInterrupt:
            log("收到中断，退出")
            return 0

        if updates is None:
            time.sleep(5)                     # 网络抖动，等一会再来
            continue
        if not isinstance(updates, list):
            time.sleep(2)
            continue

        for up in updates:
            offset = up["update_id"] + 1
            try:
                if "message" in up:
                    handle_message(up["message"])
                elif "callback_query" in up:
                    handle_callback(up["callback_query"])
            except Exception as e:
                log("处理更新 %s 出错：%s" % (up.get("update_id"), e))
                try:
                    cid = ((up.get("message") or {}).get("chat") or {}).get("id")
                    if cid:
                        send(cid, "⚠️ 处理这条消息时出错了，看服务器日志："
                                  "<code>journalctl -u telegram-bot -n 50</code>")
                except Exception:
                    pass


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
