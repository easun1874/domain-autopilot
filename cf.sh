#!/usr/bin/env bash
# cf.sh - Cloudflare API 封装库
#   source 进 add-site.sh / sync-dns.sh 使用；也可独立执行子命令调试
#   bash cf.sh check | ip | zone <域名> | ensure <域名> <类型> <内容> [proxy] | delete <域名> | flush

CF_API_BASE="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"
# 所有消费方共用这一个文件：cf.sh / admin-api.py / Caddy(systemd drop-in)
CF_TOKEN_FILE="${CF_TOKEN_FILE:-/etc/caddy/cf.env}"
CF_TOKEN_FILE_LEGACY="/etc/caddy/.cf_token"   # setup.sh 早期版本写的裸 token，向后兼容
CF_CACHE_DIR="${CF_CACHE_DIR:-/var/cache/caddy/cf}"

cf_log() { printf '\033[32m[cf]\033[0m %s\n' "$*"; }
cf_err() { printf '\033[31m[!!]\033[0m %s\n' "$*" >&2; }

# 兼容两种文件格式：
#   KEY=value  —— /etc/caddy/cf.env，systemd EnvironmentFile 要求的格式
#   裸 token   —— 旧版 /etc/caddy/.cf_token
_extract_token() {
	local f="$1" t=""
	[ -f "$f" ] || return 1
	t="$(sed -n 's/^CF_API_TOKEN=//p' "$f" 2>/dev/null | tr -d '[:space:]')"
	if [ -z "$t" ]; then
		t="$(tr -d '[:space:]' < "$f" 2>/dev/null)"
	fi
	[ -n "$t" ] || return 1
	printf '%s' "$t"
}

# Caddyfile 里的 {env.CF_API_TOKEN} 是在适配期（caddy adapt）求值的：
# 手动执行 caddy validate / caddy reload 时，当前 shell 里没有这个变量，
# Caddy 会报 "API token '' appears invalid; ..."，于是校验必然失败 ——
# 表现为新站点加不上、update 重载不了。凡是直接调 caddy 的脚本，
# 都先过一遍这里，把 cf.env 载入当前环境。
cf_load_env() {
	local f="${CF_TOKEN_FILE:-/etc/caddy/cf.env}"
	[ -r "$f" ] || return 0
	set -a
	# shellcheck disable=SC1090
	. "$f"
	set +a
}

cf_token() {
	local t=""
	t="$(_extract_token "$CF_TOKEN_FILE")" || t=""
	if [ -z "$t" ]; then
		t="$(_extract_token "$CF_TOKEN_FILE_LEGACY")" || t=""
	fi
	if [ -z "$t" ]; then
		cf_err "读不到 Cloudflare Token（找过 $CF_TOKEN_FILE 和 $CF_TOKEN_FILE_LEGACY）"
		cf_err "跑 setup.sh 或 enable-cf-native.sh 写入即可"
		return 1
	fi
	printf '%s' "$t"
}

cf_ready() {
	command -v jq >/dev/null 2>&1 || { cf_err "缺少 jq，先 apt install -y jq"; return 1; }
	cf_token >/dev/null 2>&1
}

cf_api() { # cf_api METHOD PATH [BODY] —— 带 1 次重试，失败则报错退出码 1
	local method="$1" path="$2" body="${3:-}" token resp detail n=0
	token="$(cf_token)" || return 1
	while [ $n -lt 2 ]; do
		resp="$(curl -sS --max-time 20 -X "$method" \
			-H "Authorization: Bearer $token" \
			-H "Content-Type: application/json" \
			${body:+-d "$body"} \
			"${CF_API_BASE}${path}" 2>/dev/null)"
		if printf '%s' "$resp" 2>/dev/null | jq -e '.success == true' >/dev/null 2>&1; then
			printf '%s' "$resp"
			return 0
		fi
		n=$((n + 1))
		[ $n -lt 2 ] && sleep 3
	done
	detail="$(printf '%s' "$resp" | jq -r '.errors[0].message // "未知错误"' 2>/dev/null)"
	cf_err "API 失败 [$method $path]: ${detail:-空响应}"
	return 1
}

cf_parent_domain() { # a.b.example.com -> example.com
	echo "$1" | awk -F. 'NF<=2{print;next}{print $(NF-1)"."$NF}'
}

