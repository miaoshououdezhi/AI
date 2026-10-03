#!/usr/bin/env bash
# Interaction regressions use real protocol validators and mock only external
# discovery/service mutation. No network queries or actual service operations.
set -u
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then printf 'SKIP: Bash >=4.4 required\n' >&2; exit 77; fi
TEST_REPO=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d)
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
export XM_ROOT=$TEST_ROOT/root
# shellcheck source=../xray-manager.sh
source "$TEST_REPO/xray-manager.sh"
trap 'state_exit_cleanup $?; rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
mkdir -p "$XM_ETC"
state_empty v26.3.27 > "$XM_STATE"
# Mock only the external core key-generation command; OpenSSL produces fresh
# cryptographically valid X25519 pairs, then real protocol validators check them.
# Real Xray native/transport checks are in tests/test-xhttp.sh, not this fixture.
cat > "$TEST_ROOT/key-core" <<'KEYCORE'
#!/usr/bin/env python3
import base64,subprocess,sys
if sys.argv[1:] != ["x25519"]:
    sys.exit(2)
private=subprocess.check_output(["openssl","genpkey","-algorithm","X25519","-outform","DER"],stderr=subprocess.DEVNULL)
public=subprocess.check_output(["openssl","pkey","-inform","DER","-pubout","-outform","DER"],input=private,stderr=subprocess.DEVNULL)
def encode(data):return base64.urlsafe_b64encode(data[-32:]).decode().rstrip("=")
print("PrivateKey: "+encode(private))
print("Password (PublicKey): "+encode(public))
KEYCORE
chmod 0700 "$TEST_ROOT/key-core"
export XRAY_BIN="$TEST_ROOT/key-core"
TEST_CALL="$TEST_ROOT/call.json"
TEST_READY_FAIL=0; TEST_IP_FAIL=0; TEST_PORT_FAIL=0; TEST_RELEASE_FAIL=0
xm_ready() { [[ $TEST_READY_FAIL == 0 ]]; }
platform_random_port() { [[ $TEST_PORT_FAIL == 0 ]] || return 1; printf '25001\n'; }
platform_port_available() { [[ $1 != 25002 ]]; }
platform_public_ip() { [[ $TEST_IP_FAIL == 0 ]] || return 1; printf '8.8.8.8\n'; }
platform_release_choices() {
    [[ $TEST_RELEASE_FAIL == 0 ]] || return 1
    printf 'stable\tv26.10.2\t2026-10-02T06:00:00Z\nstable\tv26.9.1\t2026-09-01T10:00:00Z\npreview\tv26.10.3\t2026-10-03T07:00:00Z\npreview\tv26.10.1\t2026-10-01T11:00:00Z\n'
}
xm_dispatch() { jq -n --args '$ARGS.positional' "$@" > "$TEST_CALL"; }

printf '3\n\n\n\n\n\n' > "$TEST_ROOT/input"
xm_menu_add < "$TEST_ROOT/input" > "$TEST_ROOT/stdout" 2> "$TEST_ROOT/default.log" || fail 'default SS creation'
jq -e '.[0]=="add" and .[1]=="shadowsocks" and (.[2]|test("^node-[0-9a-f]{8}$")) and (.[3]|test("^SS2022-[0-9a-f]{8}$")) and .[4]=="25001" and .[5]=="8.8.8.8"' "$TEST_CALL" >/dev/null || fail 'random defaults not accepted'
mapfile -t TEST_ARGS < <(jq -r '.[]' "$TEST_CALL")
protocol_new "${TEST_ARGS[@]:1}" > "$TEST_ROOT/node.json" || fail 'generated default node invalid'
TEST_PASSWORD=$(jq -r .password "$TEST_ROOT/node.json")
if grep -Fq "$TEST_PASSWORD" "$TEST_ROOT/default.log" "$TEST_ROOT/stdout"; then fail 'default secret leaked'; fi
pass 'Enter accepts random ID/name/free port/secret and discovers public IP without leaking secret'

