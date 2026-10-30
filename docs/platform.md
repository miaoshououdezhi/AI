# 平台与运行维护

## 系统与核心

支持 Debian 12 / 13（systemd）、Alpine 3.23 / 3.24（OpenRC），架构为 amd64 和 arm64。运行需要 Bash ≥ 4.4，安装器自动准备依赖。

Xray 默认版本为 v26.10.29，支持选择官方版本升级及回退。新建 HY2 由 Xray 运行。历史辅助核心节点继续使用 sing-box 1.14.2。下载来自各核心的官方 HTTPS 发布资源，检查摘要、归档路径、文件类型和架构；下载或校验失败时保留旧核心。

新 HY2 要求实际安装的 Xray 为 v26.10.29 或更新版本，较旧版本会提示先升级。升级管理脚本保留现有核心；旧 HY2 未设置 `engine` 或为 `sing-box` 时保持辅助核心运行，新 HY2 的 `engine=xray` 使用主核心 UDP 健康检查。

## 服务与权限

| 项目 | 主核心 | 辅助核心 |
| --- | --- | --- |
| 服务名 | `xray-manager` | `xray-manager-extra` |
| 程序 | `/opt/xray-manager/bin/xray` | `/opt/xray-manager/bin/sing-box` |
| 配置 | `/etc/xray-manager/config.json` | `/etc/xray-manager/extra.json` |
| 协议 | REALITY、XHTTP、SS2022、VLESS WS、HY2、SOCKS5 | 历史辅助核心节点 |

两核心使用专用非登录账户 `xray-manager`。状态和配置使用受限权限，导出文件使用 `0600`。首次安装不创建节点；辅助核心在需要时安装，删除最后一个辅助节点后停用其服务。

配置变更先完成参数和原生配置检查，再切换文件并检查服务。失败时恢复原状态、配置和各核心原来的运行状态。停止中的核心不会因普通配置修改而启动。

`xy diagnose` 检查配置一致性、核心和服务健康。程序不改写全局防火墙、SSH、DNS 或用户 crontab。服务器端口是否可访问，还取决于网络、防火墙、云安全组和客户端设置。

## 定时任务

系统更新和核心重启计划均默认关闭，时间采用服务器本机时区，格式为 `HH:MM`。

- 核心重启：每日执行，只重启运行中的核心；错过时间不补跑。
- 系统更新：支持每日、每周一、每月 1 日，或仅手动；只在计划分钟执行，错过不补跑。
- Debian 使用项目专属 systemd timer，Alpine 使用项目专属 OpenRC 调度服务。

Debian 系统更新先执行 `apt-get --error-on=any update`，索引全部成功后执行 `DEBIAN_FRONTEND=noninteractive apt-get upgrade --with-new-pkgs -y`。Alpine 执行 `apk update` 后执行 `apk upgrade`。软件包升级可能重启服务；脚本不自动重启机器，不能通用回滚系统包变更。

## 日志

`xy logs` 默认显示主核心最近 80 行，也可选择 `extra`、`update`、`restart`。Debian 读取相应服务 journal；Alpine 使用 `/var/log/xray-manager/` 下的日志：

| 日志 | 用途 |
| --- | --- |
| `console.log` | Xray |
| `extra-console.log` | sing-box |
| `system-update-schedule.log` | 系统更新 |
| `restart-schedule.log` | 定时重启 |

四类日志均配置每日检查、`maxsize 10M`、保留 4 份、压缩和数字编号轮转。核心日志为 `0640`，调度日志为 `0600`。轮转依赖周期执行，并非实时大小上限。项目轮转配置使用 `nodateext`；已有的 `-YYYYMMDD` 及 `.gz` 日期归档仍可在卸载时清理。

访问日志关闭，保留警告和错误。最近的原生配置校验错误保存在受管日志目录；节点状态损坏时仍可查看日志。

## 备份与恢复

`state.json` 是节点状态来源，`config.json` 和 `extra.json` 由管理器生成。使用 `xy export` 备份完整节点、出站路由及 TLS PEM；导入时保留目标机器的 Xray 核心版本。

升级核心后保留上一版及其版本信息，`xy rollback` 在校验通过后切换。脚本更新失败会恢复原管理代码；更新过程中收到中断信号时，可能保留代码恢复目录并显示路径。

断电和 `SIGKILL` 无法触发清理。发生异常后先运行 `xy diagnose`，保留 `/etc/xray-manager/.transaction.*` 及提示的代码恢复目录，确认恢复内容后再操作服务。

## 卸载范围

安装器记录安装前软件包及本项目新增依赖。完全卸载先检查目录归属、文件类型、服务、账户与依赖计划，再清理项目资源。未知文件、符号链接、外部服务覆盖或共享账户资源会导致预检失败并保留现场。

受管日志支持数字轮转和八位日期归档。项目外导出、证书及系统标准父目录保留。依赖删除使用包管理器模拟结果，仅删除可安全移除的已记录新增包；系统基础包、SSH、共享包和无历史记录的包保留，不执行全局 autoremove。

首次安装失败且核心或状态不完整时，可重试安装；也可在完整项目目录执行 `bash xray-manager.sh --yes uninstall`，通过相同预检后清理。
