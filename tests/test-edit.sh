#!/usr/bin/env bash
# Real protocol/state transaction tests. Mock only core execution, service and
# user confirmation; true Xray native validation runs separately with XRAY_BIN.
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
cat > "$scratch/key-core" <<'KEYS'
#!/usr/bin/env python3
import base64,subprocess,sys
if sys.argv[1:] != ["x25519"]:sys.exit(2)
a=subprocess.check_output(["openssl","genpkey","-algorithm","X25519","-outform","DER"],stderr=subprocess.DEVNULL)
b=subprocess.check_output(["openssl","pkey","-inform","DER","-pubout","-outform","DER"],input=a,stderr=subprocess.DEVNULL)
enc=lambda data:base64.urlsafe_b64encode(data[-32:]).decode().rstrip("=")
print("PrivateKey: "+enc(a));print("Password (PublicKey): "+enc(b))
KEYS
chmod 0700 "$scratch/key-core"
export XRAY_BIN="$scratch/key-core"
cat > "$XM_BIN" <<'CORE'
#!/usr/bin/env bash
[[ ${TEST_NATIVE_FAIL:-0} != 1 ]]
CORE
chmod 0755 "$XM_BIN"
platform_detect() { return 0; }
TEST_RUNNING=1; TEST_HEALTH_FAIL=0; TEST_CONFIRM=1; TEST_RACE=0; TEST_PORT_CHECKS=0
platform_service() { case $1 in status) [[ $TEST_RUNNING == 1 ]] ;; stop) TEST_RUNNING=0 ;; start|restart) TEST_RUNNING=1 ;; *) return 1 ;; esac; }
platform_health() { if ((TEST_HEALTH_FAIL > 0)); then TEST_HEALTH_FAIL=$((TEST_HEALTH_FAIL-1)); return 1; fi; [[ $TEST_RUNNING == 1 ]]; }
platform_port_available() { TEST_PORT_CHECKS=$((TEST_PORT_CHECKS+1)); [[ $1 != 29000 ]]; }
xm_confirm() {
    [[ -z $XM_LOCK_FD ]] || fail 'human confirmation still holds lock'
    if [[ $TEST_RACE == 1 ]]; then
        jq '.nodes[0].name="concurrent-edit"' "$XM_STATE" > "$scratch/race-state"
        mv "$scratch/race-state" "$XM_STATE"
        protocol_generate "$XM_STATE" "$XM_CONFIG" || fail 'race config fixture'
    fi
    [[ $TEST_CONFIRM == 1 ]]
}
protocol_new shadowsocks ss-one 'SS one' 28001 8.8.8.8 > "$scratch/ss.json" || fail 'SS fixture'
protocol_new vless-reality reality-one 'REALITY one' 28002 8.8.4.4 www.cloudflare.com www.cloudflare.com:443 > "$scratch/reality.json" || fail 'REALITY fixture'
protocol_new vless-xhttp xhttp-one 'XHTTP one' 28003 1.1.1.1 www.cloudflare.com www.cloudflare.com:443 /fixture-path packet-up > "$scratch/xhttp.json" || fail 'XHTTP fixture'
command jq -n --slurpfile a "$scratch/ss.json" --slurpfile b "$scratch/reality.json" --slurpfile c "$scratch/xhttp.json" '{schema_version:1,core_version:"v26.3.27",nodes:[$a[0],$b[0],$c[0]]}' > "$XM_STATE"
protocol_generate "$XM_STATE" "$XM_CONFIG" || fail 'initial config'
cp "$XM_STATE" "$scratch/original-state"
# Intercept actual jq argv while delegating unchanged to the real executable.
# Known credentials must travel via stdin/private files, never a child argv.
mapfile -t TEST_SECRET_VALUES < <(command jq -r '.nodes[]|.password,.private_key,.public_key,.uuid,.short_id|select(type=="string")' "$XM_STATE")
jq() {
    local argument secret
    for argument in "$@"; do
        for secret in "${TEST_SECRET_VALUES[@]}"; do
            [[ $argument != *"$secret"* ]] || { printf 'FAIL: credential exposed in child jq argv\n' >&2; return 90; }
        done
    done
    printf '.\n' >> "$scratch/jq-argv-checks"
    command jq "$@"
}
other_before=$(jq -c '.nodes[1:]' "$XM_STATE")
xm_dispatch edit ss-one name 'Renamed SS' || fail 'rename'
[[ $(jq -r '.nodes[0].name' "$XM_STATE") == 'Renamed SS' && $(jq -c '.nodes[1:]' "$XM_STATE") == "$other_before" && $TEST_PORT_CHECKS == 0 ]] || fail 'rename altered other nodes or checked own listener'
xm_dispatch edit ss-one port 28011 || fail 'free new port'
[[ $TEST_PORT_CHECKS == 2 ]] || fail 'new port not checked both before and under save lock'
xm_dispatch edit ss-one address 2001:db8::3 || fail 'IPv6 edit'
protocol_new shadowsocks fresh fresh 29999 localhost > "$scratch/fresh-ss"
pw=$(jq -r .password "$scratch/fresh-ss")
TEST_SECRET_VALUES+=("$pw" "70f3d700-983a-4f3d-900e-7342b3b614e5" a4b7)
xm_dispatch edit ss-one password "$pw" || fail 'SS password edit'
xm_dispatch edit reality-one sni www.example.com || fail 'SNI edit'
xm_dispatch edit reality-one target www.example.com:443 || fail 'target edit'
xm_dispatch edit reality-one uuid 70f3d700-983a-4f3d-900e-7342b3b614e5 || fail 'UUID edit'
xm_dispatch edit reality-one shortid a4b7 || fail 'shortID alias edit'
protocol_new vless-reality fresh fresh 29998 localhost www.cloudflare.com www.cloudflare.com:443 > "$scratch/fresh-reality" || fail 'pair fixture'
private=$(jq -r .private_key "$scratch/fresh-reality"); public=$(jq -r .public_key "$scratch/fresh-reality")
TEST_SECRET_VALUES+=("$private" "$public")
xm_dispatch edit reality-one keys "$private" "$public" || fail 'valid new key pair rejected'
xm_dispatch edit xhttp-one path /changed-path || fail 'XHTTP path edit'
xm_dispatch edit xhttp-one mode stream-one || fail 'XHTTP mode edit'
state_validate "$XM_STATE" || fail 'edited state invalid'
pass 'three protocol edits preserve identity/other nodes, skip own port, accept fresh matched keys'

