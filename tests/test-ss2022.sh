#!/usr/bin/env bash
# Both selectable SS2022 methods share the full validator/generator/URI path.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
source "$repo/lib/protocol.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() { if "$@" >"$scratch/rejected.out" 2>"$scratch/rejected.err"; then fail 'invalid SS2022 input accepted'; fi; }
for bits in 128 256; do
    method="2022-blake3-aes-$bits-gcm"
    protocol_new shadowsocks "ss$bits" "SS$bits 中文" "$((24000+bits))" 127.0.0.1 '' "$method" > "$scratch/$bits.json"
    protocol_validate_node "$(cat "$scratch/$bits.json")"
    protocol_share "$(cat "$scratch/$bits.json")" > "$scratch/$bits.uri"
    password=$(jq -r .password "$scratch/$bits.json")
    protocol_new shadowsocks "ss$bits" test 24443 localhost "$password" "$method" > "$scratch/explicit.json"
    [[ $(jq -r .password "$scratch/explicit.json") == "$password" ]] || fail 'explicit key changed'
    reject protocol_new shadowsocks bad bad 24444 localhost 'not-base64-secret' "$method"
    reject protocol_validate_node "$(jq '.password += "="' "$scratch/$bits.json")"
    reject protocol_validate_node "$(jq '.password=""' "$scratch/$bits.json")"
    # The wrong-size key must fail even when it is valid canonical Base64.
    other=$((384-bits))
    reject protocol_validate_node "$(jq --arg m "2022-blake3-aes-$other-gcm" '.method=$m' "$scratch/$bits.json")"
done
protocol_new shadowsocks legacy legacy 24445 localhost > "$scratch/legacy.json"
[[ $(jq -r .method "$scratch/legacy.json") == 2022-blake3-aes-128-gcm ]] || fail 'legacy default changed'
protocol_new shadowsocks legacy legacy 24445 localhost "$(jq -r .password "$scratch/legacy.json")" > "$scratch/legacy-explicit.json"
reject protocol_new shadowsocks bad bad 24444 localhost '' aes-256-gcm
reject protocol_new shadowsocks bad bad 24444 localhost '' ''
reject protocol_new shadowsocks bad bad 24444 localhost '' 2022-blake3-aes-256-gcm extra
jq -s '{schema_version:1,core_version:"v26.10.29",nodes:.}' "$scratch/128.json" "$scratch/256.json" > "$scratch/state.json"
protocol_validate_nodes "$scratch/state.json"
protocol_generate "$scratch/state.json" "$scratch/config.json"
"${XM_PYTHON:-python3}" - "$scratch" "$repo/assets/xray-outbound.py" <<'PY'
import base64,importlib.util,json,pathlib,sys,urllib.parse
sys.dont_write_bytecode=True
p=pathlib.Path(sys.argv[1]);spec=importlib.util.spec_from_file_location('outbound',sys.argv[2]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
config=json.loads((p/'config.json').read_text())
for i,bits in enumerate((128,256)):
 n=json.loads((p/f'{bits}.json').read_text());uri=(p/f'{bits}.uri').read_text().strip();u=urllib.parse.urlsplit(uri)
 assert len(base64.b64decode(n['password'],validate=True))==bits//8
 assert urllib.parse.unquote(u.username)==n['method'] and urllib.parse.unquote(u.password)==n['password']
 assert urllib.parse.unquote(u.fragment)==n['name']
 parsed=m.parse_uri(uri)['settings']['servers'][0]
 assert parsed['method']==n['method'] and parsed['password']==n['password']
 assert config['inbounds'][i]['settings']['method']==n['method']
 assert config['inbounds'][i]['settings']['password']==n['password']
assert 'not-base64-secret' not in (p/'rejected.err').read_text()
print('PASS SS2022 AES-128/256 key generation, canonical length checks, legacy default, config and share/upstream roundtrip')
PY
if [[ -n ${XRAY_BIN:-} ]]; then
    "$XRAY_BIN" run -test -config "$scratch/config.json" > "$scratch/native.log" 2>&1 || fail 'SS2022 native configuration rejected'
    printf 'PASS SS2022 AES-128/256 native server configuration\n'
else
    printf 'SKIP SS2022 native configuration: set XRAY_BIN\n'
fi
