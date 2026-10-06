#!/usr/bin/env bash
# Real URI parsing and state transactions. Native process/service failures are
# isolated fixtures; test-outbound-protocol.sh separately uses a real XRAY_BIN.
set -u
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then exit 77; fi
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
scratch=$(mktemp -d)
export XM_ROOT="$scratch/root"
source "$repo/xray-manager.sh"
trap 'state_exit_cleanup $?; rm -rf -- "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
mkdir -p "$XM_HOME/bin" "$XM_ETC" "$XM_DATA" "$XM_LOG"
for directory in "$XM_HOME" "$XM_ETC" "$XM_DATA" "$XM_LOG"; do printf 'xray-manager:1\n' > "$directory/.xray-manager-owned"; done
cat > "$XM_BIN" <<'CORE'
#!/usr/bin/env bash
[[ ${TEST_NATIVE_FAIL:-0} != 1 ]]
CORE
chmod 0755 "$XM_BIN"
platform_detect() { return 0; }
platform_port_available() { return 0; }
TEST_RUNNING=1; TEST_HEALTH_FAIL=0; TEST_CONFIRM=1; TEST_RACE=0
platform_service() { case $1 in status) [[ $TEST_RUNNING == 1 ]] ;; stop) TEST_RUNNING=0 ;; start|restart) TEST_RUNNING=1 ;; *) return 1 ;; esac; }
platform_health() { if ((TEST_HEALTH_FAIL > 0)); then TEST_HEALTH_FAIL=$((TEST_HEALTH_FAIL-1)); return 1; fi; [[ $TEST_RUNNING == 1 ]]; }
xm_confirm() {
    [[ -z $XM_LOCK_FD ]] || fail 'human confirmation holds lock'
    printf '%s\n' "$1" >> "$scratch/confirmations"
    if [[ $TEST_RACE == 1 ]]; then
        command jq '.nodes[0].name="concurrent-change"' "$XM_STATE" > "$scratch/race-state"
        mv "$scratch/race-state" "$XM_STATE"
        protocol_generate "$XM_STATE" "$XM_CONFIG" || fail 'race config'
    fi
    [[ $TEST_CONFIRM == 1 ]]
}
# Child argv must never contain an upstream credential or whole URI.
TEST_SECRET_VALUES=()
jq() {
    local argument secret
    for argument in "$@"; do
        for secret in "${TEST_SECRET_VALUES[@]}"; do
            [[ $argument != *"$secret"* ]] || { printf 'FAIL: upstream credential in jq argv\n' >&2; return 90; }
        done
    done
    command jq "$@"
}
pair=$("${XM_PYTHON:-python3}" - <<'KEYS'
import base64,subprocess
private=subprocess.check_output(["openssl","genpkey","-algorithm","X25519","-outform","DER"],stderr=subprocess.DEVNULL)
public=subprocess.check_output(["openssl","pkey","-inform","DER","-pubout","-outform","DER"],input=private,stderr=subprocess.DEVNULL)
for value in (private,public): print(base64.urlsafe_b64encode(value[-32:]).decode().rstrip("="))
KEYS
) || fail 'REALITY key fixture'
private=$(sed -n '1p' <<< "$pair"); public=$(sed -n '2p' <<< "$pair")
protocol_new vless-reality first 'First REALITY' 28001 8.8.8.8 www.cloudflare.com www.cloudflare.com:443 70f3d700-983a-4f3d-900e-7342b3b614e5 "$private" "$public" a4b7 > "$scratch/first.json" || fail 'first REALITY fixture'
protocol_new shadowsocks second 'Second node' 28002 8.8.4.4 > "$scratch/second.json" || fail 'second fixture'
jq -n --slurpfile a "$scratch/first.json" --slurpfile b "$scratch/second.json" '{schema_version:1,core_version:"v26.3.27",nodes:[$a[0],$b[0]]}' > "$XM_STATE"
protocol_generate "$XM_STATE" "$XM_CONFIG" || fail 'initial config'
cp "$XM_STATE" "$scratch/legacy.json"
key_one=$(printf '0123456789abcdef' | openssl base64 -A)
key_two=$(printf 'fedcba9876543210' | openssl base64 -A)
uri_one="ss://$(printf '2022-blake3-aes-128-gcm:%s' "$key_one" | openssl base64 -A)@upstream-one.example:443#private-one"
uri_two="ss://$(printf '2022-blake3-aes-128-gcm:%s' "$key_two" | openssl base64 -A)@[2001:db8::2]:8443#private-two"
TEST_SECRET_VALUES=("$key_one" "$key_two" "$uri_one" "$uri_two")
first_before=$(jq -c '.nodes[0]' "$XM_STATE"); second_before=$(jq -c '.nodes[1]' "$XM_STATE")
printf '%s\n' "$uri_one" > "$scratch/uri"
xm_dispatch route add first < "$scratch/uri" > "$scratch/add.out" 2> "$scratch/add.err" || fail 'add all'
[[ $(jq -c '.nodes[1]' "$XM_STATE") == "$second_before" ]] || fail 'add changed unrelated node'
jq -e '.nodes[0].outbound_route.mode=="all" and .nodes[0].outbound_route.domains==[] and .nodes[0].outbound_route.ips==[]' "$XM_STATE" >/dev/null || fail 'all route persisted'
jq -e '.routing.rules | any(.inboundTag==["node-first"] and .outboundTag=="outbound-first")' "$XM_CONFIG" >/dev/null || fail 'all route not bound to first inbound'
xm_dispatch route show first > "$scratch/show.json" 2> "$scratch/show.err" || fail 'show'
jq -e '.enabled and .id=="first" and .address=="upstream-one.example" and .port==443 and .mode=="all" and (has("uri")|not)' "$scratch/show.json" >/dev/null || fail 'show summary'
for file in "$scratch/add.out" "$scratch/add.err" "$scratch/show.json" "$scratch/show.err"; do
    for secret in "${TEST_SECRET_VALUES[@]}"; do if grep -Fq "$secret" "$file"; then fail 'summary leaked credential'; fi; done
