#!/usr/bin/env bash
# sync-dns.sh - 巡检：站点 DNS 记录对齐 + 源站 IP 漂移同步 + 证书到期预警
#
# 用法：
#   sync-dns.sh            # 正常巡检，缺记录会补、记录错了会改
#   sync-dns.sh --check    # 真·只读，只出报告，绝不碰 Cloudflare
#   sync-dns.sh --quiet    # 没异常就不输出，给高频 cron 用
#
# cron 建议（每 10 分钟，IP 漂移最多 10 分钟内自愈）：
#   */10 * * * * /usr/local/bin/sync-dns.sh --quiet >> /var/log/caddy-sync.log 2>&1
set -uo pipefail

CONF="/etc/caddy/Caddyfile"
SITES_DIR="/etc/caddy/sites"
LAST_IP_FILE="/etc/caddy/.last_ip"
CHECK_ONLY=0
QUIET=0

while [ $# -gt 0 ]; do
	case "$1" in
		--check | -c) CHECK_ONLY=1; shift ;;
		--quiet | -q) QUIET=1; shift ;;
		-h | --help)
			sed -n '2,16p' "$0" | sed 's/^# \?//'
			exit 0
			;;
		*) shift ;;
	esac
done

ts() { printf '[%s]' "$(date '+%F %T')"; }
log()  { printf '%s %s\n' "$(ts)" "$*"; }
# 常规信息在 --quiet 下不输出
info() { [ "$QUIET" -eq 1 ] || printf '%s %s\n' "$(ts)" "$*"; }
# 异常（IP 漂移、记录缺失、证书预警）永远输出，这是巡检的意义所在
warn() { printf '%s \033[33m[!]\033[0m %s\n' "$(ts)" "$*"; }
err()  { printf '%s \033[31m[!!]\033[0m %s\n' "$(ts)" "$*" >&2; }
act()  { printf '%s \033[32m[*]\033[0m %s\n' "$(ts)" "$*"; }

CF_LIB=""
for p in "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cf.sh" /usr/local/lib/caddy/cf.sh; do
	[ -f "$p" ] && CF_LIB="$p" && break
done
if [ -n "$CF_LIB" ]; then
	# shellcheck source=cf.sh
	. "$CF_LIB"
fi

info "==== 开始巡检（$([ "$CHECK_ONLY" -eq 1 ] && echo '只读' || echo '可修改')）===="

# ---------- 0. 读/写操作总开关：--check 下任何写都必须被拦住 ----------
readonly_write() {
	# 用法：readonly_write <实际执行的命令...>
	if [ "$CHECK_ONLY" -eq 1 ]; then
		warn "[只读] 跳过写操作: $*"
		return 0
	fi
	"$@"
}

# ---------- 1. 源站 IP 漂移检测 ----------
# 只认公网 IPv4。云主机的公网 IP 通常不在网卡上（边缘网关做 1:1 NAT），
# 所以 `ip route get` 只能拿到 10.x 私网地址。若把它当成"新公网 IP"，下面就会
# 把所有站点的 A 记录改成这个私网地址 —— 外网直接不可达，而且下次巡检会把
# .last_ip 也写成它，之后再也发现不了。宁可判定"取不到"（后面的分支会跳过写记录）。
is_public_ipv4() {
	local ip="${1:-}"
	printf '%s' "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
	case "$ip" in
		10.* | 127.* | 192.168.* | 169.254.* | 0.* | 255.*) return 1 ;;
		172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 1 ;;
	esac
	return 0
}

CUR_IP="$(cf_public_ip 2>/dev/null)"
is_public_ipv4 "$CUR_IP" || CUR_IP=""

if [ -z "$CUR_IP" ]; then
	# 外部探测全挂时退回到本机出口地址 —— 只在公网 IP 直接挂在网卡上才有意义，
	# 所以同样要过一遍公网校验，私网地址一律丢弃
	CAND="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"
	if is_public_ipv4 "$CAND"; then
		CUR_IP="$CAND"
	fi
fi

if [ -z "$CUR_IP" ]; then
	warn "取不到可信的公网 IP，跳过漂移检查（检查出网是否正常）"
	DRIFTED=1   # 未知状态，按"需要检查"处理，但不误报为漂移
else
	LAST_IP=""
	# 注意：这里只读 .last_ip 这一个文件，不能把站点配置目录混进来
	[ -f "$LAST_IP_FILE" ] && LAST_IP="$(tr -d '[:space:]' < "$LAST_IP_FILE")"
	if [ -z "$LAST_IP" ]; then
		if [ "$CHECK_ONLY" -eq 1 ]; then
			warn "[只读] 应写入 .last_ip 快照: $CUR_IP"
		else
			printf '%s' "$CUR_IP" > "$LAST_IP_FILE"
			info "首次记录源站 IP: $CUR_IP"
		fi
		DRIFTED=0
	elif [ "$LAST_IP" != "$CUR_IP" ]; then
		warn "源站 IP 已漂移: $LAST_IP -> $CUR_IP"
		DRIFTED=1
	else
		info "源站 IP 未变: $CUR_IP"
		DRIFTED=0
	fi
fi

# ---------- 2. 逐站比对 DNS 记录 ----------
# 统一建 A 记录：dynamic_dns 也只建 A，混用 CNAME 会跟它抢同一个域名
dns_current() { # 查询 Cloudflare 里现有的记录内容
	local domain="$1" zone resp
	zone="$(cf_zone_id "$(cf_parent_domain "$domain")" 2>/dev/null)" || return 1
	resp="$(cf_api GET "/zones/${zone}/dns_records?type=A&name=${domain}&per_page=1" 2>/dev/null)" || return 1
	printf '%s' "$resp" | jq -r '.result[0].content // empty'
}

