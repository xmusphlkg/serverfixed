#!/usr/bin/env bash
set -Eeuo pipefail

# miner_rescue_v3.sh
# Defensive cleanup script for /dev/shm miner infections and persistence.
#
# Default: dry-run only.
# Use:
#   sudo bash miner_rescue.sh
#   sudo bash miner_rescue.sh --remediate
#   sudo bash miner_rescue.sh --remediate --aggressive
#
# v3 focus:
# - Clean /dev/shm malicious files even when no process is running.
# - Clean cron persistence.
# - Clean /etc/rc.local persistence.
# - Clean systemd / timer / user-systemd persistence.
# - Clean profile / bashrc / ssh rc / ld.so.preload persistence.
# - Final force cleanup loop.
# - Clear final status: CLEAN / WARNING / INFECTED.
# - Recommend users whose passwords / SSH keys should be rotated.

REMEDIATE=0
AGGRESSIVE=0
INSTALL_TOOLS=0

for arg in "$@"; do
  case "$arg" in
    --remediate)
      REMEDIATE=1
      ;;
    --aggressive)
      AGGRESSIVE=1
      ;;
    --install-tools)
      INSTALL_TOOLS=1
      ;;
    -h|--help)
      cat <<'EOF'
Usage:
  sudo bash miner_rescue.sh
  sudo bash miner_rescue.sh --remediate
  sudo bash miner_rescue.sh --remediate --aggressive
  sudo bash miner_rescue.sh --remediate --install-tools

Options:
  --remediate      Actually clean suspicious items.
  --aggressive     Also stop/disable xrdp, anydesk, vnc-related services if present.
  --install-tools  Try installing fail2ban, lsof, psmisc, inotify-tools.
EOF
      exit 0
      ;;
    *)
      echo "[FATAL] Unknown argument: $arg"
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
REPORT="${BASE}/summary.txt"

mkdir -p "$BASE" "$QUAR"

exec > >(tee -a "$LOG") 2>&1

say() {
  echo "[$(date +%F_%T)] $*"
}

section() {
  echo
  echo "==================== $* ===================="
}

append_report() {
  echo "$*" >> "$REPORT"
}

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

  say "Quarantine: $f -> $dest"

  if [[ "$REMEDIATE" -eq 1 ]]; then
    cp -a "$f" "$dest" 2>/dev/null || true
    chmod 000 "$dest" 2>/dev/null || true
    chmod 000 "$f" 2>/dev/null || true
    rm -f "$f" 2>/dev/null || true
  fi
}

# Process IOC: focus on runtime command line.
PROC_BAD_RE='(/dev/shm|xmrig|kinsing|kdevtmpfsi|cryptonight|cryptonote|monero|minexmr|nanopool|stratum|\.kw)'

# Persistence IOC: focus on commands, not documentation.
PERSIST_BAD_RE='(/dev/shm|xmrig|kinsing|kdevtmpfsi|cryptonight|cryptonote|monero|minexmr|nanopool|stratum|base64[[:space:]]+-d|curl[[:space:]].*\|[[:space:]]*(sh|bash)|wget[[:space:]].*\|[[:space:]]*(sh|bash)|bash[[:space:]]+-c|nohup[[:space:]].*&|logger-)'

# Exclude historical logs and common documentation / package false positives.
EXCLUDE_PATH_RE='(/root/incident_cleanup_|/tmp/cron_.*_20[0-9]{2}-[0-9]{2}-[0-9]{2}|/root/miniconda3/|/home/.*/miniconda3/|/home/.*/anaconda3/|/home/.*/\.snakemake/metadata/|/usr/share/doc/|/usr/share/man/|/usr/share/info/|/var/cache/|/var/lib/dpkg/info/)'

safe_grep_persist() {
  grep -RInE "$PERSIST_BAD_RE" "$@" 2>/dev/null | grep -Ev "$EXCLUDE_PATH_RE" || true
}

echo "============================================================"
echo " Miner rescue v3"
echo " Host: $HOST"
echo " Time: $TS"
echo " Mode: $([[ $REMEDIATE -eq 1 ]] && echo REMEDIATE || echo DRY-RUN)"
echo " Aggressive: $AGGRESSIVE"
echo " Install tools: $INSTALL_TOOLS"
echo " Report directory: $BASE"
echo "============================================================"

append_report "Host: $HOST"
append_report "Time: $TS"
append_report "Mode: $([[ $REMEDIATE -eq 1 ]] && echo REMEDIATE || echo DRY-RUN)"
append_report "Aggressive: $AGGRESSIVE"
append_report ""

