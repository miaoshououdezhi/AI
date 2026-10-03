# xray-manager

面向 Linux 服务器的 Xray 中文终端管理脚本。菜单按核心、节点、维护、数据四组排列，也提供便于自动化的命令行接口。

支持 **Debian 12 / 13、Alpine 3.23 / 3.24**，`amd64` 和 `arm64`。Debian 使用 systemd，Alpine 使用 OpenRC。系统版本范围固定于 2026-10-02，不自动接管未知发行版。核心默认固定 **v26.3.27**。菜单可以查询并选择官方版本；CLI 升级仍须显式指定版本。

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

远程安装入口固定下载已通过验证的项目提交。安装结束后，执行 `xy` 进入中文菜单。也可以使用 `bash /opt/xray-manager/xray-manager.sh`。重复部署保留当前支持的节点和核心；首次安装没有公网节点。

### 下载仓库后安装

也可以在服务器下载完整仓库，进入目录后以 root 执行安装：

```sh
git clone https://github.com/miaoshououdezhi/AI.git
cd AI
sh install.sh
```

Alpine 默认没有 Bash 时，`install.sh` 会安装它；随后自动准备依赖、专用服务账户、目录、校验后的核心与开机服务。需要可访问 GitHub 官方发行资源。已安装的服务器再次执行安装会保留当前支持的节点和核心。

```sh
# 中文交互菜单
xy

# 命令帮助，不需要 root
bash xray-manager.sh help

# 安装另一个明确版本
sh install.sh v26.3.27
```

安装会提供全局 `xy` 命令，直接输入 `xy` 打开菜单，也可用 `xy help`、`xy list` 等命令参数；管理操作需要 root。现存陌生 `/usr/local/bin/xy` 不会被覆盖，会在项目状态变更前拒绝并提示冲突。

首次安装不创建公网监听，服务配置没有入站节点。添加节点后才会使用所选端口；网络防火墙和云安全组需按实际网络环境配置。程序不会更改 SSH、全局 DNS 或系统防火墙。

## 菜单

宽度至少 60 列时使用两列布局，组间留空；窄终端改为单列。优先使用有效 `COLUMNS`，否则从终端窗口获取宽度，无法获取时按 80 列显示。状态和分组仅在交互终端使用颜色，重定向输出保持纯文本；设置 `NO_COLOR`（含空值）或 `TERM=dumb` 也会关闭颜色。

```text
  Xray 管理  ·  xray-manager

  核心 v26.3.27
  节点 0  ·  运行中

核心管理
[1]  安装核心        [2]  选择版本并升级
[3]  核心回退

节点管理
[4]  查看节点        [5]  添加节点
[6]  删除节点        [7]  分享链接

运行维护
[8]  服务操作        [9]  查看日志
[10]  运行诊断

数据管理
[11]  备份状态        [12]  恢复状态
[13]  卸载管理器

[0]  退出
```

输入 `0` 返回或退出，任意输入字段用 `:q` 取消。提示中的方括号显示默认值，按回车直接使用；无默认值的必填字段会提示补填。菜单保留此前输出和错误；关闭标准输入会及时退出。删除、恢复、卸载要求输入 `y` 或 `yes`（不区分大小写），CLI 自动化使用命令前的 `--yes`。

添加节点时逐字段验证，输入不合法会留在当前字段重新提示。每次新建重新生成随机 ID、名称、端口、密钥和 XHTTP 路径，并校验与已有节点的冲突；默认项如下：

| 字段 | 回车行为 |
|---|---|
| 协议 | VLESS REALITY Vision |
| 节点 ID | 使用随机 `node-xxxxxxxx`，排除已有 ID |
| 名称 | 使用协议名称加随机后缀 |
| 监听端口 | 使用随机未占用端口 1024..65535，排除已有节点端口 |
| 对外地址 | 自动探测公网 IP；也可手动填写 IP 或域名 |
| REALITY SNI / 目标 | `www.cloudflare.com` / 所填 SNI 的 443 端口 |
| UUID、REALITY 密钥、ShortID | 自动随机生成，保持隐藏 |
| SS2022 主密钥 | 使用随机默认值，输入隐藏 |
| XHTTP 路径 / 模式 | 随机 `/` 加 16 位十六进制路径 / `packet-up` |

