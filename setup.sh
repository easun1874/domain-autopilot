#!/usr/bin/env bash
# setup.sh - 在 VPS 上一键装好：Caddy 反代 + Cloudflare API 自动化 + 证书自动签发续签 + 管理面板
#
# 用法：
#   bash setup.sh                              # 交互式，会问你要 Token 和邮箱
#   CF_TOKEN=xxx LE_EMAIL=a@b.c bash setup.sh  # 非交互
#   CF_TOKEN_FILE=/root/.cf_token.tmp bash setup.sh   # 从文件读 Token（推荐，Token 不进命令行/进程列表）
#
# 可调环境变量：
#   INSTALL_PANEL=0        不装管理面板（默认 1）
#   ENABLE_CF_NATIVE=0     不自动打开 Caddy 原生 Cloudflare 集成（默认 auto=有 Token 就开）
set -euo pipefail

LE_EMAIL="${LE_EMAIL:-your-email@example.com}"
CF_TOKEN_INPUT="${CF_TOKEN:-}"
CF_TOKEN_FILE="${CF_TOKEN_FILE:-}"
INSTALL_PANEL="${INSTALL_PANEL:-1}"
ENABLE_CF_NATIVE="${ENABLE_CF_NATIVE:-auto}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
info() { printf '\033[36m[--]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[!!]\033[0m %s\n' "$*" >&2; }

if [ "$(id -u)" -ne 0 ]; then err "请用 root 执行：sudo -i 然后 bash setup.sh"; exit 1; fi

# Token 优先级：环境变量 > 文件 > 交互式输入
if [ -z "$CF_TOKEN_INPUT" ] && [ -n "$CF_TOKEN_FILE" ] && [ -s "$CF_TOKEN_FILE" ]; then
	CF_TOKEN_INPUT="$(tr -d '[:space:]' < "$CF_TOKEN_FILE")"
	log "Token 已从 $CF_TOKEN_FILE 读取"
fi

echo "== 1/9 安装 Caddy / jq / python3 =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl jq python3 >/dev/null 2>&1 || apt-get install -y curl jq python3

install_caddy() {
	# 先试发行版源
	if apt-get install -y -qq caddy >/dev/null 2>&1; then return 0; fi
	# 回退到 Caddy 官方 Cloudsmith 源（Debian 源里的版本可能过旧或不含插件）
	info "发行版源没有 caddy，改用 Caddy 官方源"
	apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https >/dev/null 2>&1 || true
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
		| gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
		| tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
	apt-get update -qq
	apt-get install -y -qq caddy >/dev/null 2>&1
}
if command -v caddy >/dev/null 2>&1; then
	log "Caddy 已存在：$(caddy version | head -1)"
elif install_caddy && command -v caddy >/dev/null 2>&1; then
	log "Caddy 已安装：$(caddy version | head -1)"
else
	err "Caddy 安装失败。请手动安装后重跑：https://caddyserver.com/docs/install"
	exit 1
fi

echo "== 2/9 防火墙放行（含 SSH，避免把自己关在门外）=="
# 推断真实 SSH 端口：优先用当前连接的端口，其次 sshd 配置，最后 22
SSH_PORT=""
if [ -n "${SSH_CONNECTION:-}" ]; then
	# shellcheck disable=SC2086
	set -- ${SSH_CONNECTION}
	SSH_PORT="$4"
fi
if [ -z "$SSH_PORT" ]; then
	SSH_PORT="$(grep -Ei '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null \
		| awk '{print $2}' | head -1)"
fi
[ -n "$SSH_PORT" ] || SSH_PORT=22
info "检测到 SSH 端口：$SSH_PORT"

if command -v ufw >/dev/null 2>&1 || apt-get install -y -qq ufw >/dev/null 2>&1; then
	ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
	ufw allow 80/tcp  comment 'HTTP (ACME + 跳转)' >/dev/null
	ufw allow 443/tcp comment 'HTTPS' >/dev/null
	# 面板只监听 127.0.0.1，不放行 8848 —— 走 SSH 隧道访问
	ufw --force enable >/dev/null 2>&1 || true
	log "ufw 已启用，放行：$SSH_PORT / 80 / 443"
	ufw status numbered 2>/dev/null | head -8 || true
else
	err "没有 ufw。请自行在云厂商控制台的安全组里放行 80 / 443 / $SSH_PORT"
fi

echo "== 3/9 写入 Cloudflare API Token =="
if [ -z "$CF_TOKEN_INPUT" ]; then
	read -rsp "  粘贴 Cloudflare API Token（输入不可见，回车继续）: " CF_TOKEN_INPUT
	echo
fi
if [ -z "$CF_TOKEN_INPUT" ]; then
	err "没填 Token。以后补：printf 'CF_API_TOKEN=你的token\n' > /etc/caddy/cf.env && chmod 600 /etc/caddy/cf.env"
else
	# KEY=value 格式：Caddy systemd EnvironmentFile、admin-api.py、cf.sh 三方共用这一个文件
	printf 'CF_API_TOKEN=%s\n' "$(printf '%s' "$CF_TOKEN_INPUT" | tr -d '[:space:]')" > /etc/caddy/cf.env
	chmod 600 /etc/caddy/cf.env
	chmod 700 /etc/caddy
	log "Token 已写入 /etc/caddy/cf.env（600）"
fi

echo "== 4/9 写入 Caddy 配置 =="
mkdir -p /etc/caddy/sites
install -m 644 "$SCRIPT_DIR/Caddyfile" /etc/caddy/Caddyfile
sed -i "s/^[[:space:]]*email .*/\temail ${LE_EMAIL}/" /etc/caddy/Caddyfile
log "主配置就位，站点目录 /etc/caddy/sites"

