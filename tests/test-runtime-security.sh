#!/usr/bin/env bash
# Check process-local mitigation and command/state error boundaries without init.
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
export XM_ROOT=$scratch/root
source "$repo/xray-manager.sh"
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
python3 - "$repo" <<'PY'
import pathlib,subprocess,sys
p=pathlib.Path(sys.argv[1])
for name in ('xray-manager','xray-manager-extra'):
 text=(p/'assets'/f'{name}.service').read_text()
 service=text.split('[Service]\n',1)[1].split('\n[',1)[0]
 assert 'Environment=GODEBUG=multipathtcp=0' in service
 result=subprocess.check_output(['sh','-c','. "$1"; printenv GODEBUG','_',str(p/'assets'/f'{name}.openrc')],text=True)
 assert result.strip()=='multipathtcp=0',result
print('PASS: systemd and OpenRC process-local MPTCP environment')
PY
mkdir -p "$XM_HOME/bin" "$XM_ETC" "$XM_LOG"
protocol_validate_nodes() { return 0; }
protocol_generate() { printf '{"inbounds":[],"candidate":true}\n' > "$2"; }
protocol_generate_extra() { printf '{"inbounds":[]}\n' > "$2"; }
protocol_has_extra() { return 1; }
platform_extra_enabled() { return 1; }
platform_service() { printf 'main:%s\n' "$1" >> "$scratch/calls"; [[ $1 != status ]] || return "$main_status"; }
platform_extra_service() { printf 'extra:%s\n' "$1" >> "$scratch/calls"; [[ $1 != status ]] || return "$extra_status"; }
platform_health() { printf 'main:health\n' >> "$scratch/calls"; }
printf '#!/bin/sh\nexit 0\n' > "$XM_BIN"
chmod +x "$XM_BIN"
printf '{"original":true}\n' > "$XM_CONFIG"
state_empty v26.10.29 > "$XM_STATE"
state_empty v26.10.31 > "$scratch/candidate"
printf '#!/bin/sh\n# candidate core\nexit 0\n' > "$scratch/core"
chmod +x "$scratch/core"
cp "$XM_STATE" "$scratch/old-state"; cp "$XM_CONFIG" "$scratch/old-config"; cp "$XM_BIN" "$scratch/old-core"
for which in main extra; do
    main_status=0; extra_status=0
    if [[ $which == main ]]; then main_status=2; else extra_status=2; cp "$XM_BIN" "$XM_EXTRA_BIN"; fi
    : > "$scratch/calls"
    if state_apply "$scratch/candidate" "$scratch/core"; then fail 'unknown state allowed core replacement'; fi
    cmp "$XM_STATE" "$scratch/old-state" && cmp "$XM_CONFIG" "$scratch/old-config" && cmp "$XM_BIN" "$scratch/old-core" || fail 'unknown state mutated installation'
    if grep -v ':status$' "$scratch/calls"; then fail 'unknown state mutated service'; fi
done
# Public service/status and scheduled restart must fail instead of reporting stopped.
xm_ready() { return 0; }
platform_restart_schedule_due() { return 0; }
for which in main extra; do
    main_status=0; extra_status=0
    if [[ $which == main ]]; then main_status=2; else extra_status=2; fi
    for action in status start stop restart enable disable; do
        : > "$scratch/calls"
        if xm_service "$action"; then fail "unknown $which state accepted: $action"; fi
        if grep -v ':status$' "$scratch/calls"; then fail 'service action despite unknown state'; fi
    done
    : > "$scratch/calls"
    if xm_scheduled_restart; then fail 'unknown state accepted by scheduled restart'; fi
    if grep -v ':status$' "$scratch/calls"; then fail 'scheduled action despite unknown state'; fi
done
# CLI auxiliary upgrade requires an installed engine, no arguments and confirmation.
platform_extra_upgrade() { printf 'upgrade\n' >> "$scratch/upgraded"; }
XM_YES=0
if xm_upgrade_extra </dev/null; then fail 'upgrade-extra missing confirmation accepted'; fi
[[ ! -e $scratch/upgraded ]] || fail 'cancelled upgrade ran'
XM_YES=1
xm_upgrade_extra || fail 'confirmed auxiliary upgrade'
if xm_upgrade_extra arbitrary; then fail 'auxiliary upgrade arguments accepted'; fi
rm -f "$XM_EXTRA_BIN" "$scratch/upgraded"
if xm_upgrade_extra; then fail 'missing auxiliary accepted'; fi
[[ ! -e $scratch/upgraded ]] || fail 'missing auxiliary triggered install'
printf 'PASS: unknown service state preserves files and stops mutations; auxiliary CLI gates\n'
