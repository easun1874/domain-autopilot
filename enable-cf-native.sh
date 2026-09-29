#!/usr/bin/env bash
# enable-cf-native.sh - 打开 Caddy 自带的 Cloudflare 集成，不写一行 Cloudflare API 代码
#
#   A. ACME DNS-01 证书签发
#        Caddy 调 dns.providers.cloudflare 模块，自己去 CF 建 _acme-challenge TXT
#        拿证书、续签、删记录。不占 80 端口，还能签 *.example.com 泛域名。
#
#   B. dynamic_dns 自动维护 DNS 记录
#        扫描 Caddyfile 里所有站点的域名，自动到 CF 建/更新 A 记录。
#        VPS 换 IP 时自动改记录，不用 crontab 比对。
#
# 两块都只读同一个 API Token，任意一个模块缺失时另一块照常工作。
set -euo pipefail

CONF="/etc/caddy/Caddyfile"
ENV_FILE="/etc/caddy/cf.env"
DROPIN_DIR="/etc/systemd/system/caddy.service.d"
DROPIN="$DROPIN_DIR/cf.conf"

ASSUME_YES=0

usage() {
	cat <<'EOF'
用法:
  enable-cf-native.sh [-y]

选项:
  -y, --yes   跳过交互确认，给自动化用
  -h, --help  显示帮助

说明:
  把 Caddy 自带的 Cloudflare 集成打开，分两块，互不依赖：

  A. ACME DNS-01 证书签发  ->  全局 acme_dns cloudflare
       · 不占 80 端口，防火墙可以只留 443
       · 一张 *.example.com 泛证书管所有子域，加子域不用重新申请

  B. dynamic_dns 自动维护   ->  自动建 A 记录 + IP 漂移自动更新
       · 相当于把 sync-dns.sh 的手工比对换成了 Caddy 内建循环

  两块共用同一个 API Token，存在 /etc/caddy/cf.env（600 权限），
  Caddy 通过 systemd drop-in 读它，不写进 Caddyfile 明文。
EOF
}

log() { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[--]\033[0m %s\n' "$*"; }
err() { printf '\033[31m[!!]\033[0m %s\n' "$*" >&2; }

if [ "$#" -eq 0 ]; then
	:
elif [ "$1" = "-y" ] || [ "$1" = "--yes" ]; then
	ASSUME_YES=1
elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
	usage; exit 0
else
	err "未知参数: $1"; usage; exit 1
fi

[ "$(id -u)" -eq 0 ] || { err "请用 root 执行（sudo -i 或 sudo bash）"; exit 1; }
command -v caddy >/dev/null 2>&1 || { err "没找到 caddy 命令，先跑 setup.sh"; exit 1; }
[ -f "$CONF" ] || { err "$CONF 不存在，先跑 setup.sh"; exit 1; }

# ---------- 探测 Caddy 内置了哪些模块 ----------
MODULES="$(caddy list-modules 2>/dev/null || true)"

if printf '%s\n' "$MODULES" | grep -qx "dns.providers.cloudflare"; then
	HAS_PROVIDER=1
else
	HAS_PROVIDER=0
fi
if printf '%s\n' "$MODULES" | grep -qx "dynamic_dns"; then
	HAS_DYNAMIC=1
else
	HAS_DYNAMIC=0
fi

echo
echo "Caddy 模块探测:"
printf '  dns.providers.cloudflare  %s\n' "$([ $HAS_PROVIDER -eq 1 ] && echo '有' || echo '没有')"
printf '  dynamic_dns               %s\n' "$([ $HAS_DYNAMIC -eq 1 ] && echo '有' || echo '没有')"

if [ "$ASSUME_YES" -eq 0 ]; then
	echo
	read -r -p "确认要改 Caddy 配置吗？(y/N) " ans
	case "$ans" in
		y | Y | yes | YES) ;;
		*) warn "已取消，未做任何改动"; exit 0 ;;
	esac
fi

if [ "$HAS_PROVIDER" -eq 0 ]; then
	err "缺少 dns.providers.cloudflare 模块，DNS-01 用不了"
	warn "补装方式二选一："
	warn "  1) 换自带该模块的镜像：docker run ... iarekylew00t/caddy-cloudflare"
	warn "  2) 自己编译：xcaddy build --with github.com/caddy-dns/cloudflare"
	warn "本脚本会继续，但只启用能启用的部分"
fi

