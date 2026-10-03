#!/usr/bin/env python3
# xray-manager-owned:1
"""Private OpenRC scheduler: local daily time, no global cron resources."""
import datetime
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

CONFIG = Path('/etc/xray-manager/restart-schedule')
COMMAND = ['/bin/bash', '/opt/xray-manager/xray-manager.sh', 'scheduled-restart']
STOP = False


def read_time(path=CONFIG):
    if path.is_symlink() or not path.is_file():
        raise ValueError('schedule configuration must be a regular file')
    data = path.read_bytes()
    match = re.fullmatch(rb'# xray-manager-owned:1\n((?:[01][0-9]|2[0-3]):[0-5][0-9])\n', data)
    if match is None:
        raise ValueError('invalid owned daily HH:MM schedule')
    return match[1].decode('ascii')


def due(now, target, started_minute, last_day):
    """Never catch up a missed minute, nor fire during the startup minute."""
    minute = now.strftime('%Y-%m-%d %H:%M')
    return minute != started_minute and now.strftime('%H:%M') == target and now.date() != last_day


def request_stop(_signum, _frame):
    global STOP
    STOP = True


def main():
    os.environ.pop('TZ', None)
    time.tzset()
    target = read_time()
    started_minute = datetime.datetime.now().strftime('%Y-%m-%d %H:%M')
    last_day = None
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    print('Daily Xray restart scheduler enabled at ' + target + ' (machine local time)', flush=True)
    while not STOP:
        time.tzset()
        now = datetime.datetime.now()
        if due(now, target, started_minute, last_day):
            last_day = now.date()
            try:
                env = os.environ.copy()
                env['PATH'] = '/usr/sbin:/usr/bin:/sbin:/bin'
                child = subprocess.Popen(COMMAND, env=env)
                try:
                    code = child.wait(timeout=120)
                except subprocess.TimeoutExpired:
                    child.terminate()
                    try:
                        code = child.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        code = child.wait()
                print('Scheduled restart exit=' + str(code), flush=True)
            except (OSError, subprocess.TimeoutExpired) as error:
                print('Scheduled restart failed: ' + str(error), file=sys.stderr, flush=True)
        # Short sleeps permit service stop and avoid reliance on wall-clock arithmetic.
        for _ in range(15):
            if STOP:
                break
            time.sleep(1)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print('Restart scheduler configuration error: ' + str(error), file=sys.stderr)
        sys.exit(1)
