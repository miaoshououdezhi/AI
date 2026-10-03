#!/usr/bin/env bash
# Platform adapter. Sourcing this file never installs packages or touches services.
_XM_PLATFORM_ASSETS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../assets" 2>/dev/null && pwd)"

_platform_error() {
    if declare -F xm_error >/dev/null; then xm_error "平台：$*"; else printf '[错误] 平台：%s\n' "$*" >&2; fi
    return 1
}
_platform_info() {
    if declare -F xm_info >/dev/null; then xm_info "$*"; else printf '[信息] %s\n' "$*" >&2; fi
}
_platform_warning() {
    if declare -F xm_warning >/dev/null; then xm_warning "$*"; else printf '[警告] %s\n' "$*" >&2; fi
}
# Human-only Python diagnostics use the same palette/TTY policy as Common.
# Colors travel as fixed environment values, never in secret-bearing argv.
_platform_python() (
    set -o pipefail
    export _XM_PY_CYAN='' _XM_PY_YELLOW='' _XM_PY_RED='' _XM_PY_RESET=''
    if [[ -t 2 && ! ${NO_COLOR+x} && ${TERM:-dumb} != dumb ]]; then
        _XM_PY_CYAN=$'\033[96m'; _XM_PY_YELLOW=$'\033[93m'; _XM_PY_RED=$'\033[91m'; _XM_PY_RESET=$'\033[0m'
    fi
    {
        cat <<'PYLABEL'
import os, sys
def human(kind, message):
    color = os.environ.get({'信息':'_XM_PY_CYAN','警告':'_XM_PY_YELLOW','错误':'_XM_PY_RED'}[kind], '')
    reset = os.environ.get('_XM_PY_RESET', '') if color else ''
    print(color + '[' + kind + '] ' + str(message) + reset, file=sys.stderr, flush=True)
PYLABEL
        cat
    } | python3 "$@"
)