echo "== 5/9 安装管理脚本 =="
install -d -m 755 /usr/local/lib/caddy
install -m 755 "$SCRIPT_DIR/cf.sh"               /usr/local/lib/caddy/cf.sh
install -m 755 "$SCRIPT_DIR/enable-cf-native.sh" /usr/local/lib/caddy/enable-cf-native.sh
install -m 755 "$SCRIPT_DIR/add-site.sh"         /usr/local/bin/add-site.sh
install -m 755 "$SCRIPT_DIR/sync-dns.sh"         /usr/local/bin/sync-dns.sh
install -m 755 /usr/local/lib/caddy/enable-cf-native.sh /usr/local/bin/enable-cf-native.sh
mkdir -p /var/cache/caddy/cf && chmod 700 /var/cache/caddy/cf
log "cf.sh / add-site.sh / sync-dns.sh / enable-cf-native.sh 已安装"

echo "== 6/9 校验并启动 Caddy =="
caddy fmt --overwrite --config /etc/caddy/Caddyfile
if ! caddy validate --config /etc/caddy/Caddyfile; then
	err "Caddyfile 校验失败，已中止。修完再跑：caddy validate --config /etc/caddy/Caddyfile"
	exit 1
fi
systemctl enable --now caddy >/dev/null 2>&1 || true
systemctl is-active caddy >/dev/null && log "Caddy 运行中" || err "Caddy 未启动，看：journalctl -u caddy -n 50"

echo "== 7/9 注册巡检定时任务 =="
# 每 10 分钟一次：源站 IP 漂移最多 10 分钟内自愈，不用等第二天。
# --quiet 表示没异常就不写日志。装了 dynamic_dns 的话 Caddy 自己 5 分钟改一次，
# 这条保留作兜底，两者不冲突。
( crontab -l 2>/dev/null | grep -v 'sync-dns.sh' || true; \
	echo "*/10 * * * * /usr/local/bin/sync-dns.sh --quiet >> /var/log/caddy-sync.log 2>&1" ) | crontab -
systemctl enable --now cron >/dev/null 2>&1 || true
crontab -l 2>/dev/null | grep -q sync-dns && log "定时任务已注册（每 10 分钟巡检，IP 漂移自动改 DNS）"

echo "== 8/9 打开 Caddy 原生 Cloudflare 集成 =="
CF_NATIVE_DONE=0
if [ "$ENABLE_CF_NATIVE" = "0" ]; then
	info "按配置跳过（ENABLE_CF_NATIVE=0）"
elif [ ! -s /etc/caddy/cf.env ]; then
	info "没有 Token，跳过。补完 Token 后手动跑：enable-cf-native.sh"
else
	# -y 跳过交互确认；Token 已在第 3 步写入 cf.env，脚本会直接复用
	if bash /usr/local/lib/caddy/enable-cf-native.sh -y 2>&1 | tail -6; then
		CF_NATIVE_DONE=1
		log "原生集成已开启（DNS-01 签发 + dynamic_dns 自动维护 A 记录）"
	else
		err "enable-cf-native.sh 未成功，不影响基本反代。稍后手动跑看详情"
	fi
fi
# 报告模块实况——标准版 Caddy 通常没有 dynamic_dns
if caddy list-modules 2>/dev/null | grep -q 'dns.providers.cloudflare'; then
	log "模块 dns.providers.cloudflare：已装（可走 DNS-01）"
else
	info "模块 dns.providers.cloudflare：未装。要泛域名证书/DNS-01 需带插件的构建，见 README 第 12 节"
fi
caddy list-modules 2>/dev/null | grep -q 'dynamic_dns' \
	&& log "模块 dynamic_dns：已装" || info "模块 dynamic_dns：未装（IP 漂移改由 sync-dns.sh 每日兜底）"

echo "== 9/9 安装管理面板 =="
if [ "$INSTALL_PANEL" != "1" ]; then
	info "按配置跳过面板安装"
else
	install -m 755 "$SCRIPT_DIR/admin-api.py"    /usr/local/lib/caddy/admin-api.py
	install -m 644 "$SCRIPT_DIR/admin-ui.html"   /usr/local/lib/caddy/admin-ui.html
	[ -f "$SCRIPT_DIR/README.md" ] && install -m 644 "$SCRIPT_DIR/README.md" /usr/local/lib/caddy/README.md
	if [ -d /run/systemd/system ]; then
		install -m 644 "$SCRIPT_DIR/admin-api.service" /etc/systemd/system/admin-api.service
		systemctl daemon-reload
		systemctl enable --now admin-api >/dev/null 2>&1
		if systemctl is-active admin-api >/dev/null 2>&1; then
			log "面板已启动，监听 127.0.0.1:8848"
		else
			err "面板启动失败，看：journalctl -u admin-api -n 50"
		fi
	else
		info "非 systemd 环境，手动启动：/usr/bin/python3 /usr/local/lib/caddy/admin-api.py"
	fi
fi

echo
echo "==================== 部署完成 ===================="
cat <<EOF
加站点（DNS + 证书 + 反代 全自动）：
  add-site.sh app.example.com 127.0.0.1:8080
  sleep 20 && curl -sI https://app.example.com | head -1

访问管理面板（在你自己电脑上开隧道，不要改监听地址）：
  ssh -L 8848:127.0.0.1:8848 root@$(hostname -I 2>/dev/null | awk '{print $1}' || echo '服务器IP')
  然后浏览器打开 http://localhost:8848

更新这套工具本身（幂等，站点和 Token 都不动）：
  domain-autopilot-update --check    # 先看有没有新版
  domain-autopilot-update

自检：
  bash /usr/local/lib/caddy/cf.sh check      # Cloudflare API 连通性
  systemctl status caddy admin-api --no-pager
EOF