printf '3\n--invalid\ncustom-a\nname\n0\n25002\n25001\nbad/path\n8.8.4.4\nshort\n\n' > "$TEST_ROOT/input"
xm_menu_add < "$TEST_ROOT/input" > "$TEST_ROOT/stdout" 2> "$TEST_ROOT/retry.log" || fail 'field validation retries'
jq -e '.[2]=="custom-a" and .[3]=="name" and .[4]=="25001" and .[5]=="8.8.4.4"' "$TEST_CALL" >/dev/null || fail 'retry accepted wrong fields'
grep -q '端口' "$TEST_ROOT/retry.log" && grep -q 'ID' "$TEST_ROOT/retry.log" || fail 'missing immediate field feedback'
pass 'invalid ID, zero/occupied port, address and SS password re-prompt their field'

TEST_IP_FAIL=1; TEST_PORT_FAIL=1
printf '3\n\n\n25001\n\n8.8.4.4\n\n' > "$TEST_ROOT/input"
xm_menu_add < "$TEST_ROOT/input" > "$TEST_ROOT/stdout" 2> "$TEST_ROOT/fallback.log" || fail 'manual fallback after discovery failure'
jq -e '.[4]=="25001" and .[5]=="8.8.4.4"' "$TEST_CALL" >/dev/null || fail 'manual fallback values'
TEST_IP_FAIL=0; TEST_PORT_FAIL=0
pass 'public IP/random-port failure keeps manual input available'

rm -f "$TEST_CALL"
printf '3\n:q\n' > "$TEST_ROOT/input"
if xm_menu_add < "$TEST_ROOT/input" > /dev/null 2> "$TEST_ROOT/cancel.log"; then fail 'cancel unexpectedly succeeded'; fi
[[ ! -e $TEST_CALL ]] || fail 'cancel dispatched mutation'
TEST_READY_FAIL=1
if xm_menu_add < /dev/null > /dev/null 2> "$TEST_ROOT/uninstalled.log"; then fail 'uninstalled add accepted'; fi
if xm_menu_upgrade < /dev/null > /dev/null 2> "$TEST_ROOT/uninstalled.log"; then fail 'uninstalled upgrade accepted'; fi
TEST_READY_FAIL=0
pass 'cancel and missing installation cannot dispatch mutation'

# Terminal controls are rejected before printing user input back to the terminal.
printf '\033[31m\nvalid\n' > "$TEST_ROOT/input"
xm_read TEST_VALUE 'test' < "$TEST_ROOT/input" 2> "$TEST_ROOT/control.log" || fail 'control retry'
[[ $TEST_VALUE == valid ]] || fail 'terminal control accepted'
if LC_ALL=C grep -q $'\033' "$TEST_ROOT/control.log"; then fail 'input control rendered'; fi
pass 'terminal escape input is rejected without ANSI injection'

printf '3\nyes\n' > "$TEST_ROOT/input"
xm_menu_upgrade < "$TEST_ROOT/input" > /dev/null 2> "$TEST_ROOT/upgrade.log" || fail 'preview choice'
jq -e '.[0]=="upgrade" and .[1]=="v26.10.3"' "$TEST_CALL" >/dev/null || fail 'preview choice dispatched wrong version'
[[ $(grep -c '发布：' "$TEST_ROOT/upgrade.log") == 4 ]] || fail 'four release timestamps not shown'
grep -q '预览版' "$TEST_ROOT/upgrade.log" && grep -q '正式版' "$TEST_ROOT/upgrade.log" || fail 'release channels missing'
rm -f "$TEST_CALL"
export XM_YES=1
printf '1\n\n' > "$TEST_ROOT/input"
if xm_menu_upgrade < "$TEST_ROOT/input" > /dev/null 2> "$TEST_ROOT/decline.log"; then fail 'upgrade Enter confirmation accepted'; fi
[[ ! -e $TEST_CALL ]] || fail 'upgrade without second confirmation dispatched'
export XM_YES=0
TEST_RELEASE_FAIL=1
printf 'm\ninvalid\nv26.8.1\nyes\n' > "$TEST_ROOT/input"
xm_menu_upgrade < "$TEST_ROOT/input" > /dev/null 2> "$TEST_ROOT/manual.log" || fail 'release failure/manual fallback'
jq -e '.[0]=="upgrade" and .[1]=="v26.8.1"' "$TEST_CALL" >/dev/null || fail 'manual version not dispatched'
printf '0\n' > "$TEST_ROOT/input"
xm_menu_upgrade < "$TEST_ROOT/input" > /dev/null 2> "$TEST_ROOT/return.log" || fail 'release failure return'
if xm_menu_upgrade < /dev/null > /dev/null 2> "$TEST_ROOT/eof.log"; then fail 'upgrade EOF unexpectedly succeeded'; fi
TEST_RELEASE_FAIL=0
pass 'four releases/dates, explicit second confirmation, manual fallback, return and EOF'

