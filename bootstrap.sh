#!/usr/bin/env bash
# bootstrap.sh - 在 VPS 上从头自举整套 domain-autopilot
#
# 全流程都在 VPS 上完成，不依赖任何本地电脑。
#
# 用法（VPS 上，root 身份）：
#   bash bootstrap.sh                          # 公开仓库匿名下载 + 安装（推荐，不用任何凭据）
#   bash bootstrap.sh --token ghp_xxxx         # 私有仓库：用 PAT 下载
#   bash bootstrap.sh --local-dir /root/da     # 源码已在机器上，跳过拉取直接装
#   bash bootstrap.sh --skip-setup             # 只拉代码，不执行安装
#   bash bootstrap.sh --update                 # 只更新已装的 deployment
#
# 环境变量（跟命令行参数等价，适合非交互场景）：
#   GITHUB_TOKEN  仅私有仓库需要；公开仓库留空即可走匿名下载
#   CF_TOKEN      Cloudflare API Token
#   LE_EMAIL      Let's Encrypt 通知邮箱
#
# 拉代码的三条路，按顺序尝试 / 按需选择：
#   1. 公开仓库匿名下载  默认        零凭据，最省事
#   2. GitHub PAT        --token    私有仓库全自动
#   3. SSH deploy key    交互式引导  一次配置，之后永久可用
#   4. 本地已有源码      --local-dir 离线场景
set -euo pipefail

REPO_OWNER="${REPO_OWNER:-easun1874}"
REPO_NAME="${REPO_NAME:-domain-autopilot}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/domain-autopilot}"
KEY_FILE="$HOME/.ssh/${REPO_NAME}_ed25519"
API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
LOCAL_DIR=""
SKIP_SETUP=0
UPDATE_ONLY=0
ASSUME_YES=0
CF_TOKEN_INPUT="${CF_TOKEN:-}"
LE_EMAIL_INPUT="${LE_EMAIL:-}"

log()  { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
info() { printf '\033[36m[--]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[!!]\033[0m %s\n' "$*" >&2; }
line() { printf '\033[90m%s\033[0m\n' '──────────────────────────────────────────────'; }

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
	case "$1" in
		-t | --token)      GITHUB_TOKEN="$2"; shift 2 ;;
		-d | --local-dir)  LOCAL_DIR="$2"; shift 2 ;;
		-b | --branch)     BRANCH="$2"; shift 2 ;;
		-e | --email)      LE_EMAIL_INPUT="$2"; shift 2 ;;
		--cf-token)        CF_TOKEN_INPUT="$2"; shift 2 ;;
		--skip-setup)      SKIP_SETUP=1; shift ;;
		--update)          UPDATE_ONLY=1; shift ;;
		-y | --yes)        ASSUME_YES=1; shift ;;
		-h | --help)       usage ;;
		*) err "未知参数: $1"; usage; exit 1 ;;
	esac
done

echo
line
printf '\033[36m  domain-autopilot · VPS 端自举\033[0m\n'
line

# ---------- 0. 基础检查 ----------
if [ "$(id -u)" -ne 0 ]; then err "请用 root 执行：sudo -i"; exit 1; fi

need_cmd() { command -v "$1" >/dev/null 2>&1; }

for c in curl tar; do
	if ! need_cmd "$c"; then
		info "缺少 $c，正在安装"
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq && apt-get install -y -qq curl tar >/dev/null 2>&1 \
			|| { err "装不上 $c，请先手动安装"; exit 1; }
	fi
done
log "基础命令就绪"

# ---------- 1. 更新模式：直接走已装的部署 ----------
if [ "$UPDATE_ONLY" -eq 1 ]; then
	[ -d "$INSTALL_DIR/.git" ] || [ -d "$INSTALL_DIR" ] \
		|| { err "$INSTALL_DIR 不存在，请先完整 bootstrap"; exit 1; }
	exec bash "$INSTALL_DIR/update.sh" ${ASSUME_YES:+-y}
fi

# ---------- 2. 本地源码模式 ----------
if [ -n "$LOCAL_DIR" ]; then
	[ -d "$LOCAL_DIR" ] || { err "--local-dir 指向的目录不存在：$LOCAL_DIR"; exit 1; }
	info "使用本地源码：$LOCAL_DIR"
	mkdir -p "$INSTALL_DIR"
	( cd "$LOCAL_DIR" && tar cf - --exclude='.git' --exclude='__pycache__' --exclude='*.tgz' --exclude='*.tar.gz' . ) \
		| tar xf - -C "$INSTALL_DIR"
	log "源码已就位：$INSTALL_DIR"
	run_setup=1
