#!/usr/bin/env bash
# serverfixed Linux 初始化脚本
# 功能：自动识别 Debian/Ubuntu/PVE，测试中国境内 apt mirror，更新系统，启用 SSH，新建管理员用户并配置 sudo/SSH。
# 设计原则：先备份、再修改；尽量不破坏第三方源；所有可选步骤失败时给出清晰提示。

set -Eeuo pipefail

INIT_USER="${INIT_USER:-likangguo}"
RUN_UPGRADE="${RUN_UPGRADE:-1}"
MIRROR_FORCE="${MIRROR_FORCE:-}"
MIRROR_TIMEOUT="${MIRROR_TIMEOUT:-3}"
MIRROR_REPEAT="${MIRROR_REPEAT:-2}"
SSH_PASSWORD_AUTH="${SSH_PASSWORD_AUTH:-yes}"
SSH_ROOT_LOGIN="${SSH_ROOT_LOGIN:-prohibit-password}"
PVE_FIX_REPOS="${PVE_FIX_REPOS:-1}"
FORCE_IPV4_APT="${FORCE_IPV4_APT:-1}"
LOG_FILE="${LOG_FILE:-/var/log/serverfixed-init.log}"

TS="$(date +%Y%m%d-%H%M%S)"
OS_ID="unknown"
OS_LIKE=""
OS_NAME="unknown"
OS_VERSION="unknown"
OS_CODENAME=""
APT_FAMILY=""
SELECTED_MIRROR_NAME=""
SELECTED_MIRROR_URL=""
SELECTED_SECURITY_URL=""
APT_BACKUP_DIR=""
APT_DISABLED_DIR=""

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*" >&2; }
fatal() { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  warn "脚本在第 ${BASH_LINENO[0]} 行附近失败，退出码：${exit_code}。请查看日志：${LOG_FILE}"
  exit "$exit_code"
}
trap on_error ERR

usage() {
  cat <<'USAGE'
用法：
  sudo bash linux_init_cn.sh

常用环境变量：
  INIT_USER=likangguo              要创建/配置的管理员用户名
  RUN_UPGRADE=1                   apt update 后是否执行 apt upgrade；设为 0 可跳过
  MIRROR_FORCE=URL                跳过测速，强制使用指定 apt mirror，例如 https://mirrors.ustc.edu.cn/ubuntu
  SSH_PASSWORD_AUTH=yes           是否允许 SSH 密码登录，首次初始化建议 yes，稳定后可改 no
  SSH_ROOT_LOGIN=prohibit-password  root SSH 登录策略：no / prohibit-password / yes
  PVE_FIX_REPOS=1                 Proxmox VE 上自动禁用 enterprise 源并添加 no-subscription 源
  FORCE_IPV4_APT=1                为 apt 写入 IPv4 优先和超时配置，避免 IPv6 路由异常卡住

示例：
  sudo bash linux_init_cn.sh
  INIT_USER=likangguo RUN_UPGRADE=0 sudo bash linux_init_cn.sh
  MIRROR_FORCE=https://mirrors.ustc.edu.cn/ubuntu RUN_UPGRADE=0 sudo bash linux_init_cn.sh
USAGE
}

require_root() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi
  [[ "$(id -u)" -eq 0 ]] || fatal "请使用 root 或 sudo 运行。"
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE" || fatal "无法写入日志文件：${LOG_FILE}"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

