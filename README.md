# OneKey · 多协议节点一键脚本

一行命令在 VPS 上搭好代理节点。数字菜单操作，自动生成分享链接、二维码、Clash 配置和订阅地址，小火箭 / Clash / v2rayN / Surge 都能直接导入。

- **7 种协议**：VLESS-REALITY、Hysteria2、TUIC、AnyTLS、VLESS-Argo、Shadowsocks、Snell v6
- **双内核按需安装**：Xray 支持的协议用 Xray，不支持的用 sing-box；选了协议才下载内核，不用了自动删除
- **随机端口**（10000–60000），自动避开已占用端口
- **IPv4 / IPv6 可选**：节点链接用 IPv4 + IPv6 / 只用 IPv4 / 只用 IPv6；出站可选优先或只用 IPv4 / IPv6
- **三种证书**：域名证书 / IP 证书（默认，Let's Encrypt，自动续签，和 3x-ui 一样）/ 自签证书
- **一键导入**：分享链接 + 二维码、Clash（mihomo）配置、带随机密钥的订阅链接
- **TCP 调优**：BBR + fq + 按内存自动调整缓冲区，可一键恢复
- **干净卸载**：程序、配置、服务、内核参数全部还原

```
=========== OneKey 多协议节点脚本 v1.1.0 ===========
  1) 安装 / 添加协议
  2) 查看节点链接
  3) 订阅链接（小火箭 / Clash）
  4) IP 设置（IPv4 / IPv6）
  5) 删除某个协议
  6) 重启所有服务
  7) 运行状态
  8) 开启 BBR 加速
  9) TCP 调优
 10) 更新内核（已安装的 Xray / sing-box）
 11) 证书设置（域名 / IP / 自签）
 12) 卸载全部
  0) 退出
```

## 快速开始

用 root 登录 VPS，运行：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Aurivian11/onekey/main/install.sh)
```

装好后，以后在服务器上输入 `onekey` 就能打开菜单。

1. 选 **1 安装 / 添加协议**，选协议，端口直接回车（随机）。
2. 安装完自动显示每个节点的链接和二维码，小火箭直接扫码导入。
3. Clash 用户：查看链接时按回车开启订阅，会显示 Clash 订阅地址、`clash://` 一键导入链接和二维码（菜单 3 也能随时查看）。

## 支持的协议

| 协议 | 内核 | 传输 | 说明 |
|---|---|---|---|
| VLESS-REALITY | Xray | TCP | Vision 流控，伪装 `www.amd.com`，免域名免证书 |
| Hysteria2 | Xray | UDP | 默认 IP 证书，见下方「证书」 |
| VLESS-Argo | Xray + cloudflared | 不开端口 | 走 Cloudflare 隧道隐藏服务器 IP；支持临时隧道或固定隧道（Token + 自己的域名） |
| Shadowsocks | Xray | TCP+UDP | aes-256-gcm / chacha20-ietf-poly1305 / 2022-blake3，适合当中转落地 |
| TUIC v5 | sing-box | UDP | Xray 不支持；BBR 拥塞控制；默认 IP 证书 |
| AnyTLS | sing-box | TCP | Xray 不支持；默认 IP 证书 |
| Snell v6 | 官方 snell-server | TCP | 仅 Surge 等支持 Snell v6 的客户端 |

内核只在选择对应协议时下载（Xray / sing-box 来自 GitHub 官方 Release，snell-server 来自 dl.nssurge.com，cloudflared 来自 Cloudflare 官方 Release）；某个内核不再被任何协议使用时会被自动删除。

## 导入客户端

| 客户端 | 导入方式 | 可用节点 |
|---|---|---|
| 小火箭 Shadowrocket | 扫每个节点的二维码 / 复制链接自动识别 / 扫「小火箭订阅」二维码一次导入全部 | 除 Snell 外 |
| Clash Verge Rev / Clash Meta for Android / Stash | 打开 `clash://install-config?url=…` 一键导入链接 / 扫 Clash 订阅二维码 / 粘贴「Clash 订阅」地址 | 除 Snell 外 |
| v2rayN / NekoBox / sing-box App | 复制链接或「小火箭订阅」地址 | 除 Snell 外 |
| Surge | 把菜单 2 里的 Snell 行粘贴到 `[Proxy]` | Snell v6 |

