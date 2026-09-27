#!/usr/bin/env bash
# update.sh - 在 VPS 上把 domain-autopilot 更新到最新版并重装
#
# 用法（VPS 上）：
#   bash update.sh                  # 拉最新代码 → 重装脚本 → reload Caddy
#   bash update.sh --check          # 只看有没有新版本，不动手
#   bash update.sh --no-setup       # 只更新文件和脚本，不跑 setup.sh
#   bash update.sh --no-reload      # 不重启 Caddy / 面板
#
# 幂等：跑多少次都一样，已存在的站点和 /etc/caddy/cf.env 都不会被覆盖丢失。
#
# 环境变量：
#   GITHUB_TOKEN   私有仓库用 PAT 拉取
#   BRANCH         分支（默认 main）
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/domain-autopilot}"
REPO_OWNER="${REPO_OWNER:-easun1874}"
REPO_NAME="${REPO_NAME:-domain-autopilot}"
BRANCH="${BRANCH:-main}"
KEY_FILE="$HOME/.ssh/${REPO_NAME}_ed25519"
API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

CHECK_ONLY=0
DO_SETUP=1
DO_RELOAD=1

log()  { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
info() { printf '\033[36m[--]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[!!]\033[0m %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
	case "$1" in
		--check)     CHECK_ONLY=1; shift ;;
		--no-setup)  DO_SETUP=0; shift ;;
		--no-reload) DO_RELOAD=0; shift ;;
		-h | --help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) err "未知参数: $1"; exit 1 ;;
	esac
done

[ "$(id -u)" -eq 0 ] || { err "请用 root 执行"; exit 1; }
[ -d "$INSTALL_DIR" ] || { err "$INSTALL_DIR 不存在，请先跑 bootstrap.sh"; exit 1; }

cd "$INSTALL_DIR"

# 记录更新前的版本，好对比有没有真的更新
OLD_REV="$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"

echo "== 1/4 拉取最新代码 =="
if [ -d "$INSTALL_DIR/.git" ]; then
	if [ "$CHECK_ONLY" -eq 1 ]; then
		git fetch --depth 1 origin "$BRANCH" >/dev/null 2>&1 || true
		NEW_REV="$(git rev-parse --short "origin/$BRANCH" 2>/dev/null || echo 'unknown')"
		if [ "$OLD_REV" = "$NEW_REV" ]; then
			log "已是最新（$OLD_REV）"
		else
			info "有新版本可用：$OLD_REV → $NEW_REV"
			git --no-pager log --oneline "HEAD..origin/$BRANCH" 2>/dev/null | head -10 || true
		fi
		exit 0
	fi
	git pull --ff-only origin "$BRANCH" 2>&1 | tail -3 || { err "git pull 失败"; exit 1; }
	log "代码已更新"
