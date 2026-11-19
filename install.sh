#!/usr/bin/env bash
# =============================================================
#  OneKey 多协议节点一键脚本
#  协议：VLESS-REALITY / Hysteria2 / TUIC / AnyTLS / VLESS-Argo /
#        Shadowsocks / Snell v6
#  内核：Xray（REALITY / Hysteria2 / Argo / SS）+ sing-box（TUIC / AnyTLS）
#        + snell-server + cloudflared；内核只在选择协议时才安装
#  证书：域名证书 / IP 证书（默认，Let's Encrypt 自动续签）/ 自签
#  系统：Debian / Ubuntu / Alpine（OpenRC）/ CentOS 系
# =============================================================
set -o pipefail

ONEKEY_VER="1.3.2"
# 一键安装时脚本会从这里下载自己，安装成 onekey 命令
SCRIPT_URL="${ONEKEY_URL:-https://raw.githubusercontent.com/Aurivian11/onekey/main/install.sh}"

BASE=/etc/onekey
STATE=$BASE/state
SB_CONF=$BASE/sing-box.json
XRAY_CONF=$BASE/xray.json
CERT_DIR=$BASE/cert
LINKS=$BASE/links.txt
ARGO_LOG=$BASE/argo.log
BIN_SB=/usr/local/bin/sing-box
BIN_XRAY=/usr/local/bin/xray
BIN_SNELL=/usr/local/bin/snell-server
BIN_CF=/usr/local/bin/cloudflared
CMD=/usr/local/bin/onekey

SNELL_VER="${SNELL_VER:-v6.0.0}"
DEF_REALITY_SNI="www.amd.com"
DEF_TLS_SNI="www.bing.com"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[36m%s\033[0m\n' "$*"; }
die()    { red "错误：$*"; exit 1; }

NONINT=${NONINT:-0}   # 1 = 非交互，全部用默认值
ask() {   # ask "提示" 默认值 -> 输出结果
  local prompt=$1 def=$2 ans
  if [[ $NONINT == 1 ]]; then echo "$def"; return; fi
  read -r -p "$prompt [默认 $def]: " ans
  echo "${ans:-$def}"
}

# ---------------- 环境检测 ----------------
[[ $EUID -eq 0 ]] || die "请用 root 运行"

detect_os() {
  OS_ID=$( [[ -f /etc/os-release ]] && . /etc/os-release; echo "${ID:-unknown}" )
  if command -v apk >/dev/null 2>&1; then PKG=apk
  elif command -v apt-get >/dev/null 2>&1; then PKG=apt
  elif command -v dnf >/dev/null 2>&1; then PKG=dnf
  elif command -v yum >/dev/null 2>&1; then PKG=yum
  else die "不支持的系统（找不到 apt/apk/dnf/yum）"; fi
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then INIT=systemd
  elif command -v rc-service >/dev/null 2>&1; then INIT=openrc
  else die "需要 systemd 或 OpenRC"; fi
  case $(uname -m) in
    x86_64|amd64) ARCH=amd64; SNELL_ARCH=amd64; CF_ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64; SNELL_ARCH=aarch64; CF_ARCH=arm64 ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
}

install_deps() {
  local need=0 c
  for c in curl jq openssl qrencode tar unzip ss; do command -v $c >/dev/null 2>&1 || need=1; done
  [[ $need == 0 ]] && return
  yellow "安装依赖..."
  case $PKG in
    apt) apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq openssl qrencode tar unzip iproute2 ca-certificates >/dev/null ;;
    apk) apk add --no-cache bash curl jq openssl libqrencode-tools tar unzip iproute2 ca-certificates >/dev/null ;;
    dnf|yum) $PKG install -y -q epel-release >/dev/null 2>&1; $PKG install -y -q curl jq openssl qrencode tar unzip iproute >/dev/null ;;
  esac
  for c in curl jq openssl tar; do command -v $c >/dev/null 2>&1 || die "依赖 $c 安装失败"; done
}

get_ip() {
  IP4=$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 6 https://ipv4.icanhazip.com 2>/dev/null)
  IP6=$(curl -6 -fsS --max-time 6 https://api64.ipify.org 2>/dev/null || curl -6 -fsS --max-time 6 https://ipv6.icanhazip.com 2>/dev/null)
  IP4=$(echo "$IP4" | tr -d '[:space:]'); IP6=$(echo "$IP6" | tr -d '[:space:]')
  [[ $IP6 == *:* ]] || IP6=""
  [[ $IP4 == *.* ]] || IP4=""
  [[ -n $IP4 || -n $IP6 ]] || die "获取公网 IP 失败"
}

# ---------------- IP 设置（IPv4 / IPv6） ----------------
# LINK_IP：节点链接 / 二维码 / 订阅里用哪个地址   both | 4 | 6
# OUT_IP ：出站（访问网站时用的 IP）            auto | prefer4 | prefer6 | only4 | only6
IP_ENV=$BASE/ip.env
LINK_IP=both; OUT_IP=auto
[[ -f $IP_ENV ]] && . "$IP_ENV"
save_ip() { printf "LINK_IP='%s'\nOUT_IP='%s'\n" "$LINK_IP" "$OUT_IP" >"$IP_ENV"; chmod 600 "$IP_ENV"; }
link_hosts() {
  [[ -z $IP4$IP6 ]] && get_ip
  case $LINK_IP in
    4) echo "${IP4:-$IP6}" ;;
    6) echo "${IP6:-$IP4}" ;;
    *) echo "$IP4 $IP6" ;;
  esac
}
link_label() { case $LINK_IP in 4) echo "只用 IPv4";; 6) echo "只用 IPv6";; *) echo "IPv4 + IPv6";; esac; }
out_label()  { case $OUT_IP in prefer4) echo "优先 IPv4";; prefer6) echo "优先 IPv6";; only4) echo "只用 IPv4";; only6) echo "只用 IPv6";; *) echo "系统默认";; esac; }
xray_strategy() { case $OUT_IP in prefer4) echo UseIPv4v6;; prefer6) echo UseIPv6v4;; only4) echo UseIPv4;; only6) echo UseIPv6;; *) echo AsIs;; esac; }
sb_strategy()   { case $OUT_IP in prefer4) echo prefer_ipv4;; prefer6) echo prefer_ipv6;; only4) echo ipv4_only;; only6) echo ipv6_only;; *) echo "";; esac; }
snell_pref()    { case $OUT_IP in prefer4) echo prefer-ipv4;; prefer6) echo prefer-ipv6;; only4) echo ipv4-only;; only6) echo ipv6-only;; *) echo default;; esac; }

first_ip_setup() {   # 第一次安装协议时选择节点地址（环境变量 IP_MODE=4|6|both 可跳过询问）
  [[ -f $IP_ENV ]] && return
  [[ -z $IP4$IP6 ]] && get_ip
  if [[ -n ${IP_MODE:-} ]]; then LINK_IP=$IP_MODE
  elif [[ -z $IP4 ]]; then LINK_IP=6
  elif [[ -z $IP6 ]]; then LINK_IP=4
  elif [[ $NONINT != 1 ]]; then
    echo
    echo "检测到 IPv4：$IP4    IPv6：$IP6"
    echo "节点链接使用哪个地址？（以后可在主菜单「IP 设置」修改）"
    echo "  1) IPv4 + IPv6 都生成"
    echo "  2) 只用 IPv4"
    echo "  3) 只用 IPv6"
    case $(ask "请选择" 1) in 2) LINK_IP=4;; 3) LINK_IP=6;; *) LINK_IP=both;; esac
  fi
  save_ip
}

