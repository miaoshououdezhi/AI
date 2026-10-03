#!/bin/bash
set -Eeuo pipefail
exec > /dev/ttyS0 2>&1
finish() { code=$?; if ((code!=0)); then systemctl status xray-manager xray-manager-extra -l --no-pager || true; journalctl -b -u xray-manager-extra -n 40 -l --no-pager || true; fi; printf 'MULTI_VM_CI_ENTRY_EXIT=%s\n' "$code"; sync; systemctl poweroff --force --force; }
trap finish EXIT
mount -o remount,rw /
ip link set eth0 up; ip addr add 10.0.2.15/24 dev eth0; ip route add default via 10.0.2.2
printf 'nameserver 10.0.2.3\n' > /etc/resolv.conf
journalctl --flush
printf 'LIFECYCLE_PHASE=FRESH_INSTALL; PID1='; cat /proc/1/comm
[[ $(cat /proc/1/comm) == systemd ]]
printf 'GUEST_ENVIRONMENT_AND_PRODUCT_HASHES\n'
cat /etc/os-release
uname -m
systemctl --version
sha256sum /root/source/xray-manager.sh /root/source/install.sh /root/source/lib/* /root/source/assets/xray-manager-extra.service
dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' | awk '$2=="installed" {print $1}' | sort > /root/foundation-baseline
sh /root/source/install.sh
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=localhost -addext subjectAltName=DNS:localhost -keyout /root/tls.key -out /root/tls.crt >/dev/null 2>&1
chmod 600 /root/tls.key
xy --yes add shadowsocks ss Test-SS 22001 127.0.0.1
xy --yes add anytls any Test-AnyTLS 22002 127.0.0.1 localhost /root/tls.crt /root/tls.key
jq -r '.baseline[]' /etc/xray-manager/dependency-ledger.json | sort > /root/ledger-baseline
cmp /root/foundation-baseline /root/ledger-baseline
# Repeat installation must preserve existing nodes, ledger, and both units.
systemctl is-active --quiet xray-manager
systemctl is-active --quiet xray-manager-extra
sha256sum /etc/xray-manager/state.json > /root/reinstall-state-before.sha256
sha256sum /etc/xray-manager/dependency-ledger.json > /root/reinstall-ledger-before.sha256
sh /root/source/install.sh
sha256sum /etc/xray-manager/state.json > /root/reinstall-state-after.sha256
sha256sum /etc/xray-manager/dependency-ledger.json > /root/reinstall-ledger-after.sha256
cmp /root/reinstall-state-before.sha256 /root/reinstall-state-after.sha256
cmp /root/reinstall-ledger-before.sha256 /root/reinstall-ledger-after.sha256
systemctl is-active --quiet xray-manager
systemctl is-active --quiet xray-manager-extra
printf 'REINSTALL_STATE_LEDGER_AND_RUNNING_FLAGS_PRESERVED\n' 
grep -q 'AF_NETLINK' /etc/systemd/system/xray-manager-extra.service
! grep -q 'AF_NETLINK' /etc/systemd/system/xray-manager.service
xy service start
systemctl is-active --quiet xray-manager
systemctl is-active --quiet xray-manager-extra
printf 'LIFECYCLE_PHASE=INDEPENDENT_FLAGS\n'
systemctl stop xray-manager-extra
xy --yes edit ss name Renamed-SS
! systemctl is-active --quiet xray-manager-extra
systemctl start xray-manager-extra
systemctl stop xray-manager
xy --yes edit any name Renamed-AnyTLS
! systemctl is-active --quiet xray-manager
systemctl is-active --quiet xray-manager-extra
systemctl stop xray-manager-extra
xy --yes edit ss port 22011
! systemctl is-active --quiet xray-manager
! systemctl is-active --quiet xray-manager-extra
xy service start
printf 'LIFECYCLE_PHASE=MIGRATION\n'
before=$(sha256sum /etc/xray-manager/state.json)
if xy --yes edit ss port 22002; then exit 41; fi
[[ $(sha256sum /etc/xray-manager/state.json) == "$before" ]]
xy export /root/portable-final.json
[[ $(stat -c %a /root/portable-final.json) == 600 ]]
cp /root/tls.crt /root/external-cert.crt
rm /root/tls.crt /root/tls.key
xy --yes delete any
xy --yes delete ss
xy --yes import /root/portable-final.json
systemctl is-active --quiet xray-manager
systemctl is-active --quiet xray-manager-extra
printf 'LIFECYCLE_PHASE=CLEANUP\n'
xy schedule set 23:59
printf 'foreign\n' > /etc/xray-manager/foreign-file
if xy --yes uninstall; then exit 43; fi
systemctl is-active --quiet xray-manager
systemctl is-active --quiet xray-manager-extra
rm /etc/xray-manager/foreign-file
printf 'fixture\n' > /var/log/xray-manager/last-error.log
printf 'fixture\n' > /var/log/xray-manager/last-extra-error.log
xy --yes uninstall
for path in /opt/xray-manager /etc/xray-manager /var/lib/xray-manager /var/log/xray-manager /usr/local/bin/xy /etc/systemd/system/xray-manager.service /etc/systemd/system/xray-manager-extra.service /etc/systemd/system/xray-manager-restart.service /etc/systemd/system/xray-manager-restart.timer; do [[ ! -e $path && ! -L $path ]]; done
! getent passwd xray-manager
! getent group xray-manager
[[ -s /root/portable-final.json && -s /root/external-cert.crt ]]
dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' | awk '$2=="installed" {print $1}' | sort > /root/after-packages
[[ -z $(comm -23 /root/foundation-baseline /root/after-packages) ]]
printf 'REMAINING_ADDED_PACKAGES\n'; comm -13 /root/foundation-baseline /root/after-packages
printf 'SYSTEMD_DUAL_CORE_MIGRATION_CLEANUP_PASS\n'