查看、分享和删除节点先展示带编号的列表，显示名称、类型（`reality`、`xhttp`、`ss2022`）、地址与端口。输入对应编号操作；查看隐藏凭据，并提供“修改名称”和“修改节点配置”；分享仅输出选中节点链接，删除显示摘要并确认。列表展示后节点信息发生变化会拒绝操作，需重新选择。重点字段使用颜色，纯文本输出仍可识别。

公网探测或随机端口获取失败时，保留手动输入及取消选项。地址探测结果用于客户端分享，不更改监听方式。添加前检查安装状态，实际写入前再次按既有协议校验和事务执行。秘密不会自动明文显示；只有明确选择“分享”才输出客户端链接。

菜单升级展示官方 GitHub 正式版、预览版各最近两项及 UTC 发布时间，实际缺少的频道不会补造版本。选择版本后显示当前与目标版本，必须再输入 `y` 或 `yes`（不区分大小写） 才执行下载与切换；回车默认取消。版本查询失败仍可选 `m` 手动输入或 `0` 返回，手动版本格式错误会重新提示。

## 配置节点

新增支持 VLESS REALITY Vision、VLESS XHTTP + REALITY、Shadowsocks 2022。Trojan 已完整移除；升级本管理脚本时，会先私密备份原状态，再清退已有 Trojan 节点，其余节点保留。清退不要求旧证书仍有效。每个节点使用独立 ID 和端口；相同端口不可重复。

```sh
# 替换为自己的服务器地址和 REALITY 目标；密钥/UUID/ShortID 自动生成
xy add vless-reality node-a '我的 REALITY' 1443 server.example.com www.cloudflare.com www.cloudflare.com:443

# XHTTP 使用 REALITY 安全层，无须证书；路径请使用不同随机字符串
xy add vless-xhttp node-b '我的 XHTTP' 2443 server.example.com www.cloudflare.com www.cloudflare.com:443 /a7d390ef52c1068b packet-up

# 使用 2022-blake3-aes-128-gcm，自动生成随机主密钥
xy add shadowsocks node-c '我的 SS2022' 3443 server.example.com

xy list
xy share node-a
xy --yes delete node-c
```

REALITY 目标由使用者选择，目标 TLS 服务需与 SNI 相容。

交互菜单输入密码时隐藏字符。CLI 可传入密码，但会出现在调用者的 shell 历史或进程参数中，日常优先用菜单自动生成。生产配置关闭访问日志，仅保留警告和错误；日志轮转是周期检查，并非即时硬大小上限。分享链接和 JSON 备份包含客户端秘密；服务端 REALITY 私钥不会进入分享链接。

完整参数格式见 `help` 和 [协议说明](docs/protocols.md)。

## 查看与修改节点

选择主菜单 `[4] 查看节点`，先显示所有节点的编号、名称、类型、地址和端口；输入节点编号进入详情，再选择 `[1] 修改名称` 或 `[2] 修改节点配置`。配置菜单只展示当前协议支持的字段，ID 和协议类型固定。输入合法后显示摘要，再输入 `y`/`yes`（任意大小写）才保存；回车保留当前值，`:q` 或 EOF 取消。UUID、ShortID、密码和密钥的当前值保持隐藏。

| 协议 | 可修改字段 |
|---|---|
| 全部 | 名称、监听端口、对外 IP/域名 |
| REALITY / XHTTP | UUID、SNI、目标域名:端口、ShortID、公私钥 |
| XHTTP | 路径、模式（auto/packet-up/stream-up/stream-one） |
| SS2022 | 16 字节标准 Base64 主密钥 |

REALITY 公私钥须成对填写并匹配，一次验证完整新密钥对；不会因旧另一半密钥而阻止合法替换。名称、端口、凭据和 XHTTP 路径须不与其他节点冲突；保留自己的原端口不会将自身监听误判为冲突，换端口则检查实际监听。输入期间不持锁，保存时重新检查选中节点的完整快照；若已被另一操作修改，会拒绝保存并提示重新选择。

