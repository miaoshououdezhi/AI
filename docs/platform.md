# 平台与服务

支持 Debian 12/13（systemd）与 Alpine 3.23/3.24（OpenRC），发行资源映射 x86_64 → Xray-linux-64.zip、aarch64 → Xray-linux-arm64-v8a.zip。其他 OS/CPU 拒绝安装。平台检测读取 os-release 数据，不执行它。

`platform_dependencies` 安装必要工具，Alpine 特别安装 flock、runuser、setpriv；Debian 安装 util-linux 等。需要服务管理器已经运行，普通未启动 init 的容器仅可验证配置，不能宣称服务安装成功。

核心默认 v26.3.27，下载自固定 XTLS/Xray-core HTTPS release，验证同源 .dgst SHA256、ZIP 大小、路径、类型、重复项及 ELF 位数/架构；只提取 xray，拒绝覆盖下载目标。下载失败不会替换现有运行核心。同源摘要不能独立防范发行账户本身被攻陷。

专用非登录账户 xray-manager，以最小网络绑定 capability 运行。程序、配置、数据和日志使用专属目录及所有权标记。已有陌生同名服务、账户、组、非空目录或符号链接路径均拒绝接管。systemd 通过 AmbientCapabilities 提供低端口能力并限制可写目录；OpenRC 使用 setpriv 继承最小 capability。两者均不以 root 运行 Xray。

健康检查要求真实服务运行、专用账户/对应 executable 的唯一进程保持稳定、原生配置有效、节点 TCP 监听归属该进程；Shadowsocks 还检查 UDP。空节点不监听公网，但仍要求核心进程健康。

日志保留 warning/error，访问日志关闭。OpenRC 使用 logrotate 每日检查，maxsize 10MiB、最多4个轮转文件；这不是即时硬上限。systemd 使用 journal 和日志速率限制，journal 总量遵循系统自身配置。项目不修改全局 journal 配置。

Trojan 使用外部现有证书，不负责 ACME。建议 /etc/ssl/xray/ 路径，私钥 root:xray-manager 0640，目录允许服务账户穿越。systemd ProtectHome 与 PrivateTmp 会隔离 /root、/home、/tmp，证书不要放在这些路径。

卸载停止并禁用受管服务，只删除明确项目文件，保留账户、系统依赖、日志、未知文件和外部证书。XM_ROOT 仅作路径前缀用于隔离测试；非空时拒绝宿主依赖、账户与真实服务改动。不修改系统防火墙、SSH、全局 DNS 或 sysctl。

实际验证环境、候选提交、退出码及未覆盖项记录在 .ai/tasks/initial-manager。模拟检测不等同于在对应系统实测；原生 Linux ARM64 资源的架构校验也不等同于 ARM 服务器真实服务启动。
