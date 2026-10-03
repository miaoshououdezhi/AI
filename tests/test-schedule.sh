#!/usr/bin/env bash
# Scheduler parsing/daily behavior and transaction mocks; never changes host init.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/lib/platform.sh"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/xray-schedule-tests.XXXXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
test_dir=$(cd "$test_dir" && pwd -P)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() { if "$@" >"$test_dir/out" 2>"$test_dir/err"; then fail "unexpected success: $*"; fi; }
for value in 00:00 04:00 23:59; do _platform_schedule_time "$value" || fail valid-time; done
for value in '' 4:00 24:00 00:60 '04:00;id' $'04:00\n' 004:00; do reject _platform_schedule_time "$value"; done
# Invalid syntax fails before init checks or filesystem/service mutations.
_platform_init_available() { fail 'unexpected init call'; }
reject platform_restart_schedule set 24:00
reject platform_restart_schedule set 04:00 extra
reject platform_restart_schedule disable extra
reject platform_restart_schedule nonsense
python3 - "$repo/assets/xray-manager-restart.py" "$test_dir" <<'PY'
import datetime, importlib.util, pathlib, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('schedule', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
p = pathlib.Path(sys.argv[2])/'state'
p.write_text('# xray-manager-owned:1\n04:00\n')
assert m.read_time(p) == '04:00'
for bad in ('04:00\n', '# xray-manager-owned:1\n4:00\n', '# xray-manager-owned:1\n04:00\nextra\n', '# xray-manager-owned:1\n24:00\n'):
    p.write_text(bad)
    try: m.read_time(p)
    except ValueError: pass
    else: raise AssertionError('invalid schedule accepted')
p.unlink(); p.symlink_to('/etc/passwd')
try: m.read_time(p)
except ValueError: pass
else: raise AssertionError('symlink accepted')
now = datetime.datetime(2026, 10, 3, 4, 0, 10)
assert not m.due(now, '04:00', '2026-10-03 04:00', None)
assert m.due(now, '04:00', '2026-10-03 03:59', None)
assert not m.due(now, '04:00', '2026-10-03 03:59', now.date())
assert not m.due(now.replace(minute=1), '04:00', '2026-10-03 03:59', None)
assert m.due(now+datetime.timedelta(days=1), '04:00', '2026-10-03 03:59', now.date())
print('PASS: scheduler exact time, daily deduplication, startup skip, missed minute skip')
PY
# Root-free transaction tests remap all fixed init targets into a private directory.
export XM_ROOT=''
XM_HOME=$test_dir/home; XM_ETC=$test_dir/etc; XM_LOG=$test_dir/log
mkdir -p "$XM_HOME/assets" "$XM_ETC" "$XM_LOG" "$test_dir/units"
printf '#!/bin/sh\n' > "$XM_HOME/xray-manager.sh"; chmod 0755 "$XM_HOME/xray-manager.sh"
printf 'xray-manager:1\n' > "$XM_ETC/.xray-manager-owned"
_platform_paths() { return 0; }
_platform_init_available() { return 0; }
_platform_schedule_link() { return 0; }
platform_restart_schedule_preflight() { return 0; }
_platform_schedule_files() {
    printf '%s\n' "$XM_ETC/restart-schedule"
    if [[ $XM_INIT == systemd ]]; then printf '%s\n' "$test_dir/units/xray-manager-restart.service" "$test_dir/units/xray-manager-restart.timer";
    else printf '%s\n' "$test_dir/units/xray-manager-restart"; fi
}
_platform_owned_file() { return 0; }
_platform_install_owned() {
    local target=$2
    case $target in /etc/systemd/system/*|/etc/init.d/*) target=$test_dir/units/${target##*/} ;; esac
    cp -- "$1" "$target" && chmod "$3" "$target"
}
_platform_schedule_enabled() { [[ -f $test_dir/enabled ]]; }
_platform_schedule_running() { [[ -f $test_dir/running ]]; }
_platform_schedule_control() {
    case $1 in
        start) if [[ -f $test_dir/fail-start ]]; then rm -f "$test_dir/fail-start"; return 1; fi; touch "$test_dir/running" ;;
        stop) rm -f "$test_dir/running" ;;
        enable) touch "$test_dir/enabled" ;;
        disable) rm -f "$test_dir/enabled" ;;
    esac
}
systemctl() {
    case $1 in daemon-reload) return 0 ;; show) printf 'Sat 2026-10-03 04:00:00 UTC\n' ;; *) fail 'unexpected systemctl' ;; esac
}
export XM_INIT=systemd
platform_restart_schedule set 04:00
[[ $(_platform_schedule_read_time) == 04:00 ]] || fail 'initial set'
[[ -f $test_dir/running && -f $test_dir/enabled ]] || fail 'initial scheduler activation'
grep -q 'OnCalendar=\*-\*-\* 04:00:00' "$test_dir/units/xray-manager-restart.timer" || fail 'calendar template'
[[ $(platform_restart_schedule status) == enabled$'\t'04:00$'\t'* ]] || fail 'status format'
cp "$XM_ETC/restart-schedule" "$test_dir/before"
touch "$test_dir/fail-start"
reject platform_restart_schedule set 05:00
cmp "$XM_ETC/restart-schedule" "$test_dir/before" || { cat "$test_dir/err" >&2; fail 'failure state rollback'; }
[[ -f $test_dir/running && -f $test_dir/enabled ]] || fail 'failure activation rollback'
platform_restart_schedule disable
[[ ! -e $XM_ETC/restart-schedule && ! -e $test_dir/running && ! -e $test_dir/enabled ]] || fail disable
platform_restart_schedule disable
[[ $(platform_restart_schedule status) == disabled$'\t'-$'\t'* ]] || fail 'disabled status format'
printf 'PASS: schedule set/status/disable/idempotency and failed activation rollback (init mocks)\n'

