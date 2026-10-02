#!/bin/sh
# POSIX entry point: Alpine installations may not include Bash.
set -u
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
if ! command -v bash >/dev/null 2>&1; then
    if [ "$(id -u)" -ne 0 ]; then printf '%s\n' '错误：首次安装 Bash 需要 root。' >&2; exit 1; fi
    if [ -n "${XM_ROOT:-}" ]; then printf '%s\n' '错误：隔离测试不能更改宿主依赖，请预先安装 Bash。' >&2; exit 1; fi
    os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
    os_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
    case "$os_id:$os_version" in
        alpine:3.23.*|alpine:3.24.*|alpine:3.23|alpine:3.24) apk add --no-cache bash || exit 1 ;;
        debian:12|debian:13) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y bash || exit 1 ;;
        *) printf '%s\n' '错误：仅支持 Debian 12/13 和 Alpine 3.23/3.24。' >&2; exit 1 ;;
    esac
fi
exec bash "$script_dir/xray-manager.sh" install "$@"