set_link_ip() {   # set_link_ip both|4|6
  [[ -z $IP4$IP6 ]] && get_ip
  [[ $1 == 6 && -z $IP6 ]] && { red "这台服务器没有公网 IPv6"; return 1; }
  [[ $1 == 4 && -z $IP4 ]] && { red "这台服务器没有公网 IPv4"; return 1; }
  LINK_IP=$1; save_ip
  ls "$STATE"/*.env >/dev/null 2>&1 && gen_clients >/dev/null 2>&1
  green "节点地址已设为：$(link_label)（链接、二维码、Clash 配置、订阅已更新，客户端需重新导入或更新订阅）"
}
set_out_ip() {   # set_out_ip auto|prefer4|prefer6|only4|only6
  [[ -z $IP4$IP6 ]] && get_ip
  [[ $1 == only6 && -z $IP6 ]] && { red "这台服务器没有公网 IPv6，不能设为只用 IPv6"; return 1; }
  [[ $1 == only4 && -z $IP4 ]] && { red "这台服务器没有公网 IPv4，不能设为只用 IPv4"; return 1; }
  OUT_IP=$1; save_ip
  local ok=1
  [[ -f $XRAY_CONF ]] && { apply_xray || ok=0; }
  [[ -f $SB_CONF ]] && { apply_singbox || ok=0; }
  has snell && { write_snell_conf; svc restart onekey-snell; }
  [[ $ok == 1 ]] && green "出站已设为：$(out_label)（节点链接不变，无需重新导入）" || red "部分内核应用失败，见上方信息"
}

ip_menu() {
  [[ -z $IP4$IP6 ]] && get_ip
  echo
  echo "本机公网：IPv4 ${IP4:-无}    IPv6 ${IP6:-无}"
  echo "当前设置：节点地址 $(link_label)；出站 $(out_label)"
  echo
  echo "  节点地址（链接 / 二维码 / 订阅里用的 IP）"
  echo "  1) IPv4 + IPv6 都生成"
  echo "  2) 只用 IPv4"
  echo "  3) 只用 IPv6"
  echo "  出站（通过节点访问网站时，对方看到的 IP）"
  echo "  4) 系统默认"
  echo "  5) 优先 IPv4"
  echo "  6) 优先 IPv6"
  echo "  7) 只用 IPv4"
  echo "  8) 只用 IPv6"
  echo "  0) 返回"
  local c; read -r -p "请选择 [0-8]: " c
  case $c in
    1) set_link_ip both ;; 2) set_link_ip 4 ;; 3) set_link_ip 6 ;;
    4) set_out_ip auto ;; 5) set_out_ip prefer4 ;; 6) set_out_ip prefer6 ;;
    7) set_out_ip only4 ;; 8) set_out_ip only6 ;;
  esac
}

port_used() { ss -Hlntu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]$1\$"; }
tcp_busy() { ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }
port_owner() { ss -Hltnp "sport = :$1" 2>/dev/null | grep -o 'users:(("[^"]*' | head -1 | cut -d'"' -f2; }
hop_range() { has hy2 && ( HOP=""; . "$STATE/hy2.env"; echo "$HOP" ); }   # Hysteria2 端口跳跃范围，如 20000-29999
in_hop() {   # in_hop 端口：是否落在端口跳跃范围里（这些 UDP 端口会被转给 Hysteria2）
  local r; r=$(hop_range); [[ -n $r ]] || return 1
  (( $1 >= ${r%-*} && $1 <= ${r#*-} ))
}
rand_port() {
  local p
  for _ in $(seq 1 50); do
    p=$(( (RANDOM << 15 | RANDOM) % 50001 + 10000 ))
    port_used "$p" || in_hop "$p" || { echo "$p"; return; }
  done
  echo 34567
}
ask_port() {   # ask_port 名称 协议 -> PORT（环境变量 PORT_SET 可指定端口）
  local def; def=${PORT_SET:-$(rand_port)}
  while :; do
    PORT=$(ask "$1 端口" "$def")
    [[ $PORT =~ ^[0-9]+$ ]] && (( PORT > 0 && PORT < 65536 )) || { red "端口无效"; [[ $NONINT == 1 ]] && die "端口无效"; continue; }
    port_used "$PORT" && ! grep -qs "PORT='$PORT'" "$STATE/$2.env" && { red "端口 $PORT 已被占用"; [[ $NONINT == 1 ]] && die "端口被占用"; continue; }
    [[ $2 != hy2 ]] && in_hop "$PORT" && { red "端口 $PORT 在 Hysteria2 端口跳跃范围 $(hop_range) 里"; [[ $NONINT == 1 ]] && die "端口在端口跳跃范围里"; continue; }
    break
  done
}

open_port() {   # open_port 端口或范围(a-b) tcp|udp|both
  local p=$1 t=$2
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    [[ $t != udp ]] && ufw allow "${p/-/:}"/tcp >/dev/null
    [[ $t != tcp ]] && ufw allow "${p/-/:}"/udp >/dev/null
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    [[ $t != udp ]] && firewall-cmd -q --permanent --add-port="$p"/tcp
    [[ $t != tcp ]] && firewall-cmd -q --permanent --add-port="$p"/udp
    firewall-cmd -q --reload
  fi
}

uri() { jq -rn --arg s "$1" '$s|@uri'; }
b64url() { printf '%s' "$1" | base64 | tr -d '\n=' | tr '+/' '-_'; }
rand_hex() { openssl rand -hex "$1"; }
rand_pw() { openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-"${1:-24}"; }

# ---------------- 服务管理 ----------------
svc_write() {   # svc_write 名称 "命令" [日志文件]
  local name=$1 cmd=$2 log=$3
  if [[ $INIT == systemd ]]; then
    cat >/etc/systemd/system/$name.service <<EOF
[Unit]
Description=OneKey $name
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$cmd
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
${log:+StandardOutput=append:$log}
${log:+StandardError=append:$log}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$name" >/dev/null 2>&1
  else
    local bin=${cmd%% *} args=${cmd#* }
    cat >/etc/init.d/$name <<EOF
#!/sbin/openrc-run
name="$name"
command="$bin"
command_args="$args"
command_background=true
pidfile="/run/$name.pid"
${log:+output_log="$log"}
${log:+error_log="$log"}
depend() { need net; }
EOF
    chmod +x /etc/init.d/$name
    rc-update add "$name" default >/dev/null 2>&1
  fi
}
svc() {   # svc start|stop|restart|status 名称
  if [[ $INIT == systemd ]]; then
    case $1 in
      status) systemctl is-active "$2" 2>/dev/null ;;
      *) systemctl "$1" "$2" >/dev/null 2>&1 ;;
    esac
  else
    case $1 in
      status) rc-service "$2" status 2>/dev/null | grep -q started && echo active || echo inactive ;;
      *) rc-service "$2" "$1" >/dev/null 2>&1 ;;
    esac
  fi
}
svc_remove() {
  svc stop "$1"
  if [[ $INIT == systemd ]]; then
    systemctl disable "$1" >/dev/null 2>&1; rm -f /etc/systemd/system/$1.service; systemctl daemon-reload
  else
    rc-update del "$1" default >/dev/null 2>&1; rm -f /etc/init.d/$1
  fi
}

# ---------------- 内核安装（按需） ----------------
# Xray 支持的协议用 Xray，不支持的用 sing-box；Snell 用官方 snell-server
# 内核只在选择对应协议时才下载，没有协议使用时自动删除
core_of() {
  case $1 in
    reality|argo|ss|hy2) echo xray ;;
    tuic|anytls)         echo singbox ;;
    snell)               echo snell ;;
  esac
}
XRAY_PROTOS=(reality hy2 argo ss)
# 系统没有 IPv6（或内核关闭了 IPv6）时只监听 IPv4，否则双栈
[[ -f /proc/net/if_inet6 ]] && LISTEN_ALL="::" || LISTEN_ALL="0.0.0.0"
SB_PROTOS=(tuic anytls)

gh_latest() { curl -fsSL "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name; }

# ---------------- Xray 版本 ----------------
# 新版 Xray（v26.7.11 起）的 REALITY 服务端和 sing-box / mihomo 内核的客户端不兼容，
# v26.6.27 是实测 Xray / sing-box / mihomo 内核客户端都能连的最后一个版本，所以提供「兼容版」固定在这个版本
XRAY_COMPAT=v26.6.27
CORE_ENV=$BASE/core.env
XRAY_VER=${XRAY_VER:-}          # compat | latest | vX.Y.Z；空 = 还没选（旧版装的按 latest 处理）
[[ -z $XRAY_VER && -f $CORE_ENV ]] && . "$CORE_ENV"
save_core_env() { mkdir -p "$BASE"; printf "XRAY_VER='%s'\n" "$XRAY_VER" >"$CORE_ENV"; chmod 600 "$CORE_ENV"; }
xray_tag() {   # 要装的 Xray 版本号
  case ${XRAY_VER:-latest} in
    compat) echo "$XRAY_COMPAT" ;;
    latest) gh_latest XTLS/Xray-core ;;
    *)      echo "$XRAY_VER" ;;
  esac
}
xray_ver_label() {
  case ${XRAY_VER:-latest} in
    compat) echo "兼容版 $XRAY_COMPAT（固定，REALITY 对 Xray / sing-box / mihomo 客户端都能连）" ;;
    latest) echo "最新版（更新内核时跟着升级）" ;;
    *)      echo "固定 $XRAY_VER" ;;
  esac
}
xray_cur() { [[ -x $BIN_XRAY ]] && "$BIN_XRAY" version 2>/dev/null | awk 'NR==1{print "v"$2}'; }   # 不用 head：pipefail 下会因 SIGPIPE 返回失败
xray_ver_ask() {   # 第一次装 Xray 时选版本（环境变量 XRAY_VER=compat|latest|vX.Y.Z 可跳过询问）
  [[ -n $XRAY_VER ]] && { save_core_env; return; }
  if [[ $NONINT == 1 ]]; then XRAY_VER=compat; save_core_env; return; fi
  echo
  echo "选择 Xray 内核版本（以后可在主菜单 10「更新」里修改）："
  echo "  1) 兼容版 $XRAY_COMPAT   VLESS-REALITY 对 Xray / sing-box / mihomo（Clash Meta）内核的客户端都能连（实测）"
  echo "  2) 最新版              新版 REALITY 只有 Xray 内核客户端（如 v2rayN）能连，sing-box / mihomo 内核连不上"
  echo "  （只影响 REALITY；Hysteria2 / SS / Argo 两个版本都一样）"
  case $(ask "请选择" 1) in 2) XRAY_VER=latest ;; *) XRAY_VER=compat ;; esac
  save_core_env
}

install_xray() {
  [[ -x $BIN_XRAY && $1 != force ]] && return
  [[ -x $BIN_XRAY ]] || xray_ver_ask
  local tag tmp asset
  tag=$(xray_tag); [[ $tag == v* ]] || { red "获取 Xray 版本失败"; return 1; }
  yellow "下载 Xray 内核 $tag..."
  [[ $ARCH == amd64 ]] && asset=Xray-linux-64.zip || asset=Xray-linux-arm64-v8a.zip
  tmp=$(mktemp -d)
  if ! curl -fsL -o "$tmp/x.zip" "https://github.com/XTLS/Xray-core/releases/download/$tag/$asset" \
     || ! unzip -o -q "$tmp/x.zip" xray -d "$tmp" || ! "$tmp/xray" version >/dev/null 2>&1; then
    rm -rf "$tmp"; red "下载 Xray $tag 失败（版本号不存在或网络问题），原来的内核没动"; return 1
  fi
  install -m 755 "$tmp/xray" "$BIN_XRAY"; rm -rf "$tmp"
  green "Xray $(xray_cur) 已安装"
  svc_write onekey-xray "$BIN_XRAY run -c $XRAY_CONF"
}

set_xray_ver() {   # set_xray_ver compat|latest|vX.Y.Z：切换版本并重装 Xray（已装的话）
  local v=$1 old=$XRAY_VER
  case $v in
    compat|latest) ;;
    v[0-9]*.*) ;;
    [0-9]*.*) v=v$v ;;
    *) red "版本格式不对：$1（例：compat、latest、v26.6.27）"; return 1 ;;
  esac
  [[ $v == "$XRAY_COMPAT" ]] && v=compat
  XRAY_VER=$v
  if [[ -x $BIN_XRAY ]]; then
    local want; want=$(xray_tag)
    if [[ $want == "$(xray_cur)" ]]; then save_core_env; green "Xray 已经是 $want，版本设置改为：$(xray_ver_label)"; return 0; fi
    if ! install_xray force; then XRAY_VER=$old; return 1; fi
    [[ -f $XRAY_CONF ]] && { svc restart onekey-xray; sleep 1; }
    if [[ -f $XRAY_CONF && $(svc status onekey-xray) != active ]]; then
      red "Xray $want 启动失败（这个版本可能不支持现在的配置），换回原来的版本"
      XRAY_VER=$old; install_xray force && svc restart onekey-xray; return 1
    fi
  fi
  save_core_env
  green "Xray 版本：$(xray_ver_label)$( [[ -x $BIN_XRAY ]] && echo "，当前 $(xray_cur)")（节点链接不变）"
}
xray_ver_menu() {
  echo
  echo "当前 Xray：${XRAY_VER:+$(xray_ver_label)}$( [[ -x $BIN_XRAY ]] && echo "，已安装 $(xray_cur)")"
  echo "  1) 兼容版 $XRAY_COMPAT   REALITY 对 Xray / sing-box / mihomo（Clash Meta）内核的客户端都能连（推荐）"
  echo "  2) 最新版              REALITY 只有 Xray 内核客户端（如 v2rayN）能连"
  echo "  3) 指定版本号"
  echo "  0) 返回"
  local c; read -r -p "请选择 [0-3]: " c
  case $c in
    1) set_xray_ver compat ;;
    2) set_xray_ver latest ;;
    3) local v; read -r -p "版本号（如 v26.6.27，见 github.com/XTLS/Xray-core/releases）：" v; [[ -n $v ]] && set_xray_ver "$v" ;;
  esac
}

install_singbox() {
  [[ -x $BIN_SB && $1 != force ]] && return
  yellow "下载 sing-box 内核..."
  local tag ver suffix="" tmp
  tag=$(gh_latest SagerNet/sing-box); [[ $tag == v* ]] || die "获取 sing-box 版本失败"
  ver=${tag#v}
  [[ $PKG == apk ]] && suffix="-musl"
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/sb.tgz" "https://github.com/SagerNet/sing-box/releases/download/$tag/sing-box-$ver-linux-$ARCH$suffix.tar.gz" || die "下载 sing-box 失败"
  tar -xzf "$tmp/sb.tgz" -C "$tmp" || die "解压失败"
  install -m 755 "$tmp"/sing-box-*/sing-box "$BIN_SB"; rm -rf "$tmp"
  green "sing-box $($BIN_SB version | head -1 | awk '{print $3}') 已安装"
  svc_write onekey-sb "$BIN_SB run -c $SB_CONF"
}

install_snell() {
  [[ -x $BIN_SNELL ]] && return
  yellow "下载 snell-server $SNELL_VER..."
  [[ $PKG == apk ]] && apk add --no-cache gcompat libstdc++ >/dev/null
  local tmp; tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/s.zip" "https://dl.nssurge.com/snell/snell-server-$SNELL_VER-linux-$SNELL_ARCH.zip" || die "下载 snell-server 失败"
  unzip -o -q "$tmp/s.zip" -d "$tmp" && install -m 755 "$tmp/snell-server" "$BIN_SNELL"
  rm -rf "$tmp"
  svc_write onekey-snell "$BIN_SNELL -c $BASE/snell.conf"
}

install_cloudflared() {
  [[ -x $BIN_CF ]] && return
  yellow "下载 cloudflared..."
  curl -fsSL -o "$BIN_CF" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH" || die "下载 cloudflared 失败"
  chmod 755 "$BIN_CF"
}

need_core() {   # 给某个协议装好它需要的内核（第一次安装时顺便选 IPv4 / IPv6）
  first_ip_setup
  case $(core_of "$1") in
    xray)    install_xray ;;
    singbox) install_singbox ;;
    snell)   install_snell ;;
  esac
}

