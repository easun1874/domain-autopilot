# domain-autopilot

**一台 VPS，无限 HTTPS 站点。加站点只用一行命令 —— 或者在 Telegram 里发一句话。**

[![CI](https://github.com/easun1874/domain-autopilot/actions/workflows/ci.yml/badge.svg)](https://github.com/easun1874/domain-autopilot/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-89e051.svg)](https://www.gnu.org/software/bash/)
[![Python](https://img.shields.io/badge/python-3.8%2B%20stdlib%20only-3776ab.svg)](https://www.python.org/)
[![Caddy](https://img.shields.io/badge/caddy-v2-fdd995.svg)](https://caddyserver.com/)

项目主页源文件：`docs/index.html`（浏览器直接打开即可，无需服务器）

> **发布形态**：本仓库公开托管（MIT）。安装与更新走匿名下载，不需要任何 GitHub
> Token。项目主页源文件 `docs/index.html` 用浏览器直接打开即可，无需服务器；
> GitHub Pages 未启用——这个主页的定位是自用文档，没有公开托管的必要。
> CI 会跑语法检查、面板冒烟测试和「敏感文件不入库」，公开仓库下照常运行。

---

目标：一台有公网 IP 的 VPS 跑很多服务，通过域名安全访问。
**Cloudflare 的 DNS 记录、Let's Encrypt 证书签发与续签，全部自动完成，不用手动操作。**

---

## 0. 部署：SSH 上去，粘一段命令，完事

全程三步，没有任何一步需要本地电脑参与：

| 步 | 在哪 | 干什么 |
|---|---|---|
| 1 | 你自己的 Windows | `ssh` 登到 VPS（之后就忘了本地这回事） |
| 2 | VPS | **粘贴一段命令** |
| 3 | VPS | 跟着提示输两个 Token，然后看它装完 |

### 第 1 步：登上去

```bash
ssh -p 2222 root@203.0.113.10
```

### 第 2 步：粘贴这一段，回车

```bash
curl -fsSL -o /tmp/da.tgz https://codeload.github.com/easun1874/domain-autopilot/tar.gz/refs/heads/main
mkdir -p /tmp/da-src && tar xzf /tmp/da.tgz -C /tmp/da-src --strip-components=1
bash /tmp/da-src/bootstrap.sh --local-dir /tmp/da-src
```

仓库是**公开**的，不需要任何 GitHub Token，三行直接跑。

### 第 3 步：跟着提示走

`bootstrap.sh` 接手之后会把源码落到 `/opt/domain-autopilot`，然后自动进入安装。
中途它会停下来问你一次 **Cloudflare API Token**（第 2 节讲怎么拿）：

```
== 3/9 写入 Cloudflare API Token ==
  粘贴 Cloudflare API Token（输入不可见，回车继续）:
```

输完之后一路到底：

```
[ok] 基础命令就绪
[ok] 源码已就位：/opt/domain-autopilot
[ok] 源码完整性检查通过（9 个文件）
[ok] 已提供更新命令：domain-autopilot-update
[--] 开始执行 setup.sh —— 装 Caddy / 防火墙 / 脚本 / 巡检 / 面板

  1/9 安装 Caddy / jq / python3
  2/9 防火墙放行（含 SSH，避免把自己关在门外）
  3/9 写入 Cloudflare API Token      ← 这里问你 CF Token
  4/9 写入 Caddy 配置
  5/9 安装管理脚本
  6/9 校验并启动 Caddy
  7/9 注册巡检定时任务
  8/9 打开 Caddy 原生 Cloudflare 集成
  9/9 安装管理面板
```

> **全程只需要一个 Token**：Cloudflare API Token，屏幕提示是 `粘贴 Cloudflare API Token`。
> 没有第二个 —— 源码是公开仓库直下的，不用 GitHub 凭据。

### 第 4 步：加第一个站点

```bash
add-site.sh app.example.com 127.0.0.1:8080
```

一行命令自动：建 Cloudflare DNS 记录 → 签证书 → 配反代 → 热加载。**以后加站点都用这一条。**

### 之后的日常（全在 VPS 上）

| 想干什么 | 命令 |
|---|---|
| 加站点 | `add-site.sh 域名 127.0.0.1:8080` |
| 删站点（连带删 DNS） | `add-site.sh -r 域名` |
| 立即巡检一次 | `sync-dns.sh` |
| 只看不动手 | `sync-dns.sh --check` |
| 更新这套工具本身 | `domain-autopilot-update` |
| 看看有没有新版 | `domain-autopilot-update --check` |

### 部署前必查的两件事

1. **云厂商控制台的安全组要放行 80 / 443**。各家叫法不同：Oracle 叫 Security List，阿里云/腾讯云叫安全组，AWS 叫 Security Group。只配系统防火墙没用，这是最常踩的坑。
2. **域名必须已经托管到 Cloudflare**，并且 CF Token 得有这个域的权限。

---

## 0.1 本机推送（可选，非必需）

如果你手边正好有笔记本、不方便在 VPS 上操作，才有这一节。**正常请走上面第 0 节。**

```bash
bash deploy.sh root@203.0.113.10 -p 2222 -i ~/.ssh/id_ed25519
```

`deploy.sh` 只做一件事：把源码打包传到 VPS，然后调用 VPS 上的 `bootstrap.sh`。
**安装逻辑只有一份**，两条路径共用，不会出现"本机装的和服务器上装的不一样"。

不加 `--dry-run` 之外的任何参数时它会进向导，依次问：目标服务器 → SSH 端口 → 私钥 → LE 邮箱 → CF Token。
Token 不回显且当场调 Cloudflare 官方接口验真假。想先看它会干什么：

```bash
bash deploy.sh root@203.0.113.10 -p 2222 -i ~/.ssh/id_ed25519 --dry-run
```

---

## 0.2 常见疑问

**Q：一堆脚本，到底该跑哪个？**

| 脚本 | 在哪跑 | 什么时候跑 |
|---|---|---|
| `bootstrap.sh` | **【VPS】** | **首次安装，跑这一个就够** |
| `setup.sh` | 【VPS】 | 由 bootstrap 自动调用，一般不用手动跑 |
| `deploy.sh` | 【本机】 | 可选路径，见 0.1 节 |
| `update.sh` | 【VPS】 | 更新工具本身，装好后命令名叫 `domain-autopilot-update` |
| `add-site.sh` | 【VPS】 | 每次加/删站点 |

**Q：`add-site.sh` 前面为啥不加 `bash`、也不加 `./`？**
因为 `setup.sh` 已经把它装到 `/usr/local/bin/` 并加了执行权限，【VPS】上直接当命令敲。
只有在源码目录里测试时才需要 `bash add-site.sh`。

**Q：bootstrap 之后还需要 GitHub Token 吗？**
不需要了。源码已经在 `/opt/domain-autopilot`，`domain-autopilot-update` 默认不再联网取授权。
除非你要从 GitHub 拉新版，那才需要重新给一次。

**Q：部署完怎么打开那个 Web 面板？**
在你自己电脑上另开终端建隧道，浏览器访问 `http://localhost:8848`：

```bash
ssh -N -L 8848:127.0.0.1:8848 -p 2222 root@203.0.113.10
```

面板默认只监听服务器自己的 `127.0.0.1`，不对外，这是刻意的。

> **连不上 SSH、隧道开不起来？** 跨境链路偶尔会在密钥交换阶段重置连接。典型现象是
> 报 `Connection closed by <服务器IP> port <端口>`，`ssh -vv` 停在
> `expecting SSH2_MSG_KEX_ECDH_REPLY`，而同一台机器的 443 完全正常——说明不是 IP 被封，
> 也不是服务器问题，是链路上针对 SSH 的协议级干扰，通常几分钟就自己好了。
>
> 两招，按顺序试：
>
> 1. 加 `-o KexAlgorithms=curve25519-sha256` 禁掉后量子 KEX；
> 2. 还不行，就把 SSH 塞进代理：用 `ProxyCommand` 让 ssh 先经你的代理做 HTTP CONNECT，
>    再连目标的 SSH 端口。跨境那一跳换成代理自己的协议，就绕开了干扰。用 `nc`/`socat`
>    或几十行 Python 都能实现（本仓库不含这个中转脚本，属于你本地环境的一部分）。

**Q：装崩了能重来吗？**
能。所有脚本都幂等，`bootstrap.sh` 和 `setup.sh` 重复跑不会把事情搞得更糟，已有站点和 Token 不丢。

---

---

## 1. 前置准备

| 项目 | 要求 | 确认方式 |
|---|---|---|
| VPS 系统 | Ubuntu 20.04+ / Debian 11+ | `cat /etc/os-release` |
| root 权限 | 是 | `sudo -i` 可进 |
| 域名在 Cloudflare 托管 | 是 | `dig NS example.com` 看到 CF 的 NS |
| 云厂商防火墙放行 | 80 / 443 / SSH | **控制台里也要放行**，不只是系统防火墙 |
| Cloudflare API Token | 有 | 见下面第 2 节 |

> 大陆 VPS 的 80 端口可能受限。跑过 `enable-cf-native.sh` 后走 DNS-01，80 端口可以直接关掉
> （第 12 节）。没跑之前，仍然需要 80。

---

## 2. 拿 Cloudflare API Token（一次性）

下面写的是**中文界面**的措辞，英文界面按括号里的对照就行。

1. 登录 `dash.cloudflare.com` → 右上角头像 → **配置文件**（My Profile）→ 左侧 **API 令牌**（API Tokens）
2. 点 **创建令牌**（Create Token）→ 选「**编辑区域 DNS**」→ 点它右边的 **使用模板**
3. **权限**（Permissions）确认是这两条（少一条都会失败）：
   - `区域 → DNS → 编辑`（Zone → DNS → Edit）
   - `区域 → 区域 → 读取`（Zone → Zone → Read）
   - 只需要这两个。不要勾 账号 / Workers / 区域设置 一类的，没必要
4. **区域资源**（Zone Resources）→ 点选「**包含**」（Include）：
   - 只跑一个域名 → **特定区域**（Specific zone）→ 勾它
   - 以后还要加别的域 → **所有区域**（All zones）
5. 点 **继续到摘要**（Continue to summary）→ **创建令牌** → 复制那串 token
   > **只显示这一次**，关掉页面就再也看不全了，先存到密码管理器

### 拿到之后先自己验一遍，别装到一半才发现

```bash
curl -s https://api.cloudflare.com/client/v4/user/tokens/verify \
  -H "Authorization: Bearer 你的token"
```

看到 `"success":true` 就够了。想进一步确认有权限改 DNS：

```bash
curl -s "https://api.cloudflare.com/client/v4/zones?name=你的域名&status=active" \
  -H "Authorization: Bearer 你的token"
```

第二步应该返回 `"result":[{"id":"...","name":"你的域名"}]`。**返回空数组就说明权限范围没圈到这个域**，
去第 4 步把 Zone Resources 改成 All zones 重建一个。

### 关于橙色云：默认不开

Cloudflare 里 DNS 记录的代理开关（那朵**橙色的云**）**默认保持关闭**，也就是只留灰色云。
`add-site.sh` 建记录时就是灰云，不需要你手动去点。

**默认不开的三个理由：**

- 直连源站，浏览器看到的就是 Caddy 签的 Let's Encrypt 证书，不被 CF 边缘证书遮蔽
- 不经过 CF 边缘，不受 zone 级 SSL/TLS 加密模式和边缘缓存影响——开着代理时常见的
  308 跳转死循环、526 证书错误都不会出现
- 链路少一跳，DNS → 源站 → Caddy 一目了然，出问题好定位

**开了代理反而会出两件事：**

- DNS-01 可能签不了证书 —— `_acme-challenge` 的 TXT 记录被 CF 自己吃掉，Let's Encrypt 看不到
- `sync-dns.sh` 改不动 A 记录 —— 代理下改的是 CF 边缘节点，源站记录不动

只有**确实需要隐藏源站 IP** 时才用 `add-site.sh ... --proxy`。此时源站必须有公共 CA 签发的
有效证书，否则 CF 回源报 **526**。

> 以前手动开过橙云的域名：DNS 页里把橙色云点成灰色，等几秒生效。这条跟 Token 权限无关，
> **权限全给对了但云是橙的，一样签不出证书**。

### 在哪接入（只接一次，三个地方共用）

**你只需要粘贴一次。** 跑 `setup.sh` 或 `enable-cf-native.sh` 时交互式输入即可，
它们会把 Token 写进同一个文件：

```
/etc/caddy/cf.env        # 权限 600，内容一行：CF_API_TOKEN=xxxx
```

之后三个消费方都从这一处读：

| 消费方 | 怎么读 | 拿它干什么 |
|---|---|---|
| `cf.sh` | `sed` 解析该文件 | 建 / 删 A 记录（加站点、删站点、每日巡检） |
| **Caddy 自己** | systemd drop-in 注入环境变量 | ① DNS-01 建 `_acme-challenge` TXT 签证书<br>② `dynamic_dns` 建 A 记录、IP 漂移自动改 |
| `admin-api.py` | 直接读该文件 | 面板上显示每个域名的实际 DNS 记录 |

非交互部署就传环境变量：

```bash
export CF_TOKEN='你的token'
bash setup.sh
```

> 老版本写到 `/etc/caddy/.cf_token`（裸 token）。现在统一到 `cf.env`，
> 但 `cf.sh` 两种格式都认，**已部署过的不用手动迁移**。

### 关于记录类型：统一用 A

`add-site.sh` 和 `sync-dns.sh` 现在都建 **A 记录**，不再给子域建 CNAME。
原因是 `dynamic_dns` 只会建 A，两条不同类型的记录抢同一个域名会冲突
（DNS 规范下 CNAME 不能与其他记录共存）。

VPS 只有一个公网 IP，子域直接 A 记录指过去最干净，还能避免"父域记录被误删导致子域全挂"的连锁风险。
确实需要 CNAME 的话加 `-c, --cname`，但**开了 `dynamic_dns` 就别用**。

---

## 3. 部署

### 3.1 bootstrap.sh 详解（VPS 端首次安装）

```bash
bash bootstrap.sh                       # 交互式：引导认证 + 拉代码 + 安装
bash bootstrap.sh --token ghp_xxxx      # 全自动，不再问 GitHub 认证
bash bootstrap.sh --cf-token xxx --email you@example.com   # 连 CF 信息一起喂进去
bash bootstrap.sh --local-dir /root/da  # 源码已在机器上，跳过拉取直接装
bash bootstrap.sh --skip-setup          # 只拉代码不安装
bash bootstrap.sh --update              # 等价于跑 domain-autopilot-update
```

拉代码的三条路，脚本自己按顺序尝试：

| 优先级 | 方式 | 触发条件 | 说明 |
|---|---|---|---|
| 1 | GitHub PAT | 给了 `--token` 或 `GITHUB_TOKEN` | 调 GitHub API 下 tarball，**最省事** |
| 2 | SSH deploy key | 有 `~/.ssh/domain-autopilot_ed25519` | 已在 GitHub 配过 Deploy keys 就用这条路 |
| 3 | 交互式引导 | 上面都不成立 | 生成密钥 → 打印公钥 → 给你直达链接 → 回车继续 |

第 3 条路的产物长这样：

```
──────────────────────────────────────────────
  需要一次授权：把下面的公钥加到 GitHub
──────────────────────────────────────────────

ssh-ed25519 AAAA... domain-autopilot-deploy

  添加地址（Deploy keys，只读即可，不用勾 Allow write access）：
  https://github.com/easun1874/domain-autopilot/settings/keys

  加完之后按回车继续 (或输入 token 直接下载)
```

Token / 邮箱的传递方式和 `setup.sh` 一致：**Cloudflare Token 走临时文件**（`CF_TOKEN_FILE`），
不进命令行、不出现在 `ps` 输出里，装完即删。

### 3.2 更新整套工具（update.sh）

装完之后命令名叫 `domain-autopilot-update`，源码文件是 `update.sh`：

```bash
domain-autopilot-update            # 拉最新代码 → 重装脚本 → 刷新面板 → 重载 Caddy
domain-autopilot-update --check    # 只看有没有新版，什么都不动
domain-autopilot-update --no-setup # 只更新文件，不重跑 setup.sh
domain-autopilot-update --no-reload # 更新完不重载 Caddy
```

四个特点：

- **幂等**，跑几次都一样
- **已有站点一个都不动**，`/etc/caddy/sites/*.conf` 不受影响
- **Token 不丢**，`/etc/caddy/cf.env` 不会被覆盖
- Caddy 用 `reload` 不是 `restart`，**站点不中断**

如果是 git 仓库就用 `git pull`，否则需要给 `GITHUB_TOKEN` 重新下一次源码包。

### 3.3 setup.sh 做的九件事

| 步 | 干什么 | 备注 |
|---|---|---|
| 1 | 装 Caddy / jq / python3 | 发行版源没有就用 Caddy 官方 Cloudsmith 源 |
| 2 | 防火墙放行 | **先推断并放行真实 SSH 端口**，再 80 / 443 |
| 3 | 写 Token | 落到 `/etc/caddy/cf.env`（600），三方共用这一个文件 |
| 4 | 写 Caddy 配置 | 主配置 + `/etc/caddy/sites/` |
| 5 | 装脚本 | `cf.sh` `add-site.sh` `sync-dns.sh` `enable-cf-native.sh` |
| 6 | 校验并启动 Caddy | 校验失败直接中止，不会带病上线 |
| 7 | 注册巡检 | 每 10 分钟跑 `sync-dns.sh --quiet`，IP 漂移自动改 DNS |
| 8 | 打开原生 CF 集成 | `-y` 自动跑 `enable-cf-native.sh`，缺模块则降级 |
| 9 | 装管理面板 | `admin-api.service` 常驻，监听 127.0.0.1:8848 |

跑完这 9 步，还会**问一句要不要装 Telegram 机器人**（第 16 节）。回车跳过也行——
第 9 步已经顺手把机器人程序和 `telegram-bot-reload.path` 放好了，之后你随时可以在
面板里填个 Token 就把它启用。机器人是独立的 `telegram-bot.service`，不装不影响任何其它功能。

### 3.4 部署后访问面板

```bash
ssh -N -L 8848:127.0.0.1:8848 root@你的IP      # 本机开
# 浏览器打开 http://localhost:8848
```

### 3.5 改过 SSH 端口的，跑完务必确认一下

`setup.sh` 会从 `SSH_CONNECTION` 推断你当前连的是哪个端口（最准），读不到才回退 `sshd_config`，
最后兜底 22。推断错了就可能把自己关在门外。跑完立刻确认：

```bash
ufw status | grep -i ssh
```

**被锁在外面的代价不值得赌。**

---

## 4. 添加站点（核心）

```bash
# 本机服务
add-site.sh app.example.com 127.0.0.1:8080

# 局域网另一台机器
add-site.sh nas.example.com 192.168.1.10:5000

# Docker 里，用 compose 服务名
add-site.sh wiki.example.com wiki:3000

# 需要隐藏源站 IP 时才开 CF 代理（默认不开，见第 2 节末尾）
add-site.sh app.example.com 127.0.0.1:8080 --proxy
```

> 不想敲命令、也不想开 SSH 隧道进面板？装了第 16 节的 Telegram 机器人后，
> 在手机上发一句 `/add app.example.com 127.0.0.1:8080` 就完事了。

### 上游该写什么：本机服务一律用 127.0.0.1

上游地址是 **Caddy 作为客户端去连的目标**，跟域名解析、跟下面那个「源站 IP」完全是两回事：

| 服务在哪 | 上游怎么写 |
|---|---|
| 同一台 VPS 上 | `127.0.0.1:端口` ← 就该这么写 |
| 局域网另一台机器 | 那台机器的内网 IP，如 `192.168.1.10:5000` |
| Docker 里 | compose 服务名，如 `wiki:3000`，或 `127.0.0.1:映射端口` |

**上游必须能推出唯一端口**，两种写法会被直接拦下（因为 Caddy 会静默接受、站点永远 502，
报错里一点线索都没有）：

| 别这么写 | 为什么 |
|---|---|
| `127.0.0.1`、`wiki`（不带 scheme 又不带端口） | Caddy 会补默认端口，连到一个你根本没在监听的地方 |
| `127.0.0.1 8080`（用空格分隔） | Caddy 把空格分开的几段当成**多个上游**做负载均衡，配置校验照样通过，访问时随机 502 |

带 scheme 的可以省端口（`https://backend.example.com` 按 443 走）。

**别把本机公网 IP 写进上游。** 云主机的公网 IP 通常不在网卡上（网卡只有 `10.x` 私网地址），
由边缘网关做 1:1 NAT。写成公网 IP 后，Caddy 得把包发出网卡、绕网关再送回来（hairpin），
代价三条：

1. 多一次公网往返。实测 connect 从 `0.15ms` 变成 `0.40ms` —— **这条可以忽略**，别为性能改
2. 这条链路要求安全列表放行该端口。哪天你把 ingress 收紧，站点立刻 502，且报错不好查
3. 最要紧的：为了让这条链路成立，后端端口得挂在公网上。**任何人扫到它，就能绕过 Caddy
   和 HTTPS 直接访问你的服务**（`curl http://<你的IP>:8800` 直接出内容，证书形同虚设）

第 3 条是真风险，不是理论。改成 `127.0.0.1` 后，就可以放心把那些端口的 ingress 从安全
列表里全删掉，服务只从 Caddy 进。

`add-site.sh` 已内置防护：上游里出现本机公网 IP、**且本机确实有进程在监听该端口**时，
自动改写成 `127.0.0.1` 并提示；服务不在本机时保持原样，不会误伤。

### 后端是自签 HTTPS 的面板（x-ui / 3x-ui 等）

这类面板默认只开 HTTPS，证书还是自签的（常见伪装成 `CN=www.bing.com`）。照浏览器地址栏抄
进上游会连着踩三个坑，现在都由 `add-site.sh` 自动处理：

| 你输入的上游 | 会发生什么 |
|---|---|
| `203.0.113.10:35216/a6bba520f977239b9f` | 剥掉路径（上游不支持路径）→ 公网 IP 改回环 → 探测到该端口是 TLS，自动补 `https://` 并跳过证书校验 |
| `https://127.0.0.1:35216` | 照原样用，跳过证书校验（内网 + `https` 自动判定为自签） |
| `127.0.0.1:8800`（普通 HTTP 服务） | 探测不到 TLS，保持原样，不多加一行配置 |

三条规则背后的道理：

- **路径不该写进上游。** Caddy 本来就原样透传请求路径，所以路径属于访问 URL，不属于上游。
  剥掉时会提示，添加结束时还会告诉你正确访问地址。
- **不写 `https://` 也能识别。** 对回环/内网主机做一次 TLS 握手探测，能拿到证书就补上
  `https://`，省得你为一个 502 查半天（Caddy 只会给 502，不会告诉你"它其实是 https"）。
- **自签证书必须跳过校验**，否则报 `x509: certificate signed by unknown authority`。
  上游是 `https` 且主机属回环/内网时自动加 `transport http { tls_insecure_skip_verify }`；
  公网主机证书不受信则需显式 `-k` / `--insecure`。不想跳过就别加。

> **x-ui 的 webBasePath 会让根路径 404，这是正常的。** 面板把 `/a6bba520...` 当成自己的
> 地址，前端静态资源也全是绝对路径，所以不能把这串路径藏起来（藏了前端就 404）。
> 添加后请用 `https://域名/a6bba520.../` 访问，分享给别人也带上这一段。

想先看生成什么、再决定要不要落盘，加 `--dry-run`：

```bash
add-site.sh panel.example.com 203.0.113.10:35216/a6bba520f977239b9f --dry-run
```

只打印将要写入的 `sites/panel.example.com.conf`，不建 DNS、不落盘、不 reload。
面板里也有对应提示，可直接填 `https://127.0.0.1:35216`。

### 反代别的机器上的服务（跨 VPS）

上游写对方的地址就行。那道自动改写**不会碰跨机上游** —— 它只在本机公网 IP + 本机确有
监听时才触发，指向别的机器一律原样保留。

```bash
# 对方 VPS 的公网 IP
add-site.sh api.example.com http://198.51.100.7:8080

# 同一 VPC / 内网互通，走内网更好（更快，且不必对公网开端口）
add-site.sh api.example.com http://10.0.0.9:8080

# 对方也用本工具部署过 -> 直接反代它的 HTTPS，最干净
add-site.sh api.example.com https://api.other.example.com
```

**加之前先在 VPS 上验一遍通不通**，Caddy 连不上只会给你 502，不会告诉你原因：

```bash
curl -sS -o /dev/null -w '%{http_code}\n' --max-time 5 http://198.51.100.7:8080/
```

三个容易踩的点：

1. **对方机器那个端口得真的开着，且对方安全列表要放行你的 VPS**。能收窄来源就收窄，
   别放行全网 —— 云控制台一般支持「源 = 你的 VPS 公网 IP」。
2. **优先走内网或隧道**。同 VPC 用私网 IP；没有内网互通就组 WireGuard，比把后端端口
   摊在公网上强得多。
3. **对方是自签 HTTPS 时会校验失败**。要么让对方上真证书，要么在该站点的 conf 里关掉校验：

```caddyfile
reverse_proxy https://<对方> {
	transport http {
		tls_insecure_skip_verify
	}
}
```

   但这等于放弃证书校验，公网链路上不推荐 —— 能上真证书就上。

脚本内部自动完成的链路：

```
add-site.sh 立刻建记录: 读 Token -> 查 zone id -> 子域建 CNAME / 根域建 A -> 指向本机公网 IP
dynamic_dns 持续保底:   Caddy 自己每 5 分钟比对，VPS 换 IP 自动改
        -> 生成 /etc/caddy/sites/<域名>.conf -> caddy validate -> caddy reload
        -> Caddy 自己拿 Token 去 Let's Encrypt 签证书（HTTP-01，或全局 DNS-01）
```

注意 Caddy 走哪条 ACME 验证，取决于第 12 节有没有跑 `enable-cf-native.sh`：
跑过就默认 DNS-01（不占 80 端口、可签泛域名），没跑就是 HTTP-01。

可选参数：

| 参数 | 作用 |
|---|---|
| `-i, --ip IP` | 手动指定源站 IP，不自动检测 |
| `-P, --proxy` | **开启** Cloudflare 代理（默认关闭；开了浏览器看到的是 CF 证书，且源站需有有效证书） |
| `-p, --no-proxy` | 兼容旧写法，等同于默认行为（不开代理） |
| `-n, --no-api-dns` | 不碰 Cloudflare，只写 Caddy 配置 |
| `-e, --email` | 指定 LE 注册邮箱 |
| `-d, --dns` | 强制本站 DNS-01（全局已开时不需要加） |
| `-r, --remove` | 删除站点，**同时删掉 Cloudflare 里的 DNS 记录** |

验证：

```bash
sleep 20
curl -sI https://app.example.com | head -1        # 期望 200
curl -sI http://app.example.com | head -1         # 期望 301
# 看证书状态。Caddy 没有 list-certificates / certificates 子命令，直接问 openssl
openssl s_client -connect app.example.com:443 -servername app.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates
```

---

## 5. 自动巡检：源站 IP 漂移（sync-dns.sh）

`setup.sh` 已把 `sync-dns.sh` 挂进 cron，**每 10 分钟**一次：

```
*/10 * * * * /usr/local/bin/sync-dns.sh --quiet >> /var/log/caddy-sync.log 2>&1
```

做三件事：

1. **源站 IP 漂移检测**：公网 IP 跟上次快照比，变了就把所有站点的 A 记录改成新 IP
2. **DNS 记录对齐**：扫 `/etc/caddy/sites/*.conf`，缺记录补、记录错了改
3. **证书到期预警**：低于 20 天写进日志

**换了源站 IP 会怎样？** 上游全写 `127.0.0.1`，所以 Caddy 侧一个字节都不用改；
证书绑的是域名不是 IP、又是 DNS-01 签的，也不受影响。唯一要跟上的是 DNS ——
`sync-dns.sh` 会在**最多 10 分钟内**把 A 记录自动改成新 IP（想立刻生效就手动跑一次）。

⚠️ 但有个前提：**只认公网 IPv4**。云主机的公网 IP 往往不在网卡上（边缘网关做 1:1 NAT），
`ip route get` 只能拿到 `10.x` 私网地址。外部探测全挂时若把它当成"新公网 IP"，就会把
所有站点的 A 记录改成私网地址 —— 外网瞬间全不可达，而且下次巡检还会把这个错误地址
写进快照、之后再也发现不了。所以取到私网 / 回环 / 链路本地地址时一律**判定为"取不到"
并跳过写记录**，宁可什么都不做，也不要写错。

| 参数 | 作用 |
|---|---|
| 无参数 | 正常巡检，缺记录会补、错了会改 |
| `--check` | **真·只读**，只出报告，绝不碰 Cloudflare |
| `--quiet` | 没异常就不输出（cron 用） |

```bash
sync-dns.sh            # 立即修一次（换 IP 后手动跑这个）
sync-dns.sh --check    # 只想看现状
tail -20 /var/log/caddy-sync.log
```

### 换 IP 之后会发生什么

| 会发生 | 不会发生 |
|---|---|
| 站点短暂不可访问（DNS 还指向旧 IP） | **证书完全不受影响** —— LE 证书绑域名不绑 IP |
| 最多 10 分钟内 A 记录被自动改好，默认直连改完即生效 | 证书不会因为 IP 变化而失效或需要重签 |
| 若自己开了代理，还要多等 CF 缓存 ~300s | DNS-01 续签照常成功（验证的是 TXT 记录，与 A 记录无关） |

**要是等不及**，SSH 上去手动跑一次就行：

```bash
sync-dns.sh
```

> 公网 IP 靠 icanhazip / ipify / ifconfig.me 三级探测，全挂时退回本机出口网卡地址。
> 如果你的 VPS 在 NAT 后面（网卡是内网 IP），以 `add-site.sh -i <IP>` 手动指定为准。

---

## 6. 泛域名证书（一条证书管所有子域）

```bash
# 1) 新建一个只带 DNS:Edit 的 Token（权限更最小）
# 2) 签 *.example.com
add-site.sh example.com 127.0.0.1:8080 --dns
```

之后不管加多少 `*.example.com` 的子域，都不用再申请证书。
90 天后的续签同样是 Caddy 自动做。

> Let's Encrypt 对同一注册域**每周限 50 张证书**，调试时别反复乱签，建议先把 `Caddyfile` 的
> `acme_ca` 指向 staging 环境测通再切生产。

---

## 7. 安全加固清单

- [ ] **SSH 改端口 + 禁密码登录**：改 `/etc/ssh/sshd_config` 的 `Port` 和 `PasswordAuthentication no`，改完先开个新窗口测通再关老窗口。
- [ ] **管理面板不要暴露公网**：Portainer / NAS 后台 / Jellyfin 这类走 Tailscale，或者在 Caddyfile 里加 `basicauth`。
- [ ] **别开无关端口**：`ss -tulnp` 看一遍，除了 22/80/443 都收掉；服务间走 Docker 内部网络。
- [ ] **备份**：`tar czf /root/caddy-backup.tar.gz /etc/caddy /usr/local/lib/caddy`，代理挂了所有域名都挂。
- [ ] **Cloudflare 侧**：开速率限制规则；如想更严格，用 Cloudflare 面板的官方 IP 列表做一条"仅这些来源可访问源站"规则。

---

## 8. 排错速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `cf.sh: API 失败 ... 1001 bad request` | Token 没权限或域名不在该 zone | 检查 Token 的 `Zone:DNS:Edit` 和域名范围 |
| `找不到 zone: xxx` | 域名没托管到 Cloudflare | `dig NS example.com` 确认 |
| 返回 502 | 上游端口写错、容器没起，或**后端是自签 HTTPS 却把上游写成了 http** | VPS 上 `curl -I 127.0.0.1:8080` 自检；若 `curl -sk https://127.0.0.1:35216` 有内容就是后者 → 上游写 `https://127.0.0.1:35216`（脚本会跳过自签校验） |
| 根路径 404、带路径才通 | 上游服务把路径当自己的地址（x-ui / 3x-ui 的 webBasePath） | 属预期行为，用添加完成时输出的带路径 URL 访问 |
| 签发报 `too many certificates` | 撞 LE 周限流 | 等一周；先用 staging 调试 |
| DNS 解析直接就是 VPS 的 IP | 正常，默认就是直连（灰云） | 想改走 CF 代理：`add-site.sh ... --proxy`，或面板勾「开启 Cloudflare 代理」 |
| 能访问但证书不是 Let's Encrypt | 有人开了 CF 代理，属预期 | 见第 9 节说明 |
| `https://域名` 308 跳转死循环，或报 526 | 开了 CF 代理，且加密模式/源站证书不匹配 | 最省事是关掉橙云；或把 CF 加密模式改成「完全（严格）」 |
| Caddy 起不来 | 配置语法错 | `caddy validate --config /etc/caddy/Caddyfile` |

---

## 9. 关于"证书看起来不是 LE"

**默认不该出现这种情况。** 默认不开 CF 代理，浏览器直连源站，拿到的就是 Caddy 签的
Let's Encrypt 证书。看不到 LE 绿锁，说明这条记录被人手动开了代理。

Cloudflare 代理打开后，浏览器到 Cloudflare 这一段用的是 **Cloudflare 自己的证书**，
源站那份 Caddy 签的证书对浏览器不可见——这是设计如此，不是配错。

两者二选一：

- **要 LE 绿锁（默认）**：不开代理，代价是源站 IP 暴露在 DNS 里
- **要隐藏源站 IP**：`add-site.sh ... --proxy` 开代理，代价是源站必须有公共 CA 签发的
  有效证书，否则 CF 回源报 526

---

## 10. 常用命令

```bash
domain-autopilot-update --check          # 看看这套工具有没有新版
domain-autopilot-update                  # 更新到最新版（站点不受影响）

add-site.sh --remove app.example.com      # 删站点（连带删 DNS 记录）
add-site.sh panel.example.com https://127.0.0.1:35216 --dry-run   # 只看会生成什么，不落盘
bash /usr/local/lib/caddy/cf.sh check     # 验证 Token
bash /usr/local/lib/caddy/cf.sh ip        # 看本机公网 IP
bash /usr/local/lib/caddy/cf.sh resolve app.example.com   # 查本地解析
systemctl status caddy
journalctl -u caddy -f
ls /etc/caddy/sites/
```

---

## 11. 生态里已有的同类项目（2026-09 调研）

先说结论：这个需求**有成熟开源方案，不需要从零造**。但各自侧重不同，按需取用。

| 项目 | 技术栈 | 自动建 CF DNS 记录 | 自动证书 | 绑定 Docker | 特点 |
|---|---|---|---|---|---|
| **grantdb / homeall** `caddy-reverse-proxy-cloudflare` | Caddy + 16 插件 Docker 镜像 | 部分（`caddy-dynamicdns` 管 IP 漂移） | ✅ DNS-01 | 强绑定 | 加服务只加 Docker 标签，附 CrowdSec / WAF / 限流 |
| `uinstinct/cloudflare-caddy` | Caddy + Python bootstrap | ✅ 幂等 | ⚠️ 用 Cloudflare Origin CA（约 15 年） | 强绑定 | 架构跟本方案最接近，用 Origin CA 而非 LE |
| `LiukerSun/DevTools` | Traefik | ✅ 新服务启动自动建 A 记录 | ✅ | 强绑定 | 还带 Keycloak SSO + Prometheus/Grafana，重 |
| `wick233/Nginx_Reverse_Proxy` | Nginx + Certbot | ✅ | ✅ | 否 | 交互式脚本，思路接近 `add-site.sh` |
| `nginx-proxy` + `acme-companion` | Nginx | ❌ | ✅ | 强绑定 | 老牌方案，靠环境变量发现容器 |
| `Traefik` | Go | ⚠️ 需自建 | ✅ | 强绑定 | 生态标配，标签路由 |
| `Nginx Proxy Manager` | Nginx + UI | UI 里勾 | ✅ | 强绑定 | 纯 GUI 操作 |
| **本方案** | Caddy + 纯 bash | ✅ 幂等，含 IP 漂移 | ✅ | **不绑定** | 目标可以是本机端口 / 局域网 IP / Docker 服务名 |

### 怎么选

- **全 Docker、加服务很频繁** → 直接用 `caddy-reverse-proxy-cloudflare`，给容器打标签就行，
  连 Caddyfile 都不用写。这种情况下本方案就多余了，别重复造轮子。
- **源站要挂 Cloudflare Origin CA 证书**（不想让浏览器看到第三方 CA）→ 看 `uinstinct/cloudflare-caddy`。
- **想要 SSO、限流、监控一条龙** → `DevTools`（Traefik + Keycloak 那套）。
- **项目散在各处**（有的在 Docker、有的在别的机器、有的只跑个端口）→ **本方案。**
  `add-site.sh` 的上游填什么都行，`sync-dns.sh` 也不依赖 Docker。

### 本方案借鉴到的东西

`caddy-docker-proxy` 的"标签即路由"思想和 `caddy-dynamicdns` 的"IP 漂移自动更新 DNS"
是两个很值得抄的点。前者如果要做，下一步可以给 `add-site.sh` 加一个 `--compose` 模式，
自动往 `docker-compose.yml` 里写 `traefik.http.routers.*` 标签；后者已经在 `sync-dns.sh` 里用
bash 实现（比对公网 IP 与上次记录，变了就更新 A 记录）。

### 11.1 硬排名：star / 成熟度 / 更新活跃度（2026-09-25 实测）

按"最成熟 + 星最高 + 还在持续更新"三个维度加权后的顺序：

| 排名 | 项目 | star | 最近提交 / 最新发布 | 更新状态 | 备注 |
|---|---|---|---|---|---|
| 1 | `caddyserver/caddy` | 74.6k | 2026-08-02 起持续提交 | 极活跃 | 引擎本体，自动 HTTPS 的 Go 生态事实标准 |
| 2 | `traefik/traefik` | 64.3k | 2026-08-28 | 极活跃 | CNCF 系，Docker / K8s 一等公民，生态最大 |
| 3 | `jc21/nginx-proxy-manager` | 34.1k | 2026-09-03 | 活跃 | 文档和社区最全，纯 GUI |
| 4 | `nginx-proxy/nginx-proxy` | 19.9k | 持续维护 | 活跃 | 老牌，靠容器环境变量发现服务 |
| 5 | `cloudflare/cloudflared` | 15.8k | 2026-08-07 | 活跃 | CF 官方，只支持一年内的版本 |
| 6 | `bunkerity/bunkerweb` | 10.9k | 2026-08-21 | 活跃 | WAF 属性更强，代理能力是附属 |
| 7 | `tobychui/zoraxy` | 5.4k | 2026-08-22 | 活跃 | 单体 Go + Web UI，功能拼装感强 |
| 8 | `lucaslorentz/caddy-docker-proxy` | 4.6k | v2.13.1（2026-07-02） | 很活跃 | 更新频率高于 star 量，适合全 Docker |
| 9 | `gogodoxy/godoxy` | 4.1k | 2026-08-21 | 很活跃 | MIT，Docker/Podman 自动发现，还管 Proxmox |
| 10 | `linuxserverio/swag` | 3.7k | 2026-09-01 | 活跃 | 稳但偏保守，适合照抄配置 |

**注意两个数字陷阱：**

- `fatedier/frp` 109k star 全站第一，但它是**内网穿透**工具，不是反向代理方案，跟你的场景无关。
- `lucaslorentz/caddy-docker-proxy` 只有 4.6k star，但 2026-06 到 07 连发 v2.12.x → v2.13.1，
  **更新频率比上面一堆 60k+ 的项目还猛**。star 数在这里不代表维护质量。

**唯一直角的判断：** 上面这些项目**没有一个原生做到"自动调 Cloudflare API 建 DNS 记录 + 反向代理 + 自动续签"一条龙**。
它们解决的都是"流量进来怎么转发 + 证书怎么签"，DNS 记录那一步基本都要自己补（脚本、插件或自建 provider）。
这就是本方案 `cf.sh` 存在的理由——它是生态里缺的那一环，不是重复造轮子。

---

## 12. 用 Caddy 原生的 Cloudflare 集成，替换掉自制 API 调用

这一节是整个方案最省事的一步。**你不用自己写任何 Cloudflare API 代码**——Caddy 里有两个
模块已经做完了这件事，只是默认没打开。先跑：

```bash
bash enable-cf-native.sh
```

它会打开两块能力，**互不依赖，缺哪个都能用另一个**：

| 块 | 模块 | 解决什么 | 前提 |
|---|---|---|---|
| **A. 证书 DNS-01 签发** | `dns.providers.cloudflare` | Caddy 自己去 CF 建 `_acme-challenge` TXT 拿证书，续签、删记录全自动 | 标准 Caddy 就有 |
| **B. 自动维护 DNS 记录** | `dynamic_dns` 应用 | 扫描所有站点的域名，自动到 CF 建 A 记录；VPS 换 IP 后自动改 | 需 xcaddy 重编 |

脚本做的事：探测模块 → 存 Token 到 `/etc/caddy/cf.env`（600）→ systemd drop-in 注入环境变量
→ 往 Caddyfile 注入 `acme_dns` 与 `dynamic_dns` → 校验 → 热加载。**重复跑是幂等的。**

### 打开之后的变化

- **防火墙可以只留 443**，80 端口直接关掉。DNS-01 不走 HTTP。
- **一张 `*.example.com` 泛证书管所有子域**，以后加子域不用重新申请证书。
- **VPS 换 IP 不用管了**，`dynamic_dns` 每 5 分钟自己比对一遍。

### 那 cf.sh / sync-dns.sh 还要不要

**要，它们不重复，只是分工不同：**

| 工具 | 管什么 | dynamic_dns 覆盖了吗 |
|---|---|---|
| `cf.sh` | 加站点时**立即**建记录、`-r` 删除时连记录一起删、管代理开关（开/关云） | ❌ 没覆盖。dynamic_dns 只建 A/AAAA，不管删除和代理 |
| `sync-dns.sh` | 证书到期预警、扫描补齐缺失记录、打日志 | 部分覆盖。dynamic_dns 不管证书有效期 |

而且 `add-site.sh` 建记录是**立刻**生效，`dynamic_dns` 最多要等一个 `check_interval`（默认 30 秒）。
两者是"立即 + 保底"的关系，不是替代。

### 检查是否启用成功

```bash
caddy list-modules | grep -E 'cloudflare|dynamic_dns'
journalctl -u caddy -n 50 --no-pager      # 看有没有 CF API 报错
```

常见报错：

| 报错 | 原因 |
|---|---|
| `Invalid request headers` | Token 没传进 Caddy 进程，检查 `/etc/systemd/system/caddy.service.d/cf.conf` |
| `timed out waiting for record to fully propagate` | 本机 DNS 缓存了旧记录，加 `resolvers 1.1.1.1` 到 tls 块 |
| `expected 1 zone, got 0` | 域名被写进 `/etc/hosts` 或走本地 DNS 解析，challenge 找不到公网 zone |

---

## 13. 文件清单

| 文件 | 在哪跑 | 作用 |
|---|---|---|
| `bootstrap.sh` | **【VPS】** | **首次安装入口**：拉代码 → 完整性检查 → 调 setup.sh。全流程在服务器本地完成 |
| `update.sh` | 【VPS】 | 更新整套工具，装好后命令名 `domain-autopilot-update`。幂等，不动站点和 Token |
| `deploy.sh` | 【本机】· 可选 | 给不方便在服务器上操作的人：打包上传源码 → 调 VPS 上的 bootstrap.sh |
| `setup.sh` | 【VPS】 | 装 Caddy / jq / python3、防火墙、Token、脚本、cron、面板。通常由 deploy.sh 代跑 |
| `enable-cf-native.sh` | 【VPS】 | 打开 Caddy 原生的 Cloudflare 集成（DNS-01 签发 + 自动建记录）。setup.sh 已含这一步 |
| `cf.sh` | 【VPS】 | Cloudflare API 封装库（可被 source，也可独立跑子命令调试） |
| `add-site.sh` | 【VPS】 | 加/删站点：自动建 DNS + 配置 + 证书。装完在 `/usr/local/bin/`，直接敲命令名 |
| `sync-dns.sh` | 【VPS】 | 巡检：证书预警、DNS 对齐、IP 漂移。已挂 cron，每 10 分钟自动跑 |
| `Caddyfile` | Caddy 主配置，站点配置通过 `import` 加载 |
| `admin-api.py` | 管理面板后端，纯标准库，默认只监听 127.0.0.1:8848 |
| `admin-ui.html` | 管理面板前端，单文件，无构建步骤 |
| `admin-api.service` | 面板的 systemd 单元，含 `ProtectSystem=strict` 等加固 |
| `telegram-bot.py` | 【VPS】 | Telegram 机器人，纯标准库长轮询，白名单鉴权。只调 `add-site.sh`，不自己实现逻辑 |
| `telegram-bot.service` | 机器人的 systemd 单元，凭据走 `/etc/caddy/telegram.env`（600） |
| `telegram-bot-setup.sh` | 【VPS】 | 装/改机器人：隐藏输入 Token、自动探测你的 Telegram ID、写配置、装单元。可重复跑 |
| `telegram-bot-reload.path` | 盯 `/etc/caddy/telegram.env`，一变就重启机器人。面板能"保存即生效"靠的就是它 |
| `telegram-bot-reload.service` | 上面那个 path 单元触发的动作：`enable` + `restart` 机器人 |

---

## 14. 上游依赖与改动清单

**本方案不是从零写的，它是一个"组装 + 补缺口"的活儿。**

### 直接依赖的上游

| 上游项目 | 用它的什么 | 我们用在哪 |
|---|---|---|
| `caddyserver/caddy` 74.6k★ | 反向代理引擎 + 自动 HTTPS | 整个方案的底座，所有站点配置都是 Caddyfile |
| `caddy-dns/cloudflare` 935★ | `dns.providers.cloudflare` 模块，DNS-01 签发 | `enable-cf-native.sh` 打开它，证书签发与续签全交给它 |
| `mholt/caddy-dynamicdns` | `dynamic_dns` 应用，自动维护 A 记录 + IP 漂移 | 同上，替代手写的 IP 漂移比对 |
| `libdns/cloudflare` | 上面两个模块底层的 CF API 封装 | 间接依赖，我们不直接碰 |

### 借鉴思路但没直接用的

| 项目 | 借鉴了什么 |
|---|---|
| `lucaslorentz/caddy-docker-proxy` 4.6k★ | "标签即路由"——加服务不用改配置文件 |
| `uinstinct/cloudflare-caddy` | 幂等地建 Cloudflare DNS 记录 |
| `wick233/Nginx_Reverse_Proxy` | 交互式脚本建站点的思路 |

### 我们自己写的部分（即"改动"）

| 文件 | 为什么必须自己写 |
|---|---|
| `cf.sh` | **生态缺口**。上面所有项目都不管"加站点时立即建记录 / 删站点时连记录删 / 开不开 CF 代理"这三件事 |
| `add-site.sh` | 把"建记录 + 写配置 + 热加载"串成一条命令，且不绑定 Docker |
| `sync-dns.sh` | 证书到期预警。Caddy 只管续签，不管提前告诉你 |
| `enable-cf-native.sh` | 检测模块 + 注入配置 + 处理 systemd 环境变量，把上游能力拼成一条命令 |
| `admin-api.py` / `admin-ui.html` | 上游全是 CLI，没有给"散装 VPS"的轻量面板 |

### 现在能实现的功能

- 一行命令加站点：DNS 记录、证书、反代、热加载全自动
- 证书自动续签，不到 20 天提前预警
- VPS 换 IP 自动改 DNS（`dynamic_dns` 5 分钟一轮 + `sync-dns.sh` 每日兜底）
- 80 端口可关，一张 `*.example.com` 泛证书管所有子域
- 上游可以是本机端口 / 局域网 IP / Docker 服务名，**不绑定 Docker**
- Web 面板查看、增删站点

---

## 15. 管理面板（前端）

不想敲命令时用这个。后端 `admin-api.py` **只用 Python 标准库，不装 pip 包**，
前端 `admin-ui.html` 是单文件，没有构建步骤。

```bash
# VPS 上
python3 admin-api.py                      # 默认 127.0.0.1:8848

# 你自己电脑上开隧道，然后浏览器访问 http://localhost:8848
ssh -L 8848:127.0.0.1:8848 root@你的IP
```

想先看看长什么样（不碰真实系统）：

```bash
python3 admin-api.py --mock     # 演示模式，数据是假的
```

### 面板能做什么

- 站点列表：域名、上游、CF 记录类型与 IP、代理开关状态
- 证书到期天数：>30 绿、7~30 黄、≤7 红
- 添加 / 删除站点（删除会二次确认）
- 顶部状态徽章：Caddy 是否运行、CF 模块装没装、Token 有没有
- 没启用原生集成时，顶部会提示去跑 `enable-cf-native.sh`
- Caddyfile 实时预览
- **Telegram 机器人**：填 Token → 验证 → 探测你的用户 ID → 保存并启动，
  全程不用敲命令（见第 16.2 节 A 方案）

### 安全设计（重要）

**后端默认只监听 `127.0.0.1`，不对外暴露。** 这是刻意的——管理面板本身就是攻击面，
第 7 节安全加固清单里明确要求管理后台不要直接暴露公网。

所以访问方式只有两条：

1. **SSH 隧道（推荐）**：`ssh -L 8848:127.0.0.1:8848 root@你的IP`，零暴露面。
2. **加 basicauth 后走 Caddy**：需要额外配置，且务必先想清楚风险。

面板不做登录认证，因为默认只听回环地址。一旦你把它改到 `0.0.0.0`，就等于把一个
能增删站点、能读 Token 的接口裸奔在公网上——**不要这么干**。

### API

| 方法 | 路径 | 作用 |
|---|---|---|
| GET | `/api/status` | Caddy 状态、模块、Token |
| GET | `/api/sites` | 站点列表（含证书天数） |
| POST | `/api/sites` | 添加站点，调 `add-site.sh` |
| DELETE | `/api/sites/<域名>` | 删除站点，调 `add-site.sh --remove` |
| GET | `/api/dns` | 查各域名在 Cloudflare 的实际记录 |
| GET | `/api/certs` | 证书到期列表 |
| POST | `/api/refresh` | 跑一次 `sync-dns.sh --check` |
| GET | `/api/config` | 读 Caddyfile |
| GET | `/api/telegram` | 机器人配置与服务状态 |
| POST | `/api/telegram/verify` | 用 Token 调 Telegram `getMe` 验证 |
| POST | `/api/telegram/pair` | 调 `getUpdates` 探测你的 Telegram 用户 ID |
| POST | `/api/telegram/apply` | 写 `/etc/caddy/telegram.env`（600），Token 不回显、不进日志 |

---

## 16. Telegram 机器人（用手机加站点）

面板只监听回环地址（第 15 节讲了为什么），所以每次想看它都得先开 SSH 隧道。
但日常其实只有一件事——**加个站点**。那就没必要为了这个去开隧道：
在 Telegram 里发一句 `/add 域名 上游` 就够了。

机器人是**可选**的，和面板互不依赖，装与不装都不影响其它功能。

### 16.1 建一个 bot 拿 Token（一次性，1 分钟）

1. Telegram 里搜 **@BotFather**，发 `/newbot`
2. 起个显示名，再起个用户名（必须以 `bot` 结尾，全局唯一）
3. BotFather 回你一串形如 `123456789:AAE-xxxxxxxx` 的 Token，复制下来

> ⚠️ **一个 Token 只能有一个进程在轮询。** 别和已有机器人共用同一个 bot
> （两边同时 `getUpdates` 会互相抢消息，日志里报 `409 Conflict`）。
> 专门新建一个最省事。

### 16.2 安装

两种方式，效果一样，选一个就行。

**A. 在管理面板里点（不用敲命令）**

打开面板（第 15 节讲了怎么开隧道），右下角有「Telegram 机器人」卡片：

1. 把 BotFather 给的 Token 粘进去 → 点「**验证 Token**」，它会告诉你这个机器人叫什么
2. 去 Telegram 搜到那个 bot，随便发一句话（`/start` 就行）
3. 回面板点「**探测我的 ID**」，它自动把你的用户 ID 填进白名单（也可以直接手填）
4. 点「**保存并启动**」

> 面板做这件事**没有放宽任何权限**。它只往 `/etc/caddy/telegram.env` 写文件，
> 而面板本来就只能写 `/etc/caddy`（`admin-api.service` 是 `ProtectSystem=strict`）。
> "让服务读到新配置"这一步交给 `telegram-bot-reload.path`：systemd 盯着那个文件，
> 一变就重启机器人。附带的好处是你自己手工编辑 `telegram.env` 之后也会自动生效，
> 不用记得去 `systemctl restart`。

**B. 用命令行**

VPS 上，root：

```bash
bash /usr/local/lib/caddy/telegram-bot-setup.sh
```

脚本会做四件事：

1. **隐藏输入**问你 Token（`read -s`，不进 shell 历史、不进进程列表、不回显）
2. 拿 `getMe` 验一遍，告诉你机器人叫什么，Token 抄错当场就能发现
3. 让你去给机器人发一句话，它**自动探测出你的 Telegram 用户 ID** 并填进白名单——
   不用去别处查 ID，也不用先手动开权限
4. 写配置（600）→ 装文件与 systemd 单元 → 启动 → 打印用法

非交互安装（Token 走环境变量，同样不进 argv）：

```bash
TELEGRAM_BOT_TOKEN=123456789:AAE-xxx TELEGRAM_ALLOWED_IDS=123456789 \
  bash /usr/local/lib/caddy/telegram-bot-setup.sh
```

### 16.3 怎么用

| 命令 | 作用 |
|---|---|
| `/add` | 交互式：先问域名 → 再问上游 → 回显确认（带按钮）→ 执行 |
| `/add app.example.com 127.0.0.1:8080` | 一行写完，直接进确认 |
| `/list` | 列出现有站点（域名 / 上游 / 签发方式） |
| `/cancel` | 放弃当前这次添加 |
| `/help` | 用法 |

加完之后它会自己等证书签发，然后回报**源站真实状态码**：

| 回报 | 含义 |
|---|---|
| `✅ 站点已就绪` | 证书签下来了，源站应答 2xx/3xx |
| `🟡 上游连不上`（502/503） | Caddy 和证书都好，是上游那个服务没在跑 |
| `🟡 HTTPS 还没起来` | 等了 ~45 秒还没拿到有效响应：证书还在签，或域名没指向这台机器 |

### 16.4 它做了什么、没做什么

**做**：把「域名 + 上游」拼成 `add-site.sh <域名> <上游>` 去调它（子进程用参数列表，
不拼 shell 字符串，域名和上游都做了严格校验）。

**不做**：不碰 Caddyfile、不自己调 Cloudflare API、不重写任何业务逻辑。
它和网页面板走**完全相同的路径**——所以 `add-site.sh` 的行为一变，机器人和面板同时跟着变，
不会出现两边不一致。

### 16.5 安全

- **白名单**：只有 `TELEGRAM_ALLOWED_IDS` 里的用户能操作。非白名单用户发消息，
  机器人只回他自己的 ID（方便首次配置），**不执行任何动作**。
- **Token 存 `/etc/caddy/telegram.env`（600）**，与 Cloudflare Token 分开存放——
  Caddy 进程永远不需要这个 Token，混在一起只会平白扩大凭据的可见范围。
- **Token 泄露 = 别人能冒充你的机器人发指令**。别贴群、别提交进仓库
  （仓库的 CI 有一道"敏感文件不应入库"的检查）。
- 服务以 **root** 运行（`add-site.sh` 要写 `/etc/caddy/sites` 并 reload Caddy）。
  权限边界靠白名单 + 文件权限守；单元里另有 `ProtectSystem=full` / `ProtectHome` / `PrivateTmp`。
  这里故意没用 `strict`：机器人会调 `caddy` CLI 和 `systemctl`，`strict` 下容易在 reload
  那一步出现说不清的失败。
- 想临时停：`systemctl stop telegram-bot`。彻底卸载：
  `bash /usr/local/lib/caddy/telegram-bot-setup.sh --uninstall`（保留 `telegram.env`，里面有你的 Token）。

### 16.6 排错

| 现象 | 原因 / 处理 |
|---|---|
| 发消息没反应 | `systemctl status telegram-bot`；`journalctl -u telegram-bot -n 50` |
| 回你「⛔ 无权限」 | 你的 ID 不在白名单。把回显的那个 ID 加进 `telegram.env`，再 `systemctl restart telegram-bot` |
| 日志报 `409 Conflict` | 同一个 Token 被两个进程轮询了（多半是和别的机器人共用了一个 bot） |
| 启动就退出，说 Token 无效 | Token 抄错了；或 VPS 出不了网：`curl -s https://api.telegram.org` |
| 显示添加成功但网页打不开 | 机器人回报的状态码就是线索：502 = 上游服务没在跑；其它非 2xx 去查上游日志 |
| 换 Token / 改白名单 | 面板里「Telegram 机器人」卡片改完保存即生效；或手改 `telegram.env` —— 装了 `reload.path` 的话也会自动重启，不用手动 restart |
| 面板保存了但服务没起来 | `systemctl status telegram-bot-reload.path`。没这个单元就跑一次 `domain-autopilot-update` 补上 |

