#!/usr/bin/env bash
# User flows use real formatters/protocol validation; fixture services never run.
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
export XM_ROOT=$scratch/root
source "$repo/xray-manager.sh"
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ $XM_DEFAULT_CORE_VERSION == v26.10.31 ]] || fail 'default stable version'
# Removed protocols cannot reach filesystem preparation through the CLI.
xm_ready() { touch "$scratch/reached-ready"; return 1; }
for type in anytls tuicv5; do
    status=0
    xm_dispatch add "$type" old 'removed' 443 example.com localhost /tmp/cert /tmp/key > "$scratch/out" 2> "$scratch/err" || status=$?
    [[ $status == 2 && ! -e $scratch/reached-ready ]] || fail 'removed add reached mutation'
done
# Actual version rather than only state metadata gates native HY2 creation.
cat > "$scratch/core" <<'CORE'
#!/bin/sh
printf 'Xray %s (fixture)\n' "$TEST_CORE_VERSION"
CORE
chmod 0700 "$scratch/core"
XM_BIN=$scratch/core
for version in 26.10.29 26.10.31 26.11.1; do export TEST_CORE_VERSION=$version; xm_hy2_core_ready; done
for version in 26.3.27 26.10.28 malformed; do
    export TEST_CORE_VERSION=$version
    if xm_hy2_core_ready > "$scratch/out" 2> "$scratch/err"; then fail 'old/unknown core accepted for new HY2'; fi
done
# Menu offers exactly the six active protocols.
xm_menu_ready() { return 0; }
printf '0\n' | xm_menu_add > "$scratch/out" 2> "$scratch/add-menu"
python3 - "$scratch/add-menu" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
assert not any(x in s for x in ('AnyTLS','TUIC'))
assert re.findall(r'^\[(\d+)\]',s,re.M)==['1','2','3','4','5','6','0']
assert 'HY2（Xray）' in s
PY
mkdir -p "$XM_ETC"
state_empty "$XM_DEFAULT_CORE_VERSION" > "$XM_STATE"
xm_ready() { return 0; }
platform_random_port() { printf '25001\n'; }
platform_port_available() { return 0; }
platform_public_ip() { printf '8.8.8.8\n'; }
xm_dispatch() { printf '%s\0' "$@" | python3 -c 'import json,sys; json.dump(sys.stdin.read().split("\0")[:-1],sys.stdout)' > "$scratch/call"; }
for choice in 1 2; do
    printf '3\n\n\n\n\n%s\n\n' "$choice" | xm_menu_add > "$scratch/out" 2> "$scratch/add-result"
    mapfile -t args < <(jq -r '.[]' "$scratch/call")
    node=$(protocol_new "${args[@]:1}")
    printf '%s' "$node" > "$scratch/node-$choice.json"
    python3 - "$scratch/node-$choice.json" "$choice" <<'PY'
import base64,json,sys
n=json.load(open(sys.argv[1])); bits=128 if sys.argv[2]=='1' else 256
assert n['method']==f'2022-blake3-aes-{bits}-gcm'
assert len(base64.b64decode(n['password']))==bits//8
PY
    if grep -Fq "$(jq -r .password <<< "$node")" "$scratch/out" "$scratch/add-result"; then fail 'secret exposed while adding'; fi
done
printf '3\n\n\n\n\n9\n:q\n' | xm_menu_add > "$scratch/out" 2> "$scratch/cancel" && fail 'cancelled algorithm accepted'
grep -q '请选择 1 或 2' "$scratch/cancel" || fail 'algorithm retry missing'
# Cards and details share field starts; selection preserves the complete URI.
node=$(jq '.id="node256"|.name="中文节点名称🙂很长很长很长很长很长很长很长很长很长"|.address="2001:db8::1234"' "$scratch/node-2.json")
jq -n --argjson n "$node" '{schema_version:1,core_version:"v26.10.29",nodes:[$n]}' > "$XM_STATE"
expected=$(protocol_share "$node")
xm_dispatch() {
    [[ $1 == share && $2 == node256 ]] || return 1
    protocol_share "$(jq -c '.nodes[0]' "$XM_STATE")"
}
for width in 40 80; do
    printf '1\n' | COLUMNS=$width xm_menu_node share > "$scratch/share" 2> "$scratch/cards"
    [[ $(cat "$scratch/share") == "$expected" ]] || fail 'share URI was decorated/truncated'
    python3 - "$scratch/cards" "$width" <<'PY'
import pathlib,re,sys,unicodedata
s=pathlib.Path(sys.argv[1]).read_text();width=int(sys.argv[2])
def cells(s):return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in s)
fields=[line for line in s.splitlines() if line.startswith('    ')]
assert len(fields)>=8
for line in fields:
 assert cells(line)<=width,line
 m=re.match(r'^    (?:名称|地址|ID|协议|端口) +(\S)',line)
 assert m and cells(line[:m.start(1)])==10,line
assert '[输入] 节点编号' in s and '\n  > ' in s
assert '── 分享结果 ──' in s
assert not '\x1b' in s
PY
done
printf 'PASS: six add protocols, rejected removed CLI, actual HY2 version gate, SS128/256 input, aligned cards and exact URI\n'
