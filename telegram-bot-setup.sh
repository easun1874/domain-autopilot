#!/usr/bin/env bash
# telegram-bot-setup.sh - 配置并安装 domain-autopilot 的 Telegram 机器人
#
# 用法（VPS 上，root）：
#   bash telegram-bot-setup.sh                  # 交互式：隐藏输入 Token，自动探测你的 Telegram ID
#   bash telegram-bot-setup.sh 123456789        # 直接指定你的 Telegram 用户 ID
#   bash telegram-bot-setup.sh --status         # 看当前配置和服务状态
#   bash telegram-bot-setup.sh --uninstall      # 卸载（保留 telegram.env，里面是你的 Token）
#
# 非交互（Token 别放进命令行——会进 shell 历史和进程列表，用环境变量或文件）：
#   TELEGRAM_BOT_TOKEN=xxx TELEGRAM_ALLOWED_IDS=123 bash telegram-bot-setup.sh
#
# 幂等：跑多少次都一样，换 Token 或改白名单直接重跑。
set -euo pipefail

ENV_FILE="/etc/caddy/telegram.env"
LIB_DIR="/usr/local/lib/caddy"
UNIT="/etc/systemd/system/telegram-bot.service"
SERVICE="telegram-bot"
API="https://api.telegram.org"

log()  { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
info() { printf '\033[36m[--]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[!!]\033[0m %s\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Token 通过环境变量递给 python，绝不出现在 argv 里（argv 会进 ps）
tg_api() {
	TELEGRAM_BOT_TOKEN="${TG_TOKEN:-}" python3 - "$1" "${2:-}" <<'PY'
import json, os, sys, urllib.parse, urllib.request
method = sys.argv[1]
extra = json.loads(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else {}
url = "https://api.telegram.org/bot%s/%s" % (os.environ.get("TELEGRAM_BOT_TOKEN", ""), method)
data = urllib.parse.urlencode(extra).encode()
try:
    with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=30) as r:
        sys.stdout.write(r.read().decode("utf-8", "replace"))
except Exception as e:
    sys.stdout.write(json.dumps({"ok": False, "description": str(e)}))
PY
}

jstr() {
	# 从 stdin 的 JSON 里取一个顶层字段，取不到就输出空串。不用 eval。
	python3 -c '
import json, sys
key = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit()
v = d.get(key)
print("" if v is None else v)
' "$1" 2>/dev/null || true
}

jname() {
	# 取 result.username
	python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit()
print((d.get("result") or {}).get("username", ""))
' 2>/dev/null || true
}

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- 前置检查

[ "$(id -u)" -eq 0 ] || { err "请用 root 执行：sudo -i 然后 bash telegram-bot-setup.sh"; exit 1; }
command -v python3 >/dev/null 2>&1 || { err "缺 python3，先跑 setup.sh"; exit 1; }

case "${1:-}" in
	-h | --help) usage; exit 0 ;;
	--status)
		echo "== 配置 =="
		if [ -s "$ENV_FILE" ]; then
			echo "  文件：$ENV_FILE（$(stat -c '%a %U:%G' "$ENV_FILE")）"
			# 只露前 8 位，后面整段砍掉 —— 别让 --status 把 Token 打出来
			echo "  Token：$(grep -oP '^TELEGRAM_BOT_TOKEN=\K.{8}' "$ENV_FILE" 2>/dev/null || true)…（已隐藏，共 $(grep -oP '^TELEGRAM_BOT_TOKEN=\K.*' "$ENV_FILE" 2>/dev/null | tr -d '\n' | wc -c) 字符）"
			echo "  白名单：$(grep -oP '^TELEGRAM_ALLOWED_IDS=\K.*' "$ENV_FILE" || echo '（空——任何人都无法执行动作）')"
		else
			echo "  未配置（$ENV_FILE 不存在）"
		fi
		echo "== 服务 =="
		systemctl status "$SERVICE" --no-pager 2>&1 | head -6 || true
		exit 0
		;;
	--uninstall)
		info "停止并禁用 $SERVICE"
		systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
		rm -f "$UNIT" "$LIB_DIR/telegram-bot.py"
		systemctl daemon-reload >/dev/null 2>&1 || true
		log "已卸载。凭据文件保留在 $ENV_FILE（里面有你的 Token），要删自己删：rm -f $ENV_FILE"
		exit 0
		;;
	--*)
		err "未知参数：$1"; usage; exit 1
		;;
esac

if [ ! -d /run/systemd/system ]; then
	err "没有 systemd，这个脚本装不了。手动跑：python3 $LIB_DIR/telegram-bot.py"
	exit 1
fi

# ---------------------------------------------------------------- 1/5 Token

echo "== 1/5 获取 Bot Token =="
TG_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
if [ -z "$TG_TOKEN" ] && [ -s "$ENV_FILE" ]; then
	TG_TOKEN="$(grep -oP '^TELEGRAM_BOT_TOKEN=\K.*' "$ENV_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
	[ -n "$TG_TOKEN" ] && info "沿用 $ENV_FILE 里已有的 Token（要换就直接粘贴新的）"
fi
read -rsp "  粘贴 Telegram Bot Token（输入不可见，回车继续）: " TOKEN_INPUT || true
echo
[ -n "$TOKEN_INPUT" ] && TG_TOKEN="$(printf '%s' "$TOKEN_INPUT" | tr -d '[:space:]')"
if [ -z "$TG_TOKEN" ]; then
	err "没有 Token。去 Telegram 找 @BotFather：/newbot → 起名字 → 拿 Token"
	exit 1
