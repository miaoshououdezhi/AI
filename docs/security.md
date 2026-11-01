# 安全更新与修复边界

核查日期：2026-11-01。项目使用 Xray v26.10.31，历史节点的辅助核心使用 sing-box 1.14.4；管理器本身是 Bash 与 Python，不安装或运行 PHP。

## Linux 内核与 MPTCP

[CVE-2026-98432](https://security-tracker.debian.org/tracker/CVE-2026-98432) 位于 Linux IPv4 TCP 处理路径。Xray v26.10.31 默认关闭 MPTCP，本项目的主、辅助核心 systemd 和 OpenRC 服务也设置 `GODEBUG=multipathtcp=0`。这只影响本项目服务，不改全局 sysctl、防火墙或其他应用。

[Go 官方公告](https://groups.google.com/g/golang-announce/c/PCoQcdxoScw/m/aD-MgXEvAAAJ) 明确指出，禁用 MPTCP 只能降低暴露面，漏洞并不限于 MPTCP；完整修复依赖修复后的内核。更新服务定义不会改变已运行进程，需重新启动核心服务后生效。

已有服务器先更新管理脚本和核心：

```sh
xy update-manager
xy upgrade v26.10.31
# 仅已有历史辅助核心时执行：
xy upgrade-extra
xy service restart
xy diagnose
```

之后通过 `xy update-system` 或发行版包管理器安装安全更新。依据发行版安全公告确认安装的内核包已包含修复，并在合适的维护时间重启进入修复后的内核，或使用发行版支持的有效 live patch。容器共享宿主内核，容器内升级软件包不能修复宿主内核；托管内核需联系提供商。不要仅凭 `uname` 的上游版本号判断发行版回移补丁是否存在。脚本不会自动重启服务器。

## Go 与辅助核心

Xray v26.10.31 官方 Linux 构建使用 Go 1.27.3。旧 sing-box 1.14.2 使用 Go 1.26.8；本项目固定的 sing-box 1.14.4 使用 Go 1.26.10，包含 [10 月 Go 安全更新](https://groups.google.com/g/golang-announce/c/66pojueaQek)。Go 运行库编入二进制，单独更新服务器上的 Go 工具链不会修复旧代理二进制。

下载仍来自官方 HTTPS 发布资源，校验固定摘要、归档路径、文件类型和 ELF 架构。旧辅助核心保留管理与迁移兼容，并提示显式执行 `xy upgrade-extra`；升级失败保留旧版本，需排除失败原因后重试。为降低风险，不应长期继续使用旧辅助核心或回退至已撤下的 Xray 版本。

这次核查不代表所有第三方依赖均无漏洞。sing-box 仍包含当前辅助节点配置没有启用的 HTTP/2、SSH 等依赖功能；若将来扩展配置，应重新核查对应依赖与可达路径。不要在管理器生成的配置之外直接启用未经验证的功能。

## PHP 与部署环境

[近期 PHP 官方公告](https://www.php.net/archive/2026.php) 中的 PHP 请求处理漏洞不直接适用于本项目，因为本项目没有 PHP 运行时或站点。若服务器同时运行 PHP 网站，需要按发行版或 PHP 官方公告单独更新 PHP 和相关服务；仓库检查无法确认那台服务器的实际状态。

CI 验证管理器逻辑、Linux amd64 容器中的核心配置及回环互通，并验证 `deploy.sh` 固定提交与当前运行文件一致。CI 不证明生产服务器内核已修复、Linux ARM64 已实机测试，或完整 systemd/OpenRC 启动已验证。
