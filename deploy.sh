#!/usr/bin/env bash
# deploy.sh - 【可选】从本地电脑把整套方案推到 VPS
#
# 这是给不方便在 VPS 上操作的人准备的备选路径，不是必需的。
# 推荐做法：直接到 VPS 上跑 bootstrap.sh，全程不碰本地电脑。
# 见 README 第 0 节。
#
# 本脚本唯一做的事：把 bootstrap.sh 送到 VPS 并调用它。
# 安装逻辑只有一份，全在 bootstrap.sh / setup.sh 里，两条路径共用。
#
# 用法：
#   bash deploy.sh root@1.2.3.4                           # 向导会补问邮箱和 Token
#   bash deploy.sh root@1.2.3.4 -p 2222 -i ~/.ssh/key
#   CF_TOKEN=xxx LE_EMAIL=a@b.c bash deploy.sh root@1.2.3.4   # 全自动
#   bash deploy.sh root@1.2.3.4 --dry-run                  # 只看会做什么
#
# 依赖：本机要有 ssh / tar（Windows 10+ 自带 OpenSSH，Git Bash 自带 tar）
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET=""
SSH_PORT=22
KEY_FILE="${KEY_FILE:-}"
EMAIL="${LE_EMAIL:-}"
CF_TOKEN_INPUT="${CF_TOKEN:-}"
VERIFY_TOKEN=1
TOKEN_VERIFIED=0
REMOTE_STAGE="/root/.domain-autopilot-stage"
REMOTE_DIR="/opt/domain-autopilot"
DRY_RUN=0
TUNNEL=0
DO_INSTALL=1
ANS=""

log()  { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
info() { printf '\033[36m[--]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[!!]\033[0m %s\n' "$*" >&2; }
line() { printf '\033[90m%s\033[0m\n' "──────────────────────────────────────────────"; }

usage() {
	cat <<'EOF'
用法: deploy.sh [user@host] [选项]

这是可选路径。推荐直接在 VPS 上跑 bootstrap.sh，不需要本地参与。

选项:
  -p, --port PORT   SSH 端口（默认 22）
  -i, --key FILE    SSH 私钥路径
  -e, --email MAIL  Let's Encrypt 通知邮箱
      --cf-token T  Cloudflare API Token
      --no-install  只上传文件，不执行安装
      --tunnel      安装完成后建立 8848 SSH 隧道（Ctrl-C 结束）
      --skip-verify 不校验 Cloudflare Token 有效性
  -n, --dry-run     只打印将要执行的命令
  -h, --help        显示本帮助

环境变量:
  CF_TOKEN    Cloudflare API Token（设了就不问）
  LE_EMAIL    同 --email
EOF
}

prompt_val() {
	local tip="$1" def="$2" v=""
	if [ -n "$def" ]; then
		printf '    \033[33m?\033[0m %s \033[90m[%s]\033[0m\n    \033[33m>\033[0m ' "$tip" "$def"
	else
		printf '    \033[33m?\033[0m %s\n    \033[33m>\033[0m ' "$tip"
	fi
	read -r v || true
	[ -n "$v" ] || v="$def"
	ANS="$v"
}

prompt_secret() {
	local v=""
	printf '    \033[33m?\033[0m %s\n    \033[33m>\033[0m ' "$1"
	read -rs v || true
	printf '\n'
	ANS="$(printf '%s' "$v" | tr -d '[:space:]')"
}

cf_verify_token() {
	local t="$1" resp
	command -v curl >/dev/null 2>&1 || { info "本机没有 curl，跳过 Token 校验"; return 0; }
	resp="$(curl -s --max-time 12 -H "Authorization: Bearer $t" \
		-H "Content-Type: application/json" \
		https://api.cloudflare.com/client/v4/user/tokens/verify 2>/dev/null)" || resp=""
	[ -z "$resp" ] && { info "访问不了 api.cloudflare.com，跳过校验"; return 0; }
	printf '%s' "$resp" | grep -q '"success":[[:space:]]*true'
}

run_wizard() {
	echo
	line
	printf '\033[36m  部署配置向导\033[0m\n'
	line
	info "提示：这是可选的本地路径。在 VPS 上直接跑 bootstrap.sh 更省事。"
	echo

	[ -n "$TARGET" ] || {
		prompt_val "目标服务器（user@host）" ""
		TARGET="$ANS"
		case "$TARGET" in *@*) ;; *) err "格式应为 user@host"; exit 1 ;; esac
		prompt_val "SSH 端口" "22"
		SSH_PORT="${ANS:-22}"
		prompt_val "SSH 私钥路径（留空用默认密钥）" ""
		KEY_FILE="$ANS"
	}

	if [ "$DO_INSTALL" -eq 1 ]; then
		[ -n "$EMAIL" ] || { prompt_val "Let's Encrypt 通知邮箱" ""; EMAIL="$ANS"; }

		if [ -z "$CF_TOKEN_INPUT" ]; then
			echo
			info "Cloudflare API Token：https://dash.cloudflare.com/profile/api-tokens"
			info "模板选 Edit zone DNS，权限需含 Zone→DNS→Edit 与 Zone→Zone→Read"
			while :; do
				prompt_secret "粘贴 Cloudflare API Token（不可见；留空则安装时再问）"
				CF_TOKEN_INPUT="$ANS"
				[ -z "$CF_TOKEN_INPUT" ] && { info "留空：安装时在服务器上问你"; break; }
				[ "$VERIFY_TOKEN" -eq 0 ] && { warn "已指定 --skip-verify"; break; }
				if cf_verify_token "$CF_TOKEN_INPUT"; then
					log "Token 校验通过"; TOKEN_VERIFIED=1; break
				fi
				err "Token 校验未通过"
				prompt_val "重输新 Token；确认无误想跳过校验请输入 keep" ""
				case "$ANS" in
					keep | KEEP) warn "跳过校验，继续"; break ;;
					"") continue ;;
					*)
						CF_TOKEN_INPUT="$(printf '%s' "$ANS" | tr -d '[:space:]')"
						cf_verify_token "$CF_TOKEN_INPUT" && { log "Token 校验通过"; TOKEN_VERIFIED=1; } \
							|| warn "仍未通过，按你的输入继续"
						break ;;
				esac
			done
		fi
	fi

	echo
	line
	printf '\033[36m  配置确认\033[0m\n'
	line
	printf '  目标服务器 : %s （端口 %s）\n' "$TARGET" "$SSH_PORT"
	[ -n "$KEY_FILE" ] && printf '  SSH 私钥   : %s\n' "$KEY_FILE"
	printf '  LE 邮箱    : %s\n' "$EMAIL"
	if [ -n "$CF_TOKEN_INPUT" ]; then
		printf '  CF Token   : %s…%s （%s）\n' "${CF_TOKEN_INPUT:0:4}" "${CF_TOKEN_INPUT: -4}" \
			"$([ "$TOKEN_VERIFIED" -eq 1 ] && echo '已验证' || echo '未验证')"
	else
		printf '  CF Token   : 未填（安装时在服务器上问）\n'
	fi
	line
	prompt_val "确认开始部署？输入 y 继续，其他任意键取消" "y"
	case "$ANS" in y | Y | yes | YES) ;; *) info "已取消"; exit 0 ;; esac
}

