#!/usr/bin/env bash
set -Eeuo pipefail

# Zabbix Agent 2 installer for Debian/Ubuntu/PVE lab servers.
#
# This script installs or reconfigures zabbix-agent2 on the CURRENT machine only.
# It is designed for a non-root user and uses sudo internally.
#
# Supported systems:
#   - Debian 10/11/12/13, including Proxmox VE based on Debian
#   - Ubuntu 20.04/22.04/24.04/26.04
#
# Important TrueNAS note:
#   Do NOT run this on the TrueNAS SCALE host OS. TrueNAS is an appliance OS.
#   Install Zabbix Agent 2 inside a VM instead, or monitor TrueNAS via SNMP/API.
#
# Basic usage:
#   bash zabbix-agent2-install.sh 192.168.10.57 server06
#
# One-line GitHub usage:
#   curl -fsSL https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/zabbix-agent2-install.sh -o /tmp/zabbix-agent2-install.sh
#   bash /tmp/zabbix-agent2-install.sh 192.168.10.57 server06
#
# Environment variable usage:
#   SERVER=192.168.10.57 ZBX_HOST=server06 bash zabbix-agent2-install.sh
#
# Optional variables:
#   SERVER=192.168.10.57       Zabbix server/proxy IP or DNS name
#   ZBX_HOST=server06          Zabbix Hostname value, must match frontend host name
#   ZBX_VERSION=7.0            Zabbix major version, default is 7.0 LTS
#   TIMEZONE=Asia/Shanghai     Set system timezone. Use TIMEZONE=skip to skip
#   REPAIR_APT=1               Try to repair broken apt/dpkg before install
#   CONFIGURE_FIREWALL=1       Add ufw/firewalld allow rule if firewall is active
#   REPORT_DIR=/var/tmp/zabbix-agent2-install-report

DEFAULT_SERVER="192.168.10.57"
SERVER="${SERVER:-${ZBX_SERVER:-${1:-$DEFAULT_SERVER}}}"
ZBX_HOST="${ZBX_HOST:-${ZBX_HOSTNAME:-${2:-$(hostname -f 2>/dev/null || hostname)}}}"
ZBX_VERSION="${ZBX_VERSION:-7.0}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
REPAIR_APT="${REPAIR_APT:-1}"
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-1}"
REPORT_DIR="${REPORT_DIR:-/var/tmp/zabbix-agent2-install-report}"
RUN_ID="$(date +%F_%H%M%S)"
LOG_FILE="${REPORT_DIR}/install-${RUN_ID}.log"
SUMMARY_FILE="${REPORT_DIR}/summary-${RUN_ID}.txt"

log() { echo; echo "========== $* =========="; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

sudo_cmd() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

apt_run() {
  sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

prepare_logging() {
  sudo_cmd mkdir -p "$REPORT_DIR"

  if [[ "$(id -u)" -ne 0 ]]; then
    sudo_cmd chown "$(id -u):$(id -g)" "$REPORT_DIR" 2>/dev/null || true
  fi

  if ! touch "$LOG_FILE" "$SUMMARY_FILE" 2>/dev/null; then
    sudo_cmd touch "$LOG_FILE" "$SUMMARY_FILE"
    sudo_cmd chmod 0666 "$LOG_FILE" "$SUMMARY_FILE"
  fi

  exec > >(tee -a "$LOG_FILE") 2>&1
}

set_conf() {
  local key="$1"
  local value="$2"
  local file="$3"

  if sudo_cmd grep -qE "^#?${key}=" "$file"; then
    sudo_cmd sed -i "s|^#\?${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" | sudo_cmd tee -a "$file" >/dev/null
  fi
}

repair_apt() {
  log "Repair apt/dpkg state"

  sudo_cmd dpkg --configure -a || true
  apt_run update -o Acquire::Retries=3 || true

  if apt_run -y --fix-broken install; then
    info "apt --fix-broken install succeeded"
    return 0
  fi

  warn "First apt repair failed. Trying to unhold and synchronize common GnuPG packages."

  local pkgs=(gnupg dirmngr gnupg-utils gpg gpg-agent gpg-wks-client gpg-wks-server gpgsm gpgv)

  if have apt-mark; then
    for p in "${pkgs[@]}"; do
      sudo_cmd apt-mark unhold "$p" >/dev/null 2>&1 || true
    done
  fi

  apt_run update -o Acquire::Retries=3 || true
  apt_run install -y --allow-downgrades --allow-change-held-packages "${pkgs[@]}" || true
  sudo_cmd dpkg --configure -a || true

  apt_run -y --fix-broken install || fail "APT is still broken. Check: apt-mark showhold && apt-cache policy gnupg dirmngr gpg"
}

detect_os() {
  [[ -r /etc/os-release ]] || fail "Cannot detect OS: /etc/os-release is missing"
  # shellcheck disable=SC1091
  . /etc/os-release

  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  ARCH="$(dpkg --print-architecture)"

  case "$OS_ID" in
    debian)
      DIST="debian"
      DIST_VER="${OS_VERSION_ID%%.*}"
      ;;
    ubuntu)
      DIST="ubuntu"
      DIST_VER="$OS_VERSION_ID"
      ;;
    *)
      fail "Unsupported OS: ID=${OS_ID}. This script supports Debian/Ubuntu only."
      ;;
  esac

  case "$DIST" in
    debian)
      case "$DIST_VER" in
        10|11|12|13) ;;
        *) fail "Unsupported Debian version: ${DIST_VER}" ;;
      esac
      ;;
    ubuntu)
      case "$DIST_VER" in
        20.04|22.04|24.04|26.04) ;;
        *) fail "Unsupported Ubuntu version: ${DIST_VER}" ;;
      esac
      ;;
  esac

  case "$ARCH" in
    amd64|i386)
      REPO_DIST_PATH="$DIST"
      ;;
    arm64)
      if [[ "$DIST" == "debian" ]]; then
        REPO_DIST_PATH="debian-arm64"
      else
        REPO_DIST_PATH="ubuntu-arm64"
      fi
      ;;
    *)
      fail "Unsupported CPU architecture: ${ARCH}"
      ;;
  esac
}