- Clash 配置自带「节点选择」「自动选择（测速择优）」两个分组，国内直连、国外走代理。
- 订阅由服务器上的 busybox httpd 提供，地址带 32 位随机密钥；目录不可浏览，密钥错误返回 404。订阅是明文 HTTP，地址等于全部节点的密码，泄露后用「更换订阅地址」让旧地址失效。
- 请用 mihomo 内核的 Clash（如 Clash Verge Rev），原版 Clash 不支持 REALITY / Hysteria2 / TUIC / AnyTLS。

> **REALITY 兼容性（2026-11 实测）**：Xray 从 v26.7.11 起，REALITY 服务端与 sing-box 内核、mihomo（Clash Meta）内核的客户端不兼容，Xray 内核客户端（如 v2rayN）可正常连接；其它协议不受影响。

## IP 设置（IPv4 / IPv6）

菜单 **4**，两项可分别设置：

| 设置 | 选项 | 作用 |
|---|---|---|
| 节点地址 | IPv4 + IPv6 / 只用 IPv4 / 只用 IPv6 | 决定链接、二维码、Clash 配置、订阅里用哪个 IP。第一次安装协议时会询问（服务器同时有 IPv4 和 IPv6 时） |
| 出站 | 系统默认 / 优先 IPv4 / 优先 IPv6 / 只用 IPv4 / 只用 IPv6 | 通过节点访问网站时，对方看到的是服务器的 IPv4 还是 IPv6（Xray、sing-box、Snell 同时生效） |

- 修改「节点地址」后链接会变，客户端需要重新导入或更新订阅；修改「出站」不影响链接。
- VLESS-Argo 始终使用 Cloudflare 隧道域名，不受「节点地址」影响。

## 证书（Hysteria2 / TUIC / AnyTLS）

第一次安装这三个协议之一时选择，以后在菜单 **11** 随时切换。REALITY、Argo、SS、Snell 不需要证书。

| 证书 | 隐蔽性 | 条件 | 客户端 |
|---|---|---|---|
| 域名证书 | 最好 | 一个已解析到本机的域名（Cloudflare 要关小黄云） | 正常验证证书 |
| **IP 证书（默认）** | 较好 | 不需要域名；TCP 80 端口能从外网访问 | 正常验证证书 |
| 自签证书 | 差，主动探测一眼能认出 | 无 | 必须开「跳过证书验证」 |