FOUND=0
FIXED=0
CF_OK=0
if command -v cf_ready >/dev/null 2>&1 && cf_ready >/dev/null 2>&1; then
	CF_OK=1
else
	warn "cf.sh 或 Token 不可用，跳过 DNS 对齐（Token 过期了吗？）"
fi

# 先盘点站点配置。跳过 DNS 对齐时 FOUND 仍是 0，不能据此说"没有站点"
SITE_CONFS=()
for f in "$SITES_DIR"/*.conf; do
	[ -f "$f" ] && SITE_CONFS+=("$f")
done

if [ "${#SITE_CONFS[@]}" -eq 0 ]; then
	info "没有站点配置（$SITES_DIR 为空）"
elif [ "$CF_OK" -ne 1 ]; then
	info "有 ${#SITE_CONFS[@]} 个站点配置，但 CF 不可用，未做比对"
elif [ -z "$CUR_IP" ]; then
	warn "没有可信的公网 IP，跳过逐站比对（避免把错误的 IP 写进去）"
else
	for f in "${SITE_CONFS[@]}"; do
		[ -f "$f" ] || continue
		dom="$(grep -m1 -E '^[^[:space:]#]+' "$f" 2>/dev/null | awk '{print $1}')"
		[ -n "$dom" ] || continue
		FOUND=$((FOUND + 1))

		cur="$(dns_current "$dom" 2>/dev/null)"
		if [ "$cur" = "$CUR_IP" ]; then
			info "OK   $dom -> $cur"
		elif [ -z "$cur" ]; then
			warn "缺失 $dom 没有 A 记录"
			if [ "$CHECK_ONLY" -eq 0 ]; then
				cf_ensure_dns "$dom" A "$CUR_IP" true >/dev/null 2>&1 \
					&& act "已补建 $dom -> $CUR_IP" || err "补建失败 $dom"
				FIXED=$((FIXED + 1))
			fi
		else
			warn "不符 $dom 指向 $cur，应为 $CUR_IP"
			if [ "$CHECK_ONLY" -eq 0 ]; then
				cf_ensure_dns "$dom" A "$CUR_IP" true >/dev/null 2>&1 \
					&& act "已更新 $dom -> $CUR_IP" || err "更新失败 $dom"
				FIXED=$((FIXED + 1))
			fi
		fi
	done
fi

if [ "${#SITE_CONFS[@]}" -gt 0 ] && { [ "$QUIET" -eq 0 ] || [ "$FIXED" -gt 0 ]; }; then
	log "站点 ${#SITE_CONFS[@]} 个，本次修正 $FIXED 条"
fi

# IP 漂移处理完毕后再落盘，避免"记录没改成却把旧 IP 记为已处理"
if [ "$CHECK_ONLY" -eq 0 ] && [ "$DRIFTED" -eq 1 ] && [ -n "$CUR_IP" ]; then
	printf '%s' "$CUR_IP" > "$LAST_IP_FILE"
	info "已更新.last_ip 快照"
fi

# ---------- 3. 证书到期预警 ----------
# Caddy 的 DataDir 是 <HOME>/.local/share/caddy —— **不是 HOME 本身**（systemd 单元里
# Caddy 的 HOME=/var/lib/caddy，所以数据在 /var/lib/caddy/.local/share/caddy）。
# 证书实际在 DataDir 下的 certificates/<issuer>/<域名>/ ，很容易把 certificates
# 这一层漏掉 —— 那样这段预警会静默失效，只留一句"未找到证书目录"，非常隐蔽。
# 路径与面板 admin-api.py 的 CERT_BASES 保持一致，别两套标准。
CERT_CANDIDATES=()
if [ -n "${CADDY_DATA_DIRECTORY:-}" ]; then
	CERT_CANDIDATES+=("$CADDY_DATA_DIRECTORY/certificates" "$CADDY_DATA_DIRECTORY")
fi
CERT_CANDIDATES+=(
	/var/lib/caddy/.local/share/caddy/certificates
	/root/.local/share/caddy/certificates
	/var/lib/caddy/certificates
	/caddy_data/certificates
	/root/.local/share/caddy
	/var/lib/caddy
	/caddy_data
)
CERT_DIR=""
for d in "${CERT_CANDIDATES[@]}"; do
	[ -n "$d" ] || continue
	if [ -d "$d/acme-v02.api.letsencrypt.org-directory" ]; then
		CERT_DIR="$d"
		break
	fi
done
[ -n "$CERT_DIR" ] || CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates"

if [ -d "$CERT_DIR/acme-v02.api.letsencrypt.org-directory" ]; then
	FOUND_CERT=0
	EXPIRING=0
	while IFS= read -r crt; do
		FOUND_CERT=$((FOUND_CERT + 1))
		end="$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2)"
		[ -n "$end" ] || continue
		days=$((($(date -d "$end" +%s) - $(date +%s)) / 86400))
		name="$(basename "$(dirname "$crt")")"
		[ "$days" -lt 20 ] && warn "证书剩余 $days 天：$name（$end）" && EXPIRING=$((EXPIRING + 1))
	done < <(find "$CERT_DIR/acme-v02.api.letsencrypt.org-directory" -name '*.crt' 2>/dev/null)
	info "证书 $FOUND_CERT 张，临期 $EXPIRING 张"
else
	warn "未找到证书目录：$CERT_DIR（自定义 data dir 请用 CADDY_DATA_DIRECTORY 指定）"
fi

info "==== 巡检结束 ===="
exit 0