validate_user() {
  [[ "$INIT_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || fatal "用户名不合法：${INIT_USER}"
}

load_os_info() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
    OS_NAME="${PRETTY_NAME:-${NAME:-unknown}}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-}"
  fi

  if [[ -z "$OS_CODENAME" ]] && command -v lsb_release >/dev/null 2>&1; then
    OS_CODENAME="$(lsb_release -sc 2>/dev/null || true)"
  fi

  if [[ -z "$OS_CODENAME" ]] && [[ -r /etc/debian_version ]]; then
    case "$(cut -d. -f1 /etc/debian_version 2>/dev/null || true)" in
      13) OS_CODENAME="trixie" ;;
      12) OS_CODENAME="bookworm" ;;
      11) OS_CODENAME="bullseye" ;;
      10) OS_CODENAME="buster" ;;
      9)  OS_CODENAME="stretch" ;;
    esac
  fi

  if [[ "$OS_ID" =~ ^(ubuntu|pop|linuxmint)$ || "$OS_LIKE" == *ubuntu* ]]; then
    APT_FAMILY="ubuntu"
  elif [[ "$OS_ID" =~ ^(debian|raspbian|kali)$ || "$OS_LIKE" == *debian* || -d /etc/pve ]]; then
    APT_FAMILY="debian"
  elif command -v apt-get >/dev/null 2>&1; then
    APT_FAMILY="debian"
  fi

  log "识别系统：${OS_NAME}，ID=${OS_ID}，VERSION=${OS_VERSION}，CODENAME=${OS_CODENAME:-unknown}，APT_FAMILY=${APT_FAMILY:-none}"

  if [[ "$OS_ID" == "ubuntu" && "$OS_CODENAME" == "plucky" ]]; then
    warn "检测到 Ubuntu 25.04/plucky。该版本是短周期版本，若 apt 仓库不可用，建议升级到受支持版本或改用 old-releases 源。"
  fi
}

probe_url() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -LfsS -o /dev/null \
      --connect-timeout "$MIRROR_TIMEOUT" \
      --max-time "$((MIRROR_TIMEOUT + 5))" \
      -w '%{time_total}' "$url" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    local start end elapsed
    start="$(date +%s%3N)"
    timeout "$((MIRROR_TIMEOUT + 5))" wget -q --spider "$url" >/dev/null 2>&1 || return 1
    end="$(date +%s%3N)"
    elapsed=$((end - start))
    awk -v e="$elapsed" 'BEGIN { printf "%.3f", e/1000 }'
  else
    return 1
  fi
}

