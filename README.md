# xray-manager

面向 Linux 服务器的中文终端管理脚本。Xray 管理 REALITY、XHTTP、SS2022、VLESS(ws) 和认证 SOCKS5；AnyTLS、HY2、TUIC v5 使用按需安装的独立 sing-box 辅助核心。菜单按核心、节点、维护、数据四组排列，也提供便于自动化的命令行接口。

支持 **Debian 12 / 13、Alpine 3.23 / 3.24**，`amd64` 和 `arm64`。Debian 使用 systemd，Alpine 使用 OpenRC。系统版本范围固定于 2026-10-02，不自动接管未知发行版。Xray 默认固定 **v26.3.27**，辅助核心固定 **sing-box 1.14.2**，辅助核心并非 Xray 的入站协议。菜单可以查询并选择官方版本；CLI 升级仍须显式指定版本。

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

宽度至少 60 列时使用两列布局，组间留空；窄终端改为单列。优先使用有效 `COLUMNS`，否则从终端窗口获取宽度，无法获取时按 80 列显示。普通界面使用固定 RGB 配色：蓝色 `#00BFFF`、青色 `#00FFFF`、亮绿色 `#00FF00`。功能正文为白色 `#FFFFFF`，编号为蓝色；日志信息及标题为青色，成功和数值为亮绿，警告使用蓝色 `[警告]`，错误与明确失败使用红色 `#FF0000` 的 `[错误]` 标签，全部写入 stderr；节点 JSON/TSV 和分享 URI 的 stdout 不添加日志前缀。菜单操作后在 TTY 提示“按任意键返回主菜单”，非 TTY 不阻塞或消耗后续输入。状态和分组仅在交互终端使用颜色，重定向输出保持纯文本；设置 `NO_COLOR`（含空值）或 `TERM=dumb` 也会关闭颜色。

```text
  Xray 管理  ·  xray-manager
  OS      Debian GNU/Linux 13 · x86_64
  Host    my-vps
  Kernel  6.12.0
  CPU     Virtual CPU · 2 核
  Memory  64.0 MiB / 256.0 MiB
  Disk    3.0 GiB / 20.0 GiB

  核心 v26.3.27
  节点 0  ·  运行中

核心管理
[1]   安装核心          [2]  版本升级
[3]   核心回退          [4]  脚本更新

节点管理
[5]   节点管理          [6]  添加节点
[7]   删除节点          [8]  分享链接

运行维护
[9]   服务操作          [10]  查看日志
[11]  运行诊断

数据管理
[12]  导出配置          [13]  导入配置

危险操作
[14]  完全卸载

[0]  退出脚本
```

系统概览只读取本机信息，标签蓝色、值绿色；CPU显示可用核数，内存优先采用有效 cgroup v2 限额及当前使用量，磁盘显示根文件系统已用/总量。缺失项显示“未知”，窄终端截取长值；读取不会安装依赖、发起网络请求或更改服务。概览一次采集、一次批量裁剪，采集或格式化失败仍显示六项“未知”。

输入 `0` 返回或退出，任意输入字段用 `:q` 取消。提示中的方括号显示默认值，按回车直接使用；无默认值的必填字段会提示补填。菜单保留此前输出和错误；关闭标准输入会及时退出。删除、导入、完全卸载要求输入 `y` 或 `yes`（不区分大小写），CLI 自动化使用命令前的 `--yes`。

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

查看、分享和删除节点先展示带编号的列表，显示名称、类型（`reality`、`xhttp`、`ss2022`、`vless(ws)`、`anytls`、`hy2`、`tuicv5`、`socks5`）、地址与端口。输入对应编号操作；详情隐藏凭据，并直接提供名称、端口、IP/地址、SNI（仅支持的协议）及更多配置快捷操作；分享仅输出选中节点链接，删除显示摘要并确认。列表展示后节点信息发生变化会拒绝操作，需重新选择。重点字段使用颜色，纯文本输出仍可识别。列表在 40/80 列下裁剪显示副本，保留完整编号和类型，IPv6 地址使用方括号；按编号操作仍使用完整原节点及快照保护。

公网探测或随机端口获取失败时，保留手动输入及取消选项。地址探测结果用于客户端分享，不更改监听方式。添加前检查安装状态，实际写入前再次按既有协议校验和事务执行。秘密不会自动明文显示；只有明确选择“分享”才输出客户端链接。

