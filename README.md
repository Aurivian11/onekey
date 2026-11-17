# OneKey · 多协议节点一键脚本

一行命令在 VPS 上搭好代理节点。数字菜单操作，自动生成分享链接、二维码、Clash 配置和订阅地址，小火箭 / Clash / v2rayN / Surge 都能直接导入。

- **7 种协议**：VLESS-REALITY、Hysteria2、TUIC、AnyTLS、VLESS-Argo、Shadowsocks、Snell v6
- **双内核按需安装**：Xray 支持的协议用 Xray，不支持的用 sing-box；选了协议才下载内核，不用了自动删除
- **随机端口**（10000–60000），IPv4 / IPv6 双栈，自动避开已占用端口
- **一键导入**：分享链接 + 二维码、Clash（mihomo）配置、带随机密钥的订阅链接
- **TCP 调优**：BBR + fq + 按内存自动调整缓冲区，可一键恢复
- **干净卸载**：程序、配置、服务、内核参数全部还原

```
=========== OneKey 多协议节点脚本 v1.0.0 ===========
  1) 安装 / 添加协议
  2) 查看节点链接
  3) 订阅链接（小火箭 / Clash）
  4) 删除某个协议
  5) 重启所有服务
  6) 运行状态
  7) 开启 BBR 加速
  8) TCP 调优
  9) 更新内核（已安装的 Xray / sing-box）
 10) 卸载全部
  0) 退出
```

## 快速开始

用 root 登录 VPS，运行：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Aurivian11/onekey/main/install.sh)
```

装好后，以后在服务器上输入 `onekey` 就能打开菜单。

1. 选 **1 安装 / 添加协议**，选协议，端口直接回车（随机）。
2. 安装完自动显示链接和二维码，用手机扫码或复制链接导入客户端。
3. 想用订阅：选 **3 订阅链接**，把地址粘贴到小火箭或 Clash。

## 支持的协议

| 协议 | 内核 | 传输 | 说明 |
|---|---|---|---|
| VLESS-REALITY | Xray | TCP | Vision 流控，伪装 `www.amd.com`，免域名免证书 |
| Hysteria2 | Xray | UDP | 自签证书，客户端需开「跳过证书验证」 |
| VLESS-Argo | Xray + cloudflared | 不开端口 | 走 Cloudflare 隧道隐藏服务器 IP；支持临时隧道或固定隧道（Token + 自己的域名） |
| Shadowsocks | Xray | TCP+UDP | aes-256-gcm / chacha20-ietf-poly1305 / 2022-blake3，适合当中转落地 |
| TUIC v5 | sing-box | UDP | Xray 不支持；自签证书，BBR 拥塞控制 |
| AnyTLS | sing-box | TCP | Xray 不支持；自签证书 |
| Snell v6 | 官方 snell-server | TCP | 仅 Surge 等支持 Snell v6 的客户端 |

内核只在选择对应协议时下载（Xray / sing-box 来自 GitHub 官方 Release，snell-server 来自 dl.nssurge.com，cloudflared 来自 Cloudflare 官方 Release）；某个内核不再被任何协议使用时会被自动删除。

## 导入客户端

| 客户端 | 导入方式 | 可用节点 |
|---|---|---|
| 小火箭 Shadowrocket | 扫二维码 / 复制链接自动识别 / 订阅：＋ → Subscribe → 粘贴「小火箭订阅」地址 | 除 Snell 外 |
| Clash Verge Rev / Clash Meta for Android / Stash | 粘贴「Clash 订阅」地址，或导入 `/etc/onekey/clash.yaml` | 除 Snell 外 |
| v2rayN / NekoBox / sing-box App | 复制链接或「小火箭订阅」地址 | 除 Snell 外 |
| Surge | 把菜单 2 里的 Snell 行粘贴到 `[Proxy]` | Snell v6 |

- Clash 配置自带「节点选择」「自动选择（测速择优）」两个分组，国内直连、国外走代理。
- 订阅由服务器上的 busybox httpd 提供，地址带 32 位随机密钥；目录不可浏览，密钥错误返回 404。订阅是明文 HTTP，地址等于全部节点的密码，泄露后用「更换订阅地址」让旧地址失效。
- 请用 mihomo 内核的 Clash（如 Clash Verge Rev），原版 Clash 不支持 REALITY / Hysteria2 / TUIC / AnyTLS。

> **REALITY 兼容性（2026-11 实测）**：Xray 从 v26.7.11 起，REALITY 服务端与 sing-box 内核、mihomo（Clash Meta）内核的客户端不兼容，Xray 内核客户端（如 v2rayN）可正常连接；其它协议不受影响。

## TCP 调优

菜单 **8** 可选：应用推荐调优 / 查看当前参数 / 恢复调优前的参数。

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
onekey links                # 查看全部链接
onekey sub                  # 开启订阅 / 查看订阅地址（sub reset 换地址，sub off 关闭）
onekey clash                # 输出 Clash 配置
onekey remove hy2           # 删除某个协议
onekey status               # 运行状态
onekey tcp                  # TCP 调优（tcp show 查看，tcp restore 恢复）
onekey bbr                  # 只开 BBR
onekey rebuild              # 按当前规则重新生成内核配置
onekey uninstall            # 卸载全部
```

## 测试工具

`test_links.sh` 会读取脚本生成的分享链接，在服务器上逐个连接并访问 `generate_204`，检查每条链接是否可用（REALITY 用 Xray 客户端测，其它用 sing-box 客户端测）：

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

## 常见问题

- **连不上**：先确认服务商的防火墙 / 安全组放行了端口（Hysteria2、TUIC 是 UDP）；菜单 6 看服务是否在运行。
- **Hysteria2 / TUIC / AnyTLS 报证书错误**：客户端打开「跳过证书验证 / allowInsecure」。
- **Argo 链接失效**：临时隧道在服务器或服务重启后域名会变，菜单 2 重新查看；订阅会自动更新。
- **想换伪装网站**：重新添加 REALITY 时在「伪装域名 (SNI)」填其它支持 TLS 1.3 的大站。

## 免责声明

本项目仅供学习和研究网络技术使用。请遵守你所在地区以及服务器所在地的法律法规，使用本脚本产生的一切后果由使用者自行承担。