done
pass 'per-node all route, unrelated node preservation, inbound binding and credential-free summaries'
printf '%s\n' "$uri_two" > "$scratch/uri"
xm_dispatch route add second rules '["domain:example.com"]' '["203.0.113.0/24"]' < "$scratch/uri" >/dev/null 2>&1 || fail 'second independent rules route'
first_with_route=$(jq -c '.nodes[0]' "$XM_STATE")
jq -e '[.routing.rules[]|select(.outboundTag=="outbound-second")]|length==2 and all(.inboundTag==["node-second"])' "$XM_CONFIG" >/dev/null || fail 'domain/IP OR rules not independent'
second_with_route=$(jq -c '.nodes[1]' "$XM_STATE")
xm_dispatch route add first < "$scratch/uri" >/dev/null 2>&1 || fail 'replacement'
grep -q '替换节点 first 已有的出站路由' "$scratch/confirmations" || fail 'replacement confirmation missing'
[[ $(jq -c '.nodes[1]' "$XM_STATE") == "$second_with_route" ]] || fail 'replacement changed second route'
xm_dispatch route delete first >/dev/null 2>&1 || fail 'delete'
[[ $(jq -c '.nodes[0]' "$XM_STATE") == "$first_before" && $(jq -c '.nodes[1]' "$XM_STATE") == "$second_with_route" ]] || fail 'deletion altered unrelated node or inbound'
xm_dispatch route delete first >/dev/null 2>&1 || fail 'idempotent delete'
xm_dispatch route show first > "$scratch/direct.json" || fail 'direct show'
jq -e '.enabled==false and .mode=="direct"' "$scratch/direct.json" >/dev/null || fail 'direct summary'
pass 'two nodes retain independent all/rules routes, explicit replacement and single-node deletion'

reject_route() {
    cp "$XM_STATE" "$scratch/reject-state"; cp "$XM_CONFIG" "$scratch/reject-config"
    if xm_dispatch route "$@" < "$scratch/uri" > "$scratch/reject.out" 2> "$scratch/reject.err"; then fail 'invalid or cancelled route accepted'; fi
    cmp "$XM_STATE" "$scratch/reject-state" && cmp "$XM_CONFIG" "$scratch/reject-config" || fail 'rejected route mutated active files'
}
reject_route add first all extra '[]'
reject_route add first rules '[]' '[]'
reject_route add first rules '["bad;command"]' '[]'
reject_route add first rules '[]' '["not-an-ip"]'
reject_route add first invalid
reject_route show first unexpected
reject_route delete first unexpected
reject_route add missing
printf 'not-a-node-uri\n' > "$scratch/uri"; reject_route add first
printf ':q\n' > "$scratch/uri"; reject_route add first
: > "$scratch/uri"; reject_route add first
printf '%s\n' "$uri_one" > "$scratch/uri"
TEST_CONFIRM=0; reject_route add first; TEST_CONFIRM=1
export TEST_NATIVE_FAIL=1; reject_route add first; unset TEST_NATIVE_FAIL
TEST_HEALTH_FAIL=1; reject_route add first
[[ $TEST_RUNNING == 1 ]] || fail 'health rollback lost running state'
TEST_RUNNING=0
xm_dispatch route add first < "$scratch/uri" >/dev/null 2>&1 || fail 'stopped add'
[[ $TEST_RUNNING == 0 ]] || fail 'route add started stopped core'
TEST_RUNNING=1; TEST_RACE=1
printf '%s\n' "$uri_two" > "$scratch/uri"
if xm_dispatch route add first < "$scratch/uri" >/dev/null 2>&1; then fail 'stale confirmation saved'; fi
[[ $(jq -r '.nodes[0].name' "$XM_STATE") == concurrent-change ]] || fail 'concurrent node overwritten'
TEST_RACE=0
XM_SELECTED_NODE=$first_with_route
reject_route delete first
unset XM_SELECTED_NODE
pass 'invalid rules/links, cancellation/EOF, native/health rollback, stopped-core preservation and concurrent snapshot rejection'