fi

info "校验 Token…"
ME="$(tg_api getMe)"
if [ "$(printf '%s' "$ME" | jstr ok)" != "True" ]; then
	err "Token 无效：$(printf '%s' "$ME" | jstr description)"
	err "确认整段都复制了（形如 123456789:AAE...），中间别漏字符"
	exit 1
fi
BOT_NAME="$(printf '%s' "$ME" | jname)"
log "Token 有效：@$BOT_NAME"

# ---------------------------------------------------------------- 2/5 白名单

echo "== 2/5 设置授权用户 =="
ALLOWED="${TELEGRAM_ALLOWED_IDS:-}"
if [ -z "$ALLOWED" ] && [ -s "$ENV_FILE" ]; then
	ALLOWED="$(grep -oP '^TELEGRAM_ALLOWED_IDS=\K.*' "$ENV_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
fi
[ $# -ge 1 ] && ALLOWED="$1"

if [ -n "$ALLOWED" ]; then
	log "使用指定白名单：$ALLOWED"
else
	echo
	info "接下来自动探测你的 Telegram 用户 ID（不用去别处查）："
	echo "  1) 在 Telegram 里搜索 @$BOT_NAME 并打开它"
	echo "  2) 随便发一条消息过去（发 /start 就行）"
	echo "  3) 我在这里等你，最多 90 秒"
	echo
	printf '  等待中'
	DETECTED=""
	for _ in $(seq 1 9); do
		UPD="$(tg_api getUpdates '{"timeout":10}')"
		DETECTED="$(printf '%s' "$UPD" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit()
for u in (d.get("result") or []):
    m = u.get("message") or {}
    f = m.get("from") or {}
    if f.get("id") and m.get("text"):
        print("%s|%s" % (f["id"], f.get("username") or f.get("first_name") or ""))
        break
' 2>/dev/null || true)"
		[ -n "$DETECTED" ] && break
		printf '.'
	done
	echo
	if [ -n "$DETECTED" ]; then
		D_ID="${DETECTED%%|*}"
		D_WHO="${DETECTED##*|}"
		log "探测到：${D_WHO:+@$D_WHO }ID=$D_ID"
		read -rp "  用它吗？[Y/n] " YN || true
		if [ "${YN:-Y}" != "n" ] && [ "${YN:-Y}" != "N" ]; then
			ALLOWED="$D_ID"
		fi
	fi
fi

if [ -z "$ALLOWED" ]; then
	err "白名单为空。机器人会启动，但任何人都只能收到自己的 ID、无法执行动作。"
	err "之后补：编辑 $ENV_FILE 里的 TELEGRAM_ALLOWED_IDS，再 systemctl restart $SERVICE"
fi

# ---------------------------------------------------------------- 3/5 写配置

echo "== 3/5 写入配置 =="
mkdir -p /etc/caddy
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_IDS=%s\n' "$TG_TOKEN" "${ALLOWED:-}" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
chmod 700 /etc/caddy
log "$ENV_FILE 已写入（600）"

# ---------------------------------------------------------------- 4/5 装文件

echo "== 4/5 安装程序与单元 =="
install -d -m 755 "$LIB_DIR"
if [ -f "$SCRIPT_DIR/telegram-bot.py" ]; then
	install -m 755 "$SCRIPT_DIR/telegram-bot.py" "$LIB_DIR/telegram-bot.py"
	install -m 644 "$SCRIPT_DIR/telegram-bot.service" "$UNIT"
else
	# 从安装目录里的源码副本拉起（update.sh 会同步到 /opt/domain-autopilot）
	SRC="${INSTALL_DIR:-/opt/domain-autopilot}"
	[ -f "$SRC/telegram-bot.py" ] || { err "找不到 telegram-bot.py"; exit 1; }
	install -m 755 "$SRC/telegram-bot.py" "$LIB_DIR/telegram-bot.py"
	install -m 644 "$SRC/telegram-bot.service" "$UNIT"
fi
log "telegram-bot.py → $LIB_DIR/，单元 → $UNIT"

# ---------------------------------------------------------------- 5/5 启动

echo "== 5/5 启动服务 =="
systemctl daemon-reload
systemctl enable --now "$SERVICE" >/dev/null 2>&1 || true
sleep 3
if systemctl is-active "$SERVICE" >/dev/null 2>&1; then
	log "服务运行中"
	journalctl -u "$SERVICE" -n 6 --no-pager 2>/dev/null | sed 's/^/    /' || true
else
	err "服务没起来，看：journalctl -u $SERVICE -n 50"
	exit 1
fi

echo
echo "==================== Telegram 机器人就绪 ===================="
cat <<EOF
在 Telegram 里打开 @$BOT_NAME，直接发：
  /add                        一步步问你域名和上游
  /add oci.example.com 127.0.0.1:8787     一行写完
  /list                       看现有站点

排错：
  bash $0 --status                  # 看配置与服务状态
  journalctl -u $SERVICE -f         # 实时日志
  改 Token / 白名单：重跑本脚本，或编辑 $ENV_FILE 后 systemctl restart $SERVICE
卸载：
  bash $0 --uninstall
EOF