# ---------------- 证书（只给 Hysteria2 / TUIC / AnyTLS 用） ----------------
# CERT_MODE：domain = 域名证书    ip = IP 证书（Let's Encrypt 短期证书，约 6 天，acme.sh 自动续签）
#            self   = 自签证书
# 三种证书都放在 $CERT_DIR/cert.pem + key.pem，内核配置不用改；只有链接里的 SNI / 跳过验证不同
CERT_ENV=$BASE/cert.env
ACME_HOME=/root/.acme.sh
ACME=$ACME_HOME/acme.sh
ACME_LOG=$BASE/acme.log
CERT_MODE=""; CERT_DOMAIN=""; CERT_NAMES=""
[[ -f $CERT_ENV ]] && . "$CERT_ENV"
[[ -z $CERT_MODE && -f $CERT_DIR/cert.pem ]] && CERT_MODE=self   # 1.0 版装的都是自签
save_cert_env() {
  mkdir -p "$BASE"
  printf "CERT_MODE='%s'\nCERT_DOMAIN='%s'\nCERT_NAMES='%s'\n" "$CERT_MODE" "$CERT_DOMAIN" "$CERT_NAMES" >"$CERT_ENV"; chmod 600 "$CERT_ENV"
}
cert_label() {
  case $CERT_MODE in
    domain) echo "域名证书（$CERT_DOMAIN）" ;;
    ip)     echo "IP 证书（${CERT_NAMES// / + }，自动续签）" ;;
    self)   echo "自签证书" ;;
    *)      echo "未设置" ;;
  esac
}
cert_expiry() {
  [[ -s $CERT_DIR/cert.pem ]] || return
  local e; e=$(openssl x509 -enddate -noout -in "$CERT_DIR/cert.pem" | cut -d= -f2)
  date -d "$e" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$e"
}
uses_cert() { has hy2 || has tuic || has anytls; }
ca_mode() { [[ $CERT_MODE == ip || $CERT_MODE == domain ]]; }   # 正式证书（Let's Encrypt 签发）
ca_cert() { ca_mode && [[ -s $CERT_DIR/cert.pem ]]; }          # 正式证书且文件在
cert_needed() { uses_cert || sub_on; }                           # 还有东西用证书（订阅用它开 HTTPS）
cert_main() { echo "${CERT_NAMES%% *}"; }   # acme.sh 里记录这张证书用的名字
cert_ok_for() { openssl x509 -checkend "$1" -noout -in "$CERT_DIR/cert.pem" >/dev/null 2>&1; }   # 证书 $1 秒后仍有效
cert_warn() {   # 正式证书已过期 / 2 天内到期时显示红字警告
  ca_cert || return 0
  if ! cert_ok_for 0; then
    red "警告：证书已于 $(cert_expiry) 过期，Hysteria2 / TUIC / AnyTLS 和 HTTPS 订阅现在连不上！"
  elif ! cert_ok_for 172800; then
    red "警告：证书 $(cert_expiry) 到期，自动续签好像没成功"
  else return 0; fi
  yellow "  常见原因：TCP 80 和 443 端口都被占用，或被服务商防火墙拦截。处理后运行 onekey cert renew（日志：$ACME_LOG）"
}
tls_opts() {   # tls_opts 主机 -> "SNI 跳过验证(1/0)"
  case $CERT_MODE in
    domain) echo "$CERT_DOMAIN 0" ;;
    ip) if [[ " $CERT_NAMES " == *" $1 "* ]]; then echo "$1 0"; else echo "$1 1"; fi ;;   # 证书没包含这个 IP 时只能跳过验证
    *)  echo "$DEF_TLS_SNI 1" ;;
  esac
}

cert_reload() {   # 证书换了以后重启用到证书的内核（acme.sh 续签后自动调用 onekey cert reload）
  has hy2 && [[ -f $XRAY_CONF ]] && svc restart onekey-xray
  { has tuic || has anytls; } && [[ -f $SB_CONF ]] && svc restart onekey-sb
  sub_on && ca_cert && svc restart onekey-sub   # HTTPS 订阅也要换上新证书
  return 0
}

# 每天检查一次（acme.sh 自己的续签之外再兜底）：证书快过期说明 acme.sh 续签失败了，
# 这时按原类型重新申请（会依次试 80、443 端口），成功后重启内核、更新链接
CRON_LINE="17 4 * * * $CMD cert cron >/dev/null 2>&1"
cert_cron_set() {   # cert_cron_set on|off
  command -v crontab >/dev/null 2>&1 || return 0
  local cur; cur=$(crontab -l 2>/dev/null | grep -vF "$CMD cert cron")
  if [[ $1 == on ]]; then printf '%s\n%s\n' "$cur" "$CRON_LINE" | sed '/^$/d' | crontab -
  else printf '%s\n' "$cur" | sed '/^$/d' | crontab -; fi
}
cert_cron() {
  ca_cert || return 0
  local need=172800; [[ $CERT_MODE == domain ]] && need=1728000   # IP 证书剩 2 天、域名证书剩 20 天
  cert_ok_for "$need" && return 0
  echo "[$(date '+%F %T')] 证书 $(cert_expiry) 到期，acme.sh 没续签成功，重新申请" >>"$ACME_LOG"
  NONINT=1 set_cert "$CERT_MODE" "$CERT_DOMAIN" >>"$ACME_LOG" 2>&1 && cert_apply >/dev/null 2>&1
}

cert_release() {   # 没有东西用证书时停止续签；以后再需要时按原来的类型自动重新申请
  ca_mode && ! cert_needed || return 0
  acme_forget "$(cert_main)"; cert_cron_set off
  rm -f "$CERT_DIR/cert.pem" "$CERT_DIR/key.pem"
  yellow "已没有协议用到证书，停止向 Let's Encrypt 续签；以后再装 Hysteria2 / TUIC / AnyTLS 时会自动重新申请"
}

acme_install() {
  [[ -x $ACME ]] && return
  yellow "安装 acme.sh（申请证书 + 每天检查自动续签）..."
  case $PKG in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq socat cron >/dev/null 2>&1 \
           || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq socat cron >/dev/null; }
         systemctl enable --now cron >/dev/null 2>&1 ;;
    apk) apk add --no-cache socat >/dev/null; rc-update add crond default >/dev/null 2>&1; rc-service crond start >/dev/null 2>&1 ;;
    dnf|yum) $PKG install -y -q socat cronie >/dev/null; systemctl enable --now crond >/dev/null 2>&1 ;;
  esac
  command -v socat >/dev/null 2>&1 || { red "socat 安装失败"; return 1; }
  ( cd /tmp && curl -fsSL https://get.acme.sh | sh ) >"$ACME_LOG" 2>&1
  [[ -x $ACME ]] || { red "acme.sh 安装失败（日志：$ACME_LOG）"; return 1; }
  $ACME --upgrade --auto-upgrade >/dev/null 2>&1
}

acme_forget() {   # acme_forget 名字：不再续签这张证书
  [[ -x $ACME && -n $1 ]] || return 0
  $ACME --remove -d "$1" --ecc >/dev/null 2>&1; $ACME --remove -d "$1" >/dev/null 2>&1
  rm -rf "${ACME_HOME:?}/$1" "${ACME_HOME:?}/$1_ecc"
}

acme_issue() {   # acme_issue ip|domain 名字... -> 申请成功后装到 $CERT_DIR
  # 先用 TCP 80（HTTP 验证），80 被占用或验证不通过再用 TCP 443（TLS-ALPN 验证）；
  # 哪种成功 acme.sh 就记住哪种，以后续签沿用
  local kind=$1; shift
  local args=() n p ok=0 mode=()
  for n in "$@"; do args+=(-d "$n"); done
  local extra=()
  [[ $kind == ip ]] && extra=(--certificate-profile shortlived --days 3)   # IP 证书约 6 天有效，3 天续签一次
  for p in ${ACME_PORTS:-80 443}; do
    if tcp_busy "$p"; then yellow "TCP $p 端口被 $(port_owner "$p") 占用，不能用它验证"; continue; fi
    [[ $p == 80 ]] && mode=(--standalone --httpport 80) || mode=(--alpn --tlsport 443)
    open_port "$p" tcp
    yellow "向 Let's Encrypt 申请证书：$*（用 TCP $p 端口验证，约半分钟）..."
    if $ACME --issue "${args[@]}" "${mode[@]}" --server letsencrypt --keylength ec-256 --force "${extra[@]}" >>"$ACME_LOG" 2>&1; then ok=1; break; fi
    acme_forget "$1"; yellow "TCP $p 端口验证没通过"
  done
  [[ $ok == 1 ]] || return 1
  mkdir -p "$CERT_DIR"
  # 先装到临时位置确认成功，再替换正在用的证书
  local td; td=$(mktemp -d)
  $ACME --install-cert -d "$1" --ecc --key-file "$td/key.pem" --fullchain-file "$td/cert.pem" >>"$ACME_LOG" 2>&1
  if [[ ! -s $td/cert.pem || ! -s $td/key.pem ]]; then rm -rf "$td"; acme_forget "$1"; return 1; fi
  install -m 644 "$td/cert.pem" "$CERT_DIR/cert.pem"; install -m 600 "$td/key.pem" "$CERT_DIR/key.pem"; rm -rf "$td"
  # 以后续签直接装到正式位置，并重启内核
  $ACME --install-cert -d "$1" --ecc --key-file "$CERT_DIR/key.pem" --fullchain-file "$CERT_DIR/cert.pem" \
    --reloadcmd "$CMD cert reload" >>"$ACME_LOG" 2>&1
  return 0
}

cert_ip() {   # IP 证书：按「IP 设置」申请；IPv4+IPv6 一起申请失败时，再分别单独试
  acme_install || return 1
  [[ -z $IP4$IP6 ]] && get_ip
  local tries=() t
  case $LINK_IP in
    4) tries=("${IP4:-$IP6}") ;;
    6) tries=("${IP6:-$IP4}") ;;
    *) if [[ -n $IP4 && -n $IP6 ]]; then tries=("$IP4 $IP6" "$IP4" "$IP6"); else tries=("$IP4$IP6"); fi ;;
  esac
  for t in "${tries[@]}"; do
    # shellcheck disable=SC2086
    if acme_issue ip $t; then
      CERT_NAMES=$t; CERT_DOMAIN=""
      [[ $t != "${tries[0]}" ]] && yellow "「${tries[0]// / + }」没有全部验证通过，证书只包含 $t（其它 IP 的链接会跳过证书验证）"
      return 0
    fi
  done
  red "IP 证书申请失败：TCP 80 或 443 端口至少要有一个空着、能从外网访问（服务商安全组要放行）（日志：$ACME_LOG）"
  return 1
}

dns_lookup() {   # dns_lookup 域名 A|AAAA -> 解析结果（用公共 DNS，避免本机 hosts 干扰）
  curl -fsS --max-time 8 -H 'accept: application/dns-json' "https://dns.google/resolve?name=$1&type=$2" 2>/dev/null \
    | jq -r --arg t "$([[ $2 == A ]] && echo 1 || echo 28)" '.Answer[]? | select(.type == ($t|tonumber)) | .data'
}
cert_domain() {   # 域名证书：域名必须已解析到本机
  local d=${1,,}
  [[ $d =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || { red "域名格式不对：$1"; return 1; }
  [[ -z $IP4$IP6 ]] && get_ip
  local a aaaa hit=0
  a=$(dns_lookup "$d" A); aaaa=$(dns_lookup "$d" AAAA)
  [[ -n $IP4 ]] && grep -qxF "$IP4" <<<"$a" && hit=1
  [[ -n $IP6 ]] && grep -qxF "$IP6" <<<"$aaaa" && hit=1
  if [[ $hit == 0 ]]; then
    red "域名 $d 没有解析到本机（A：$(echo $a)  AAAA：$(echo $aaaa)；本机：$IP4 $IP6）"
    yellow "先在域名的 DNS 里添加 A 记录指向 $IP4${IP6:+（或 AAAA 指向 $IP6）}；用 Cloudflare 的要关掉小黄云（仅 DNS），等几分钟再试"
    return 1
  fi
  [[ -n $aaaa && -z $IP6 ]] && yellow "提示：域名有 AAAA 记录但本机没有 IPv6，Let's Encrypt 可能优先走 IPv6 导致验证失败"
  acme_install || return 1
  acme_issue domain "$d" || { red "域名证书申请失败：TCP 80 或 443 端口至少要有一个空着、能从外网访问（日志：$ACME_LOG）"; return 1; }
  CERT_DOMAIN=$d; CERT_NAMES=$d
}

cert_self() {
  mkdir -p "$CERT_DIR"
  openssl ecparam -genkey -name prime256v1 -out "$CERT_DIR/key.pem" 2>/dev/null
  openssl req -new -x509 -days 3650 -key "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" -subj "/CN=$DEF_TLS_SNI" 2>/dev/null
  chmod 600 "$CERT_DIR/key.pem"
  CERT_DOMAIN=""; CERT_NAMES=""
}

set_cert() {   # set_cert ip|domain|self [域名]：申请 / 生成证书并记录；失败时原来的证书不动
  local mode=$1 d=$2 old_mode=$CERT_MODE old_main old_label; old_main=$(cert_main); old_label=$(cert_label)
  OLD_SUB_URL=$(sub_on && sub_url sub)   # cert_apply 用来判断订阅地址变没变
  if [[ $mode == domain && -z $d ]]; then
    [[ $NONINT == 1 ]] && { red "域名证书需要 DOMAIN=你的域名"; return 1; }
    read -r -p "输入已解析到本机的域名：" d
    [[ -n $d ]] || return 1
  fi
  case $mode in
    ip)     cert_ip || return 1 ;;
    domain) cert_domain "$d" || return 1 ;;
    self)   cert_self ;;
    *)      red "未知证书类型：$mode"; return 1 ;;
  esac
  CERT_MODE=$mode; save_cert_env
  [[ $(cert_label) != "$old_label" ]] && CERT_CHANGED=1 || CERT_CHANGED=0
  [[ ($old_mode == ip || $old_mode == domain) && -n $old_main && $old_main != "$(cert_main)" ]] && acme_forget "$old_main"
  ca_mode && cert_cron_set on || cert_cron_set off
  green "证书：$(cert_label)$( [[ $mode != self ]] && echo "，到期 $(cert_expiry)")"
}