section "Basic system info"
uname -a || true
uptime || true
free -h || true
df -h / /tmp /var/tmp /dev/shm 2>/dev/null || true
mount | grep ' /dev/shm ' || true

section "Top processes"
echo "---- top RSS ----"
ps -eo pid,ppid,user,%cpu,%mem,rss,vsz,etime,cmd --sort=-rss | head -50 || true
echo
echo "---- top CPU ----"
ps -eo pid,ppid,user,%cpu,%mem,rss,vsz,etime,cmd --sort=-%cpu | head -50 || true

kill_ioc_processes() {
  local stage="$1"
  local pids

  pids="$(ps -eo pid=,cmd= | grep -E "$PROC_BAD_RE" | grep -v grep | awk '{print $1}' | sort -u || true)"

  if [[ -z "$pids" ]]; then
    say "$stage: no suspicious IOC processes."
    return 0
  fi

  say "$stage: suspicious IOC PIDs: $pids"
  append_report "$stage IOC PIDs: $pids"

  for p in $pids; do
    echo "---- PID $p ----"
    ps -fp "$p" || true
    echo "exe:"
    readlink -f "/proc/$p/exe" 2>/dev/null || true
    echo "cmdline:"
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true
    echo
    echo "network:"
    ss -tunap 2>/dev/null | grep -F "pid=$p," || true
  done

  if [[ "$REMEDIATE" -eq 1 ]]; then
    say "$stage: killing suspicious processes."
    for p in $pids; do
      kill -9 "$p" 2>/dev/null || true
    done
  else
    say "$stage: DRY-RUN, not killing processes."
  fi
}

section "Initial IOC process cleanup"
kill_ioc_processes "initial"

section "Temporary directories before cleanup"
for d in /dev/shm /tmp /var/tmp; do
  [[ -d "$d" ]] || continue
  echo "---- $d ----"
  find "$d" -maxdepth 2 -xdev \( -type f -o -type l \) \
    -printf '%M %u %g %s %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort || true
done

section "Quarantine obvious temp IOC files"
TEMP_SUSPICIOUS="$(
  find /dev/shm /tmp /var/tmp -maxdepth 2 -xdev \( -type f -o -type l \) \
    \( -name '*xmrig*' -o -name '*kinsing*' -o -name '*kdevtmp*' -o -name '.*worker*' -o -name '.*k*ork*' -o -name '.*kw*' \) \
    -print 2>/dev/null || true
)"

if [[ -z "$TEMP_SUSPICIOUS" ]]; then
  say "No obvious temp IOC files by filename."
else
  echo "$TEMP_SUSPICIOUS"
  append_report "Temp IOC files found."
  if [[ "$REMEDIATE" -eq 1 ]]; then
    while IFS= read -r f; do
      [[ -n "$f" ]] && quarantine_file "$f"
    done <<< "$TEMP_SUSPICIOUS"
  else
    say "DRY-RUN: not quarantining temp files."
  fi
fi

clean_dev_shm() {
  section "Path-level /dev/shm cleanup"

  echo "Files and symlinks directly under /dev/shm:"
  find /dev/shm -maxdepth 1 \( -type f -o -type l \) -ls 2>/dev/null || true

  if [[ "$REMEDIATE" -eq 1 ]]; then
    say "Deleting all regular files and symlinks directly under /dev/shm."
    find /dev/shm -maxdepth 1 \( -type f -o -type l \) -print -delete 2>/dev/null || true
  else
    say "DRY-RUN: would delete all regular files and symlinks directly under /dev/shm."
  fi
}

clean_dev_shm

section "Cron persistence scan"
CRON_PATHS=(
  /etc/crontab
  /etc/cron.d
  /etc/cron.hourly
  /etc/cron.daily
  /etc/cron.weekly
  /etc/cron.monthly
  /var/spool/cron
  /var/spool/cron/crontabs
)

for path in "${CRON_PATHS[@]}"; do
  [[ -e "$path" ]] || continue
  echo "---- $path ----"
  safe_grep_persist "$path"
done

