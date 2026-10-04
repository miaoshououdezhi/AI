#!/bin/sh
# Standalone remote bootstrap. Run locally with: sh deploy.sh
# Runtime modules are fetched from a fixed, verified project commit.
set -eu
# Human messages stay on stderr; bootstrap needs neither Bash nor tput.
xray_boot_message() {
    xray_boot_color=$1; xray_boot_label=$2; shift 2
    if [ -t 2 ] && [ -z "${NO_COLOR+x}" ] && [ "${TERM:-dumb}" != dumb ]; then
        printf '\033[%sm[%s] %s\033[0m\n' "$xray_boot_color" "$xray_boot_label" "$*" >&2
    else
        printf '[%s] %s\n' "$xray_boot_label" "$*" >&2
    fi
}
xray_boot_error() { xray_boot_message '38;2;255;0;0' '错误' "$@"; }
xray_boot_info() { xray_boot_message '38;2;0;255;255' '信息' "$@"; }
[ "$#" -eq 0 ] || { xray_boot_error '用法：sh deploy.sh'; exit 2; }
[ "$(id -u)" -eq 0 ] || { xray_boot_error '请先切换到 root 再执行。'; exit 1; }
case $(uname -m) in
  x86_64|aarch64|arm64) ;;
  *) xray_boot_error '仅支持 amd64 和 arm64 架构。'; exit 1 ;;
esac
. /etc/os-release
umask 077
xray_tmp=$(mktemp -d)
cleanup() { rm -rf -- "$xray_tmp"; }
trap cleanup 0
trap "exit 130" INT
trap "exit 143" TERM
trap "exit 129" HUP
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

case "$ID:$VERSION_ID" in debian:12|debian:13|alpine:3.23|alpine:3.23.*|alpine:3.24|alpine:3.24.*) ;; *) xray_boot_error '不支持此系统。'; exit 1 ;; esac
xray_package_snapshot "$ID" "$xray_tmp/dependency-snapshot.json" || { xray_boot_error '无法记录安装前依赖，未安装软件包。'; exit 1; }
export XM_DEPENDENCY_SNAPSHOT_FILE="$xray_tmp/dependency-snapshot.json"
xray_boot_info '正在准备下载依赖，安装前包基线已记录。'
case "$ID:$VERSION_ID" in
  debian:12|debian:13)
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl tar gzip
    ;;
  alpine:3.23|alpine:3.23.*|alpine:3.24|alpine:3.24.*)
    apk add --no-cache ca-certificates curl tar gzip
    ;;
  *) xray_boot_error '仅支持 Debian 12/13 和 Alpine 3.23/3.24。'; exit 1 ;;
esac
xray_boot_info '正在下载固定版本的管理脚本。'
curl --http1.1 --fail --location --proto "=https" --proto-redir "=https" --tlsv1.2 --retry 2 --connect-timeout 15 --max-time 300 \
  -o "$xray_tmp/project.tar.gz" \
  https://github.com/miaoshououdezhi/AI/archive/d214b22f55066f6032065b8546e9a825abfa9c60.tar.gz
xray_boot_info '正在解压并启动安装。'
mkdir "$xray_tmp/project"
tar -xzf "$xray_tmp/project.tar.gz" -C "$xray_tmp/project" --strip-components=1
sh "$xray_tmp/project/install.sh"