xm_ui_init
COLUMNS=80 xm_menu_render 2> "$TEST_ROOT/wide.log"
COLUMNS=40 xm_menu_render 2> "$TEST_ROOT/narrow.log"
[[ $(wc -l < "$TEST_ROOT/wide.log") -le 28 ]] || fail 'wide menu exceeds 28 lines'
grep -q '\[1\].*\[2\]' "$TEST_ROOT/wide.log" || fail 'wide menu not two columns'
if grep -q '\[1\].*\[2\]' "$TEST_ROOT/narrow.log"; then fail 'narrow menu still two columns'; fi
if LC_ALL=C grep -q $'\033' "$TEST_ROOT/wide.log"; then fail 'non-TTY contains ANSI'; fi
pass 'wide menu fits 28 lines, narrow menu uses one column, non-TTY output is plain'

# Real PTYs verify the TTY gate, NO_COLOR presence, and TERM=dumb behavior.
python3 - "$TEST_REPO" <<'PY'
import errno,fcntl,os,pty,struct,subprocess,sys,termios
repo=sys.argv[1]
for mode,expected,width in [('color',True,40),('no_color',False,40),('dumb',False,40),('explicit_columns',True,80),('invalid_columns',True,40),('zero_size',True,80)]:
    master,slave=pty.openpty(); env=dict(os.environ); env['TERM']='xterm-256color'; env.pop('NO_COLOR',None); env.pop('COLUMNS',None)
    fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',24,0 if mode=='zero_size' else 40,0,0))
    if mode=='explicit_columns':env['COLUMNS']='80'
    if mode=='invalid_columns':env['COLUMNS']='invalid'
    if mode=='no_color':env['NO_COLOR']=''
    if mode=='dumb':env['TERM']='dumb'
    child=subprocess.Popen(['bash','-c','source "$1/lib/common.sh"; xm_ui_init; xm_ui_heading "Heading"; printf "WIDTH=%s\\n" "$(xm_terminal_width)" >&2','--',repo],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=slave,env=env)
    os.close(slave); data=b''
    while True:
        try:
            block=os.read(master,4096)
            if not block:break
            data+=block
        except OSError as error:
            if error.errno==errno.EIO:break
            raise
    os.close(master)
    assert child.wait()==0
    assert (b'\x1b[' in data)==expected, (mode,data)
    assert ('WIDTH=%s'%width).encode() in data, (mode,data)