section "Clean user crontabs"
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
  tmp_before="/tmp/cron_${u}_${TS}.txt"
  tmp_after="/tmp/cron_${u}_${TS}.clean"

  if crontab -u "$u" -l > "$tmp_before" 2>/dev/null; then
    if grep -E "$PERSIST_BAD_RE" "$tmp_before" >/dev/null 2>&1; then
      say "Suspicious crontab for user: $u"
      cat "$tmp_before"
      cp "$tmp_before" "${BASE}/crontab_${u}.before"

      grep -Ev "$PERSIST_BAD_RE" "$tmp_before" > "$tmp_after" || true

      if [[ "$REMEDIATE" -eq 1 ]]; then
        say "Installing cleaned crontab for $u"
        crontab -u "$u" "$tmp_after"
        cp "$tmp_after" "${BASE}/crontab_${u}.after"
      else
        say "DRY-RUN: would clean crontab for $u."
      fi
    fi
  fi
done

section "Systemd service and timer scan"
SYSTEMD_PATHS=(
  /etc/systemd/system
  /lib/systemd/system
  /usr/lib/systemd/system
)

for p in "${SYSTEMD_PATHS[@]}"; do
  [[ -d "$p" ]] || continue
  echo "---- $p ----"
  safe_grep_persist "$p"
done

SYSTEMD_HITS="$(safe_grep_persist "${SYSTEMD_PATHS[@]}" | cut -d: -f1 | sort -u || true)"

if [[ -n "$SYSTEMD_HITS" ]]; then
  append_report "Suspicious systemd unit files detected."
  echo "$SYSTEMD_HITS"

  for f in $SYSTEMD_HITS; do
    [[ -f "$f" ]] || continue
    backup_file "$f"
    unit="$(basename "$f")"

    if [[ "$REMEDIATE" -eq 1 ]]; then
      say "Stopping/disabling suspicious systemd unit: $unit"
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

section "Active systemd timers"
systemctl list-timers --all || true

section "User systemd scan and cleanup"
USER_SYSTEMD_FILES="$(find /root /home -path '*/.config/systemd/user/*' -type f -print 2>/dev/null || true)"

if [[ -n "$USER_SYSTEMD_FILES" ]]; then
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue

    if grep -nE "$PERSIST_BAD_RE" "$f" 2>/dev/null | grep -Ev "$EXCLUDE_PATH_RE" >/dev/null; then
      say "Suspicious user systemd file: $f"
      grep -nE "$PERSIST_BAD_RE" "$f" 2>/dev/null || true
      backup_file "$f"

      if [[ "$REMEDIATE" -eq 1 ]]; then
        quarantine_file "$f"
      else
        say "DRY-RUN: would quarantine $f"
      fi
    fi
  done <<< "$USER_SYSTEMD_FILES"
else
  say "No user systemd files found."
fi

clean_rc_local_profiles_ldpreload() {
  section "rc.local / profile / ssh rc / ld.so.preload cleanup"

  local files=(
    /etc/rc.local
    /etc/profile
    /etc/bash.bashrc
    /etc/ld.so.preload
    /etc/ssh/sshrc
  )

  local f
  for f in /etc/profile.d/* /etc/init.d/* /root/.bashrc /root/.profile /root/.ssh/rc /home/*/.bashrc /home/*/.profile /home/*/.ssh/rc; do
    files+=("$f")
  done

  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue

    if grep -nE "$PERSIST_BAD_RE" "$f" 2>/dev/null | grep -Ev "$EXCLUDE_PATH_RE" >/dev/null; then
      say "Suspicious persistence file: $f"
      grep -nE "$PERSIST_BAD_RE" "$f" 2>/dev/null || true
      backup_file "$f"

      if [[ "$REMEDIATE" -eq 1 ]]; then
        if [[ "$f" == "/etc/ld.so.preload" ]]; then
          say "Clearing suspicious /etc/ld.so.preload"
          : > "$f"
        elif [[ "$f" == "/etc/rc.local" ]]; then
          say "Deleting suspicious lines from /etc/rc.local"
          sed -i.bak_${TS} -E "\#${PERSIST_BAD_RE}#d" "$f" || true
          chmod +x "$f" 2>/dev/null || true
        else
          say "Commenting suspicious lines in $f"
          sed -i.bak_${TS} -E "/$PERSIST_BAD_RE/s/^/# INCIDENT_DISABLED_${TS} /" "$f" || true
        fi
      else
        say "DRY-RUN: would clean suspicious lines in $f."
      fi
    fi
  done
}

clean_rc_local_profiles_ldpreload