gen_cert() {   # 装 Hysteria2 / TUIC / AnyTLS 时准备证书（环境变量 CERT=ip|domain|self、DOMAIN= 可跳过询问）
  [[ -n $CERT_MODE && -s $CERT_DIR/cert.pem ]] && return
  local m=${CERT:-} d=${DOMAIN:-}
  if [[ -z $m && -n $CERT_MODE ]]; then   # 之前用过、后来没协议用而停掉的证书：按原类型直接重新申请
    m=$CERT_MODE; d=${d:-$CERT_DOMAIN}
    yellow "按之前的设置重新申请：$(cert_label)"
  fi
  if [[ -z $m && $NONINT != 1 ]]; then
    echo
    echo "Hysteria2 / TUIC / AnyTLS 需要 TLS 证书，选择证书类型（以后可在主菜单「证书设置」修改）："
    echo "  1) 域名证书   最不容易被识别，需要一个已解析到本机的域名"
    echo "  2) IP 证书    Let's Encrypt 签发，不需要域名，自动续签（TCP 80 或 443 端口要能从外网访问）"
    echo "  3) 自签证书   什么都不需要，但容易被识别，客户端要跳过证书验证"
    case $(ask "请选择" 2) in 1) m=domain;; 3) m=self;; *) m=ip;; esac
  fi
  if ! set_cert "${m:-ip}" "$d"; then
    yellow "先改用自签证书，节点照常可用；以后可在主菜单「证书设置」重新申请"
    set_cert self
  fi
  sub_refresh
}

cert_apply() {   # 换证书后：重启内核，更新链接 / Clash / 订阅
  cert_reload
  sub_on && sub_service
  gen_clients >/dev/null 2>&1
  if uses_cert && [[ ${CERT_CHANGED:-1} == 1 ]]; then
    yellow "Hysteria2 / TUIC / AnyTLS 的链接已更新（SNI / 证书验证变了），客户端需重新导入或更新订阅"
  elif uses_cert; then
    green "证书已换新，节点链接不变"
  fi
  if sub_on && [[ $(sub_url sub) != "${OLD_SUB_URL:-}" ]]; then
    yellow "订阅地址变成：$(sub_url sub)（客户端需重新导入订阅）"
  fi
}
cert_renew() {
  case $CERT_MODE in
    ip|domain)
      [[ -x $ACME ]] || { red "找不到 acme.sh"; return 1; }
      yellow "续签中..."
      if $ACME --renew -d "$(cert_main)" --ecc --force >>"$ACME_LOG" 2>&1; then green "已续签，到期 $(cert_expiry)"
      else red "续签失败（日志：$ACME_LOG）"; return 1; fi ;;
    *) yellow "当前是自签证书，不需要续签" ;;
  esac
}
cert_menu() {
  echo
  echo "当前证书：$(cert_label)$( [[ -s $CERT_DIR/cert.pem ]] && echo "    到期：$(cert_expiry)")"
  cert_warn
  echo "（证书给 Hysteria2 / TUIC / AnyTLS 和 HTTPS 订阅用；REALITY、Argo、SS、Snell 不需要证书）"
  echo
  echo "  1) 域名证书   最不容易被识别，需要已解析到本机的域名"
  echo "  2) IP 证书    Let's Encrypt，自动续签（推荐，需要 TCP 80 或 443 端口）"
  echo "  3) 自签证书   容易被识别"
  echo "  4) 立即续签"
  echo "  0) 返回"
  local c; read -r -p "请选择 [0-4]: " c
  case $c in
    1) set_cert domain && cert_apply ;;
    2) set_cert ip && cert_apply ;;
    3) set_cert self && cert_apply ;;
    4) cert_renew ;;
  esac
}

# 不依赖内核的密钥生成
gen_uuid() { cat /proc/sys/kernel/random/uuid; }
gen_x25519() {   # 输出 "私钥 公钥"（base64url，REALITY 通用格式）
  local k; k=$(openssl genpkey -algorithm X25519 2>/dev/null) || die "openssl 不支持 X25519"
  printf '%s %s\n' \
    "$(echo "$k" | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')" \
    "$(echo "$k" | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')"
}

# ---------------- 状态 & 配置 ----------------
save_state() {   # save_state 协议 KEY=VAL ...
  local f=$STATE/$1.env; shift
  mkdir -p "$STATE"; : >"$f"; chmod 600 "$f"
  local kv; for kv in "$@"; do printf "%s='%s'\n" "${kv%%=*}" "${kv#*=}" >>"$f"; done
}
has() { [[ -f $STATE/$1.env ]]; }

xray_inbound() {   # Xray inbound JSON
  local p=$1; ( . "$STATE/$p.env"
  case $p in
    reality) jq -nc --arg la "$LISTEN_ALL" --argjson port "$PORT" --arg u "$UUID" --arg sni "$SNI" --arg pk "$PRIV" --arg sid "$SID" \
      '{tag:"vless-reality",listen:$la,port:$port,protocol:"vless",
        settings:{clients:[{id:$u,flow:"xtls-rprx-vision"}],decryption:"none"},
        streamSettings:{network:"tcp",security:"reality",
          realitySettings:{show:false,target:($sni+":443"),xver:0,serverNames:[$sni],privateKey:$pk,shortIds:[$sid]}}}' ;;
    hy2) jq -nc --arg la "$LISTEN_ALL" --argjson port "$PORT" --arg pw "$PASS" --arg c "$CERT_DIR/cert.pem" --arg k "$CERT_DIR/key.pem" \
      '{tag:"hysteria2",listen:$la,port:$port,protocol:"hysteria",
        settings:{version:2,clients:[{auth:$pw}]},
        streamSettings:{network:"hysteria",hysteriaSettings:{version:2},security:"tls",
          tlsSettings:{alpn:["h3"],certificates:[{certificateFile:$c,keyFile:$k}]}}}' ;;
    argo) jq -nc --arg la "$LISTEN_ALL" --argjson port "$PORT" --arg u "$UUID" --arg path "$WSPATH" \
      '{tag:"vless-argo",listen:"127.0.0.1",port:$port,protocol:"vless",
        settings:{clients:[{id:$u}],decryption:"none"},
        streamSettings:{network:"ws",wsSettings:{path:$path}}}' ;;
    ss) jq -nc --arg la "$LISTEN_ALL" --argjson port "$PORT" --arg m "$METHOD" --arg pw "$PASS" \
      '{tag:"shadowsocks",listen:$la,port:$port,protocol:"shadowsocks",
        settings:{method:$m,password:$pw,network:"tcp,udp"}}' ;;
  esac )
}

sb_inbound() {   # sing-box inbound JSON
  local p=$1; ( . "$STATE/$p.env"
  local tls; tls=$(jq -nc --arg c "$CERT_DIR/cert.pem" --arg k "$CERT_DIR/key.pem" '{enabled:true,alpn:["h3"],certificate_path:$c,key_path:$k}')
  case $p in
    tuic) jq -nc --arg la "$LISTEN_ALL" --argjson port "$PORT" --arg u "$UUID" --arg pw "$PASS" --argjson tls "$tls" \
      '{type:"tuic",tag:"tuic",listen:$la,listen_port:$port,users:[{uuid:$u,password:$pw}],congestion_control:"bbr",tls:$tls}' ;;
    anytls) jq -nc --arg la "$LISTEN_ALL" --argjson port "$PORT" --arg pw "$PASS" --argjson tls "$tls" \
      '{type:"anytls",tag:"anytls",listen:$la,listen_port:$port,users:[{name:"onekey",password:$pw}],tls:($tls|del(.alpn))}' ;;
  esac )
}

drop_core() {   # 没有协议用到时，停掉并删除该内核
  case $1 in
    xray)    [[ -x $BIN_XRAY ]] || return; svc_remove onekey-xray; rm -f "$BIN_XRAY" "$XRAY_CONF"; yellow "已没有协议使用 Xray，内核已删除" ;;
    singbox) [[ -x $BIN_SB ]] || return; svc_remove onekey-sb; rm -f "$BIN_SB" "$SB_CONF"; yellow "已没有协议使用 sing-box，内核已删除" ;;
  esac
}