```sh
xy edit node-a name '新的显示名称'
xy edit node-a port 1444
xy edit node-a address server.example.com
xy edit node-a sni www.cloudflare.com
xy edit node-a target www.cloudflare.com:443
xy edit node-a short_id a4b7
xy edit node-b path /new-random-path
xy edit node-b mode packet-up
# keys 字段须同时填写匹配的私钥和公钥；秘密会出现在 CLI 参数/历史中
xy edit node-a keys PRIVATE_KEY PUBLIC_KEY
# 自动化才使用 --yes，日常秘密编辑优先使用菜单
xy --yes edit node-c name '新的 SS2022 名称'
```

CLI 格式为 `edit ID FIELD VALUE`；`keys` 例外接受私钥和公钥两个值，`shortid` 是 `short_id` 的别名。`uuid`、`password` 也可按上表使用。非法字段、格式、密钥匹配和跨协议字段会被拒绝。只替换所选节点，其余节点和核心保持；保存复用原生校验与服务健康事务，失败回退，原来停止的核心保持停止。没有变化时不写配置、不重启服务。

## 服务、升级与数据

```sh
xy service status
xy service restart

# 每日按 VPS 本机时区重启正在运行的核心；停止则跳过，不补执行
xy schedule status
xy --yes schedule set 04:00
xy --yes schedule disable
xy logs 80
xy diagnose

# 升级版本必须实际存在于 XTLS/Xray-core 官方 release
xy upgrade v26.3.27
xy rollback

# 备份目标必须不存在；备份目录需预先建立
xy backup /root/xray-backup.json
xy --yes restore /root/xray-backup.json
xy --yes uninstall
```

服务菜单的 `[7] 定时重启核心` 可查看状态、设置每日 `HH:MM`（默认 `04:00`）或禁用；时间为 24 小时格式 `00:00..23:59`。确认支持 `y`/`yes` 的任意大小写，回车或其他输入取消。任务按机器本机时区执行，只重启运行中的核心；机器错过执行时刻不会补执行，启用时恰好处于指定分钟也不会立即补跑。首次安装默认关闭，卸载会移除项目专属定时任务。Debian 使用项目专属 systemd timer，Alpine 使用项目专属 OpenRC Python 调度服务；不修改全局 crontab。

升级管理脚本发现旧 Trojan 节点时，先验证状态结构并拒绝未知类型，再校验过滤后的配置，保存 `/etc/xray-manager/trojan-retired-backup.XXXXXXXX` 完整原状态（`0600`），原生配置和服务事务切换成功后才更新已安装脚本。失败保留旧运行状态及已安装代码，备份保留。备份含秘密，卸载不会删除；新版不能恢复含已移除类型的旧备份，应仅提取仍支持的节点另行恢复。

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
bash tests/test-interactive.sh
bash tests/test-edit.sh
bash tests/test-platform.sh
bash tests/test-protocol.sh
```

`test-interactive.sh` 使用真实协议校验、模拟外部查询及真实 PTY，覆盖回车随机默认值、XHTTP、字段重提示、编号选择及列表变化保护、查询失败手动回退、取消/EOF、大小写确认、定时重启输入与停止核心跳过、升级二次确认以及颜色降级。

`test-edit.sh` 使用真实协议验证与状态事务、模拟核心执行和服务，覆盖三协议修改、成对密钥、字段/冲突拒绝、确认取消、快照并发和回退；它不冒充真实核心原生验证，真实核心校验另行执行。

`test-shell.sh` 使用隔离临时目录与模拟服务，覆盖锁冲突、原生校验失败、启动/健康失败、核心切换回退及历史版本元数据写失败。`XM_ROOT` 仅为隔离测试添加路径前缀，平台模块明确拒绝沙箱中对宿主账户、依赖和真实服务进行操作。

CI 在四个发行版容器中验证依赖安装、下载和原生空配置校验；容器检查不能替代真实 systemd / OpenRC 生命周期或端到端客户端连通。ARM64 资源有下载/ELF 验证支持，实际系统与架构验收需要单独核对对应候选版本的测试证据，不将支持列表等同于全部环境已经实测。

平台细节见 [平台说明](docs/platform.md)。脚本采用 MIT 许可；Xray 核心由其官方项目独立发行，本仓库不包含或再许可核心二进制。
