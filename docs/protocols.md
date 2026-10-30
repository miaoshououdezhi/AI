# 协议与节点

## 支持协议

| CLI 类型 | 协议与传输 | 凭据及主要参数 |
| --- | --- | --- |
| `vless-reality` | VLESS + REALITY + Vision，TCP / RAW | UUID、X25519 密钥对、SNI、target、ShortID |
| `vless-xhttp` | VLESS + XHTTP + REALITY | REALITY 参数、path、mode；不使用 Vision flow |
| `shadowsocks` | Shadowsocks 2022，TCP / UDP | `2022-blake3-aes-128-gcm` / `2022-blake3-aes-256-gcm`，分别为 16 / 32 字节标准 Base64 密钥 |
| `vless-ws` | VLESS + WebSocket + TLS | UUID、SNI、WS 路径、证书与私钥 |
| `socks5` | 认证 SOCKS5，TCP / UDP | 用户名和密码；协议本身无传输加密 |
| `hysteria2` | Hysteria2 / HY2，QUIC / UDP | 密码、SNI、证书与私钥 |

添加菜单与 CLI 支持以上六种协议，均使用 Xray，默认版本为 v26.10.29。历史辅助核心节点可继续管理、分享及备份。

## 通用字段

- ID：字母开头，后续可用字母、数字、`_`、`-`，长度 1–32。
- 名称：长度 1–128，不含控制字符。
- 端口：1–65535，各节点不能重复；菜单默认随机选取未占用的高位端口。
- 地址：裸 IPv4、裸 IPv6 或 ASCII 域名，不包含协议前缀、端口或路径。IPv6 分享链接由脚本自动加方括号。

节点默认监听双栈 `::`，检测到系统禁用 IPv6 时使用 `0.0.0.0`。使用 IPv6 分享地址需要服务器本身具备可用 IPv6。生成的路由默认直连，并拦截私网、回环、链路本地、组播等保留目的地址。

## REALITY 与 XHTTP

SNI 应与目标 TLS 服务的证书相容，target 使用 `host:port`，IPv6 目标使用 `[IPv6]:port`。目标需可从服务器访问并支持合适的 TLS；XHTTP + REALITY 目标应支持 TLS 1.3 和 H2。

交互默认 SNI 为 `genshin.hoyoverse.com`，目标为 `SNI:443`。UUID、密钥对和 ShortID 自动生成；ShortID 为 2–16 位偶数长度十六进制。分享链接只包含客户端所需公钥，不包含服务端私钥。

XHTTP 路径以 `/` 开头，长度 2–128，只接受 ASCII 字母、数字、`/`、`_`、`-`，不能包含连续斜线。默认随机生成路径；模式支持 `packet-up`（默认）、`auto`、`stream-up`、`stream-one`。

```sh
xy add vless-reality reality-a 'REALITY' 1443 server.example.com genshin.hoyoverse.com genshin.hoyoverse.com:443
xy add vless-xhttp xhttp-a 'XHTTP' 2443 server.example.com genshin.hoyoverse.com genshin.hoyoverse.com:443 /a7d390ef52c1068b packet-up
xy add shadowsocks ss-a 'SS2022 AES128' 3443 server.example.com
# 空密码让脚本生成随机密钥；算法为可选的最后一个参数
xy add shadowsocks ss-b 'SS2022 AES256' 3444 server.example.com '' 2022-blake3-aes-256-gcm
```

## HY2 与 TLS

新建 HY2 使用 Xray 的 Hysteria2 入站、TLS 1.3 和 QUIC / UDP，需要 Xray v26.10.29 或更新版本。旧 HY2 缺少 `engine` 字段时继续使用 sing-box；新节点保存 `engine: "xray"`，生成配置、健康检查和出站路由按所属核心处理。

TLS 节点读取现有证书和匹配私钥，检查生效时间、有效期、SAN 与 SNI、公私钥对应关系。文件使用绝对路径，必须是普通文件且不能是符号链接；证书和私钥不可被组或其他用户写入，私钥不可被其他用户读取。仅接受未加密 PEM 私钥。

