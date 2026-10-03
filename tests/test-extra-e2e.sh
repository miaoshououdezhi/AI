#!/usr/bin/env bash
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/lib/protocol.sh"
: "${XRAY_BIN:?set XRAY_BIN}" "${XM_EXTRA_BIN:?set XM_EXTRA_BIN}"
py=${XM_PYTHON:-python3}
scratch=$(mktemp -d)
pids=()
cleanup() {
    local pid
    for pid in ${pids[@]+"${pids[@]}"}; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
    rm -rf "$scratch"
}
trap cleanup EXIT
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$scratch/key.pem" -out "$scratch/cert.pem" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' -days 2 >/dev/null 2>&1
chmod 600 "$scratch/key.pem"
"$XRAY_BIN" version | head -2
"$XM_EXTRA_BIN" version | head -2
for type in vless-ws socks5 anytls hysteria2 tuicv5; do
    if [[ $type == vless-ws ]]; then protocol_new "$type" fixture "$type" 25443 localhost localhost /xm-ws "$scratch/cert.pem" "$scratch/key.pem" > "$scratch/node.json"
    elif [[ $type == socks5 ]]; then protocol_new "$type" fixture "$type" 25443 localhost > "$scratch/node.json"
    else protocol_new "$type" fixture "$type" 25443 localhost localhost "$scratch/cert.pem" "$scratch/key.pem" > "$scratch/node.json"; fi
    jq -n --slurpfile n "$scratch/node.json" '{schema_version:1,nodes:$n}' > "$scratch/state.json"
    protocol_generate "$scratch/state.json" "$scratch/xray.json"
    protocol_generate_extra "$scratch/state.json" "$scratch/extra.json"
    "$py" - "$scratch" <<'PY'
import json,pathlib,socket,sys
p=pathlib.Path(sys.argv[1]);sockets=[];ports=[]
for _ in range(3):
 s=socket.socket();s.bind(('127.0.0.1',0));sockets.append(s);ports.append(s.getsockname()[1])
n=json.loads((p/'node.json').read_text());t=n['type'];extra=t in ('anytls','hysteria2','tuicv5');f=p/('extra.json' if extra else 'xray.json');cfg=json.loads(f.read_text())
if extra:
 cfg['inbounds'][0].update(listen='127.0.0.1',listen_port=ports[0]);cfg['route']['rules']=[{'ip_cidr':['127.0.0.1/32'],'port':[ports[2]],'action':'route','outbound':'direct'},{'action':'reject'}]
 out={'type':'tuic' if t=='tuicv5' else t,'tag':'proxy','server':'127.0.0.1','server_port':ports[0],'password':n['password'],'tls':{'enabled':True,'server_name':'localhost','certificate':n['tls_cert'].splitlines()}}
 if t=='tuicv5':out.update(uuid=n['uuid'],congestion_control='cubic');out['tls']['alpn']=['h3']
 client={'log':{'level':'warn'},'inbounds':[{'type':'socks','listen':'127.0.0.1','listen_port':ports[1]}],'outbounds':[out]}
else:
 cfg['inbounds'][0].update(listen='127.0.0.1',port=ports[0]);cfg['routing']['rules']=[{'type':'field','ip':['127.0.0.1/32'],'port':str(ports[2]),'outboundTag':'direct'},{'type':'field','network':'tcp,udp','outboundTag':'block'}]
 cfg['outbounds'][0]['settings']={'finalRules':[{'action':'allow','ip':['127.0.0.1/32'],'port':str(ports[2])}]}
 if t=='vless-ws':out={'protocol':'vless','settings':{'vnext':[{'address':'127.0.0.1','port':ports[0],'users':[{'id':n['uuid'],'encryption':'none'}]}]},'streamSettings':{'network':'ws','security':'tls','wsSettings':{'path':n['path']},'tlsSettings':{'serverName':'localhost','certificates':[{'certificate':n['tls_cert'].splitlines(),'usage':'verify'}]}}}
 else:out={'protocol':'socks','settings':{'servers':[{'address':'127.0.0.1','port':ports[0],'users':[{'user':n['username'],'pass':n['password']}]}]}}
 client={'log':{'loglevel':'warning'},'inbounds':[{'listen':'127.0.0.1','port':ports[1],'protocol':'socks','settings':{'auth':'noauth'}}],'outbounds':[out]}
f.write_text(json.dumps(cfg));(p/'client.json').write_text(json.dumps(client));(p/'ports').write_text('\n'.join(map(str,ports))+'\n');(p/'payload').write_text('xray-manager-five-protocol-e2e\n')
for s in sockets:s.close()
PY
    mapfile -t ports < "$scratch/ports"
    "$py" -m http.server "${ports[2]}" --bind 127.0.0.1 --directory "$scratch" > "$scratch/http.log" 2>&1 & pids+=("$!")
    if [[ $(protocol_engine "$type") == extra ]]; then
        "$XM_EXTRA_BIN" check -c "$scratch/extra.json"
        "$XM_EXTRA_BIN" check -c "$scratch/client.json"
        "$XM_EXTRA_BIN" run -c "$scratch/extra.json" > "$scratch/server.log" 2>&1 & pids+=("$!")
        "$XM_EXTRA_BIN" run -c "$scratch/client.json" > "$scratch/client.log" 2>&1 & pids+=("$!")
    else
        "$XRAY_BIN" run -test -config "$scratch/xray.json"
        "$XRAY_BIN" run -test -config "$scratch/client.json"
        "$XRAY_BIN" run -config "$scratch/xray.json" > "$scratch/server.log" 2>&1 & pids+=("$!")
        "$XRAY_BIN" run -config "$scratch/client.json" > "$scratch/client.log" 2>&1 & pids+=("$!")
    fi
    sleep 2
    if ! curl --disable --fail --silent --show-error --noproxy '' --connect-timeout 10 --max-time 20 --socks5-hostname "127.0.0.1:${ports[1]}" "http://127.0.0.1:${ports[2]}/payload" -o "$scratch/response"; then
        cat "$scratch/server.log" "$scratch/client.log" >&2; exit 1
    fi
    cmp "$scratch/payload" "$scratch/response"
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
    pids=()
    if [[ $type == socks5 ]]; then
        printf 'PASS e2e socks5: real password-authenticated client/server, exact loopback HTTP fixture\n'
    else
        printf 'PASS e2e %s: real authenticated client/server, verified TLS, exact loopback HTTP fixture\n' "$type"
    fi
done
