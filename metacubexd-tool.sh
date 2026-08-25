#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# MetaCubeXD Server + Mihomo
# Debian / Ubuntu LXC bare-metal installer/updater
#
# Runtime Release:
#   https://github.com/w101723/metacubexd-build/releases/tag/latest
#
# Commands:
#   ./metacubexd-lxc-release.sh install
#   ./metacubexd-lxc-release.sh update
#   ./metacubexd-lxc-release.sh rollback
#   ./metacubexd-lxc-release.sh status
#   ./metacubexd-lxc-release.sh check
#
# Optional:
#   CONTROL_PORT=3000
#   CLASH_API_PORT=9090
#   MIXED_PORT=7890
#   DEFAULT_BACKEND_URL=http://192.168.101.152:9090
#   KEEP_RELEASES=3
#   MIHOMO_VERSION=latest
#   RELEASE_TAG=latest
#
# IMPORTANT:
#   This script downloads PUBLIC GitHub Release assets directly.
#   No GitHub PAT / Actions permission is required.
# ============================================================

APP="metacubexd"

BUILD_REPO="${BUILD_REPO:-w101723/metacubexd-build}"
RELEASE_TAG="${RELEASE_TAG:-latest}"
RUNTIME_ASSET="${RUNTIME_ASSET:-metacubexd-runtime.tar.gz}"
RUNTIME_SHA_ASSET="${RUNTIME_SHA_ASSET:-metacubexd-runtime.tar.gz.sha256}"

MIHOMO_REPO="${MIHOMO_REPO:-MetaCubeX/mihomo}"
MIHOMO_VERSION="${MIHOMO_VERSION:-latest}"

BASE_DIR="/opt/metacubexd"
RELEASES_DIR="${BASE_DIR}/releases"
CURRENT_LINK="${BASE_DIR}/current"
DATA_DIR="/var/lib/metacubexd"

ENV_FILE="/etc/metacubexd.env"
SERVICE_FILE="/etc/systemd/system/metacubexd.service"
SYSCTL_FILE="/etc/sysctl.d/99-mihomo-router.conf"
MIHOMO_BIN="/usr/local/bin/mihomo"

CONTROL_PORT="${CONTROL_PORT:-3000}"
CLASH_API_PORT="${CLASH_API_PORT:-9090}"
MIXED_PORT="${MIXED_PORT:-7890}"
KEEP_RELEASES="${KEEP_RELEASES:-3}"
TZ_VALUE="${TZ_VALUE:-Asia/Shanghai}"
DEFAULT_BACKEND_URL="${DEFAULT_BACKEND_URL:-}"

TMP_DIR=""
OLD_CURRENT=""
DOWNLOADED_RUNTIME_TAR=""
RUNTIME_VERSION=""
NODE_CA_OPTIONS=""