else
	run_setup=1
	# ---------- 3. 从 GitHub 拉代码 ----------
	ensure_key() {
		if [ -f "$KEY_FILE" ]; then log "复用已有密钥：$KEY_FILE"; return 0; fi
		info "生成专用 SSH 密钥（不设密码）"
		mkdir -p "$(dirname "$KEY_FILE")" && chmod 700 "$(dirname "$KEY_FILE")"
		ssh-keygen -t ed25519 -N '' -C "${REPO_NAME}-deploy" -f "$KEY_FILE" -q
		chmod 600 "$KEY_FILE"
		log "密钥已生成"
	}

	try_clone() {
		local host="$1" port="$2"
		GIT_SSH_COMMAND="ssh -p $port -i $KEY_FILE -o StrictHostKeyChecking=accept-new \
-o IdentitiesOnly=yes -o ConnectTimeout=10" \
			git clone --depth 1 -b "$BRANCH" "git@${host}:${REPO_OWNER}/${REPO_NAME}.git" \
			"$INSTALL_DIR" >/dev/null 2>&1
	}

	fetch_ok=0

	# 3-A. GitHub PAT —— 全自动，优先走这条路
	if [ -n "$GITHUB_TOKEN" ]; then
		info "检测到 GitHub Token，用 API 下载源码包"
		tmp="$(mktemp -d)"
		if curl -fsSL --max-time 90 \
			-H "Authorization: Bearer $GITHUB_TOKEN" \
			-H "Accept: application/vnd.github+json" \
			"$API/tarball/$BRANCH" -o "$tmp/src.tar.gz" 2>/dev/null; then
			rm -rf "$INSTALL_DIR"; mkdir -p "$INSTALL_DIR"
			tar xzf "$tmp/src.tar.gz" -C "$INSTALL_DIR" --strip-components=1
			rm -rf "$tmp"
			log "源码已下载到 $INSTALL_DIR"
			fetch_ok=1
		else
			err "Token 下载失败：Token 无效，或没有本仓库的读取权限"
			rm -rf "$tmp"
			exit 1
		fi
	fi

	# 3-A2. 公开仓库匿名下载 —— 不需要任何凭据，私有仓库会自然失败并往下走
	if [ "$fetch_ok" -eq 0 ] && [ -z "$GITHUB_TOKEN" ]; then
		info "未提供 GitHub Token，先试公开仓库匿名下载"
		tmp="$(mktemp -d)"
		if curl -fsSL --max-time 90 \
			"https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${BRANCH}" \
			-o "$tmp/src.tar.gz" 2>/dev/null; then
			rm -rf "$INSTALL_DIR"; mkdir -p "$INSTALL_DIR"
			tar xzf "$tmp/src.tar.gz" -C "$INSTALL_DIR" --strip-components=1
			rm -rf "$tmp"
			log "源码已下载到 $INSTALL_DIR"
			fetch_ok=1
		else
			rm -rf "$tmp"
			info "匿名下载失败（仓库可能是私有的），转 SSH deploy key"
		fi
	fi

	# 3-B. SSH deploy key
	if [ "$fetch_ok" -eq 0 ]; then
		need_cmd git || { info "安装 git"; apt-get install -y -qq git >/dev/null 2>&1; }
		ensure_key

		if [ ! -d "$INSTALL_DIR/.git" ] && try_clone github.com 22; then
			log "clone 成功（github.com:22）"; fetch_ok=1
		fi
		if [ "$fetch_ok" -eq 0 ] && [ ! -d "$INSTALL_DIR/.git" ] && try_clone ssh.github.com 443; then
			log "clone 成功（ssh.github.com:443）"; fetch_ok=1
		fi

		if [ "$fetch_ok" -eq 0 ]; then
			echo
			line
			printf '\033[33m  需要一次授权：把下面的公钥加到 GitHub\033[0m\n'
			line
			echo
			cat "$KEY_FILE.pub"
			echo
			echo "  添加地址（Deploy keys，只读即可，不用勾 Allow write access）："
			echo "  https://github.com/${REPO_OWNER}/${REPO_NAME}/settings/keys"
			echo
			if [ -t 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
				printf '  加完之后按回车继续 \033[90m(或输入 token 直接下载)\033[0m\n    \033[33m>\033[0m '
				read -r ans || true
			else
				ans=""
			fi
			if [ -n "$ans" ]; then
				GITHUB_TOKEN="$(printf '%s' "$ans" | tr -d '[:space:]')"
				tmp="$(mktemp -d)"
				if curl -fsSL --max-time 90 -H "Authorization: Bearer $GITHUB_TOKEN" \
					-H "Accept: application/vnd.github+json" \
					"$API/tarball/$BRANCH" -o "$tmp/src.tar.gz" 2>/dev/null; then
					rm -rf "$INSTALL_DIR"; mkdir -p "$INSTALL_DIR"
					tar xzf "$tmp/src.tar.gz" -C "$INSTALL_DIR" --strip-components=1
					rm -rf "$tmp"
					log "源码已下载到 $INSTALL_DIR"
					fetch_ok=1
				else
					err "Token 仍然无效"; rm -rf "$tmp"; exit 1
				fi
			else
				if try_clone github.com 22 || try_clone ssh.github.com 443; then
					log "clone 成功"; fetch_ok=1
				else
					err "还是拉不到。确认公钥已加到 Deploy keys，或改用 --token"
					exit 1
				fi
			fi
		fi
	fi
fi

# ---------- 4. 完整性检查 ----------
REQUIRED="Caddyfile cf.sh add-site.sh sync-dns.sh enable-cf-native.sh install-caddy-modules.sh node-agent.sh setup.sh admin-api.py admin-ui.html admin-api.service"
MISSING=0
for f in $REQUIRED; do
	[ -f "$INSTALL_DIR/$f" ] || { err "缺失文件：$f"; MISSING=1; }
done
[ "$MISSING" -eq 0 ] || { err "源码不完整，放弃"; exit 1; }
log "源码完整性检查通过（$(printf '%s' "$REQUIRED" | wc -w | tr -d ' ') 个文件）"

chmod +x "$INSTALL_DIR"/*.sh 2>/dev/null || true

# ---------- 5. 安装 update 命令 ----------
if [ -f "$INSTALL_DIR/update.sh" ]; then
	if install -m 755 "$INSTALL_DIR/update.sh" /usr/local/bin/domain-autopilot-update 2>/dev/null; then
		log "已提供更新命令：domain-autopilot-update"
	else
		warn "写不进 /usr/local/bin（权限不足？）。不影响继续，但以后要手动：bash $INSTALL_DIR/update.sh"
	fi
fi

if [ "$SKIP_SETUP" -eq 1 ]; then
	echo
	log "按 --skip-setup 要求，只拉代码未安装。"
	info "要装就跑：cd $INSTALL_DIR && bash setup.sh"
	exit 0
fi

# ---------- 6. 执行安装 ----------
echo
info "开始执行 setup.sh —— 装 Caddy / 防火墙 / 脚本 / 巡检 / 面板"
echo

cd "$INSTALL_DIR"
SETUP_ENV=""
if [ -n "$CF_TOKEN_INPUT" ]; then
	tmp_token="$(mktemp /root/.cf_token.XXXXXX)"
	# ⚠️ umask 只在这几行内生效，写完立刻还原。
	# 这里踩过一个狠坑：umask 077 会**继承给后面 exec 出去的 setup.sh**，让它
	# 建出来的目录和文件全是 700/600 —— 包括 /etc/caddy 和 /etc/caddy/sites。
	# 而 Caddy 是以 caddy 用户运行的，读不到自己的 Caddyfile，服务直接
	# permission denied 起不来。（mktemp 本身就已经给 600，这行只是双保险。）
	OLD_UMASK="$(umask)"
	umask 077
	printf '%s' "$CF_TOKEN_INPUT" > "$tmp_token"
	umask "$OLD_UMASK"
	SETUP_ENV="CF_TOKEN_FILE=$tmp_token"
	log "Cloudflare Token 已写入临时文件（装完即删，不进命令行）"
fi
[ -n "$LE_EMAIL_INPUT" ] && SETUP_ENV="$SETUP_ENV LE_EMAIL=$LE_EMAIL_INPUT"

# shellcheck disable=SC2086
if env $SETUP_ENV bash setup.sh; then
	SETUP_RC=0
else
	SETUP_RC=$?
fi
[ -n "${tmp_token:-}" ] && rm -f "$tmp_token"

if [ "$SETUP_RC" -ne 0 ]; then
	err "setup.sh 返回非零（$SETUP_RC），看上面输出定位"
	exit "$SETUP_RC"
fi

echo
line
printf '\033[32m  全部搞定。以后加站点就一条命令：\033[0m\n'
line
cat <<EOF

  add-site.sh 你的域名 127.0.0.1:8080

  更新这套工具本身：
  domain-autopilot-update

  源码位置：$INSTALL_DIR
EOF
