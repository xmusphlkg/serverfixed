#!/usr/bin/env bash
set -Eeuo pipefail

# miner_rescue.sh
# Defensive cleanup script for /dev/shm cron-based miner infections.
# Default: dry-run. Use --remediate to modify system.
# Use --aggressive to stop xrdp/anydesk and quarantine broader suspicious files.

REMEDIATE=0
AGGRESSIVE=0

for arg in "$@"; do
  case "$arg" in
    --remediate) REMEDIATE=1 ;;
    --aggressive) AGGRESSIVE=1 ;;
    -h|--help)
      echo "Usage: sudo bash $0 [--remediate] [--aggressive]"
      exit 0
      ;;
    *)
      echo "Unknown arg: $arg"
      exit 1
      ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "[FATAL] Please run as root: sudo bash $0"
  exit 1
fi

TS="$(date +%F_%H%M%S)"
HOST="$(hostname -f 2>/dev/null || hostname)"
BASE="/root/incident_cleanup_${HOST}_${TS}"
QUAR="${BASE}/quarantine"
LOG="${BASE}/cleanup.log"
mkdir -p "$BASE" "$QUAR"

exec > >(tee -a "$LOG") 2>&1

echo "============================================================"
echo " Miner rescue / cleanup"
echo " Host: $HOST"
echo " Time: $TS"
echo " Mode: $([[ $REMEDIATE -eq 1 ]] && echo REMEDIATE || echo DRY-RUN)"
echo " Aggressive: $AGGRESSIVE"
echo " Output: $BASE"
echo "============================================================"
echo

IOC_RE='(/dev/shm|/var/tmp|xmrig|kinsing|kdevtmpfsi|\.k.*worker|\.kw.*ork|stratum|cryptonight|monero|pool\.|nanopool|minexmr|bash -c|curl .*\|.*sh|wget .*\|.*sh|base64 -d|nohup .*&|/tmp/\.|/dev/shm/\.)'

say() { echo "[$(date +%F_%T)] $*"; }

backup_file() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  local dest="${BASE}/backup${f}"
  mkdir -p "$(dirname "$dest")"
  cp -a "$f" "$dest" 2>/dev/null || true
}

quarantine_file() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  local clean
  clean="$(echo "$f" | sed 's#/#_#g')"
  local dest="${QUAR}/${clean}.${TS}"
  say "Quarantine file: $f -> $dest"
  if [[ "$REMEDIATE" -eq 1 ]]; then
    cp -a "$f" "$dest" 2>/dev/null || true
    chmod 000 "$f" 2>/dev/null || true
    rm -f "$f" 2>/dev/null || true
  fi
}

section() {
  echo
  echo "==================== $* ===================="
}

section "Basic system info"
uname -a || true
uptime || true
free -h || true
df -h / /tmp /var/tmp /dev/shm 2>/dev/null || true

section "Current top memory / CPU processes"
ps -eo pid,ppid,user,%cpu,%mem,rss,vsz,etime,cmd --sort=-rss | head -40 || true
echo
ps -eo pid,ppid,user,%cpu,%mem,rss,vsz,etime,cmd --sort=-%cpu | head -40 || true

section "Known bad process scan"
BAD_PIDS="$(ps -eo pid=,ppid=,user=,cmd= | grep -E "$IOC_RE" | grep -v grep | awk '{print $1}' | sort -u || true)"

if [[ -z "$BAD_PIDS" ]]; then
  say "No obvious IOC processes found."
else
  say "Suspicious process PIDs:"
  for p in $BAD_PIDS; do
    echo "---- PID $p ----"
    ps -fp "$p" || true
    readlink -f "/proc/$p/exe" 2>/dev/null || true
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true
    echo
    ls -l "/proc/$p/exe" 2>/dev/null || true
    ss -tunap 2>/dev/null | grep -F "pid=$p," || true
  done

  if [[ "$REMEDIATE" -eq 1 ]]; then
    say "Killing suspicious IOC processes..."
    for p in $BAD_PIDS; do
      kill -9 "$p" 2>/dev/null || true
    done
  else
    say "DRY-RUN: not killing processes. Re-run with --remediate."
  fi
fi

section "Scan /dev/shm, /tmp, /var/tmp"
for d in /dev/shm /tmp /var/tmp; do
  [[ -d "$d" ]] || continue
  echo "---- $d ----"
  find "$d" -maxdepth 2 -xdev \( -type f -o -type l \) -printf '%M %u %g %s %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort || true
done

