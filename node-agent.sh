#!/usr/bin/env bash
# node-agent.sh - 被纳管节点侧的「白名单执行器」
#
# 这个脚本不是给人手动跑的。它是 authorized_keys 里 command= 的目标：
#
#   command="/usr/local/bin/domain-autopilot-node",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA... panel@domain-autopilot
#
# 效果：任何用这把密钥登录进来的人，无论他请求执行什么命令，sshd 都会强制执行本脚本，
# 他原本请求的命令被塞进 $SSH_ORIGINAL_COMMAND，由本脚本做白名单校验。
#
# 为什么必须这样：控制面板（admin-api.py）本身要暴露在公网。如果它直接拿一把能在
# 节点上执行任意命令的 root 密钥，那面板一旦被攻破，所有被纳管的机器一起沦陷。
# 挂上这层之后，这把密钥的实际能力被压缩成四件事：
#
#   list    列站点        add     加站点
#   remove  删站点        certs   读证书到期   status  看节点状态
#
# 别的命令一律拒绝 —— 连 `id`、`ls` 都跑不了。
#
# 输出格式（给面板 admin-api.py 解析）。故意选最简单的分隔符，不引入 jq / python 依赖，
# 因为被纳管的机器可能只装了 Caddy 和 add-site.sh，没装面板：
#   list    每行：域名 <TAB> 上游 <TAB> 标记(逗号分隔，dns01 / auth；无标记输出 "-")
#   status  每行：key=value（caddy / version / hostname / sites）
#   certs   每行：证书名 <TAB> openssl notAfter 原文
#   add / remove  直接透传 add-site.sh 的输出与退出码
#
# ⚠️ 所有输出都必须是「行尾没有空字段」的形态。面板侧 sh() 会 .strip() 整段输出，
#    只吃掉最末行的收尾空白；末行若以空字段+TAB 结束，字段数会少一个被误判为坏行。
#    所以空字段一律给占位符（list 的标记给 "-"）。
set -uo pipefail

ADD_SITE="${ADD_SITE:-/usr/local/bin/add-site.sh}"
SITES_DIR="${SITES_DIR:-/etc/caddy/sites}"
CERT_BASE="${CADDY_CERT_DIR:-/var/lib/caddy/.local/share/caddy/certificates}"

RE_DOMAIN='^[A-Za-z0-9._*-]+\.[A-Za-z]{2,}$'
RE_AUTH='^[^:[:space:]]+:[^[:space:]]+$'
RE_IP='^[0-9]{1,3}(\.[0-9]{1,3}){3}$|^[0-9a-fA-F:]+$'

die() { printf '[node-agent] %s\n' "$*" >&2; exit 1; }

CMD="${SSH_ORIGINAL_COMMAND:-}"
[ -n "$CMD" ] || die "没收到命令。这个入口只接受 list / add / remove / certs / status。"

# 关键：用 `read -a` 做纯空白切分，**不解析引号**。这正是我们要的效果 ——
# 客户端塞进来的任何引号、分号、$() 都会原样变成独立 token，随后被下面的
# 正则校验拒掉。全程没有 eval，也就不存在命令注入。
read -r -a A <<<"$CMD"
ACT="${A[0]:-}"

case "$ACT" in

list)
	[ "${#A[@]}" -eq 1 ] || die "list 不接受参数"
	shopt -s nullglob
	for p in "$SITES_DIR"/*.conf; do
		d="$(basename "$p" .conf)"
		u="$(sed -nE 's/^[[:space:]]*reverse_proxy[[:space:]]+([^[:space:]{]+).*/\1/p' "$p" | head -1)"
		f=""
		grep -q 'dns cloudflare' "$p" 2>/dev/null && f="${f}dns01,"
		grep -q 'basic_auth' "$p" 2>/dev/null && f="${f}auth,"
		f="${f%,}"
		# ⚠️ 没有标记时输出 "-"，不要留空。
		# 面板侧 sh() 会对整段 stdout 做 .strip()，只作用于字符串末尾 ——
		# 若最后一行以空字段收尾（行尾 TAB），TAB 会被吃掉，那一行就从 3 段变 2 段，
		# 被解析器当成坏行丢掉（表现：面板里随机少一个站点）。
		# 给个占位符，行结构就恒定了。
		[ -n "$f" ] || f="-"
		printf '%s\t%s\t%s\n' "$d" "$u" "$f"
	done
	;;

status)
	[ "${#A[@]}" -eq 1 ] || die "status 不接受参数"
	printf 'caddy=%s\n' "$(systemctl is-active caddy 2>/dev/null || echo unknown)"
	printf 'version=%s\n' "$(caddy version 2>/dev/null | head -1 | awk '{print $1}')"
	printf 'hostname=%s\n' "$(hostname 2>/dev/null || echo unknown)"
	printf 'sites=%s\n' "$(ls -1 "$SITES_DIR"/*.conf 2>/dev/null | wc -l | tr -d ' ')"
	;;

certs)
	[ "${#A[@]}" -eq 1 ] || die "certs 不接受参数"
	shopt -s nullglob
	for crt in "$CERT_BASE"/*/*/*.crt; do
		n="$(basename "$(dirname "$crt")")"
		e="$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2)"
		printf '%s\t%s\n' "$n" "$e"
	done
	;;

add)
	[ "${#A[@]}" -ge 3 ] || die "add 用法：add <域名> <上游> [选项]"
	[ -x "$ADD_SITE" ] || die "找不到 $ADD_SITE —— 这台机器还没装 domain-autopilot"
	DOMAIN="${A[1]}"
	[[ "$DOMAIN" =~ $RE_DOMAIN ]] || die "域名不合法：$DOMAIN"
	ARGS=("$DOMAIN" "${A[2]}")
	if [ "${#A[@]}" -gt 3 ]; then
		i=3
		while [ "$i" -lt "${#A[@]}" ]; do
			case "${A[$i]}" in
			--dns | --proxy | --no-api-dns | --cname | --insecure)
				ARGS+=("${A[$i]}")
				i=$((i + 1))
				;;
			--ip)
				[ $((i + 1)) -lt "${#A[@]}" ] || die "--ip 缺少值"
				[[ "${A[$((i + 1))]}" =~ $RE_IP ]] || die "--ip 值不合法"
				ARGS+=("--ip" "${A[$((i + 1))]}")
				i=$((i + 2))
				;;
			--auth)
				[ $((i + 1)) -lt "${#A[@]}" ] || die "--auth 缺少值"
				[[ "${A[$((i + 1))]}" =~ $RE_AUTH ]] || die "--auth 值应为 用户:密码"
				ARGS+=("--auth" "${A[$((i + 1))]}")
				i=$((i + 2))
				;;
			*)
				die "不支持的选项：${A[$i]}"
				;;
			esac
		done
	fi
	exec "$ADD_SITE" "${ARGS[@]}"
	;;

remove)
	[ "${#A[@]}" -eq 2 ] || die "remove 用法：remove <域名>"
	[ -x "$ADD_SITE" ] || die "找不到 $ADD_SITE —— 这台机器还没装 domain-autopilot"
	[[ "${A[1]}" =~ $RE_DOMAIN ]] || die "域名不合法：${A[1]}"
	exec "$ADD_SITE" --remove "${A[1]}"
	;;

*)
	die "不认识的命令：$ACT（只支持 list / add / remove / certs / status）"
	;;
esac