reject_edit() {
    cp "$XM_STATE" "$scratch/reject-state"; cp "$XM_CONFIG" "$scratch/reject-config"
    if xm_dispatch edit "$@" > /dev/null 2>&1; then fail "invalid edit accepted: $1 $2"; fi
    cmp "$XM_STATE" "$scratch/reject-state" && cmp "$XM_CONFIG" "$scratch/reject-config" || fail 'invalid edit changed active bytes'
}
for field in id type schema_version unknown method private_key public_key; do reject_edit ss-one "$field" bad; done
reject_edit ss-one uuid 70f3d700-983a-4f3d-900e-7342b3b614e5
reject_edit reality-one path /not-supported
reject_edit xhttp-one password secret
for port in 0 65536 02800 '2800;id' 29000 28002; do reject_edit ss-one port "$port"; done
reject_edit ss-one name 'REALITY one'
reject_edit ss-one address 'bad/path'
reject_edit ss-one name $'bad\033[31m'
reject_edit ss-one password AAAAA
reject_edit reality-one uuid invalid
reject_edit reality-one short_id abc
reject_edit xhttp-one mode invalid
reject_edit xhttp-one path '/bad?query'
reject_edit xhttp-one path '/bad//path'
reject_edit reality-one keys "$private" "$(jq -r .public_key "$scratch/xhttp.json")"
reject_edit xhttp-one keys "$private" "$public"
reject_edit xhttp-one uuid "$(jq -r '.nodes[1].uuid' "$XM_STATE")"
pass 'protocol whitelist, injection/control/invalid formats, port/name/secret conflicts and mismatched pairs reject without writes'

