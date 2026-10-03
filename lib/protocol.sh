#!/usr/bin/env bash
# No side effects when sourced. Secrets are passed through stdin, not child argv.
_protocol_error() { printf '协议错误：%s\n' "$*" >&2; return 1; }

protocol_validate_node() {
    [[ $# == 1 ]] || { _protocol_error '需要一个节点 JSON'; return 1; }
    printf '%s' "$1" | "${XM_PYTHON:-python3}" -c '
import base64, ipaddress, json, re, subprocess, sys, unicodedata, uuid
def need(ok, message):
    if not ok: raise ValueError(message)
def text(n, key, lo=1, hi=1024):
    v=n.get(key)
    need(isinstance(v,str) and lo<=len(v)<=hi and not any(unicodedata.category(c) in ("Cc","Cs") for c in v), key+" 格式无效")
    return v
def host(v):
    need(isinstance(v,str) and 1<=len(v)<=253, "地址无效")
    need("%" not in v,"不支持带 scope ID 的地址")
    try: ipaddress.ip_address(v); return
    except ValueError: pass
    need(bool(re.fullmatch(r"(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?",v)), "地址必须是裸 IP 或 ASCII 域名")
def key32(v):
    need(bool(re.fullmatch(r"[A-Za-z0-9_-]{43}",v)), "REALITY 密钥格式无效")
    b=base64.urlsafe_b64decode(v+"=")
    need(len(b)==32 and base64.urlsafe_b64encode(b).decode().rstrip("=")==v, "REALITY 密钥编码无效")
    return b
def openssl(args,data=None):
    r=subprocess.run(["openssl"]+args,input=data,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
    need(r.returncode==0,"X25519 密钥检查失败")
    return r.stdout
try:
    n=json.load(sys.stdin); need(isinstance(n,dict),"节点必须是对象")
    t=text(n,"type"); common={"id","name","type","port","address"}
    extras={"vless-reality":{"uuid","private_key","public_key","short_id","sni","target"},"vless-xhttp":{"uuid","private_key","public_key","short_id","sni","target","path","mode"},"shadowsocks":{"method","password"}}
    need(t in extras,"未知协议")
    need(set(n)==common|extras[t],"节点字段缺失或含未知字段")
    need(bool(re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,31}",text(n,"id"))),"节点 ID 无效")
    text(n,"name",1,128)
    p=n.get("port"); need(type(p)==int and 1<=p<=65535,"端口必须是 1..65535 整数")
    host(text(n,"address"))
    if t in ("vless-reality","vless-xhttp"):
        u=text(n,"uuid"); need(str(uuid.UUID(u))==u.lower(),"UUID 格式无效")
        priv=key32(text(n,"private_key")); pub=key32(text(n,"public_key"))
        der=bytes.fromhex("302e020100300506032b656e04220420")+priv
        derived=openssl(["pkey","-inform","DER","-pubout","-outform","DER"],der)[-32:]
        need(derived==pub and any(pub),"REALITY 公私钥不匹配")
        need(bool(re.fullmatch(r"(?:[0-9a-fA-F]{2}){1,8}",text(n,"short_id"))),"shortId 必须为 2..16 位偶数十六进制")
        host(text(n,"sni")); need(":" not in n["sni"],"SNI 必须为域名或 IPv4")
        m=re.fullmatch(r"(\[[0-9a-fA-F:]+\]|[^:]+):([0-9]{1,5})",text(n,"target"))
        need(m is not None,"REALITY target 必须为 host:port（IPv6 用方括号）")
        host(m.group(1).strip("[]")); need(1<=int(m.group(2))<=65535,"target 端口无效")
        if t=="vless-xhttp":
            path=text(n,"path",2,128)
            need(bool(re.fullmatch(r"/[A-Za-z0-9/_-]+",path)) and "//" not in path,"XHTTP path 必须以 / 开头，长度 2..128，仅含 ASCII 字母、数字、/、_、-，禁止连续斜线")
            need(text(n,"mode") in ("auto","packet-up","stream-up","stream-one"),"XHTTP mode 必须为 auto、packet-up、stream-up 或 stream-one")
    elif t=="shadowsocks":
        need(text(n,"method")=="2022-blake3-aes-128-gcm","仅支持 SS2022 AES-128-GCM")
        pwd=text(n,"password"); raw=base64.b64decode(pwd,validate=True)
        need(len(raw)==16 and base64.b64encode(raw).decode()==pwd,"SS2022 密码必须是 16 字节标准 Base64 密钥")
except (ValueError,TypeError,KeyError,OSError) as e:
    print("协议错误："+str(e),file=sys.stderr); sys.exit(1)
'
}

protocol_new() {
    [[ $# -ge 5 ]] || { _protocol_error '参数不足'; return 1; }
    local type=$1 id=$2 name=$3 port=$4 address=$5 node extra core keys private public uid short
    shift 5
    [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || { _protocol_error '端口无效'; return 1; }
    case "$type" in
        vless-reality|vless-xhttp)
            local required=2
            [[ $type != vless-xhttp ]] || required=4
            [[ $# == "$required" || $# == $((required+4)) ]] || { _protocol_error 'VLESS 需要 SNI TARGET，XHTTP 还需 PATH MODE；可附 UUID PRIVATE PUBLIC SHORTID'; return 1; }
            if [[ $# == $((required+4)) ]]; then
                local offset=$((required+1)); uid=${!offset}; offset=$((offset+1)); private=${!offset}; offset=$((offset+1)); public=${!offset}; offset=$((offset+1)); short=${!offset}
            else
                core=${XRAY_BIN:-${XM_BIN:-/opt/xray-manager/bin/xray}}
                [[ -x $core ]] || { _protocol_error '需要已安装的 Xray 生成 REALITY 密钥'; return 1; }
                keys=$("$core" x25519 2>/dev/null) || return 1
                private=$(printf '%s\n' "$keys" | sed -n 's/^PrivateKey: //p')
                public=$(printf '%s\n' "$keys" | sed -n 's/^Password (PublicKey): //p; s/^PublicKey: //p')
                uid=$("${XM_PYTHON:-python3}" -c 'import uuid; print(uuid.uuid4())') || return 1
                short=$(openssl rand -hex 8) || return 1
            fi
            extra=$(printf '%s\0' "$uid" "$private" "$public" "$short" "$1" "$2" | jq -Rs 'split("\u0000")|{uuid:.[0],private_key:.[1],public_key:.[2],short_id:.[3],sni:.[4],target:.[5]}') || return 1
            if [[ $type == vless-xhttp ]]; then
                extra=$(printf '%s\0' "$extra" "$3" "$4" | jq -Rs 'split("\u0000")|(.[0]|fromjson)+{path:.[1],mode:.[2]}') || return 1
            fi
            ;;
        shadowsocks)
            [[ $# -le 1 ]] || { _protocol_error 'Shadowsocks 参数过多'; return 1; }
            private=${1:-}; [[ -n $private ]] || private=$(openssl rand -base64 16) || return 1
            extra=$(printf '%s\0' "$private" | jq -Rs 'split("\u0000")|{method:"2022-blake3-aes-128-gcm",password:.[0]}') || return 1
            ;;
        *) _protocol_error '未知协议'; return 1 ;;
    esac
    node=$(printf '%s\0' "$id" "$name" "$type" "$port" "$address" "$extra" | jq -Rsc 'split("\u0000")|{id:.[0],name:.[1],type:.[2],port:(.[3]|tonumber),address:.[4]}+(.[5]|fromjson)') || return 1
    protocol_validate_node "$node" || return 1
    printf '%s\n' "$node"
}

protocol_generate() {
    [[ $# == 2 && -f $1 && ! -L $1 && ! -L $2 ]] || { _protocol_error '状态或输出路径无效'; return 1; }
    local state=$1 output=$2 node listen
    listen=$("${XM_PYTHON:-python3}" -c '
import errno,socket
try:
    with socket.socket(socket.AF_INET6,socket.SOCK_STREAM) as s:s.bind(("::",0))
    print("::")
except OSError as e:
    # A sandbox denying all sockets cannot establish stack availability. The
    # native Xray/service check is authoritative in that restricted environment.
    print("0.0.0.0" if e.errno in (errno.EAFNOSUPPORT,errno.EPROTONOSUPPORT,errno.EADDRNOTAVAIL,errno.ENODEV) else "::")
') || return 1
    # Linux can explicitly disable the IPv6 stack. Preserve IPv4 operation in
    # that case without changing any host sysctl or network configuration.
    if [[ -d /proc/sys/net && ! -e /proc/net/if_inet6 ]] || [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 && $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) == 1 ]]; then
        listen=0.0.0.0
    fi
    jq -e 'type=="object" and .schema_version==1 and (.nodes|type=="array") and (.nodes|length<=128) and (.nodes|map(.id)|length== (unique|length)) and (.nodes|map(.port)|length==(unique|length))' "$state" >/dev/null || { _protocol_error '状态 schema 或重复 ID/端口无效'; return 1; }
    while IFS= read -r node; do protocol_validate_node "$node" || return 1; done < <(jq -c '.nodes[]' "$state")
    if [[ $listen == 0.0.0.0 ]] && jq -e '.nodes|any(.address|contains(":"))' "$state" >/dev/null; then
        _protocol_error '当前服务器 IPv6 不可用，请使用 IPv4 地址或域名'; return 1
    fi
    (umask 077; : > "$output"; chmod 600 "$output" || exit 1; jq --arg listen "$listen" '
        {log:{loglevel:"warning",access:"none"},inbounds:[.nodes[]|
          {tag:("node-"+.id),listen:$listen,port:.port}+
          (if .type=="vless-reality" then
            {protocol:"vless",settings:{clients:[{id:.uuid,flow:"xtls-rprx-vision"}],decryption:"none"},streamSettings:{network:"raw",security:"reality",realitySettings:{show:false,target:.target,xver:0,serverNames:[.sni],privateKey:.private_key,shortIds:[.short_id]}}}
          elif .type=="vless-xhttp" then
            {protocol:"vless",settings:{clients:[{id:.uuid}],decryption:"none"},streamSettings:{network:"xhttp",security:"reality",xhttpSettings:{path:.path,mode:.mode},realitySettings:{show:false,target:.target,xver:0,serverNames:[.sni],privateKey:.private_key,shortIds:[.short_id]}}}
          else {protocol:"shadowsocks",settings:{method:.method,password:.password,network:"tcp,udp"}}
          end)],outbounds:[{tag:"direct",protocol:"freedom",settings:{}},{tag:"block",protocol:"blackhole",settings:{}}],routing:{domainStrategy:"IPOnDemand",rules:[{type:"field",ip:["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","198.18.0.0/15","224.0.0.0/4","240.0.0.0/4","::/128","::1/128","64:ff9b:1::/48","100::/64","fc00::/7","fe80::/10","ff00::/8"],outboundTag:"block"}]}}
    ' "$state" > "$output") || return 1
    chmod 600 "$output"
}

protocol_share() {
    [[ $# == 1 ]] || { _protocol_error '需要一个节点 JSON'; return 1; }
    protocol_validate_node "$1" || return 1
    printf '%s' "$1" | "${XM_PYTHON:-python3}" -c '
import json,sys,urllib.parse
n=json.load(sys.stdin); q=lambda s:urllib.parse.quote(s,safe="")
host="["+n["address"]+"]" if ":" in n["address"] else n["address"]
tail="@"+host+":"+str(n["port"])
if n["type"]=="vless-reality":
    opts={"encryption":"none","flow":"xtls-rprx-vision","security":"reality","sni":n["sni"],"fp":"chrome","pbk":n["public_key"],"sid":n["short_id"],"type":"tcp"}
    uri="vless://"+q(n["uuid"])+tail+"?"+urllib.parse.urlencode(opts,quote_via=urllib.parse.quote)
elif n["type"]=="vless-xhttp":
    opts={"encryption":"none","security":"reality","sni":n["sni"],"fp":"chrome","pbk":n["public_key"],"sid":n["short_id"],"type":"xhttp","path":n["path"],"mode":n["mode"]}
    uri="vless://"+q(n["uuid"])+tail+"?"+urllib.parse.urlencode(opts,quote_via=urllib.parse.quote)
else:
    # SIP002 requires percent encoded plaintext userinfo for AEAD-2022.
    uri="ss://"+q(n["method"])+":"+q(n["password"])+tail
print(uri+"#"+q(n["name"]))
'
}
