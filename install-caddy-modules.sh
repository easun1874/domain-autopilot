#!/usr/bin/env bash
# install-caddy-modules.sh - 把 Caddy 换成「带 Cloudflare + dynamic_dns 模块」的官方构建
#
# 为什么需要这一步：
#   apt 装出来的 caddy 是**标准版**，不含 dns.providers.cloudflare。缺了它，
#   DNS-01 签发（不占 80 端口、能签泛域名）和 dynamic_dns（IP 漂移自动改记录）
#   都用不了 —— 而这两个正是本项目最想要的能力。apt 官方源也不提供带第三方
#   模块的包，唯一的路就是换二进制。
#
# 本脚本做三件事：
#   1. 从 caddyserver.com 的下载 API 拉一个把这两个模块编进去的构建
#   2. 原子替换 /usr/bin/caddy（换之前先备份到 /usr/bin/caddy.bak.<时间戳>）
#   3. apt-mark hold caddy
#
#   第 3 步千万别省：不 hold 的话，某次 apt upgrade 会把二进制覆盖回标准版，
#   表现是「站点还在跑、但证书到了续签日突然签不出来」，而且没有任何显眼线索。
#
# 用法:
#   bash install-caddy-modules.sh            # 已是模块版就什么都不做
#   bash install-caddy-modules.sh --force    # 强制重下重装
#   bash install-caddy-modules.sh --dry-run  # 只探测现状与将要下载的 URL
set -euo pipefail

CADDY_BIN="/usr/bin/caddy"
FORCE=0
DRY=0

PLUGINS=(
	"github.com/caddy-dns/cloudflare"
	"github.com/mholt/caddy-dynamicdns"
)

log() { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
info() { printf '\033[36m[--]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!!]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[31m[!!]\033[0m %s\n' "$*" >&2; }

usage() { sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
	case "$1" in
		-f | --force) FORCE=1; shift ;;
		--dry-run) DRY=1; shift ;;
		-h | --help) usage ;;
		*) err "未知参数: $1"; usage; exit 1 ;;
	esac
done

[ "$(id -u)" -eq 0 ] || { err "请用 root 执行（sudo -i 或 sudo bash）"; exit 1; }

# ---------- 认架构 ----------
# caddyserver.com 的下载 API 用的是 Go 的 GOARCH 命名，和 dpkg / uname 都不一样，
# 必须显式映射，否则会下载到一个架构不符的二进制（跑起来直接 Exec format error）。
arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$arch" in
	amd64 | x86_64) GOARCH="amd64" ;;
	arm64 | aarch64) GOARCH="arm64" ;;
	armhf | armv7l) GOARCH="arm" ;;
	armel) GOARCH="arm" ;;
	i386 | i686) GOARCH="386" ;;
	*)
		err "不认识的架构：$arch。去 https://caddyserver.com/download 自己构建"
		exit 1
		;;
esac
info "架构：$arch -> GOARCH=$GOARCH"

# ---------- 组装下载 URL ----------
URL="https://caddyserver.com/api/download?os=linux&arch=${GOARCH}"
for p in "${PLUGINS[@]}"; do
	URL="${URL}&p=${p}"
done

# ---------- 现状探测 ----------
have_module() {
	command -v caddy >/dev/null 2>&1 || return 1
	caddy list-modules 2>/dev/null | grep -qx "dns.providers.cloudflare"
}

if [ "$FORCE" -eq 0 ] && have_module; then
	log "当前 Caddy 已带 dns.providers.cloudflare，无需处理"
	echo "  版本: $(caddy version 2>/dev/null | head -1)"
	apt-mark showhold 2>/dev/null | grep -qx caddy \
		&& log "caddy 已被 apt-mark hold（升级不会覆盖）" \
		|| warn "建议补一下：apt-mark hold caddy —— 否则 apt upgrade 会把二进制换回标准版"
	exit 0
fi

if [ ! -x "$CADDY_BIN" ]; then
	err "找不到 $CADDY_BIN —— 先装一次 Caddy（跑 setup.sh），再来换二进制"
	exit 1
fi

OLD_VER="$(caddy version 2>/dev/null | head -1 || echo '未知')"
info "当前版本：$OLD_VER（缺模块）"
info "将下载：$URL"

if [ "$DRY" -eq 1 ]; then
	echo
	echo "dry-run：什么都没做。去掉 --dry-run 就真的下载并替换。"
	exit 0
fi

# ---------- 下载 ----------
if ! command -v curl >/dev/null 2>&1; then
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq && apt-get install -y -qq curl >/dev/null 2>&1
fi

TMP="$(mktemp /tmp/caddy.XXXXXX)"
trap 'rm -f "$TMP"' EXIT

info "下载中（约 45MB）…"
if ! curl -fsSL --max-time 300 "$URL" -o "$TMP"; then
	err "下载失败。检查到 caddyserver.com 的网络，或换个时间重试"
	exit 1
fi

# ---------- 校验下载物 ----------
# 三道关，任何一道不过就放弃替换 —— 换错了会让 Caddy 直接起不来，
# 而 Caddy 起不来意味着所有站点的 HTTPS 一起挂，代价远大于不做。
# 注意先 chmod 再试运行：mktemp 建的临时文件默认没有执行位，不补权限去跑
# 会得到 "Permission denied"，看起来像「下载坏了」，其实是自己没给它执行权限。
chmod 755 "$TMP"
if ! "$TMP" version >/dev/null 2>&1; then
	err "下载回来的东西跑不起来（不是可执行文件，或被截断）"
	exit 1
fi
NEW_VER="$("$TMP" version 2>/dev/null | head -1)"
if ! "$TMP" list-modules 2>/dev/null | grep -qx "dns.providers.cloudflare"; then
	err "下载回来的构建里没有 dns.providers.cloudflare，放弃替换"
	exit 1
fi
info "新版本：$NEW_VER（模块齐全）"

# ---------- 备份并替换 ----------
BAK="$CADDY_BIN.bak.$(date +%s)"
cp -a "$CADDY_BIN" "$BAK"
log "已备份原二进制：$BAK"

mv -f "$TMP" "$CADDY_BIN"
trap - EXIT

# ---------- 防覆盖 ----------
if command -v apt-mark >/dev/null 2>&1; then
	apt-mark hold caddy >/dev/null 2>&1 && log "已 apt-mark hold caddy（apt upgrade 不会再覆盖它）" \
		|| warn "apt-mark hold 失败，手动补一下，否则升级会把二进制换回去"
fi

# ---------- 校验配置并重启 ----------
if command -v caddy >/dev/null 2>&1 && [ -f /etc/caddy/Caddyfile ]; then
	if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
		log "Caddyfile 校验通过"
	else
		warn "Caddyfile 校验没过（可能是本来就有的问题）。二进制已经换好了，"
		warn "先别重启，修完配置再 systemctl restart caddy"
		exit 0
	fi
fi

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet caddy; then
	systemctl restart caddy >/dev/null 2>&1 || true
	sleep 1
	if systemctl is-active --quiet caddy; then
		log "Caddy 已重启，运行中"
	else
		err "Caddy 起不来了！回滚：cp -a $BAK $CADDY_BIN && systemctl restart caddy"
		exit 1
	fi
fi

echo
log "完成：$(caddy version 2>/dev/null | head -1)"
echo "  验证模块: caddy list-modules | grep -E 'dns.providers.cloudflare|^dynamic_dns$'"
echo "  下一步：  bash enable-cf-native.sh -y     # 打开 DNS-01 + dynamic_dns"
echo "  回滚：    cp -a $BAK $CADDY_BIN && systemctl restart caddy"
