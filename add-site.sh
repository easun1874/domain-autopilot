#!/usr/bin/env bash
# add-site.sh - 添加一个 HTTPS 站点：自动建 Cloudflare DNS 记录 + 自动签发证书 + 自动续签
#   add-site.sh app.example.com 127.0.0.1:8080
set -euo pipefail

CONF="/etc/caddy/Caddyfile"
SITES_DIR="/etc/caddy/sites"

DOMAIN=""
UPSTREAM=""
EMAIL="${LE_EMAIL:-}"
MODE="http"
REMOVE=0
NO_API_DNS=0
USE_PROXY=0
USE_CNAME=0
FIXED_IP=""
INSECURE=0
DRY=0
UPSTREAM_PATH=""

usage() {
	cat <<'EOF'
用法:
  add-site.sh <域名> <上游地址> [选项]
  add-site.sh --remove <域名>

示例:
  add-site.sh app.example.com 127.0.0.1:8080
  add-site.sh wiki.example.com 192.168.1.10:3000
  add-site.sh panel.example.com https://127.0.0.1:35216   # 后端是自签 HTTPS
  add-site.sh --remove app.example.com

选项:
  -e, --email EMAIL   Let's Encrypt 注册邮箱（或设 LE_EMAIL 环境变量）
  -d, --dns           强制本站走 DNS-01。跑过 enable-cf-native.sh 后全局已开，一般不用加
  -i, --ip IP         手动指定源站 IP，默认自动检测本机公网 IP
  -c, --cname         子域建 CNAME 指向父域（默认建 A 记录）
                      警告：开了 dynamic_dns 就别用，两者会抢同一个域名
  -P, --proxy         开启 Cloudflare 代理（默认关闭，只建灰云记录直连源站）
                      -p / --no-proxy 仍可用，等同于默认行为
  -n, --no-api-dns    只写 Caddy 配置，DNS 记录你自己去面板加
  -k, --insecure      上游是 https 但证书不受信（自签）时跳过校验。
                      上游主机是回环/内网地址且写了 https:// 时会自动开启，不用手动加
  --dry-run           只打印将要写入的 Caddy 站点配置，不建 DNS、不落盘、不 reload。
                      想确认「上游会被写成什么」时用这个，例如带路径的面板
  -r, --remove        删除站点（同时删掉 Cloudflare DNS 记录）
  -h, --help          显示帮助

前提: /etc/caddy/.cf_token 里放了 Cloudflare API Token（跑 setup.sh 会引导你填）
EOF
}

log() { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[31m[!!]\033[0m %s\n' "$*" >&2; }

# 内网/回环主机判定。公网 CA 不给私网地址签证书，所以「https + 内网主机」几乎必然
# 是自签，可以直接判定要跳过 TLS 校验，不必让用户去理解 --insecure。
is_private_host() {
	case "$1" in
		localhost | 127.* | ::1) return 0 ;;
		10.*) return 0 ;;
		192.168.*) return 0 ;;
		172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 0 ;;
	esac
	# 不带点的短主机名（docker compose 服务名 / 容器名）也算内网
	case "$1" in
		*.*) return 1 ;;
		*) return 0 ;;
	esac
}

if [ "$#" -eq 0 ]; then usage; exit 1; fi

while [ "$#" -gt 0 ]; do
	case "$1" in
		-r | --remove) REMOVE=1; shift ;;
		-d | --dns) MODE="dns"; shift ;;
		-e | --email) EMAIL="$2"; shift 2 ;;
		-i | --ip) FIXED_IP="$2"; shift 2 ;;
		-c | --cname) USE_CNAME=1; shift ;;
		-P | --proxy) USE_PROXY=1; shift ;;
		-p | --no-proxy) USE_PROXY=0; shift ;;   # 兼容旧写法：不开代理本就是默认
		-n | --no-api-dns) NO_API_DNS=1; shift ;;
		-k | --insecure) INSECURE=1; shift ;;
		--dry-run) DRY=1; shift ;;
		-h | --help) usage; exit 0 ;;
		-*) err "未知参数: $1"; exit 1 ;;
		*)
			if [ -z "$DOMAIN" ]; then DOMAIN="$1"; else UPSTREAM="$1"; fi
			shift
			;;
	esac
done

[ -n "$DOMAIN" ] || { usage; exit 1; }
[ "$(id -u)" -eq 0 ] || { err "请用 root 执行（sudo -i 或 sudo bash）"; exit 1; }
[ "$DRY" -eq 1 ] || [ -d "$SITES_DIR" ] || { err "$SITES_DIR 不存在，先跑 setup.sh"; exit 1; }

