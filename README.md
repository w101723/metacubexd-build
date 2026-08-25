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

## Release 下载

最新 Runtime：

- [metacubexd-runtime.tar.gz](https://github.com/w101723/metacubexd-build/releases/download/latest/metacubexd-runtime.tar.gz)
- [SHA-256 校验文件](https://github.com/w101723/metacubexd-build/releases/download/latest/metacubexd-runtime.tar.gz.sha256)