export XM_INIT=openrc
cp "$repo/assets/xray-manager-restart.py" "$XM_HOME/assets/xray-manager-restart.py"
platform_restart_schedule set 23:59
[[ $(_platform_schedule_read_time) == 23:59 ]] || fail 'OpenRC schedule'
[[ $(platform_restart_schedule status) == enabled$'\t'23:59$'\t'* ]] || fail 'OpenRC status'
grep -q '/opt/xray-manager/assets/xray-manager-restart.py' "$test_dir/units/xray-manager-restart" || fail 'OpenRC private runner'
cp "$XM_ETC/restart-schedule" "$test_dir/before-openrc"
touch "$test_dir/fail-start"
reject platform_restart_schedule set 22:58
cmp "$XM_ETC/restart-schedule" "$test_dir/before-openrc" || fail 'OpenRC failed activation rollback'
[[ -f $test_dir/running && -f $test_dir/enabled ]] || fail 'OpenRC activation rollback'
platform_restart_schedule disable
platform_restart_schedule disable
[[ ! -e $test_dir/units/xray-manager-restart ]] || fail 'OpenRC resource removal'
printf 'PASS: OpenRC private runner transaction/idempotency/failed activation rollback (init mocks)\n'

# OpenRC service overlays are executable external configuration: reject every
# exact/level-specific file or dangling link, and preserve all foreign bytes.
conf_root=$test_dir/openrc-overlays
mkdir -p "$conf_root/etc/conf.d" "$conf_root/etc/runlevels/boot" "$conf_root/usr/local/etc/init.d"
_platform_schedule_openrc_overrides "$conf_root"
for name in xray-manager-restart xray-manager-restart.default xray-manager-restart.boot; do
    printf 'foreign preserved\n' > "$conf_root/etc/conf.d/$name"
    reject _platform_schedule_openrc_overrides "$conf_root"
    [[ $(cat "$conf_root/etc/conf.d/$name") == 'foreign preserved' ]] || fail 'foreign overlay modified'
    rm "$conf_root/etc/conf.d/$name"
done
ln -s "$test_dir/nonexistent" "$conf_root/etc/conf.d/xray-manager-restart.shutdown"
reject _platform_schedule_openrc_overrides "$conf_root"
[[ -L $conf_root/etc/conf.d/xray-manager-restart.shutdown ]] || fail 'foreign overlay link removed'
rm "$conf_root/etc/conf.d/xray-manager-restart.shutdown"
ln -s /etc/init.d/xray-manager-restart "$conf_root/etc/runlevels/boot/xray-manager-restart"
reject _platform_schedule_openrc_overrides "$conf_root"
rm "$conf_root/etc/runlevels/boot/xray-manager-restart"
printf '# foreign init\n' > "$conf_root/usr/local/etc/init.d/xray-manager-restart"
reject _platform_schedule_openrc_overrides "$conf_root"
[[ -s $conf_root/usr/local/etc/init.d/xray-manager-restart ]] || fail 'foreign alternate init removed'
printf 'PASS: OpenRC exact/runlevel conf.d overlays, dangling links, alternate init and external runlevel rejection\n'

# Preserve unclaimed runtime PID files; accept an existing regular pidfile only
# when its matching OpenRC service has the project ownership marker.
(
    source "$repo/lib/platform.sh"
    pid_root=$test_dir/pid-preflight
    mkdir -p "$pid_root/run" "$pid_root/etc/init.d"
    _platform_schedule_pid_preflight "$pid_root"
    printf '123\n' > "$pid_root/run/xray-manager-restart.pid"
    reject _platform_schedule_pid_preflight "$pid_root"
    [[ $(cat "$pid_root/run/xray-manager-restart.pid") == 123 ]] || fail 'foreign pidfile changed'
    printf '#!/sbin/openrc-run\n# foreign service\n' > "$pid_root/etc/init.d/xray-manager-restart"
    reject _platform_schedule_pid_preflight "$pid_root"
    cp "$repo/assets/xray-manager-restart.openrc" "$pid_root/etc/init.d/xray-manager-restart"
    _platform_schedule_pid_preflight "$pid_root"
    rm "$pid_root/run/xray-manager-restart.pid"
    ln -s "$test_dir/nonexistent" "$pid_root/run/xray-manager-restart.pid"
    reject _platform_schedule_pid_preflight "$pid_root"
    [[ -L $pid_root/run/xray-manager-restart.pid ]] || fail 'foreign pidfile link removed'
    rm "$pid_root/run/xray-manager-restart.pid"
    mkdir "$pid_root/run/xray-manager-restart.pid"
    reject _platform_schedule_pid_preflight "$pid_root"
)
printf 'PASS: scheduler PID symlink/type/unclaimed ownership rejection and preservation\n'