section "at job scan"
if command -v atq >/dev/null 2>&1; then
  ATJOBS="$(atq 2>/dev/null | awk '{print $1}' || true)"
  atq || true

  if [[ -n "$ATJOBS" ]]; then
    for job in $ATJOBS; do
      echo "---- at job $job ----"
      if at -c "$job" 2>/dev/null | grep -E "$PERSIST_BAD_RE" >/dev/null; then
        say "Suspicious at job: $job"
        at -c "$job" 2>/dev/null | grep -nE "$PERSIST_BAD_RE" || true

        if [[ "$REMEDIATE" -eq 1 ]]; then
          atrm "$job" 2>/dev/null || true
        else
          say "DRY-RUN: would remove at job $job"
        fi
      fi
    done
  fi
else
  say "atq not available."
fi

section "SSH accounts, keys, and users needing credential rotation"

echo "---- UID 0 accounts ----"
UID0_USERS="$(awk -F: '$3==0 {print $1}' /etc/passwd 2>/dev/null | sort -u || true)"
awk -F: '$3==0 {print}' /etc/passwd || true

echo
echo "---- Login-capable users ----"
LOGIN_USERS="$(awk -F: '$7 !~ /(nologin|false)$/ {print $1}' /etc/passwd 2>/dev/null | sort -u || true)"
awk -F: '$7 !~ /(nologin|false)$/ {printf "%-20s uid=%-8s shell=%s\n",$1,$3,$7}' /etc/passwd || true

echo
echo "---- Users with non-locked password hash in /etc/shadow ----"
PASSWORD_USERS=""
if [[ -r /etc/shadow ]]; then
  PASSWORD_USERS="$(awk -F: '($2 != "!" && $2 != "*" && $2 !~ /^!/ && length($2)>0) {print $1}' /etc/shadow | sort -u || true)"
  echo "$PASSWORD_USERS"
else
  echo "Cannot read /etc/shadow"
fi

echo
echo "---- Users with authorized_keys ----"
KEY_USERS="$(
  find /root /home -path '*/.ssh/authorized_keys' -type f -printf '%h\n' 2>/dev/null \
    | sed -E 's#/.ssh$##; s#^/home/##; s#^/root$#root#' | sort -u || true
)"

find /root /home -path '*/.ssh/authorized_keys' -type f \
  -exec echo "### {}" \; \
  -exec sh -c 'wc -l "$1"; sed -n "1,5p" "$1"' sh {} \; 2>/dev/null || true

echo
echo "---- Sudo/admin group users ----"
SUDO_USERS=""
if getent group sudo >/dev/null 2>&1; then
  SUDO_USERS+=" $(getent group sudo | awk -F: '{print $4}' | tr ',' ' ')"
fi
if getent group wheel >/dev/null 2>&1; then
  SUDO_USERS+=" $(getent group wheel | awk -F: '{print $4}' | tr ',' ' ')"
fi
SUDO_USERS="$(echo "$SUDO_USERS" | tr ' ' '\n' | sed '/^$/d' | sort -u || true)"
echo "$SUDO_USERS"

echo
echo "---- Recent login users ----"
RECENT_USERS="$(last -w 2>/dev/null | awk 'NF>=1 && $1 !~ /^(reboot|wtmp|shutdown)$/ {print $1}' | head -100 | sort -u || true)"
last -a | head -80 || true

CREDENTIAL_USERS="$(
  {
    echo "$UID0_USERS"
    echo "$LOGIN_USERS"
    echo "$PASSWORD_USERS"
    echo "$KEY_USERS"
    echo "$SUDO_USERS"
    echo "$RECENT_USERS"
  } | tr ' ' '\n' | sed '/^$/d' | sort -u
)"

append_report "Users recommended for credential review/change:"
append_report "$CREDENTIAL_USERS"
append_report ""

section "Network listeners"
ss -tulpen || true

section "Docker audit"
if command -v docker >/dev/null 2>&1; then
  echo "---- docker ps ----"
  docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" || true

  echo
  echo "---- docker risky mounts / privileged ----"
  DOCKER_AUDIT="${BASE}/docker_audit.txt"

  if [[ -n "$(docker ps -q 2>/dev/null || true)" ]]; then
    docker inspect $(docker ps -q) --format '### {{.Name}}
Privileged={{.HostConfig.Privileged}}
Network={{.HostConfig.NetworkMode}}
PidMode={{.HostConfig.PidMode}}
Mounts={{json .Mounts}}
' 2>/dev/null | tee "$DOCKER_AUDIT" || true

    echo
    echo "---- docker risky quick matches ----"
    grep -E 'Privileged=true|docker.sock|/var/spool/cron|/etc"|/root"|/host|"/",' "$DOCKER_AUDIT" || true
  else
    say "No running Docker containers."
  fi
else
  say "Docker not installed."
