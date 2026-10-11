#!/usr/bin/env bash
# Private schedule parsing and lifecycle tests. No host init/package mutations.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/lib/platform.sh"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/xray-update-schedule-tests.XXXXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
test_dir=$(cd "$test_dir" && pwd -P)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() { if "$@" >"$test_dir/out" 2>"$test_dir/err"; then fail "unexpected success: $*"; fi; }

# Argument validation must precede any init or filesystem operation.
_platform_init_available() { fail 'unexpected init call'; }
reject platform_system_update_schedule set hourly 04:00
reject platform_system_update_schedule set daily 4:00
reject platform_system_update_schedule set weekly 24:00
reject platform_system_update_schedule set monthly 04:00 extra
reject platform_system_update_schedule disable extra
reject platform_system_update_schedule nonsense
(
    export XM_ROOT=$test_dir/sandbox-root
    reject platform_system_update_schedule set daily 04:00
    reject platform_system_update_schedule disable
    reject platform_restart_schedule set 04:00
    reject platform_restart_schedule disable
)

python3 - "$repo/assets/xray-manager-system-update.py" "$test_dir" <<'PY'
import datetime, importlib.util, pathlib, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('system_update_schedule', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
p = pathlib.Path(sys.argv[2]) / 'state'
for period in ('daily', 'weekly', 'monthly'):
    p.write_text('# xray-manager-owned:1\n' + period + '\n04:00\n')
    assert m.read_schedule(p) == (period, '04:00')
for bad in ('04:00\n', '# xray-manager-owned:1\nhourly\n04:00\n',
            '# xray-manager-owned:1\ndaily\n4:00\n',
            '# xray-manager-owned:1\ndaily\n04:00\nextra\n'):
    p.write_text(bad)
    try: m.read_schedule(p)
    except ValueError: pass
    else: raise AssertionError('invalid schedule accepted')
p.unlink(); p.symlink_to('/etc/passwd')
try: m.read_schedule(p)
except ValueError: pass
else: raise AssertionError('symlink accepted')
mon = datetime.datetime(2026, 10, 5, 4, 0, 5)
tue = mon + datetime.timedelta(days=1)
first = datetime.datetime(2026, 12, 1, 4, 0, 5)
assert m.due(mon, 'daily', '04:00', '2026-10-05 03:59', None)
assert m.due(mon, 'weekly', '04:00', '2026-10-05 03:59', None)
assert not m.due(tue, 'weekly', '04:00', '2026-10-05 03:59', None)
assert m.due(first, 'monthly', '04:00', '2026-10-05 03:59', None)
assert not m.due(mon, 'monthly', '04:00', '2026-10-05 03:59', None)
assert not m.due(mon, 'daily', '04:00', '2026-10-05 04:00', None)
assert not m.due(mon, 'daily', '04:00', '2026-10-05 03:59', mon.date())
assert not m.due(mon.replace(minute=1), 'daily', '04:00', '2026-10-05 03:59', None)
print('PASS: strict state, daily/weekly/monthly due, deduplication and no catch-up')
PY

# Status before installation is safe and reports the manual mode.
export XM_ROOT=''
XM_HOME=$test_dir/home; XM_ETC=$test_dir/absent-etc; XM_LOG=$test_dir/log
XM_INIT=systemd
_platform_paths() { return 0; }
_platform_init_available() { return 0; }
_platform_update_schedule_link() { return 0; }
_platform_update_schedule_files() {
    printf '%s\n' "$XM_ETC/system-update-schedule"
    if [[ $XM_INIT == systemd ]]; then
        printf '%s\n' "$test_dir/units/xray-manager-system-update.service" "$test_dir/units/xray-manager-system-update.timer"
    else printf '%s\n' "$test_dir/units/xray-manager-system-update"; fi
}
[[ $(platform_system_update_schedule status) == disabled$'\t'manual$'\t'-$'\t'*$'\t'- ]] || fail 'status before installation'
(
    _platform_python() { fail 'status before installation called Python'; }
    [[ $(platform_system_update_schedule status) == disabled$'\t'manual$'\t'-$'\t'*$'\t'- ]] || fail 'no-Python status before installation'
    date() { return 1; }
    [[ $(platform_system_update_schedule status) == $'disabled\tmanual\t-\t未知\t-' ]] || fail 'timezone lookup failure truncated status'
)
reject platform_system_update_schedule set daily 04:00
mkdir -p "$XM_ETC"
reject platform_system_update_schedule status
printf 'xray-manager:1\n' > "$XM_ETC/.xray-manager-owned"
mkdir -p "$XM_HOME/assets" "$XM_LOG" "$test_dir/units"
printf '#!/bin/sh\n' > "$XM_HOME/xray-manager.sh"; chmod 0755 "$XM_HOME/xray-manager.sh"

_platform_owned_file() { return 0; }
printf '# xray-manager-owned:1\ndaily\n04:00\nextra' > "$XM_ETC/system-update-schedule"
reject _platform_update_schedule_read
rm "$XM_ETC/system-update-schedule"
_platform_install_owned() {
    local target=$2
    case $target in /etc/systemd/system/*|/etc/init.d/*) target=$test_dir/units/${target##*/} ;; esac
    cp -- "$1" "$target" && chmod "$3" "$target"
}
_platform_update_schedule_enabled() { [[ -f $test_dir/enabled ]]; }
_platform_update_schedule_running() { [[ -f $test_dir/running ]]; }
_platform_update_schedule_control() {
    case $1 in
        start) if [[ -f $test_dir/fail-start ]]; then rm -f "$test_dir/fail-start"; return 1; fi; touch "$test_dir/running" ;;
        stop) rm -f "$test_dir/running" ;;
        enable) touch "$test_dir/enabled" ;;
        disable) rm -f "$test_dir/enabled" ;;
    esac
}
systemctl() {
    case $1 in daemon-reload) return 0 ;; show) printf 'Mon 2026-10-05 04:00:00 UTC\n' ;; *) fail 'unexpected systemctl' ;; esac
}
platform_system_update_schedule set daily 04:00
[[ $(_platform_update_schedule_read) == $'daily\t04:00' ]] || fail 'daily state'
[[ -f $test_dir/enabled && -f $test_dir/running ]] || fail 'daily activation'
grep -q 'OnCalendar=\*-\*-\* 04:00:00' "$test_dir/units/xray-manager-system-update.timer" || fail 'daily calendar'
platform_system_update_schedule set weekly 05:15
grep -q 'OnCalendar=Mon \*-\*-\* 05:15:00' "$test_dir/units/xray-manager-system-update.timer" || fail 'Monday calendar'
platform_system_update_schedule set monthly 06:30
grep -q 'OnCalendar=\*-\*-01 06:30:00' "$test_dir/units/xray-manager-system-update.timer" || fail 'month-first calendar'
[[ $(platform_system_update_schedule status) == enabled$'\t'monthly$'\t'06:30$'\t'* ]] || fail 'enabled status'
cp "$XM_ETC/system-update-schedule" "$test_dir/before"
touch "$test_dir/fail-start"
reject platform_system_update_schedule set weekly 07:00
cmp "$XM_ETC/system-update-schedule" "$test_dir/before" || fail 'failed activation did not roll back state'
[[ -f $test_dir/enabled && -f $test_dir/running ]] || fail 'failed activation did not restore timer'
platform_system_update_schedule disable
platform_system_update_schedule disable
[[ ! -e $XM_ETC/system-update-schedule && ! -e $test_dir/enabled && ! -e $test_dir/running ]] || fail 'disable/idempotency'
[[ $(platform_system_update_schedule status) == disabled$'\t'manual$'\t'-$'\t'* ]] || fail 'manual status'
printf 'PASS: systemd calendar, status, disable and transactional rollback (init mocks)\n'

