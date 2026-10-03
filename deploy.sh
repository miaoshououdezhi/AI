#!/bin/sh
# Standalone remote bootstrap. Run locally with: sh deploy.sh
# Runtime modules are fetched from a fixed, verified project commit.
set -eu
[ "$#" -eq 0 ] || { printf "%s\n" "用法：sh deploy.sh" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { printf "%s\n" "请先切换到 root 再执行。" >&2; exit 1; }
case $(uname -m) in
  x86_64|aarch64|arm64) ;;
  *) printf "%s\n" "仅支持 amd64 和 arm64 架构。" >&2; exit 1 ;;
esac
. /etc/os-release
case "$ID:$VERSION_ID" in
  debian:12|debian:13)
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl tar gzip
    ;;
  alpine:3.23|alpine:3.23.*|alpine:3.24|alpine:3.24.*)
    apk add --no-cache ca-certificates curl tar gzip
    ;;
  *) printf "%s\n" "仅支持 Debian 12/13 和 Alpine 3.23/3.24。" >&2; exit 1 ;;
esac
xray_tmp=$(mktemp -d)
cleanup() { rm -rf -- "$xray_tmp"; }
trap cleanup 0
trap "exit 130" INT
trap "exit 143" TERM
trap "exit 129" HUP
curl --http1.1 --fail --location --proto "=https" --proto-redir "=https" --tlsv1.2 --retry 2 --connect-timeout 15 --max-time 300 \
  -o "$xray_tmp/project.tar.gz" \
  https://github.com/miaoshououdezhi/AI/archive/2eb980fab90c23df38c602203951e4be3ddafcb5.tar.gz
mkdir "$xray_tmp/project"
tar -xzf "$xray_tmp/project.tar.gz" -C "$xray_tmp/project" --strip-components=1
sh "$xray_tmp/project/install.sh"
