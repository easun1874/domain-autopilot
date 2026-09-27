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
elif [ -n "$GITHUB_TOKEN" ]; then
	if [ "$CHECK_ONLY" -eq 1 ]; then
		REMOTE_SHA="$(curl -fsSL --max-time 20 -H "Authorization: Bearer $GITHUB_TOKEN" \
			-H "Accept: application/vnd.github+json" "$API/commits/$BRANCH" 2>/dev/null \
			| grep -m1 '"sha"' | sed 's/.*"sha": *"\([^"]*\)".*/\1/' | cut -c1-7)"
		info "远端最新提交：${REMOTE_SHA:-取不到}"
		exit 0
	fi
	tmp="$(mktemp -d)"
	curl -fsSL --max-time 90 -H "Authorization: Bearer $GITHUB_TOKEN" \
		-H "Accept: application/vnd.github+json" "$API/tarball/$BRANCH" -o "$tmp/src.tar.gz" \
		|| { err "下载失败"; rm -rf "$tmp"; exit 1; }
	tar xzf "$tmp/src.tar.gz" -C "$INSTALL_DIR" --strip-components=1
	rm -rf "$tmp"
	log "源码包已更新"
else
	err "既不是 git 仓库，也没有 GITHUB_TOKEN，没法更新"
	exit 1
fi

NEW_REV="$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
[ "$OLD_REV" != "$NEW_REV" ] && log "版本变化：$OLD_REV → $NEW_REV" || info "版本号未变，仍执行重装确保一致"

echo "== 2/4 重装脚本 =="
for f in cf.sh enable-cf-native.sh; do
	install -m 755 "$INSTALL_DIR/$f" "/usr/local/lib/caddy/$f"
done
for f in add-site.sh sync-dns.sh enable-cf-native.sh; do
	install -m 755 "$INSTALL_DIR/$f" "/usr/local/bin/$f"
done
[ -f "$INSTALL_DIR/update.sh" ] && install -m 755 "$INSTALL_DIR/update.sh" /usr/local/bin/domain-autopilot-update
log "cf.sh / add-site.sh / sync-dns.sh / enable-cf-native.sh 已刷新"

echo "== 3/4 重装面板 =="
if [ -f "$INSTALL_DIR/admin-api.py" ]; then
	install -m 755 "$INSTALL_DIR/admin-api.py"  /usr/local/lib/caddy/admin-api.py
	install -m 644 "$INSTALL_DIR/admin-ui.html" /usr/local/lib/caddy/admin-ui.html
	[ -f "$INSTALL_DIR/admin-api.service" ] \
		&& install -m 644 "$INSTALL_DIR/admin-api.service" /etc/systemd/system/admin-api.service
	systemctl daemon-reload >/dev/null 2>&1 || true
	systemctl restart admin-api >/dev/null 2>&1 || true
	log "面板已刷新并重启"
fi

if [ "$DO_SETUP" -eq 0 ]; then
	log "按 --no-setup 要求跳过 setup.sh"
else
	echo "== 4/4 重跑 setup.sh（幂等，不会动已有站点和 Token）=="
	# cf.env 里已有 Token 就够用，不用再传；setup.sh 会自己复用
	if bash "$INSTALL_DIR/setup.sh"; then
		log "setup.sh 执行完毕"
	else
		err "setup.sh 报错，看上面输出"
		exit 1
	fi
fi

if [ "$DO_RELOAD" -eq 1 ]; then
	caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
		&& caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
		&& log "Caddy 配置已热加载（站点无中断）" \
		|| info "Caddy 未重载（可能未安装或配置有误），手动看：caddy validate --config /etc/caddy/Caddyfile"
fi

echo
log "更新完成。$(ls /etc/caddy/sites/*.conf 2>/dev/null | wc -l | tr -d ' ') 个站点保持不变"