- 域名证书和 IP 证书都用 [acme.sh](https://github.com/acmesh-official/acme.sh) 向 Let's Encrypt 申请。IP 证书是 Let's Encrypt 的短期证书（约 6 天），脚本设置为每 3 天自动续签一次，续签后自动重启内核；域名证书 90 天，到期前 30 天续签。
- 申请和续签时 acme.sh 会临时占用 **80 端口**做验证，所以 80 端口要空着（不要跑 nginx 之类），服务商安全组要放行 TCP 80。
- 节点地址设为 IPv4 + IPv6 时，IP 证书会同时包含两个 IP；IPv6 验证不通过时自动只申请 IPv4，此时 IPv6 链接会跳过证书验证。
- 申请失败时会自动先用自签证书，节点照常可用，之后可在菜单 11 重新申请。
- 换证书后链接里的 SNI / 跳过验证会变，客户端需要重新导入或更新订阅。
- 1.0 版装的节点保持自签证书不变，想换就在菜单 11 选择。

## TCP 调优

菜单 **9** 可选：应用推荐调优 / 查看当前参数 / 恢复调优前的参数。

- BBR 拥塞控制 + fq 队列
- 收发缓冲区按内存自动调整：≤512M → 8MB，1G → 16MB，2–4G → 32MB，更大 → 64MB（同时满足 Hysteria2 / TUIC 对 UDP 缓冲区的要求）
- TCP Fast Open、MTU 探测、空闲后不降速、`tcp_notsent_lowat` 降低延迟、更大的连接队列
- 第一次调优前自动备份原始值，「恢复」一键还原；卸载时自动恢复

## 命令行用法

```bash
onekey                      # 打开菜单
onekey add reality          # 非交互安装：reality | hy2 | tuic | anytls | argo | ss | snell
PORT_SET=443 onekey add reality
METHOD=chacha20-ietf-poly1305 onekey add ss
SNI=www.microsoft.com onekey add reality
IP_MODE=6 onekey add hy2        # 第一次安装时直接指定只用 IPv6（4 | 6 | both）
CERT=self onekey add tuic       # 第一次装 Hysteria2 / TUIC / AnyTLS 时指定证书（ip 默认 | domain | self）
CERT=domain DOMAIN=example.com onekey add hy2
onekey links                # 查看全部链接
onekey sub                  # 开启订阅 / 查看订阅地址（sub reset 换地址，sub off 关闭）
onekey clash                # 输出 Clash 配置
onekey remove hy2           # 删除某个协议
onekey status               # 运行状态
onekey tcp                  # TCP 调优（tcp show 查看，tcp restore 恢复）
onekey bbr                  # 只开 BBR
onekey rebuild              # 按当前规则重新生成内核配置
onekey ip                   # 查看 IP 设置
onekey ip 6                 # 节点链接只用 IPv6（4 只用 IPv4，both 两个都生成）
onekey ip out prefer6       # 出站优先 IPv6（auto | prefer4 | prefer6 | only4 | only6）
onekey cert                 # 查看证书和到期时间
onekey cert ip              # 换成 IP 证书（domain <域名> 换域名证书，self 换自签）
onekey cert renew           # 立即续签
onekey uninstall            # 卸载全部
```

## 测试工具

`test_links.sh` 会读取脚本生成的分享链接，在服务器上逐个连接并访问 `generate_204`，检查每条链接是否可用（REALITY 用 Xray 客户端测，其它用 sing-box 客户端测；链接没写跳过证书验证时会真正校验证书）：

```bash
bash test_links.sh
```

## 系统要求

| 系统 | 状态 |
|---|---|
| Debian 11 / 12 / 13、Ubuntu 20.04+（systemd） | 已在 Debian 13 实测 |
| Alpine（OpenRC） | 已适配，未实测；Snell 会自动安装 `gcompat` |
| CentOS / Rocky / Alma（dnf / yum） | 已适配，未实测；需 OpenSSL 1.1.1+ |

- 架构：amd64、arm64
- 需要 root
- 系统没有 IPv6 时自动只监听 IPv4

## 文件位置

| 路径 | 内容 |
|---|---|
| `/etc/onekey/` | 各协议参数、内核配置、证书、链接、Clash 配置、订阅文件（权限 600） |
| `/usr/local/bin/onekey` | 菜单命令 |
| `/usr/local/bin/xray`、`sing-box`、`snell-server`、`cloudflared` | 按需安装的内核 |
| `onekey-xray` / `onekey-sb` / `onekey-snell` / `onekey-argo` / `onekey-sub` | 系统服务 |
| `/etc/sysctl.d/99-onekey-tcp.conf` | TCP 调优参数 |
| `/root/.acme.sh/` | acme.sh（IP / 域名证书的申请和续签；卸载时只删本脚本的证书记录，acme.sh 保留） |

## 常见问题

- **连不上**：先确认服务商的防火墙 / 安全组放行了端口（Hysteria2、TUIC 是 UDP）；菜单 7 看服务是否在运行。
- **Hysteria2 / TUIC / AnyTLS 报证书错误**：`onekey cert` 看证书是否过期；IP / 域名证书续签失败多半是 80 端口被占用或被防火墙拦了，处理后 `onekey cert renew`。自签证书需要客户端打开「跳过证书验证 / allowInsecure」。
- **Argo 链接失效**：临时隧道在服务器或服务重启后域名会变，菜单 2 重新查看；订阅会自动更新。
- **想换伪装网站**：重新添加 REALITY 时在「伪装域名 (SNI)」填其它支持 TLS 1.3 的大站。

## 免责声明

本项目仅供学习和研究网络技术使用。请遵守你所在地区以及服务器所在地的法律法规，使用本脚本产生的一切后果由使用者自行承担。