菜单升级展示官方 GitHub 正式版、预览版各最近两项及 UTC 发布时间，实际缺少的频道不会补造版本。选择版本后显示当前与目标版本，必须再输入 `y` 或 `yes`（不区分大小写） 才执行下载与切换；回车默认取消。版本查询失败仍可选 `m` 手动输入或 `0` 返回，手动版本格式错误会重新提示。

## 配置节点

支持 VLESS REALITY Vision、VLESS XHTTP + REALITY、Shadowsocks 2022、VLESS WebSocket + TLS、AnyTLS、Hysteria2 / HY2、TUIC v5、认证 SOCKS5。Trojan 已完整移除；升级本管理脚本时，会先私密备份原状态，再清退已有 Trojan 节点，其余节点保留。清退不要求旧证书仍有效。每个节点使用独立 ID、名称和端口，凭据/路径排除重复；相同端口不可重复。TLS 协议读取现有有效证书与匹配私钥，SAN 须匹配 SNI。证书及私钥 PEM 内嵌到私密状态，使导出可跨机器迁移；不自动申请 ACME 或将客户端设为跳过证书验证。

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

交互添加 REALITY/XHTTP 只询问一次 SNI（域名或 IPv4），自动校验并设置目标为 `SNI:443`，会显示目标说明。需要其他目标时可通过节点的更多配置修改；CLI 仍接受独立的 SNI 与 TARGET。目标 TLS 服务需与 SNI 相容。

交互菜单输入密码时隐藏字符。CLI 可传入密码，但会出现在调用者的 shell 历史或进程参数中，日常优先用菜单自动生成。生产配置关闭访问日志，仅保留警告和错误；日志轮转是周期检查，并非即时硬大小上限。分享链接和 JSON 备份包含客户端秘密；服务端 REALITY 私钥不会进入分享链接。

完整参数格式见 `help` 和 [协议说明](docs/protocols.md)。

## 查看与修改节点

选择主菜单 `[5] 节点管理`，先显示所有节点的编号、名称、类型、地址和端口；输入节点编号进入详情，再选择 `[1] 修改名称`、`[2] 修改端口`、`[3] 修改 IP/地址`、`[4] 修改 SNI`（仅支持该字段的协议显示）或 `[5] 更多配置`。配置菜单只展示当前协议支持的字段，ID 和协议类型固定。输入合法后显示摘要，再输入 `y`/`yes`（任意大小写）才保存；回车保留当前值，`:q` 或 EOF 取消。UUID、ShortID、密码和密钥的当前值保持隐藏。

| 协议 | 可修改字段 |
|---|---|
| 全部 | 名称、监听端口、对外 IP/域名 |
| REALITY / XHTTP | UUID、SNI、目标域名:端口、ShortID、公私钥 |
| XHTTP | 路径、模式（auto/packet-up/stream-up/stream-one） |
| SS2022 | 16 字节标准 Base64 主密钥 |
| VLESS(ws) | UUID、TLS SNI、WS 路径、TLS 证书/私钥 |
| AnyTLS / HY2 | 密码、TLS SNI、TLS 证书/私钥 |
| TUIC v5 | UUID、密码、TLS SNI、TLS 证书/私钥 |
| SOCKS5 | 认证用户名、密码 |