TEST_CONFIRM=0
reject_edit ss-one name cancelled
TEST_CONFIRM=1
export TEST_NATIVE_FAIL=1
reject_edit ss-one name native-rejected
unset TEST_NATIVE_FAIL
TEST_HEALTH_FAIL=1
reject_edit ss-one name unhealthy
[[ $TEST_RUNNING == 1 ]] || fail 'health rollback lost service state'
TEST_RUNNING=0
xm_dispatch edit ss-one name 'Stopped SS' || fail 'stopped edit'
[[ $TEST_RUNNING == 0 ]] || fail 'edit started stopped service'
TEST_RUNNING=1; TEST_RACE=1
if xm_dispatch edit ss-one name stale-save >/dev/null 2>&1; then fail 'concurrent changed node overwritten'; fi
[[ $(jq -r '.nodes[0].name' "$XM_STATE") == concurrent-edit ]] || fail 'stale save overwrote newer node'
TEST_RACE=0
pass 'confirmation cancel, native/health failure rollback, stopped-core preservation and concurrent snapshot rejection'

# Menu tests use the same real save path and retain the displayed exact snapshot.
node=$(jq -c '.nodes[0]' "$XM_STATE")
XM_SELECTED_NODE=$node
printf 'Menu name\nY\n' > "$scratch/input"
xm_menu_edit "$node" name < "$scratch/input" > /dev/null 2> "$scratch/menu.log" || fail 'menu rename'
[[ $(jq -r '.nodes[0].name' "$XM_STATE") == 'Menu name' ]] || fail 'menu rename not saved'
XM_SELECTED_NODE=$(jq -c '.nodes[0]' "$XM_STATE")
printf '3\n\n' > "$scratch/input"
xm_menu_edit "$XM_SELECTED_NODE" < "$scratch/input" > /dev/null 2> "$scratch/secret.log" || fail 'Enter keep SS secret'
if grep -Fq "$pw" "$scratch/secret.log"; then fail 'menu secret default leaked'; fi
printf '3\n:q\n' > "$scratch/input"
if xm_menu_edit "$XM_SELECTED_NODE" < "$scratch/input" >/dev/null 2>&1; then fail 'menu secret cancel accepted'; fi
[[ -s $scratch/jq-argv-checks ]] || fail 'jq credential argv interception did not run'
pass 'menu saves confirmed rename, keeps hidden secret on Enter and cancels without mutation'
# Editing REALITY keys in the menu collects and validates both halves together.
protocol_new vless-reality pair-menu 'pair menu' 29997 localhost www.cloudflare.com www.cloudflare.com:443 > "$scratch/menu-pair" || fail 'menu pair fixture'
menu_private=$(jq -r .private_key "$scratch/menu-pair"); menu_public=$(jq -r .public_key "$scratch/menu-pair")
TEST_SECRET_VALUES+=("$menu_private" "$menu_public")
XM_SELECTED_NODE=$(jq -c '.nodes[1]' "$XM_STATE")
printf '7\n%s\n%s\nY\n' "$menu_private" "$menu_public" > "$scratch/input"
xm_menu_edit "$XM_SELECTED_NODE" < "$scratch/input" > /dev/null 2> "$scratch/menu-pair.log" || fail 'menu matched pair edit'
[[ $(jq -r '.nodes[1].private_key' "$XM_STATE") == "$menu_private" && $(jq -r '.nodes[1].public_key' "$XM_STATE") == "$menu_public" ]] || fail 'menu pair not saved'
if grep -Fq "$menu_private" "$scratch/menu-pair.log"; then fail 'menu pair leaked private key'; fi
pass 'CLI and menu pair/password/full-node jq processing keeps credentials out of child argv'
