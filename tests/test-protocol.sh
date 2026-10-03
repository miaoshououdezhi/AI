#!/usr/bin/env bash
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/lib/protocol.sh"
scratch=$(mktemp -d)
server_pid='' client_pid=''
cleanup() {
    [[ -z $client_pid ]] || kill "$client_pid" 2>/dev/null || true
    [[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null || true
    [[ -z $client_pid ]] || wait "$client_pid" 2>/dev/null || true
    [[ -z $server_pid ]] || wait "$server_pid" 2>/dev/null || true
    rm -rf "$scratch"
}
trap cleanup EXIT
core=${XRAY_BIN:-${XM_BIN:-}}
py=${XM_PYTHON:-python3}
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() { if "$@" >/dev/null 2>&1; then fail '非法输入被接受'; fi; }

protocol_new shadowsocks ss '节点 # / + ?' 24443 2001:db8::1 > "$scratch/ss.json"
reject protocol_new unknown node test 443 localhost
reject protocol_new shadowsocks node test 0 localhost
reject protocol_new shadowsocks node test 65536 localhost
reject protocol_new shadowsocks node test 0443 localhost
reject protocol_new shadowsocks node test 443 'a/?b'
reject protocol_new shadowsocks node test 443 'fe80::1%eth0'
reject protocol_new shadowsocks node test 443 localhost 'AAAAAAAAAAAAAAAAAAAAAA==oops'
reject protocol_validate_node '{"type":"shadowsocks"}'
reject protocol_validate_node 'null'
reject protocol_validate_node '[]'
reject protocol_validate_node "$(jq '.type="unsupported"' "$scratch/ss.json")"
reject protocol_validate_node "$(jq '.port=true' "$scratch/ss.json")"
reject protocol_validate_node "$(jq '.port=443.5' "$scratch/ss.json")"
reject protocol_validate_node "$(jq '.name="bad\nname"' "$scratch/ss.json")"
reject protocol_validate_node "$(jq '.name="bad\u009bname"' "$scratch/ss.json")"
reject protocol_validate_node "$(jq '.unknown="extra"' "$scratch/ss.json")"
protocol_share "$(cat "$scratch/ss.json")" > "$scratch/ss.uri"
"$py" - "$scratch" <<'PY'
import json,pathlib,sys,urllib.parse
p=pathlib.Path(sys.argv[1]); n=json.loads((p/'ss.json').read_text()); u=urllib.parse.urlsplit((p/'ss.uri').read_text().strip())
assert u.hostname==n['address'] and u.port==n['port']
assert urllib.parse.unquote(u.username)==n['method'] and urllib.parse.unquote(u.password)==n['password']
assert urllib.parse.unquote(u.fragment)==n['name'] and '%3D' in u.netloc
PY
jq -n '{schema_version:1,nodes:[]}' > "$scratch/empty.json"
protocol_generate "$scratch/empty.json" "$scratch/empty-config.json"
jq -e '.inbounds==[] and .log.loglevel=="warning" and (.routing.rules[0].ip|index("10.0.0.0/8")!=null)' "$scratch/empty-config.json" >/dev/null
jq -n --slurpfile nodes "$scratch/ss.json" '{schema_version:1,nodes:[$nodes[0],$nodes[0]]}' > "$scratch/duplicate.json"
reject protocol_generate "$scratch/duplicate.json" "$scratch/invalid-config.json"
jq '.nodes[1].id="another"' "$scratch/duplicate.json" > "$scratch/duplicate-port.json"
reject protocol_generate "$scratch/duplicate-port.json" "$scratch/invalid-config.json"
jq '.nodes[1].port=24446' "$scratch/duplicate.json" > "$scratch/duplicate-id.json"
reject protocol_generate "$scratch/duplicate-id.json" "$scratch/invalid-config.json"
# Simulate a kernel without IPv6 for protocol generation, while keeping real
# Python validation and OpenSSL cryptography intact.
cat > "$scratch/python-ipv4" <<'SH'
#!/usr/bin/env bash
if [[ $1 == -c && $2 == *'import errno,socket'* ]]; then printf '0.0.0.0\n'; else exec "$REAL_TEST_PYTHON" "$@"; fi
SH
chmod 750 "$scratch/python-ipv4"
export REAL_TEST_PYTHON=$py
jq -n --slurpfile nodes "$scratch/ss.json" '{schema_version:1,nodes:$nodes}' | jq '.nodes[0].address="127.0.0.1"' > "$scratch/ipv4-state.json"
XM_PYTHON="$scratch/python-ipv4" protocol_generate "$scratch/ipv4-state.json" "$scratch/ipv4-config.json"
jq -e '.inbounds[0].listen=="0.0.0.0"' "$scratch/ipv4-config.json" >/dev/null
jq -n --slurpfile nodes "$scratch/ss.json" '{schema_version:1,nodes:$nodes}' > "$scratch/ipv6-state.json"
reject env XM_PYTHON="$scratch/python-ipv4" REAL_TEST_PYTHON="$py" bash -c 'source "$1/lib/protocol.sh"; protocol_generate "$2" "$3"' _ "$repo" "$scratch/ipv6-state.json" "$scratch/invalid-config.json"
printf 'PASS protocol validation, URI encoding, empty config\n'

if [[ -z $core || ! -x $core ]]; then
    [[ ${1:-} != --e2e ]] || fail '--e2e 需要 XRAY_BIN'
    printf 'SKIP native config/e2e: set XRAY_BIN to the target Xray binary\n'
    exit 0
fi
export XRAY_BIN=$core
"$core" version | head -2
protocol_new vless-reality vl 'REALITY fixture' 24445 127.0.0.1 "${XM_REALITY_SNI:-www.cloudflare.com}" "${XM_REALITY_TARGET:-www.cloudflare.com:443}" > "$scratch/vl.json"
reject protocol_validate_node "$(jq '.short_id="abc"' "$scratch/vl.json")"
reject protocol_validate_node "$(jq '.uuid="bad"' "$scratch/vl.json")"
reject protocol_validate_node "$(jq '.public_key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' "$scratch/vl.json")"
reject protocol_validate_node "$(jq '.target="host:65536"' "$scratch/vl.json")"
protocol_share "$(cat "$scratch/vl.json")" > "$scratch/vl.uri"
"$py" - "$scratch" <<'PY'
import json,pathlib,sys,urllib.parse
p=pathlib.Path(sys.argv[1]); n=json.loads((p/'vl.json').read_text()); raw=(p/'vl.uri').read_text(); u=urllib.parse.urlsplit(raw.strip()); query=urllib.parse.parse_qs(u.query)
assert n['private_key'] not in raw and query['pbk']==[n['public_key']] and query['sid']==[n['short_id']]
assert query['flow']==['xtls-rprx-vision'] and query['type']==['tcp']
PY
jq -n --slurpfile ss "$scratch/ss.json" --slurpfile vl "$scratch/vl.json" '{schema_version:1,core_version:"v26.3.27",nodes:[$ss[0],$vl[0]]}' > "$scratch/state.json"
protocol_generate "$scratch/state.json" "$scratch/server.json"
"$core" run -test -config "$scratch/empty-config.json"
"$core" run -test -config "$scratch/server.json"
"$core" run -config "$scratch/empty-config.json" > "$scratch/empty-runtime.log" 2>&1 & server_pid=$!
sleep 1
kill -0 "$server_pid" || { cat "$scratch/empty-runtime.log" >&2; fail '空节点服务未保持运行'; }
kill "$server_pid"
wait "$server_pid" || true
server_pid=
printf 'PASS native config: empty + VLESS REALITY Vision/SS2022\n'
[[ ${1:-} == --e2e ]] || exit 0

# Random loopback ports avoid disturbing installed services. Clients retain REALITY
# authentication; the response HTTPS certificate is checked by curl.
"$py" - "$scratch" <<'PY'
import json,os,pathlib,socket,sys
p=pathlib.Path(sys.argv[1]); cfg=json.loads((p/'server.json').read_text()); sockets=[]; ports=[]
for _ in range(4):
    s=socket.socket(); s.bind(('127.0.0.1',0)); sockets.append(s); ports.append(s.getsockname()[1])
state=json.loads((p/'state.json').read_text()); client={'log':{'loglevel':'warning'},'inbounds':[],'outbounds':[],'routing':{'rules':[]}}
debug=os.environ.get('XM_E2E_DEBUG')=='1'
if debug:
    cfg['log']['loglevel']='debug'; cfg['log'].pop('access',None); client['log']['loglevel']='debug'
for i,n in enumerate(state['nodes']):
    server_port=ports[i]; local_port=ports[i+2]; cfg['inbounds'][i]['listen']='127.0.0.1'; cfg['inbounds'][i]['port']=server_port
    in_tag='socks-'+n['id']; out_tag='proxy-'+n['id']
    client['inbounds'].append({'tag':in_tag,'listen':'127.0.0.1','port':local_port,'protocol':'socks','settings':{'auth':'noauth','udp':False}})
    out={'tag':out_tag,'protocol':'shadowsocks' if n['type']=='shadowsocks' else 'vless'}
    user={'password':n['password']} if n['type']=='shadowsocks' else {'id':n['uuid'],'encryption':'none','flow':'xtls-rprx-vision'}
    if n['type']=='shadowsocks': out['settings']={'servers':[{'address':'127.0.0.1','port':server_port,'method':n['method'],'password':n['password']}]}
    else:
        out['settings']={'vnext':[{'address':'127.0.0.1','port':server_port,'users':[user]}]}
        out['streamSettings']={'network':'raw','security':'reality','realitySettings':{'serverName':n['sni'],'fingerprint':'chrome','password':n['public_key'],'shortId':n['short_id']}}
        if debug:
            cfg['inbounds'][i]['streamSettings']['realitySettings']['show']=True
            out['streamSettings']['realitySettings']['show']=True
    client['outbounds'].append(out); client['routing']['rules'].append({'type':'field','inboundTag':[in_tag],'outboundTag':out_tag})
(p/'server.json').write_text(json.dumps(cfg)); (p/'client.json').write_text(json.dumps(client)); (p/'ports').write_text('\n'.join(map(str,ports[2:]))+'\n')
for s in sockets:s.close()
PY
"$core" run -test -config "$scratch/client.json"
"$core" run -config "$scratch/server.json" > "$scratch/server.log" 2>&1 & server_pid=$!
"$core" run -config "$scratch/client.json" > "$scratch/client.log" 2>&1 & client_pid=$!
sleep 2
kill -0 "$server_pid" "$client_pid" || { cat "$scratch/server.log" "$scratch/client.log" >&2; fail '测试进程启动失败'; }
index=0
while IFS= read -r port; do
    index=$((index+1))
    if ! curl --disable --fail --silent --show-error --noproxy '' --connect-timeout 15 --max-time 40 --retry 1 --socks5-hostname "127.0.0.1:$port" "${XM_E2E_URL:-https://example.com}" -o "$scratch/response-$index"; then
        cat "$scratch/server.log" "$scratch/client.log" >&2; fail "客户端 $index 互通失败"
    fi
    [[ -s $scratch/response-$index ]] || fail '代理响应为空'
    printf 'PASS e2e protocol %s: verified TLS over proxy, public target\n' "$index"
done < "$scratch/ports"
