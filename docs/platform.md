# 平台与服务

支持 Debian 12/13（systemd）、Alpine 3.23/3.24（OpenRC），amd64/arm64。检测读取 os-release 数据，不执行它；不支持的系统、架构或未运行的 init 拒绝实际服务操作。`XM_ROOT` 只支持路径隔离测试，不能修改宿主账户、包或真实服务。

Xray 使用专属非登录账户 `xray-manager`，程序、配置、数据和日志位于 `/opt/xray-manager`、`/etc/xray-manager`、`/var/lib/xray-manager`、`/var/log/xray-manager`。核心默认固定 v26.3.27，下载官方 HTTPS ZIP 和 .dgst 校验 SHA256；拒绝归档路径穿越、链接、重复项、超限条目和错误 ELF 架构。升级和回退针对 Xray。下载失败不替换旧核心。

AnyTLS、Hysteria2、TUICv5 使用独立 sing-box 辅助核心，不伪装成 Xray 原生协议。辅助核心固定 1.14.2，来自 SagerNet/sing-box 官方发布，分别选择 amd64/arm64 的 glibc/musl 资产；四个归档 SHA256 固定在平台模块。先验证固定摘要，再安全读取归档并验证 ELF/版本，原子创建 binary 及私密完整性记录。已有辅助核心必须匹配本项目完整性记录，拒绝接管未知二进制。下载校验使用分块读取，避免小内存 VPS 的不必要峰值。辅助核心按需安装，未配置辅助节点时不自动启动。

辅助服务名 `xray-manager-extra`，共用非 root 专用账户，配置 `/etc/xray-manager/extra.json`，程序 `/opt/xray-manager/bin/sing-box`。两个 systemd 服务只提供 CAP_NET_BIND_SERVICE，限制系统写入范围；OpenRC 用 setpriv 继承同等权限。服务模板安装不自动启动/启用。Shell 事务负责两核心原生校验、独立运行/启用状态恢复；辅助安装失败或首个辅助节点原生校验失败时删除本次新建的 binary/hash/unit，保留原有资源。陌生同名服务、覆盖配置、运行级别链接、PID 符号链接拒绝接管。

健康检查要求专用账户和对应 executable 的唯一稳定进程、原生配置有效，以及节点端口归属实际核心 PID。Xray 只检查其节点，Shadowsocks 检查 TCP/UDP；sing-box AnyTLS 检查 TCP，HY2/TUICv5 检查 UDP。配置检查、服务启动、客户端互通是不同证据，验证记录分别说明。日志包含 warning/error，访问日志关闭；OpenRC 原 Xray logrotate 定期检查最多4个轮转文件，并非即时硬上限。辅助和定时服务日志在受管日志目录，完全卸载会删除。

## 每日定时重启与入口

`xy` 是 root:root0755 的 `/usr/local/bin/xy`，转发参数到已安装管理器。安装在项目副作用之前预检，拒绝覆盖陌生文件、目录、符号链接或链接祖先；远程 POSIX 引导可能已安装依赖。重复安装可更新自有入口。

定时功能默认关闭。`schedule set HH:MM` 每天使用服务器本机时区；例如 `04:00`。`status` 展示启用状态、时间、时区和下次执行；`disable` 移除受管定时资源。定时入口获取管理锁，校验当前配置，重启正在运行的核心，已停止的核心跳过。Debian 用专属 service/timer，OnCalendar 每日本地时间，Persistent=false，关机漏过的任务不补执行；Alpine 用专属 Python 调度器，每15秒检查，每日期最多一次，启动所在分钟和错过的分钟均不执行。Alpine 下次时间为估算，受夏令时和系统时间调整影响。

调度器不修改用户 crontab 或外部 crond；持久调度进程关闭管理锁描述符。修改失败恢复原配置及启用/运行状态。OpenRC 停止等待已经开始的重启完成；子操作120秒超时后 TERM，30秒清理后才最终终止。专属 PID 路径及外部 conf.d/运行级别覆盖均受预检保护。

## 依赖记录与完全卸载

安装前获取包清单；POSIX 引导通过 `XM_DEPENDENCY_SNAPSHOT_FILE` 传递引导之前的私密 JSON 快照，平台继承它。初始快照仅使用 dpkg-query/apk 和 awk，无 Python/jq 前提。安装依赖后保存 `/etc/xray-manager/dependency-ledger.json`，分别记录原有包和实际新增包。重复安装保留初始归属，外部新装或无历史记录的包不被接管。快照/记录只作为数据解析，不 source，也不把包名作为 shell 代码。

完全卸载先核对全部项目目录、已知文件、服务和链接；遇到未知文件、符号链接或共享 UID/GID 拒绝破坏性清理并说明保留位置。预检通过后停止双方核心、移除定时服务、辅助和主服务、专用账户及全局入口，删除受管程序、配置、日志、诊断日志、历史核心和已知缓存；外部导出、外部证书和系统标准父目录保留。文件按精确白名单和类型逐项删除，不对未检查目录使用递归 rm。账户仍有进程时不删除。

最后仅尝试删除 ledger 记载的新增、当前安装、无外部已安装反向依赖的包。保留系统 init、SSH、libc、包管理器及 Debian Essential；当前用户登录 Shell 引用的 Bash 也保留。Alpine 新安装且未被使用的 Bash 可以随新增依赖删除。移除之前两次检查 apt/apk 模拟结果，删除集合必须在可移除新增集合以内，禁用全局 autoremove；共享、系统或未知历史包明确列出保留原因。包依赖检查依据系统包数据库，管理员自行安装的软件没有依赖声明时不会出现在数据库中。

发布验证中会区分隔离的包模拟测试、真实卸载测试和服务验证；共享测试 VPS 不清除未知历史依赖，真实新装依赖清理使用隔离环境。项目不改防火墙、SSH、DNS、sysctl 或外部 cron。
