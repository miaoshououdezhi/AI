#!/usr/bin/env bash
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/lib/protocol.sh"
core=${XRAY_BIN:?set XRAY_BIN to a real Xray binary}
py=${XM_PYTHON:-python3}
export XRAY_BIN=$core
scratch=$(mktemp -d)
pids=()
cleanup() {
    local pid
    for pid in ${pids[@]+"${pids[@]}"}; do kill "$pid" 2>/dev/null || true; done
    for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid" 2>/dev/null || true; done
    rm -rf "$scratch"
}
trap cleanup EXIT
reject() { if "$@" >/dev/null 2>&1; then printf 'FAIL rejected input accepted\n' >&2; exit 1; fi; }
"$core" version | head -2
protocol_new vless-xhttp xh 'XHTTP 节点 #?' 24447 2001:db8::2 www.cloudflare.com www.cloudflare.com:443 /xm-test packet-up > "$scratch/node.json"
for path in / /bad//path '/bad?x=1' '/bad%20path' '/bad.path' '/bad path' 'relative' ; do
    reject protocol_validate_node "$(jq --arg path "$path" '.path=$path' "$scratch/node.json")"
done
reject protocol_validate_node "$(jq '.mode="evil"' "$scratch/node.json")"
reject protocol_validate_node "$(jq 'del(.path)' "$scratch/node.json")"
reject protocol_validate_node "$(jq '.path=("/"+("a"*128))' "$scratch/node.json")"
reject protocol_validate_node "$(jq '.short_id="abc"' "$scratch/node.json")"
reject protocol_validate_node "$(jq '.target="host:65536"' "$scratch/node.json")"
map_keys=()
while IFS= read -r key; do map_keys+=("$key"); done < <(jq -r '.uuid,.private_key,.public_key,.short_id' "$scratch/node.json")
protocol_new vless-xhttp fixed 'fixed fixture' 24449 localhost www.cloudflare.com www.cloudflare.com:443 /xm-fixed packet-up "${map_keys[@]}" > "$scratch/fixed.json"
jq -e --slurpfile original "$scratch/node.json" '.uuid==$original[0].uuid and .private_key==$original[0].private_key and .short_id==$original[0].short_id' "$scratch/fixed.json" >/dev/null
protocol_share "$(cat "$scratch/node.json")" > "$scratch/uri"
"$py" - "$scratch" <<'PY'
import json,pathlib,sys,urllib.parse
p=pathlib.Path(sys.argv[1]); n=json.loads((p/'node.json').read_text()); raw=(p/'uri').read_text().strip(); u=urllib.parse.urlsplit(raw); q=urllib.parse.parse_qs(u.query)
assert u.hostname==n['address'] and u.port==n['port'] and urllib.parse.unquote(u.fragment)==n['name']
assert q['type']==['xhttp'] and q['path']==[n['path']] and q['mode']==[n['mode']]
assert q['pbk']==[n['public_key']] and q['sid']==[n['short_id']] and 'flow' not in q and n['private_key'] not in raw
PY
protocol_new vless-xhttp next 'random fixture' 24448 localhost www.cloudflare.com www.cloudflare.com:443 /xm-next packet-up > "$scratch/next.json"
for field in uuid private_key public_key short_id; do
    [[ $(jq -r --arg f "$field" '.[$f]' "$scratch/node.json") != "$(jq -r --arg f "$field" '.[$f]' "$scratch/next.json")" ]]
done
printf 'PASS XHTTP validation, IPv6 URI, no private key/flow, random credentials\n'
for mode in packet-up auto stream-up stream-one; do
    jq --arg mode "$mode" '.mode=$mode' "$scratch/node.json" > "$scratch/current.json"
    jq -n --slurpfile n "$scratch/current.json" '{schema_version:1,nodes:$n}' > "$scratch/state.json"
    protocol_generate "$scratch/state.json" "$scratch/server.json"
    jq -e --arg mode "$mode" '.inbounds[0].streamSettings.network=="xhttp" and .inbounds[0].streamSettings.xhttpSettings.mode==$mode and (.inbounds[0].settings.clients[0]|has("flow")|not)' "$scratch/server.json" >/dev/null
    "$core" run -test -config "$scratch/server.json"
    printf 'PASS native XHTTP mode %s\n' "$mode"
    [[ ${1:-} == --e2e ]] || continue
    # Only the test copy removes private routing restrictions to reach its own
    # loopback HTTP fixture. Production routing remains unchanged.
    "$py" - "$scratch" <<'PY'
import json,pathlib,socket,sys
p=pathlib.Path(sys.argv[1]); sockets=[]; ports=[]
for _ in range(3):
 s=socket.socket(); s.bind(('127.0.0.1',0)); sockets.append(s); ports.append(s.getsockname()[1])
n=json.loads((p/'current.json').read_text()); cfg=json.loads((p/'server.json').read_text()); cfg['inbounds'][0].update(listen='127.0.0.1',port=ports[0]); cfg['routing']['rules']=[]
# Recent previews add freedom private-address protection independently of routing.
# Permit only this fixture IP and exact temporary port in this test copy.
# Older stable cores ignore the unsupported finalRules key.
cfg['outbounds'][0]['settings']={'finalRules':[{'action':'allow','ip':['127.0.0.1/32'],'port':str(ports[2])}]}
client={'log':{'loglevel':'warning'},'inbounds':[{'listen':'127.0.0.1','port':ports[1],'protocol':'socks','settings':{'auth':'noauth','udp':False}}],'outbounds':[{'protocol':'vless','settings':{'vnext':[{'address':'127.0.0.1','port':ports[0],'users':[{'id':n['uuid'],'encryption':'none'}]}]},'streamSettings':{'network':'xhttp','security':'reality','xhttpSettings':{'path':n['path'],'mode':n['mode']},'realitySettings':{'serverName':n['sni'],'fingerprint':'chrome','password':n['public_key'],'shortId':n['short_id']}}}]}
(p/'server.json').write_text(json.dumps(cfg)); (p/'client.json').write_text(json.dumps(client)); (p/'ports').write_text('\n'.join(map(str,ports))+'\n'); (p/'payload').write_text('xray-manager-xhttp-e2e\n')
for s in sockets:s.close()
PY
    "$core" run -test -config "$scratch/client.json"
    mapfile -t ports < "$scratch/ports"
    "$py" -m http.server "${ports[2]}" --bind 127.0.0.1 --directory "$scratch" > "$scratch/http.log" 2>&1 & pids+=("$!")
    "$core" run -config "$scratch/server.json" > "$scratch/server.log" 2>&1 & pids+=("$!")
    "$core" run -config "$scratch/client.json" > "$scratch/client.log" 2>&1 & pids+=("$!")
    sleep 2
    if ! curl --disable --fail --silent --show-error --noproxy '' --connect-timeout 10 --max-time 30 --retry 1 --socks5-hostname "127.0.0.1:${ports[1]}" "http://127.0.0.1:${ports[2]}/payload" -o "$scratch/response"; then
        cat "$scratch/server.log" "$scratch/client.log" >&2
        exit 1
    fi
    cmp "$scratch/payload" "$scratch/response"
    for pid in ${pids[@]+"${pids[@]}"}; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
    pids=()
    printf 'PASS e2e XHTTP mode %s: real client/server to loopback HTTP fixture\n' "$mode"
done