TLS 证书/私钥也可成对从绝对文件路径替换，并同时填写新 SNI；只在完整新证书匹配、有效期和 SAN 校验后提交。已安装状态的查看、编辑、删除和导出允许证书过期以便续期，结构、证书私钥匹配和 SAN 仍须合法；候选配置及导入保持严格有效期校验。

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
# TLS协议整体更新PEM，SNI可省略以保留
xy edit tls-node tls /etc/ssl/xray/fullchain.pem /etc/ssl/xray/private.key server.example.com
# 自动化才使用 --yes，日常秘密编辑优先使用菜单
xy --yes edit node-c name '新的 SS2022 名称'
```

CLI 格式为 `edit ID FIELD VALUE`；`keys` 例外接受私钥和公钥两个值，`tls` 接受证书路径、私钥路径和可选 SNI，`shortid` 是 `short_id` 的别名。`uuid`、`password` 也可按上表使用。非法字段、格式、密钥匹配和跨协议字段会被拒绝。只替换所选节点，其余节点和核心保持；保存先校验两核心候选配置，再事务切换，失败恢复两个配置及各核心原独立运行状态，原来停止的核心保持停止。仅首次新增辅助节点且主核心原运行时，辅助核心才随之首次启动。删除最后辅助节点会停用其服务。没有变化时不写配置、不重启服务。

## 新增协议示例

```sh
xy add vless-ws ws-a 'VLESS WS' 8443 server.example.com server.example.com /random-ws-path /etc/ssl/xray/fullchain.pem /etc/ssl/xray/private.key
xy add anytls at-a 'AnyTLS' 8444 server.example.com server.example.com /etc/ssl/xray/fullchain.pem /etc/ssl/xray/private.key
xy add hysteria2 hy-a 'HY2' 8445 server.example.com server.example.com /etc/ssl/xray/fullchain.pem /etc/ssl/xray/private.key
xy add tuicv5 tc-a 'TUIC v5' 8446 server.example.com server.example.com /etc/ssl/xray/fullchain.pem /etc/ssl/xray/private.key
xy add socks5 sk-a 'SOCKS5' 8447 server.example.com
```

菜单随机生成有效 UUID、用户名、密码和路径；SOCKS5 始终启用账号密码认证。添加 AnyTLS/HY2/TUIC v5 时按需安装校验后的固定辅助核心，运行配置和服务名为 `xray-manager-extra`。辅助核心下载、原生检查或启动失败时不提交节点，并撤销本次新建的辅助核心产物。现有辅助核心不会被误删。HY2/TUIC 使用 UDP，实际防火墙和安全组须按所选端口开放相应传输。

## 导出与导入配置

数据菜单仅有“导出配置”和“导入配置”。导出默认 `/root/xray-manager-export-时间戳.json`，也可输入任意已有目录中的绝对文件路径；目标必须不存在，保存 `0600` 私密 JSON，并明确显示位置与节点数。文件包含全部节点、服务器私钥、密码及 TLS PEM，不需要原证书文件就能迁移。

```sh
xy export /root/xray-manager-export.json
xy import /root/xray-manager-export.json
```

状态和导入文件必须只包含一个 schema 1 JSON 对象，最多 128 个节点且不超过 16 MiB；结构和重复字段会先校验，再进行完整协议及证书检查。导入会从普通文件受控读取到独占 0600 私密快照，超限、FIFO、目录和符号链接均拒绝；确认后只使用该快照，不重新读取外部源。导入严格检查完整 schema、所有协议参数、证书/私钥/有效期、名称/端口/凭据/路径重复以及监听冲突。它替换全部节点，保留本机当前 Xray 核心版本；确认期间节点变化会拒绝保存。两核心原生校验及服务健康失败会回退配置与各核心独立运行状态。`backup`/`restore` 是 CLI 兼容别名，菜单使用导出/导入术语。

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
xy export /root/xray-manager-export.json
xy --yes import /root/xray-manager-export.json
xy --yes uninstall
```

服务菜单的 `[7] 定时重启核心` 可查看状态、设置每日 `HH:MM`（默认 `04:00`）或禁用；时间为 24 小时格式 `00:00..23:59`。确认支持 `y`/`yes` 的任意大小写，回车或其他输入取消。任务按机器本机时区执行，只重启运行中的核心；各核心分别检查运行状态，定时不会启动停止中的任何核心。机器错过执行时刻不会补执行，启用时恰好处于指定分钟也不会立即补跑。首次安装默认关闭，卸载会移除项目专属定时任务。Debian 使用项目专属 systemd timer，Alpine 使用项目专属 OpenRC Python 调度服务；不修改全局 crontab。

升级管理脚本发现旧 Trojan 节点时，先验证状态结构并拒绝未知类型，再校验过滤后的配置，保存 `/etc/xray-manager/trojan-retired-backup.XXXXXXXX` 完整原状态（`0600`），原生配置和服务事务切换成功后才更新已安装脚本。失败保留旧运行状态及已安装代码，备份保留。备份含秘密，完全卸载会清理受管目录内的备份，应先导出到外部位置；新版不能恢复含已移除类型的旧备份，应仅提取仍支持的节点另行恢复。

所有变更由 `flock` 互斥。脚本先验证 JSON 和协议结构，再调用候选 Xray `xray run -test` 和有辅助节点时的 `sing-box check`，随后在同一文件系统中原子替换文件。重启或健康检查失败会恢复旧状态、配置、核心和运行状态；原来停止的服务在更新配置后仍保持停止。

服务日志按周期轮转（非瞬时硬上限），高日志量时需监控磁盘占用。

升级成功后保存上一核心及其版本，`rollback` 在原生校验通过后切换；再次回退可以切换回上一版本。恢复 JSON 只替换节点、保留当前核心版本；未知 schema、重复 ID/端口、不合法字段及不安全路径被拒绝。`config.json` 由状态生成，直接编辑会被诊断和服务启动检测为不一致。

