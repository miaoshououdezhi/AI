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
grep -q '\[ 1\].*\[ 2\]' "$TEST_ROOT/wide.log" || fail 'wide menu not two columns'
if grep -q '\[ 1\].*\[ 2\]' "$TEST_ROOT/narrow.log"; then fail 'narrow menu still two columns'; fi
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