section "Quarantine obvious malicious temp files"
TEMP_SUSPICIOUS="$(find /dev/shm /tmp /var/tmp -maxdepth 2 -xdev \( -type f -o -type l \) \
  \( -name '.*worker*' -o -name '*xmrig*' -o -name '*kinsing*' -o -name '*kdevtmp*' -o -name '.*k*ork*' \) \
  -print 2>/dev/null || true)"

if [[ -z "$TEMP_SUSPICIOUS" ]]; then
  say "No obvious malicious temp files found by filename."
else
  echo "$TEMP_SUSPICIOUS"
  if [[ "$REMEDIATE" -eq 1 ]]; then
    while IFS= read -r f; do
      [[ -n "$f" ]] && quarantine_file "$f"
    done <<< "$TEMP_SUSPICIOUS"
  else
    say "DRY-RUN: not deleting temp files."
  fi
fi

section "Cron scan"
CRON_DIRS=(/etc/crontab /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /var/spool/cron /var/spool/cron/crontabs)
for path in "${CRON_DIRS[@]}"; do
  [[ -e "$path" ]] || continue
  echo "---- scanning $path ----"
  grep -RInE "$IOC_RE" "$path" 2>/dev/null || true
done

section "Clean user crontabs"
# Identify users with crontabs by looking at crontab spool and also all normal users.
USERS_TO_CHECK=""
if [[ -d /var/spool/cron/crontabs ]]; then
  USERS_TO_CHECK+=" $(ls /var/spool/cron/crontabs 2>/dev/null || true)"
fi
if [[ -d /var/spool/cron ]]; then
  USERS_TO_CHECK+=" $(find /var/spool/cron -maxdepth 1 -type f -printf '%f\n' 2>/dev/null || true)"
fi
USERS_TO_CHECK+=" $(awk -F: '($3==0 || $3>=1000) && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd 2>/dev/null || true)"
USERS_TO_CHECK="$(echo "$USERS_TO_CHECK" | tr ' ' '\n' | sed '/^$/d' | sort -u)"

for u in $USERS_TO_CHECK; do
  if crontab -u "$u" -l >/tmp/cron_${u}_${TS}.txt 2>/dev/null; then
    if grep -E "$IOC_RE" "/tmp/cron_${u}_${TS}.txt" >/dev/null 2>&1; then
      say "Suspicious crontab for user: $u"
      cat "/tmp/cron_${u}_${TS}.txt"
      cp "/tmp/cron_${u}_${TS}.txt" "${BASE}/crontab_${u}.before"

      grep -Ev "$IOC_RE" "/tmp/cron_${u}_${TS}.txt" > "/tmp/cron_${u}_${TS}.clean" || true

      if [[ "$REMEDIATE" -eq 1 ]]; then
        say "Installing cleaned crontab for $u"
        crontab -u "$u" "/tmp/cron_${u}_${TS}.clean"
        cp "/tmp/cron_${u}_${TS}.clean" "${BASE}/crontab_${u}.after"
      else
        say "DRY-RUN: would remove matching IOC lines from $u crontab."
      fi
    fi
  fi
done

section "Systemd service scan"
SYSTEMD_HITS="$(grep -RIlE "$IOC_RE" /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system 2>/dev/null || true)"
if [[ -z "$SYSTEMD_HITS" ]]; then
  say "No suspicious systemd unit files found by IOC regex."
else
  echo "$SYSTEMD_HITS"
  for f in $SYSTEMD_HITS; do
    echo "---- $f ----"
    grep -nE "$IOC_RE" "$f" 2>/dev/null || true
    backup_file "$f"
    unit="$(basename "$f")"

    if [[ "$REMEDIATE" -eq 1 ]]; then
      say "Stopping/disabling suspicious unit: $unit"
      systemctl stop "$unit" 2>/dev/null || true
      systemctl disable "$unit" 2>/dev/null || true
      quarantine_file "$f"
    else
      say "DRY-RUN: would stop/disable/quarantine $unit"
    fi
  done

  if [[ "$REMEDIATE" -eq 1 ]]; then
    systemctl daemon-reload || true
  fi
fi

