# xray-manager

面向 Linux 服务器的中文终端管理工具，提供节点配置、分享、独立出站路由、核心升级回退、系统更新、定时任务、配置迁移和完整卸载。输入 `xy` 打开菜单，也可通过命令行管理。

## 支持环境

| 项目 | 支持范围 |
| --- | --- |
| 系统 | Debian 12 / 13、Alpine 3.23 / 3.24 |
| 架构 | amd64、arm64 |
| 服务管理 | Debian 使用 systemd；Alpine 使用 OpenRC |
| Xray 默认版本 | v26.10.29，可指定官方版本升级 |
| 历史节点兼容 | 保留既有 sing-box 节点的管理及数据迁移 |

安装和管理操作需要 root，依赖由安装器准备。首次安装没有节点，不开放代理监听；添加节点后，请按实际端口配置服务器防火墙和云安全组。

## 安装

通过 SSH 登录服务器，切换到 root 后执行：

```sh
wget -O xray-manager-install.sh https://raw.githubusercontent.com/miaoshououdezhi/AI/main/deploy.sh && \
sh xray-manager-install.sh
```

安装入口下载固定版本的完整项目，无需预装 Git 或 Bash。安装完成后运行：

```sh
xy
```

若缺少 `wget` 或 HTTPS 根证书，先安装：

```sh
# Debian
apt-get update && apt-get install -y wget ca-certificates

# Alpine
apk add --no-cache wget ca-certificates
```

也可以下载完整仓库后安装：

```sh
git clone https://github.com/miaoshououdezhi/AI.git
cd AI
sh install.sh
```

重复安装保留当前支持的节点和核心。项目内的 `install.sh` 依赖同目录模块，不能单独下载使用。

## 主菜单

```text
核心管理
[1]   安装核心          [2]  版本升级
[3]   核心回退          [4]  脚本更新
[5]   系统更新

节点管理
[6]   节点管理          [7]  添加节点
[8]   删除节点          [9]  分享链接

运行维护
[10]  服务操作          [11]  查看日志
[12]  运行诊断

数据管理
[13]  导出配置          [14]  导入配置

危险操作
[15]  完全卸载

[0]   退出脚本
```

菜单显示系统、CPU、内存、磁盘、核心版本和运行状态。宽终端使用两列，少于 60 列时改为单列，左列功能名称保持对齐。功能文字为白色，编号和分组使用独立颜色；重定向输出、`NO_COLOR` 或 `TERM=dumb` 下使用纯文本。

回车接受提示中的默认值，输入 `:q` 取消当前输入，输入 `0` 返回或退出。删除、导入、升级和卸载等操作会要求确认；CLI 自动化可在命令前加 `--yes`。

## 节点管理

| 协议 | 核心 | 说明 |
| --- | --- | --- |
| VLESS REALITY Vision | Xray | 自动生成 UUID、密钥和 ShortID |
| VLESS XHTTP + REALITY | Xray | 支持 packet-up、auto、stream-up、stream-one |
| Shadowsocks 2022 | Xray | 可选 AES-128-GCM / AES-256-GCM，TCP / UDP |
| VLESS WebSocket + TLS | Xray | 使用已有 TLS 证书与私钥 |
| 认证 SOCKS5 | Xray | 用户名密码认证，协议本身不加密 |
| Hysteria2 / HY2 | Xray | QUIC / UDP，使用 TLS 证书和私钥 |

添加 SS2022 时可选择 `2022-blake3-aes-128-gcm` 或 `2022-blake3-aes-256-gcm`，分别自动生成 16 / 32 字节 Base64 主密钥。添加节点时可使用随机 ID、名称、端口及凭据；对外地址可自动探测或手动填写。REALITY / XHTTP 默认 SNI 为 `genshin.hoyoverse.com`，目标为该域名的 443 端口，可按服务器连通情况调整。

节点管理、分享和删除使用相同的编号卡片：每个节点单独一组，名称、地址和 ID 按字段对齐。详情逐行显示字段；输入使用独立的 `[输入]` 与 `>` 行，分享结果单独成区，链接保持完整。进入详情后可修改名称、端口、对外地址、SNI 及协议专属字段。凭据默认隐藏，选择分享才输出客户端链接。保存前会检查参数、冲突和核心配置，失败时恢复原配置及服务运行状态。

```sh
xy add vless-reality node-a '我的 REALITY' 1443 server.example.com genshin.hoyoverse.com genshin.hoyoverse.com:443
xy add shadowsocks node-b '我的 SS2022' 3443 server.example.com
xy list
xy share node-a
xy edit node-a name '新的名称'
xy edit node-a port 1444
xy --yes delete node-b
```

HY2 新节点使用 Xray；已有安装若核心版本低于 v26.10.29，请先通过“版本升级”更新核心。更新管理脚本不会强制切换现有核心，旧 HY2 节点保持原运行方式。