# ---------- 收集 API Token ----------
if [ -s "$ENV_FILE" ]; then
	OLD_TOKEN="$(sed -n 's/^CF_API_TOKEN=//p' "$ENV_FILE" | head -1)"
else
	OLD_TOKEN=""
fi

if [ -n "$OLD_TOKEN" ]; then
	if [ "$ASSUME_YES" -eq 0 ]; then
		read -r -p "已有 Token，换个新的？直接回车保留旧的: " NEW_TOKEN
	else
		NEW_TOKEN=""
	fi
	[ -z "$NEW_TOKEN" ] && NEW_TOKEN="$OLD_TOKEN"
else
	echo
	echo "去 Cloudflare 面板建 Token："
	echo "  My Profile -> API Tokens -> Create Token"
	echo "  权限必须同时给：Zone / DNS / Edit   +   Zone / Zone / Read"
	echo
	if [ "$ASSUME_YES" -eq 0 ]; then
		read -r -s -p "粘贴 Token（输入不显示）: " NEW_TOKEN
		echo
	else
		if [ -z "${CF_API_TOKEN:-}" ]; then
			err "非交互模式下请用 CF_API_TOKEN=xxx 传 Token"; exit 1
		fi
		NEW_TOKEN="$CF_API_TOKEN"
	fi
fi

[ -n "${NEW_TOKEN:-}" ] || { err "Token 是空的"; exit 1; }

# ---------- 落盘 token（600，不放 Caddyfile） ----------
mkdir -p "$(dirname "$ENV_FILE")"
cat > "$ENV_FILE" <<EOF
# Cloudflare API Token，供 Caddy 的 dns.providers.cloudflare 与 dynamic_dns 使用
CF_API_TOKEN=${NEW_TOKEN}
EOF
chown root:root "$ENV_FILE"
chmod 600 "$ENV_FILE"
log "Token 已写入 $ENV_FILE（600）"

# ---------- systemd drop-in，让 Caddy 进程拿到这个环境变量 ----------
HAS_SYSTEMD=0
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
	HAS_SYSTEMD=1
	mkdir -p "$DROPIN_DIR"
	cat > "$DROPIN" <<EOF
# 让 caddy 服务进程读到 Cloudflare Token
[Service]
EnvironmentFile=$ENV_FILE
EOF
	chown root:root "$DROPIN"
	chmod 644 "$DROPIN"
	systemctl daemon-reload >/dev/null 2>&1 || true
	systemctl restart caddy >/dev/null 2>&1 || true
	log "systemd drop-in 已写入 $DROPIN"
else
	warn "没检测到 systemd（Docker 场景），跳过 drop-in"
	warn "  容器里请改成：docker run -e CF_API_TOKEN=... 或 compose 的 environment:"
fi

# ---------- 注入 Caddyfile（幂等，重复跑不会产生第二份） ----------
NEED_ACME=0
NEED_DDNS=0
if [ "$HAS_PROVIDER" -eq 1 ] && ! grep -q "acme_dns cloudflare" "$CONF"; then
	NEED_ACME=1
fi
if [ "$HAS_DYNAMIC" -eq 1 ] && ! grep -qE "^[[:space:]]*dynamic_dns" "$CONF"; then
	NEED_DDNS=1
fi

