#!/usr/bin/env bash
#
# remove_zerotier_linux.sh
# Linux ZeroTier cleanup/removal helper.
#
# Usage:
#   sudo bash remove_zerotier_linux.sh
#   sudo bash remove_zerotier_linux.sh --keep-identity
#   sudo bash remove_zerotier_linux.sh --no-apt-update
#
# WARNING:
#   Do not run this over a ZeroTier-only SSH session. Removing ZeroTier may
#   immediately disconnect the host from the ZeroTier network.

set -u

KEEP_IDENTITY=0
APT_UPDATE=1

log()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<'USAGE'
Remove ZeroTier from Linux and clean common leftovers.

Options:
  --keep-identity   Keep /var/lib/zerotier-one, including node identity files.
  --no-apt-update   Do not run apt update after removing ZeroTier apt sources.
  -h, --help        Show this help message.

Examples:
  sudo bash remove_zerotier_linux.sh
  sudo bash remove_zerotier_linux.sh --keep-identity
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep-identity)
      KEEP_IDENTITY=1
      ;;
    --no-apt-update)
      APT_UPDATE=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown option: $1"
      usage
      exit 2
      ;;
  esac
  shift
done

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$0" "$@"
  fi
  err "Please run as root, or install sudo."
  exit 1
fi

echo "========== ZeroTier Linux Removal =========="
warn "Make sure this host is not being managed through a ZeroTier-only connection."

if command -v zerotier-cli >/dev/null 2>&1; then
  log "Current ZeroTier status before removal:"
  zerotier-cli status 2>/dev/null || true
  zerotier-cli listnetworks 2>/dev/null || true
fi

log "Stopping and disabling zerotier-one service if present..."
systemctl stop zerotier-one 2>/dev/null || true
systemctl disable zerotier-one 2>/dev/null || true
systemctl reset-failed zerotier-one 2>/dev/null || true

log "Removing zerotier-one package when installed..."
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y zerotier-one || true
  apt-get autoremove -y || true
  apt-get autoclean || true

  log "Removing ZeroTier apt sources and keys..."
  rm -f /etc/apt/sources.list.d/*zerotier*.list
  rm -f /etc/apt/sources.list.d/*zerotier*.sources
  rm -f /usr/share/keyrings/*zerotier*.gpg
  rm -f /etc/apt/trusted.gpg.d/*zerotier*.gpg

  if [ "$APT_UPDATE" -eq 1 ]; then
    apt-get update || true
  fi
elif command -v dnf >/dev/null 2>&1; then
  dnf remove -y zerotier-one || true
  rm -f /etc/yum.repos.d/*zerotier*.repo
  dnf clean all || true
elif command -v yum >/dev/null 2>&1; then
  yum remove -y zerotier-one || true
  rm -f /etc/yum.repos.d/*zerotier*.repo
  yum clean all || true
elif command -v zypper >/dev/null 2>&1; then
  zypper --non-interactive remove zerotier-one || true
  zypper --non-interactive removerepo zerotier 2>/dev/null || true
elif command -v pacman >/dev/null 2>&1; then
  pacman -Rns --noconfirm zerotier-one || true
elif command -v apk >/dev/null 2>&1; then
  apk del zerotier-one || true
else
  warn "Unknown package manager. Package removal may need to be done manually."
fi

log "Removing systemd drop-ins and common config directories..."
rm -rf /etc/systemd/system/zerotier-one.service.d
rm -rf /etc/zerotier-one

if [ "$KEEP_IDENTITY" -eq 1 ]; then
  warn "Keeping /var/lib/zerotier-one because --keep-identity was used."
else
  log "Removing ZeroTier identity and state directory..."
  rm -rf /var/lib/zerotier-one
fi

log "Deleting leftover zt* network interfaces when present..."
if command -v ip >/dev/null 2>&1; then
  ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -E '^zt[a-zA-Z0-9]+' | while read -r iface; do
    [ -n "$iface" ] || continue
    ip link delete "$iface" 2>/dev/null || true
  done
fi

log "Reloading systemd..."
systemctl daemon-reload 2>/dev/null || true

cat <<'VERIFY'

========== Verification ==========
VERIFY

printf '\n[1] ZeroTier binaries:\n'
command -v zerotier-cli || true
command -v zerotier-one || true

printf '\n[2] ZeroTier processes:\n'
ps aux | grep -i '[z]erotier' || true

printf '\n[3] ZeroTier services:\n'
systemctl list-units --type=service --all 2>/dev/null | grep -i zerotier || true
systemctl list-unit-files 2>/dev/null | grep -i zerotier || true

printf '\n[4] ZeroTier interfaces:\n'
if command -v ip >/dev/null 2>&1; then
  ip addr | grep -i 'zt' || true
fi

printf '\n[5] ZeroTier routes:\n'
if command -v ip >/dev/null 2>&1; then
  ip route | grep -i 'zt' || true
  ip -6 route | grep -i 'zt' || true
fi

printf '\n[DONE] ZeroTier removal finished. If all verification sections are empty, cleanup is complete.\n'
