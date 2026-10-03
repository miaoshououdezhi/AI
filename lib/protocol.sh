#!/usr/bin/env bash
# No side effects when sourced. Secrets are passed through stdin, not child argv.
_protocol_error() {
    if declare -F xm_error >/dev/null; then xm_error "协议：$*"
    else printf '[错误] 协议：%s\n' "$*" >&2; fi
    return 1
}

protocol_validate_node() {
    [[ $# == 1 || $# == 2 ]] || { _protocol_error '需要节点 JSON [strict|maintenance]'; return 1; }
    local mode=${2:-strict}
    [[ $mode == strict || $mode == maintenance ]] || { _protocol_error '校验模式无效'; return 1; }
    printf '%s' "$1" | "${XM_PYTHON:-python3}" -c '

import base64, datetime, ipaddress, json, re, subprocess, sys, unicodedata, uuid
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
    need(r.returncode==0,"密钥或证书校验失败")
    return r.stdout
try:
    n=json.load(sys.stdin); need(isinstance(n,dict),"节点必须是对象")
    t=text(n,"type"); common={"id","name","type","port","address"}
    extras={"vless-reality":{"uuid","private_key","public_key","short_id","sni","target"},"vless-xhttp":{"uuid","private_key","public_key","short_id","sni","target","path","mode"},"shadowsocks":{"method","password"},"vless-ws":{"uuid","sni","path","tls_cert","tls_key"},"socks5":{"username","password"},"anytls":{"sni","tls_cert","tls_key","password"},"hysteria2":{"sni","tls_cert","tls_key","password"},"tuicv5":{"sni","tls_cert","tls_key","uuid","password"}}
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
    elif t=="socks5":
        need(bool(re.fullmatch(r"[A-Za-z0-9_-]{3,64}",text(n,"username"))),"SOCKS 用户名需为 3..64 位 ASCII 字母数字、_ 或 -")
        need(len(text(n,"password",16,128).encode())<=255,"SOCKS 密码 UTF-8 编码最多 255 字节")
    elif t in ("vless-ws","anytls","hysteria2","tuicv5"):
        sni=text(n,"sni"); host(sni)
        if t in ("vless-ws","tuicv5"):
            u=text(n,"uuid"); need(str(uuid.UUID(u))==u.lower(),"UUID 格式无效")
        if t=="vless-ws":
            path=text(n,"path",2,128)
            need(bool(re.fullmatch(r"/[A-Za-z0-9/_-]+",path)) and "//" not in path,"WS path 格式无效")
        else: text(n,"password",16,256)
        cert=n.get("tls_cert"); key=n.get("tls_key")
        need(isinstance(cert,str) and 1<=len(cert.encode())<=262144 and isinstance(key,str) and 1<=len(key.encode())<=16384,"TLS PEM 内容或大小无效")
        need(cert.count("-----BEGIN CERTIFICATE-----")>=1 and cert.count("-----BEGIN CERTIFICATE-----")==cert.count("-----END CERTIFICATE-----"),"证书 PEM 格式无效")
        need(bool(re.fullmatch(r"-----BEGIN (?:RSA |EC )?PRIVATE KEY-----\s+[A-Za-z0-9+/=\r\n]+-----END (?:RSA |EC )?PRIVATE KEY-----\s*",key)),"只支持未加密 PEM 私钥")
        certbytes=cert.encode(); keybytes=key.encode()
        if sys.argv[1]=="strict":
            openssl(["x509","-noout","-checkend","0"],certbytes)
            start=openssl(["x509","-noout","-startdate"],certbytes).decode().strip().split("=",1)[1]
            need(datetime.datetime.strptime(start,"%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc)<=datetime.datetime.now(datetime.timezone.utc),"证书尚未生效")
        san=openssl(["x509","-noout","-ext","subjectAltName"],certbytes)
        need(b"DNS:" in san or b"IP Address:" in san,"证书必须包含 SAN")
        try: ipaddress.ip_address(sni); flag="-checkip"
        except ValueError: flag="-checkhost"
        need(b"does match certificate" in openssl(["x509","-noout",flag,sni],certbytes),"证书 SAN 与 SNI 不匹配")
        need(openssl(["x509","-pubkey","-noout"],certbytes)==openssl(["pkey","-passin","pass:","-pubout"],keybytes),"证书与私钥不匹配")
    elif t=="shadowsocks":
        need(text(n,"method")=="2022-blake3-aes-128-gcm","仅支持 SS2022 AES-128-GCM")
        pwd=text(n,"password"); raw=base64.b64decode(pwd,validate=True)
        need(len(raw)==16 and base64.b64encode(raw).decode()==pwd,"SS2022 密码必须是 16 字节标准 Base64 密钥")
except (ValueError,TypeError,KeyError,OSError) as e:
    print("[错误] 协议："+str(e),file=sys.stderr); sys.exit(1)
' "$mode"
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
        vless-ws|anytls|hysteria2|tuicv5)
            local tls path required=3
            [[ $type != vless-ws ]] || required=4
            if [[ $type == tuicv5 ]]; then
                [[ $# == 3 || $# == 5 ]] || { _protocol_error 'TUIC 需要 SNI CERT KEY [UUID PASSWORD]'; return 1; }
            else
                [[ $# == "$required" || $# == $((required+1)) ]] || { _protocol_error 'TLS 节点参数不足或过多'; return 1; }
            fi
            if [[ $type == vless-ws ]]; then tls=$(protocol_tls_read "$3" "$4" "$1") || return 1; path=$2; uid=${5:-}
            else tls=$(protocol_tls_read "$2" "$3" "$1") || return 1; uid=${4:-}; fi
            if [[ $type == vless-ws || $type == tuicv5 ]]; then
                [[ -n $uid ]] || uid=$("${XM_PYTHON:-python3}" -c 'import uuid; print(uuid.uuid4())') || return 1
            fi
            if [[ $type == vless-ws ]]; then
                extra=$(printf '%s\0' "$tls" "$uid" "$path" | jq -Rs 'split("\u0000")|(.[0]|fromjson)+{uuid:.[1],path:.[2]}') || return 1
            else
                if [[ $type == tuicv5 ]]; then private=${5:-}; else private=${4:-}; fi
                [[ -n $private ]] || private=$(openssl rand -hex 24) || return 1
                extra=$(printf '%s\0' "$tls" "$private" | jq -Rs 'split("\u0000")|(.[0]|fromjson)+{password:.[1]}') || return 1
                if [[ $type == tuicv5 ]]; then extra=$(printf '%s\0' "$extra" "$uid" | jq -Rs 'split("\u0000")|(.[0]|fromjson)+{uuid:.[1]}') || return 1; fi
            fi
            ;;
        socks5)
            [[ $# == 0 || $# == 2 ]] || { _protocol_error 'SOCKS 需要 [USERNAME PASSWORD]'; return 1; }
            uid=${1:-}; private=${2:-}
            [[ -n $uid ]] || uid="u$(openssl rand -hex 6)" || return 1
            [[ -n $private ]] || private=$(openssl rand -hex 24) || return 1
            extra=$(printf '%s\0' "$uid" "$private" | jq -Rs 'split("\u0000")|{username:.[0],password:.[1]}') || return 1
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
        {log:{loglevel:"warning",access:"none"},inbounds:[.nodes[]|select(.type=="vless-reality" or .type=="vless-xhttp" or .type=="shadowsocks" or .type=="vless-ws" or .type=="socks5")|
          {tag:("node-"+.id),listen:$listen,port:.port}+
          (if .type=="vless-reality" then
            {protocol:"vless",settings:{clients:[{id:.uuid,flow:"xtls-rprx-vision"}],decryption:"none"},streamSettings:{network:"raw",security:"reality",realitySettings:{show:false,target:.target,xver:0,serverNames:[.sni],privateKey:.private_key,shortIds:[.short_id]}}}
          elif .type=="vless-xhttp" then
            {protocol:"vless",settings:{clients:[{id:.uuid}],decryption:"none"},streamSettings:{network:"xhttp",security:"reality",xhttpSettings:{path:.path,mode:.mode},realitySettings:{show:false,target:.target,xver:0,serverNames:[.sni],privateKey:.private_key,shortIds:[.short_id]}}}
          elif .type=="vless-ws" then
            {protocol:"vless",settings:{clients:[{id:.uuid}],decryption:"none"},streamSettings:{network:"ws",security:"tls",wsSettings:{path:.path},tlsSettings:{minVersion:"1.2",certificates:[{certificate:(.tls_cert|split("\n")),key:(.tls_key|split("\n"))}]}}}
          elif .type=="socks5" then
            {protocol:"socks",settings:{auth:"password",accounts:[{user:.username,pass:.password}],udp:true}}
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
elif n["type"]=="vless-ws":
    uri="vless://"+q(n["uuid"])+tail+"?"+urllib.parse.urlencode({"encryption":"none","security":"tls","sni":n["sni"],"type":"ws","path":n["path"]},quote_via=urllib.parse.quote)
elif n["type"]=="socks5":
    uri="socks5://"+q(n["username"])+":"+q(n["password"])+tail
elif n["type"] in ("anytls","hysteria2","tuicv5"):
    scheme={"anytls":"anytls","hysteria2":"hysteria2","tuicv5":"tuic"}[n["type"]]
    user=q(n["password"]) if n["type"]!="tuicv5" else q(n["uuid"])+":"+q(n["password"])
    opts={"sni":n["sni"]}
    if n["type"]=="tuicv5": opts.update(congestion_control="cubic",alpn="h3")
    uri=scheme+"://"+user+tail+"?"+urllib.parse.urlencode(opts,quote_via=urllib.parse.quote)
else:
    # SIP002 requires percent encoded plaintext userinfo for AEAD-2022.
    uri="ss://"+q(n["method"])+":"+q(n["password"])+tail
print(uri+"#"+q(n["name"]))
'
}


protocol_engine() {
    case ${1:-} in
        vless-reality|vless-xhttp|vless-ws|shadowsocks|socks5) printf 'xray\n' ;;
        anytls|hysteria2|tuicv5) printf 'extra\n' ;;
        *) _protocol_error '未知协议'; return 1 ;;
    esac
}

protocol_has_extra() {
    [[ $# == 1 && -f $1 && ! -L $1 ]] || return 1
    jq -e '.nodes|any(.type=="anytls" or .type=="hysteria2" or .type=="tuicv5")' "$1" >/dev/null
}

protocol_tls_read() {
    [[ $# == 3 ]] || { _protocol_error 'TLS 需要 CERT KEY SNI'; return 1; }
    local tls probe
    tls=$(printf '%s\0' "$1" "$2" "$3" | "${XM_PYTHON:-python3}" -c '
import json,os,stat,sys
try:
    cert,key,sni,_=sys.stdin.read().split("\0")
    values=[]
    for path,limit,secret in ((cert,262144,False),(key,16384,True)):
        if not os.path.isabs(path): raise ValueError("证书与私钥需要绝对路径")
        fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
        with os.fdopen(fd,"rb") as f:
            st=os.fstat(f.fileno())
            if not stat.S_ISREG(st.st_mode) or st.st_size>limit or st.st_mode&0o022 or (secret and st.st_mode&0o007): raise ValueError("TLS 文件类型/体积/权限无效")
            raw=f.read(limit+1)
            if len(raw)>limit: raise ValueError("TLS 文件过大")
            values.append(raw.decode("ascii"))
    print(json.dumps({"sni":sni,"tls_cert":values[0],"tls_key":values[1]}))
except (OSError,ValueError,UnicodeError) as e:
    print("[错误] 协议："+str(e),file=sys.stderr);sys.exit(1)
') || return 1
    probe=$(printf '%s' "$tls" | jq -c '.+{id:"tlsprobe",name:"TLS probe",type:"anytls",port:443,address:.sni,password:"fixture-validation-password"}') || return 1
    protocol_validate_node "$probe" || return 1
    printf '%s\n' "$tls"
}

protocol_generate_extra() {
    [[ $# == 2 && -f $1 && ! -L $1 && ! -L $2 ]] || { _protocol_error '状态或输出路径无效'; return 1; }
    local node listen
    listen=$("${XM_PYTHON:-python3}" -c '
import errno,socket
try:
    with socket.socket(socket.AF_INET6,socket.SOCK_STREAM) as s:s.bind(("::",0))
    print("::")
except OSError as e:
    print("0.0.0.0" if e.errno in (errno.EAFNOSUPPORT,errno.EPROTONOSUPPORT,errno.EADDRNOTAVAIL,errno.ENODEV) else "::")
') || return 1
    if [[ -d /proc/sys/net && ! -e /proc/net/if_inet6 ]] || [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 && $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) == 1 ]]; then listen=0.0.0.0; fi
    if [[ $listen == 0.0.0.0 ]] && jq -e '.nodes|any(.address|contains(":"))' "$1" >/dev/null; then _protocol_error '当前服务器 IPv6 不可用'; return 1; fi
    jq -e '.schema_version==1 and (.nodes|type=="array") and (.nodes|length<=128) and (.nodes|map(.id)|length==(unique|length)) and (.nodes|map(.port)|length==(unique|length))' "$1" >/dev/null || return 1
    while IFS= read -r node; do protocol_validate_node "$node" || return 1; done < <(jq -c '.nodes[]' "$1")
    (umask 077; : > "$2"; chmod 600 "$2" || exit 1
    jq --arg listen "$listen" '{log:{level:"warn",timestamp:true},inbounds:[.nodes[]|select(.type=="anytls" or .type=="hysteria2" or .type=="tuicv5")|
      {type:(if .type=="tuicv5" then "tuic" else .type end),tag:("node-"+.id),listen:$listen,listen_port:.port,tls:{enabled:true,server_name:.sni,certificate:(.tls_cert|split("\n")),key:(.tls_key|split("\n"))}}+
      (if .type=="tuicv5" then {users:[{name:.id,uuid:.uuid,password:.password}],congestion_control:"cubic",zero_rtt_handshake:false,tls:{enabled:true,server_name:.sni,alpn:["h3"],certificate:(.tls_cert|split("\n")),key:(.tls_key|split("\n"))}}
       else {users:[{name:.id,password:.password}]} end)],outbounds:[{type:"direct",tag:"direct"}],route:{rules:[{ip_is_private:true,action:"reject"},{ip_cidr:["0.0.0.0/8","100.64.0.0/10","198.18.0.0/15","224.0.0.0/4","240.0.0.0/4","::/128","64:ff9b:1::/48","100::/64","ff00::/8"],action:"reject"}],final:"direct"}}' "$1" > "$2")
}