build_repo_url() {
  RELEASE_DEB="zabbix-release_latest_${ZBX_VERSION}+${DIST}${DIST_VER}_all.deb"
  RELEASE_URL="https://repo.zabbix.com/zabbix/${ZBX_VERSION}/${REPO_DIST_PATH}/pool/main/z/zabbix-release/${RELEASE_DEB}"

  # Runtime fallback: some architectures may still be served from the generic distro path.
  FALLBACK_URL="https://repo.zabbix.com/zabbix/${ZBX_VERSION}/${DIST}/pool/main/z/zabbix-release/${RELEASE_DEB}"
}

download_zabbix_release() {
  log "Download Zabbix repository package"

  sudo_cmd rm -f /tmp/zabbix-release.deb

  local selected_url=""

  if wget --spider -q "$RELEASE_URL"; then
    selected_url="$RELEASE_URL"
  elif [[ "$FALLBACK_URL" != "$RELEASE_URL" ]] && wget --spider -q "$FALLBACK_URL"; then
    selected_url="$FALLBACK_URL"
  else
    echo "Tried URL 1: $RELEASE_URL"
    echo "Tried URL 2: $FALLBACK_URL"
    fail "Cannot find a matching zabbix-release package for ${DIST} ${DIST_VER} ${ARCH}"
  fi

  info "Using: $selected_url"
  wget -O /tmp/zabbix-release.deb "$selected_url"

  if ! dpkg-deb -I /tmp/zabbix-release.deb >/dev/null 2>&1; then
    warn "Downloaded file is not a valid Debian package. Showing file header:"
    file /tmp/zabbix-release.deb || true
    head -n 20 /tmp/zabbix-release.deb || true
    fail "Invalid zabbix-release package"
  fi
}