choose_fastest_mirror() {
  [[ -n "$APT_FAMILY" ]] || return 0
  [[ -n "$OS_CODENAME" ]] || fatal "无法识别发行版 codename，不能安全改写 apt 源。"

  if [[ -n "$MIRROR_FORCE" ]]; then
    SELECTED_MIRROR_NAME="forced"
    SELECTED_MIRROR_URL="${MIRROR_FORCE%/}"
    if [[ "$APT_FAMILY" == "debian" ]]; then
      SELECTED_SECURITY_URL="$(printf '%s' "$SELECTED_MIRROR_URL" | sed 's#/debian$#/debian-security#')"
    fi
    log "已通过 MIRROR_FORCE 强制使用 mirror：${SELECTED_MIRROR_URL}"
    return 0
  fi

  local candidates=()
  if [[ "$APT_FAMILY" == "ubuntu" ]]; then
    candidates=(
      "Tsinghua|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|"
      "USTC|https://mirrors.ustc.edu.cn/ubuntu|"
      "BFSU|https://mirrors.bfsu.edu.cn/ubuntu|"
      "NJU|https://mirrors.nju.edu.cn/ubuntu|"
      "Aliyun|https://mirrors.aliyun.com/ubuntu|"
      "Tencent|https://mirrors.cloud.tencent.com/ubuntu|"
      "Huawei|https://repo.huaweicloud.com/ubuntu|"
      "SJTU|https://mirror.sjtu.edu.cn/ubuntu|"
    )
  else
    candidates=(
      "Tsinghua|https://mirrors.tuna.tsinghua.edu.cn/debian|https://mirrors.tuna.tsinghua.edu.cn/debian-security"
      "USTC|https://mirrors.ustc.edu.cn/debian|https://mirrors.ustc.edu.cn/debian-security"
      "BFSU|https://mirrors.bfsu.edu.cn/debian|https://mirrors.bfsu.edu.cn/debian-security"
      "NJU|https://mirrors.nju.edu.cn/debian|https://mirrors.nju.edu.cn/debian-security"
      "Aliyun|https://mirrors.aliyun.com/debian|https://mirrors.aliyun.com/debian-security"
      "Tencent|https://mirrors.cloud.tencent.com/debian|https://mirrors.cloud.tencent.com/debian-security"
      "Huawei|https://repo.huaweicloud.com/debian|https://repo.huaweicloud.com/debian-security"
      "SJTU|https://mirror.sjtu.edu.cn/debian|https://mirror.sjtu.edu.cn/debian-security"
    )
  fi

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    warn "未检测到 curl/wget，无法测速；将使用 USTC 作为默认国内源。"
    if [[ "$APT_FAMILY" == "ubuntu" ]]; then
      SELECTED_MIRROR_NAME="USTC-default"
      SELECTED_MIRROR_URL="https://mirrors.ustc.edu.cn/ubuntu"
    else
      SELECTED_MIRROR_NAME="USTC-default"
      SELECTED_MIRROR_URL="https://mirrors.ustc.edu.cn/debian"
      SELECTED_SECURITY_URL="https://mirrors.ustc.edu.cn/debian-security"
    fi
    return 0
  fi

  local best_score="999999" best_name="" best_url="" best_sec=""
  log "开始测试中国境内 apt mirror 延迟，目标：dists/${OS_CODENAME}/InRelease"
  for item in "${candidates[@]}"; do
    local name base security probe total success avg t
    IFS='|' read -r name base security <<<"$item"
    base="${base%/}"
    security="${security%/}"
    probe="${base}/dists/${OS_CODENAME}/InRelease"
    total="0"
    success=0

    for _ in $(seq 1 "$MIRROR_REPEAT"); do
      t="$(probe_url "$probe" || true)"
      if [[ "$t" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        total="$(awk -v a="$total" -v b="$t" 'BEGIN { printf "%.6f", a+b }')"
        success=$((success + 1))
      fi
    done

    if [[ "$success" -gt 0 ]]; then
      avg="$(awk -v a="$total" -v n="$success" 'BEGIN { printf "%.3f", a/n }')"
      log "mirror ${name}: ${avg}s (${success}/${MIRROR_REPEAT})"
      if awk -v a="$avg" -v b="$best_score" 'BEGIN { exit !(a < b) }'; then
        best_score="$avg"
        best_name="$name"
        best_url="$base"
        best_sec="$security"
      fi
    else
      warn "mirror ${name}: 不可达或超时"
    fi
  done

  if [[ -z "$best_url" ]]; then
    warn "所有 mirror 测试失败，将使用 USTC 作为兜底源。也可用 MIRROR_FORCE 手动指定。"
    if [[ "$APT_FAMILY" == "ubuntu" ]]; then
      best_name="USTC-fallback"
      best_url="https://mirrors.ustc.edu.cn/ubuntu"
      best_sec=""
    else
      best_name="USTC-fallback"
      best_url="https://mirrors.ustc.edu.cn/debian"
      best_sec="https://mirrors.ustc.edu.cn/debian-security"
    fi
  fi

  SELECTED_MIRROR_NAME="$best_name"
  SELECTED_MIRROR_URL="$best_url"
  SELECTED_SECURITY_URL="$best_sec"
  log "选择 mirror：${SELECTED_MIRROR_NAME} -> ${SELECTED_MIRROR_URL}${best_score:+，平均 ${best_score}s}"
}

backup_apt_sources() {
  [[ -d /etc/apt ]] || return 0
  APT_BACKUP_DIR="/etc/apt/serverfixed-backup-${TS}"
  mkdir -p "$APT_BACKUP_DIR"

  if [[ -f /etc/apt/sources.list ]]; then
    cp -a /etc/apt/sources.list "$APT_BACKUP_DIR/" || warn "备份 /etc/apt/sources.list 失败，继续执行。"
  fi

  if [[ -d /etc/apt/sources.list.d ]]; then
    mkdir -p "$APT_BACKUP_DIR/sources.list.d"
    cp -a /etc/apt/sources.list.d/. "$APT_BACKUP_DIR/sources.list.d/" || warn "备份 /etc/apt/sources.list.d 失败，继续执行。"
  fi

  log "已备份 apt 源到：${APT_BACKUP_DIR}"
}

disable_file_if_exists() {
  local src="$1"
  local dst_dir="$2"
  local base
  base="$(basename "$src")"
  if [[ -e "$src" ]]; then
    mv -f "$src" "${dst_dir}/${base}.disabled-${TS}" || fatal "移动 ${src} 失败。"
    log "已禁用旧系统源：${src}"
  fi
}

cleanup_invalid_apt_filenames() {
  [[ -d /etc/apt/sources.list.d ]] || return 0
  APT_DISABLED_DIR="/etc/apt/serverfixed-disabled-${TS}"
  mkdir -p "$APT_DISABLED_DIR"

  shopt -s nullglob
  local f base
  for f in /etc/apt/sources.list.d/*.bak* \
           /etc/apt/sources.list.d/*.disabled* \
           /etc/apt/sources.list.d/*.save \
           /etc/apt/sources.list.d/*.distUpgrade; do
    if [[ -e "$f" ]]; then
      base="$(basename "$f")"
      mv -f "$f" "${APT_DISABLED_DIR}/${base}" || warn "移动无效 apt 文件名失败：${f}"
      log "已移出 apt 会提示忽略的文件：${f}"
    fi
  done
  shopt -u nullglob
}

disable_default_apt_source_files() {
  APT_DISABLED_DIR="${APT_DISABLED_DIR:-/etc/apt/serverfixed-disabled-${TS}}"
  mkdir -p "$APT_DISABLED_DIR"

  disable_file_if_exists /etc/apt/sources.list "$APT_DISABLED_DIR"
  disable_file_if_exists /etc/apt/sources.list.d/debian.sources "$APT_DISABLED_DIR"
  disable_file_if_exists /etc/apt/sources.list.d/ubuntu.sources "$APT_DISABLED_DIR"
  disable_file_if_exists /etc/apt/sources.list.d/raspi.sources "$APT_DISABLED_DIR"
  disable_file_if_exists /etc/apt/sources.list.d/raspi.list "$APT_DISABLED_DIR"
}

write_apt_ipv4_timeout_config() {
  [[ "$FORCE_IPV4_APT" == "1" ]] || return 0
  mkdir -p /etc/apt/apt.conf.d
  cat > /etc/apt/apt.conf.d/99serverfixed-force-ipv4-timeout <<'EOF2'
Acquire::ForceIPv4 "true";
Acquire::http::Timeout "10";
Acquire::https::Timeout "10";
Acquire::Retries "2";
EOF2
  log "已写入 apt IPv4/超时配置：/etc/apt/apt.conf.d/99serverfixed-force-ipv4-timeout"
}

write_apt_sources() {
  [[ -n "$SELECTED_MIRROR_URL" ]] || return 0

  backup_apt_sources
  mkdir -p /etc/apt/sources.list.d
  cleanup_invalid_apt_filenames
  disable_default_apt_source_files
  write_apt_ipv4_timeout_config

  if [[ "$APT_FAMILY" == "ubuntu" ]]; then
    cat > /etc/apt/sources.list <<EOF2
# Generated by serverfixed linux_init_cn.sh at ${TS}
deb ${SELECTED_MIRROR_URL} ${OS_CODENAME} main restricted universe multiverse
deb ${SELECTED_MIRROR_URL} ${OS_CODENAME}-updates main restricted universe multiverse
deb ${SELECTED_MIRROR_URL} ${OS_CODENAME}-backports main restricted universe multiverse
deb ${SELECTED_MIRROR_URL} ${OS_CODENAME}-security main restricted universe multiverse
EOF2
  else
    local components="main contrib non-free"
    case "$OS_CODENAME" in
      bookworm|trixie|forky|sid) components="main contrib non-free non-free-firmware" ;;
    esac
    cat > /etc/apt/sources.list <<EOF2
# Generated by serverfixed linux_init_cn.sh at ${TS}
deb ${SELECTED_MIRROR_URL} ${OS_CODENAME} ${components}
deb ${SELECTED_MIRROR_URL} ${OS_CODENAME}-updates ${components}
deb ${SELECTED_SECURITY_URL:-${SELECTED_MIRROR_URL}} ${OS_CODENAME}-security ${components}
# 如需 backports，可手动取消下一行注释：
# deb ${SELECTED_MIRROR_URL} ${OS_CODENAME}-backports ${components}
EOF2
  fi

  log "已写入新的系统 apt 源：/etc/apt/sources.list"
}

fix_pve_repos_if_needed() {
  [[ -d /etc/pve ]] || return 0
  [[ "$PVE_FIX_REPOS" == "1" ]] || return 0
  [[ "$APT_FAMILY" == "debian" ]] || return 0

  log "检测到 Proxmox VE，开始处理 enterprise/no-subscription 源。"
  mkdir -p /etc/apt/sources.list.d
  local pve_disabled="/etc/apt/serverfixed-pve-disabled-${TS}"
  mkdir -p "$pve_disabled"

  for f in /etc/apt/sources.list.d/pve-enterprise.list \
           /etc/apt/sources.list.d/ceph.list \
           /etc/apt/sources.list.d/ceph.sources; do
    if [[ -f "$f" ]] && grep -q 'enterprise.proxmox.com' "$f"; then
      mv -f "$f" "${pve_disabled}/$(basename "$f").disabled-${TS}" || warn "禁用 ${f} 失败"
      log "已禁用 enterprise 源：${f}"
    fi
  done

  cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF2
# Generated by serverfixed linux_init_cn.sh at ${TS}
deb http://download.proxmox.com/debian/pve ${OS_CODENAME} pve-no-subscription
EOF2
  log "已添加 PVE no-subscription 源。"

  local ceph_component=""
  if grep -Rqs 'ceph-quincy' "$pve_disabled" 2>/dev/null; then
    ceph_component="ceph-quincy"
  elif grep -Rqs 'ceph-reef' "$pve_disabled" 2>/dev/null; then
    ceph_component="ceph-reef"
  elif grep -Rqs 'ceph-squid' "$pve_disabled" 2>/dev/null; then
    ceph_component="ceph-squid"
  fi

  if [[ -n "$ceph_component" ]]; then
    cat > "/etc/apt/sources.list.d/${ceph_component}-no-subscription.list" <<EOF2
# Generated by serverfixed linux_init_cn.sh at ${TS}
deb http://download.proxmox.com/debian/${ceph_component} ${OS_CODENAME} no-subscription
EOF2
    log "已添加 Ceph no-subscription 源：${ceph_component}"
  fi
}

apt_update_and_install() {
  command -v apt-get >/dev/null 2>&1 || return 0
  export DEBIAN_FRONTEND=noninteractive

  log "开始 apt update。"
  apt-get update

  log "安装基础组件：sudo openssh-server ca-certificates curl wget gnupg lsb-release。"
  apt-get install -y sudo openssh-server ca-certificates curl wget gnupg lsb-release apt-transport-https

  if [[ "$RUN_UPGRADE" == "1" ]]; then
    log "开始 apt upgrade。可通过 RUN_UPGRADE=0 跳过。"
    apt-get upgrade -y
  else
    log "跳过 apt upgrade。"
  fi
}

other_linux_update_and_install() {
  command -v apt-get >/dev/null 2>&1 && return 0
  if command -v dnf >/dev/null 2>&1; then
    log "检测到 dnf。当前脚本不会替换 dnf/yum mirror，仅更新并安装 sudo/openssh-server。"
    dnf -y makecache || true
    dnf -y install sudo openssh-server
  elif command -v yum >/dev/null 2>&1; then
    log "检测到 yum。当前脚本不会替换 dnf/yum mirror，仅更新并安装 sudo/openssh-server。"
    yum -y makecache || true
    yum -y install sudo openssh-server
  else
    fatal "未检测到 apt-get/dnf/yum，无法自动安装 SSH 和 sudo。"
  fi
}

create_or_update_user() {
  if id "$INIT_USER" >/dev/null 2>&1; then
    log "用户 ${INIT_USER} 已存在，将继续配置 sudo，并提示修改密码。"
  else
    log "创建用户：${INIT_USER}"
    if command -v adduser >/dev/null 2>&1; then
      adduser --disabled-password --gecos "" "$INIT_USER"
    else
      useradd -m -s /bin/bash "$INIT_USER"
    fi
  fi

  if getent group sudo >/dev/null 2>&1; then
    usermod -aG sudo "$INIT_USER"
  elif getent group wheel >/dev/null 2>&1; then
    usermod -aG wheel "$INIT_USER"
  else
    groupadd sudo
    usermod -aG sudo "$INIT_USER"
  fi

  if command -v visudo >/dev/null 2>&1; then
    local sudoers_file="/etc/sudoers.d/90-serverfixed-${INIT_USER}"
    printf '%s ALL=(ALL:ALL) ALL\n' "$INIT_USER" > "$sudoers_file"
    chmod 0440 "$sudoers_file"
    visudo -cf "$sudoers_file"
    log "已配置 sudo 权限：${sudoers_file}"
  fi

  if [[ -t 0 ]]; then
    log "请为 ${INIT_USER} 设置/更新密码。"
    passwd "$INIT_USER"
  else
    warn "当前不是交互式终端，未能设置密码。请稍后执行：sudo passwd ${INIT_USER}"
  fi
}

ensure_sshd_include_first() {
  local main_conf="/etc/ssh/sshd_config"
  local include_line="Include /etc/ssh/sshd_config.d/*.conf"
  [[ -f "$main_conf" ]] || return 0
  mkdir -p /etc/ssh/sshd_config.d
  if ! grep -Eq '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' "$main_conf"; then
    cp -a "$main_conf" "${main_conf}.serverfixed.bak.${TS}"
    { echo "$include_line"; cat "$main_conf"; } > "${main_conf}.tmp.${TS}"
    mv -f "${main_conf}.tmp.${TS}" "$main_conf"
    log "已在 sshd_config 顶部加入 Include，以便 drop-in 配置生效。"
  fi
}

configure_ssh() {
  mkdir -p /etc/ssh/sshd_config.d
  ensure_sshd_include_first
  local conf="/etc/ssh/sshd_config.d/99-serverfixed-init.conf"
  cat > "$conf" <<EOF2
# Generated by serverfixed linux_init_cn.sh at ${TS}
PubkeyAuthentication yes
PasswordAuthentication ${SSH_PASSWORD_AUTH}
KbdInteractiveAuthentication no
UsePAM yes
PermitRootLogin ${SSH_ROOT_LOGIN}
X11Forwarding no
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 2
EOF2

  local sshd_bin=""
  sshd_bin="$(command -v sshd || true)"
  [[ -n "$sshd_bin" ]] || sshd_bin="/usr/sbin/sshd"
  [[ -x "$sshd_bin" ]] || fatal "找不到 sshd。"
  "$sshd_bin" -t

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  else
    service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw active; then
    ufw allow OpenSSH || ufw allow 22/tcp || true
    log "检测到 UFW active，已尝试放行 OpenSSH。"
  fi

  log "SSH 已启用并完成基础加固：${conf}"
}

print_summary() {
  local ip_list=""
  ip_list="$(hostname -I 2>/dev/null | xargs || true)"
  cat <<EOF2

========== 初始化完成 ==========
系统：${OS_NAME}
APT mirror：${SELECTED_MIRROR_NAME:-未变更} ${SELECTED_MIRROR_URL:-}
管理员用户：${INIT_USER}
SSH 密码登录：${SSH_PASSWORD_AUTH}
Root SSH 登录：${SSH_ROOT_LOGIN}
本机 IP：${ip_list:-unknown}
日志：${LOG_FILE}

建议测试：
  ssh ${INIT_USER}@<服务器IP>
  sudo -v

稳定后更安全的做法：
  1) 给 ${INIT_USER} 配置 SSH 公钥；
  2) 将 /etc/ssh/sshd_config.d/99-serverfixed-init.conf 中 PasswordAuthentication 改为 no；
  3) systemctl restart ssh || systemctl restart sshd。
================================
EOF2
}

main() {
  require_root "${1:-}"
  validate_user
  log "========== serverfixed Linux 初始化开始 =========="
  load_os_info

  if command -v apt-get >/dev/null 2>&1; then
    choose_fastest_mirror
    write_apt_sources
    fix_pve_repos_if_needed
    apt_update_and_install
  else
    other_linux_update_and_install
  fi

  create_or_update_user
  configure_ssh
  print_summary
}

main "$@"