CF_LIB=""
for p in "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cf.sh" /usr/local/lib/caddy/cf.sh; do
	[ -f "$p" ] && CF_LIB="$p" && break
done
if [ -n "$CF_LIB" ]; then
	# shellcheck source=cf.sh
	. "$CF_LIB"
fi

# Caddyfile 里的 {env.CF_API_TOKEN} 是在适配期（caddy adapt）求值的，手动调
# caddy validate/reload 时当前 shell 没有该变量，Caddy 会判定 Token 无效并失败，
# 结果是站点配置写进去了却校验不过。这里一次性载入，后面所有 caddy 调用都受益。
if declare -F cf_load_env >/dev/null 2>&1; then cf_load_env; fi

# 默认不开 Cloudflare 代理（灰云 / 仅 DNS），理由：
#   1) 直连源站，浏览器看到的就是 Caddy 签的 LE 证书，不被 CF 边缘证书遮蔽
#   2) 不经过 CF 边缘，不受 zone 级 SSL/TLS 加密模式和边缘缓存影响
#   3) 链路少一跳，DNS → 源站 → Caddy 一目了然，排错简单
# 需要隐藏源站 IP 时才加 --proxy（此时源站必须有公共 CA 签发的有效证书，否则报 526）。
PROXIED="false"
if [ "$USE_PROXY" -eq 1 ]; then PROXIED="true"; fi

CONF_FILE="$SITES_DIR/${DOMAIN}.conf"

# ---------- 删除站点 ----------
if [ "$REMOVE" -eq 1 ]; then
	rm -f "$CONF_FILE"
	caddy fmt --overwrite "$CONF" >/dev/null 2>&1 || true
	caddy reload --config "$CONF" >/dev/null 2>&1 || systemctl reload caddy
	log "已删除 $DOMAIN 的 Caddy 配置"
	if [ "$NO_API_DNS" -eq 0 ] && command -v cf_delete_dns >/dev/null 2>&1; then
		cf_delete_dns "$DOMAIN" || true
	fi
	exit 0
fi

[ -n "$UPSTREAM" ] || { err "缺少上游地址，例如 127.0.0.1:8080"; exit 1; }

# Caddy 的 reverse_proxy 上游只接受 scheme://主机:端口，不接受路径、也不接受结尾斜杠。
# 面板里手填 http://127.0.0.1:8080/ 是很自然的写法，但会让 caddy adapt 直接失败
# （Error: URLs for proxy upstreams only support scheme, host, and port components），
# 站点静默不生效。这里统一规范化，别让用户去踩。
#
# 「带路径」不算错误输入：x-ui / 3x-ui 这类面板用 webBasePath 隐藏自己，路径是访问
# 路径（https://127.0.0.1:35216/a6bba520...）。Caddy 本来就原样透传请求路径，所以
# 路径该出现在访问 URL 里、不该出现在上游里。这里剥掉并提示用户访问时带回去。
if [ "${UPSTREAM#unix/}" = "$UPSTREAM" ]; then
	while [ "${UPSTREAM%/}" != "$UPSTREAM" ]; do UPSTREAM="${UPSTREAM%/}"; done
	_up_scheme=""
	_up_rest="$UPSTREAM"
	case "$UPSTREAM" in
		*://*) _up_scheme="${UPSTREAM%%://*}"; _up_rest="${UPSTREAM#*://}" ;;
	esac
	case "$_up_rest" in
		*/*)
			UPSTREAM_PATH="/${_up_rest#*/}"
			if [ -n "$_up_scheme" ]; then
				UPSTREAM="${_up_scheme}://${_up_rest%%/*}"
			else
				UPSTREAM="${_up_rest%%/*}"
			fi
			warn "上游地址不能带路径，已去掉 ${UPSTREAM_PATH}；Caddy 会原样透传请求路径，访问时带上它就行"
			;;
	esac
fi

# 上游填本机公网 IP 是个隐蔽的坑：云主机的公网 IP 往往不在网卡上（网卡只有 10.x 私网
# 地址），由边缘网关做 1:1 NAT。这样的上游会让 Caddy 把包发出网卡、绕网关再回来
# （hairpin），既多走一次公网往返，又要求安全列表放行该端口——而后端端口本来就不该
# 对公网开放。只有确认本机确有进程在监听该端口时才改写成回环；上游在别的机器上
# （填本机公网 IP 只是为了走公网）则保持原样。
LOCAL_PUB_IP=""
if command -v cf_public_ip >/dev/null 2>&1; then
	LOCAL_PUB_IP="$(cf_public_ip 2>/dev/null || true)"
fi
[ -n "$LOCAL_PUB_IP" ] || LOCAL_PUB_IP="$(cat /etc/caddy/.last_ip 2>/dev/null || true)"