print('PASS real PTY colors, NO_COLOR="", TERM=dumb, stty width, COLUMNS precedence/fallback')
PY
[[ $? == 0 ]] || fail 'PTY style checks'
# Selection menus display every node and act by stable ID rather than array index.
TEST_NODE_A=$(protocol_new shadowsocks first 'First SS' 26001 8.8.8.8) || fail 'fixture A'
TEST_NODE_B=$(protocol_new shadowsocks second 'Second SS' 26002 8.8.4.4) || fail 'fixture B'
jq --argjson a "$TEST_NODE_A" --argjson b "$TEST_NODE_B" '.nodes=[$a,$b]' "$XM_STATE" > "$TEST_ROOT/state.new"
mv "$TEST_ROOT/state.new" "$XM_STATE"
printf '9\n2\n' > "$TEST_ROOT/input"
xm_menu_node share < "$TEST_ROOT/input" > "$TEST_ROOT/stdout" 2> "$TEST_ROOT/select.log" || fail 'share numbered selection'
jq -e '.[0]=="share" and .[1]=="second"' "$TEST_CALL" >/dev/null || fail 'share selection wrong ID'
grep -q '\[1\].*First SS.*ss2022' "$TEST_ROOT/select.log" && grep -q '请输入 1..2' "$TEST_ROOT/select.log" || fail 'selection list/type/retry missing'
printf '1\n0\n' > "$TEST_ROOT/input"
xm_menu_node view < "$TEST_ROOT/input" > "$TEST_ROOT/view.json" 2> "$TEST_ROOT/view.log" || fail 'view numbered selection'
grep -q 'ID first' "$TEST_ROOT/view.log" || fail 'view wrong node'
if grep -Fq "$(jq -r .password <<< "$TEST_NODE_A")" "$TEST_ROOT/view.log" "$TEST_ROOT/view.json"; then fail 'view leaked secret'; fi
printf '2\n' > "$TEST_ROOT/input"
xm_menu_node delete < "$TEST_ROOT/input" > /dev/null 2> "$TEST_ROOT/delete.log" || fail 'delete numbered selection'
jq -e '.[0]=="delete" and .[1]=="second"' "$TEST_CALL" >/dev/null || fail 'delete selection wrong ID'
rm -f "$TEST_CALL"
printf '0\n' > "$TEST_ROOT/input"
xm_menu_node share < "$TEST_ROOT/input" > /dev/null 2> /dev/null || fail 'selection return'
[[ ! -e $TEST_CALL ]] || fail 'return dispatched selection'
if xm_menu_node share < /dev/null > /dev/null 2> /dev/null; then fail 'selection EOF accepted'; fi
# Inject a concurrent edit precisely when selection attempts its under-lock recheck.
TEST_READY_COUNT=0
xm_ready() {
    TEST_READY_COUNT=$((TEST_READY_COUNT+1))
    if ((TEST_READY_COUNT == 2)); then
        jq '.nodes[0].name="Changed"' "$XM_STATE" > "$TEST_ROOT/concurrent"
        mv "$TEST_ROOT/concurrent" "$XM_STATE"
    fi
    return 0
}
printf '1\n' > "$TEST_ROOT/input"
if xm_menu_node share < "$TEST_ROOT/input" > /dev/null 2> "$TEST_ROOT/stale.log"; then fail 'stale node selected'; fi
[[ ! -e $TEST_CALL ]] || fail 'stale selection dispatched mutation'
grep -q '已变化' "$TEST_ROOT/stale.log" || fail 'stale selection missing feedback'
xm_ready() { [[ $TEST_READY_FAIL == 0 ]]; }
state_empty v26.3.27 > "$XM_STATE"
pass 'numbered view/share/delete select stable IDs, hide view secrets and reject stale snapshots/EOF'

for TEST_REPLY in y Y yes YES YeS; do xm_yes "$TEST_REPLY" || fail 'confirmation case rejected'; done
for TEST_REPLY in '' n no true 'yes '; do if xm_yes "$TEST_REPLY"; then fail 'invalid confirmation accepted'; fi; done
pass 'y/yes confirmation accepts any case and rejects other values'

printf '2\n\n\n\n\n\n\n\n\n' > "$TEST_ROOT/input"
xm_menu_add < "$TEST_ROOT/input" > /dev/null 2> "$TEST_ROOT/xhttp.log" || fail 'XHTTP default interaction'
jq -e '.[1]=="vless-xhttp" and (.[8]|test("^/[0-9a-f]{16}$")) and .[9]=="packet-up"' "$TEST_CALL" >/dev/null || fail 'XHTTP draft arguments'
mapfile -t TEST_ARGS < <(jq -r '.[]' "$TEST_CALL")
protocol_new "${TEST_ARGS[@]:1}" > "$TEST_ROOT/xhttp.json" || fail 'XHTTP draft invalid'
if grep -q 'Trojan TLS' "$TEST_ROOT/xhttp.log"; then fail 'Trojan still offered for new nodes'; fi
TEST_FIRST_XHTTP=$(cat "$TEST_ROOT/xhttp.json")
printf '2\n\n\n\n\n\n\n\n\n' > "$TEST_ROOT/input"
xm_menu_add < "$TEST_ROOT/input" > /dev/null 2> /dev/null || fail 'second XHTTP interaction'
mapfile -t TEST_ARGS < <(jq -r '.[]' "$TEST_CALL")
TEST_SECOND_XHTTP=$(protocol_new "${TEST_ARGS[@]:1}") || fail 'second XHTTP node'
[[ $(jq -r .id <<< "$TEST_FIRST_XHTTP") != "$(jq -r .id <<< "$TEST_SECOND_XHTTP")" && $(jq -r .path <<< "$TEST_FIRST_XHTTP") != "$(jq -r .path <<< "$TEST_SECOND_XHTTP")" && $(jq -r .uuid <<< "$TEST_FIRST_XHTTP") != "$(jq -r .uuid <<< "$TEST_SECOND_XHTTP")" ]] || fail 'random defaults repeat'
jq --argjson node "$TEST_FIRST_XHTTP" '.nodes=[$node]' "$XM_STATE" > "$TEST_ROOT/state.new"; mv "$TEST_ROOT/state.new" "$XM_STATE"
if xm_node_unique_secrets "$TEST_FIRST_XHTTP" >/dev/null 2>&1; then fail 'colliding credentials/path accepted'; fi
xm_node_unique_secrets "$TEST_SECOND_XHTTP" || fail 'independent random keys rejected'
state_empty v26.3.27 > "$XM_STATE"
pass 'XHTTP REALITY defaults validate, change per request and reject reused path/credentials'