cf_zone_id() { # 查 zone id，带本地缓存
	local domain="$1" zone="" cache="$CF_CACHE_DIR/${1}"
	[ -f "$cache" ] && zone="$(cat "$cache")"
	if [ -n "$zone" ]; then
		printf '%s' "$zone"
		return 0
	fi
	zone="$(cf_api GET "/zones?name=${domain}&status=active&per_page=1" | jq -r '.result[0].id // empty')"
	[ -n "$zone" ] || {
		cf_err "Cloudflare 找不到 zone: ${domain}（确认域名已托管到 CF，且 Token 有 Zone:Read 权限）"
		return 1
	}
	mkdir -p "$CF_CACHE_DIR"
	printf '%s' "$zone" >"$cache"
	printf '%s' "$zone"
}

cf_zone_flush() { rm -rf "$CF_CACHE_DIR"; }

cf_body() { # type name content proxied
	jq -nc --arg type "$1" --arg name "$2" --arg content "$3" --argjson proxied "$4" \
		'{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied}'
}

cf_ensure_dns() { # 幂等：已存在且一致则跳过，内容不同则更新
	local domain="$1" type="$2" content="$3" proxied="${4:-true}" zone id resp
	cf_ready || return 1
	zone="$(cf_zone_id "$(cf_parent_domain "$domain")")" || return 1
	resp="$(cf_api GET "/zones/${zone}/dns_records?type=${type}&name=${domain}&per_page=1")" || return 1
	id="$(printf '%s' "$resp" | jq -r '.result[0].id // empty')"
	if [ -n "$id" ]; then
		if [ "$(printf '%s' "$resp" | jq -r '.result[0].content')" != "$content" ]; then
			cf_api PUT "/zones/${zone}/dns_records/${id}" \
				"$(cf_body "$type" "$domain" "$content" "$proxied")" >/dev/null &&
				cf_log "DNS 已更新: $type $domain -> $content"
		else
			cf_log "DNS 已存在: $type $domain -> $content（跳过）"
		fi
		return 0
	fi
	cf_api POST "/zones/${zone}/dns_records" \
		"$(cf_body "$type" "$domain" "$content" "$proxied")" >/dev/null &&
		cf_log "DNS 已创建: $type $domain -> $content（代理: $proxied）"
}

cf_delete_dns() {
	local domain="$1" zone resp
	cf_ready || return 1
	zone="$(cf_zone_id "$(cf_parent_domain "$domain")" 2>/dev/null)" || return 0
	resp="$(cf_api GET "/zones/${zone}/dns_records?name=${domain}&per_page=100")" || return 1
	local id
	for id in $(printf '%s' "$resp" | jq -r '.result[].id // empty'); do
		[ -n "$id" ] || continue
		cf_api DELETE "/zones/${zone}/dns_records/${id}" >/dev/null || true
		cf_log "DNS 已删除: $domain"
	done
}

cf_public_ip() {
	local ip
	ip="$(curl -sS --max-time 6 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]')"
	[ -n "$ip" ] || ip="$(curl -sS --max-time 6 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')"
	[ -n "$ip" ] || ip="$(curl -sS --max-time 6 https://ifconfig.me/ip 2>/dev/null | tr -d '[:space:]')"
	printf '%s' "$ip"
}

cf_resolve() { # 本地看域名解析结果
	local domain="$1" got=""
	got="$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)"
	[ -z "$got" ] && got="$(getent ahosts "$domain" 2>/dev/null | awk '$1 ~ /^[0-9]+\./{print $1; exit}')"
	printf '%s' "$got"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	case "${1:-}" in
		check) cf_ready && cf_api GET "/user/tokens/verify" >/dev/null && cf_log "Cloudflare API 连通正常" ;;
		ip) cf_ready && cf_public_ip ;;
		zone) cf_ready && cf_zone_id "$2" ;;
		ensure)
			cf_ensure_dns "$2" "$3" "$4" "${5:-true}"
			;;
		delete)
			cf_delete_dns "$2"
			;;
		resolve) cf_resolve "$2" ;;
		flush) cf_zone_flush && echo "zone 缓存已清空" ;;
		*)
			cat <<'EOF'
cf.sh 子命令:
  check                                              验证 Token 与连通性
  ip                                                 取本机公网 IPv4
  zone   <域名>                                      查 zone id
  ensure <域名> <类型> <内容> [代理true/false]         创建/更新 DNS 记录
  delete <域名>                                      删除 DNS 记录
  resolve <域名>                                     查本地解析结果
  flush                                              清空 zone 缓存
EOF
			;;
	esac
fi
