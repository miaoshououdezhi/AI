#!/usr/bin/env bash
# Platform adapter. Sourcing this file never installs packages or touches services.
_XM_PLATFORM_ASSETS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../assets" 2>/dev/null && pwd)"

_platform_error() { printf '平台错误：%s\n' "$*" >&2; return 1; }
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
    python3 - "$tmp/core.zip" "$tmp/core.dgst" "$tmp/xray" "$XM_ARCH" <<'PY'
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
    print('核心验证失败：' + str(e), file=sys.stderr)
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
    python3 - "$XM_BIN" <<'PYCORE'
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
    print('核心进程检查失败：' + str(e), file=sys.stderr)
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
    nodes=$(jq -r '.nodes | if type != "array" then error("nodes must be array") else .[] | [.port,.type] | @tsv end' "$XM_ETC/state.json") || return 1
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
