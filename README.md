# xray-manager

面向 Linux 服务器的 Xray 中文终端管理脚本。菜单按核心、节点、维护、数据四组排列，也提供便于自动化的命令行接口。

支持 **Debian 12 / 13、Alpine 3.23 / 3.24**，`amd64` 和 `arm64`。Debian 使用 systemd，Alpine 使用 OpenRC。系统版本范围固定于 2026-10-02，不自动接管未知发行版。核心默认固定 **v26.3.27**，升级必须显式指定版本。

## 安装与使用

### VPS 一键远程部署

通过 SSH 登录 VPS，切换到 **root** 后，使用 `wget` 下载独立安装脚本，再在本地用 `sh` 执行：

```sh
wget -O xray-manager-install.sh https://raw.githubusercontent.com/miaoshououdezhi/AI/main/deploy.sh && \
sh xray-manager-install.sh
```

`deploy.sh` 是可单独下载运行的远程安装入口，会自动准备下载依赖、获取完整项目，再调用项目内的 `install.sh`；无需预装 Git 或 Bash。项目内的 `install.sh` 需要同目录中的模块文件，不适合单独下载执行。

如果 VPS 尚未提供 `wget` 或 HTTPS 根证书，先执行对应系统的准备命令：

```sh
# Debian 12/13
apt-get update && apt-get install -y wget ca-certificates

# Alpine 3.23/3.24
apk add --no-cache wget ca-certificates
```

远程安装入口固定下载已通过验证的项目提交。安装结束后，执行 `bash /opt/xray-manager/xray-manager.sh` 进入中文菜单。重复部署保留已有节点和核心；首次安装没有公网节点。

### 下载仓库后安装

也可以在服务器下载完整仓库，进入目录后以 root 执行安装：

```sh
git clone https://github.com/miaoshououdezhi/AI.git
cd AI
sh install.sh
```

Alpine 默认没有 Bash 时，`install.sh` 会安装它；随后自动准备依赖、专用服务账户、目录、校验后的核心与开机服务。需要可访问 GitHub 官方发行资源。已安装的服务器再次执行安装会保留现有节点和核心。

```sh
# 中文交互菜单
bash /opt/xray-manager/xray-manager.sh

# 命令帮助，不需要 root
bash xray-manager.sh help

# 安装另一个明确版本
sh install.sh v26.3.27
```

首次安装不创建公网监听，服务配置没有入站节点。添加节点后才会使用所选端口；网络防火墙和云安全组需按实际网络环境配置。程序不会更改 SSH、全局 DNS 或系统防火墙。

## 菜单

```text
核心 v26.3.27  ·  节点 0  ·  运行中

核心管理
  1 安装       2 升级       3 核心回退
节点管理
  4 列表       5 添加       6 删除       7 分享
运行维护
  8 服务       9 日志      10 诊断
数据管理
 11 备份      12 恢复      13 卸载

  0 退出
```

输入 `0` 返回或退出。菜单不会频繁清屏；出错信息保留在终端。关闭标准输入会及时退出。删除、恢复、卸载要求输入 `yes`；自动化使用命令前的 `--yes`。无操作时不会打印节点密码或私钥，分享链接只在明确选择“分享”时输出。

## 配置节点

支持 VLESS REALITY Vision、使用已有证书的 Trojan TLS、Shadowsocks 2022。每个节点使用独立 ID 和端口；相同端口不可重复。

```sh
# 替换为自己的服务器地址和 REALITY 目标；密钥/UUID/ShortID 自动生成
bash /opt/xray-manager/xray-manager.sh add vless-reality node-a '我的 REALITY' 1443 server.example.com www.cloudflare.com www.cloudflare.com:443

# 证书须有效且 SAN 匹配对外域名；服务用户须能读取证书及私钥
bash /opt/xray-manager/xray-manager.sh add trojan node-b '我的 TLS' 2443 server.example.com /etc/ssl/xray/fullchain.pem /etc/ssl/xray/private.key

# 使用 2022-blake3-aes-128-gcm，自动生成随机主密钥
bash /opt/xray-manager/xray-manager.sh add shadowsocks node-c '我的 SS2022' 3443 server.example.com

bash /opt/xray-manager/xray-manager.sh list
bash /opt/xray-manager/xray-manager.sh share node-a
bash /opt/xray-manager/xray-manager.sh --yes delete node-c
```

Trojan 私钥建议 `root:xray-manager`、`0640`，其父目录允许该账户穿越。现有证书应放在受管目录以外，例如 `/etc/ssl/xray/`；脚本不会申请、续期或改写它们。REALITY 目标由使用者选择，目标 TLS 服务需与 SNI 相容。