# Export restores complete URI/rules in a private snapshot; legacy files remain
# loadable. The importing machine keeps its own current core version.
xm_dispatch export "$scratch/export.json" >/dev/null 2>&1 || fail 'export'
[[ $(stat -c %a "$scratch/export.json") == 600 ]] || fail 'export mode'
cp "$XM_STATE" "$scratch/exported-state"
xm_dispatch route delete first >/dev/null 2>&1 || fail 'delete before restore'
xm_dispatch route delete second >/dev/null 2>&1 || fail 'delete second before restore'
command jq '.core_version="v26.9.30"' "$XM_STATE" > "$scratch/new-version"; mv "$scratch/new-version" "$XM_STATE"
xm_dispatch import "$scratch/export.json" >/dev/null 2>&1 || fail 'import routed configuration'
jq -e --slurpfile before "$scratch/exported-state" '.nodes==$before[0].nodes and .core_version=="v26.9.30"' "$XM_STATE" >/dev/null || fail 'route import lost fields or changed current core'
cp "$XM_STATE" "$scratch/restore-state"; cp "$XM_CONFIG" "$scratch/restore-config"
command jq '.nodes[0].outbound_route.uri="ss://invalid"' "$scratch/export.json" > "$scratch/invalid-import.json"
if xm_dispatch import "$scratch/invalid-import.json" >/dev/null 2>&1; then fail 'malformed exported route imported'; fi
cmp "$XM_STATE" "$scratch/restore-state" && cmp "$XM_CONFIG" "$scratch/restore-config" || fail 'invalid import changed state'
xm_dispatch import "$scratch/legacy.json" >/dev/null 2>&1 || fail 'legacy import'
jq -e '.nodes|all(has("outbound_route")|not)' "$XM_STATE" >/dev/null || fail 'legacy import retained deleted routes'
pass '0600 full-route export/import, invalid-route refusal and route-free legacy compatibility'

# Detail menu uses the authoritative command path. Input hiding/TTY colours are
# additionally covered by the existing UI PTY suite.
XM_SELECTED_NODE=$(jq -c '.nodes[0]' "$XM_STATE")
printf '6\n1\n%s\n' "$uri_one" > "$scratch/menu-input"
xm_menu_node_details "$XM_SELECTED_NODE" < "$scratch/menu-input" >/dev/null 2> "$scratch/menu-add.log" || fail 'detail menu route add'
grep -q '\[6\].*添加出站路由' "$scratch/menu-add.log" || fail 'details add action missing'
grep -q '\[7\].*删除出站路由' "$scratch/menu-add.log" || fail 'details delete action missing'
XM_SELECTED_NODE=$(jq -c '.nodes[0]' "$XM_STATE")
printf '0\n' > "$scratch/menu-input"
xm_menu_node_details "$XM_SELECTED_NODE" < "$scratch/menu-input" >/dev/null 2> "$scratch/menu-summary.log" || fail 'detail route summary'
grep -q 'upstream-one.example:443' "$scratch/menu-summary.log" || fail 'upstream summary missing'
for secret in "${TEST_SECRET_VALUES[@]}"; do if grep -Fq "$secret" "$scratch/menu-summary.log"; then fail 'detail secret leaked'; fi; done
printf '7\n' > "$scratch/menu-input"
xm_menu_node_details "$XM_SELECTED_NODE" < "$scratch/menu-input" >/dev/null 2>&1 || fail 'detail delete route'
unset XM_SELECTED_NODE
xm_work_end; xm_unlock
xm_install_code || fail 'code install copies helper'
cmp "$repo/assets/xray-outbound.py" "$XM_HOME/assets/xray-outbound.py" || fail 'missing installed URI helper'
_platform_clean_files_preflight || fail 'uninstall allowlist rejected installed helper'
pass 'detail actions, hidden route summary, helper installation and uninstall ownership allowlist'
