# MetaCubeXD Build

自动构建并发布 MetaCubeXD Runtime，同时提供 Debian/Ubuntu LXC 一键安装工具和 Mihomo 嗅探配置示例。

## 文件说明

- `.github/workflows/build-metacubexd.yml`：构建 UI 与 Server，并将 Runtime 发布到 [`latest` Release](https://github.com/w101723/metacubexd-build/releases/tag/latest)。
- `metacubexd-tool.sh`：安装、更新、回滚和检查 MetaCubeXD Server + Mihomo。
- `sniffer.yaml`：Mihomo HTTP、TLS、QUIC 流量嗅探配置片段。

## 一键安装

适用于 Debian/Ubuntu LXC，需要使用 `root` 运行：

```bash
curl -fLo metacubexd-tool.sh \
  https://raw.githubusercontent.com/w101723/metacubexd-build/main/metacubexd-tool.sh

chmod +x metacubexd-tool.sh
sudo ./metacubexd-tool.sh install
```

脚本会自动安装 Node.js 22、Mihomo 和 MetaCubeXD Runtime，并创建 `metacubexd.service` systemd 服务。

## 常用命令

```bash
# 安装
sudo ./metacubexd-tool.sh install

# 更新到最新 Runtime
sudo ./metacubexd-tool.sh update

# 回滚到上一个版本
sudo ./metacubexd-tool.sh rollback

# 查看运行状态
sudo ./metacubexd-tool.sh status

# 检查运行环境
sudo ./metacubexd-tool.sh check
```

可通过环境变量自定义端口和后端地址：

```bash
CONTROL_PORT=3000 \
CLASH_API_PORT=9090 \
MIXED_PORT=7890 \
DEFAULT_BACKEND_URL=http://192.168.1.2:9090 \
sudo -E ./metacubexd-tool.sh install
```

默认配置文件位于 `/etc/metacubexd.env`，数据目录位于 `/var/lib/metacubexd`。

## 嗅探配置

`sniffer.yaml` 可作为 Mihomo 配置片段使用：

```yaml
sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  override-destination: true
```

将文件中的 `sniffer` 配置合并到现有 Mihomo 配置后，重启 Mihomo 使其生效。

## 旁路网关转发设置

LXC 作为局域网旁路网关时，需要开启 Linux 转发并关闭可能干扰策略路由的相关参数。

创建 sysctl 配置：

```bash
cat >/etc/sysctl.d/99-mihomo-router.conf <<'EOF'
net.ipv4.ip_forward=1

net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.all.src_valid_mark=1

net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0

net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
EOF
```

应用配置：

```bash
sysctl --system
```

确认 IPv4 转发已经开启：

```bash
sysctl net.ipv4.ip_forward
```

应返回：

```text
net.ipv4.ip_forward = 1
```

安装脚本会自动配置上述大部分网关参数，并检查 `/dev/net/tun` 和 nftables 权限。

### 放行 FORWARD 流量

如果系统的 `FORWARD` 默认策略为 `DROP`，还需要放行转发流量：

```bash
iptables -S FORWARD
```

假设 LXC 出口网卡为 `eth0`：

```bash
iptables -I FORWARD 1 -i eth0 -j ACCEPT

iptables -I FORWARD 1 \
  -o eth0 \
  -m conntrack \
  --ctstate ESTABLISHED,RELATED \
  -j ACCEPT
```

如果需要永久生效，建议使用 systemd 执行幂等的转发规则脚本：

```bash
cat >/usr/local/sbin/mihomo-gateway-forward <<'EOF'
#!/bin/bash
set -e

IFACE=$(ip route show default | awk '/default/ {print $5; exit}')

iptables -C FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null || \
iptables -I FORWARD 1 -i "$IFACE" -j ACCEPT

iptables -C FORWARD \
  -o "$IFACE" \
  -m conntrack \
  --ctstate ESTABLISHED,RELATED \
  -j ACCEPT 2>/dev/null || \
iptables -I FORWARD 1 \
  -o "$IFACE" \
  -m conntrack \
  --ctstate ESTABLISHED,RELATED \
  -j ACCEPT
EOF

chmod +x /usr/local/sbin/mihomo-gateway-forward
```

创建 systemd 服务：

```bash
cat >/etc/systemd/system/mihomo-gateway-forward.service <<'EOF'
[Unit]
Description=Mihomo Gateway Forwarding
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/mihomo-gateway-forward

[Install]
WantedBy=multi-user.target
EOF
```

启用服务：

```bash
systemctl daemon-reload
systemctl enable --now mihomo-gateway-forward
```

### 开启 Mihomo TUN

Mihomo 还需要开启 TUN，并使用 `mixed` 网络栈：

```yaml
mixed-port: 7890
allow-lan: true
bind-address: "*"

tun:
  enable: true
  stack: mixed
  auto-route: true
  auto-redirect: true
  auto-detect-interface: true

  dns-hijack:
    - any:53
    - tcp://any:53
```

> `mixed-port` 是供客户端显式使用的 HTTP/SOCKS 代理端口；`tun.stack: mixed` 是旁路网关透明转发所使用的 TUN 网络栈，两者不是同一个配置。

### LXC TUN 权限

使用旁路网关前，需要确认 LXC 已挂载 `/dev/net/tun`，并具有 TUN、nftables 和路由管理权限。PVE LXC 如果没有 `/dev/net/tun`，可在 PVE 宿主机执行：

```bash
pct stop <CTID>
pct set <CTID> -dev0 path=/dev/net/tun,mode=0666
pct start <CTID>
```

### 客户端设置

客户端将默认网关设置为 LXC 的局域网 IP。客户端 DNS 也应指向旁路网关，或由 Mihomo 的 `dns-hijack` 接管：

```text
客户端
  ↓
默认网关 = LXC
  ↓
Linux FORWARD
  ↓
Mihomo TUN
  ↓
DIRECT / PROXY
  ↓
Internet
```

同时应确保路由规则排除旁路网关自身和局域网保留地址，避免流量循环。

## Release 下载

最新 Runtime：

- [metacubexd-runtime.tar.gz](https://github.com/w101723/metacubexd-build/releases/download/latest/metacubexd-runtime.tar.gz)
- [SHA-256 校验文件](https://github.com/w101723/metacubexd-build/releases/download/latest/metacubexd-runtime.tar.gz.sha256)