_platform_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || { _platform_error '此操作需要 root。'; return 1; }
}
_platform_real() {
    [[ -z ${XM_ROOT:-} ]] || { _platform_error 'XM_ROOT 沙箱模式禁止修改宿主软件包、账户和服务。'; return 1; }
    _platform_root
}
_platform_paths() {
    local root=${XM_ROOT:-}
    [[ -z $root || ( $root == /* && $root != / && $root != */ && $root != *'/../'* && $root != */.. && $root != *'/./'* ) ]] || {
        _platform_error 'XM_ROOT 必须是无 .. 的绝对路径。'; return 1;
    }
    XM_HOME=${XM_HOME:-$root/opt/xray-manager}
    XM_ETC=${XM_ETC:-$root/etc/xray-manager}
    XM_DATA=${XM_DATA:-$root/var/lib/xray-manager}
    XM_LOG=${XM_LOG:-$root/var/log/xray-manager}
    XM_BIN=${XM_BIN:-$XM_HOME/bin/xray}
    [[ $XM_HOME == "$root/opt/xray-manager" && $XM_ETC == "$root/etc/xray-manager" && $XM_DATA == "$root/var/lib/xray-manager" && $XM_LOG == "$root/var/log/xray-manager" && $XM_BIN == "$XM_HOME/bin/xray" ]] || {
        _platform_error '受管目录必须使用固定项目路径（隔离测试请设置 XM_ROOT）。'; return 1;
    }
}
_platform_no_symlink() {
    local path=$1 cursor=$1
    [[ $path == /* ]] || return 1
    while [[ $cursor != / && -n $cursor ]]; do
        [[ ! -L $cursor ]] || { _platform_error "拒绝符号链接路径：$cursor"; return 1; }
        cursor=${cursor%/*}
    done
}
_platform_owned_dir() {
    local dir=$1
    [[ -d $dir && ! -L $dir && -f $dir/.xray-manager-owned && ! -L $dir/.xray-manager-owned ]] &&
        [[ $(cat -- "$dir/.xray-manager-owned") == 'xray-manager:1' ]]
}
_platform_owned_file() {
    local file=$1
    [[ -f $file && ! -L $file ]] &&
        head -n 2 -- "$file" | grep -qx '# xray-manager-owned:1'
}

platform_detect() {
    local release=${XM_ROOT:-}/etc/os-release line key value id='' version=''
    [[ -r $release ]] || { _platform_error "不能读取 $release"; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        key=${line%%=*}; value=${line#*=}
        value=${value#\"}; value=${value%\"}; value=${value#\'}; value=${value%\'}
        case $key in ID) id=$value ;; VERSION_ID) version=$value ;; esac
    done < "$release"
    case $id:$version in
        debian:12|debian:13) XM_OS=debian; XM_INIT=systemd ;;
        alpine:3.23|alpine:3.23.*|alpine:3.24|alpine:3.24.*) XM_OS=alpine; XM_INIT=openrc ;;
        *) _platform_error "不支持的系统：$id $version（支持 Debian 12/13、Alpine 3.23/3.24）。"; return 1 ;;
    esac
    XM_OS_VERSION=$version
    case $(uname -m) in
        x86_64) XM_ARCH=amd64 ;; aarch64|arm64) XM_ARCH=arm64 ;;
        *) _platform_error "不支持的 CPU 架构：$(uname -m)"; return 1 ;;
    esac
    XM_LIBC=glibc; [[ $XM_OS != alpine ]] || XM_LIBC=musl
    export XM_OS XM_OS_VERSION XM_INIT XM_ARCH XM_LIBC
}

platform_dependencies() {
    _platform_real || return 1
    platform_detect || return 1
    _platform_dependency_begin || return 1
    _platform_info '检查并安装平台依赖。'
    local cmd missing=0
    for cmd in curl jq unzip openssl python3 flock ss logrotate; do
        command -v "$cmd" >/dev/null 2>&1 || missing=1
    done
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || missing=1
    if [[ $XM_OS == alpine ]]; then
        for cmd in setpriv runuser rc-service supervise-daemon; do command -v "$cmd" >/dev/null 2>&1 || missing=1; done
        [[ $missing -eq 0 ]] || apk add --no-cache bash ca-certificates curl jq unzip openssl python3 flock runuser setpriv iproute2 logrotate openrc musl-utils || return 1
    else
        command -v systemctl >/dev/null 2>&1 || missing=1
        if [[ $missing -ne 0 ]]; then
            apt-get update || return 1
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bash ca-certificates curl jq unzip openssl python3 util-linux iproute2 logrotate systemd || return 1
        fi
    fi
    for cmd in curl jq unzip openssl python3 flock ss logrotate; do
        command -v "$cmd" >/dev/null 2>&1 || { _platform_error "依赖安装后仍缺少 $cmd"; return 1; }
    done
    _platform_dependency_record
}

platform_prepare() {
    _platform_paths || return 1
    [[ -n ${XM_ROOT:-} ]] || _platform_root || return 1
    local dir
    # Preflight all targets before creating resources. Never adopt somebody else's directory.
    for dir in "$XM_HOME" "$XM_ETC" "$XM_DATA" "$XM_LOG"; do
        _platform_no_symlink "$dir" || return 1
        if [[ -e $dir && ! -d $dir ]]; then _platform_error "路径不是目录：$dir"; return 1; fi
        if [[ -d $dir ]] && ! _platform_owned_dir "$dir"; then
            [[ -z $(find "$dir" -mindepth 1 -maxdepth 1 -print -quit) ]] || { _platform_error "拒绝接管未标记目录：$dir"; return 1; }
        fi
    done
    if [[ -z ${XM_ROOT:-} ]]; then
        local entry uid home shell
        entry=$(getent passwd xray-manager || true)
        if [[ -n $entry ]]; then
            IFS=: read -r _ _ uid _ _ home shell <<< "$entry"
            [[ $uid -ne 0 && $home == /var/lib/xray-manager && ( $shell == /usr/sbin/nologin || $shell == /sbin/nologin ) ]] || {
                _platform_error '现有 xray-manager 账户不符合专用服务账户要求。'; return 1;
            }
            [[ -f /var/lib/xray-manager/.xray-manager-account && ! -L /var/lib/xray-manager/.xray-manager-account ]] || {
                _platform_error '现有 xray-manager 账户未由本项目创建。'; return 1;
            }
        else
            getent group xray-manager >/dev/null 2>&1 && { _platform_error '同名组已存在，拒绝接管。'; return 1; }
            if [[ ${XM_OS:-} == alpine ]]; then
                addgroup -S xray-manager && adduser -S -D -H -h /var/lib/xray-manager -s /sbin/nologin -G xray-manager xray-manager || return 1
            else
                groupadd --system xray-manager && useradd --system --no-create-home --home-dir /var/lib/xray-manager --shell /usr/sbin/nologin --gid xray-manager xray-manager || return 1
            fi
        fi
    fi
    for dir in "$XM_HOME" "$XM_ETC" "$XM_DATA" "$XM_LOG"; do
        mkdir -p -- "$dir" || return 1
        chmod 0750 "$dir" || return 1
        printf 'xray-manager:1\n' > "$dir/.xray-manager-owned" || return 1
        chmod 0600 "$dir/.xray-manager-owned" || return 1
        [[ -n ${XM_ROOT:-} ]] || chown root:xray-manager "$dir" "$dir/.xray-manager-owned" || return 1
    done
    _platform_no_symlink "$XM_HOME/bin" || return 1
    mkdir -p -- "$XM_HOME/bin" || return 1
    chmod 0755 "$XM_HOME" "$XM_HOME/bin" || return 1
    if [[ -z ${XM_ROOT:-} ]]; then
        printf 'xray-manager:1\n' > "$XM_DATA/.xray-manager-account" || return 1
        chmod 0600 "$XM_DATA/.xray-manager-account" || return 1
        chown root:root "$XM_DATA/.xray-manager-account" "$XM_HOME" "$XM_HOME/bin" || return 1
        _platform_dependency_record || return 1
    fi
}

# Verify the complete archive before extraction, and copy only the regular ELF binary.
platform_fetch_core() (
    local version=${1:-} dest=${2:-} asset tmp url
    [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { _platform_error '核心版本必须为 v数字.数字.数字。'; return 1; }
    [[ -n $dest && $dest == /* && ! -e $dest && ! -L $dest ]] || { _platform_error '下载目标必须是尚不存在的绝对路径。'; return 1; }
    _platform_no_symlink "$dest" || return 1
    case ${XM_ARCH:-} in amd64) asset=Xray-linux-64.zip ;; arm64) asset=Xray-linux-arm64-v8a.zip ;; *) _platform_error '请先调用 platform_detect 设置支持的架构。'; return 1 ;; esac
    [[ -d ${dest%/*} ]] || { _platform_error '下载目标父目录不存在。'; return 1; }
    tmp=$(mktemp -d "${dest%/*}/.xray-download.XXXXXXXX") || return 1
    trap 'rm -rf -- "$tmp"' EXIT
    url="https://github.com/XTLS/Xray-core/releases/download/$version/$asset"
    curl --http1.1 --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 --connect-timeout 15 --max-time 300 --max-filesize 104857600 --output "$tmp/core.zip" "$url" || return 1
    curl --http1.1 --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 --connect-timeout 15 --max-time 60 --max-filesize 16384 --output "$tmp/core.dgst" "$url.dgst" || return 1
    _platform_python - "$tmp/core.zip" "$tmp/core.dgst" "$tmp/xray" "$XM_ARCH" <<'PY'
import hashlib, pathlib, re, stat, struct, sys, zipfile
archive, digest, output, arch = sys.argv[1:]
try:
    text = pathlib.Path(digest).read_text(encoding='ascii')
    expected = re.findall(r'^(?:SHA2?-?256)\s*=\s*([0-9a-fA-F]{64})\s*$', text, re.M)
    if len(expected) != 1:
        raise ValueError('missing or ambiguous SHA256 digest')
    with open(archive, 'rb') as f:
        h = hashlib.sha256()
        for data in iter(lambda: f.read(1024 * 1024), b''):
            h.update(data)
    if h.hexdigest() != expected[0].lower():
        raise ValueError('SHA256 mismatch')
    with zipfile.ZipFile(archive) as z:
        seen = set()
        total = 0
        for info in z.infolist():
            name = info.filename
            p = pathlib.PurePosixPath(name)
            mode = info.external_attr >> 16
            if name in seen or name.startswith('/') or '\\' in name or '..' in p.parts or '\x00' in name or stat.S_ISLNK(mode):
                raise ValueError('unsafe or duplicate archive path')
            if mode and stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError('unexpected archive file type')
            total += info.file_size
            if info.file_size > 150 * 1024 * 1024 or total > 300 * 1024 * 1024:
                raise ValueError('oversized archive')
            seen.add(name)
        info = z.getinfo('xray')
        if info.is_dir() or info.file_size < 64:
            raise ValueError('invalid xray executable')
        with z.open(info) as src, open(output, 'xb') as target:
            head = src.read(64)
            machine = 62 if arch == 'amd64' else 183
            if head[:6] != b'\x7fELF\x02\x01' or struct.unpack('<H', head[18:20])[0] != machine:
                raise ValueError('ELF architecture mismatch')
            target.write(head)
            for data in iter(lambda: src.read(1024 * 1024), b''):
                target.write(data)
except Exception as e:
    human('错误', '核心验证失败：' + str(e))
    sys.exit(1)
PY
    [[ $? -eq 0 ]] || return 1
    chmod 0755 "$tmp/xray" || return 1
    # Atomic create with hard-link: never replace a concurrent writer's destination.
    ln -- "$tmp/xray" "$dest" || return 1
)

_platform_init_available() {
    _platform_real || return 1
    [[ -n ${XM_INIT:-} ]] || platform_detect || return 1
    case $XM_INIT in
        systemd) [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null || { _platform_error 'systemd 未作为此系统的服务管理器运行。'; return 1; } ;;
        openrc) [[ -f /run/openrc/softlevel ]] && command -v rc-service >/dev/null || { _platform_error 'OpenRC 运行级别不可用。'; return 1; } ;;
        *) _platform_error '不支持的 init。'; return 1 ;;
    esac
}
_platform_check_service_file() {
    local file=$1
    _platform_no_symlink "$file" || return 1
    [[ ! -e $file ]] || _platform_owned_file "$file" || { _platform_error "拒绝覆盖其他项目文件：$file"; return 1; }
}
_platform_install_owned() {
    local source=$1 target=$2 mode=$3 temp
    _platform_check_service_file "$target" || return 1
    temp=$(mktemp "${target%/*}/.xray-manager.XXXXXXXX") || return 1
    if ! cp -- "$source" "$temp" || ! chmod "$mode" "$temp" || ! chown root:root "$temp" || ! mv -f -- "$temp" "$target"; then
        rm -f -- "$temp"; return 1
    fi
}

platform_install_service() {
    _platform_paths && _platform_init_available || return 1
    local dir service asset
    for dir in "$XM_HOME" "$XM_ETC" "$XM_DATA" "$XM_LOG"; do
        _platform_owned_dir "$dir" || { _platform_error "受管目录未准备：$dir"; return 1; }
    done
    _platform_check_service_file /etc/logrotate.d/xray-manager || return 1
    if [[ $XM_INIT == systemd ]]; then
        service=/etc/systemd/system/xray-manager.service; asset=xray-manager.service
        for dir in /usr/lib/systemd/system /lib/systemd/system; do
            [[ ! -e $dir/xray-manager.service ]] || { _platform_error '发现发行版目录中的同名服务，拒绝覆盖。'; return 1; }
        done
    else
        service=/etc/init.d/xray-manager; asset=xray-manager.openrc
        command -v setpriv >/dev/null 2>&1 || { _platform_error 'OpenRC 需要 setpriv。'; return 1; }
    fi
    _platform_check_service_file "$service" || return 1
    [[ -f $_XM_PLATFORM_ASSETS/$asset && -f $_XM_PLATFORM_ASSETS/xray-manager.logrotate ]] || { _platform_error '缺少随项目发布的服务模板。'; return 1; }
    _platform_install_owned "$_XM_PLATFORM_ASSETS/$asset" "$service" 0755 || return 1
    _platform_install_owned "$_XM_PLATFORM_ASSETS/xray-manager.logrotate" /etc/logrotate.d/xray-manager 0644 || return 1
    [[ $XM_INIT != systemd ]] || systemctl daemon-reload || return 1
}

platform_remove_service() {
    _platform_init_available || return 1
    local service
    platform_restart_schedule_preflight || return 1
    platform_restart_schedule disable || return 1
    if [[ $XM_INIT == systemd ]]; then service=/etc/systemd/system/xray-manager.service; else service=/etc/init.d/xray-manager; fi
    _platform_check_service_file "$service" && _platform_check_service_file /etc/logrotate.d/xray-manager || return 1
    if [[ -e $service ]]; then
        platform_service stop || return 1
        platform_service disable || return 1
        rm -f -- "$service" || return 1
    fi
    [[ ! -e /etc/logrotate.d/xray-manager ]] || rm -f -- /etc/logrotate.d/xray-manager || return 1
    [[ $XM_INIT != systemd ]] || systemctl daemon-reload || return 1
    # Preserve dedicated account and private data for reinstall or explicit shell cleanup.
}

platform_service() {
    local action=${1:-} service
    case $action in start|stop|restart|status|enable|disable) ;; *) _platform_error '未知服务操作。'; return 1 ;; esac
    _platform_init_available || return 1
    if [[ $XM_INIT == systemd ]]; then service=/etc/systemd/system/xray-manager.service; else service=/etc/init.d/xray-manager; fi
    _platform_owned_file "$service" || { _platform_error '服务不属于本项目或尚未安装。'; return 1; }
    if [[ $XM_INIT == systemd ]]; then
        if [[ $action == status ]]; then systemctl is-active --quiet xray-manager.service; else systemctl "$action" xray-manager.service; fi
    else
        case $action in
            enable) rc-update add xray-manager default ;;
            disable)
                if rc-update show default | grep -q '^[[:space:]]*xray-manager[[:space:]]*|'; then
                    rc-update del xray-manager default
                fi ;;
            *) rc-service xray-manager "$action" ;;
        esac
    fi
}

platform_logs() {
    local lines=${1:-50}
    [[ $lines =~ ^[0-9]+$ && ${#lines} -le 4 ]] && ((10#$lines >= 1 && 10#$lines <= 1000)) || { _platform_error '日志行数必须为 1..1000。'; return 1; }
    _platform_init_available || return 1
    if [[ $XM_INIT == systemd ]]; then
        journalctl --unit xray-manager.service --no-pager --output short --lines "$((10#$lines))"
    else
        [[ -f ${XM_LOG:-/var/log/xray-manager}/console.log && ! -L ${XM_LOG:-/var/log/xray-manager}/console.log ]] || { _platform_error '暂无日志。'; return 1; }
        tail -n "$((10#$lines))" -- "${XM_LOG:-/var/log/xray-manager}/console.log"
    fi
}

platform_port_available() {
    local port=${1:-} tcp udp
    [[ $port =~ ^[0-9]+$ && ${#port} -le 5 ]] && ((10#$port >= 1 && 10#$port <= 65535)) || { _platform_error '端口必须为 1..65535。'; return 1; }
    command -v ss >/dev/null 2>&1 || { _platform_error '缺少 ss，无法安全检查端口。'; return 1; }
    tcp=$(ss -H -ltn "sport = :$((10#$port))") && udp=$(ss -H -lun "sport = :$((10#$port))") || return 1
    [[ -z $tcp && -z $udp ]] || { _platform_error "端口 $port 已被 TCP 或 UDP 监听占用。"; return 1; }
}

_platform_core_pid() {
    _platform_python - "$XM_BIN" <<'PYCORE'
import glob, os, pwd, sys
try:
    uid = pwd.getpwnam('xray-manager').pw_uid
    found = []
    for p in glob.glob('/proc/[0-9]*'):
        try:
            if os.stat(p).st_uid == uid and os.readlink(p + '/exe') == sys.argv[1]:
                found.append(p.rsplit('/', 1)[-1])
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
    if len(found) != 1:
        raise ValueError('expected one dedicated Xray process')
    print(found[0])
except Exception as e:
    human('错误', '核心进程检查失败：' + str(e))
    sys.exit(1)
PYCORE
}

platform_health() {
    _platform_paths || return 1
    local port type tcp udp nodes pid pid_after
    platform_service status >/dev/null 2>&1 || { _platform_error 'Xray 服务未运行。'; return 1; }
    [[ -x $XM_BIN && -f $XM_ETC/config.json && -f $XM_ETC/state.json ]] || return 1
    pid=$(_platform_core_pid) || return 1
    "$XM_BIN" run -test -config "$XM_ETC/config.json" >/dev/null 2>&1 || { _platform_error '核心拒绝当前配置。'; return 1; }
    nodes=$(jq -r '.nodes | if type != "array" then error("nodes must be array") else .[] | select(.type!="anytls" and .type!="hysteria2" and .type!="tuicv5") | [.port,.type] | @tsv end' "$XM_ETC/state.json") || return 1
    sleep 1
    platform_service status >/dev/null 2>&1 || { _platform_error 'Xray 启动后退出。'; return 1; }
    pid_after=$(_platform_core_pid) || return 1
    [[ $pid_after == "$pid" ]] || { _platform_error 'Xray 核心进程不稳定。'; return 1; }
    [[ -n $nodes ]] || return 0
    while IFS=$'\t' read -r port type; do
        [[ $port =~ ^[0-9]+$ && ${#port} -le 5 ]] && ((10#$port >= 1 && 10#$port <= 65535)) || return 1
        tcp=$(ss -H -ltnp "sport = :$port") || return 1
        [[ $tcp == *"pid=$pid,"* ]] || { _platform_error "Xray 核心未监听 TCP 端口：$port"; return 1; }
        if [[ $type == shadowsocks ]]; then
            udp=$(ss -H -lunp "sport = :$port") || return 1
            [[ $udp == *"pid=$pid,"* ]] || { _platform_error "Xray 核心未监听 Shadowsocks UDP 端口：$port"; return 1; }
        fi
    done <<< "$nodes"
}

# Read-only helpers for interactive setup. No release tag or network response is executed.
platform_release_choices() (
    local tmp page count total_started=$SECONDS remaining max_time=8
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/xray-manager-releases.XXXXXXXX") || return 1
    trap 'rm -rf -- "$tmp"' EXIT
    printf '[]\n' > "$tmp/records.json" || return 1
    for page in 1 2 3 4 5; do
        remaining=$((40 - (SECONDS - total_started)))
        ((remaining > 0)) || { _platform_error '官方版本查询超时，请稍后重试。'; return 1; }
        ((remaining >= max_time)) || max_time=$remaining
        if ! curl --http1.1 --silent --show-error --fail --location --max-redirs 2 \
            --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --connect-timeout 3 --max-time "$max_time" --max-filesize 16777216 \
            --limit-rate 4M --header 'Accept: application/vnd.github+json' \
            --header 'X-GitHub-Api-Version: 2022-11-28' \
            --output "$tmp/page.json" \
            "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=100&page=$page"; then
            _platform_error '无法查询 Xray 官方版本（网络失败或 API 限流），请稍后重试。'; return 1
        fi
        count=$(_platform_python - "$tmp/page.json" "$tmp/records.json" <<'PYRELEASE'
import datetime, json, pathlib, re, sys
page, records = map(pathlib.Path, sys.argv[1:])
try:
    if page.stat().st_size > 16 * 1024 * 1024:
        raise ValueError('API response exceeds size limit')
    releases = json.loads(page.read_text(encoding='utf-8'))
    if not isinstance(releases, list) or len(releases) > 100:
        raise ValueError('API must return an array of at most 100 releases')
    previous = json.loads(records.read_text(encoding='utf-8'))
    seen = {r['tag'] for r in previous}
    unsupported = False
    for release in releases:
        if not isinstance(release, dict) or type(release.get('draft')) is not bool:
            raise ValueError('invalid release draft field')
        if release['draft']:
            continue
        if type(release.get('prerelease')) is not bool:
            raise ValueError('invalid release prerelease field')
        tag, published = release.get('tag_name'), release.get('published_at')
        if not isinstance(tag, str) or len(tag) > 64:
            raise ValueError('invalid release tag field')
        if not isinstance(published, str) or not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z', published):
            raise ValueError('invalid published_at field')
        datetime.datetime.strptime(published, '%Y-%m-%dT%H:%M:%SZ')
        if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag):
            unsupported = True
            continue
        if tag in seen:
            continue
        seen.add(tag)
        previous.append({'channel': 'preview' if release['prerelease'] else 'stable', 'tag': tag, 'published': published})
    if unsupported:
        human('信息', '已过滤不支持的版本标签；本脚本支持 v数字.数字.数字。')
    records.write_text(json.dumps(previous), encoding='utf-8')
    print(len(releases))
except Exception as e:
    human('错误', '官方版本响应验证失败：' + str(e))
    sys.exit(1)
PYRELEASE
        ) || return 1
        rm -f -- "$tmp/page.json" || return 1
        if ((count < 100)); then
            _platform_python - "$tmp/records.json" <<'PYCHOICES'
import json, sys
records = json.load(open(sys.argv[1], encoding='utf-8'))
lines = []
for channel in ('stable', 'preview'):
    choices = sorted((r for r in records if r['channel'] == channel), key=lambda r: r['published'], reverse=True)[:2]
    for r in choices:
        lines.append('\t'.join((channel, r['tag'], r['published'])))
if not lines:
    human('错误', '官方版本列表没有可用的 v数字.数字.数字 版本。')
    sys.exit(1)
print('\n'.join(lines))
PYCHOICES
            return $?
        fi
    done
    _platform_error '官方版本列表超过查询上限，无法确认最新版本，请稍后重试。'
    return 1
)

platform_public_ip() (
    local tmp url address
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/xray-manager-address.XXXXXXXX") || return 1
    trap 'rm -rf -- "$tmp"' EXIT
    for url in https://api.ipify.org https://api64.ipify.org https://icanhazip.com; do
        if ! curl --http1.1 --silent --fail --location --max-redirs 2 \
            --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --connect-timeout 2 --max-time 5 --max-filesize 128 --limit-rate 128 \
            --output "$tmp/address" "$url"; then
            continue
        fi
        address=$(_platform_python - "$tmp/address" <<'PYADDRESS'
import ipaddress, pathlib, re, sys
try:
    raw = pathlib.Path(sys.argv[1]).read_bytes()
    if not raw or len(raw) > 128:
        raise ValueError('invalid response length')
    value = raw.decode('ascii').strip(' \t\r\n')
    if not re.fullmatch(r'[0-9A-Fa-f:.]+', value):
        raise ValueError('invalid IP characters')
    address = ipaddress.ip_address(value)
    if not address.is_global or address.is_multicast or address.is_reserved or address.is_unspecified or address.is_loopback or address.is_link_local:
        raise ValueError('not a unicast public IP address')
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None and not address.ipv4_mapped.is_global:
        raise ValueError('private mapped IPv4 address')
    print(address.compressed)
except Exception:
    sys.exit(1)
PYADDRESS
        ) || continue
        printf '%s\n' "$address"
        return 0
    done
    _platform_error '无法检测有效公网 IPv4/IPv6，请手动填写地址或取消。'
    return 1
)

# Optional explicit state path; by default inspect the active project state if installed.
platform_random_port() (
    local state=${1:-${XM_STATE:-${XM_ETC:-${XM_ROOT:-}/etc/xray-manager}/state.json}} used='' hex value port attempt
    (($# <= 1)) || { _platform_error '随机端口最多接受一个状态文件参数。'; return 1; }
    command -v ss >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 || { _platform_error '随机端口需要 ss 和 openssl。'; return 1; }
    if [[ -e $state || -L $state || $# -eq 1 ]]; then
        [[ -f $state && -r $state && ! -L $state ]] || { _platform_error '无法安全读取节点状态，未生成随机端口。'; return 1; }
        used=$(_platform_python - "$state" <<'PYPORTS'
import json, pathlib, sys
try:
    p = pathlib.Path(sys.argv[1])
    if p.stat().st_size > 16 * 1024 * 1024:
        raise ValueError('state too large')
    state = json.loads(p.read_text(encoding='utf-8'))
    if not isinstance(state, dict) or not isinstance(state.get('nodes'), list):
        raise ValueError('invalid state nodes')
    ports = []
    for node in state['nodes']:
        if not isinstance(node, dict) or type(node.get('port')) is not int or not 1 <= node['port'] <= 65535:
            raise ValueError('invalid state port')
        ports.append(str(node['port']))
    print(' '.join(ports))
except Exception as e:
    human('错误', '节点端口读取失败：' + str(e))
    sys.exit(1)
PYPORTS
        ) || return 1
    fi
    for ((attempt=0; attempt<64; attempt++)); do
        hex=$(openssl rand -hex 2) || { _platform_error '随机数生成失败。'; return 1; }
        [[ $hex =~ ^[0-9a-fA-F]{4}$ ]] || { _platform_error '随机数输出不合法。'; return 1; }
        value=$((16#$hex))
        # Rejection sampling avoids modulo bias over the 64512 non-privileged ports.
        ((value < 64512)) || continue
        port=$((1024 + value))
        [[ " $used " != *" $port "* ]] || continue
        if platform_port_available "$port" 2>/dev/null; then
            printf '%s\n' "$port"
            return 0
        fi
    done
    _platform_error '尝试 64 次后未找到空闲端口，请手动填写。'
    return 1
)

# Optional daily restart scheduler. All commands use fixed project names and paths.
# Read status as: enabled|disabled<TAB>HH:MM|-<TAB>local timezone<TAB>next|-.
_platform_schedule_time() { [[ ${1:-} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }
_platform_schedule_files() {
    printf '%s\n' "$XM_ETC/restart-schedule"
    if [[ $XM_INIT == systemd ]]; then
        printf '%s\n' /etc/systemd/system/xray-manager-restart.service /etc/systemd/system/xray-manager-restart.timer
    else
        printf '%s\n' /etc/init.d/xray-manager-restart
    fi
}
_platform_schedule_link() {
    local link target
    if [[ $XM_INIT == systemd ]]; then
        link=/etc/systemd/system/timers.target.wants/xray-manager-restart.timer
        target=/etc/systemd/system/xray-manager-restart.timer
    else
        link=/etc/runlevels/default/xray-manager-restart
        target=/etc/init.d/xray-manager-restart
    fi
    _platform_no_symlink "${link%/*}" || return 1
    if [[ -e $link || -L $link ]]; then
        [[ -L $link && $(readlink "$link") == "$target" ]] || { _platform_error "定时重启开机链接不属于本项目：$link"; return 1; }
        _platform_owned_file "$target" || { _platform_error '定时重启开机链接缺少对应受管服务。'; return 1; }
    fi
}
platform_restart_schedule_preflight() {
    _platform_paths && _platform_init_available || return 1
    local file dir
    _platform_owned_dir "$XM_ETC" || { _platform_error '配置目录缺少所有权标记。'; return 1; }
    while IFS= read -r file; do _platform_check_service_file "$file" || return 1; done < <(_platform_schedule_files)
    _platform_schedule_link || return 1
    if [[ $XM_INIT == systemd ]]; then
        for dir in /usr/lib/systemd/system /lib/systemd/system /run/systemd/system; do
            for file in xray-manager-restart.service xray-manager-restart.timer xray-manager-restart.service.d xray-manager-restart.timer.d; do
                [[ ! -e $dir/$file && ! -L $dir/$file ]] || { _platform_error "发现其他位置的同名定时资源：$dir/$file"; return 1; }
            done
        done
        for file in /etc/systemd/system/xray-manager-restart.service.d /etc/systemd/system/xray-manager-restart.timer.d; do
            [[ ! -e $file && ! -L $file ]] || { _platform_error "拒绝接管带外部覆盖配置的定时资源：$file"; return 1; }
        done
    else
        _platform_schedule_openrc_overrides || return 1
        _platform_schedule_pid_preflight || return 1
        _platform_no_symlink "$XM_LOG/restart-schedule.log" || return 1
        _platform_no_symlink "$XM_HOME/assets/xray-manager-restart.py" || return 1
        if [[ -e $XM_HOME/assets/xray-manager-restart.py ]]; then
            _platform_owned_file "$XM_HOME/assets/xray-manager-restart.py" || { _platform_error '定时调度程序不属于本项目。'; return 1; }
        fi
    fi
}
_platform_schedule_command() (
    # A long-lived scheduler must never retain the manager's flock descriptor.
    if [[ ${XM_LOCK_FD:-} =~ ^[0-9]+$ ]] && [[ -e /proc/self/fd/$XM_LOCK_FD ]]; then exec {XM_LOCK_FD}>&-; fi
    unset TZ
    "$@"
)
_platform_schedule_enabled() {
    if [[ $XM_INIT == systemd ]]; then
        systemctl is-enabled --quiet xray-manager-restart.timer
    else
        [[ -L /etc/runlevels/default/xray-manager-restart ]]
    fi
}
_platform_schedule_running() {
    if [[ $XM_INIT == systemd ]]; then
        systemctl is-active --quiet xray-manager-restart.timer
    else
        rc-service xray-manager-restart status >/dev/null 2>&1
    fi
}
_platform_schedule_control() {
    local action=$1
    if [[ $XM_INIT == systemd ]]; then
        _platform_schedule_command systemctl "$action" xray-manager-restart.timer
    else
        case $action in
            enable) _platform_schedule_command rc-update add xray-manager-restart default ;;
            disable)
                if _platform_schedule_enabled; then _platform_schedule_command rc-update del xray-manager-restart default; fi ;;
            *) _platform_schedule_command rc-service xray-manager-restart "$action" ;;
        esac
    fi
}
_platform_schedule_read_time() {
    local file=$XM_ETC/restart-schedule marker time
    local extra
    [[ -f $file && ! -L $file ]] || return 1
    # shellcheck disable=SC2034
    { IFS= read -r marker && IFS= read -r time && ! IFS= read -r extra; } < "$file" || return 1
    [[ $marker == '# xray-manager-owned:1' ]] && _platform_schedule_time "$time" || return 1
    printf '%s\n' "$time"
}
_platform_schedule_local_next() {
    _platform_python - "${1:--}" <<'PYNEXT'
import datetime, os, time, sys
os.environ.pop('TZ', None)
time.tzset()
now = datetime.datetime.now().astimezone()
zone = now.strftime('%Z %z')
if sys.argv[1] == '-':
    print(zone + '\t-')
else:
    hour, minute = map(int, sys.argv[1].split(':'))
    # Local naive timestamp uses the machine's timezone/DST rules for that day.
    local_now = datetime.datetime.now()
    next_time = local_now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if next_time <= local_now:
        next_time += datetime.timedelta(days=1)
    print(zone + '\t' + next_time.astimezone().strftime('%Y-%m-%d %H:%M:%S %Z'))
PYNEXT
}
platform_restart_schedule() (
    local action=${1:-} time=${2:-} file tmp old_enabled=0 old_running=0 index=0 result=0
    case $action in
        status|disable) (($# == 1)) || { _platform_error 'status/disable 不接受时间参数。'; return 2; } ;;
        set) (($# == 2)) && _platform_schedule_time "$time" || { _platform_error '时间必须为 00:00..23:59，例如 04:00（每天，本机时区）。'; return 2; } ;;
        *) _platform_error '定时重启操作为 status、set HH:MM 或 disable。'; return 2 ;;
    esac
    platform_restart_schedule_preflight || return 1
    if [[ $action == status ]]; then
        if [[ ! -e $XM_ETC/restart-schedule ]]; then
            printf 'disabled\t-\t'; _platform_schedule_local_next -; return $?
        fi
        time=$(_platform_schedule_read_time) || { _platform_error '定时配置格式无效。'; return 1; }
        if _platform_schedule_enabled && _platform_schedule_running; then
            printf 'enabled\t%s\t' "$time"
            if [[ $XM_INIT == systemd ]]; then
                local zone next
                zone=$(_platform_schedule_local_next -) || return 1
                zone=${zone%%$'\t'*}
                next=$(systemctl show --property=NextElapseUSecRealtime --value xray-manager-restart.timer) || return 1
                [[ -n $next && $next != n/a ]] || next=-
                printf '%s\t%s\n' "$zone" "$next"
            else _platform_schedule_local_next "$time"; fi
        else
            printf 'disabled\t%s\t' "$time"; _platform_schedule_local_next -
        fi
        return $?
    fi
    if [[ $action == disable && ! -e $XM_ETC/restart-schedule ]]; then
        local resources=0
        while IFS= read -r file; do [[ ! -e $file ]] || resources=1; done < <(_platform_schedule_files)
        if ((resources == 0)); then return 0; fi
    fi
    [[ -x $XM_HOME/xray-manager.sh ]] || { _platform_error '管理程序尚未安装。'; return 1; }
    _platform_owned_file "$([[ $XM_INIT == systemd ]] && printf /etc/systemd/system/xray-manager.service || printf /etc/init.d/xray-manager)" || { _platform_error '请先安装本项目核心服务。'; return 1; }
    if [[ $XM_INIT == openrc && $action == set ]]; then
        [[ -f $XM_HOME/assets/xray-manager-restart.py ]] && _platform_owned_file "$XM_HOME/assets/xray-manager-restart.py" || { _platform_error '缺少本项目 Python 调度程序，请更新管理脚本。'; return 1; }
        command -v python3 >/dev/null 2>&1 || { _platform_error '缺少 Python3 调度依赖。'; return 1; }
    fi
    tmp=$(umask 077; mktemp -d "$XM_ETC/.restart-schedule.XXXXXXXX") || return 1
    trap 'rm -rf -- "$tmp"' EXIT
    local -a files=()
    while IFS= read -r file; do
        files+=("$file")
        if [[ -e $file ]]; then cp -p -- "$file" "$tmp/old-$index" || return 1; fi
        index=$((index+1))
    done < <(_platform_schedule_files)
    _platform_schedule_enabled && old_enabled=1
    _platform_schedule_running && old_running=1
    _platform_schedule_restore() {
        local i
        _platform_schedule_running && _platform_schedule_control stop >/dev/null 2>&1 || true
        _platform_schedule_enabled && _platform_schedule_control disable >/dev/null 2>&1 || true
        for ((i=0; i<${#files[@]}; i++)); do
            _platform_no_symlink "${files[i]}" || return 1
            if [[ -e $tmp/old-$i ]]; then
                _platform_install_owned "$tmp/old-$i" "${files[i]}" "$(python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$tmp/old-$i")" || return 1
            else rm -f -- "${files[i]}" || return 1; fi
        done
        [[ $XM_INIT != systemd ]] || _platform_schedule_command systemctl daemon-reload || return 1
        ((old_enabled == 0)) || _platform_schedule_control enable || return 1
        ((old_running == 0)) || _platform_schedule_control start || return 1
    }
    _platform_schedule_apply() {
        ((old_running == 0)) || _platform_schedule_control stop || return 1
        if [[ $action == disable ]]; then
            ((old_enabled == 0)) || _platform_schedule_control disable || return 1
            platform_restart_schedule_preflight || return 1
            for file in "${files[@]}"; do rm -f -- "$file" || return 1; done

        else
            printf '# xray-manager-owned:1\n%s\n' "$time" > "$tmp/state" || return 1
            _platform_install_owned "$tmp/state" "$XM_ETC/restart-schedule" 0600 || return 1
            if [[ $XM_INIT == systemd ]]; then
                sed "s/@TIME@/$time/" "$_XM_PLATFORM_ASSETS/xray-manager-restart.timer" > "$tmp/timer" || return 1
                _platform_install_owned "$_XM_PLATFORM_ASSETS/xray-manager-restart.service" /etc/systemd/system/xray-manager-restart.service 0644 &&
                    _platform_install_owned "$tmp/timer" /etc/systemd/system/xray-manager-restart.timer 0644 || return 1
            else
                _platform_install_owned "$_XM_PLATFORM_ASSETS/xray-manager-restart.openrc" /etc/init.d/xray-manager-restart 0755 || return 1
            fi
        fi
        [[ $XM_INIT != systemd ]] || _platform_schedule_command systemctl daemon-reload || return 1
        if [[ $action == set ]]; then
            _platform_schedule_control enable && _platform_schedule_control start && _platform_schedule_running || return 1
        fi
    }
    if ! _platform_schedule_apply; then
        result=1
        if _platform_schedule_restore; then _platform_error '定时重启修改失败，已恢复原配置和启停状态。'; else _platform_error '定时重启修改及恢复失败，请检查专属调度服务。'; fi
    fi
    return "$result"
)

# Global user entrypoint; XM_ROOT supports root-free filesystem isolation tests.
platform_shortcut_preflight() {
    _platform_paths || return 1
    [[ -n ${XM_ROOT:-} ]] || _platform_root || return 1
    local parent=${XM_ROOT:-}/usr/local/bin
    _platform_no_symlink "$parent" || return 1
    while [[ $parent != / && -n $parent ]]; do
        [[ ! -e $parent || -d $parent ]] || { _platform_error "xy 入口父路径不是目录：$parent"; return 1; }
        parent=${parent%/*}
    done
    _platform_check_service_file "${XM_ROOT:-}/usr/local/bin/xy"
}
platform_shortcut_install() {
    platform_shortcut_preflight || return 1
    local target=${XM_ROOT:-}/usr/local/bin/xy source=$_XM_PLATFORM_ASSETS/xy temp
    _platform_owned_file "$source" || { _platform_error '缺少本项目 xy 入口模板。'; return 1; }
    mkdir -p -- "${target%/*}" || return 1
    _platform_no_symlink "${target%/*}" || return 1
    if [[ -z ${XM_ROOT:-} ]]; then
        _platform_install_owned "$source" "$target" 0755
    else
        temp=$(mktemp "${target%/*}/.xray-manager.XXXXXXXX") || return 1
        if ! cp -- "$source" "$temp" || ! chmod 0755 "$temp" || ! mv -f -- "$temp" "$target"; then
            rm -f -- "$temp"; return 1
        fi
    fi
}
platform_shortcut_remove() {
    platform_shortcut_preflight || return 1
    [[ ! -e ${XM_ROOT:-}/usr/local/bin/xy ]] || rm -f -- "${XM_ROOT:-}/usr/local/bin/xy"
}

# OpenRC loads service-specific conf.d overlays before every service operation.
# Reject them rather than sourcing, overwriting or deleting externally owned code.
# Optional root is passed by isolated test fixtures in tests/test-schedule.sh.
# shellcheck disable=SC2120
_platform_schedule_openrc_overrides() {
    local root=${1:-} dir file
    for dir in /etc /usr/local/etc /usr/lib/rc /lib/rc; do
        for file in "$root$dir/conf.d/xray-manager-restart" "$root$dir/conf.d/xray-manager-restart."*; do
            [[ ! -e $file && ! -L $file ]] || { _platform_error "定时服务存在外部 OpenRC 覆盖配置：$file"; return 1; }
        done
        if [[ $dir != /etc ]]; then
            file=$root$dir/init.d/xray-manager-restart
            [[ ! -e $file && ! -L $file ]] || { _platform_error "其他 OpenRC 路径存在同名服务：$file"; return 1; }
        fi
    done
    for file in "$root/etc/runlevels/"*/xray-manager-restart; do
        [[ -e $file || -L $file ]] || continue
        [[ $file == "$root/etc/runlevels/default/xray-manager-restart" ]] || { _platform_error "定时服务存在外部运行级别链接：$file"; return 1; }
    done
}


# OpenRC supervise-daemon may create its pidfile before launching the scheduler.
# Never allow that write to follow a symlink or replace an unclaimed runtime file.
# Optional root is passed by isolated test fixtures in tests/test-schedule.sh.
# shellcheck disable=SC2120
_platform_schedule_pid_preflight() {
    local root=${1:-} pid
    pid=$root/run/xray-manager-restart.pid
    _platform_no_symlink "$pid" || return 1
    if [[ -e $pid ]]; then
        [[ -f $pid ]] || { _platform_error "定时服务 PID 路径不是普通文件：$pid"; return 1; }
        _platform_owned_file "$root/etc/init.d/xray-manager-restart" || { _platform_error "定时服务 PID 文件没有对应受管服务，拒绝接管：$pid"; return 1; }
    fi
}

# Optional sing-box engine, pinned official archive digests (release v1.14.2).
_platform_extra_paths() {
    _platform_paths || return 1
    XM_EXTRA_BIN=${XM_EXTRA_BIN:-$XM_HOME/bin/sing-box}
    XM_EXTRA_CONFIG=${XM_EXTRA_CONFIG:-$XM_ETC/extra.json}
    [[ $XM_EXTRA_BIN == "$XM_HOME/bin/sing-box" && $XM_EXTRA_CONFIG == "$XM_ETC/extra.json" ]] || { _platform_error '辅助核心必须使用固定受管路径。'; return 1; }
}
_platform_extra_asset() {
    case ${XM_ARCH:-}:${XM_LIBC:-} in
        amd64:glibc) printf 'sing-box-1.14.2-linux-amd64-glibc\t5c7bc18461827b28d0e5ee7e89d33b276d3ff7c818531104c8e8d26d85b0656e\n' ;;
        amd64:musl) printf 'sing-box-1.14.2-linux-amd64-musl\t8f6cb4bcf94d2b33c65d52e0d5b142db29a938336f1ff7267f397ac3758fc297\n' ;;
        arm64:glibc) printf 'sing-box-1.14.2-linux-arm64-glibc\t87db5c3a96ebad1c44c0be1fe7955db2f76b8c97bbc0ed62173063d675e078cf\n' ;;
        arm64:musl) printf 'sing-box-1.14.2-linux-arm64-musl\t675297394f9430cebb72b3c48ba8bce0d6f7c750a9d68a8f7f88c515c8255cd1\n' ;;
        *) _platform_error '不支持的辅助核心架构/libc。'; return 1 ;;
    esac
}
platform_extra_ensure() (
    _platform_extra_paths && _platform_real || return 1
    _platform_owned_dir "$XM_HOME" && _platform_owned_dir "$XM_ETC" || return 1
    _platform_no_symlink "$XM_EXTRA_BIN" && _platform_no_symlink "$XM_ETC/extra-core.sha256" || return 1
    local tmp asset digest version
    if [[ -e $XM_EXTRA_BIN ]]; then
        [[ -x $XM_EXTRA_BIN && -f $XM_ETC/extra-core.sha256 ]] || { _platform_error '现有辅助核心缺少本项目校验记录，拒绝接管。'; return 1; }
        _platform_python - "$XM_EXTRA_BIN" "$XM_ETC/extra-core.sha256" <<'PY'
import hashlib,pathlib,re,sys
b,p=map(pathlib.Path,sys.argv[1:])
if p.stat().st_size>128:sys.exit(1)
h=p.read_text().strip();actual=hashlib.sha256()
with b.open('rb') as f:
 for data in iter(lambda:f.read(1024*1024),b''):actual.update(data)
if not re.fullmatch('[0-9a-f]{64}',h) or actual.hexdigest()!=h:sys.exit(1)
PY
        [[ $? == 0 ]] || { _platform_error '现有辅助核心完整性检查失败。'; return 1; }
        version=$("$XM_EXTRA_BIN" version) || return 1
        [[ ${version%%$'\n'*} == 'sing-box version 1.14.2' ]] || { _platform_error '辅助核心版本必须为 1.14.2。'; return 1; }
        return 0
    fi
    [[ ! -e $XM_ETC/extra-core.sha256 ]] || { _platform_error '辅助核心校验记录存在但核心丢失，请检查受管目录。'; return 1; }
    IFS=$'\t' read -r asset digest < <(_platform_extra_asset)
    [[ -n $asset && $digest =~ ^[0-9a-f]{64}$ ]] || return 1
    tmp=$(umask 077; mktemp -d "$XM_ETC/.extra-download.XXXXXXXX") || return 1
    trap 'rm -rf -- "$tmp"' EXIT
    _platform_info '获取并校验辅助核心 sing-box 1.14.2。'
    curl --http1.1 --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 --connect-timeout 15 --max-time 300 --max-filesize 104857600 --output "$tmp/core.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/v1.14.2/$asset.tar.gz" || return 1
    _platform_extra_verify_archive "$tmp/core.tar.gz" "$digest" "$asset" "$XM_ARCH" "$tmp/core" "$tmp/hash"
    [[ $? == 0 ]] || return 1
    chmod 0755 "$tmp/core" && chmod 0600 "$tmp/hash" || return 1
    version=$("$tmp/core" version) || return 1
    [[ ${version%%$'\n'*} == 'sing-box version 1.14.2' ]] || { _platform_error '下载辅助核心版本与固定版本不符。'; return 1; }
    ln -- "$tmp/core" "$XM_EXTRA_BIN" || return 1
    if ! ln -- "$tmp/hash" "$XM_ETC/extra-core.sha256"; then rm -f -- "$XM_EXTRA_BIN"; return 1; fi
)
_platform_extra_service_path() {
    if [[ $XM_INIT == systemd ]]; then printf /etc/systemd/system/xray-manager-extra.service; else printf /etc/init.d/xray-manager-extra; fi
}
platform_extra_preflight() {
    _platform_extra_paths && _platform_init_available || return 1
    local file dir link target
    target=$(_platform_extra_service_path)
    for dir in "$XM_HOME" "$XM_ETC" "$XM_DATA" "$XM_LOG"; do _platform_owned_dir "$dir" || return 1; done
    _platform_check_service_file "$target" || return 1
    if [[ $XM_INIT == systemd ]]; then
        for dir in /etc/systemd/system /run/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
            file=$dir/xray-manager-extra.service.d
            [[ ! -e $file && ! -L $file ]] || { _platform_error "拒绝外部辅助服务覆盖：$file"; return 1; }
            [[ $dir == /etc/systemd/system || (! -e $dir/xray-manager-extra.service && ! -L $dir/xray-manager-extra.service) ]] || { _platform_error '其他位置有同名辅助服务。'; return 1; }
        done
        link=/etc/systemd/system/multi-user.target.wants/xray-manager-extra.service
    else
        for dir in /etc /usr/local/etc /lib/rc /usr/lib/rc; do
            for file in "$dir/conf.d/xray-manager-extra" "$dir/conf.d/xray-manager-extra."*; do [[ ! -e $file && ! -L $file ]] || { _platform_error "拒绝外部辅助服务覆盖：$file"; return 1; }; done
            [[ $dir == /etc || (! -e $dir/init.d/xray-manager-extra && ! -L $dir/init.d/xray-manager-extra) ]] || { _platform_error '其他位置有同名辅助服务。'; return 1; }
        done
        _platform_no_symlink /run/xray-manager-extra.pid || return 1
        if [[ -e /run/xray-manager-extra.pid ]]; then [[ -f /run/xray-manager-extra.pid ]] && _platform_owned_file "$target" || return 1; fi
        _platform_no_symlink "$XM_LOG/extra-console.log" || return 1
        for link in /etc/runlevels/*/xray-manager-extra; do [[ ! -e $link && ! -L $link || $link == /etc/runlevels/default/xray-manager-extra ]] || { _platform_error '辅助服务存在外部运行级别。'; return 1; }; done
        link=/etc/runlevels/default/xray-manager-extra
    fi
    _platform_no_symlink "${link%/*}" || return 1
    [[ ! -e $link && ! -L $link || (-L $link && $(readlink "$link") == "$target") ]] || { _platform_error '辅助服务开机链接不属于本项目。'; return 1; }
}
platform_extra_install_service() {
    platform_extra_preflight || return 1
    local asset=xray-manager-extra.openrc target
    [[ $XM_INIT != systemd ]] || asset=xray-manager-extra.service
    target=$(_platform_extra_service_path)
    _platform_install_owned "$_XM_PLATFORM_ASSETS/$asset" "$target" 0755 || return 1
    [[ $XM_INIT != systemd ]] || _platform_schedule_command systemctl daemon-reload
}
platform_extra_service() {
    local action=${1:-} target
    case $action in start|stop|restart|status|enable|disable) ;; *) _platform_error '未知辅助服务操作。'; return 2 ;; esac
    platform_extra_preflight || return 1
    target=$(_platform_extra_service_path)
    if [[ ! -e $target ]]; then
        case $action in stop|disable) return 0 ;; *) return 1 ;; esac
    fi
    _platform_owned_file "$target" || return 1
    if [[ $action == start || $action == restart ]]; then
        "$XM_EXTRA_BIN" check -c "$XM_EXTRA_CONFIG" >/dev/null || return 1
    fi
    if [[ $XM_INIT == systemd ]]; then
        if [[ $action == status ]]; then systemctl is-active --quiet xray-manager-extra.service; else _platform_schedule_command systemctl "$action" xray-manager-extra.service; fi
    else
        case $action in
            enable) _platform_schedule_command rc-update add xray-manager-extra default ;;
            disable) [[ ! -L /etc/runlevels/default/xray-manager-extra ]] || _platform_schedule_command rc-update del xray-manager-extra default ;;
            *) _platform_schedule_command rc-service xray-manager-extra "$action" ;;
        esac
    fi
}
platform_extra_remove_service() {
    platform_extra_preflight || return 1
    platform_extra_service stop && platform_extra_service disable || return 1
    local target
    target=$(_platform_extra_service_path)
    rm -f -- "$target" || return 1
    [[ $XM_INIT != systemd ]] || _platform_schedule_command systemctl daemon-reload
}
platform_extra_health() {
    _platform_extra_paths || return 1
    platform_extra_service status >/dev/null 2>&1 || { _platform_error '辅助服务未运行。'; return 1; }
    local pid after nodes port type sockets
    pid=$(_platform_python - "$XM_EXTRA_BIN" <<'PY'
import glob,os,pwd,sys
uid=pwd.getpwnam('xray-manager').pw_uid;pids=[]
for p in glob.glob('/proc/[0-9]*'):
 try:
  if os.stat(p).st_uid==uid and os.readlink(p+'/exe')==sys.argv[1]:pids.append(p.rsplit('/',1)[-1])
 except (OSError,PermissionError):pass
if len(pids)!=1:sys.exit(1)
print(pids[0])
PY
    ) || return 1
    "$XM_EXTRA_BIN" check -c "$XM_EXTRA_CONFIG" >/dev/null 2>&1 || return 1
    sleep 1
    after=$(readlink "/proc/$pid/exe") || return 1
    [[ $after == "$XM_EXTRA_BIN" ]] && platform_extra_service status >/dev/null 2>&1 || return 1
    nodes=$(jq -r '.nodes[] | select(.type=="anytls" or .type=="hysteria2" or .type=="tuicv5") | [.port,.type] | @tsv' "$XM_ETC/state.json") || return 1
    while IFS=$'\t' read -r port type; do
        [[ -n $port ]] || continue
        [[ $port =~ ^[0-9]{1,5}$ ]] && ((10#$port>=1 && 10#$port<=65535)) || return 1
        if [[ $type == anytls ]]; then sockets=$(ss -H -ltnp "sport = :$port"); else sockets=$(ss -H -lunp "sport = :$port"); fi
        [[ $sockets == *"pid=$pid,"* ]] || { _platform_error "辅助核心未监听 $type 端口 $port。"; return 1; }
    done <<< "$nodes"
}
platform_extra_enabled() {
    platform_extra_preflight || return 1
    if [[ $XM_INIT == systemd ]]; then systemctl is-enabled --quiet xray-manager-extra.service; else [[ -L /etc/runlevels/default/xray-manager-extra ]]; fi
}

# Package inventory and addition ledger: data only, never source package names.
_platform_package_inventory() (
    set -o pipefail
    case ${XM_OS:-} in
        debian) dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' | awk -F '\t' '$2=="installed" {print $1}' ;;
        alpine) apk info ;;
        *) return 1 ;;
    esac | awk -v osname="$XM_OS" '
        BEGIN {printf "{\"os\":\"%s\",\"packages\":[",osname; sep=""; bad=0}
        {if ($0 !~ /^[a-z0-9][a-z0-9+._:-]*$/ || length($0)>128) {bad=1; exit 1} printf "%s\"%s\"",sep,$0; sep=","}
        END {if (bad) exit 1; print "]}"}'
)
platform_dependencies_snapshot() {
    _platform_real && platform_detect || return 1
    (($# <= 1)) || return 2
    local file=${1:-}
    if [[ -z $file ]]; then _platform_dependency_begin; return $?; fi
    [[ $file == /* && ! -e $file && ! -L $file ]] && _platform_no_symlink "$file" || return 1
    (umask 077; set -o noclobber; _platform_package_inventory > "$file") || return 1
}
_platform_dependency_begin() {
    local file=${XM_DEPENDENCY_SNAPSHOT_FILE:-}
    [[ -z ${_XM_DEPENDENCY_BEFORE:-} ]] || return 0
    if [[ -n $file ]]; then
        _platform_no_symlink "$file" && [[ -f $file && $(wc -c < "$file") -le 1048576 ]] || { _platform_error '依赖快照路径或大小无效。'; return 1; }
        _XM_DEPENDENCY_BEFORE=$(cat "$file") || return 1
    else _XM_DEPENDENCY_BEFORE=$(_platform_package_inventory) || return 1; fi

}
_platform_dependency_record() {
    [[ -n ${_XM_DEPENDENCY_BEFORE:-} ]] || return 0
    _platform_paths || return 1
    _platform_owned_dir "$XM_ETC" || return 0 # First install records after prepare.
    local target=$XM_ETC/dependency-ledger.json tmp
    _platform_no_symlink "$target" || return 1
    [[ ! -e $target || ( -f $target && $(wc -c < "$target") -le 1048576 ) ]] || return 1
    tmp=$(umask 077; mktemp -d "$XM_ETC/.dependency-ledger.XXXXXXXX") || return 1
    printf '%s\n' "$_XM_DEPENDENCY_BEFORE" > "$tmp/before" || { rm -rf "$tmp"; return 1; }
    _platform_package_inventory > "$tmp/after" || { rm -rf "$tmp"; return 1; }
    _platform_python - "$tmp/before" "$tmp/after" "$target" "$tmp/new" <<'PY'
import json,pathlib,re,sys
before,after,target,out=map(pathlib.Path,sys.argv[1:])
try:
 b=json.loads(before.read_text());a=json.loads(after.read_text())
 for inv in (b,a):
  assert set(inv)=={'os','packages'} and inv['os']==a['os'] and isinstance(inv['packages'],list)
  assert all(isinstance(p,str) and re.fullmatch('[a-z0-9][a-z0-9+._:-]{0,127}',p) for p in inv['packages'])
 added=set(a['packages'])-set(b['packages'])
 if target.exists():
  old=json.loads(target.read_text());assert old.get('owner')=='xray-manager:1' and old.get('os')==a['os']
  assert isinstance(old.get('baseline'),list) and isinstance(old.get('added'),list)
  assert all(isinstance(p,str) and re.fullmatch('[a-z0-9][a-z0-9+._:-]{0,127}',p) for p in old['baseline']+old['added'])
  # Never adopt a dependency that was present before this invocation but was
  # not already attributed to our installer (legacy/externally added package).
  baseline=set(old['baseline']) | (set(b['packages'])-set(old['added']))
  added=(set(old['added']) | added)-baseline
 else: baseline=set(b['packages'])
 out.write_text(json.dumps({'owner':'xray-manager:1','os':a['os'],'baseline':sorted(baseline),'added':sorted(added)})+'\n')
except Exception as e: human('错误', '依赖记录错误：'+str(e));sys.exit(1)
PY
    local result=$?
    if ((result == 0)); then chmod 0600 "$tmp/new" && chown root:root "$tmp/new" && mv -f -- "$tmp/new" "$target" || result=1; fi
    if ((result == 0)); then _XM_DEPENDENCY_BEFORE=; unset XM_DEPENDENCY_SNAPSHOT_FILE; fi
    rm -rf -- "$tmp"
    return "$result"
}
# Emit only removable, newly-added packages; preserve packages with external
# installed reverse dependencies. Simulation must not remove anything outside it.
_platform_dependency_plan() {
    local ledger=$1
    _platform_no_symlink "$ledger" && [[ -f $ledger && $(wc -c < "$ledger") -le 1048576 ]] || return 1
    _platform_python - "$ledger" "${XM_OS:-}" <<'PY'
import json,pathlib,re,subprocess,sys
try:
 j=json.loads(pathlib.Path(sys.argv[1]).read_text());osname=sys.argv[2]
 assert j.get('owner')=='xray-manager:1' and j.get('os')==osname
 assert isinstance(j.get('baseline'),list) and isinstance(j.get('added'),list)
 assert all(isinstance(p,str) and re.fullmatch('[a-z0-9][a-z0-9+._:-]{0,127}',p) for p in j['baseline']+j['added'])
 if osname=='debian':
  inventory=subprocess.check_output(['dpkg-query','-W','-f=${binary:Package}\t${db:Status-Status}\n'],text=True)
  installed={l.split('\t')[0] for l in inventory.splitlines() if l.endswith('\tinstalled')}
 else:installed=set(subprocess.check_output(['apk','info'],text=True).splitlines())
 protected={'openssh','openssh-server','openssh-client','openssh-sftp-server','alpine-base','busybox','apk-tools','apt','dpkg','libc6','musl','systemd','openrc','sudo'}
 if osname=='debian':
  essentials=subprocess.check_output(['dpkg-query','-W','-f=${binary:Package}\t${Essential}\n'],text=True)
  protected.update(l.split('\t')[0].split(':')[0] for l in essentials.splitlines() if l.endswith('\tyes'))
 passwd=subprocess.check_output(['getent','passwd'],text=True)
 if any(l.rsplit(':',1)[-1] in ('/bin/bash','/usr/bin/bash') for l in passwd.splitlines()):protected.add('bash')
 candidates=(set(j['added'])-set(j['baseline'])) & installed
 candidates={p for p in candidates if p.split(':')[0] not in protected}
 # Iteratively protect dependencies required by packages outside our final set.
 changed=True
 while changed:
  changed=False
  for p in sorted(candidates):
   if osname=='debian':
    text=subprocess.check_output(['apt-cache','rdepends','--installed',p],text=True)
    deps=set()
    for line in text.splitlines():
     if not line.startswith(' '):continue
     token=line.strip().lstrip('|').strip().split()[0]
     matches={x for x in installed if x==token or x.split(':')[0]==token}
     if not matches:deps.add('?')
     else:deps.update(matches)
   else:
    text=subprocess.check_output(['apk','info','--rdepends',p],text=True)
    deps=set()
    for line in text.splitlines():
     if not line or 'is required by:' in line:continue
     matches={x for x in installed if line==x or line.startswith(x+'-')}
     if not matches:deps.add('?')
     else:deps.update(matches)
   if deps-candidates:
    candidates.remove(p);changed=True
 retained=(set(j['added']) & installed)-candidates
 if retained:human('警告', '保留系统/共享/登录Shell依赖：'+', '.join(sorted(retained)))
 if not candidates:sys.exit(0)
 names=sorted(candidates)
 argv=['apt-get','--simulate','--no-auto-remove','purge','--']+names if osname=='debian' else ['apk','del','--simulate','--']+names
 text=subprocess.check_output(argv,stderr=subprocess.STDOUT,text=True)
 removed=set()
 for line in text.splitlines():
  assert not re.match(r'^(?:Inst|Conf)\s',line) and not re.search(r'(?:Installing|Upgrading|Downgrading)\s',line),'simulation would alter unrelated package state'
  match=re.match(r'^(?:Remv|Purg)\s+(\S+)',line) if osname=='debian' else re.search(r'(?:Purging|Removing)\s+(\S+)',line)
  if match:
   token=match[1]; matches={p for p in installed if p==token or p.split(':')[0]==token}
   assert len(matches)==1,'ambiguous removal';removed.update(matches)
 assert removed and removed<=candidates,'package simulation would exceed owned additions'
 for p in sorted(removed):print(p)
except Exception as e:human('错误', '依赖卸载计划无法安全确认：'+str(e));sys.exit(1)
PY
}
platform_dependency_cleanup() {
    _platform_real && platform_detect || return 1
    local ledger=${1:-${XM_ETC:-/etc/xray-manager}/dependency-ledger.json} plan package
    [[ -e $ledger || -L $ledger ]] || { _platform_warning '未发现本项目依赖记录，保留历史软件包。'; return 0; }
    plan=$(_platform_dependency_plan "$ledger") || return 1
    [[ -n $plan ]] || { _platform_info '未发现可安全删除的独占新增依赖；共享/系统/历史包保留。'; return 0; }
    local -a packages=()
    while IFS= read -r package; do packages+=("$package"); done <<< "$plan"
    # Re-run simulation immediately before mutation; never use auto-remove.
    [[ $(_platform_dependency_plan "$ledger") == "$plan" ]] || return 1
    if [[ $XM_OS == debian ]]; then DEBIAN_FRONTEND=noninteractive apt-get --no-auto-remove purge -y -- "${packages[@]}";
    else apk del -- "${packages[@]}"; fi
}

_platform_clean_files_preflight() {
    _platform_paths || return 1
    local dir
    for dir in "$XM_HOME" "$XM_ETC" "$XM_DATA" "$XM_LOG"; do
        _platform_no_symlink "$dir" && _platform_owned_dir "$dir" || { _platform_error "完全卸载拒绝未受管目录：$dir"; return 1; }
    done
    _platform_python - "$XM_HOME" "$XM_ETC" "$XM_DATA" "$XM_LOG" <<'PY'
import pathlib,re,sys
home,etc,data,logs=map(pathlib.Path,sys.argv[1:])
allowed={home:{'.xray-manager-owned','xray-manager.sh','install.sh','bin','lib','assets'},home/'bin':{'xray','xray.previous','sing-box'},home/'lib':{'common.sh','state.sh','platform.sh','protocol.sh'},home/'assets':{'xy','xray-manager.service','xray-manager.openrc','xray-manager.logrotate','xray-manager-restart.service','xray-manager-restart.timer','xray-manager-restart.openrc','xray-manager-restart.py','xray-manager-extra.service','xray-manager-extra.openrc'},etc:{'.xray-manager-owned','.manager.lock','state.json','config.json','extra.json','extra-core.sha256','core.previous-version','restart-schedule','dependency-ledger.json'},data:{'.xray-manager-owned','.xray-manager-account'},logs:{'.xray-manager-owned','console.log','extra-console.log','restart-schedule.log','last-error.log','last-extra-error.log'}}
try:
 for base in (home,etc,data,logs):
  for p in base.rglob('*'):
   if p.is_symlink():raise ValueError('symlink '+str(p))
   names=allowed.get(p.parent,set())
   extra=p.parent==etc and re.fullmatch(r'trojan-retired-backup\.[A-Za-z0-9]{8}',p.name)
   rotated=p.parent==logs and re.fullmatch(r'(console|extra-console|restart-schedule)\.log\.[1-4](?:\.gz)?',p.name)
   if p.name not in names and not extra and not rotated:raise ValueError('unknown file retained: '+str(p))
   if p.is_dir() and p not in allowed:raise ValueError('unexpected directory '+str(p))
   if not(p.is_dir() or p.is_file()):raise ValueError('non-regular file '+str(p))
except Exception as e:human('错误', '完全卸载预检失败：'+str(e));sys.exit(1)
PY
}
_platform_clean_account_preflight() {
    [[ -z ${XM_ROOT:-} ]] || return 0
    local account group uid gid entry name other_uid other_gid home shell
    account=$(getent passwd xray-manager || true)
    group=$(getent group xray-manager || true)
    [[ -n $account ]] || { [[ -z $group ]] || { _platform_error '同名组缺少受管账户。'; return 1; }; return 0; }
    [[ -f $XM_DATA/.xray-manager-account && $(cat "$XM_DATA/.xray-manager-account") == 'xray-manager:1' ]] || return 1
    IFS=: read -r name _ uid gid _ home shell <<< "$account"
    [[ $uid != 0 && $home == /var/lib/xray-manager && ( $shell == /sbin/nologin || $shell == /usr/sbin/nologin ) ]] || return 1
    [[ $group =~ ^xray-manager:[^:]*:$gid:(xray-manager)?$ ]] || { _platform_error '专用组被外部用户共享，拒绝删除账户。'; return 1; }
    while IFS=: read -r name _ other_uid other_gid _; do
        [[ $name == xray-manager || ( $other_uid != "$uid" && $other_gid != "$gid" ) ]] || { _platform_error '专用 UID/GID 被外部账户共享。'; return 1; }
    done < <(getent passwd)
    _platform_python - "$uid" "$XM_BIN" "$XM_HOME/bin/sing-box" <<'PY'
import glob,os,sys
uid=int(sys.argv[1]);allowed=set(sys.argv[2:])
for p in glob.glob('/proc/[0-9]*'):
 try:
  if os.stat(p).st_uid==uid and os.readlink(p+'/exe') not in allowed:raise ValueError('foreign process uses project account')
 except (FileNotFoundError,ProcessLookupError,PermissionError):pass
PY
}
platform_clean_uninstall_preflight() {
    _platform_clean_files_preflight && _platform_clean_account_preflight && platform_shortcut_preflight || return 1
    if [[ -z ${XM_ROOT:-} ]]; then
        platform_restart_schedule_preflight && platform_extra_preflight && _platform_main_resource_preflight || return 1
        local service
        [[ $XM_INIT != systemd ]] && service=/etc/init.d/xray-manager || service=/etc/systemd/system/xray-manager.service
        _platform_check_service_file "$service" && _platform_check_service_file /etc/logrotate.d/xray-manager || return 1
    fi
    if [[ -e $XM_ETC/dependency-ledger.json ]]; then
        _platform_dependency_plan "$XM_ETC/dependency-ledger.json" >/dev/null || { _platform_error '依赖移除计划无法安全确认，完全卸载尚未改变系统。'; return 1; }
    fi
}
platform_clean_uninstall() (
    platform_clean_uninstall_preflight || return 1
    local tmp='' ledger='' result=0 uid
    trap '[[ -z $tmp ]] || rm -rf -- "$tmp"' EXIT
    if [[ -e $XM_ETC/dependency-ledger.json ]]; then
        tmp=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/xray-manager-uninstall.XXXXXXXX") || return 1
        ledger=$tmp/ledger.json
        cp -- "$XM_ETC/dependency-ledger.json" "$ledger" || { rm -rf "$tmp"; return 1; }
    fi
    if [[ -z ${XM_ROOT:-} ]]; then
        platform_extra_remove_service && platform_remove_service && platform_shortcut_remove || { [[ -z $tmp ]] || rm -rf "$tmp"; return 1; }
        _platform_clean_account_preflight || return 1
        if [[ $XM_INIT == openrc ]]; then
            local pidfile
            for pidfile in /run/xray-manager.pid /run/xray-manager-extra.pid /run/xray-manager-restart.pid; do
                _platform_no_symlink "$pidfile" || return 1
                [[ ! -e $pidfile || -f $pidfile ]] || return 1
                rm -f -- "$pidfile" || return 1
            done
        fi
        uid=$(getent passwd xray-manager | cut -d: -f3 || true)
        if [[ -n $uid ]]; then
            _platform_python - "$uid" <<'PYQUIET'
import glob,os,sys
uid=int(sys.argv[1])
for p in glob.glob('/proc/[0-9]*'):
 try:
  if os.stat(p).st_uid==uid:raise ValueError('project account still has a running process; cleanup stopped')
 except (FileNotFoundError,ProcessLookupError,PermissionError):pass
PYQUIET
            [[ $? == 0 ]] || return 1
            if [[ $XM_OS == alpine ]]; then deluser xray-manager || return 1; else userdel xray-manager || return 1; fi
            if getent group xray-manager >/dev/null; then
                if [[ $XM_OS == alpine ]]; then delgroup xray-manager || return 1; else groupdel xray-manager || return 1; fi
            fi
        fi
    else platform_shortcut_remove || return 1; fi
    # Revalidate all leaves immediately before deleting. Unknown files always stop
    # cleanup; no recursive rm of an unchecked directory is used.
    _platform_clean_files_preflight || return 1
    _platform_python - "$XM_HOME" "$XM_ETC" "$XM_DATA" "$XM_LOG" <<'PY'
import pathlib,sys
for path in map(pathlib.Path,sys.argv[1:]):
 for p in sorted(path.rglob('*'),key=lambda p:len(p.parts),reverse=True):
  if p.is_symlink():raise ValueError('path changed to symlink during cleanup')
  if p.is_dir():p.rmdir()
  elif p.is_file():p.unlink()
  else:raise ValueError('path changed type during cleanup')
 path.rmdir()
PY
    [[ $? == 0 ]] || result=1
    if ((result == 0)) && [[ -z ${XM_ROOT:-} && -n $ledger ]]; then platform_dependency_cleanup "$ledger" || result=1; fi
    [[ -z $tmp ]] || rm -rf -- "$tmp"
    return "$result"
)

_platform_extra_verify_archive() {
    _platform_python - "$@" <<'PY'
import hashlib,pathlib,struct,sys,tarfile
archive,digest,folder,arch,out,hfile=sys.argv[1:]
try:
    h=hashlib.sha256()
    with open(archive,'rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
    if h.hexdigest()!=digest: raise ValueError('pinned SHA256 mismatch')
    with tarfile.open(archive,'r:gz') as tar:
        seen=set(); total=0; chosen=None
        for member in tar:
            p=pathlib.PurePosixPath(member.name)
            if member.name in seen or p.is_absolute() or '..' in p.parts or '\\' in member.name or not(member.isfile() or member.isdir()): raise ValueError('unsafe archive member')
            seen.add(member.name); total+=member.size
            if member.size>150*1024*1024 or total>300*1024*1024: raise ValueError('oversized archive')
            if member.name==folder+'/sing-box': chosen=member
        if chosen is None: raise ValueError('missing binary')
        src=tar.extractfile(chosen);head=src.read(64)
        if len(head)<64 or head[:6]!=b'\x7fELF\x02\x01' or struct.unpack('<H',head[18:20])[0]!=(62 if arch=='amd64' else 183): raise ValueError('wrong ELF architecture')
        h=hashlib.sha256();h.update(head)
        with open(out,'xb') as f:
            f.write(head)
            for chunk in iter(lambda:src.read(1024*1024),b''):f.write(chunk);h.update(chunk)
        pathlib.Path(hfile).write_text(h.hexdigest()+'\n')
except Exception as e:
    human('错误', '辅助核心校验失败：'+str(e));sys.exit(1)
PY
}
_platform_main_resource_preflight() {
    local target link dir file
    if [[ $XM_INIT == systemd ]]; then
        target=/etc/systemd/system/xray-manager.service
        for dir in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system /run/systemd/system; do
            file=$dir/xray-manager.service.d
            [[ ! -e $file && ! -L $file ]] || { _platform_error "拒绝外部主服务覆盖：$file"; return 1; }
            [[ $dir == /etc/systemd/system || ( ! -e $dir/xray-manager.service && ! -L $dir/xray-manager.service ) ]] || return 1
        done
        link=/etc/systemd/system/multi-user.target.wants/xray-manager.service
    else
        target=/etc/init.d/xray-manager
        for dir in /etc /usr/local/etc /lib/rc /usr/lib/rc; do
            for file in "$dir/conf.d/xray-manager" "$dir/conf.d/xray-manager."*; do [[ ! -e $file && ! -L $file ]] || { _platform_error "拒绝外部主服务覆盖：$file"; return 1; }; done
            [[ $dir == /etc || ( ! -e $dir/init.d/xray-manager && ! -L $dir/init.d/xray-manager ) ]] || return 1
        done
        for file in /etc/runlevels/*/xray-manager; do [[ ! -e $file && ! -L $file || $file == /etc/runlevels/default/xray-manager ]] || return 1; done
        file=/run/xray-manager.pid
        _platform_no_symlink "$file" || return 1
        if [[ -e $file ]]; then [[ -f $file ]] && _platform_owned_file "$target" || return 1; fi
        link=/etc/runlevels/default/xray-manager
    fi
    _platform_check_service_file "$target" && _platform_no_symlink "${link%/*}" || return 1
    [[ ! -e $link && ! -L $link || ( -L $link && $(readlink "$link") == "$target" ) ]] || { _platform_error '主服务存在外部开机链接。'; return 1; }
}
# Presence snapshot counts foreign resources too, so rollback never adopts them.
platform_extra_installed() {
    case ${XM_INIT:-} in systemd|openrc) ;; *) return 1 ;; esac
    local target
    target=$(_platform_extra_service_path)
    [[ -e $target || -L $target ]]
}
platform_extra_discard_new() {
    (($# == 2)) && [[ $1 =~ ^[01]$ && $2 =~ ^[01]$ ]] || return 2
    _platform_extra_paths && _platform_real || return 1
    local result=0 target
    target=$(_platform_extra_service_path)
    if [[ $2 == 0 && ( -e $target || -L $target ) ]]; then
        _platform_owned_file "$target" && platform_extra_remove_service || result=1
    fi
    if [[ $1 == 0 && ( -e $XM_EXTRA_BIN || -L $XM_EXTRA_BIN ) ]]; then
        _platform_no_symlink "$XM_EXTRA_BIN" && _platform_no_symlink "$XM_ETC/extra-core.sha256" || return 1
        [[ -f $XM_EXTRA_BIN && -f $XM_ETC/extra-core.sha256 ]] || return 1
        _platform_python - "$XM_EXTRA_BIN" "$XM_ETC/extra-core.sha256" <<'PY'
import hashlib,pathlib,re,sys
b,p=map(pathlib.Path,sys.argv[1:]);assert p.stat().st_size<=128
h=p.read_text().strip();actual=hashlib.sha256()
with b.open('rb') as f:
 for data in iter(lambda:f.read(1024*1024),b''):actual.update(data)
assert re.fullmatch('[0-9a-f]{64}',h) and actual.hexdigest()==h
PY
        [[ $? == 0 ]] || return 1
        rm -f -- "$XM_EXTRA_BIN" "$XM_ETC/extra-core.sha256" || result=1
    fi
    return "$result"
}