section "Shell profile / rc scan"
PROFILE_PATHS=(/etc/profile /etc/bash.bashrc /etc/rc.local /root/.bashrc /root/.profile /root/.ssh/rc)
for hp in /home/*/.bashrc /home/*/.profile /home/*/.ssh/rc; do
  PROFILE_PATHS+=("$hp")
done

for f in "${PROFILE_PATHS[@]}"; do
  [[ -e "$f" ]] || continue
  if grep -nE "$IOC_RE" "$f" >/dev/null 2>&1; then
    say "Suspicious profile/rc file: $f"
    grep -nE "$IOC_RE" "$f" || true
    backup_file "$f"
    if [[ "$REMEDIATE" -eq 1 ]]; then
      say "Commenting suspicious lines in $f"
      sed -i.bak_${TS} -E "/$IOC_RE/s/^/# INCIDENT_DISABLED_${TS} /" "$f" || true
    else
      say "DRY-RUN: would comment suspicious lines in $f"
    fi
  fi
done

section "SSH account and key audit"
echo "UID 0 accounts:"
awk -F: '$3==0 {print}' /etc/passwd || true
echo
echo "Authorized keys:"
find /root /home -path '*/.ssh/authorized_keys' -type f -exec echo "---- {} ----" \; -exec cat {} \; 2>/dev/null || true
echo
echo "Recent logins:"
last -a | head -50 || true

section "Network listeners"
ss -tulpen || true

section "Docker audit"
if command -v docker >/dev/null 2>&1; then
  echo "---- docker ps ----"
  docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" || true

  echo
  echo "---- docker risky mounts / privileged ----"
  docker inspect $(docker ps -q) --format '### {{.Name}}
Privileged={{.HostConfig.Privileged}}
Network={{.HostConfig.NetworkMode}}
PidMode={{.HostConfig.PidMode}}
Mounts={{json .Mounts}}
' 2>/dev/null || true

  echo
  echo "---- docker.sock mount quick check ----"
  docker inspect $(docker ps -q) --format '{{.Name}} {{json .Mounts}}' 2>/dev/null | grep -E 'docker.sock|/var/spool/cron|/etc"|/root"|"/",' || true
else
  say "Docker not installed."
fi

section "Remount /dev/shm noexec,nosuid,nodev"
mount | grep ' /dev/shm ' || true
if [[ "$REMEDIATE" -eq 1 ]]; then
  say "Remounting /dev/shm with noexec,nosuid,nodev"
  mount -o remount,noexec,nosuid,nodev /dev/shm 2>/dev/null || true

  if ! grep -qE '^[^#].*\s/dev/shm\s' /etc/fstab; then
    backup_file /etc/fstab
    echo 'tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0' >> /etc/fstab
    say "Added /dev/shm hardening line to /etc/fstab"
  else
    say "/etc/fstab already has /dev/shm entry. Please manually ensure it contains noexec,nosuid,nodev."
  fi
else
  say "DRY-RUN: would remount /dev/shm noexec,nosuid,nodev and persist in /etc/fstab if absent."
fi
mount | grep ' /dev/shm ' || true

section "Optional aggressive service stop"
if [[ "$AGGRESSIVE" -eq 1 ]]; then
  for svc in xrdp xrdp-sesman anydesk; do
    if systemctl list-unit-files | awk '{print $1}' | grep -qx "${svc}.service"; then
      say "Aggressive mode: stopping/disabling $svc"
      if [[ "$REMEDIATE" -eq 1 ]]; then
        systemctl disable --now "$svc" 2>/dev/null || true
      fi
    fi
  done
else
  say "Not stopping xrdp/anydesk automatically. Use --aggressive if desired."
fi

section "Install minimal hardening tools if available"
if [[ "$REMEDIATE" -eq 1 ]]; then
  if command -v apt >/dev/null 2>&1; then
    say "Installing fail2ban if apt is available"
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y fail2ban lsof psmisc >/dev/null 2>&1 || true
    systemctl enable --now fail2ban 2>/dev/null || true
  elif command -v yum >/dev/null 2>&1; then
    say "yum detected; not auto-installing to avoid breaking production. Install fail2ban manually if needed."
  fi
fi

section "Post-clean verification"
echo "---- IOC processes ----"
ps -eo pid,ppid,user,%cpu,%mem,etime,cmd | grep -E "$IOC_RE" | grep -v grep || true

echo "---- IOC cron ----"
for path in "${CRON_DIRS[@]}"; do
  [[ -e "$path" ]] || continue
  grep -RInE "$IOC_RE" "$path" 2>/dev/null || true
done

echo "---- memory ----"
free -h || true

echo
echo "============================================================"
echo "Done."
echo "Report/log directory: $BASE"
echo
if [[ "$REMEDIATE" -eq 0 ]]; then
  echo "This was DRY-RUN only. Re-run with:"
  echo "  sudo bash $0 --remediate"
  echo "or:"
  echo "  sudo bash $0 --remediate --aggressive"
fi
echo "============================================================"