# 协议与节点契约

初版以 Xray-core **v26.3.27** 为兼容基线。安装其他显式版本时，管理器会用该版本的 `xray run -test -config` 检查；通过配置检查不代表真实客户端已互通。Xray 的该版本仍接受 Trojan 和 Shadowsocks，但会输出未来可能删除的弃用提示，升级前应备份并执行互通检查。

## 三种节点

| 类型 | 服务端参数 | 客户端映射 |
| --- | --- | --- |
| `vless-reality` | UUID、X25519 公私钥、SNI、target、shortId | VLESS + REALITY + `xtls-rprx-vision`，TCP/RAW，Chrome 指纹；公钥填入 `pbk` |
| `trojan` | 密码、已有 TLS 证书和私钥 | Trojan + TLS + TCP/RAW；SNI 等于对外地址，客户端保持证书验证 |
| `shadowsocks` | 随机 16 字节 Base64 密钥 | `2022-blake3-aes-128-gcm`；TCP 与 UDP |

`address` 是分享地址，接受裸 IPv4、裸 IPv6 或 ASCII 域名，IPv6 不带方括号或 scope ID。分享函数会自行增加方括号。普通中文显示名称会按 UTF-8 percent-encoding 写入 URI；显示名称不能包含换行和终端控制字符。

所有节点默认绑定双栈 `::`。通过创建临时 IPv6 socket、绑定端口 0 后立即关闭，探测协议栈支持，不启动监听。Linux 内核没有 IPv6，或 `/proc/sys/net/ipv6/conf/all/disable_ipv6=1` 时，自动使用 IPv4 `0.0.0.0`；不更改系统网络设置。IPv4 模式拒绝 IPv6 节点地址。IPv6 分享地址需要服务器自身具有可用 IPv6 与相应路由。若测试沙箱禁止所有 socket 操作，探测结果无法确定，保留双栈配置，由原生 Xray 配置与实际服务启动检查作最终判断。

REALITY 的 `sni` 需与目标站点的证书相符，`target` 为 `host:port`，IPv6 target 写成 `[IPv6]:port`。应选择可从服务器访问、支持 TLS 1.3 的合适站点。shortId 限定为 2–16 位偶数长度十六进制。管理器检查 UUID、密钥编码及公私钥对应关系；不会把服务端私钥写入分享 URI。

Trojan 要求证书 SAN 与 `address` 一致、尚未过期、证书与私钥匹配。路径必须是普通绝对路径文件，拒绝直接符号链接与组/其他用户可写文件，私钥禁止其他用户访问；通常为 `0640 root:xray-manager`，所在目录须让服务账户可以遍历。当 root 调用且服务账户已经存在时，会实际检查该账户可读。管理器不替用户修改外部证书权限，不申请证书，也不添加 `allowInsecure`。自签证书只适用于客户端显式信任它的环境。

建议在受管目录之外的 `/etc/ssl/xray/` 准备证书与私钥，确保服务账户可读，并自行维护续期。状态备份记录证书路径，不包含外部证书文件；恢复前须保证对应文件存在。

## 状态 JSON

状态 schema 为 `schema_version: 1`，`nodes` 数组最多 128 项，ID 与端口不得重复。每个节点必须恰好具有对应字段；未知节点字段被拒绝。

| 字段 | 约束 |
| --- | --- |
| `id` | 字母开头，随后为字母、数字、`_` 或 `-`，1–32 字符 |
| `name` | 1–128 字符，无控制字符 |
| `type` | 上述三种类型之一 |
| `port` | JSON 整数，1–65535 |
| `address` | IP 或 ASCII 域名，不含协议前缀、端口或路径 |
| VLESS 额外字段 | `uuid`, `private_key`, `public_key`, `short_id`, `sni`, `target` |
| Trojan 额外字段 | `cert`, `key`, `password`，密码 16–256 字符 |
| Shadowsocks 额外字段 | `method`, `password`，method 固定上述 SS2022 算法，password 为 16 字节标准 Base64 |

状态、配置和备份包含认证资料，应按管理器的目录及权限要求保管。只有显式调用分享操作才展示客户端认证信息。函数内部通过 stdin 将敏感值交给 JSON/校验程序，避免把密钥放进它们的命令行参数。

## 模块函数

这些函数只有被调用时才执行；source 模块不会修改系统。

