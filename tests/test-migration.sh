#!/usr/bin/env bash
# Portable migration and dual-core transaction tests use authoritative protocol
# validators/generators. Core execution and init are mocked, never called native.
set -u
if (( BASH_VERSINFO[0]<4 || (BASH_VERSINFO[0]==4 && BASH_VERSINFO[1]<4) )); then exit 77; fi
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
scratch=$(mktemp -d)
export XM_ROOT="$scratch/root"
source "$repo/xray-manager.sh"
trap 'state_exit_cleanup $?; rm -rf -- "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
mkdir -p "$XM_HOME/bin" "$XM_ETC" "$XM_DATA" "$XM_LOG"
for directory in "$XM_HOME" "$XM_ETC" "$XM_DATA" "$XM_LOG"; do printf 'xray-manager:1\n' > "$directory/.xray-manager-owned"; done
for core in "$XM_BIN" "$XM_EXTRA_BIN"; do
    cat > "$core" <<'CORE'
#!/usr/bin/env bash
if [[ $0 == */sing-box ]]; then [[ ${TEST_EXTRA_NATIVE_FAIL:-0} != 1 ]]; else [[ ${TEST_MAIN_NATIVE_FAIL:-0} != 1 ]]; fi
CORE
    chmod 0755 "$core"
done
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$scratch/key.pem" -out "$scratch/cert.pem" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' -days 2 >/dev/null 2>&1 || fail 'certificate fixture'
chmod 0600 "$scratch/key.pem"
protocol_new shadowsocks ss 'SS' 27001 127.0.0.1 > "$scratch/ss" || fail 'SS fixture'
protocol_new anytls at 'AnyTLS' 27002 127.0.0.1 localhost "$scratch/cert.pem" "$scratch/key.pem" > "$scratch/at" || fail 'AnyTLS fixture'
protocol_new vless-ws ws 'VLESS WS' 27003 127.0.0.1 localhost /test-ws "$scratch/cert.pem" "$scratch/key.pem" > "$scratch/ws" || fail 'WS fixture'
jq -n --slurpfile a "$scratch/ss" --slurpfile b "$scratch/at" --slurpfile c "$scratch/ws" '{schema_version:1,core_version:"v26.3.27",nodes:[$a[0],$b[0],$c[0]]}' > "$scratch/portable"
platform_detect() { return 0; }
platform_extra_ensure() { return 0; }
platform_extra_install_service() { return 0; }
platform_extra_installed() { return 0; }
platform_extra_discard_new() { return 0; }
TEST_MAIN=1; TEST_EXTRA=1; TEST_EXTRA_ENABLED=1; TEST_FAIL_EXTRA_HEALTH=0; TEST_CONFIRM=1; TEST_RACE=0
platform_service() { case $1 in status) [[ $TEST_MAIN == 1 ]] ;; start|restart) TEST_MAIN=1 ;; stop) TEST_MAIN=0 ;; enable|disable) return 0 ;; *) return 1 ;; esac; }
platform_extra_service() { case $1 in status) [[ $TEST_EXTRA == 1 ]] ;; start|restart) TEST_EXTRA=1 ;; stop) TEST_EXTRA=0 ;; enable) TEST_EXTRA_ENABLED=1 ;; disable) TEST_EXTRA_ENABLED=0 ;; *) return 1 ;; esac; }
platform_extra_enabled() { [[ $TEST_EXTRA_ENABLED == 1 ]]; }
platform_health() { [[ $TEST_MAIN == 1 ]]; }
platform_extra_health() { if ((TEST_FAIL_EXTRA_HEALTH>0)); then TEST_FAIL_EXTRA_HEALTH=$((TEST_FAIL_EXTRA_HEALTH-1)); return 1; fi; [[ $TEST_EXTRA == 1 ]]; }
xm_confirm() {
    [[ -z $XM_LOCK_FD ]] || fail 'migration confirmation holds lock'
    if [[ $TEST_RACE == 1 ]]; then jq '.nodes[0].name="newer"' "$XM_STATE" > "$scratch/race"; mv "$scratch/race" "$XM_STATE"; fi
    [[ $TEST_CONFIRM == 1 ]]
}
reset_state() {
    cp "$scratch/portable" "$XM_STATE"
    protocol_generate "$XM_STATE" "$XM_CONFIG" && protocol_generate_extra "$XM_STATE" "$XM_EXTRA_CONFIG" || fail 'fixture config'
    TEST_MAIN=1; TEST_EXTRA=1; TEST_EXTRA_ENABLED=1
}
reset_state
xm_dispatch export "$scratch/export.json" > "$scratch/stdout" 2> "$scratch/export.log" || fail 'export'
[[ ! -s $scratch/stdout && $(stat -c %a "$scratch/export.json") == 600 ]] || fail 'export stream/mode'
cmp "$XM_STATE" "$scratch/export.json" || fail 'export lost nodes/PEM'
grep -q "$scratch/export.json" "$scratch/export.log" && grep -q '节点 3' "$scratch/export.log" || fail 'export path/count missing'
if xm_dispatch export "$scratch/export.json" >/dev/null 2>&1; then fail 'export overwrote existing file'; fi
ln -s "$scratch/foreign" "$scratch/export-link"
if xm_dispatch export "$scratch/export-link" >/dev/null 2>&1; then fail 'export symlink accepted'; fi
[[ ! -e $scratch/foreign ]] || fail 'export touched symlink target'
# The exported PEM is sufficient after the original source files disappear.
rm -f "$scratch/cert.pem" "$scratch/key.pem"
jq '.core_version="v1.2.3"' "$scratch/export.json" > "$scratch/import.json"
xm_dispatch import "$scratch/import.json" >/dev/null 2> "$scratch/import.log" || fail 'portable PEM import'
[[ $(jq -r .core_version "$XM_STATE") == v26.3.27 && $TEST_MAIN == 1 && $TEST_EXTRA == 1 ]] || fail 'import changed core/running states'
grep -q '节点数：3' "$scratch/import.log" || fail 'import summary missing'
pass '0600 export includes all portable PEM, reports path/count, refuses overwrite and imports without source cert files'

