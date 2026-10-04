#!/usr/bin/env python3
"""Strict share-URI to Xray outbound mapping. Credentials only arrive on stdin."""
import base64
import binascii
import ipaddress
import json
import re
import sys
import unicodedata
import urllib.parse
import uuid

MAIN_TYPES = {"vless-reality", "vless-xhttp", "vless-ws", "shadowsocks", "socks5"}
FINGERPRINTS = {"chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized"}
METHODS = {"aes-128-gcm", "aes-256-gcm", "chacha20-poly1305", "chacha20-ietf-poly1305", "xchacha20-poly1305", "xchacha20-ietf-poly1305", "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305"}

def need(condition, message):
    if not condition:
        raise ValueError(message)

def text(value, limit=4096, empty=False):
    need(isinstance(value, str) and (empty or bool(value)) and len(value) <= limit and not any(unicodedata.category(c) in ("Cc", "Cs") for c in value), "文本字段格式无效")
    return value

def host(value):
    text(value, 253)
    need("%" not in value, "不支持带 scope ID 的地址")
    try:
        ipaddress.ip_address(value)
    except ValueError:
        need(bool(re.fullmatch(r"(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", value)), "地址必须是裸 IP 或 ASCII 域名")
    return value

def decode(value):
    need(not re.search(r"%(?![0-9A-Fa-f]{2})", value), "URI 百分号编码无效")
    return text(urllib.parse.unquote(value, errors="strict"), empty=True)

def unbase(value):
    need(bool(re.fullmatch(r"[A-Za-z0-9+/_-]+={0,2}", value)), "Base64 编码无效")
    return base64.b64decode(value.replace("-", "+").replace("_", "/") + "=" * (-len(value) % 4), validate=True).decode("utf-8")

