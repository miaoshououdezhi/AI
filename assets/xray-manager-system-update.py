#!/usr/bin/env python3
# xray-manager-owned:1
"""Private OpenRC scheduler for system package updates; no global cron edits."""
import datetime
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time

CONFIG = Path('/etc/xray-manager/system-update-schedule')
LOG = Path('/var/log/xray-manager/system-update-schedule.log')
COMMAND = ['/bin/bash', '/opt/xray-manager/xray-manager.sh', 'scheduled-system-update']
STOP = False


def read_schedule(path=CONFIG):
    if path.is_symlink():
        raise ValueError('schedule configuration must not be a symlink')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 128:
            raise ValueError('schedule configuration must be a small regular file')
        data = os.read(fd, 129)
    finally:
        os.close(fd)
    match = re.fullmatch(
        rb'# xray-manager-owned:1\n(daily|weekly|monthly)\n((?:[01][0-9]|2[0-3]):[0-5][0-9])\n',
        data,
    )
    if match is None:
        raise ValueError('invalid owned period and HH:MM schedule')
    return match[1].decode('ascii'), match[2].decode('ascii')


def due(now, period, target, started_minute, last_date):
    """Run once on a matching local day/minute; never catch up after startup."""
    minute = now.strftime('%Y-%m-%d %H:%M')
    if minute == started_minute or now.date() == last_date:
        return False
    if now.strftime('%H:%M') != target:
        return False
    return period == 'daily' or (period == 'weekly' and now.weekday() == 0) or (
        period == 'monthly' and now.day == 1
    )


def request_stop(_signum, _frame):
    global STOP
    STOP = True


def main():
    os.environ.pop('TZ', None)
    time.tzset()
    period, target = read_schedule()
    started_minute = datetime.datetime.now().strftime('%Y-%m-%d %H:%M')
    last_date = None
    child = None
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    print('System update scheduler enabled: ' + period + ' ' + target + ' (machine local time)', flush=True)
    while not STOP:
        time.tzset()
        now = datetime.datetime.now()
        if child is not None and child.poll() is not None:
            print('Scheduled system update exit=' + str(child.returncode), flush=True)
            child = None
        if child is None and due(now, period, target, started_minute, last_date):
            last_date = now.date()
            try:
                env = os.environ.copy()
                env['PATH'] = '/usr/sbin:/usr/bin:/sbin:/bin'
                # Package upgrades have no fixed duration. Give the worker its
                # own session and log fd so scheduler stop does not cut it off.
                fd = os.open(LOG, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1 or info.st_mode & 0o077:
                    os.close(fd)
                    raise ValueError('system update log is not a private root-owned regular file')
                with os.fdopen(fd, 'ab', buffering=0) as output:
                    child = subprocess.Popen(COMMAND, env=env, stdout=output,
                                             stderr=subprocess.STDOUT,
                                             start_new_session=True, close_fds=True)
                print('Scheduled system update started pid=' + str(child.pid), flush=True)
            except (OSError, ValueError) as error:
                print('Scheduled system update failed: ' + str(error), file=sys.stderr, flush=True)
        for _ in range(15):
            if STOP:
                break
            time.sleep(1)
    if child is not None and child.poll() is None:
        print('Scheduler stopped; active package update continues to completion', flush=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print('System update scheduler configuration error: ' + str(error), file=sys.stderr)
        sys.exit(1)