while [ $# -gt 0 ]; do
	case "$1" in
		-h | --help) usage; exit 0 ;;
		-p | --port) SSH_PORT="$2"; shift 2 ;;
		-i | --key) KEY_FILE="$2"; shift 2 ;;
		-e | --email) EMAIL="$2"; shift 2 ;;
		--cf-token) CF_TOKEN_INPUT="$2"; shift 2 ;;
		--no-install) DO_INSTALL=0; shift ;;
		--tunnel) TUNNEL=1; shift ;;
		--skip-verify) VERIFY_TOKEN=0; shift ;;
		-n | --dry-run) DRY_RUN=1; shift ;;
		-*) err "未知参数: $1"; usage; exit 1 ;;
		*) TARGET="$1"; shift ;;
	esac
done

if [ "$DRY_RUN" -eq 0 ]; then
	if [ -t 0 ]; then run_wizard
	else info "非交互环境，跳过向导（用 CF_TOKEN / LE_EMAIL 环境变量传参）"; fi
fi

[ -n "$TARGET" ] || { err "请给出目标主机：bash deploy.sh root@1.2.3.4"; usage; exit 1; }
case "$TARGET" in *@*) ;; *) err "格式应为 user@host"; exit 1 ;; esac

EMAIL_ESC="$(printf '%s' "${EMAIL:-}" | sed "s/'/'\\\\''/g")"

echo
echo "== 0/4 本地检查 =="
REQUIRED="bootstrap.sh update.sh setup.sh Caddyfile cf.sh add-site.sh sync-dns.sh enable-cf-native.sh admin-api.py admin-ui.html admin-api.service"
MISSING=0
for f in $REQUIRED; do
	if [ -f "$DIR/$f" ]; then printf '  \033[32m✓\033[0m %s\n' "$f"
	else printf '  \033[31m✗\033[0m %s（缺失）\n' "$f"; MISSING=1; fi