交互菜单输入密码时隐藏字符。CLI 可传入密码，但会出现在调用者的 shell 历史或进程参数中，日常优先用菜单自动生成。生产配置关闭访问日志，仅保留警告和错误；日志轮转是周期检查，并非即时硬大小上限。分享链接和 JSON 备份包含客户端秘密；服务端 REALITY 私钥不会进入分享链接。

完整参数格式见 `help` 和 [协议说明](docs/protocols.md)。

## 服务、升级与数据

```sh
bash /opt/xray-manager/xray-manager.sh service status
bash /opt/xray-manager/xray-manager.sh service restart
bash /opt/xray-manager/xray-manager.sh logs 80
bash /opt/xray-manager/xray-manager.sh diagnose

# 升级版本必须实际存在于 XTLS/Xray-core 官方 release
bash /opt/xray-manager/xray-manager.sh upgrade v26.3.27
bash /opt/xray-manager/xray-manager.sh rollback

# 备份目标必须不存在；备份目录需预先建立
bash /opt/xray-manager/xray-manager.sh backup /root/xray-backup.json
bash /opt/xray-manager/xray-manager.sh --yes restore /root/xray-backup.json
bash /opt/xray-manager/xray-manager.sh --yes uninstall
```

所有变更由 `flock` 互斥。脚本先验证 JSON 和协议结构，再调用候选核心 `xray run -test`，随后在同一文件系统中原子替换文件。重启或健康检查失败会恢复旧状态、配置、核心和运行状态；原来停止的服务在更新配置后仍保持停止。

服务日志按周期轮转（非瞬时硬上限），高日志量时需监控磁盘占用。

升级成功后保存上一核心及其版本，`rollback` 在原生校验通过后切换；再次回退可以切换回上一版本。恢复 JSON 只替换节点、保留当前核心版本；未知 schema、重复 ID/端口、不合法字段及不安全路径被拒绝。`config.json` 由状态生成，直接编辑会被诊断和服务启动检测为不一致。

下载仅使用官方 HTTPS release，核对其 `.dgst` 的 SHA256，并检查压缩包路径、文件类型、大小及 ELF 架构。摘要与资源来自同一发行源，摘要校验不等同于独立签名验证。安装需要 root，Xray 使用专用非登录账户运行。

信号 `INT`/`TERM` 会触发回退和清理；断电或 `SIGKILL` 无法运行清理逻辑。此时先运行 `diagnose`，保留 `/etc/xray-manager/.transaction.*` 现场以便从旧副本恢复，不应手工删除现场后直接重启。安装依赖的软件包及创建的服务账户在卸载后保留，避免影响其他程序。卸载只删除明确列出的本项目文件；日志、备份、外部证书和未知文件保留。

## 文件布局

| 路径 | 用途 |
|---|---|
| `/opt/xray-manager/` | 受信任脚本、模块、核心与上一版核心 |
| `/etc/xray-manager/state.json` | 版本化私密状态，schema 1 |
| `/etc/xray-manager/config.json` | 由状态生成的运行配置 |
| `/var/lib/xray-manager/` | 服务运行数据 |
| `/var/log/xray-manager/` | 轮转日志与最近校验失败诊断 |
| `xray-manager` | systemd / OpenRC 服务名与运行账户 |

受管目录使用所有权标记；首次安装遇到未标记非空目录或同名陌生服务会拒绝接管。状态/配置使用 `root:xray-manager`、`0640`，备份 `0600`。备份是 JSON 文件，不读取 Shell 状态文件或解压未知归档。

## 开发与验证

运行要求 Bash ≥ 4.4，依赖由平台模块安装。各 `lib/` 模块可被 `source`，载入时不会安装依赖或操作服务。

```sh
for file in xray-manager.sh lib/*.sh tests/*.sh; do bash -n "$file"; done
sh -n install.sh
shellcheck -x -S warning xray-manager.sh install.sh lib/*.sh tests/*.sh
bash tests/test-shell.sh
bash tests/test-platform.sh
bash tests/test-protocol.sh
```

`test-shell.sh` 使用隔离临时目录与模拟服务，覆盖锁冲突、原生校验失败、启动/健康失败、核心切换回退及历史版本元数据写失败。`XM_ROOT` 仅为隔离测试添加路径前缀，平台模块明确拒绝沙箱中对宿主账户、依赖和真实服务进行操作。

CI 在四个发行版容器中验证依赖安装、下载和原生空配置校验；容器检查不能替代真实 systemd / OpenRC 生命周期或端到端客户端连通。ARM64 资源有下载/ELF 验证支持，实际验证范围及独立测试证据见 `.ai/tasks/initial-manager/`。发布前应核对该证据与候选版本，不将支持列表等同于全部环境已经实测。

平台细节见 [平台说明](docs/platform.md)。脚本采用 MIT 许可；Xray 核心由其官方项目独立发行，本仓库不包含或再许可核心二进制。
