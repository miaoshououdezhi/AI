# 平台与服务

支持 Debian 12/13（systemd）与 Alpine 3.23/3.24（OpenRC），发行资源映射 x86_64 → Xray-linux-64.zip、aarch64 → Xray-linux-arm64-v8a.zip。其他 OS/CPU 拒绝安装。平台检测读取 os-release 数据，不执行它。

`platform_dependencies` 安装必要工具，Alpine 特别安装 flock、runuser、setpriv；Debian 安装 util-linux 等。需要服务管理器已经运行，普通未启动 init 的容器仅可验证配置，不能宣称服务安装成功。

核心默认 v26.3.27，下载自固定 XTLS/Xray-core HTTPS release，验证同源 .dgst SHA256、ZIP 大小、路径、类型、重复项及 ELF 位数/架构；只提取 xray，拒绝覆盖下载目标。下载失败不会替换现有运行核心。同源摘要不能独立防范发行账户本身被攻陷。

专用非登录账户 xray-manager，以最小网络绑定 capability 运行。程序、配置、数据和日志使用专属目录及所有权标记。已有陌生同名服务、账户、组、非空目录或符号链接路径均拒绝接管。systemd 通过 AmbientCapabilities 提供低端口能力并限制可写目录；OpenRC 使用 setpriv 继承最小 capability。两者均不以 root 运行 Xray。

健康检查要求真实服务运行、专用账户/对应 executable 的唯一进程保持稳定、原生配置有效、节点 TCP 监听归属该进程；Shadowsocks 还检查 UDP。空节点不监听公网，但仍要求核心进程健康。

日志保留 warning/error，访问日志关闭。OpenRC 使用 logrotate 每日检查，maxsize 10MiB、最多4个轮转文件；这不是即时硬上限。systemd 使用 journal 和日志速率限制，journal 总量遵循系统自身配置。项目不修改全局 journal 配置。


卸载停止并禁用受管服务，只删除明确项目文件，保留账户、系统依赖、日志、未知文件和外部证书。XM_ROOT 仅作路径前缀用于隔离测试；非空时拒绝宿主依赖、账户与真实服务改动。不修改系统防火墙、SSH、全局 DNS 或 sysctl。

实际验证环境、候选提交、退出码及未覆盖项记录在 .ai/tasks/initial-manager。模拟检测不等同于在对应系统实测；原生 Linux ARM64 资源的架构校验也不等同于 ARM 服务器真实服务启动。

## 每日定时重启

定时重启默认关闭。`schedule set HH:MM` 使用服务器本机时区，每天在指定时间重启当前正在运行的核心；例如 `04:00`。`schedule status` 显示配置、调度服务状态、时区和下一次时间；`schedule disable` 关闭并移除本项目的定时资源。用户手动停止核心后，定时任务跳过，不自动启动核心。重启入口先取得管理锁，再进行状态/原生配置校验和服务健康检查，忙碌或验证失败会返回失败并留下日志。

Debian 使用专属 `xray-manager-restart.service` 和 `.timer`，OnCalendar 为每天本地 HH:MM，Persistent=false；关机期间错过的任务不会在开机补执行。Alpine 使用专属 OpenRC `xray-manager-restart` 服务和随项目发布的 Python 调度程序。调度程序每15秒查看本机时间，每个日期最多发起一次；启动所在分钟不执行任务，错过的分钟不补执行。Alpine 状态中的下次时间为计划时间估算，受夏令时、系统时钟调整和调度间隔影响；Debian 读取 systemd 实际的下次时间。不要把此功能作为精准秒级调度器。

Alpine 不启停系统 `crond`，不修改任何用户的全局 crontab，不使用 BusyBox crond 的全局 PID/reboot 文件。Python 调度服务以 root 运行，仅调用固定 argv 的管理命令，不读取或执行用户提供的 shell 代码；核心继续使用非 root 专用账户。禁用或卸载只停止、禁用并删除本项目定时服务与 `/etc/xray-manager/restart-schedule`。配置修改失败恢复原文件和原启用/运行状态；陌生同名资源、覆盖文件或符号链接拒绝接管。调度子进程关闭交互管理器锁描述符，避免长期占锁。

OpenRC 调度服务收到停止请求时，等待已经开始的重启操作结束；子操作超时120秒时先发送 TERM，提供30秒清理机会，再在仍未退出时终止。OpenRC 服务停止限时155秒。调度日志位于 `/var/log/xray-manager/restart-schedule.log`，保留于卸载之后；按每日执行频率增长，管理员可结合系统日志策略轮转。


全局入口 `xy` 位于 `/usr/local/bin/xy`，由 root 拥有、权限0755，转发参数到安装目录中的管理脚本。入口含项目所有权标记；安装在创建项目目录或替换核心之前预检，拒绝覆盖已有陌生文件、目录、符号链接或符号链接祖先。POSIX 远程部署阶段可能已经安装引导依赖，该预检只保证管理器项目安装副作用之前检查入口。重复安装可以更新本项目入口；卸载只删除本项目入口并保留 `/usr/local/bin` 目录。OpenRC 定时资源预检还拒绝同名 conf.d、运行级别后缀覆盖、其他配置路径中的同名服务以及非受管运行级别链接；这些外部文件不会被读取为代码或删除。