done
[ "$MISSING" -eq 0 ] || { err "文件不齐，放弃"; exit 1; }
for c in ssh tar; do command -v "$c" >/dev/null 2>&1 || { err "本机缺少 $c"; exit 1; }; done

SSH_OPTS="-p $SSH_PORT -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ConnectTimeout=10"
[ -n "$KEY_FILE" ] && SSH_OPTS="$SSH_OPTS -i $KEY_FILE"

echo "== 1/4 连通性检查 =="
if [ "$DRY_RUN" -eq 1 ]; then
	info "跳过（dry-run）"
else
	ssh $SSH_OPTS "$TARGET" 'echo "  $(hostname) / $([ -r /etc/os-release ] && . /etc/os-release && echo "$PRETTY_NAME") / $(uname -m)"' \
		|| { err "连不上 $TARGET，检查 IP / 端口 / 密钥"; exit 1; }
	log "连得上 $TARGET"
fi

echo "== 2/4 上传 bootstrap.sh 与源码到 $REMOTE_STAGE =="
UPLOAD="tar czf - -C '$DIR' --exclude='__pycache__' --exclude='.git' . | \
ssh $SSH_OPTS '$TARGET' \"rm -rf $REMOTE_STAGE && mkdir -p $REMOTE_STAGE && tar xzf - -C $REMOTE_STAGE\""
if [ "$DRY_RUN" -eq 1 ]; then
	echo "  $UPLOAD"
else
	# shellcheck disable=SC2086
	tar czf - -C "$DIR" --exclude='__pycache__' --exclude='.git' . \
		| ssh $SSH_OPTS "$TARGET" "rm -rf $REMOTE_STAGE && mkdir -p $REMOTE_STAGE && tar xzf - -C $REMOTE_STAGE"
	log "已上传，安装目录将是 $REMOTE_DIR"
fi

if [ "$DO_INSTALL" -eq 0 ]; then
	log "按 --no-install 要求，只上传未安装。"
	info "要装就 ssh 上去：bash $REMOTE_STAGE/bootstrap.sh --local-dir $REMOTE_STAGE"
	exit 0
fi

echo "== 3/4 调用 VPS 端 bootstrap.sh 执行安装 =="
TOKEN_ARG=""
if [ -n "$CF_TOKEN_INPUT" ]; then
	if [ "$DRY_RUN" -eq 0 ]; then
		printf '%s' "$CF_TOKEN_INPUT" | ssh $SSH_OPTS "$TARGET" "umask 077; cat > /root/.cf_token.tmp"
		log "Token 已安全传到远端临时文件（装完即删，不进命令行）"
	fi
	TOKEN_ARG="CF_TOKEN_FILE=/root/.cf_token.tmp"
fi

REMOTE_CMD="cd $REMOTE_STAGE && ${TOKEN_ARG:+$TOKEN_ARG }${EMAIL_ESC:+LE_EMAIL='$EMAIL_ESC' }bash bootstrap.sh --local-dir $REMOTE_STAGE; rc=\$?; rm -rf '$REMOTE_STAGE' /root/.cf_token.tmp; exit \$rc"
if [ "$DRY_RUN" -eq 1 ]; then
	echo "  ssh -t $SSH_OPTS $TARGET \"$REMOTE_CMD\""
	exit 0
fi
# shellcheck disable=SC2086
ssh -t $SSH_OPTS "$TARGET" "$REMOTE_CMD" || { err "安装返回非零，看上面输出"; exit 1; }
# shellcheck disable=SC2086
ssh $SSH_OPTS "$TARGET" "rm -rf '$REMOTE_STAGE' /root/.cf_token.tmp" >/dev/null 2>&1 || true

echo "== 4/4 完成 =="
cat <<EOF

之后的日常全部在 VPS 上做：
  ssh $SSH_OPTS $TARGET
  add-site.sh 你的域名 127.0.0.1:8080
  domain-autopilot-update          # 更新这套工具

开管理面板隧道（在你自己电脑上执行）：
  ssh -N -L 8848:127.0.0.1:8848 $TARGET -p $SSH_PORT
  浏览器打开 http://localhost:8848
EOF

if [ "$TUNNEL" -eq 1 ]; then
	info "正在建立隧道 http://localhost:8848 ...（Ctrl-C 结束）"
	# shellcheck disable=SC2086
	ssh -N -L 8848:127.0.0.1:8848 $SSH_OPTS "$TARGET"
fi
