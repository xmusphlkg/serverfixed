#!/usr/bin/env bash
# serverfixed Linux 初始化脚本
# 默认只做最稳定的第一步：自动识别系统、测速选择中国境内 apt mirror、备份并写入系统 apt 源。
# 后续 apt update、安装 SSH/sudo、创建用户等步骤请按 LINUX_INIT_CN.md 手动执行。

set -Eeuo pipefail

INIT_USER="${INIT_USER:-likangguo}"
MIRROR_FORCE="${MIRROR_FORCE:-}"
MIRROR_TIMEOUT="${MIRROR_TIMEOUT:-3}"
MIRROR_REPEAT="${MIRROR_REPEAT:-2}"
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

默认功能：
  1. 自动识别 Debian/Ubuntu/PVE。
  2. 自动测试中国境内 apt mirror 延迟。
  3. 选择最低延迟 mirror。
  4. 备份原 apt 源。
  5. 清理 sources.list.d 里会引发 apt Notice 的无效备份文件。
  6. 写入新的系统 apt 源。
  7. 写入 apt IPv4/超时配置，避免 IPv6 异常导致 apt 卡死。
  8. 打印下一步手动初始化命令。

常用环境变量：
  MIRROR_FORCE=URL       跳过测速，强制使用指定 mirror。
  MIRROR_TIMEOUT=3       单次 mirror 连接超时时间。
  MIRROR_REPEAT=2        每个 mirror 测试次数。
  FORCE_IPV4_APT=1       为 apt 强制 IPv4 和超时配置。
  INIT_USER=likangguo    打印后续用户创建命令时使用的用户名。

示例：
  sudo bash linux_init_cn.sh
  MIRROR_FORCE=https://mirrors.ustc.edu.cn/ubuntu sudo bash linux_init_cn.sh
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
    warn "检测到 Ubuntu 25.04/plucky。该版本是短周期版本；若 apt update 后出现 404，请按说明文档改用 old-releases 或升级系统。"
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
  [[ -n "$APT_FAMILY" ]] || fatal "未检测到 apt 系统，本脚本只负责 Debian/Ubuntu/PVE apt 换源。"
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
  log "选择 mirror：${SELECTED_MIRROR_NAME} -> ${SELECTED_MIRROR_URL}"
}

backup_apt_sources() {
  [[ -d /etc/apt ]] || fatal "/etc/apt 不存在，无法继续。"
  APT_BACKUP_DIR="/etc/apt/serverfixed-backup-${TS}"
  mkdir -p "$APT_BACKUP_DIR"

  [[ -f /etc/apt/sources.list ]] && cp -a /etc/apt/sources.list "$APT_BACKUP_DIR/" || true
  if [[ -d /etc/apt/sources.list.d ]]; then
    mkdir -p "$APT_BACKUP_DIR/sources.list.d"
    cp -a /etc/apt/sources.list.d/. "$APT_BACKUP_DIR/sources.list.d/" 2>/dev/null || true
  fi

  log "已备份 apt 源到：${APT_BACKUP_DIR}"
}

move_if_exists() {
  local src="$1"
  local dst_dir="$2"
  local base
  base="$(basename "$src")"
  if [[ -e "$src" ]]; then
    mv -f "$src" "${dst_dir}/${base}.disabled-${TS}" || fatal "移动 ${src} 失败。"
    log "已移出旧源文件：${src}"
  fi
}

cleanup_and_disable_old_sources() {
  APT_DISABLED_DIR="/etc/apt/serverfixed-disabled-${TS}"
  mkdir -p "$APT_DISABLED_DIR"
  mkdir -p /etc/apt/sources.list.d

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

  move_if_exists /etc/apt/sources.list "$APT_DISABLED_DIR"
  move_if_exists /etc/apt/sources.list.d/debian.sources "$APT_DISABLED_DIR"
  move_if_exists /etc/apt/sources.list.d/ubuntu.sources "$APT_DISABLED_DIR"
  move_if_exists /etc/apt/sources.list.d/raspi.sources "$APT_DISABLED_DIR"
  move_if_exists /etc/apt/sources.list.d/raspi.list "$APT_DISABLED_DIR"
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
  [[ -n "$SELECTED_MIRROR_URL" ]] || fatal "没有选定 mirror，无法写入 apt 源。"

  backup_apt_sources
  cleanup_and_disable_old_sources
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

print_next_steps() {
  cat <<EOF2

========== 换源完成，后续请手动执行 ==========
系统：${OS_NAME}
APT mirror：${SELECTED_MIRROR_NAME} ${SELECTED_MIRROR_URL}
备份目录：${APT_BACKUP_DIR}
旧源移出目录：${APT_DISABLED_DIR}
日志：${LOG_FILE}

建议下一步：

1) 更新 apt 索引：
  apt clean
  apt update

2) 安装基础组件：
  apt install -y sudo openssh-server ca-certificates curl wget gnupg lsb-release

3) 启动 SSH：
  systemctl enable --now ssh || systemctl enable --now sshd
  systemctl status ssh --no-pager || systemctl status sshd --no-pager

4) 新建/配置管理员用户：
  adduser ${INIT_USER}
  usermod -aG sudo ${INIT_USER}
  echo '${INIT_USER} ALL=(ALL:ALL) ALL' > /etc/sudoers.d/90-${INIT_USER}
  chmod 0440 /etc/sudoers.d/90-${INIT_USER}
  visudo -cf /etc/sudoers.d/90-${INIT_USER}

5) 设置 SSH 基础配置：
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-serverfixed-init.conf <<'SSHCONF'
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
PermitRootLogin prohibit-password
X11Forwarding no
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 2
SSHCONF
  sshd -t
  systemctl restart ssh || systemctl restart sshd

6) 从另一台机器测试：
  ssh ${INIT_USER}@<服务器IP>
  sudo -v

详细说明见仓库：LINUX_INIT_CN.md
============================================
EOF2
}

main() {
  require_root "${1:-}"
  log "========== serverfixed Linux apt 换源开始 =========="
  load_os_info
  choose_fastest_mirror
  write_apt_sources
  print_next_steps
}

main "$@"