XM_INIT=openrc
cp "$repo/assets/xray-manager-system-update.py" "$XM_HOME/assets/xray-manager-system-update.py"
platform_system_update_schedule set weekly 08:40
[[ $(_platform_update_schedule_read) == $'weekly\t08:40' ]] || fail 'OpenRC state'
[[ -f $test_dir/units/xray-manager-system-update ]] || fail 'OpenRC service'
grep -q '/opt/xray-manager/assets/xray-manager-system-update.py' "$test_dir/units/xray-manager-system-update" || fail 'OpenRC Python runner'
cp "$XM_ETC/system-update-schedule" "$test_dir/before-openrc"
touch "$test_dir/fail-start"
reject platform_system_update_schedule set daily 09:00
cmp "$XM_ETC/system-update-schedule" "$test_dir/before-openrc" || fail 'OpenRC failed activation did not restore state'
[[ -f $test_dir/enabled && -f $test_dir/running ]] || fail 'OpenRC failed activation did not restore service'
platform_system_update_schedule disable
[[ ! -e $test_dir/units/xray-manager-system-update ]] || fail 'OpenRC resource removal'
printf 'PASS: OpenRC private service lifecycle (init mocks)\n'

ln -s "$test_dir/foreign" "$XM_LOG/system-update-schedule.log"
reject platform_system_update_schedule_preflight
[[ -L $XM_LOG/system-update-schedule.log ]] || fail 'foreign log symlink changed'
rm "$XM_LOG/system-update-schedule.log"
conf_root=$test_dir/openrc-overrides
mkdir -p "$conf_root/etc/conf.d" "$conf_root/etc/runlevels/boot" "$conf_root/usr/local/etc/init.d"
_platform_update_schedule_openrc_overrides "$conf_root"
for name in xray-manager-system-update xray-manager-system-update.default; do
    printf 'foreign preserved\n' > "$conf_root/etc/conf.d/$name"
    reject _platform_update_schedule_openrc_overrides "$conf_root"
    [[ $(cat "$conf_root/etc/conf.d/$name") == 'foreign preserved' ]] || fail 'foreign override changed'
    rm "$conf_root/etc/conf.d/$name"