证书和私钥内嵌到私密状态与导出文件，跨机器迁移无需原始证书路径。脚本不申请 ACME 证书，分享链接不包含服务器私钥，也不默认跳过 TLS 验证。自签证书需要客户端信任。

```sh
xy add vless-ws ws-a 'VLESS WS' 8443 server.example.com server.example.com /random-ws-path /etc/ssl/xray/fullchain.pem /etc/ssl/xray/private.key
xy add hysteria2 hy-a 'HY2' 8445 server.example.com server.example.com /etc/ssl/xray/fullchain.pem /etc/ssl/xray/private.key
xy add socks5 sk-a 'SOCKS5' 8447 server.example.com
```

未提供的 UUID、用户名和密码自动生成。HY2 使用 UDP，防火墙和安全组应开放对应 UDP 端口。SOCKS5 始终启用用户名密码认证。

## 修改与分享

所有节点可修改名称、端口和对外地址，其他字段按协议提供：

| 协议 | 其他可修改字段 |
| --- | --- |
| REALITY / XHTTP | UUID、SNI、target、ShortID、成对密钥 |
| XHTTP | path、mode |
| SS2022 | password |
| VLESS WS | UUID、SNI、path、TLS 证书与私钥 |
| HY2 | password、SNI、TLS 证书与私钥 |
| SOCKS5 | username、password |

```sh
xy edit reality-a address server.example.com
xy edit reality-a short_id a4b7
xy edit xhttp-a path /new-random-path
xy edit xhttp-a mode packet-up
xy edit ws-a tls /etc/ssl/xray/fullchain.pem /etc/ssl/xray/private.key server.example.com
xy share reality-a
```

ID 和协议类型固定。更新 REALITY 密钥时必须同时提供匹配的私钥和公钥；TLS 更新同时提供证书和私钥，可附新 SNI。日常秘密输入建议使用菜单。

已有证书过期时，仍可查看、导出、删除或更换证书；新建、导入及变更节点需通过有效期检查。分享链接包含客户端认证资料，第三方客户端需支持相应协议和传输。

## 出站路由

Xray 节点可各自保存一个上游，支持以下分享链接：

- `ss://`：SS2022 AES-128、AES-256、ChaCha20，以及受支持的 AEAD Shadowsocks。SS2022 AES 支持 `PSK:identity` 密钥链，ChaCha20 使用单密钥。
- `vless://`：TLS / REALITY 与 RAW / WS / XHTTP 的受支持组合。
- `trojan://`：TLS RAW / WS 上游。
- `socks://` / `socks5://`：带用户名密码认证的上游。

这是上游出站支持列表，不能据此添加同类型入站。订阅、插件、辅助核心协议、未知或重复参数、不兼容传输及不安全 TLS 参数会被拒绝。链接为单行，最多 8192 字符。

`all` 模式让当前节点流量经上游；`rules` 模式使用域名和 IP JSON 数组，至少一类非空，任一匹配即可经上游。域名写为 `domain:example.com` 或 `full:example.com`，IP 接受 IPv4 / IPv6 或 CIDR。未命中流量直连，私网及保留地址拦截优先。

路由保存在私密节点状态和导出文件中。当前入站的分享链接不包含服务器上游秘密，`route show` 只显示脱敏摘要。

## 配置文件

状态使用 `schema_version: 1`，最多 128 个节点，导入文件上限 16 MiB。节点 ID、名称、端口、凭据及相关路径按规则检查冲突，未知字段被拒绝。

出站路由使用可选 `outbound_route` 字段，包含 `uri`、`mode`、`domains`、`ips`。未配置路由的文件可直接导入；含路由的文件应导入已支持该功能的管理器。

请通过菜单、CLI 或完整导入修改节点，不直接编辑生成的核心配置。状态与导出包含秘密，应保持私密权限。