else
	if [ "$CHECK_ONLY" -eq 1 ]; then
		if [ -n "$GITHUB_TOKEN" ]; then
			REMOTE_SHA="$(curl -fsSL --max-time 20 -H "Authorization: Bearer $GITHUB_TOKEN" \
				-H "Accept: application/vnd.github+json" "$API/commits/$BRANCH" 2>/dev/null \
				| grep -m1 '"sha"' | sed 's/.*"sha": *"\([^"]*\)".*/\1/' | cut -c1-7)" || true
		else
			REMOTE_SHA="$(curl -fsSL --max-time 20 \
				-H "Accept: application/vnd.github+json" "$API/commits/$BRANCH" 2>/dev/null \
				| grep -m1 '"sha"' | sed 's/.*"sha": *"\([^"]*\)".*/\1/' | cut -c1-7)" || true
		fi
		info "远端最新提交：${REMOTE_SHA:-取不到}"
		exit 0
	fi
	tmp="$(mktemp -d)"
	if [ -n "$GITHUB_TOKEN" ]; then
		curl -fsSL --max-time 90 -H "Authorization: Bearer $GITHUB_TOKEN" \
			-H "Accept: application/vnd.github+json" "$API/tarball/$BRANCH" -o "$tmp/src.tar.gz" \
			|| { err "下载失败"; rm -rf "$tmp"; exit 1; }
	else
		info "未提供 GITHUB_TOKEN，尝试公开仓库匿名下载"
		curl -fsSL --max-time 90 \
			"https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${BRANCH}" \
			-o "$tmp/src.tar.gz" \
			|| { err "下载失败：仓库非公开时请先 export GITHUB_TOKEN"; rm -rf "$tmp"; exit 1; }
	fi
	tar xzf "$tmp/src.tar.gz" -C "$INSTALL_DIR" --strip-components=1
	rm -rf "$tmp"
	log "源码包已更新"
fi

NEW_REV="$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
[ "$OLD_REV" != "$NEW_REV" ] && log "版本变化：$OLD_REV → $NEW_REV" || info "版本号未变，仍执行重装确保一致"

echo "== 2/4 重装脚本 =="
for f in cf.sh enable-cf-native.sh install-caddy-modules.sh; do
	install -m 755 "$INSTALL_DIR/$f" "/usr/local/lib/caddy/$f"
done
for f in add-site.sh sync-dns.sh enable-cf-native.sh install-caddy-modules.sh; do
	install -m 755 "$INSTALL_DIR/$f" "/usr/local/bin/$f"
done
# 节点侧白名单执行器：装成 domain-autopilot-node（各节点 authorized_keys 里 command= 指的名字）
if [ -f "$INSTALL_DIR/node-agent.sh" ]; then
	install -m 755 "$INSTALL_DIR/node-agent.sh" /usr/local/bin/domain-autopilot-node
fi
if [ -f "$INSTALL_DIR/update.sh" ]; then
	install -m 755 "$INSTALL_DIR/update.sh" /usr/local/bin/domain-autopilot-update
fi
if [ -f "$INSTALL_DIR/telegram-bot-setup.sh" ]; then
	install -m 755 "$INSTALL_DIR/telegram-bot-setup.sh" /usr/local/lib/caddy/telegram-bot-setup.sh
fi
log "cf.sh / add-site.sh / sync-dns.sh / enable-cf-native.sh 已刷新"

echo "== 3/4 重装面板与 Telegram 机器人 =="
if [ -f "$INSTALL_DIR/admin-api.py" ]; then
	install -m 755 "$INSTALL_DIR/admin-api.py"  /usr/local/lib/caddy/admin-api.py
	install -m 644 "$INSTALL_DIR/admin-ui.html" /usr/local/lib/caddy/admin-ui.html
	[ -f "$INSTALL_DIR/admin-api.service" ] \
		&& install -m 644 "$INSTALL_DIR/admin-api.service" /etc/systemd/system/admin-api.service
	systemctl daemon-reload >/dev/null 2>&1 || true
	systemctl restart admin-api >/dev/null 2>&1 || true
	log "面板已刷新并重启"
fi

# 机器人相关文件分两层对待：
#   程序和 reload 单元 —— 面板要靠它们才能在网页里配机器人，无条件同步
#   机器人本体         —— 只在启用了的机器上重启，别把没用的服务拉到别人机器上跑
if [ -f "$INSTALL_DIR/telegram-bot.py" ]; then
	install -m 755 "$INSTALL_DIR/telegram-bot.py" /usr/local/lib/caddy/telegram-bot.py
	if [ -d /run/systemd/system ]; then
		for u in telegram-bot.service telegram-bot-reload.path telegram-bot-reload.service; do
			# 写成 if 而不是 `[ -f ... ] && install`：后者在文件缺失时返回 1，
			# 在 set -e 下会直接终止整个脚本
			if [ -f "$INSTALL_DIR/$u" ]; then
				install -m 644 "$INSTALL_DIR/$u" "/etc/systemd/system/$u"
			fi
		done
		systemctl daemon-reload >/dev/null 2>&1 || true
		# reload.path 是面板改配置后能自动生效的前提，老机器升级时补上
		systemctl enable --now telegram-bot-reload.path >/dev/null 2>&1 || true
	fi
	# 用 is-enabled 判断"配置过并启用过"，不能用 list-unit-files：
	# 上面刚把单元文件装了进去，那个判断会永远命中。
	if systemctl is-enabled telegram-bot.service >/dev/null 2>&1; then
		systemctl restart telegram-bot >/dev/null 2>&1 || true
		log "Telegram 机器人已刷新并重启"
	else
		info "Telegram 机器人未启用。可在面板里填 Token 开启，或 bash /usr/local/lib/caddy/telegram-bot-setup.sh"
	fi
fi

if [ "$DO_SETUP" -eq 0 ]; then
	log "按 --no-setup 要求跳过 setup.sh"
else
	echo "== 4/4 重跑 setup.sh（幂等，不会动已有站点和 Token）=="
	# cf.env 里已有 Token 就够用，不用再传；setup.sh 会自己复用
	# INSTALL_TELEGRAM=0：机器人已在第 3 步刷新过，这里别再交互问一遍，
	# 免得 domain-autopilot-update 从 TTY 跑时每次都被拦一下。
	# 想装机器人：bash /usr/local/lib/caddy/telegram-bot-setup.sh
	if INSTALL_TELEGRAM=0 bash "$INSTALL_DIR/setup.sh"; then
		log "setup.sh 执行完毕"
	else
		err "setup.sh 报错，看上面输出"
		exit 1
	fi
fi

if [ "$DO_RELOAD" -eq 1 ]; then
	# Caddyfile 里的 {env.CF_API_TOKEN}（启用 CF 原生集成后会写入）在适配期求值，
	# 手动调 caddy 时环境里没有它会被判成无效 Token，这里先载入 cf.env。
	if [ -r /etc/caddy/cf.env ]; then
		set -a
		# shellcheck disable=SC1091
		. /etc/caddy/cf.env
		set +a
	fi
	caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
		&& caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
		&& log "Caddy 配置已热加载（站点无中断）" \
		|| info "Caddy 未重载（可能未安装或配置有误），手动看：caddy validate --config /etc/caddy/Caddyfile"
fi

echo
log "更新完成。$(ls /etc/caddy/sites/*.conf 2>/dev/null | wc -l | tr -d ' ') 个站点保持不变"
