#!/usr/bin/env bash
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
py=${XM_PYTHON:-python3}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
source "$repo/lib/protocol.sh"
export OUTBOUND_TEST_CORE=${XRAY_BIN:-${XM_BIN:-}}
"$py" - "$repo/assets/xray-outbound.py" "$scratch" <<'PY'
import base64, copy, importlib.util, json, os, subprocess, sys
sys.dont_write_bytecode=True
spec=importlib.util.spec_from_file_location("outbound",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
scratch=sys.argv[2]
key16=base64.b64encode(bytes(range(16))).decode(); key32=base64.b64encode(bytes(range(32))).decode()
uid="11111111-1111-4111-8111-111111111111"
pbk=base64.urlsafe_b64encode(bytes(range(32))).decode().rstrip("=")
uris=[
 "ss://"+base64.urlsafe_b64encode(("2022-blake3-aes-128-gcm:"+key16).encode()).decode().rstrip("=")+"@example.com:443#test",
 "ss://2022-blake3-aes-128-gcm:"+key16+":"+key16+"@example.com:443",
 "ss://2022-blake3-aes-256-gcm:"+key32+"@example.com:443",
 "ss://2022-blake3-chacha20-poly1305:"+key32+"@example.com:443",
 "ss://"+base64.urlsafe_b64encode(b"aes-128-gcm:legacy@127.0.0.1:1234").decode().rstrip("="),
 "socks5://user:p%40ss%3Aword@[2001:db8::1]:1080",
 "trojan://p%40ss@example.com:443?security=tls&type=ws&path=%2Ftest&host=example.com&alpn=http%2F1.1",
 "vless://"+uid+"@example.com:443?security=reality&type=tcp&pbk="+pbk+"&sid=aabb&fp=chrome&flow=xtls-rprx-vision",
 "vless://"+uid+"@example.com:443?security=reality&type=xhttp&pbk="+pbk+"&sid=&mode=auto&path=%2Ftest",
 "vless://"+uid+"@example.com:443?security=tls&type=ws&path=%2Ftest&host=example.com",
]
core=os.environ.get("OUTBOUND_TEST_CORE")
for i,uri in enumerate(uris):
 outbound=m.parse_uri(uri)
 route={"uri":uri,"mode":"all","domains":[],"ips":[]}
 m.validate_route(route)
 if core:
  path=os.path.join(scratch,"native-%d.json"%i)
  with open(path,"w") as f: json.dump({"log":{"loglevel":"none"},"outbounds":[outbound]},f)
  result=subprocess.run([core,"run","-test","-config",path],capture_output=True)
  if result.returncode: raise AssertionError("native fixture %d failed (credentials suppressed)"%i)
for uri in [uris[0].split("#")[0]+"?plugin=v2ray",uris[7]+"&fp=firefox",uris[7]+"&extra=%7B%7D",uris[7].replace("sid=aabb","sid=abc"),uris[7].replace("type=tcp","type=ws"),uris[9]+"&flow=xtls-rprx-vision",uris[9]+"&allowInsecure=1","hysteria2://secret@example.com:443","socks5://user:secret@example.com:1080?udp=1","ss://2022-blake3-aes-128-gcm:badkey@example.com:443","ss://2022-blake3-chacha20-poly1305:"+key32+":"+key32+"@example.com:443", "socks5://user:secret%0A@example.com:1080", "ss://invalid", "vless://"+uid+"@example.com:443?security=tls&path=%ZZ", "trojan://secret@example.com:443?security=tls&type=raw&path=/x"]:
 try: m.parse_uri(uri)
 except (ValueError,TypeError): pass
 else: raise AssertionError("invalid URI accepted")
route={"uri":uris[0],"mode":"rules","domains":["example.com","full:test.example"],"ips":["203.0.113.5","2001:db8::/32"]}
out, domains, ips=m.validate_route(route)
assert domains==["domain:example.com","full:test.example"] and ips==["203.0.113.5/32","2001:db8::/32"]
for changes in [{"mode":"all"},{"domains":[],"ips":[]},{"domains":["geosite:cn"]},{"ips":["geoip:cn"]},{"domains":["example.com","domain:example.com"]},{"extra":1},{"uri":None}]:
 bad=dict(route,**changes)
 try: m.validate_route(bad)
 except (ValueError,TypeError): pass
 else: raise AssertionError("invalid route accepted")
base={"inbounds":[{"tag":"node-one"},{"tag":"node-two"}],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}],"routing":{"rules":[{"outboundTag":"block","ip":["10.0.0.0/8"]}]}}
state={"nodes":[{"id":"one","type":"socks5","outbound_route":route},{"id":"two","type":"shadowsocks","outbound_route":{"uri":uris[5],"mode":"all","domains":[],"ips":[]}}]}
config=m.augment(state,copy.deepcopy(base))
assert config["outbounds"][0]["tag"]=="direct" and config["routing"]["rules"][0]==base["routing"]["rules"][0]
assert [r["inboundTag"] for r in config["routing"]["rules"][1:]]==[["node-one"],["node-one"],["node-two"]]
assert all("sniffing" not in entry for entry in config["inbounds"])
del state["nodes"][0]["outbound_route"]
deleted=m.augment(state,copy.deepcopy(base))
assert len(deleted["outbounds"])==3 and deleted["outbounds"][-1]["tag"]=="outbound-two"
assert deleted["routing"]["rules"][-1]["inboundTag"]==["node-two"]
for t in ("anytls","hysteria2","tuicv5"):
 try: m.validate_node({"type":t,"outbound_route":route})
 except ValueError: pass
 else: raise AssertionError("auxiliary route accepted")
with open(os.path.join(scratch,"uri"),"w") as f:f.write(uris[0])
print("PASS: strict URI mapping, SS2022 key chains, rule OR, per-inbound isolation, delete and auxiliary rejection"+ ("; native outbound fixtures" if core else "; native checks SKIP: XRAY_BIN unavailable"))
PY
uri=$(cat "$scratch/uri")
route=$(protocol_outbound_route "$uri" all '[]' '[]')
summary=$(printf '%s' "$route" | protocol_outbound_summary)
[[ $(printf '%s' "$summary" | jq -r .protocol) == shadowsocks ]] || exit 1
node=$(protocol_new shadowsocks ss test 24443 127.0.0.1)
printf '%s\0' "$node" "$route" | jq -Rsc 'split("\u0000")|{schema_version:1,core_version:"v26.3.27",nodes:[((.[0]|fromjson)+{outbound_route:(.[1]|fromjson)})]}' > "$scratch/state.json"
protocol_generate "$scratch/state.json" "$scratch/config.json"
jq -e '.outbounds[0].tag=="direct" and .outbounds[2].tag=="outbound-ss" and .routing.rules[0].outboundTag=="block" and .routing.rules[1].inboundTag==["node-ss"]' "$scratch/config.json" >/dev/null
if [[ -n ${XRAY_BIN:-${XM_BIN:-}} ]]; then
    "${XRAY_BIN:-$XM_BIN}" run -test -config "$scratch/config.json" > "$scratch/native.log" 2>&1 || { printf 'FAIL: generated native config (credentials suppressed)\n' >&2; exit 1; }
fi
if protocol_outbound_route 'socks5://user:DoNotLeak@bad/host' all '[]' '[]' > "$scratch/error" 2>&1; then exit 1; fi
! grep -q DoNotLeak "$scratch/error"
printf 'PASS: shell stdin interfaces, generated node-bound config, redacted errors\n'