if [ -n "$LOCAL_PUB_IP" ] && [ "${UPSTREAM#*$LOCAL_PUB_IP}" != "$UPSTREAM" ] && [ "${UPSTREAM#unix/}" = "$UPSTREAM" ]; then
	UP_PORT="$(printf '%s' "$UPSTREAM" | sed -nE 's|^[^:]*://||; s|^.*:([0-9]+)$|\1|p')"
	if [ -n "$UP_PORT" ] && ss -lnt 2>/dev/null | grep -qE "[:.]${UP_PORT}[[:space:]]"; then
		UPSTREAM="${UPSTREAM//$LOCAL_PUB_IP/127.0.0.1}"
		warn "上游填的是本机公网 IP，本机确有 $UP_PORT 在监听，已自动改为 127.0.0.1（少绕网关一圈，也不必对公网开放该端口）"
	else
		warn "上游填的是本机公网 IP，但本机没查到监听端口 $UP_PORT，保持原样（服务可能在别的机器上）"
	fi
fi

if [ -n "$EMAIL" ] && [ "$DRY" -eq 0 ]; then
	sed -i "s/^[[:space:]]*email .*/	email ${EMAIL}/" "$CONF"
fi

# 上游只写 host:port、后端却是 https —— Caddy 会按 http 去连，必然 502
# （x-ui / 3x-ui 面板默认只开 https，这是最常踩的一个）。对没写 scheme 的
# 内网/回环上游做一次 TLS 探测：握手能拿到证书就补上 https://。
# 只在没写 scheme 时探测，写了的以用户为准。
if [ "${UPSTREAM#unix/}" = "$UPSTREAM" ] &&
	[ "${UPSTREAM#http://}" = "$UPSTREAM" ] && [ "${UPSTREAM#https://}" = "$UPSTREAM" ]; then
	_probe_host="${UPSTREAM%%:*}"
	_probe_port="${UPSTREAM##*:}"
	if [ -n "$_probe_port" ] && [ "$_probe_port" != "$UPSTREAM" ] &&
		[ "${_probe_host#[}" = "$_probe_host" ] &&
		is_private_host "$_probe_host" && command -v openssl >/dev/null 2>&1; then
		_probe="$(timeout 5 openssl s_client -connect "${_probe_host}:${_probe_port}" \
			-servername "$_probe_host" </dev/null 2>/dev/null || true)"
		case "$_probe" in
			*"BEGIN CERTIFICATE"*)
				UPSTREAM="https://${_probe_host}:${_probe_port}"
				warn "上游只写了 ${_probe_host}:${_probe_port}，但该端口是 TLS（https）；已补上 https:// 并按自签处理"
				;;
		esac
	fi
fi

# 上游是 https 时 Caddy 会校验证书链。自签证书（x-ui / 3x-ui / 各类自建面板默认自签，
# 常见伪装 CN=www.bing.com）会让反代直接 502，报
# x509: certificate signed by unknown authority。内网主机的 https 自动跳过校验；
# 公网主机证书不受信时需显式加 --insecure。
TLS_BLOCK=""
if [ "${UPSTREAM#https://}" != "$UPSTREAM" ]; then
	_up_host="${UPSTREAM#https://}"
	_up_host="${_up_host%%:*}"
	_up_host="${_up_host#[}"
	_up_host="${_up_host%]}"
	if [ "$INSECURE" -eq 1 ]; then
		TLS_BLOCK="$(printf '\n\t\ttransport http {\n\t\t\ttls_insecure_skip_verify\n\t\t}')"
		warn "按 --insecure 跳过上游 TLS 校验：$UPSTREAM"
	elif is_private_host "$_up_host"; then
		TLS_BLOCK="$(printf '\n\t\ttransport http {\n\t\t\ttls_insecure_skip_verify\n\t\t}')"
		warn "上游是 https 且主机 $_up_host 属内网/回环，按自签证书处理：跳过 TLS 校验（对方证书正常也不会因此出错）"
	fi
fi

# ---------- 自动创建 Cloudflare DNS 记录 ----------
DNS_DESC="未启用自动 DNS"
if [ "$DRY" -eq 1 ]; then
	DNS_DESC="(dry-run 跳过)"