下载仅使用官方 HTTPS release，核对其 `.dgst` 的 SHA256，并检查压缩包路径、文件类型、大小及 ELF 架构。摘要与资源来自同一发行源，摘要校验不等同于独立签名验证。安装需要 root，Xray 使用专用非登录账户运行。

信号 `INT`/`TERM` 会触发回退和清理；断电或 `SIGKILL` 无法运行清理逻辑。此时先运行 `diagnose`，保留 `/etc/xray-manager/.transaction.*` 现场以便从旧副本恢复，不应手工删除现场后直接重启。完全卸载先核对每个自有文件、目录、服务、账户和依赖计划，移除项目目录内配置、私密历史备份、日志、缓存、两个核心、服务、调度、`xy` 和专用账户。遇到未知文件、外部服务覆盖或符号链接会拒绝并保留现场，不递归误删陌生文件。用户在受管目录外的导出和证书不会删除。

远程部署、Bash 引导和依赖安装前记录完整已装包基线，仅记录本脚本新增包；重复安装不接管其他软件后来新增的包。完全卸载仅移除已记录、不是其他软件依赖且包管理器模拟删除清单安全的依赖；历史安装没有依赖记录时不猜删。系统既有包、SSH、其他软件依赖保留。

## 文件布局

| 路径 | 用途 |
|---|---|
| `/opt/xray-manager/` | 受信任脚本、模块、核心与上一版核心 |
| `/etc/xray-manager/state.json` | 版本化私密状态，schema 1 |
| `/etc/xray-manager/config.json` | 由状态生成的 Xray 配置 |
| `/etc/xray-manager/extra.json` | 由状态生成的 sing-box 配置 |
| `/etc/xray-manager/dependency-ledger.json` | 本次新增依赖与安装前基线 |
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
bash tests/test-migration.sh
bash tests/test-ui.sh
bash tests/test-platform.sh
bash tests/test-protocol.sh
```

`test-interactive.sh` 使用真实协议校验、模拟外部查询及真实 PTY，覆盖回车随机默认值、XHTTP、字段重提示、编号选择及列表变化保护、查询失败手动回退、取消/EOF、大小写确认、定时重启输入与停止核心跳过、升级二次确认以及颜色降级。

`test-edit.sh` 使用真实协议验证与状态事务、模拟核心执行和服务，覆盖三协议修改、成对密钥、字段/冲突拒绝、确认取消、快照并发和回退；它不冒充真实核心原生验证，真实核心校验另行执行。

`test-migration.sh` 用真实协议/状态事务与模拟核心执行/服务验证 PEM 可移植性、两核心回退和独立停止状态；`test-ui.sh` 用真实 PTY 验证标签、亮色、单键返回及非 TTY 不消费输入。真实两核心原生与客户端互通另行执行，不将模拟测试冒充 native/e2e。

`test-shell.sh` 使用隔离临时目录与模拟服务，覆盖锁冲突、原生校验失败、启动/健康失败、核心切换回退及历史版本元数据写失败。`XM_ROOT` 仅为隔离测试添加路径前缀，平台模块明确拒绝沙箱中对宿主账户、依赖和真实服务进行操作。

CI 在四个发行版容器中验证依赖安装、下载、Xray XHTTP 和新协议的两核心原生配置校验；容器检查不能替代真实 systemd / OpenRC 生命周期或端到端客户端连通。ARM64 资源有下载/ELF 验证支持，实际系统与架构验收需要单独核对对应候选版本的测试证据，不将支持列表等同于全部环境已经实测。

平台细节见 [平台说明](docs/platform.md)。脚本采用 MIT 许可；Xray 核心由其官方项目独立发行，本仓库不包含或再许可核心二进制。

管理脚本本身更新可运行 `xy update-manager`，或选择主菜单 `[4] 脚本更新`。它固定查询本项目 GitHub `main`，显示 main 提交和部署脚本所固定的运行提交，确认后执行项目部署入口，保留核心与节点。下载/校验/取消不改安装；安装失败会恢复原管理代码，不覆盖节点或核心，也不承诺撤销安装器的软件包副作用。成功后菜单退出，请重新运行 `xy` 加载新模块。核心版本切换仍使用 `upgrade`。

管理脚本更新执行期间收到 INT、TERM 或 HUP 时，会保留权限为 0700 的代码恢复目录并显示路径，供检查和恢复；不会删除唯一备份，也不自动改写节点数据。此行为区别于节点/核心配置事务的 INT/TERM 回退。SIGKILL 和断电无法由 Shell 捕获。