```text
protocol_new vless-reality ID NAME PORT ADDRESS SNI TARGET [UUID PRIVATE PUBLIC SHORTID]
protocol_new trojan ID NAME PORT ADDRESS CERT KEY [PASSWORD]
protocol_new shadowsocks ID NAME PORT ADDRESS [PASSWORD]
protocol_validate_node NODE_JSON
protocol_generate STATE_FILE OUTPUT_FILE
protocol_share NODE_JSON
```

成功返回 0；失败返回非 0 并向 stderr 写诊断。`new` 输出完整节点 JSON，`share` 输出单条 URI；其他操作成功时不输出秘密。`generate` 生成限制权限的配置文件，事务切换、最终运行组权限及 Xray 原生校验由上层管理器执行。REALITY 未提供固定密钥参数时，使用 `XRAY_BIN` 或 `XM_BIN` 指向的 Xray 生成；固定版本输出的第二项为 `Password (PublicKey)`，它是客户端需要的 X25519 公钥。`XM_PYTHON` 仅为指定可用 Python 解释器的可选环境覆盖，Linux 默认 `python3`。

生成配置具有 direct 默认出口、block 出口和显式私网/保留网段阻断规则，使用 `IPOnDemand`，不依赖 geoip/geosite 文件，不更改全局 DNS。私网、loopback、链路本地与组播目的流量被阻断；不提供代理访问服务器内网的开关。REALITY 的伪装 target 不属于代理出站路由。生产配置使用 `loglevel: warning` 与 `access: none`，禁用逐连接访问日志。没有节点时，`inbounds: []`，Xray 保持运行且不开放任何监听。

Shadowsocks 分享采用 SIP002 的 AEAD-2022 格式：method/password 分别 percent-encode，禁止将整个 userinfo Base64URL 编码。VLESS/Trojan 分享参照 v2rayN 的 URI 字段约定。不同客户端的导入实现可能有差异，验收互通使用同版本 Xray 客户端；不声明所有第三方客户端均实测通过。

## 检查与来源

```bash
XRAY_BIN=/path/to/xray bash tests/test-protocol.sh
XRAY_BIN=/path/to/xray bash tests/test-protocol.sh --e2e
```

第一项执行非法输入、证书身份与权限、URI 编码、IPv4 fallback、空节点及三协议原生配置检查。第二项在临时 loopback 端口启动真实 Xray 客户端与服务端，使用 SOCKS5 请求公网 HTTPS，TLS 检查保持开启；默认请求目标为 `https://example.com`，REALITY SNI/伪装目标为 `www.cloudflare.com` / `www.cloudflare.com:443`。需要网络与本地端口绑定能力。临时凭据和进程退出时清理。可通过 `XM_REALITY_SNI`、`XM_REALITY_TARGET`、`XM_E2E_URL` 修改测试目标；这些参数只影响测试。目标站点与区域可达性会影响 REALITY 握手：在本次授权服务器中 Cloudflare 目标互通通过，Microsoft 目标未通过，因此不能把任意公开 TLS 站点当成必然可用。`XM_E2E_DEBUG=1` 仅为随机测试 fixture 开启详细诊断及访问日志，生产日志配置保持不变。

来源核实日期：2026-10-02。实现为原创，以下资料用于核对语义和格式：

- [Xray v26.3.27 X25519 输出源码](https://github.com/XTLS/Xray-core/blob/v26.3.27/main/commands/all/curve25519.go)。
- [Xray v26.3.27 传输配置源码](https://github.com/XTLS/Xray-core/blob/v26.3.27/infra/conf/transport_internet.go)。
- [REALITY 文档](https://xtls.github.io/config/transport.html)、[Shadowsocks 文档](https://xtls.github.io/config/inbounds/shadowsocks.html)。在线文档可能继续更新，固定版本最终以源码及实测为准。
- [SIP002 URI 标准](https://shadowsocks.org/doc/sip002.html)。
- [v2rayN VLESS URI](https://github.com/2dust/v2rayN/blob/master/v2rayN/ServiceLib/Handler/Fmt/VLESSFmt.cs)、[Trojan URI](https://github.com/2dust/v2rayN/blob/master/v2rayN/ServiceLib/Handler/Fmt/TrojanFmt.cs)。仅核对字段映射，未宣称特定 v2rayN 发布版本的互通结果。