if [ "$NEED_ACME" -eq 1 ] || [ "$NEED_DDNS" -eq 1 ]; then
	cp "$CONF" "$CONF.bak.$(date +%s)"

	# 块通过 stdin 喂给 awk，不落临时文件。
	#
	# ⚠️ 关键修正：acme_dns 和 dynamic_dns **都是全局选项**，必须写在文件顶部那个
	#    { } 块里面。旧版把 dynamic_dns 插在 `:80 {` 之前 —— 那是全局块外面，
	#    Caddy 会直接报 `unrecognized directive: provider` 并拒绝启动。
	#    这个 bug 很阴：只有当 Caddy 真的编进了 dynamic_dns 模块时才暴露，
	#    标准版 Caddy 上 HAS_DYNAMIC=0、压根不注入，所以长期没被发现。
	#
	# domains 里不再塞 example.com 占位符：dynamic_domains 会自动扫描 Caddy 配置里
	# 所有站点域名去管，塞个你根本没权限的域名进去只会刷错误日志。
	#
	# ttl 必须带时间单位：写 `ttl 60` 会得到
	#   parsing caddyfile tokens for 'dynamic_dns': time: missing unit in duration "60"
	# 。选项名是 ttl（不是 dns_ttl，那个会报 wrong argument）。
	DDNS_BLOCK=$'dynamic_dns {\n\tprovider cloudflare {env.CF_API_TOKEN}\n\tcheck_interval 5m\n\tttl 60s\n\tdynamic_domains\n}'

	printf '%s' "$DDNS_BLOCK" | awk \
		-v do_acme="$NEED_ACME" \
		-v do_ddns="$NEED_DDNS" '
		g == 0 && /^[[:space:]]*\{[[:space:]]*$/ {
			print
			g = 1
			if (do_acme == 1) print "\tacme_dns cloudflare {env.CF_API_TOKEN}"
			if (do_ddns == 1) {
				while ((getline l < "-") > 0) print l
			}
			next
		}
		{ print }
	' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"

	# 上面那个 `> "$CONF.tmp"` 是重定向建的文件，权限跟着当前 umask 走 ——
	# 万一 umask 是 077（比如被 bootstrap 的 --cf-token 路径带进来的），
	# Caddyfile 就成了 600，而它是 caddy 用户必须读的文件，服务会直接起不来。
	# 这里显式纠正，别指望 umask 恰好是对的。
	chmod 755 "$(dirname "$CONF")"
	chmod 644 "$CONF"

	# 注入之后自检一次：如果某个块没进去（比如 Caddyfile 被改得没有顶部 { } 块了），
	# 与其留下一个看似成功实则缺功能的配置，不如明确报出来。
	if [ "$NEED_ACME" -eq 1 ] && ! grep -q "acme_dns cloudflare" "$CONF"; then
		err "没找到顶部 { } 全局块，acme_dns 没能注入。请手动加："
		err '  在文件最上面的 { } 里加一行  acme_dns cloudflare {env.CF_API_TOKEN}'
	fi
	if [ "$NEED_DDNS" -eq 1 ] && ! grep -q "^[[:space:]]*dynamic_dns[[:space:]]*{" "$CONF"; then
		err "dynamic_dns 没能注入（同样是因为缺顶部 { } 块）"
	fi

	if [ "$NEED_ACME" -eq 1 ]; then log "已注入全局 acme_dns cloudflare（DNS-01 签发，不占 80 端口）"; fi
	if [ "$NEED_DDNS" -eq 1 ]; then log "已注入 dynamic_dns 块（自动建记录 + IP 漂移）"; fi
else
	warn "两块都已启用，跳过"
fi

# ---------- 校验并热加载 ----------
# {env.CF_API_TOKEN} 是在适配期（caddy adapt）求值的，手动调 caddy 时当前 shell
# 没有这个变量，Caddy 会报 "API token '' appears invalid"。先把刚写好的 cf.env 载入。
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# 注意：caddy fmt 不认 --config（文件名是位置参数）。写 --config 会 unknown flag
# 直接返回非 0，在 set -e/if 里表现为整个脚本失败。
if ! caddy fmt --overwrite "$CONF" >/dev/null 2>&1; then
	err "Caddyfile 格式化失败"; exit 1
fi
if ! caddy validate --config "$CONF" >/dev/null 2>&1; then
	err "Caddyfile 校验未通过，已保留备份，请检查："
	cat "$CONF"
	exit 1
fi
caddy reload --config "$CONF" >/dev/null 2>&1 || systemctl reload caddy
log "Caddy 已热加载"

# ---------- 结果 ----------
echo
echo "=========== 已启用 ==========="
[ "$HAS_PROVIDER" -eq 1 ] && echo "  A. ACME DNS-01 签发  已开（防火墙 80 可关）"
[ "$HAS_PROVIDER" -eq 0 ] && echo "  A. ACME DNS-01 签发  不可用，缺 dns.providers.cloudflare 模块"
[ "$HAS_DYNAMIC" -eq 1 ] && echo "  B. dynamic_dns       已开（自动建记录 + IP 漂移）"
[ "$HAS_DYNAMIC" -eq 0 ] && echo "  B. dynamic_dns       不可用，Caddy 是标准版（需 xcaddy 重新编译）"
echo
echo "下一步:"
echo "  · caddy list-modules | grep cloudflare     看模块"
echo "  · journalctl -u caddy -n 50 --no-pager     看有没有 CF API 报错"
echo "  · 重新签发测试：rm -rf /var/lib/caddy/.local/share/caddy/certificates/*/example.com && systemctl restart caddy"
echo "  · 注意 ①: dynamic_dns 的 domains 要改成你自己的父域"
echo "  · 注意 ②: dynamic_domains 会自动扫站点域名，domains 块只是给的兜底样例"
echo