done
ln -s /etc/init.d/xray-manager-system-update "$conf_root/etc/runlevels/boot/xray-manager-system-update"
reject _platform_update_schedule_openrc_overrides "$conf_root"
rm "$conf_root/etc/runlevels/boot/xray-manager-system-update"
printf 'foreign init\n' > "$conf_root/usr/local/etc/init.d/xray-manager-system-update"
reject _platform_update_schedule_openrc_overrides "$conf_root"
printf 'PASS: OpenRC overlay, foreign runlevel and log symlink rejection\n'

(
    source "$repo/lib/platform.sh"
    pid_root=$test_dir/pid-preflight
    mkdir -p "$pid_root/run" "$pid_root/etc/init.d"
    _platform_update_schedule_pid_preflight "$pid_root"
    printf '123\n' > "$pid_root/run/xray-manager-system-update.pid"
    reject _platform_update_schedule_pid_preflight "$pid_root"
    printf '#!/sbin/openrc-run\n# foreign service\n' > "$pid_root/etc/init.d/xray-manager-system-update"
    reject _platform_update_schedule_pid_preflight "$pid_root"
    cp "$repo/assets/xray-manager-system-update.openrc" "$pid_root/etc/init.d/xray-manager-system-update"
    _platform_update_schedule_pid_preflight "$pid_root"
    rm "$pid_root/run/xray-manager-system-update.pid"
    ln -s "$test_dir/foreign" "$pid_root/run/xray-manager-system-update.pid"
    reject _platform_update_schedule_pid_preflight "$pid_root"
    [[ -L $pid_root/run/xray-manager-system-update.pid ]] || fail 'foreign PID symlink changed'
)
printf 'PASS: OpenRC PID path and ownership preflight\n'