C_RESET='\033[0m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_BLUE='\033[34m'

log()  { printf "${C_BLUE}==>${C_RESET} %s\n" "$*" >&2; }
ok()   { printf "${C_GREEN}OK:${C_RESET} %s\n" "$*"; }
warn() { printf "${C_YELLOW}WARN:${C_RESET} %s\n" "$*" >&2; }
die()  { printf "${C_RED}ERROR:${C_RESET} %s\n" "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "请使用 root 运行。"
}

detect_os() {
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "当前仅支持 Debian/Ubuntu，检测到: ${ID:-unknown}" ;;
  esac
}

install_dependencies() {
  log "安装基础依赖"

  export DEBIAN_FRONTEND=noninteractive

  apt-get update

  apt-get install -y \
    ca-certificates \
    curl \
    jq \
    tar \
    gzip \
    openssl \
    iproute2 \
    iptables \
    nftables \
    procps \
    tzdata \
    gnupg

  update-ca-certificates >/dev/null 2>&1 || true
}

install_node22() {
  local need_install=1

  if command -v node >/dev/null 2>&1; then
    local major
    major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"

    if [[ "${major}" == "22" ]]; then
      need_install=0
    fi
  fi

  if [[ "${need_install}" -eq 1 ]]; then
    log "安装 Node.js 22"

    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
  fi

  command -v node >/dev/null || die "Node.js 安装失败"

  if node --use-system-ca -e 'process.exit(0)' >/dev/null 2>&1; then
    NODE_CA_OPTIONS="--use-system-ca"
  else
    NODE_CA_OPTIONS="--use-openssl-ca"
  fi

  ok "Node.js $(node -v)"
  ok "Node CA: ${NODE_CA_OPTIONS}"
}

github_api() {
  local url="$1"

  curl -fsSL \
    --retry 3 \
    --retry-delay 2 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "${url}"
}

install_mihomo() {
  log "检查 Mihomo"

  local release_json
  local tag
  local asset_name
  local download_url
  local installed_version=""

  if [[ "${MIHOMO_VERSION}" == "latest" ]]; then
    release_json="$(github_api "https://api.github.com/repos/${MIHOMO_REPO}/releases/latest")"
    tag="$(jq -r '.tag_name' <<<"${release_json}")"
  else
    tag="${MIHOMO_VERSION}"
    release_json="$(github_api "https://api.github.com/repos/${MIHOMO_REPO}/releases/tags/${tag}")"
  fi

  [[ -n "${tag}" && "${tag}" != "null" ]] || die "无法获取 Mihomo 版本"

  case "$(uname -m)" in
    x86_64|amd64)
      asset_name="mihomo-linux-amd64-compatible-${tag}.gz"
      ;;
    aarch64|arm64)
      asset_name="mihomo-linux-arm64-${tag}.gz"
      ;;
    *)
      die "不支持 CPU 架构: $(uname -m)"
      ;;
  esac

  if [[ -x "${MIHOMO_BIN}" ]]; then
    installed_version="$("${MIHOMO_BIN}" -v 2>/dev/null | head -n1 || true)"

    if grep -Fq "${tag#v}" <<<"${installed_version}"; then
      ok "Mihomo 已是 ${tag}"
      return 0
    fi
  fi

  download_url="$(
    jq -r --arg name "${asset_name}" \
      '.assets[] | select(.name == $name) | .browser_download_url' \
      <<<"${release_json}" | head -n1
  )"

  [[ -n "${download_url}" ]] \
    || die "未找到 Mihomo 文件: ${asset_name}"

  local tmp_gz
  tmp_gz="$(mktemp)"

  log "下载 Mihomo ${tag}"

  curl -fL \
    --retry 3 \
    --retry-delay 2 \
    "${download_url}" \
    -o "${tmp_gz}"

  gzip -dc "${tmp_gz}" >"${MIHOMO_BIN}.new"
  rm -f "${tmp_gz}"

  chmod 755 "${MIHOMO_BIN}.new"

  "${MIHOMO_BIN}.new" -v >/dev/null \
    || die "Mihomo 二进制验证失败"

  mv -f "${MIHOMO_BIN}.new" "${MIHOMO_BIN}"

  ok "Mihomo ${tag} 已安装"
}