elif [ "$NO_API_DNS" -eq 0 ]; then
	if ! command -v cf_ensure_dns >/dev/null 2>&1; then
		err "没找到 cf.sh，已跳过自动建 DNS"
	elif ! cf_ready >/dev/null 2>&1; then
		err "Cloudflare Token 不可用（$CF_TOKEN_FILE），已跳过自动建 DNS"
	else
		ip="$FIXED_IP"
		[ -z "$ip" ] && ip="$(cf_public_ip)"
		if [ -z "$ip" ]; then
			err "取不到本机公网 IP，请用 --ip 手动指定"
		else
			parent="$(cf_parent_domain "$DOMAIN")"
			if [ "$USE_CNAME" -eq 1 ] && [ "$DOMAIN" != "$parent" ]; then
				cf_ensure_dns "$DOMAIN" "CNAME" "$parent" "$PROXIED"
				DNS_DESC="CF DNS: CNAME -> $parent"
			else
				# 默认建 A 记录。原因：dynamic_dns 只会建 A，两条不同类型抢同一个
				# 域名会冲突（DNS 规范下 CNAME 不能与其他记录共存）。
				cf_ensure_dns "$DOMAIN" "A" "$ip" "$PROXIED"
				DNS_DESC="CF DNS: A -> $ip"
			fi
		fi
	fi
elif [ "$USE_PROXY" -eq 1 ]; then
	DNS_DESC="手动 DNS，记得自己去开 Cloudflare 代理"
else
	DNS_DESC="手动 DNS，不开代理"
fi

# ---------- 生成 Caddy 站点配置 ----------
if [ "$MODE" = "dns" ]; then
	if [ -z "${CF_TOKEN:-}" ]; then
		err "DNS-01 模式需要 Cloudflare Token，先执行：export CF_TOKEN='你的token'"
		exit 1
	fi
	SITE_CONF="$(cat <<EOF
# 自动生成 by add-site.sh $(date -u +%F)
${DOMAIN} {
	tls {
		dns cloudflare {env.CF_TOKEN}
		resolutions
	}
	encode gzip
	reverse_proxy ${UPSTREAM} {
		flush_interval -1${TLS_BLOCK}
	}
}
EOF
)"
	SIG="DNS-01 签发"
else
	SITE_CONF="$(cat <<EOF
# 自动生成 by add-site.sh $(date -u +%F)
${DOMAIN} {
	encode gzip
	reverse_proxy ${UPSTREAM} {
		flush_interval -1${TLS_BLOCK}
	}
}
EOF
)"
	SIG="HTTP-01 签发"
fi

# --dry-run：只把将要写入的内容打出来。改上游写法（剥路径、跳过自签校验）之后，
# 这是唯一能先看结果再落盘的路子。
if [ "$DRY" -eq 1 ]; then
	echo "--- $CONF_FILE （dry-run，未写入）---"
	printf '%s\n' "$SITE_CONF"
	exit 0
fi

printf '%s\n' "$SITE_CONF" > "$CONF_FILE"

chown root:root "$CONF_FILE"
chmod 644 "$CONF_FILE"

caddy fmt --overwrite "$CONF" >/dev/null 2>&1 || true

# 校验失败必须回滚刚写的片段文件：坏配置留在 sites/ 里，
# 之后每一次 reload（其它站点、update 重启）都会失败，表现为
# Caddy 一直跑着旧配置、新站点静默不生效，极难排查。
if ! VALIDATE_ERR="$(caddy validate --config "$CONF" 2>&1)"; then
	err "Caddyfile 校验未通过，已回滚本次生成的配置。caddy 报错："
	echo "$VALIDATE_ERR" | tail -3 | sed 's/^/    /'
	rm -f "$CONF_FILE"
	exit 1
fi

if ! RELOAD_ERR="$(caddy reload --config "$CONF" 2>&1)"; then
	if ! systemctl reload caddy >/dev/null 2>&1; then
		err "Caddy 重载失败，已回滚本次生成的配置。caddy 报错："
		echo "$RELOAD_ERR" | tail -3 | sed 's/^/    /'
		rm -f "$CONF_FILE"
		exit 1
	fi
fi

ACCESS_URL="https://$DOMAIN"
if [ -n "$UPSTREAM_PATH" ]; then ACCESS_URL="https://$DOMAIN$UPSTREAM_PATH/"; fi

echo
log "站点已添加: $ACCESS_URL  ->  $UPSTREAM"
log "签发: $SIG    DNS: $DNS_DESC  代理: $PROXIED"
echo "  · 证书正在签发，等 10~30 秒生效"
echo "  · 验证: curl -sI $ACCESS_URL | head -1"
if [ -n "$UPSTREAM_PATH" ]; then
	echo "  · 该服务把路径当成自己的地址（webBasePath 之类），根路径 https://$DOMAIN/ 会 404"
	echo "    分享给别人时记得带上 $UPSTREAM_PATH"
fi
echo "  · 查看证书到期: openssl x509 -enddate -noout -in /var/lib/caddy/.local/share/caddy/certificates/*/$DOMAIN/$DOMAIN.crt"
echo "  · 删除: add-site.sh --remove $DOMAIN"
