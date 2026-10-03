#!/bin/sh
# POSIX entry point: Alpine installations may not include Bash.
set -u
umask 077
xray_snapshot_tmp=
cleanup() { [ -z "$xray_snapshot_tmp" ] || rm -rf -- "$xray_snapshot_tmp"; }
trap cleanup 0
# Snapshot packages before any bootstrap apt/apk mutation. Names are data, never
# sourced; the platform module validates this private JSON again before use.
xray_package_snapshot() {
    xray_snapshot_os=$1
    xray_snapshot_file=$2
    xray_snapshot_list="${xray_snapshot_file}.packages"
    case "$xray_snapshot_os" in
        debian)
            dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' > "${xray_snapshot_file}.raw" || return 1
            awk -F '\t' '$2=="installed" {print $1}' "${xray_snapshot_file}.raw" > "$xray_snapshot_list" || return 1
            rm -f -- "${xray_snapshot_file}.raw" ;;
        alpine) apk info > "$xray_snapshot_list" || return 1 ;;
        *) return 1 ;;
    esac
    [ -s "$xray_snapshot_list" ] || return 1
    (
        printf '{"os":"%s","packages":[' "$xray_snapshot_os"
        xray_snapshot_first=1
        while IFS= read -r xray_snapshot_package; do
            case "$xray_snapshot_package" in ''|*[!A-Za-z0-9.+:_-]*) exit 1 ;; esac
            [ "$xray_snapshot_first" -eq 1 ] || printf ','
            xray_snapshot_first=0
            printf '"%s"' "$xray_snapshot_package"
        done < "$xray_snapshot_list"
        printf ']}\n'
    ) > "$xray_snapshot_file" || return 1
    chmod 0600 "$xray_snapshot_file" || return 1
    rm -f -- "$xray_snapshot_list"
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
if [ "$(id -u)" -eq 0 ] && [ -z "${XM_ROOT:-}" ] && [ -z "${XM_DEPENDENCY_SNAPSHOT_FILE:-}" ]; then
    xray_snapshot_os=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
    xray_snapshot_tmp=$(mktemp -d) || exit 1
    xray_package_snapshot "$xray_snapshot_os" "$xray_snapshot_tmp/dependency-snapshot.json" || { printf '[错误] 无法记录安装前依赖，未安装软件包。\n' >&2; exit 1; }
    export XM_DEPENDENCY_SNAPSHOT_FILE="$xray_snapshot_tmp/dependency-snapshot.json"
fi
if ! command -v bash >/dev/null 2>&1; then
    if [ "$(id -u)" -ne 0 ]; then printf '%s\n' '[错误] 首次安装 Bash 需要 root。' >&2; exit 1; fi
    if [ -n "${XM_ROOT:-}" ]; then printf '%s\n' '[错误] 隔离测试不能更改宿主依赖，请预先安装 Bash。' >&2; exit 1; fi
    os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
    os_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
    case "$os_id:$os_version" in
        alpine:3.23.*|alpine:3.24.*|alpine:3.23|alpine:3.24) apk add --no-cache bash || exit 1 ;;
        debian:12|debian:13) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y bash || exit 1 ;;
        *) printf '%s\n' '[错误] 仅支持 Debian 12/13 和 Alpine 3.23/3.24。' >&2; exit 1 ;;
    esac
fi
bash "$script_dir/xray-manager.sh" install "$@"
xray_install_result=$?
exit "$xray_install_result"
