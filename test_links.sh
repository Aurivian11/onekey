#!/usr/bin/env bash
# 用 onekey 生成的分享链接构造客户端，逐个测试连通性（在服务器上运行）
#  - VLESS-REALITY：服务端是 Xray，用 Xray 客户端测（新版 Xray 的 REALITY 与 sing-box 客户端不兼容）
#  - 其它协议：用 sing-box 客户端测（链接没写跳过证书验证时会真正校验证书）
# 用法：bash test_links.sh [链接文件，默认 /etc/onekey/links.txt]
set -o pipefail
FILE=${1:-/etc/onekey/links.txt}
[[ -s $FILE ]] || onekey links >/dev/null 2>&1
[[ -s $FILE ]] || { echo "没有链接文件"; exit 1; }
HAS_SB=0; command -v sing-box >/dev/null 2>&1 && HAS_SB=1
HAS_XRAY=0; command -v xray >/dev/null 2>&1 && HAS_XRAY=1

urldec() { local s=${1//+/ }; printf '%b' "${s//%/\\x}"; }
qp() { echo "$QUERY" | tr '&' '\n' | grep -m1 "^$1=" | cut -d= -f2- | { read -r v; urldec "$v"; }; }
insec() {   # 链接里写了跳过证书验证才跳过；否则正常校验证书
  [[ $(qp insecure) == 1 || $(qp allow_insecure) == 1 || $(qp allowInsecure) == 1 ]] && echo true || echo false
}
b64d() { local s=$1; s=${s//-/+}; s=${s//_/\/}; while (( ${#s} % 4 )); do s+="="; done; echo "$s" | base64 -d 2>/dev/null; }

parse() {   # 拆出 SCHEME USERINFO HOST PORT QUERY TAG
  local l=$1 rest hp
  SCHEME=${l%%://*}; rest=${l#*://}
  TAG=$(urldec "${rest##*#}"); rest=${rest%%#*}
  QUERY=""; [[ $rest == *\?* ]] && { QUERY=${rest#*\?}; rest=${rest%%\?*}; }
  USERINFO=${rest%@*}; hp=${rest##*@}
  if [[ $hp == \[* ]]; then HOST=${hp#[}; HOST=${HOST%%]*}; PORT=${hp##*]:}
  else HOST=${hp%:*}; PORT=${hp##*:}; fi
}

xray_outbound() {   # REALITY 链接 -> Xray outbound
  jq -nc --arg t "$TAG" --arg h "$HOST" --argjson p "$PORT" --arg u "$USERINFO" --arg flow "$(qp flow)" \
    --arg sni "$(qp sni)" --arg fp "$(qp fp)" --arg pbk "$(qp pbk)" --arg sid "$(qp sid)" \
    '{tag:$t,protocol:"vless",settings:{vnext:[{address:$h,port:$p,users:[{id:$u,flow:$flow,encryption:"none"}]}]},
      streamSettings:{network:"tcp",security:"reality",realitySettings:{serverName:$sni,fingerprint:$fp,publicKey:$pbk,shortId:$sid}}}'
}

sb_outbound() {   # 其它链接 -> sing-box outbound
  case $SCHEME in
    vless)
      if [[ $(qp security) == reality ]]; then
        jq -nc --arg t "$TAG" --arg h "$HOST" --argjson p "$PORT" --arg u "$USERINFO" --arg flow "$(qp flow)" \
          --arg sni "$(qp sni)" --arg fp "$(qp fp)" --arg pbk "$(qp pbk)" --arg sid "$(qp sid)" \
          '{type:"vless",tag:$t,server:$h,server_port:$p,uuid:$u,flow:$flow,
            tls:{enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:$fp},reality:{enabled:true,public_key:$pbk,short_id:$sid}}}'
      else
        jq -nc --arg t "$TAG" --arg h "$HOST" --argjson p "$PORT" --arg u "$USERINFO" --arg sni "$(qp sni)" \
          --arg host "$(qp host)" --arg path "$(qp path)" \
          '{type:"vless",tag:$t,server:$h,server_port:$p,uuid:$u,tls:{enabled:true,server_name:$sni},
            transport:{type:"ws",path:$path,headers:{Host:$host}}}'
      fi ;;
    hysteria2)
      jq -nc --arg t "$TAG" --arg h "$HOST" --argjson p "$PORT" --arg pw "$(urldec "$USERINFO")" --arg sni "$(qp sni)" --argjson ins "$(insec)" \
        '{type:"hysteria2",tag:$t,server:$h,server_port:$p,password:$pw,tls:{enabled:true,server_name:$sni,insecure:$ins,alpn:["h3"]}}' ;;
    tuic)
      jq -nc --arg t "$TAG" --arg h "$HOST" --argjson p "$PORT" --arg u "${USERINFO%%:*}" --arg pw "$(urldec "${USERINFO#*:}")" \
        --arg sni "$(qp sni)" --arg cc "$(qp congestion_control)" --argjson ins "$(insec)" \
        '{type:"tuic",tag:$t,server:$h,server_port:$p,uuid:$u,password:$pw,congestion_control:$cc,tls:{enabled:true,server_name:$sni,insecure:$ins,alpn:["h3"]}}' ;;
    anytls)
      jq -nc --arg t "$TAG" --arg h "$HOST" --argjson p "$PORT" --arg pw "$(urldec "$USERINFO")" --arg sni "$(qp sni)" --argjson ins "$(insec)" \
        '{type:"anytls",tag:$t,server:$h,server_port:$p,password:$pw,tls:{enabled:true,server_name:$sni,insecure:$ins}}' ;;
    ss)
      local mp; mp=$(b64d "$USERINFO")
      jq -nc --arg t "$TAG" --arg h "$HOST" --argjson p "$PORT" --arg m "${mp%%:*}" --arg pw "${mp#*:}" \
        '{type:"shadowsocks",tag:$t,server:$h,server_port:$p,method:$m,password:$pw}' ;;
  esac
}

SB_OUT=(); SB_IN=(); SB_RULE=(); X_OUT=(); X_IN=(); X_RULE=(); NAMES=(); i=0
while IFS= read -r l; do
  [[ $l == *://* ]] || continue
  parse "$l"; port=$((11000 + i)); name=$TAG
  if [[ $SCHEME == vless && $(qp security) == reality && $HAS_XRAY == 1 ]]; then
    X_OUT+=("$(xray_outbound)")
    X_IN+=("$(jq -nc --arg t "in$i" --argjson p $port '{tag:$t,listen:"127.0.0.1",port:$p,protocol:"socks",settings:{udp:true}}')")
    X_RULE+=("$(jq -nc --arg i "in$i" --arg o "$name" '{type:"field",inboundTag:[$i],outboundTag:$o}')")
    NAMES+=("$name:$port:xray")
  elif [[ $HAS_SB == 1 ]]; then
    o=$(sb_outbound); [[ -n $o ]] || continue
    SB_OUT+=("$o")
    SB_IN+=("$(jq -nc --arg t "in$i" --argjson p $port '{type:"mixed",tag:$t,listen:"127.0.0.1",listen_port:$p}')")
    SB_RULE+=("$(jq -nc --arg i "in$i" --arg o "$name" '{inbound:[$i],outbound:$o}')")
    NAMES+=("$name:$port:sing-box")
  else
    NAMES+=("$name:0:none")
  fi
  i=$((i+1))
done <"$FILE"

TD=$(mktemp -d); chmod 700 "$TD"; PIDS=()
arr() { if [[ $# -eq 0 ]]; then echo '[]'; else printf '%s\n' "$@" | jq -s .; fi; }
if [[ ${#SB_OUT[@]} -gt 0 ]]; then
  jq -n --argjson o "$(arr "${SB_OUT[@]}")" --argjson i "$(arr "${SB_IN[@]}")" --argjson r "$(arr "${SB_RULE[@]}")" \
    '{log:{level:"error"},inbounds:$i,outbounds:($o+[{type:"direct",tag:"direct"}]),route:{rules:$r,final:"direct"}}' >"$TD/sb.json"
  sing-box check -c "$TD/sb.json" || { echo "sing-box 客户端配置无效"; rm -rf "$TD"; exit 1; }
  sing-box run -c "$TD/sb.json" >"$TD/sb.log" 2>&1 & PIDS+=($!)
fi
if [[ ${#X_OUT[@]} -gt 0 ]]; then
  jq -n --argjson o "$(arr "${X_OUT[@]}")" --argjson i "$(arr "${X_IN[@]}")" --argjson r "$(arr "${X_RULE[@]}")" \
    '{log:{loglevel:"error"},inbounds:$i,outbounds:($o+[{protocol:"freedom",tag:"direct"}]),routing:{rules:$r}}' >"$TD/xray.json"
  xray run -test -c "$TD/xray.json" >/dev/null 2>&1 || { echo "Xray 客户端配置无效"; rm -rf "$TD"; exit 1; }
  xray run -c "$TD/xray.json" >"$TD/xray.log" 2>&1 & PIDS+=($!)
fi
sleep 3
pass=0; fail=0; skip=0
for n in "${NAMES[@]}"; do
  name=${n%%:*}; rest=${n#*:}; port=${rest%%:*}; client=${rest#*:}
  if [[ $client == none ]]; then skip=$((skip+1)); printf '  ⏭  %-22s 跳过（服务器上没有可用的测试客户端）\n' "$name"; continue; fi
  res=$(curl -s --max-time 15 -x "socks5h://127.0.0.1:$port" -o /dev/null -w "%{http_code} %{time_total}" https://www.google.com/generate_204)
  ip=$(curl -s --max-time 15 -x "socks5h://127.0.0.1:$port" https://api64.ipify.org)
  if [[ ${res%% *} == 204 ]]; then
    pass=$((pass+1)); printf '  ✅ %-22s 204  %5.0f ms  客户端 %-8s 出口 %s\n' "$name" "$(awk -v t="${res##* }" 'BEGIN{print t*1000}')" "$client" "$ip"
  else fail=$((fail+1)); printf '  ❌ %-22s 失败 (%s)  客户端 %s\n' "$name" "$res" "$client"; fi
done
kill "${PIDS[@]}" 2>/dev/null
echo "通过 $pass / $((pass+fail))$( ((skip)) && echo "，跳过 $skip")"
if (( fail > 0 )); then tail -3 "$TD"/*.log 2>/dev/null; fi
rm -rf "$TD"