detect_lan_ip() {
  local ip=""

  ip="$(
    ip -4 route get 1.1.1.1 2>/dev/null |
      awk '{
        for(i=1;i<=NF;i++) {
          if($i=="src") {
            print $(i+1)
            exit
          }
        }
      }' || true
  )"

  if [[ -z "${ip}" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi

  printf '%s' "${ip}"
}

env_get() {
  local key="$1"

  [[ -f "${ENV_FILE}" ]] || return 1

  grep -m1 -E "^${key}=" "${ENV_FILE}" |
    cut -d= -f2- || true
}

env_set() {
  local key="$1"
  local value="$2"
  local escaped="${value//|/\\|}"

  touch "${ENV_FILE}"

  if grep -q -E "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "${ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" >>"${ENV_FILE}"
  fi
}

ensure_env_file() {
  log "配置 ${ENV_FILE}"

  local lan_ip
  local backend
  local control_token
  local clash_secret

  lan_ip="$(detect_lan_ip)"

  backend="${DEFAULT_BACKEND_URL}"

  if [[ -z "${backend}" ]]; then
    backend="$(env_get DEFAULT_BACKEND_URL || true)"
  fi

  if [[ -z "${backend}" ]]; then
    [[ -n "${lan_ip}" ]] || lan_ip="127.0.0.1"
    backend="http://${lan_ip}:${CLASH_API_PORT}"
  fi

  if [[ ! -f "${ENV_FILE}" ]]; then
    umask 077
    touch "${ENV_FILE}"
  fi

  control_token="$(env_get CONTROL_TOKEN || true)"
  clash_secret="$(env_get CLASH_SECRET || true)"

  [[ -n "${control_token}" ]] \
    || control_token="$(openssl rand -hex 32)"

  [[ -n "${clash_secret}" ]] \
    || clash_secret="$(openssl rand -hex 32)"

  # 升级时保留已有端口
  local old_port
  local old_control
  local old_api
  local old_mixed

  old_port="$(env_get PORT || true)"
  old_control="$(env_get CONTROL_PORT || true)"
  old_api="$(env_get CLASH_API_PORT || true)"
  old_mixed="$(env_get MIXED_PORT || true)"

  [[ -n "${old_control}" ]] && CONTROL_PORT="${old_control}"
  [[ -n "${old_api}" ]] && CLASH_API_PORT="${old_api}"
  [[ -n "${old_mixed}" ]] && MIXED_PORT="${old_mixed}"

  [[ -n "${old_port}" ]] || old_port="${CONTROL_PORT}"

  env_set NODE_ENV "production"

  env_set PORT "${old_port}"
  env_set CONTROL_PORT "${CONTROL_PORT}"

  env_set UI_DIST "${CURRENT_LINK}/ui-dist"

  env_set MIHOMO_BIN "${MIHOMO_BIN}"
  env_set DATA_DIR "${DATA_DIR}"

  env_set CLASH_API_PORT "${CLASH_API_PORT}"
  env_set MIXED_PORT "${MIXED_PORT}"

  env_set DEFAULT_BACKEND_URL "${backend}"

  env_set CONTROL_TOKEN "${control_token}"
  env_set CLASH_SECRET "${clash_secret}"

  # 解决 Node fetch 本地 CA/中间证书信任问题
  env_set NODE_OPTIONS "${NODE_CA_OPTIONS}"
  env_set SSL_CERT_FILE "/etc/ssl/certs/ca-certificates.crt"

  env_set TZ "${TZ_VALUE}"

  chmod 600 "${ENV_FILE}"

  ok "默认 Backend: ${backend}"
}

configure_gateway_sysctl() {
  log "配置 LXC 网关参数"

  cat >"${SYSCTL_FILE}" <<'EOF'
# MetaCubeXD / Mihomo LXC gateway

net.ipv4.ip_forward=1

# TUN / policy routing
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0

# Single-arm gateway:
# avoid client bypass caused by ICMP Redirect
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0

net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
EOF

  sysctl --system >/dev/null 2>&1 \
    || warn "部分 sysctl 设置失败，请检查 LXC 权限"

  local iface
  iface="$(
    ip route show default 2>/dev/null |
      awk '/default/ {print $5; exit}' || true
  )"

  if [[ -n "${iface}" ]]; then
    sysctl -w "net.ipv4.conf.${iface}.rp_filter=0" \
      >/dev/null 2>&1 || true

    sysctl -w "net.ipv4.conf.${iface}.send_redirects=0" \
      >/dev/null 2>&1 || true
  fi

  if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" == "1" ]]; then
    ok "IPv4 forwarding 已开启"
  else
    warn "net.ipv4.ip_forward != 1，LXC 不能正常作为网关"
  fi
}

check_lxc_capabilities() {
  log "检查 TUN / nftables"

  if [[ -c /dev/net/tun ]]; then
    ok "/dev/net/tun 正常"
  else
    warn "/dev/net/tun 不存在"
    warn "在 PVE 宿主机执行："
    warn "  pct stop <CTID>"
    warn "  pct set <CTID> -dev0 path=/dev/net/tun,mode=0666"
    warn "  pct start <CTID>"
  fi

  local test_table="metacubexd_test_$$"

  if nft add table inet "${test_table}" >/dev/null 2>&1; then
    nft delete table inet "${test_table}" >/dev/null 2>&1 || true
    ok "nftables 写权限正常"
  else
    warn "nftables 无写权限，Mihomo auto-redirect 可能无法工作"
  fi
}

download_runtime() {
  TMP_DIR="$(mktemp -d)"

  local runtime_tar="${TMP_DIR}/${RUNTIME_ASSET}"
  local runtime_sha="${TMP_DIR}/${RUNTIME_SHA_ASSET}"

  local base_url
  base_url="https://github.com/${BUILD_REPO}/releases/download/${RELEASE_TAG}"

  echo
  log "下载 MetaCubeXD Runtime"
  log "Release: https://github.com/${BUILD_REPO}/releases/tag/${RELEASE_TAG}"

  curl -fL \
    --retry 3 \
    --retry-delay 2 \
    "${base_url}/${RUNTIME_ASSET}" \
    -o "${runtime_tar}" \
    || die "下载失败: ${base_url}/${RUNTIME_ASSET}"

  curl -fL \
    --retry 3 \
    --retry-delay 2 \
    "${base_url}/${RUNTIME_SHA_ASSET}" \
    -o "${runtime_sha}" \
    || die "下载失败: ${base_url}/${RUNTIME_SHA_ASSET}"

  log "校验 SHA256"

  (
    cd "${TMP_DIR}"
    sha256sum -c "${RUNTIME_SHA_ASSET}"
  ) || die "Runtime SHA256 校验失败"

  local digest
  digest="$(sha256sum "${runtime_tar}" | awk '{print $1}')"

  # latest tag 会不断覆盖同名资产，所以不能用 "latest" 作为本地版本。
  # 用文件内容 SHA 作为真正版本 ID。
  RUNTIME_VERSION="release-${digest:0:12}"
  DOWNLOADED_RUNTIME_TAR="${runtime_tar}"

  ok "Runtime: ${RUNTIME_VERSION}"
}

install_runtime_release() {
  local runtime_tar="$1"
  local target="${RELEASES_DIR}/${RUNTIME_VERSION}"
  local staging="${RELEASES_DIR}/.${RUNTIME_VERSION}.staging"

  mkdir -p "${RELEASES_DIR}"

  OLD_CURRENT="$(readlink -f "${CURRENT_LINK}" 2>/dev/null || true)"

  if [[ -d "${target}" ]]; then
    ok "${RUNTIME_VERSION} 已安装"
  else
    rm -rf "${staging}"
    mkdir -p "${staging}"

    log "解压 Runtime -> ${target}"

    tar xzf "${runtime_tar}" -C "${staging}"

    [[ -f "${staging}/ui-dist/index.html" ]] \
      || die "Runtime 缺少 ui-dist/index.html"

    [[ -f "${staging}/server/server/index.mjs" ]] \
      || die "Runtime 缺少 server/server/index.mjs"

    mv "${staging}" "${target}"
  fi

  ln -sfnT "${target}" "${CURRENT_LINK}"

  ok "current -> ${target}"
}

write_systemd_service() {
  log "安装 systemd 服务"

  local node_bin
  node_bin="$(command -v node)"

  cat >"${SERVICE_FILE}" <<EOF
[Unit]
Description=MetaCubeXD Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

EnvironmentFile=${ENV_FILE}

WorkingDirectory=${CURRENT_LINK}/server

ExecStartPre=/usr/bin/mkdir -p ${DATA_DIR}/profiles

ExecStart=${node_bin} ${CURRENT_LINK}/server/server/index.mjs

Restart=always
RestartSec=3

KillMode=control-group
TimeoutStopSec=15

LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${APP}.service" >/dev/null
}

service_healthcheck() {
  local port
  port="$(env_get CONTROL_PORT || true)"

  [[ -n "${port}" ]] || port="${CONTROL_PORT}"

  local i

  for i in $(seq 1 20); do
    if systemctl is-active --quiet "${APP}.service" &&
       curl -fsS \
         --max-time 2 \
         "http://127.0.0.1:${port}/" \
         >/dev/null 2>&1; then
      return 0
    fi

    sleep 1
  done

  return 1
}

restart_with_rollback() {
  log "启动 MetaCubeXD"

  systemctl restart "${APP}.service"

  if service_healthcheck; then
    ok "MetaCubeXD 启动成功"
    return 0
  fi

  warn "新版本健康检查失败"

  journalctl \
    -u "${APP}.service" \
    -n 80 \
    --no-pager || true

  if [[ -n "${OLD_CURRENT}" && -d "${OLD_CURRENT}" ]]; then
    warn "自动回滚到 ${OLD_CURRENT}"

    ln -sfnT "${OLD_CURRENT}" "${CURRENT_LINK}"

    systemctl restart "${APP}.service" || true

    if service_healthcheck; then
      ok "自动回滚成功"
      return 1
    fi
  fi

  die "MetaCubeXD 启动失败，无法自动恢复"
}

cleanup_old_releases() {
  [[ "${KEEP_RELEASES}" =~ ^[0-9]+$ ]] \
    || KEEP_RELEASES=3

  (( KEEP_RELEASES >= 2 )) \
    || KEEP_RELEASES=2

  local current
  current="$(readlink -f "${CURRENT_LINK}" 2>/dev/null || true)"

  mapfile -t releases < <(
    find "${RELEASES_DIR}" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d \
      ! -name '.*.staging' \
      -printf '%T@ %p\n' 2>/dev/null |
      sort -nr |
      cut -d' ' -f2-
  )

  local idx
  local path

  for idx in "${!releases[@]}"; do
    if (( idx >= KEEP_RELEASES )); then
      path="${releases[$idx]}"

      if [[ "$(readlink -f "${path}")" != "${current}" ]]; then
        log "清理旧 Runtime: ${path}"
        rm -rf "${path}"
      fi
    fi
  done
}

show_summary() {
  local lan_ip
  local backend
  local control
  local api
  local mixed

  lan_ip="$(detect_lan_ip)"

  backend="$(env_get DEFAULT_BACKEND_URL || true)"
  control="$(env_get CONTROL_PORT || true)"
  api="$(env_get CLASH_API_PORT || true)"
  mixed="$(env_get MIXED_PORT || true)"

  echo
  echo "============================================================"
  echo " MetaCubeXD LXC"
  echo "============================================================"
  echo " Web UI       : http://${lan_ip:-127.0.0.1}:${control}"
  echo " Mihomo API   : http://${lan_ip:-127.0.0.1}:${api}"
  echo " Mixed Proxy  : ${lan_ip:-127.0.0.1}:${mixed}"
  echo " Default API  : ${backend}"
  echo " Runtime      : $(readlink -f "${CURRENT_LINK}" 2>/dev/null || true)"
  echo " Data         : ${DATA_DIR}"
  echo " Env          : ${ENV_FILE}"
  echo " Release      : https://github.com/${BUILD_REPO}/releases/tag/${RELEASE_TAG}"
  echo
  echo " Commands:"
  echo "   systemctl status metacubexd"
  echo "   journalctl -u metacubexd -f"
  echo "   $0 update"
  echo "   $0 rollback"
  echo "============================================================"
}

do_install_or_update() {
  local action="$1"

  require_root
  detect_os

  install_dependencies
  install_node22
  install_mihomo

  mkdir -p \
    "${BASE_DIR}" \
    "${RELEASES_DIR}" \
    "${DATA_DIR}/profiles"

  download_runtime

  install_runtime_release "${DOWNLOADED_RUNTIME_TAR}"

  ensure_env_file
  configure_gateway_sysctl
  check_lxc_capabilities
  write_systemd_service

  if ! restart_with_rollback; then
    exit 1
  fi

  cleanup_old_releases
  show_summary

  ok "${action}完成"
}

do_status() {
  require_root

  echo "=== Service ==="

  systemctl status \
    "${APP}.service" \
    --no-pager \
    -l || true

  echo
  echo "=== Runtime ==="

  readlink -f "${CURRENT_LINK}" 2>/dev/null || true

  if [[ -f "${CURRENT_LINK}/BUILD_INFO" ]]; then
    cat "${CURRENT_LINK}/BUILD_INFO"
  fi

  echo
  echo "=== Node ==="

  node -v 2>/dev/null || true

  echo
  echo "=== Mihomo ==="

  "${MIHOMO_BIN}" -v 2>/dev/null || true

  echo
  echo "=== Network ==="

  ip -br addr
  echo
  ip route
  echo

  sysctl net.ipv4.ip_forward 2>/dev/null || true

  echo
  echo "=== TUN ==="

  ls -l /dev/net/tun 2>/dev/null || true
}

do_check() {
  require_root

  local failed=0

  if [[ -x "${MIHOMO_BIN}" ]]; then
    ok "Mihomo"
  else
    warn "Mihomo 不存在"
    failed=1
  fi

  if command -v node >/dev/null 2>&1; then
    ok "Node.js $(node -v)"
  else
    warn "Node.js 不存在"
    failed=1
  fi

  if [[ -f "${CURRENT_LINK}/ui-dist/index.html" ]]; then
    ok "UI Runtime"
  else
    warn "UI Runtime 不存在"
    failed=1
  fi

  if [[ -f "${CURRENT_LINK}/server/server/index.mjs" ]]; then
    ok "Server Runtime"
  else
    warn "Server Runtime 不存在"
    failed=1
  fi

  if [[ -c /dev/net/tun ]]; then
    ok "/dev/net/tun"
  else
    warn "/dev/net/tun 不存在"
  fi

  if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" == "1" ]]; then
    ok "IPv4 forwarding"
  else
    warn "IPv4 forwarding 未开启"
  fi

  if systemctl is-active --quiet "${APP}.service"; then
    ok "metacubexd.service"
  else
    warn "metacubexd.service 未运行"
    failed=1
  fi

  if service_healthcheck; then
    ok "Web healthcheck"
  else
    warn "Web healthcheck 失败"
    failed=1
  fi

  return "${failed}"
}

do_rollback() {
  require_root

  [[ -L "${CURRENT_LINK}" ]] \
    || die "current 软链接不存在"

  local current
  current="$(readlink -f "${CURRENT_LINK}")"

  mapfile -t candidates < <(
    find "${RELEASES_DIR}" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d \
      -printf '%T@ %p\n' |
      sort -nr |
      cut -d' ' -f2-
  )

  local previous=""

  for path in "${candidates[@]}"; do
    if [[ "$(readlink -f "${path}")" != "${current}" ]]; then
      previous="${path}"
      break
    fi
  done

  [[ -n "${previous}" ]] \
    || die "没有可回滚的旧版本"

  log "回滚"
  log "${current}"
  log " -> ${previous}"

  ln -sfnT "${previous}" "${CURRENT_LINK}"

  systemctl restart "${APP}.service"

  if service_healthcheck; then
    ok "回滚成功"
    show_summary
    return 0
  fi

  warn "回滚版本启动失败，恢复原版本"

  ln -sfnT "${current}" "${CURRENT_LINK}"
  systemctl restart "${APP}.service" || true

  die "回滚失败"
}

usage() {
  cat <<EOF
MetaCubeXD LXC Installer

Usage:
  $0 install
  $0 update
  $0 rollback
  $0 status
  $0 check

Public Release:
  https://github.com/${BUILD_REPO}/releases/tag/${RELEASE_TAG}

Download:
  https://github.com/${BUILD_REPO}/releases/download/${RELEASE_TAG}/${RUNTIME_ASSET}
  https://github.com/${BUILD_REPO}/releases/download/${RELEASE_TAG}/${RUNTIME_SHA_ASSET}

No GitHub PAT is required.

Examples:
  $0 install
  $0 update
  CONTROL_PORT=8080 $0 install
  MIHOMO_VERSION=v1.19.30 $0 update
EOF
}

main() {
  local cmd="${1:-install}"

  case "${cmd}" in
    install)
      do_install_or_update "安装"
      ;;

    update|upgrade)
      do_install_or_update "升级"
      ;;

    rollback)
      do_rollback
      ;;

    status)
      do_status
      ;;

    check)
      do_check
      ;;

    -h|--help|help)
      usage
      ;;

    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