reject_import() {
    cp "$XM_STATE" "$scratch/before-state"; cp "$XM_CONFIG" "$scratch/before-main"; cp "$XM_EXTRA_CONFIG" "$scratch/before-extra"
    if xm_dispatch import "$1" >/dev/null 2>&1; then fail 'invalid import accepted'; fi
    cmp "$XM_STATE" "$scratch/before-state" && cmp "$XM_CONFIG" "$scratch/before-main" && cmp "$XM_EXTRA_CONFIG" "$scratch/before-extra" || fail 'failed import changed active data'
}
jq '.nodes[1].name=.nodes[0].name' "$scratch/import.json" > "$scratch/invalid"
reject_import "$scratch/invalid"
jq '.nodes[1].password="short"' "$scratch/import.json" > "$scratch/invalid"
reject_import "$scratch/invalid"
jq '.nodes[1].type="unknown"' "$scratch/import.json" > "$scratch/invalid"
reject_import "$scratch/invalid"
TEST_CONFIRM=0; reject_import "$scratch/import.json"; TEST_CONFIRM=1
export TEST_EXTRA_NATIVE_FAIL=1; reject_import "$scratch/import.json"; unset TEST_EXTRA_NATIVE_FAIL
TEST_FAIL_EXTRA_HEALTH=1; reject_import "$scratch/import.json"
[[ $TEST_MAIN == 1 && $TEST_EXTRA == 1 ]] || fail 'extra health rollback lost independent services'
TEST_MAIN=0; TEST_EXTRA=1
xm_dispatch import "$scratch/import.json" >/dev/null 2>&1 || fail 'independently running extra import'
[[ $TEST_MAIN == 0 && $TEST_EXTRA == 1 ]] || fail 'import started stopped main'
TEST_MAIN=1; TEST_EXTRA=0
xm_dispatch import "$scratch/import.json" >/dev/null 2>&1 || fail 'main-only running import'
[[ $TEST_MAIN == 1 && $TEST_EXTRA == 0 ]] || fail 'import started independently stopped existing extra'
TEST_MAIN=0; TEST_EXTRA=0
xm_dispatch import "$scratch/import.json" >/dev/null 2>&1 || fail 'stopped import'
[[ $TEST_MAIN == 0 && $TEST_EXTRA == 0 ]] || fail 'import started stopped cores'
TEST_RACE=1
if xm_dispatch import "$scratch/import.json" >/dev/null 2>&1; then fail 'import overwrote concurrent update'; fi
[[ $(jq -r '.nodes[0].name' "$XM_STATE") == newer ]] || fail 'import lost concurrent edit'
TEST_RACE=0
pass 'schema/protocol/duplicates/cancel reject, extra native/health rollback, independent/stopped states and concurrent snapshot hold'