fi

section "Remount and persist /dev/shm hardening"
echo "Before:"
mount | grep ' /dev/shm ' || true

if [[ "$REMEDIATE" -eq 1 ]]; then
  say "Remounting /dev/shm with noexec,nosuid,nodev"
  mount -o remount,noexec,nosuid,nodev /dev/shm 2>/dev/null || true

  if ! grep -qE '^[^#].*\s/dev/shm\s' /etc/fstab; then
    backup_file /etc/fstab
    echo 'tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0' >> /etc/fstab
    say "Added /dev/shm hardening entry to /etc/fstab"
  else
    say "/etc/fstab already has /dev/shm entry. Please manually ensure it includes noexec,nosuid,nodev."
  fi
else
  say "DRY-RUN: would remount /dev/shm noexec,nosuid,nodev and persist if absent."
fi

echo "After:"
mount | grep ' /dev/shm ' || true

section "Optional aggressive service stop"
if [[ "$AGGRESSIVE" -eq 1 ]]; then
  for svc in xrdp xrdp-sesman anydesk vncserver tigervncserver; do
    if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service"; then
      say "Aggressive mode: stopping/disabling $svc"
      if [[ "$REMEDIATE" -eq 1 ]]; then
        systemctl disable --now "$svc" 2>/dev/null || true
      fi
    fi
  done
else
  say "Not stopping xrdp/anydesk/vnc automatically. Use --aggressive if desired."
fi

section "Install minimal hardening tools"
if [[ "$INSTALL_TOOLS" -eq 1 || "$REMEDIATE" -eq 1 ]]; then
  if command -v apt-get >/dev/null 2>&1; then
    say "Installing fail2ban/lsof/psmisc/inotify-tools if apt is available."
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y fail2ban lsof psmisc inotify-tools >/dev/null 2>&1 || true
    systemctl enable --now fail2ban 2>/dev/null || true
  else
    say "No apt-get found. Please install fail2ban/lsof/psmisc manually if needed."
  fi
else
  say "Skipping tool installation."
fi

section "Final force cleanup loop"

for round in 1 2 3; do
  say "Final cleanup round $round"

  kill_ioc_processes "final-round-$round"

  if [[ "$REMEDIATE" -eq 1 ]]; then
    say "Final round $round: deleting all regular files and symlinks directly under /dev/shm."
    find /dev/shm -maxdepth 1 \( -type f -o -type l \) -print -delete 2>/dev/null || true

    say "Final round $round: cleaning rc.local/profile persistence again."
    clean_rc_local_profiles_ldpreload >/dev/null 2>&1 || true

    say "Final round $round: remounting /dev/shm noexec,nosuid,nodev."
    mount -o remount,noexec,nosuid,nodev /dev/shm 2>/dev/null || true

    find "$QUAR" -type f -exec chmod 000 {} \; 2>/dev/null || true
  fi

  sleep 2
done

section "Final verification"

FINAL_PROC="$(ps -eo pid,ppid,user,%cpu,%mem,etime,cmd | grep -E "$PROC_BAD_RE" | grep -v grep || true)"
FINAL_SHM="$(find /dev/shm -maxdepth 1 \( -type f -o -type l \) -ls 2>/dev/null || true)"

FINAL_CRON="$(
  for p in "${CRON_PATHS[@]}"; do
    [[ -e "$p" ]] && safe_grep_persist "$p"
  done || true
)"

FINAL_SYSTEMD="$(safe_grep_persist /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system 2>/dev/null || true)"