完整协议参数及 TLS 要求见 [协议说明](docs/protocols.md)，全部命令可用 `xy help` 查看。日常凭据输入建议使用菜单，避免写入 Shell 历史或进程参数。

## 节点独立出站路由

Xray 节点详情提供“设置出站 / 落地节点”和“删除出站 / 恢复直连”。链路为“客户端 → 当前节点 → 粘贴的落地节点 → 目标网站”。每个节点可配置一个上游，选择全部流量经上游，或仅让指定域名 / IP 经上游；其他节点保留各自设置，删除路由后恢复直连。新建 HY2 也支持 Xray 出站路由；历史 sing-box 节点不提供此功能。

支持的上游格式及限制见 [协议说明](docs/protocols.md#出站路由)。CLI 从标准输入读取上游链接：

```sh
# 私密文件应设置为 0600 权限
xy --yes route add node-a < /root/upstream-uri.txt
xy --yes route add node-a rules '["domain:example.com"]' '["203.0.113.0/24"]' < /root/upstream-uri.txt
xy route show node-a
xy --yes route delete node-a
```

域名或 IP 任一规则命中即经上游，其余直连。域名规则依赖请求中已有域名，不自动嗅探；私网及保留地址拦截规则保持生效。

## 更新、服务与定时任务

更新管理脚本可选择 `[4] 脚本更新`，或执行：

```sh
xy update-manager
```

更新保留核心和节点。成功后重新运行 `xy`，加载新脚本。Xray 核心通过 `[2] 版本升级` 选择版本，或显式指定官方版本；`rollback` 切换到保存的上一版核心。

```sh
xy upgrade v26.10.29
xy rollback
xy service status
xy service restart
xy diagnose
```

`[5] 系统更新` 支持立即更新、每日、每周一或每月 1 日更新，也可设为仅手动。系统更新使用当前软件仓库：Debian 先完整更新索引，再升级软件包；Alpine 执行 `apk update` 和 `apk upgrade`。不切换发行版、不自动重启机器。软件包升级可能重启服务，系统包变更不能通用回滚。

```sh
xy update-system
xy system-update-schedule status
xy --yes system-update-schedule set daily 04:00
xy --yes system-update-schedule set weekly 04:00
xy --yes system-update-schedule set monthly 04:00
xy --yes system-update-schedule disable
```

服务菜单还支持每日定时重启核心。两类计划默认关闭，使用服务器本机时区和 `HH:MM` 格式，错过执行时间不补跑；定时重启只处理正在运行的核心。

```sh
xy schedule status
xy --yes schedule set 04:00
xy --yes schedule disable
```

查看日志可选择主核心、辅助核心、系统更新或定时重启：

```sh
xy logs 80
xy logs extra 80
xy logs update 80
xy logs restart 80
```

## 配置导出与导入

```sh
xy export /root/xray-manager-export.json
xy import /root/xray-manager-export.json
```

导出包含全部节点、独立出站路由、认证资料及内嵌 TLS 证书私钥，使用 `0600` 权限。目标需为已有目录中的绝对路径，且文件尚不存在。请妥善保管，不要公开上传。

导入会校验文件、节点参数、证书和端口冲突；确认后替换全部节点，保留本机当前 Xray 版本。支持最多 128 个节点，文件上限 16 MiB。跨机器迁移前先更新目标机器的管理脚本。

## 完全卸载

选择 `[15] 完全卸载`，或执行：

```sh
xy --yes uninstall
```

卸载移除项目配置、节点、日志、核心、服务、定时任务、专用账户和 `xy`，并清理已记录且不被其他软件使用的新增依赖。系统原有包、共享依赖、项目目录外的导出文件和证书保留。

项目日志的数字轮转文件以及 `console.log-20261027` 这类日期归档均可正常清理。遇到未知文件、符号链接或外部服务覆盖时，卸载会中止并显示具体路径；应先确认文件用途，不要直接删除未知文件。

## 目录与更多说明

| 路径 | 内容 |
| --- | --- |
| `/opt/xray-manager/` | 管理脚本、模块、核心及上一版核心 |
| `/etc/xray-manager/` | 私密节点状态、生成配置和定时计划 |
| `/var/lib/xray-manager/` | 服务运行数据 |
| `/var/log/xray-manager/` | 日志及最近的配置校验错误 |
| `/usr/local/bin/xy` | 全局命令入口 |

节点配置请通过菜单或 CLI 修改，直接改写生成的 `config.json` 会导致状态不一致。异常中断后先运行 `xy diagnose`，保留事务恢复目录；具体服务、日志与恢复行为见 [平台说明](docs/platform.md)。

本项目采用 [MIT 许可证](LICENSE)。Xray 和 sing-box 由各自官方项目独立发行。