reset_state
jq '.nodes|=map(select(.type!="anytls"))' "$XM_STATE" > "$scratch/main-only"
xm_dispatch import "$scratch/main-only" >/dev/null 2>&1 || fail 'remove last extra node'
[[ $TEST_MAIN == 1 && $TEST_EXTRA == 0 && $TEST_EXTRA_ENABLED == 0 ]] || fail 'last extra removal did not stop/disable extra'
xm_dispatch import "$scratch/import.json" >/dev/null 2>&1 || fail 'add first extra via import'
[[ $TEST_MAIN == 1 && $TEST_EXTRA == 1 && $TEST_EXTRA_ENABLED == 1 ]] || fail 'first extra did not follow running main'
# Scheduled restart must not activate either independently stopped core.
TEST_MAIN=0; TEST_EXTRA=1
xm_dispatch scheduled-restart >/dev/null 2>&1 || fail 'extra-only schedule'
[[ $TEST_MAIN == 0 && $TEST_EXTRA == 1 ]] || fail 'schedule started main'
TEST_MAIN=1; TEST_EXTRA=0
xm_dispatch scheduled-restart >/dev/null 2>&1 || fail 'main-only schedule'
[[ $TEST_MAIN == 1 && $TEST_EXTRA == 0 ]] || fail 'schedule started extra'
pass 'first/last extra lifecycle and scheduled restart respect independent running states'
# Renew a portable TLS pair in one draft; a mismatched private key must fail.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$scratch/renew-key.pem" -out "$scratch/renew-cert.pem" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' -days 3 >/dev/null 2>&1 || fail 'renewal fixture'
chmod 0600 "$scratch/renew-key.pem"
old_password=$(jq -r '.nodes[]|select(.id=="at")|.password' "$XM_STATE")
xm_dispatch edit at tls "$scratch/renew-cert.pem" "$scratch/renew-key.pem" localhost >/dev/null 2>&1 || fail 'TLS pair renewal'
[[ $(jq -r '.nodes[]|select(.id=="at")|.password' "$XM_STATE") == "$old_password" ]] || fail 'renewal changed credentials'
state_validate "$XM_STATE" || fail 'renewed state invalid'
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$scratch/wrong-key.pem" >/dev/null 2>&1 || fail 'wrong key fixture'
chmod 0600 "$scratch/wrong-key.pem"
cp "$XM_STATE" "$scratch/before-renewal"
if xm_dispatch edit at tls "$scratch/renew-cert.pem" "$scratch/wrong-key.pem" localhost >/dev/null 2>&1; then fail 'mismatched TLS pair accepted'; fi
cmp "$XM_STATE" "$scratch/before-renewal" || fail 'failed TLS renewal changed state'
pass 'TLS renewal validates matching certificate/key together and preserves credentials'