def parse_uri(uri):
    text(uri, 8192)
    need(not any(c.isspace() for c in uri), "节点链接不能含空白")
    # Legacy Shadowsocks encodes the complete method:password@host:port.
    if uri.startswith("ss://") and "@" not in uri.split("#", 1)[0]:
        body, sep, fragment = uri[5:].partition("#")
        need("?" not in body, "不支持此 Shadowsocks 链接参数")
        uri = "ss://" + unbase(body) + (sep + fragment if sep else "")
    u = urllib.parse.urlsplit(uri)
    need(u.scheme in {"vless", "trojan", "ss", "socks", "socks5"}, "不支持此出站链接协议")
    need(u.path in ("", "/") and "@" in u.netloc, "节点链接结构无效")
    decode(u.fragment)  # Labels are metadata; still reject malformed/control text.
    address = host(u.hostname)
    port = u.port
    need(type(port) is int and 1 <= port <= 65535, "出站端口必须为 1..65535")
    need(u.netloc.count("@") == 1, "凭据中的保留字符须进行百分号编码")
    credential = decode(u.netloc.rsplit("@", 1)[0])
    pairs = urllib.parse.parse_qsl(u.query, keep_blank_values=True, strict_parsing=True, errors="strict")
    need(not re.search(r"%(?![0-9A-Fa-f]{2})", u.query), "URI 百分号编码无效")
    q = dict(pairs)
    need(len(q) == len(pairs), "节点链接含重复参数")
    for key, value in pairs:
        text(key, 64); text(value, empty=True)
    if u.scheme in {"socks", "socks5"}:
        need(not q, "SOCKS 出站不支持链接附加参数")
        need(":" in credential, "SOCKS 链接必须提供用户名和密码")
        user, password = credential.split(":", 1)
        text(user, 255); text(password, 255)
        need(len(user.encode()) <= 255 and len(password.encode()) <= 255, "SOCKS 凭据超过 255 字节")
        return {"protocol": "socks", "settings": {"servers": [{"address": address, "port": port, "users": [{"user": user, "pass": password}]}]}}
    if u.scheme == "ss":
        need(not q, "Shadowsocks 出站暂不支持插件或附加参数")
        if ":" not in credential:
            credential = unbase(credential)
        need(":" in credential, "Shadowsocks 凭据格式无效")
        method, password = credential.split(":", 1)
        need(method in METHODS, "不支持此 Shadowsocks 加密方法")
        text(password, 2048)
        if method.startswith("2022-"):
            size = 16 if "aes-128" in method else 32
            keys = password.split(":")
            need(1 <= len(keys) <= 8, "SS2022 密钥链长度无效")
            need("chacha20" not in method or len(keys) == 1, "SS2022 ChaCha20 不支持多用户密钥链")
            for key in keys:
                raw = base64.b64decode(key, validate=True)
                need(len(raw) == size and base64.b64encode(raw).decode() == key, "SS2022 密钥长度或编码无效")
        return {"protocol": "shadowsocks", "settings": {"servers": [{"address": address, "port": port, "method": method, "password": password}]}}
    allowed = {"type", "security", "sni", "fp", "alpn", "path", "host"}
    if u.scheme == "vless":
        allowed |= {"encryption", "flow", "pbk", "sid", "spx", "mode", "headerType"}
    need(set(q) <= allowed, "节点链接含暂不支持的参数")
    network = q.get("type", "tcp")
    network = {"tcp": "raw", "websocket": "ws"}.get(network, network)
    need(network in {"raw", "xhttp", "ws"}, "不支持此出站传输")
    security = q.get("security", "tls" if u.scheme == "trojan" else "none")
    need(security in {"tls", "reality"}, "VLESS/Trojan 出站必须使用 TLS 或 REALITY")
    need(u.scheme == "vless" or (security == "tls" and network in {"raw", "ws"}), "不支持此 Trojan 传输组合")
    need(not (security == "reality" and network == "ws"), "REALITY 不支持 WS")
    if "headerType" in q:
        need(q["headerType"] == "none" and network == "raw", "不支持此 RAW 伪装")
    need(network != "raw" or not ({"path", "host", "mode"} & set(q)), "RAW 链接含不兼容的传输参数")
    need(network == "xhttp" or "mode" not in q, "mode 参数只适用于 XHTTP")
    stream = {"network": network, "security": security}
    sni = host(q.get("sni", address))
    need(":" not in sni, "SNI 必须为域名或 IPv4")
    fp = q.get("fp", "chrome" if security == "reality" else "")
    need(not fp or fp in FINGERPRINTS, "不支持此 TLS 指纹")
    if security == "reality":
        pbk = q.get("pbk", "")
        need(bool(re.fullmatch(r"[A-Za-z0-9_-]{43}", pbk)), "REALITY 公钥格式无效")
        raw = base64.urlsafe_b64decode(pbk + "=")
        need(len(raw) == 32 and any(raw) and base64.urlsafe_b64encode(raw).decode().rstrip("=") == pbk, "REALITY 公钥编码无效")
        sid = q.get("sid", "")
        need(bool(re.fullmatch(r"(?:[a-fA-F0-9]{2}){0,8}", sid)), "REALITY shortId 格式无效")
        spx = q.get("spx", "/")
        need(spx.startswith("/"), "REALITY spiderX 必须以 / 开头")
        need("alpn" not in q, "REALITY 链接不支持 alpn 参数")
        stream["realitySettings"] = {"serverName": sni, "fingerprint": fp, "password": pbk, "shortId": sid, "spiderX": spx}
    else:
        need(not ({"pbk", "sid", "spx"} & set(q)), "TLS 链接含 REALITY 参数")
        tls = {"serverName": sni, "minVersion": "1.2"}
        if fp:
            tls["fingerprint"] = fp
        if "alpn" in q:
            alpn = q["alpn"].split(",")
            need(1 <= len(alpn) <= 8 and all(re.fullmatch(r"[A-Za-z0-9./_-]{1,64}", p) for p in alpn) and len(set(alpn)) == len(alpn), "ALPN 格式无效")
            tls["alpn"] = alpn
        stream["tlsSettings"] = tls
    if network in {"xhttp", "ws"}:
        path = q.get("path", "/")
        need(path.startswith("/") and len(path) <= 2048, "传输路径格式无效")
        transport = {"path": path}
        if "host" in q:
            transport["host"] = host(q["host"])
        if network == "xhttp":
            mode = q.get("mode", "auto")
            need(mode in {"auto", "packet-up", "stream-up", "stream-one"}, "XHTTP mode 无效")
            transport["mode"] = mode
        stream["xhttpSettings" if network == "xhttp" else "wsSettings"] = transport
    if u.scheme == "vless":
        need(str(uuid.UUID(credential)) == credential.lower(), "VLESS UUID 格式无效")
        need(q.get("encryption", "none") == "none", "暂不支持 VLESS Encryption 链接")
        flow = q.get("flow", "")
        need(flow in {"", "xtls-rprx-vision", "xtls-rprx-vision-udp443"}, "VLESS flow 无效")
        need(not flow or network == "raw", "Vision flow 只支持 RAW 出站")
        user = {"id": credential, "encryption": "none"}
        if flow:
            user["flow"] = flow
        return {"protocol": "vless", "settings": {"vnext": [{"address": address, "port": port, "users": [user]}]}, "streamSettings": stream}
    text(credential, 256)
    return {"protocol": "trojan", "settings": {"servers": [{"address": address, "port": port, "password": credential}]}, "streamSettings": stream}