main() {
  if [[ -e /etc/truenas-release || -e /etc/ix-release ]]; then
    fail "This looks like a TrueNAS SCALE host OS. Do not install apt packages on TrueNAS host OS. Use a VM instead."
  fi

  if [[ "$(id -u)" -ne 0 ]]; then
    have sudo || fail "sudo is required for non-root execution"
    sudo -v || fail "sudo authentication failed"
  fi

  prepare_logging
  trap 'echo; echo "[ERROR] Script failed at line ${LINENO}. Full log: ${LOG_FILE}" >&2' ERR

  log "Basic information"
  echo "server              : $SERVER"
  echo "zabbix_host         : $ZBX_HOST"
  echo "zabbix_version      : $ZBX_VERSION"
  echo "timezone            : $TIMEZONE"
  echo "repair_apt          : $REPAIR_APT"
  echo "configure_firewall  : $CONFIGURE_FIREWALL"
  echo "report_dir          : $REPORT_DIR"
  echo "log_file            : $LOG_FILE"

  log "Detect OS"
  detect_os
  echo "os_id               : $OS_ID"
  echo "version_id          : $OS_VERSION_ID"
  echo "codename            : $OS_CODENAME"
  echo "dist                : $DIST"
  echo "dist_ver            : $DIST_VER"
  echo "arch                : $ARCH"
  echo "repo_dist_path      : $REPO_DIST_PATH"

  build_repo_url
  echo "release_url         : $RELEASE_URL"
  [[ "$FALLBACK_URL" != "$RELEASE_URL" ]] && echo "fallback_url        : $FALLBACK_URL"

  if [[ "$REPAIR_APT" == "1" ]]; then
    repair_apt
  else
    log "APT repair skipped"
  fi

  log "Install basic tools"
  apt_run update -o Acquire::Retries=3
  apt_run install -y wget ca-certificates apt-transport-https lsb-release

  if [[ "$TIMEZONE" != "skip" && -n "$TIMEZONE" ]]; then
    log "Set timezone"
    if have timedatectl; then
      sudo_cmd timedatectl set-timezone "$TIMEZONE" || warn "Failed to set timezone: $TIMEZONE"
      timedatectl || true
    else
      warn "timedatectl not found, skipping timezone setup"
    fi
  fi

  download_zabbix_release

  log "Install Zabbix repository"
  # Remove stale Zabbix repo files to avoid mixed-version repo problems.
  sudo_cmd find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name 'zabbix*.list' -o -name 'zabbix*.sources' \) -print -delete 2>/dev/null || true
  sudo_cmd dpkg -i /tmp/zabbix-release.deb
  apt_run update -o Acquire::Retries=3

  log "Install Zabbix Agent 2"
  sudo_cmd systemctl disable --now zabbix-agent 2>/dev/null || true
  apt_run install -y zabbix-agent2

  [[ -f /etc/zabbix/zabbix_agent2.conf ]] || fail "Missing config file: /etc/zabbix/zabbix_agent2.conf"

  log "Configure Zabbix Agent 2"
  sudo_cmd cp -a /etc/zabbix/zabbix_agent2.conf "/etc/zabbix/zabbix_agent2.conf.bak.${RUN_ID}"
  set_conf "Server" "$SERVER" /etc/zabbix/zabbix_agent2.conf
  set_conf "ServerActive" "$SERVER" /etc/zabbix/zabbix_agent2.conf
  set_conf "Hostname" "$ZBX_HOST" /etc/zabbix/zabbix_agent2.conf

  log "Start service"
  sudo_cmd systemctl daemon-reload
  sudo_cmd systemctl enable --now zabbix-agent2
  sudo_cmd systemctl restart zabbix-agent2

  log "Configure firewall if active"
  if [[ "$CONFIGURE_FIREWALL" == "1" ]]; then
    if have ufw && sudo_cmd ufw status 2>/dev/null | grep -qi "Status: active"; then
      sudo_cmd ufw allow from "$SERVER" to any port 10050 proto tcp || warn "ufw rule failed"
    elif have firewall-cmd && sudo_cmd firewall-cmd --state >/dev/null 2>&1; then
      sudo_cmd firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${SERVER} port protocol=tcp port=10050 accept" || warn "firewalld rich rule failed"
      sudo_cmd firewall-cmd --reload || true
    else
      info "No active ufw/firewalld detected, skipping firewall change"
    fi
  else
    info "Firewall configuration skipped"
  fi

  log "Verification"
  echo "[Config]"
  grep -E '^(Server|ServerActive|Hostname)=' /etc/zabbix/zabbix_agent2.conf || true

  echo
  echo "[Service]"
  sudo_cmd systemctl status zabbix-agent2 --no-pager || true

  echo
  echo "[Local agent.ping]"
  zabbix_agent2 -t agent.ping || true

  echo
  echo "[Listen tcp/10050]"
  if have ss; then
    sudo_cmd ss -lntp | grep ':10050' || true
  else
    warn "ss command not found"
  fi

  echo
  echo "[Recent log]"
  sudo_cmd tail -n 80 /var/log/zabbix/zabbix_agent2.log || true

  cat > /tmp/zabbix-agent2-summary.txt <<SUMMARY
Zabbix Agent 2 installation summary
===================================
Time: ${RUN_ID}
Server: ${SERVER}
Hostname: ${ZBX_HOST}
OS: ${OS_ID} ${OS_VERSION_ID} ${OS_CODENAME}
Arch: ${ARCH}
Zabbix version: ${ZBX_VERSION}
Config: /etc/zabbix/zabbix_agent2.conf
Backup: /etc/zabbix/zabbix_agent2.conf.bak.${RUN_ID}
Log: ${LOG_FILE}

Next step in Zabbix frontend:
- Host name must equal: ${ZBX_HOST}
- Interface type: Agent
- Port: 10050
- Template: Linux by Zabbix agent or Linux by Zabbix agent active
SUMMARY
  cp /tmp/zabbix-agent2-summary.txt "$SUMMARY_FILE" 2>/dev/null || sudo_cmd cp /tmp/zabbix-agent2-summary.txt "$SUMMARY_FILE"
  rm -f /tmp/zabbix-agent2-summary.txt

  log "Finished"
  cat "$SUMMARY_FILE"
  echo
  echo "[OK] Zabbix Agent 2 installed/reconfigured."
}

main "$@"