apply_xray() {
  local p list=() tmp
  for p in "${XRAY_PROTOS[@]}"; do has $p && list+=("$(xray_inbound $p)"); done
  if [[ ${#list[@]} -eq 0 ]]; then drop_core xray; return; fi
  install_xray
  local td; td=$(mktemp -d); tmp=$td/xray.json   # Xray 按扩展名识别配置格式
  printf '%s\n' "${list[@]}" | jq -s --arg ds "$(xray_strategy)" '{log:{loglevel:"warning"},inbounds:.,
     outbounds:[{protocol:"freedom",tag:"direct",settings:{domainStrategy:$ds}},{protocol:"blackhole",tag:"block"}]}' >"$tmp"
  if ! $BIN_XRAY run -test -c "$tmp" >"$td/err" 2>&1; then
    red "Xray 配置检查失败："; tail -5 "$td/err"; rm -rf "$td"; return 1
  fi
  install -m 600 "$tmp" "$XRAY_CONF"; rm -rf "$td"
  svc restart onekey-xray; sleep 1
  [[ $(svc status onekey-xray) == active ]] || { red "Xray 启动失败，查看日志：journalctl -u onekey-xray -n 30"; return 1; }
}

apply_singbox() {
  local p list=() tmp
  for p in "${SB_PROTOS[@]}"; do has $p && list+=("$(sb_inbound $p)"); done
  if [[ ${#list[@]} -eq 0 ]]; then drop_core singbox; return; fi
  install_singbox
  tmp=$(mktemp)
  printf '%s\n' "${list[@]}" | jq -s --arg st "$(sb_strategy)" '{log:{level:"warn",timestamp:true},inbounds:.,outbounds:[{type:"direct",tag:"direct"}]}
     + (if $st == "" then {} else {dns:{servers:[{type:"local",tag:"local"}]},route:{default_domain_resolver:{server:"local",strategy:$st}}} end)' >"$tmp"
  if ! $BIN_SB check -c "$tmp" >/dev/null 2>"$tmp.err"; then
    red "sing-box 配置检查失败："; cat "$tmp.err"; rm -f "$tmp" "$tmp.err"; return 1
  fi
  install -m 600 "$tmp" "$SB_CONF"; rm -f "$tmp" "$tmp.err"
  svc restart onekey-sb; sleep 1
  [[ $(svc status onekey-sb) == active ]] || { red "sing-box 启动失败，查看日志：journalctl -u onekey-sb -n 30"; return 1; }
}

apply_core_of() {   # 只重载某协议所属的内核
  case $(core_of "$1") in xray) apply_xray ;; singbox) apply_singbox ;; esac
}

rebuild() {   # 按「Xray 优先」重新分配内核（旧版全用 sing-box 的安装可用它迁移）
  local ok=1
  apply_singbox || ok=0   # 先让 sing-box 释放已归 Xray 的端口
  apply_xray || ok=0
  if has argo && [[ $(svc status onekey-argo) != active ]]; then argo_service >/dev/null; fi
  gen_clients >/dev/null 2>&1
  if [[ $ok == 1 ]]; then green "已按当前规则重建：Xray 负责 REALITY / Hysteria2 / Argo / SS，sing-box 负责 TUIC / AnyTLS"
  else red "重建时有内核出错，见上方信息"; return 1; fi
}

update_cores() {
  local any=0
  if [[ -x $BIN_XRAY ]]; then
    any=1
    if [[ ${XRAY_VER:-latest} != latest && $(xray_tag) == "$(xray_cur)" ]]; then
      green "Xray 固定在 $(xray_cur)，不升级；要换版本用「更新」菜单里的「Xray 版本」"
    else
      install_xray force && [[ -f $XRAY_CONF ]] && svc restart onekey-xray
    fi
  fi
  [[ -x $BIN_SB ]]   && { any=1; install_singbox force; [[ -f $SB_CONF ]] && svc restart onekey-sb; }
  [[ $any == 0 ]] && yellow "还没有安装任何内核（选择协议时才会安装）"
  return 0
}

# ---------------- 更新脚本 ----------------
self_update() {   # 下载最新版脚本替换 onekey 命令，然后让新版做必要的迁移
  local tmp nv; tmp=$(mktemp)
  yellow "下载最新版脚本..."
  if ! curl -fsSL -o "$tmp" "$SCRIPT_URL" || ! bash -n "$tmp" 2>/dev/null || ! grep -q '^ONEKEY_VER=' "$tmp"; then
    rm -f "$tmp"; red "下载失败或文件不完整，没有更新"; return 1
  fi
  nv=$(grep -m1 '^ONEKEY_VER=' "$tmp" | cut -d'"' -f2)
  if [[ $nv == "$ONEKEY_VER" && $1 != force ]]; then rm -f "$tmp"; green "已经是最新版 v$ONEKEY_VER"; return 0; fi
  install -m 755 "$tmp" "$CMD"; rm -f "$tmp"
  green "脚本已更新：v$ONEKEY_VER → v$nv（节点参数和链接不变）"
  "$CMD" migrate
}
migrate() {   # 新版脚本第一次运行时调用：按新规则更新服务，不改节点参数
  sub_refresh
  ca_cert && cert_cron_set on
  if [[ -n $(hop_range) ]]; then
    hop_apply >/dev/null 2>&1 && hop_service on
    # 1.2.0 检查端口冲突有 bug，可能把别的协议的 UDP 端口划进了跳跃范围
    hop_ok_range "$(hop_range)" "$( . "$STATE/hy2.env"; echo "$PORT")" >/dev/null 2>&1 \
      || { red "注意：端口跳跃范围 $(hop_range) 里有别的协议的 UDP 端口，那个协议会连不上"; yellow "运行 onekey hop on 自动换一个不冲突的范围"; }
  fi
  ls "$STATE"/*.env >/dev/null 2>&1 && gen_clients >/dev/null 2>&1
  return 0
}
update_menu() {
  echo
  echo "  1) 更新脚本（onekey 本身，当前 v$ONEKEY_VER）"
  echo "  2) 更新内核（sing-box 换成最新版；Xray 按「Xray 版本」设置，会短暂断线）"
  echo "  3) Xray 版本（当前 $( [[ -x $BIN_XRAY ]] && xray_cur || echo 未安装)$(case ${XRAY_VER:-latest} in compat) echo "，兼容版";; latest) echo "，跟随最新版";; *) echo "，固定版本";; esac)）"
  echo "  0) 返回"
  local c; read -r -p "请选择 [0-3]: " c
  case $c in
    1) self_update && { yellow "重新打开菜单..."; exec "$CMD"; } ;;
    2) update_cores ;;
    3) xray_ver_menu ;;
  esac
}

# ---------------- Hysteria2 端口跳跃 ----------------
# 用 nftables 把一段 UDP 端口全部转到 Hysteria2 的端口，客户端在这些端口之间轮换，
# 不容易被针对单个端口限速 / 封锁。规则开机由 onekey-hop 服务重新加载
HOP_DEFAULTS="20000-29999 30000-39999 40000-49999"
hop_ok_range() {   # hop_ok_range 范围 Hysteria2端口：检查格式，以及范围里没有别的程序在用 UDP 端口
  local r=$1 hp=$2 a b p
  [[ $r =~ ^([0-9]+)-([0-9]+)$ ]] || { red "范围格式不对，例：20000-29999"; return 1; }
  a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
  (( a >= 1024 && b <= 65535 && a < b )) || { red "范围要在 1024-65535 之间，并且前小后大"; return 1; }
  for p in $(ss -Hlnu 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -u); do   # 只列 UDP 时第 4 列是本地地址
    if (( p >= a && p <= b )) && [[ $p != "$hp" ]]; then red "UDP 端口 $p 已有程序在用，并且在 $r 里，换一个范围"; return 1; fi
  done
}
hop_default() {   # hop_default Hysteria2端口 -> 第一个没冲突的默认范围
  local r; for r in $HOP_DEFAULTS; do hop_ok_range "$r" "$1" >/dev/null 2>&1 && { echo "$r"; return; }; done
  echo "${HOP_DEFAULTS%% *}"
}
hop_need_nft() {
  if ! command -v nft >/dev/null 2>&1; then
    yellow "安装 nftables..."
    case $PKG in
      apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables >/dev/null 2>&1 \
             || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables >/dev/null; } ;;
      apk) apk add --no-cache nftables >/dev/null ;;
      dnf|yum) $PKG install -y -q nftables >/dev/null ;;
    esac
  fi
  command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1 || { red "nftables 不可用（部分 OpenVZ / LXC 小鸡不支持），不能开端口跳跃"; return 1; }
}
hop_apply() {   # 按 hy2.env 里的 HOP 重新写规则；没有 HOP 就删掉规则
  command -v nft >/dev/null 2>&1 && nft delete table inet onekey_hop >/dev/null 2>&1
  local r p; r=$(hop_range); [[ -n $r ]] || return 0
  p=$( . "$STATE/hy2.env"; echo "$PORT")
  hop_need_nft || return 1
  # pre：外面进来的；out：本机自己连自己的公网 IP（test_links.sh 在服务器上测试时用）
  nft -f - <<EOF || { red "写入端口跳跃规则失败"; return 1; }
table inet onekey_hop {
  chain pre {
    type nat hook prerouting priority -100; policy accept;
    udp dport $r counter redirect to :$p
  }
  chain out {
    type nat hook output priority -100; policy accept;
    fib daddr type local udp dport $r counter redirect to :$p
  }
}
EOF
}
hop_service() {   # hop_service on|off：开机自动加载规则
  local name=onekey-hop
  if [[ $1 == off ]]; then
    { [[ -f /etc/systemd/system/$name.service ]] || [[ -f /etc/init.d/$name ]]; } && svc_remove $name
    return 0
  fi
  if [[ $INIT == systemd ]]; then
    cat >/etc/systemd/system/$name.service <<EOF
[Unit]
Description=OneKey Hysteria2 port hopping
After=network.target nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$CMD hop apply
ExecStop=$(command -v nft) delete table inet onekey_hop

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable $name >/dev/null 2>&1; systemctl start $name >/dev/null 2>&1
  else
    cat >/etc/init.d/$name <<EOF
#!/sbin/openrc-run
description="OneKey Hysteria2 port hopping"
depend() { need net; after firewall nftables; }
start() { $CMD hop apply; }
stop() { nft delete table inet onekey_hop >/dev/null 2>&1; return 0; }
EOF
    chmod +x /etc/init.d/$name; rc-update add $name default >/dev/null 2>&1; rc-service $name start >/dev/null 2>&1
  fi
}
hop_set() {   # hop_set 范围|on|off
  has hy2 || { yellow "还没有安装 Hysteria2"; return 1; }
  local r=$1 p; p=$( . "$STATE/hy2.env"; echo "$PORT")
  if [[ $r == off ]]; then r=""
  else
    [[ -z $r || $r == on ]] && r=$(hop_default "$p")
    r=${r/:/-}; hop_ok_range "$r" "$p" || return 1
  fi
  sed -i '/^HOP=/d' "$STATE/hy2.env"; [[ -n $r ]] && echo "HOP='$r'" >>"$STATE/hy2.env"
  if ! hop_apply; then sed -i '/^HOP=/d' "$STATE/hy2.env"; hop_apply; hop_service off; return 1; fi
  if [[ -n $r ]]; then
    open_port "$r" udp; hop_service on
    green "端口跳跃已开启：UDP $r → Hysteria2 端口 $p"
    yellow "服务商安全组也要放行 UDP $r；客户端链接 / 订阅已更新，需重新导入"
  else
    hop_service off; green "端口跳跃已关闭"
  fi
  gen_clients >/dev/null 2>&1
}
hop_menu() {
  has hy2 || { yellow "还没有安装 Hysteria2"; return; }
  local r; r=$(hop_range)
  echo
  echo "Hysteria2 端口跳跃：$([[ -n $r ]] && echo "已开启 UDP $r → 端口 $( . "$STATE/hy2.env"; echo "$PORT")" || echo "未开启")"
  echo "（客户端在一段端口之间轮换，不容易被针对单个端口限速 / 封锁；需要客户端支持，如 Clash Meta / mihomo、sing-box、v2rayN；不支持的客户端照常用单端口）"
  echo
  echo "  1) 开启 / 修改范围"
  echo "  2) 关闭"
  echo "  0) 返回"
  local c; read -r -p "请选择 [0-2]: " c
  case $c in
    1) hop_set "$(ask "端口范围" "${r:-$(hop_default "$( . "$STATE/hy2.env"; echo "$PORT")")}")" ;;
    2) hop_set off ;;
  esac
}

# ---------------- 各协议安装 ----------------
confirm_overwrite() {
  has "$1" || return 0
  [[ $NONINT == 1 ]] && return 0
  local a; read -r -p "$2 已存在，覆盖重装？（旧链接和密码会作废）[Y/n]: " a
  [[ $a != [nN] ]]
}

add_reality() {
  confirm_overwrite reality VLESS-REALITY || return
  need_core reality; ask_port "VLESS-REALITY" reality
  local sni kp; sni=$(ask "伪装域名 (SNI)" "${SNI:-$DEF_REALITY_SNI}")
  kp=$(gen_x25519)
  save_state reality PORT="$PORT" UUID="$(gen_uuid)" SNI="$sni" PRIV="${kp%% *}" PUB="${kp##* }" SID="$(rand_hex 8)"
  open_port "$PORT" tcp; apply_xray && show_links reality
}
add_hy2() {
  confirm_overwrite hy2 Hysteria2 || return
  need_core hy2; gen_cert; ask_port "Hysteria2 (UDP)" hy2
  local hop=${HOP_RANGE:-}   # 非交互：HOP_RANGE=on 或 20000-29999 开启端口跳跃
  if [[ -z $hop && $NONINT != 1 ]]; then
    local a; read -r -p "开启端口跳跃？（一段 UDP 端口都转给 Hysteria2，不容易被针对单个端口限速）[Y/n]: " a
    [[ $a != [nN] ]] && hop=$(ask "端口范围" "$(hop_default "$PORT")")
  fi
  save_state hy2 PORT="$PORT" PASS="$(rand_pw 24)"
  open_port "$PORT" udp
  if [[ -n $hop && $hop != off ]]; then hop_set "$hop" || yellow "端口跳跃没开成，Hysteria2 照常用单端口"; else hop_set off >/dev/null 2>&1; fi
  apply_xray && show_links hy2
}
add_tuic() {
  confirm_overwrite tuic TUIC || return
  need_core tuic; gen_cert; ask_port "TUIC (UDP)" tuic
  save_state tuic PORT="$PORT" UUID="$(gen_uuid)" PASS="$(rand_pw 16)"
  open_port "$PORT" udp; apply_singbox && show_links tuic
}
add_anytls() {
  confirm_overwrite anytls AnyTLS || return
  need_core anytls; gen_cert; ask_port "AnyTLS" anytls
  save_state anytls PORT="$PORT" PASS="$(rand_pw 24)"
  open_port "$PORT" tcp; apply_singbox && show_links anytls
}
add_ss() {
  confirm_overwrite ss Shadowsocks || return
  need_core ss; ask_port "Shadowsocks" ss
  local m pw
  if [[ $NONINT == 1 ]]; then m=${METHOD:-aes-256-gcm}
  else
    echo "加密方式："
    echo "  1) aes-256-gcm（默认，3x-ui 落地常用）"
    echo "  2) chacha20-ietf-poly1305"
    echo "  3) 2022-blake3-aes-128-gcm"
    case $(ask "请选择" 1) in 2) m=chacha20-ietf-poly1305 ;; 3) m=2022-blake3-aes-128-gcm ;; *) m=aes-256-gcm ;; esac
  fi
  if [[ $m == 2022-* ]]; then pw=$(openssl rand -base64 16); else pw=$(rand_pw 24); fi
  save_state ss PORT="$PORT" METHOD="$m" PASS="$pw"
  open_port "$PORT" both; apply_xray && show_links ss
}
add_argo() {
  confirm_overwrite argo VLESS-Argo || return
  need_core argo; install_cloudflared
  local port token="" domain=""
  port=$(rand_port)
  if [[ $NONINT != 1 ]]; then
    echo "Argo 隧道类型："
    echo "  1) 临时隧道（默认，免账号，重启后域名会变）"
    echo "  2) 固定隧道（需要 Cloudflare Tunnel Token 和自己的域名）"
    if [[ $(ask "请选择" 1) == 2 ]]; then
      read -r -p "粘贴 Tunnel Token: " token
      read -r -p "隧道绑定的域名（如 argo.example.com）: " domain
      yellow "请在 Cloudflare 后台把该域名的服务指向 http://localhost:$port"
    fi
  fi
  save_state argo PORT="$port" UUID="$(gen_uuid)" WSPATH="/$(rand_hex 6)" TOKEN="$token" DOMAIN="$domain"
  apply_xray || return
  argo_service
  show_links argo
}
argo_service() {   # 按 argo.env 创建 / 重启 cloudflared 隧道服务
  install_cloudflared
  ( . "$STATE/argo.env"
    if [[ -n $TOKEN ]]; then
      svc_write onekey-argo "$BIN_CF tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token $TOKEN" "$ARGO_LOG"
    else
      svc_write onekey-argo "$BIN_CF tunnel --no-autoupdate --edge-ip-version auto --protocol http2 --url http://127.0.0.1:$PORT" "$ARGO_LOG"
    fi )
  : >"$ARGO_LOG"; svc restart onekey-argo
  yellow "等待 Argo 隧道建立..."
  argo_domain >/dev/null
}
argo_domain() {   # 输出当前 Argo 域名
  ( . "$STATE/argo.env"
    if [[ -n $DOMAIN ]]; then echo "$DOMAIN"; return; fi
    local d=""
    for _ in $(seq 1 30); do
      d=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$ARGO_LOG" 2>/dev/null | tail -1 | sed 's#https://##')
      [[ -n $d ]] && break; sleep 1
    done
    echo "$d" )
}
write_snell_conf() {
  ( . "$STATE/snell.env"
    cat >"$BASE/snell.conf" <<EOF
[snell-server]
listen = 0.0.0.0:$PORT$( [[ $LISTEN_ALL == "::" ]] && echo ",[::]:$PORT")
psk = $PSK
mode = $MODE
dns-ip-preference = $(snell_pref)
EOF
  )
  chmod 600 "$BASE/snell.conf"
}
add_snell() {
  confirm_overwrite snell "Snell v6" || return
  need_core snell; ask_port "Snell v6" snell
  local psk mode; psk=$(rand_pw 32)
  mode=$(ask "模式 default/unshaped（客户端要一致）" "${MODE:-default}")
  save_state snell PORT="$PORT" PSK="$psk" MODE="$mode"
  write_snell_conf
  open_port "$PORT" both; svc restart onekey-snell; sleep 1
  [[ $(svc status onekey-snell) == active ]] || red "snell-server 启动失败"
  show_links snell
}

# ---------------- 链接输出 ----------------
NAME_PREFIX=${NAME_PREFIX:-$(hostname -s 2>/dev/null)}
[[ -z $NAME_PREFIX || $NAME_PREFIX == localhost* ]] && NAME_PREFIX=onekey
link_for() {   # link_for 协议 主机 -> 链接
  local p=$1 h=$2 hb=$2
  [[ $h == *:* ]] && hb="[$h]"
  ( HOP=""; . "$STATE/$p.env"
  local tag; tag=$(uri "$NAME_PREFIX-$p$( [[ $h == *:* ]] && echo -v6)")
  local sni ins ti="" tt=""; read -r sni ins <<<"$(tls_opts "$h")"; sni=$(uri "$sni")
  [[ $ins == 1 ]] && { ti="&insecure=1&allowInsecure=1"; tt="&allow_insecure=1&allowInsecure=1"; }
  case $p in
    reality) echo "vless://$UUID@$hb:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SID&type=tcp&headerType=none#$tag" ;;
    hy2)     echo "hysteria2://$PASS@$hb:$PORT?sni=$sni&alpn=h3$ti${HOP:+&mport=$HOP}#$tag" ;;
    tuic)    echo "tuic://$UUID:$PASS@$hb:$PORT?sni=$sni&alpn=h3&congestion_control=bbr&udp_relay_mode=native$tt#$tag" ;;
    anytls)  echo "anytls://$PASS@$hb:$PORT?sni=$sni$ti#$tag" ;;
    ss)      echo "ss://$(b64url "$METHOD:$PASS")@$hb:$PORT#$tag" ;;
    snell)   echo "$NAME_PREFIX-snell$( [[ $h == *:* ]] && echo -v6) = snell, $h, $PORT, psk=$PSK, version=6, reuse=true$( [[ $MODE != default ]] && echo ", mode=$MODE")" ;;
  esac )
}
pretty() { case $1 in reality) echo VLESS-REALITY;; hy2) echo Hysteria2;; tuic) echo TUIC;; anytls) echo AnyTLS;; argo) echo VLESS-Argo;; ss) echo Shadowsocks;; snell) echo "Snell v6";; esac; }

argo_link() { ( . "$STATE/argo.env"; echo "vless://$UUID@$1:443?encryption=none&security=tls&sni=$1&fp=chrome&type=ws&host=$1&path=$(uri "$WSPATH")#$(uri "$NAME_PREFIX-argo")" ); }

ss_params() {   # SS 的明文参数：当中转落地时在 3x-ui 出站 / 其它面板里手动填
  ( . "$STATE/ss.env"
    local hs; hs=$(link_hosts | sed 's/ /  或  /')
    echo "手动填写的参数（3x-ui 出站 / 中转落地用）："
    echo "  地址：$hs"
    echo "  端口：$PORT"
    echo "  加密：$METHOD"
    echo "  密码：$PASS"
    echo "  传输：TCP + UDP" )
}
show_links() {   # show_links [协议]  不带参数 = 全部
  [[ -z $IP4$IP6 ]] && get_ip
  local p list=("$@") l
  [[ ${#list[@]} -eq 0 ]] && list=(reality hy2 tuic anytls argo ss snell)
  for p in "${list[@]}"; do
    has $p || continue
    echo; blue "========== $(pretty $p) =========="
    if [[ $p == argo ]]; then
      local d; d=$(argo_domain)
      if [[ -z $d ]]; then red "Argo 域名还没拿到，稍后运行 onekey 再查看"; continue; fi
      l=$(argo_link "$d"); echo "$l"
      [[ $NONINT != 1 ]] && command -v qrencode >/dev/null && qrencode -t ANSIUTF8 "$l"
      continue
    fi
    for h in $(link_hosts); do link_for $p "$h"; done
    if [[ $p == snell ]]; then yellow "（上面是 Surge 配置行，粘贴到 [Proxy] 段；Clash / 小火箭不支持 Snell v6）"
    elif [[ $NONINT != 1 ]] && command -v qrencode >/dev/null; then
      qrencode -t ANSIUTF8 "$(link_for $p "$(link_hosts | awk '{print $1}')")"
    fi
    case $p in hy2|tuic|anytls)
      case $CERT_MODE in
        self) yellow "提示：使用自签证书，客户端需开启「跳过证书验证 / allowInsecure」（主菜单「证书设置」可换成 IP / 域名证书）" ;;
        *)    echo "证书：$(cert_label)，客户端正常验证证书，不用开跳过验证" ;;
      esac ;;
    ss) ss_params ;;
    esac
  done
  gen_clients
  echo
  blue "---------- 导入客户端 ----------"
  echo "小火箭 Shadowrocket：扫上面每个节点的二维码，或复制链接后打开小火箭自动识别"
  if sub_on; then
    import_info
  elif [[ $NONINT != 1 && -f $CLASH ]]; then
    local a; read -r -p "Clash 只能通过「订阅链接」导入，现在开启订阅并显示 Clash 二维码？[Y/n]: " a
    if [[ $a != [nN] ]]; then sub_enable; else echo "以后可在主菜单 3 开启订阅"; fi
  else
    echo "Clash（Verge / Meta）导入：运行 onekey sub 开启订阅，获取订阅链接和二维码"
  fi
  echo
}

# ---------------- 客户端配置 / 订阅 ----------------
CLASH=$BASE/clash.yaml
SUB_ENV=$BASE/sub.env
WWW=$BASE/www
sub_on() { [[ -f $SUB_ENV ]]; }

clash_proxy() {   # clash_proxy 协议 主机 名称 -> 一行 YAML
  local p=$1 h=$2 n=$3
  ( HOP=""; . "$STATE/$p.env"
  local sni ins scv; read -r sni ins <<<"$(tls_opts "$h")"
  [[ $ins == 1 ]] && scv=true || scv=false
  case $p in
    reality) echo "  - {name: \"$n\", type: vless, server: \"$h\", port: $PORT, uuid: \"$UUID\", network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: \"$SNI\", client-fingerprint: chrome, reality-opts: {public-key: \"$PUB\", short-id: \"$SID\"}}" ;;
    hy2)     echo "  - {name: \"$n\", type: hysteria2, server: \"$h\", port: $PORT,${HOP:+ ports: \"$HOP\", hop-interval: 30,} password: \"$PASS\", sni: \"$sni\", skip-cert-verify: $scv, alpn: [h3]}" ;;
    tuic)    echo "  - {name: \"$n\", type: tuic, server: \"$h\", port: $PORT, uuid: \"$UUID\", password: \"$PASS\", sni: \"$sni\", skip-cert-verify: $scv, alpn: [h3], congestion-controller: bbr, udp-relay-mode: native}" ;;
    anytls)  echo "  - {name: \"$n\", type: anytls, server: \"$h\", port: $PORT, password: \"$PASS\", sni: \"$sni\", skip-cert-verify: $scv, client-fingerprint: chrome, udp: true}" ;;
    ss)      echo "  - {name: \"$n\", type: ss, server: \"$h\", port: $PORT, cipher: $METHOD, password: \"$PASS\", udp: true}" ;;
    argo)    echo "  - {name: \"$n\", type: vless, server: \"$h\", port: 443, uuid: \"$UUID\", udp: true, tls: true, servername: \"$h\", client-fingerprint: chrome, network: ws, ws-opts: {path: \"$WSPATH\", headers: {Host: \"$h\"}}}" ;;
  esac )
}

gen_clients() {   # 生成 links.txt / clash.yaml / 订阅文件
  [[ -z $IP4$IP6 ]] && get_ip
  local p h n d links="" proxies="" names=()
  for p in reality hy2 tuic anytls argo ss; do
    has $p || continue
    if [[ $p == argo ]]; then
      d=$(argo_domain); [[ -n $d ]] || continue
      n="$NAME_PREFIX-argo"; names+=("$n")
      proxies+="$(clash_proxy argo "$d" "$n")"$'\n'; links+="$(argo_link "$d")"$'\n'
      continue
    fi
    for h in $(link_hosts); do
      n="$NAME_PREFIX-$p$( [[ $h == *:* ]] && echo -v6)"; names+=("$n")
      proxies+="$(clash_proxy $p "$h" "$n")"$'\n'; links+="$(link_for $p "$h")"$'\n'
    done
  done
  # links.txt（含 Snell 的 Surge 行，给自己看 / 测试用）
  { printf '%s' "$links"; if has snell; then for h in $(link_hosts); do link_for snell "$h"; done; fi; } >"$LINKS"
  chmod 600 "$LINKS"
  if [[ ${#names[@]} -eq 0 ]]; then rm -f "$CLASH"; return; fi
  local list; list=$(printf '"%s", ' "${names[@]}"); list=${list%, }
  cat >"$CLASH" <<EOF
# OneKey 生成的 Clash Meta / mihomo 配置（Clash Verge Rev、Clash Meta for Android、Stash 可用）
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true
unified-delay: true
tcp-concurrent: true
geodata-mode: true
geox-url:
  geoip: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat"
  geosite: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"
  mmdb: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb"
dns:
  enable: true
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://223.5.5.5/dns-query
    - https://1.12.12.12/dns-query
proxies:
${proxies%$'\n'}
proxy-groups:
  - {name: "节点选择", type: select, proxies: ["自动选择", $list, DIRECT]}
  - {name: "自动选择", type: url-test, url: "https://www.gstatic.com/generate_204", interval: 300, tolerance: 50, proxies: [$list]}
rules:
  - GEOIP,LAN,DIRECT,no-resolve
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,节点选择
EOF
  chmod 600 "$CLASH"
  if sub_on; then
    ( . "$SUB_ENV"
      mkdir -p "$WWW/$TOKEN"; rm -f "$WWW/$TOKEN"/*
      cp "$CLASH" "$WWW/$TOKEN/clash.yaml"
      printf '%s' "$links" | base64 | tr -d '\n' >"$WWW/$TOKEN/sub"
      chmod -R go-rwx "$WWW" )
  fi
}

# 有正式证书（IP / 域名）时订阅走 HTTPS，地址只能用证书里有的 IP / 域名；否则 HTTP
sub_https() { ca_cert && command -v socat >/dev/null 2>&1; }
sub_hosts() {
  if ! sub_https; then link_hosts; return; fi
  if [[ $CERT_MODE == domain ]]; then echo "$CERT_DOMAIN"; return; fi
  local h out=""
  for h in $(link_hosts); do [[ " $CERT_NAMES " == *" $h "* ]] && out+="$h "; done
  echo "${out:-$CERT_NAMES}"
}
sub_service() {   # 按证书情况写订阅服务：HTTPS = socat 做 TLS + busybox httpd -i；HTTP = busybox httpd
  local httpd; httpd=$(httpd_cmd)
  ( . "$SUB_ENV"
    if sub_https; then
      local pf=""; [[ -f /proc/net/if_inet6 ]] && pf=",pf=ip6,ipv6only=0"
      svc_write onekey-sub "$(command -v socat) OPENSSL-LISTEN:$PORT,reuseaddr,fork,cert=$CERT_DIR/cert.pem,key=$CERT_DIR/key.pem,verify=0$pf 'EXEC:$httpd -i -h $WWW'"
    else
      svc_write onekey-sub "$httpd -f -p $PORT -h $WWW"
    fi )
  svc restart onekey-sub; sleep 1
  [[ $(svc status onekey-sub) == active ]]
}
sub_refresh() {   # 证书情况变了（新申请 / 升级脚本）时，按需在 HTTP / HTTPS 之间切换订阅服务
  sub_on || return 0
  local was=0 now=0
  grep -qs OPENSSL-LISTEN /etc/systemd/system/onekey-sub.service /etc/init.d/onekey-sub && was=1
  sub_https && now=1
  [[ $was == "$now" ]] && return 0
  sub_service >/dev/null 2>&1
  yellow "订阅已改成 $([[ $now == 1 ]] && echo HTTPS || echo HTTP)，新地址：$(sub_url sub)（客户端需重新导入订阅）"
}
sub_urls() {
  ( . "$SUB_ENV"
    local h hb s=http; sub_https && s=https
    for h in $(sub_hosts); do
      hb=$h; [[ $h == *:* ]] && hb="[$h]"
      echo "  小火箭 / v2rayN 订阅：$s://$hb:$PORT/$TOKEN/sub"
      echo "  Clash 订阅：        $s://$hb:$PORT/$TOKEN/clash.yaml"
    done )
}
sub_url() {   # sub_url sub|clash.yaml -> 第一个地址的订阅地址
  ( . "$SUB_ENV"
    local s=http; sub_https && s=https
    local h; h=$(sub_hosts | awk '{print $1}'); [[ $h == *:* ]] && h="[$h]"
    echo "$s://$h:$PORT/$TOKEN/$1" )
}
qr() { [[ $NONINT != 1 ]] && command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$1"; }
import_info() {   # 显示 Clash / 小火箭 的订阅导入方式（链接 + 二维码）
  sub_on || return
  local cu su; cu=$(sub_url clash.yaml); su=$(sub_url sub)
  echo
  blue "【Clash Verge / Clash Meta / mihomo】"
  echo "订阅地址：$cu"
  echo "一键导入（在装了 Clash 的手机或电脑上打开这个链接）："
  echo "  clash://install-config?url=$(uri "$cu")&name=$(uri "$NAME_PREFIX")"
  echo "手机扫码导入 / 复制订阅地址："
  qr "$cu"
  echo
  blue "【小火箭 Shadowrocket 订阅】"
  echo "订阅地址：$su"
  echo "小火箭首页右上角扫码，或 ＋ → 类型 Subscribe → 粘贴订阅地址："
  qr "sub://$(printf '%s' "$su" | base64 | tr -d '\n')#$(uri "$NAME_PREFIX")"
  if [[ $(sub_hosts | wc -w) -gt 1 ]]; then
    echo
    echo "（另一个 IP 的订阅地址）"; sub_urls | grep -vF "$(sub_url sub | cut -d/ -f3)/"
  fi
  if sub_https; then green "订阅走 HTTPS（$(cert_label)），传输过程中别人看不到内容"
  else yellow "订阅现在是明文 HTTP；在主菜单「证书设置」申请 IP / 域名证书后会自动改成 HTTPS"; fi
  yellow "订阅地址等于全部节点的密码，不要公开；泄露后在主菜单 3 更换订阅地址"
}

httpd_cmd() {   # 找到可用的 busybox httpd（Debian 在 busybox 里，Alpine 在 busybox-extras 里）
  if command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx httpd; then echo "$(command -v busybox) httpd"
  elif command -v busybox-extras >/dev/null 2>&1; then echo "$(command -v busybox-extras) httpd"; fi
}
sub_enable() {
  [[ -z $IP4$IP6 ]] && get_ip
  if ! sub_on; then
    local httpd; httpd=$(httpd_cmd)
    if [[ -z $httpd ]]; then
      case $PKG in apt) apt-get install -y -qq busybox >/dev/null ;; apk) apk add --no-cache busybox-extras >/dev/null ;; dnf|yum) $PKG install -y -q busybox >/dev/null ;; esac
      httpd=$(httpd_cmd)
    fi
    [[ -n $httpd ]] || { red "安装 busybox httpd 失败"; return 1; }
    local port; port=$(rand_port)
    printf "PORT='%s'\nTOKEN='%s'\n" "$port" "$(rand_hex 16)" >"$SUB_ENV"; chmod 600 "$SUB_ENV"
    mkdir -p "$WWW"
    open_port "$port" tcp
  fi
  gen_clients
  sub_service || { red "订阅服务启动失败"; return 1; }
  green "订阅已开启（地址里带随机密钥）"
  import_info
}
sub_reset() {
  sub_on || { yellow "订阅未开启"; return; }
  ( . "$SUB_ENV"; rm -rf "$WWW/$TOKEN"; printf "PORT='%s'\nTOKEN='%s'\n" "$PORT" "$(rand_hex 16)" >"$SUB_ENV" )
  gen_clients; green "已更换订阅地址，旧地址立即失效，请在客户端重新导入："; import_info
}
sub_disable() {
  sub_on || { yellow "订阅未开启"; return; }
  svc_remove onekey-sub; rm -rf "$WWW" "$SUB_ENV"; green "订阅已关闭"
  cert_release
}
sub_menu() {
  echo
  echo "订阅链接（小火箭 / Clash 一键导入）："
  echo "  1) 开启 / 查看订阅地址和二维码"
  echo "  2) 更换订阅地址（旧地址失效）"
  echo "  3) 关闭订阅"
  echo "  4) 显示 Clash 配置内容"
  echo "  0) 返回"
  local c; read -r -p "请选择 [0-4]: " c
  case $c in 1) sub_enable ;; 2) sub_reset ;; 3) sub_disable ;; 4) gen_clients; [[ -f $CLASH ]] && cat "$CLASH" || yellow "还没有可用节点" ;; esac
}

# ---------------- 删除 / 卸载 / 其它 ----------------
remove_proto() {
  local p=$1
  has $p || { yellow "$(pretty $p) 未安装"; return; }
  rm -f "$STATE/$p.env"
  case $p in
    snell) svc_remove onekey-snell; rm -f "$BASE/snell.conf" "$BIN_SNELL" ;;
    argo)  svc_remove onekey-argo; rm -f "$ARGO_LOG" "$BIN_CF" ;;
    hy2)   hop_apply; hop_service off ;;   # 端口跳跃规则跟着删
  esac
  [[ $p != snell ]] && apply_core_of "$p"
  gen_clients >/dev/null 2>&1
  green "$(pretty $p) 已删除（订阅和 Clash 配置已同步更新）"
  cert_release
}

uninstall_all() {
  if [[ $NONINT != 1 ]]; then
    local a; read -r -p "确定卸载全部协议和程序？[Y/n]: " a; [[ $a == [nN] ]] && return
  fi
  svc_remove onekey-xray; svc_remove onekey-sb; svc_remove onekey-snell; svc_remove onekey-argo; svc_remove onekey-sub
  [[ -f /etc/sysctl.d/99-onekey-tcp.conf ]] && tcp_restore
  [[ $CERT_MODE == ip || $CERT_MODE == domain ]] && acme_forget "$(cert_main)"   # acme.sh 本身保留（别的程序可能也在用）
  cert_cron_set off
  hop_service off; command -v nft >/dev/null 2>&1 && nft delete table inet onekey_hop >/dev/null 2>&1
  rm -rf "$BASE" "$BIN_XRAY" "$BIN_SB" "$BIN_SNELL" "$BIN_CF" "$CMD" /etc/sysctl.d/99-onekey-bbr.conf
  green "已全部卸载"
}

enable_bbr() {
  if [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]]; then green "BBR 已开启"; return; fi
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >/etc/sysctl.d/99-onekey-bbr.conf
  sysctl -p /etc/sysctl.d/99-onekey-bbr.conf >/dev/null 2>&1
  [[ $(sysctl -n net.ipv4.tcp_congestion_control) == bbr ]] && green "BBR 已开启" || red "BBR 开启失败（内核可能不支持）"
}

# ---------------- TCP 调优 ----------------
TCP_CONF=/etc/sysctl.d/99-onekey-tcp.conf
TCP_BAK=$BASE/sysctl-backup.conf
TCP_KEYS=(net.core.default_qdisc net.ipv4.tcp_congestion_control
  net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default
  net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min
  net.core.netdev_max_backlog net.core.somaxconn net.ipv4.tcp_max_syn_backlog
  net.ipv4.tcp_fastopen net.ipv4.tcp_mtu_probing net.ipv4.tcp_slow_start_after_idle
  net.ipv4.tcp_notsent_lowat net.ipv4.tcp_fin_timeout net.ipv4.tcp_tw_reuse
  net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
  net.ipv4.tcp_max_tw_buckets fs.file-max)

tcp_tune() {
  local mem buf
  mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  if   (( mem <= 600 ));  then buf=8388608     # ≤512M 机器：8 MB
  elif (( mem <= 1200 )); then buf=16777216    # 1G：16 MB
  elif (( mem <= 4200 )); then buf=33554432    # 2-4G：32 MB
  else buf=67108864; fi                        # 更大：64 MB
  # 第一次调优前备份原始值，恢复默认时用
  if [[ ! -f $TCP_BAK ]]; then
    local k v; : >"$TCP_BAK"
    for k in "${TCP_KEYS[@]}"; do v=$(sysctl -n "$k" 2>/dev/null) && echo "$k = $v" >>"$TCP_BAK"; done
  fi
  cat >"$TCP_CONF" <<EOF
# OneKey TCP 调优（内存 ${mem}MB，缓冲区上限 $((buf/1048576))MB）
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $buf
net.core.wmem_max = $buf
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 131072 $buf
net.ipv4.tcp_wmem = 4096 65536 $buf
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_tw_buckets = 65536
fs.file-max = 1048576
EOF
  rm -f /etc/sysctl.d/99-onekey-bbr.conf
  local out fail
  out=$(sysctl -p "$TCP_CONF" 2>&1 >/dev/null); fail=$(echo "$out" | grep -c . )
  [[ -z $out ]] && fail=0
  green "TCP 调优已应用（内存 ${mem}MB → 缓冲区上限 $((buf/1048576))MB，BBR + fq）"
  (( fail > 0 )) && { yellow "有 $fail 项当前内核不支持，已跳过："; echo "$out" | sed 's/^/  /'; }
  yellow "已写入 $TCP_CONF，重启后依然生效；节点无需重启"
}

tcp_show() {
  echo
  local k
  for k in net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max net.core.wmem_max \
           net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_fastopen net.ipv4.tcp_mtu_probing \
           net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_notsent_lowat net.core.somaxconn; do
    printf '  %-38s %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null)"
  done
  [[ -f $TCP_CONF ]] && green "  状态：已应用 OneKey 调优" || yellow "  状态：系统默认"
  echo
}

tcp_restore() {
  [[ -f $TCP_CONF ]] || { yellow "当前没有应用 OneKey 调优"; return; }
  rm -f "$TCP_CONF"
  if [[ -f $TCP_BAK ]]; then
    sysctl -p "$TCP_BAK" >/dev/null 2>&1; rm -f "$TCP_BAK"
    green "已恢复为调优前的系统参数"
  else
    yellow "没有找到备份，已删除调优配置，重启服务器后恢复系统默认"
  fi
}

tcp_menu() {
  echo
  echo "TCP 调优："
  echo "  1) 应用推荐调优（BBR + fq + 按内存调整缓冲区，对 Hysteria2/TUIC 的 UDP 也有帮助）"
  echo "  2) 查看当前参数"
  echo "  3) 恢复调优前的参数"
  echo "  0) 返回"
  local c; read -r -p "请选择 [0-3]: " c
  case $c in 1) tcp_tune ;; 2) tcp_show ;; 3) tcp_restore ;; esac
}

status() {
  echo
  local s
  for s in onekey-xray onekey-sb onekey-snell onekey-argo; do
    { [[ -f /etc/systemd/system/$s.service ]] || [[ -f /etc/init.d/$s ]]; } || continue
    if [[ $(svc status $s) == active ]]; then green "$s：运行中"; else red "$s：未运行"; fi
  done
  echo "已安装协议："
  local p; for p in reality hy2 tuic anytls argo ss snell; do has $p && echo "  - $(pretty $p)  端口 $( . "$STATE/$p.env"; echo "$PORT")"; done
  [[ -x $BIN_XRAY ]] && echo "Xray 版本：$(xray_cur)$(case ${XRAY_VER:-latest} in compat) echo "（兼容版，固定）";; latest) echo "（跟随最新版）";; *) echo "（固定版本）";; esac)"
  [[ -x $BIN_SB ]] && echo "sing-box 版本：$($BIN_SB version | head -1 | awk '{print $3}')"
  echo "拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo "IP 设置：节点地址 $(link_label)，出站 $(out_label)"
  if [[ -n $CERT_MODE ]]; then
    if [[ -s $CERT_DIR/cert.pem ]]; then echo "证书：$(cert_label)$( [[ $CERT_MODE != self ]] && echo "，到期 $(cert_expiry)")"
    else echo "证书：没有协议在用，已停止续签（再装 Hysteria2 / TUIC / AnyTLS 时自动申请）"; fi
  fi
  local hr; hr=$(hop_range); [[ -n $hr ]] && echo "Hysteria2 端口跳跃：UDP $hr"
  sub_on && echo "订阅：$(sub_https && echo HTTPS || echo HTTP)"
  cert_warn
  echo
}

restart_all() {
  ls "$STATE"/*.env >/dev/null 2>&1 || { yellow "还没有安装任何协议"; return; }
  [[ -f $XRAY_CONF ]] && svc restart onekey-xray
  [[ -f $SB_CONF ]] && svc restart onekey-sb
  has snell && svc restart onekey-snell
  has argo && { : >"$ARGO_LOG"; svc restart onekey-argo; }
  has argo && argo_domain >/dev/null
  gen_clients >/dev/null 2>&1
  green "已重启"; has argo && yellow "临时隧道重启后域名会变化，订阅已自动更新；单独导入的 Argo 链接需重新复制"
}

self_install() {
  [[ -x $CMD && $1 != force ]] && return
  if [[ -f $0 && $0 != /dev/fd/* && $0 != /proc/* ]]; then install -m 755 "$0" "$CMD"
  else curl -fsSL -o "$CMD" "$SCRIPT_URL" && chmod 755 "$CMD"; fi
  [[ -x $CMD ]] && green "快捷命令已安装：以后输入 onekey 即可打开菜单"
}

# ---------------- 菜单 ----------------
proto_menu() {
  echo
  echo "请选择协议："
  echo
  echo "  1) VLESS-REALITY"
  echo "  2) Hysteria2"
  echo "  3) TUIC"
  echo "  4) AnyTLS"
  echo "  5) VLESS-Argo"
  echo "  6) Shadowsocks"
  echo "  7) Snell v6"
  echo "  0) 返回"
  echo
  local c; read -r -p "请选择 [0-7]: " c
  case $c in
    1) add_reality ;; 2) add_hy2 ;; 3) add_tuic ;; 4) add_anytls ;;
    5) add_argo ;; 6) add_ss ;; 7) add_snell ;; *) return ;;
  esac
}
pick_proto() {   # 让用户从已安装的协议里选一个
  local arr=() p i=1
  for p in reality hy2 tuic anytls argo ss snell; do has $p && arr+=("$p"); done
  [[ ${#arr[@]} -eq 0 ]] && { yellow "还没有安装任何协议"; return 1; }
  for p in "${arr[@]}"; do echo "  $i) $(pretty $p)"; i=$((i+1)); done
  local c; read -r -p "请选择: " c
  [[ $c =~ ^[0-9]+$ ]] && (( c>=1 && c<=${#arr[@]} )) || return 1
  PICKED=${arr[$((c-1))]}
}
main_menu() {
  while :; do
    echo
    blue "=========== OneKey 多协议节点脚本 v$ONEKEY_VER ==========="
    cert_warn
    echo "  1) 安装 / 添加协议"
    echo "  2) 查看节点链接"
    echo "  3) 订阅链接（小火箭 / Clash）"
    echo "  4) IP 设置（IPv4 / IPv6）"
    echo "  5) 删除某个协议"
    echo "  6) 重启所有服务"
    echo "  7) 运行状态"
    echo "  8) 开启 BBR 加速"
    echo "  9) TCP 调优"
    echo " 10) 更新（脚本 / 内核）"
    echo " 11) 证书设置（域名 / IP / 自签）"
    echo " 12) Hysteria2 端口跳跃"
    echo " 13) 卸载全部"
    echo "  0) 退出"
    echo
    local c; read -r -p "请选择 [0-13]: " c
    case $c in
      1) proto_menu ;;
      2) show_links ;;
      3) sub_menu ;;
      4) ip_menu ;;
      5) pick_proto && remove_proto "$PICKED" ;;
      6) restart_all ;;
      7) status ;;
      8) enable_bbr ;;
      9) tcp_menu ;;
      10) update_menu ;;
      11) cert_menu ;;
      12) hop_menu ;;
      13) uninstall_all; exit 0 ;;
      0) exit 0 ;;
    esac
  done
}

# ---------------- 入口 ----------------
usage() {
  cat <<EOF
用法：onekey                 打开菜单
      onekey add <协议>      非交互安装（reality|hy2|tuic|anytls|argo|ss|snell）
                             可用环境变量：PORT_SET= SNI= METHOD= MODE= IP_MODE=4|6|both
                             XRAY_VER=compat|latest|v26.6.27（第一次装 Xray 的版本，默认 compat）
                             CERT=ip|domain|self DOMAIN=（证书，默认 ip）
                             HOP_RANGE=on|20000-29999（Hysteria2 端口跳跃）
      onekey links           查看全部链接
      onekey remove <协议>   删除协议
      onekey status          运行状态
      onekey bbr             开启 BBR
      onekey tcp [show|restore]  TCP 调优 / 查看 / 恢复
      onekey sub [on|reset|off]  订阅链接（小火箭 / Clash）开启·查看 / 换地址 / 关闭
      onekey clash           输出 Clash 配置
      onekey rebuild         按当前规则重新生成内核配置（升级脚本后用）
      onekey ip [both|4|6]   节点链接用 IPv4+IPv6 / 只用 IPv4 / 只用 IPv6
      onekey ip out <auto|prefer4|prefer6|only4|only6>  出站 IP 优先级
      onekey cert            查看证书（Hysteria2 / TUIC / AnyTLS 用）
      onekey cert ip         换成 IP 证书（Let's Encrypt，自动续签）
      onekey cert domain <域名>  换成域名证书
      onekey cert self       换成自签证书
      onekey cert renew      立即续签
      onekey hop [on|20000-29999|off]  Hysteria2 端口跳跃：开启（默认范围 / 指定范围）/ 关闭
      onekey update          更新脚本（节点不变）
      onekey update-core     更新内核（sing-box 最新版；Xray 按版本设置）
      onekey xray [compat|latest|v26.6.27]  查看 / 切换 Xray 版本（compat = REALITY 对所有内核客户端都能连的 $XRAY_COMPAT）
      onekey uninstall       卸载全部
EOF
}

detect_os
mkdir -p "$BASE" "$STATE"; chmod 700 "$BASE"
case $1 in
  "" ) install_deps; self_install; main_menu ;;
  add) NONINT=1; install_deps; self_install
       case $2 in reality|hy2|tuic|anytls|argo|ss|snell) "add_$2" ;; *) usage; exit 1 ;; esac ;;
  links) NONINT=1 show_links ;;
  remove) remove_proto "$2" ;;
  status) status ;;
  bbr) enable_bbr ;;
  tcp) case $2 in show) tcp_show ;; restore) tcp_restore ;; *) tcp_tune ;; esac ;;
  sub) case $2 in reset) sub_reset ;; off) sub_disable ;; *) sub_enable ;; esac ;;
  clash) gen_clients >/dev/null 2>&1; [[ -f $CLASH ]] && cat "$CLASH" ;;
  rebuild) rebuild ;;
  ip) case $2 in both|4|6) set_link_ip "$2" ;; out) set_out_ip "${3:-auto}" ;; *) get_ip; echo "节点地址：$(link_label)    出站：$(out_label)    （IPv4 ${IP4:-无}  IPv6 ${IP6:-无}）" ;; esac ;;
  cert) case $2 in
          ip|self) set_cert "$2" && cert_apply ;;
          domain)  set_cert domain "$3" && cert_apply ;;
          renew)   cert_renew ;;
          reload)  cert_reload ;;   # acme.sh 续签后调用
          cron)    cert_cron ;;     # 每天的兜底检查
          *) echo "证书：$(cert_label)$( [[ -s $CERT_DIR/cert.pem ]] && echo "    到期：$(cert_expiry)")"; cert_warn ;;
        esac ;;
  hop) case $2 in
         apply) hop_apply ;;   # onekey-hop 服务开机调用
         on|off|*-*) hop_set "$2" ;;
         *) r=$(hop_range); echo "Hysteria2 端口跳跃：${r:-未开启}" ;;
       esac ;;
  update) self_update "$2" ;;
  update-core) update_cores ;;
  xray) if [[ -n $2 ]]; then set_xray_ver "$2"
        else echo "Xray：$( [[ -x $BIN_XRAY ]] && xray_cur || echo 未安装)${XRAY_VER:+，$(xray_ver_label)}"; fi ;;
  migrate) migrate ;;
  uninstall) NONINT=1 uninstall_all ;;
  -v|--version) echo "$ONEKEY_VER" ;;
  *) usage ;;
esac