FINAL_RC_PROFILE="$(
  {
    [[ -f /etc/rc.local ]] && grep -nE "$PERSIST_BAD_RE" /etc/rc.local 2>/dev/null
    [[ -f /etc/profile ]] && grep -nE "$PERSIST_BAD_RE" /etc/profile 2>/dev/null
    [[ -f /etc/bash.bashrc ]] && grep -nE "$PERSIST_BAD_RE" /etc/bash.bashrc 2>/dev/null
    [[ -f /etc/ld.so.preload ]] && grep -nE "$PERSIST_BAD_RE" /etc/ld.so.preload 2>/dev/null
    grep -RInE "$PERSIST_BAD_RE" /etc/profile.d /etc/init.d /root/.bashrc /root/.profile /root/.ssh/rc /home/*/.bashrc /home/*/.profile /home/*/.ssh/rc 2>/dev/null
  } | grep -Ev "$EXCLUDE_PATH_RE" || true
)"

echo "---- final IOC processes ----"
if [[ -n "$FINAL_PROC" ]]; then
  echo "$FINAL_PROC"
else
  echo "clean"
fi

echo "---- final /dev/shm files/symlinks ----"
if [[ -n "$FINAL_SHM" ]]; then
  echo "$FINAL_SHM"
else
  echo "clean"
fi

echo "---- final cron persistence ----"
if [[ -n "$FINAL_CRON" ]]; then
  echo "$FINAL_CRON"
else
  echo "clean"
fi

echo "---- final systemd persistence ----"
if [[ -n "$FINAL_SYSTEMD" ]]; then
  echo "$FINAL_SYSTEMD"
else
  echo "clean"
fi

echo "---- final rc/profile persistence ----"
if [[ -n "$FINAL_RC_PROFILE" ]]; then
  echo "$FINAL_RC_PROFILE"
else
  echo "clean"
fi

section "Final status"

STATUS="CLEAN"
REASONS=()

if [[ -n "$FINAL_PROC" ]]; then
  STATUS="INFECTED"
  REASONS+=("仍发现可疑进程")
fi

if [[ -n "$FINAL_CRON" ]]; then
  STATUS="INFECTED"
  REASONS+=("仍发现可疑 cron 持久化")
fi

if [[ -n "$FINAL_SYSTEMD" ]]; then
  STATUS="INFECTED"
  REASONS+=("仍发现可疑 systemd 持久化")
fi

if [[ -n "$FINAL_RC_PROFILE" ]]; then
  STATUS="INFECTED"
  REASONS+=("仍发现 rc.local/profile/ssh rc/ld.so.preload 持久化")
fi

if [[ -n "$FINAL_SHM" ]]; then
  if [[ "$STATUS" != "INFECTED" ]]; then
    STATUS="WARNING"
  fi
  REASONS+=("/dev/shm 下仍有普通文件或软链接")
fi

if [[ "$REMEDIATE" -eq 0 ]]; then
  if [[ "$STATUS" == "CLEAN" ]]; then
    STATUS="DRY-RUN-CLEAN"
  else
    STATUS="DRY-RUN-WARNING"
  fi
fi

echo "STATUS: $STATUS"
append_report "Final status: $STATUS"

if [[ "${#REASONS[@]}" -gt 0 ]]; then
  echo "Reasons:"
  append_report "Reasons:"
  for r in "${REASONS[@]}"; do
    echo " - $r"
    append_report " - $r"
  done
else
  echo "Reasons: 未发现当前运行态 IOC 或持久化 IOC。"
  append_report "Reasons: 未发现当前运行态 IOC 或持久化 IOC。"
fi

echo
echo "Users recommended for password/key rotation:"
echo "$CREDENTIAL_USERS" | sed 's/^/ - /'

append_report ""
append_report "Users recommended for password/key rotation:"
echo "$CREDENTIAL_USERS" | sed 's/^/ - /' >> "$REPORT"

echo
echo "Suggested next actions:"
if [[ "$STATUS" == "CLEAN" || "$STATUS" == "DRY-RUN-CLEAN" ]]; then
  cat <<EOF
 - 当前已知 /dev/shm + cron/rc.local/systemd/profile 型矿机未再发现。
 - 建议继续观察 10-30 分钟：
   watch -n 10 'date; pgrep -af "/dev/shm|xmrig|kinsing|kdevtmpfsi|cryptonight|monero|\\.kw" || echo clean; sudo find /dev/shm -maxdepth 1 \\( -type f -o -type l \\) -ls'
 - 立即更换上面列出的用户密码或 SSH key，尤其是 root、sudo 用户、近期登录用户。
 - 收缩公网端口，重点检查 SSH、1Panel、宝塔、xrdp、AnyDesk、Node-RED、MQTT、Grafana、Zabbix、Home Assistant。
EOF
else
  cat <<EOF
 - 仍有风险，请不要认为清理完成。
 - 如果是 DRY-RUN，请执行：
   sudo bash $0 --remediate
 - 如果已经是 --remediate 仍有 IOC，请抓取复活源：
   sudo apt install -y inotify-tools
   sudo inotifywait -m /dev/shm /tmp /var/tmp -e create -e moved_to -e close_write -e attrib
 - 同时另开窗口观察：
   watch -n 1 'ps -eo pid,ppid,user,%cpu,%mem,etime,cmd --sort=-%cpu | head -50'
EOF
fi

echo
echo "Report directory: $BASE"
echo "Log file: $LOG"
echo "Summary: $REPORT"
echo "============================================================"

exit 0