# Use the real dispatcher/schedule functions, replacing only platform effects.
# shellcheck disable=SC1090
source <(sed -n '/^xm_dispatch() {/,/^}/p' "$TEST_REPO/xray-manager.sh")
TEST_CHECK_LOCK=0
platform_restart_schedule() {
    if [[ $TEST_CHECK_LOCK == 1 && -e /proc/self/fd/$XM_LOCK_FD ]]; then fail 'scheduler platform inherited manager lock'; fi
    printf '%s\n' "$*" > "$TEST_ROOT/schedule-call"
    [[ $1 != status ]] || printf 'disabled\t-\tUTC\t-\n'
}
if [[ -d /proc/self/fd ]]; then
    exec {XM_LOCK_FD}>"$TEST_ROOT/lock-probe"
    TEST_CHECK_LOCK=1
    xm_schedule status >/dev/null || fail 'scheduler lock closure'
    [[ -e /proc/self/fd/$XM_LOCK_FD ]] || fail 'scheduler closure lost parent lock'
    TEST_CHECK_LOCK=0
    xm_unlock
    rm -f "$TEST_ROOT/schedule-call"
fi
xm_confirm() { local reply; IFS= read -r reply || return 2; xm_yes "$reply"; }
printf 'Y\n' > "$TEST_ROOT/input"
xm_dispatch schedule set 04:00 < "$TEST_ROOT/input" >/dev/null 2> /dev/null || fail 'schedule case confirmation'
[[ $(cat "$TEST_ROOT/schedule-call") == 'set 04:00' ]] || fail 'schedule arguments'
rm -f "$TEST_ROOT/schedule-call"
for TEST_TIME in 4:00 24:00 04:60 '04:00;id'; do
    if xm_dispatch schedule set "$TEST_TIME" < /dev/null >/dev/null 2>&1; then fail 'invalid schedule accepted'; fi
done
[[ ! -e $TEST_ROOT/schedule-call ]] || fail 'invalid time reached platform'
printf 'n\n' > "$TEST_ROOT/input"
if xm_dispatch schedule disable < "$TEST_ROOT/input" >/dev/null 2>&1; then fail 'schedule decline accepted'; fi
[[ ! -e $TEST_ROOT/schedule-call ]] || fail 'declined schedule reached platform'
TEST_RUNNING=0; TEST_RESTARTED=0
xm_service_call() { [[ $TEST_RUNNING == 1 ]]; }
xm_service() { TEST_RESTARTED=$((TEST_RESTARTED+1)); }
xm_dispatch scheduled-restart >/dev/null 2>&1 || fail 'stopped scheduled runner'
[[ $TEST_RESTARTED == 0 ]] || fail 'scheduled runner started stopped core'
TEST_RUNNING=1
xm_dispatch scheduled-restart >/dev/null 2>&1 || fail 'running scheduled runner'
[[ $TEST_RESTARTED == 1 ]] || fail 'scheduled runner did not restart active core'
pass 'schedule strict time, y confirmation, decline, and stopped-core skip'