def validate_route(route):
    need(isinstance(route, dict) and set(route) == {"uri", "mode", "domains", "ips"}, "出站路由字段缺失或含未知字段")
    outbound = parse_uri(route["uri"])
    need(route["mode"] in {"all", "rules"}, "出站路由模式无效")
    domains, ips = route["domains"], route["ips"]
    need(isinstance(domains, list) and isinstance(ips, list) and len(domains) <= 128 and len(ips) <= 128, "出站规则必须为列表且各最多 128 条")
    normalized_domains, normalized_ips = [], []
    for domain in domains:
        text(domain, 260)
        prefix, sep, value = domain.partition(":")
        if not sep:
            prefix, value = "domain", domain
        need(prefix in {"domain", "full"}, "域名规则仅支持 domain/full 或裸域名")
        host(value)
        try:
            ipaddress.ip_address(value)
        except ValueError:
            pass
        else:
            raise ValueError("IP 地址请放入 IP 规则")
        normalized_domains.append(prefix + ":" + value.lower())
    for ip in ips:
        text(ip, 64)
        need("%" not in ip, "IP 规则不支持 scope ID")
        normalized_ips.append(str(ipaddress.ip_network(ip, strict=False)))
    need(len(set(normalized_domains)) == len(domains) and len(set(normalized_ips)) == len(ips), "出站规则重复")
    need((route["mode"] == "all" and not domains and not ips) or (route["mode"] == "rules" and (domains or ips)), "全部模式不能含规则，规则模式至少提供一条域名或 IP")
    return outbound, normalized_domains, normalized_ips

def validate_node(node):
    if "outbound_route" in node:
        need(node.get("type") in MAIN_TYPES, "此节点由辅助核心运行，暂不支持 Xray 出站路由")
        validate_route(node["outbound_route"])

def augment(state, config):
    for node in state["nodes"]:
        validate_node(node)
        if "outbound_route" not in node:
            continue
        route = node["outbound_route"]
        outbound, domains, ips = validate_route(route)
        tag = "outbound-" + node["id"]
        inbound = "node-" + node["id"]
        outbound["tag"] = tag
        config["outbounds"].append(outbound)
        rule = {"type": "field", "inboundTag": [inbound], "outboundTag": tag}
        if route["mode"] == "all":
            config["routing"]["rules"].append(rule)
        else:
            if domains:
                config["routing"]["rules"].append(dict(rule, domain=domains))
            if ips:
                config["routing"]["rules"].append(dict(rule, ip=ips))
    return config

def main():
    command = sys.argv[1]
    if command == "route":
        fields = sys.stdin.buffer.read(32769)
        need(len(fields) <= 32768, "出站输入过大")
        fields = fields.decode().split("\0")
        need(len(fields) == 5 and fields[-1] == "", "出站输入结构无效")
        route = {"uri": fields[0], "mode": fields[1], "domains": json.loads(fields[2]), "ips": json.loads(fields[3])}
        validate_route(route)
        result = route
    elif command == "validate-node":
        validate_node(json.load(sys.stdin)); return
    elif command == "summary":
        outbound, _, _ = validate_route(json.load(sys.stdin))
        settings = outbound["settings"]
        server = settings.get("servers", settings.get("vnext"))[0]
        result = {"protocol": outbound["protocol"], "address": server["address"], "port": server["port"]}
    elif command == "augment":
        state, config = [json.loads(line) for line in sys.stdin]
        result = augment(state, config)
    else:
        raise ValueError("未知出站命令")
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))

if __name__ == "__main__":
    try:
        main()
    except (ValueError, TypeError, KeyError, OSError, UnicodeError, binascii.Error, IndexError):
        # Never echo URI, credentials, raw parser exceptions or JSON content.
        print("[错误] 出站路由：节点链接或规则无效、含不支持的参数；请检查支持范围。", file=sys.stderr)
        sys.exit(1)
