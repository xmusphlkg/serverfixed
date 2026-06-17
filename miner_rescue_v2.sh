#!/usr/bin/env bash
set -Eeuo pipefail

# miner_rescue_v2.sh
# Defensive incident-response script for /dev/shm cron/systemd miner infections.
#
# Default mode: audit only, no destructive changes.
#
# Common usage:
#   sudo bash miner_rescue_v2.sh
#   sudo bash miner_rescue_v2.sh --remediate
#   sudo bash miner_rescue_v2.sh --remediate --aggressive
#
# SSH key rotation:
#   sudo bash miner_rescue_v2.sh --remediate --new-admin-key-file /path/to/new.pub --append-authorized-key
#   sudo bash miner_rescue_v2.sh --remediate --new-admin-key-file /path/to/new.pub --replace-authorized-keys --users root,mpi
#
# Safer default:
#   - Does not delete SSH keys unless --replace-authorized-keys is explicitly given.
#   - Does not disable password login unless --disable-ssh-password is explicitly given.
#   - Does not stop xrdp/anydesk unless --aggressive is given.
#
# Tested target:
#   Debian/Ubuntu-like Linux. Most checks also work on other systemd distributions.

REMEDIATE=0
AGGRESSIVE=0
APPEND_KEY=0
REPLACE_KEYS=0
DISABLE_SSH_PASSWORD=0
LOCK_PASSWORDS=0
NEW_PUBKEY_FILE=""
USER_CSV=""
KEEP_EVIDENCE=1

for arg in "$@"; do
  case "$arg" in
    --remediate)
      REMEDIATE=1
      ;;
    --aggressive)
      AGGRESSIVE=1
      ;;
    --append-authorized-key)
      APPEND_KEY=1
      ;;
    --replace-authorized-keys)
      REPLACE_KEYS=1
      ;;
    --disable-ssh-password)
      DISABLE_SSH_PASSWORD=1
      ;;
    --lock-passwords)
      LOCK_PASSWORDS=1
      ;;
    --delete-evidence)
      KEEP_EVIDENCE=0
      ;;
    --new-admin-key-file=*)
      NEW_PUBKEY_FILE="${arg#*=}"
      ;;
    --users=*)
      USER_CSV="${arg#*=}"
      ;;
    -h|--help)
      cat <<'EOF'
Usage:
  sudo bash miner_rescue_v2.sh [options]

Cleanup:
  --remediate                 Actually kill processes, clean cron, harden /dev/shm
  --aggressive                Also stop/disable xrdp and anydesk
  --delete-evidence           Delete quarantine/evidence at the end, not recommended

SSH key rotation:
  --new-admin-key-file=FILE   New trusted SSH public key to install
  --append-authorized-key     Append the new public key to selected users
  --replace-authorized-keys   Replace selected users' authorized_keys with the new key
  --users=root,mpi            Users for key operation. If omitted, root + human login users are selected.

SSH hardening:
  --disable-ssh-password      Set PasswordAuthentication no and restart SSH
  --lock-passwords            Lock password auth for selected users with passwd -l

Examples:
  sudo bash miner_rescue_v2.sh
  sudo bash miner_rescue_v2.sh --remediate
  sudo bash miner_rescue_v2.sh --remediate --aggressive
  sudo bash miner_rescue_v2.sh --remediate --new-admin-key-file /tmp/new.pub --append-authorized-key
  sudo bash miner_rescue_v2.sh --remediate --new-admin-key-file /tmp/new.pub --replace-authorized-keys --users root,mpi
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
mkdir -p "$BASE" "$QUAR"

exec > >(tee -a "$LOG") 2>&1

say() {
  echo "[$(date +%F_%T)] $*"
}

section() {
  echo
  echo "==================== $* ===================="
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
  else
    say "DRY-RUN: would quarantine $f"
  fi
}

# Strong indicators. Do not include generic "/tmp" here; it creates too many false positives.
IOC_PROCESS_RE='(/dev/shm|xmrig|kinsing|kdevtmpfsi|cryptonight|monero|stratum|nanopool|minexmr|pool\.)'

# Persistence indicators. Broader than process scan, but still excludes generic docs.
IOC_PERSIST_RE='(/dev/shm|xmrig|kinsing|kdevtmpfsi|cryptonight|monero|stratum|nanopool|minexmr|base64[[:space:]]+-d|curl[^#;|]*\|[[:space:]]*(sh|bash)|wget[^#;|]*\|[[:space:]]*(sh|bash))'

CRON_BAD_RE="$IOC_PERSIST_RE"

echo "============================================================"
echo " Miner rescue v2"
echo " Host: $HOST"
echo " Time: $TS"
echo " Mode: $([[ $REMEDIATE -eq 1 ]] && echo REMEDIATE || echo DRY-RUN)"
echo " Aggressive: $AGGRESSIVE"
echo " Output: $BASE"
echo "============================================================"

section "Basic system information"
uname -a || true
uptime || true
free -h || true
df -h / /tmp /var/tmp /dev/shm 2>/dev/null || true
mount | grep ' /dev/shm ' || true

section "Login-capable users"
echo "Users with UID 0:"
awk -F: '$3==0 {print}' /etc/passwd || true
echo
echo "Users with interactive shells:"
awk -F: '($3==0 || $3>=1000) && $7 !~ /(nologin|false|sync|shutdown|halt)$/ {print $1":"$3":"$6":"$7}' /etc/passwd || true
echo
echo "Suggested users to review/change password/key:"
awk -F: '($3==0 || $3>=1000) && $7 !~ /(nologin|false|sync|shutdown|halt)$/ {print $1}' /etc/passwd | sort -u | tee "${BASE}/suggested_users.txt" || true

section "Current top processes"
echo "Top RSS:"
ps -eo pid,ppid,user,%cpu,%mem,rss,vsz,etime,cmd --sort=-rss | head -40 || true
echo
echo "Top CPU:"
ps -eo pid,ppid,user,%cpu,%mem,rss,vsz,etime,cmd --sort=-%cpu | head -40 || true

section "Known malicious process scan"
BAD_PIDS="$(ps -eo pid=,cmd= | grep -E "$IOC_PROCESS_RE" | grep -v grep | awk '{print $1}' | sort -u || true)"

if [[ -z "$BAD_PIDS" ]]; then
  say "No active IOC process found."
else
  say "Suspicious process PIDs found: $BAD_PIDS"
  for p in $BAD_PIDS; do
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
    say "Killing suspicious processes..."
    for p in $BAD_PIDS; do
      kill -9 "$p" 2>/dev/null || true
    done
  else
    say "DRY-RUN: not killing processes."
  fi
fi

section "Temporary directory scan"
for d in /dev/shm /tmp /var/tmp; do
  [[ -d "$d" ]] || continue
  echo "---- $d ----"
  find "$d" -maxdepth 2 -xdev \( -type f -o -type l \) -printf '%M %u %g %s %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort || true
done

section "Quarantine obvious malicious temp files"
TEMP_SUSPICIOUS="$(find /dev/shm /tmp /var/tmp -maxdepth 2 -xdev \( -type f -o -type l \) \
  \( -name '.*worker*' -o -name '*xmrig*' -o -name '*kinsing*' -o -name '*kdevtmp*' -o -name '.*k*ork*' \) \
  -print 2>/dev/null || true)"

if [[ -n "$TEMP_SUSPICIOUS" ]]; then
  echo "$TEMP_SUSPICIOUS"
  while IFS= read -r f; do
    [[ -n "$f" ]] && quarantine_file "$f"
  done <<< "$TEMP_SUSPICIOUS"
else
  say "No obvious malicious temp files by filename."
fi

section "Force-clean /dev/shm regular files"
if [[ "$REMEDIATE" -eq 1 ]]; then
  say "Deleting all regular files and symlinks directly under /dev/shm"
  find /dev/shm -maxdepth 1 \( -type f -o -type l \) -print -delete 2>/dev/null || true
else
  say "DRY-RUN: would delete regular files and symlinks directly under /dev/shm"
  find /dev/shm -maxdepth 1 \( -type f -o -type l \) -ls 2>/dev/null || true
fi

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
  echo "---- scanning $path ----"
  grep -RInE "$IOC_PERSIST_RE" "$path" 2>/dev/null || true
done

section "Clean user crontabs"
USERS_TO_CHECK=""
if [[ -d /var/spool/cron/crontabs ]]; then
  USERS_TO_CHECK+=" $(ls /var/spool/cron/crontabs 2>/dev/null || true)"
fi
if [[ -d /var/spool/cron ]]; then
  USERS_TO_CHECK+=" $(find /var/spool/cron -maxdepth 1 -type f -printf '%f\n' 2>/dev/null || true)"
fi
USERS_TO_CHECK+=" $(awk -F: '($3==0 || $3>=1000) && $7 !~ /(nologin|false|sync|shutdown|halt)$/ {print $1}' /etc/passwd 2>/dev/null || true)"
USERS_TO_CHECK="$(echo "$USERS_TO_CHECK" | tr ' ' '\n' | sed '/^$/d' | sort -u)"

for u in $USERS_TO_CHECK; do
  tmp_before="/tmp/cron_${u}_${TS}.txt"
  tmp_after="/tmp/cron_${u}_${TS}.clean"

  if crontab -u "$u" -l >"$tmp_before" 2>/dev/null; then
    if grep -E "$CRON_BAD_RE" "$tmp_before" >/dev/null 2>&1; then
      say "Suspicious crontab found for user: $u"
      cat "$tmp_before"
      cp "$tmp_before" "${BASE}/crontab_${u}.before"

      grep -Ev "$CRON_BAD_RE" "$tmp_before" >"$tmp_after" || true

      if [[ "$REMEDIATE" -eq 1 ]]; then
        say "Installing cleaned crontab for $u"
        crontab -u "$u" "$tmp_after"
        cp "$tmp_after" "${BASE}/crontab_${u}.after"
      else
        say "DRY-RUN: would clean crontab for $u"
      fi
    fi
  fi
done

section "Systemd persistence scan"
SYSTEMD_PATHS=(
  /etc/systemd/system
  /lib/systemd/system
  /usr/lib/systemd/system
  /var/lib/systemd
)

SYSTEMD_HITS=""
for path in "${SYSTEMD_PATHS[@]}"; do
  [[ -e "$path" ]] || continue
  hits="$(grep -RIlE "$IOC_PERSIST_RE" "$path" 2>/dev/null || true)"
  [[ -n "$hits" ]] && SYSTEMD_HITS+=$'\n'"$hits"
done
SYSTEMD_HITS="$(echo "$SYSTEMD_HITS" | sed '/^$/d' | sort -u || true)"

if [[ -z "$SYSTEMD_HITS" ]]; then
  say "No suspicious systemd unit files found."
else
  echo "$SYSTEMD_HITS"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    echo "---- $f ----"
    grep -nE "$IOC_PERSIST_RE" "$f" 2>/dev/null || true
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
  done <<< "$SYSTEMD_HITS"

  if [[ "$REMEDIATE" -eq 1 ]]; then
    systemctl daemon-reload || true
  fi
fi

section "User systemd scan"
USER_SYSTEMD_HITS="$(find /root /home -path '*/.config/systemd/user/*' -type f -maxdepth 8 -print 2>/dev/null | while read -r f; do grep -IlE "$IOC_PERSIST_RE" "$f" 2>/dev/null || true; done | sort -u || true)"
if [[ -z "$USER_SYSTEMD_HITS" ]]; then
  say "No suspicious user systemd unit files found."
else
  echo "$USER_SYSTEMD_HITS"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    echo "---- $f ----"
    grep -nE "$IOC_PERSIST_RE" "$f" 2>/dev/null || true
    backup_file "$f"
    if [[ "$REMEDIATE" -eq 1 ]]; then
      quarantine_file "$f"
    fi
  done <<< "$USER_SYSTEMD_HITS"
fi

section "at jobs scan"
if command -v atq >/dev/null 2>&1; then
  atq || true
fi
if [[ -d /var/spool/at ]]; then
  grep -RInE "$IOC_PERSIST_RE" /var/spool/at 2>/dev/null || true
fi
if [[ -d /var/spool/atjobs ]]; then
  grep -RInE "$IOC_PERSIST_RE" /var/spool/atjobs 2>/dev/null || true
fi

section "init/profile/rc persistence scan"
PROFILE_PATHS=(
  /etc/init.d
  /etc/rc.local
  /etc/profile
  /etc/bash.bashrc
  /etc/profile.d
  /etc/ssh/sshrc
  /root/.bashrc
  /root/.profile
  /root/.ssh/rc
)

for hp in /home/*/.bashrc /home/*/.profile /home/*/.ssh/rc; do
  PROFILE_PATHS+=("$hp")
done

for f in "${PROFILE_PATHS[@]}"; do
  [[ -e "$f" ]] || continue
  if grep -RInE "$IOC_PERSIST_RE" "$f" >/dev/null 2>&1; then
    say "Suspicious init/profile/rc hit: $f"
    grep -RInE "$IOC_PERSIST_RE" "$f" 2>/dev/null || true
    backup_file "$f"

    if [[ "$REMEDIATE" -eq 1 && -f "$f" ]]; then
      say "Commenting suspicious lines in $f"
      sed -i.bak_${TS} -E "/$IOC_PERSIST_RE/s/^/# INCIDENT_DISABLED_${TS} /" "$f" || true
    else
      say "DRY-RUN: would comment suspicious lines in $f"
    fi
  fi
done

section "ld.so.preload audit"
if [[ -e /etc/ld.so.preload ]]; then
  say "/etc/ld.so.preload exists:"
  cat /etc/ld.so.preload || true
  if grep -E "$IOC_PERSIST_RE|/tmp|/var/tmp|/dev/shm" /etc/ld.so.preload >/dev/null 2>&1; then
    backup_file /etc/ld.so.preload
    if [[ "$REMEDIATE" -eq 1 ]]; then
      say "Suspicious /etc/ld.so.preload found; quarantining."
      quarantine_file /etc/ld.so.preload
    fi
  fi
else
  say "/etc/ld.so.preload does not exist."
fi

section "SSH authorized_keys audit"
find /root /home -path '*/.ssh/authorized_keys' -type f -exec echo "---- {} ----" \; -exec cat {} \; 2>/dev/null || true

section "SSH key rotation / installation"
select_users_for_key_rotation() {
  if [[ -n "$USER_CSV" ]]; then
    echo "$USER_CSV" | tr ',' '\n' | sed '/^$/d' | sort -u
  else
    awk -F: '($3==0 || $3>=1000) && $7 !~ /(nologin|false|sync|shutdown|halt)$/ {print $1}' /etc/passwd | sort -u
  fi
}

if [[ -n "$NEW_PUBKEY_FILE" ]]; then
  if [[ ! -f "$NEW_PUBKEY_FILE" ]]; then
    echo "[FATAL] New public key file not found: $NEW_PUBKEY_FILE"
    exit 1
  fi

  if ! grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ' "$NEW_PUBKEY_FILE"; then
    echo "[FATAL] Public key file does not look like an SSH public key: $NEW_PUBKEY_FILE"
    exit 1
  fi

  KEY_CONTENT="$(cat "$NEW_PUBKEY_FILE")"
  KEY_USERS="$(select_users_for_key_rotation)"

  echo "Selected users for SSH key operation:"
  echo "$KEY_USERS"

  if [[ "$APPEND_KEY" -eq 0 && "$REPLACE_KEYS" -eq 0 ]]; then
    say "New key provided, but neither --append-authorized-key nor --replace-authorized-keys was set. No key changes made."
  else
    for u in $KEY_USERS; do
      home_dir="$(getent passwd "$u" | awk -F: '{print $6}')"
      [[ -n "$home_dir" && -d "$home_dir" ]] || continue

      ssh_dir="$home_dir/.ssh"
      auth="$ssh_dir/authorized_keys"

      say "Processing authorized_keys for user: $u ($auth)"

      if [[ "$REMEDIATE" -eq 1 ]]; then
        mkdir -p "$ssh_dir"
        chmod 700 "$ssh_dir"
        touch "$auth"
        chmod 600 "$auth"
        chown -R "$u":"$(id -gn "$u" 2>/dev/null || echo "$u")" "$ssh_dir" 2>/dev/null || true

        backup_file "$auth"
        cp -a "$auth" "${BASE}/authorized_keys_${u}.before" 2>/dev/null || true

        if [[ "$REPLACE_KEYS" -eq 1 ]]; then
          say "Replacing authorized_keys for $u with the new key"
          printf '%s\n' "$KEY_CONTENT" > "$auth"
        elif [[ "$APPEND_KEY" -eq 1 ]]; then
          say "Appending new key for $u if absent"
          grep -qxF "$KEY_CONTENT" "$auth" 2>/dev/null || printf '%s\n' "$KEY_CONTENT" >> "$auth"
        fi

        chmod 600 "$auth"
        chown "$u":"$(id -gn "$u" 2>/dev/null || echo "$u")" "$auth" 2>/dev/null || true
        cp -a "$auth" "${BASE}/authorized_keys_${u}.after" 2>/dev/null || true
      else
        say "DRY-RUN: would update key for $u"
      fi
    done
  fi
else
  say "No --new-admin-key-file provided; not rotating SSH keys."
fi

section "Optional password locking for selected users"
if [[ "$LOCK_PASSWORDS" -eq 1 ]]; then
  KEY_USERS="$(select_users_for_key_rotation)"
  echo "Selected users for password lock:"
  echo "$KEY_USERS"

  for u in $KEY_USERS; do
    if [[ "$u" == "root" ]]; then
      say "Skipping root password lock by default. Lock root manually after confirming emergency access."
      continue
    fi

    if [[ "$REMEDIATE" -eq 1 ]]; then
      say "Locking password for user: $u"
      passwd -l "$u" 2>/dev/null || true
    else
      say "DRY-RUN: would lock password for user: $u"
    fi
  done
else
  say "Not locking user passwords. Use --lock-passwords explicitly."
fi

section "SSH daemon hardening"
if [[ "$DISABLE_SSH_PASSWORD" -eq 1 ]]; then
  backup_file /etc/ssh/sshd_config
  if [[ "$REMEDIATE" -eq 1 ]]; then
    say "Disabling SSH password authentication."
    sed -i.bak_${TS} -E \
      -e 's/^[#[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication no/' \
      -e 's/^[#[:space:]]*PubkeyAuthentication[[:space:]].*/PubkeyAuthentication yes/' \
      -e 's/^[#[:space:]]*PermitRootLogin[[:space:]].*/PermitRootLogin prohibit-password/' \
      /etc/ssh/sshd_config

    grep -qE '^PasswordAuthentication[[:space:]]+no' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
    grep -qE '^PubkeyAuthentication[[:space:]]+yes' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
    grep -qE '^PermitRootLogin[[:space:]]+prohibit-password' /etc/ssh/sshd_config || echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config

    sshd -t 2>/dev/null || ssh -t 2>/dev/null || true

    if systemctl list-unit-files | grep -q '^ssh.service'; then
      systemctl restart ssh || true
    elif systemctl list-unit-files | grep -q '^sshd.service'; then
      systemctl restart sshd || true
    fi
  else
    say "DRY-RUN: would disable SSH password authentication."
  fi
else
  say "Not changing SSH password authentication. Use --disable-ssh-password explicitly after testing new key login."
fi

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
  echo "---- docker.sock / host mount quick check ----"
  docker inspect $(docker ps -q) --format '{{.Name}} {{json .Mounts}}' 2>/dev/null | grep -E 'docker.sock|/var/spool/cron|/etc"|/root"|"/",' || true
else
  say "Docker not installed or not available."
fi

section "Network listeners"
ss -tulpen || true

section "Remount /dev/shm noexec,nosuid,nodev"
mount | grep ' /dev/shm ' || true

if [[ "$REMEDIATE" -eq 1 ]]; then
  say "Remounting /dev/shm with noexec,nosuid,nodev"
  mount -o remount,noexec,nosuid,nodev /dev/shm 2>/dev/null || true

  if ! grep -qE '^[^#].*\s/dev/shm\s' /etc/fstab; then
    backup_file /etc/fstab
    echo 'tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0' >> /etc/fstab
    say "Added /dev/shm hardening line to /etc/fstab."
  else
    say "/etc/fstab already has /dev/shm entry. Please manually ensure it contains noexec,nosuid,nodev."
  fi
else
  say "DRY-RUN: would remount /dev/shm noexec,nosuid,nodev."
fi

mount | grep ' /dev/shm ' || true

section "Optional aggressive service stop"
if [[ "$AGGRESSIVE" -eq 1 ]]; then
  for svc in xrdp xrdp-sesman anydesk vncserver; do
    if systemctl list-unit-files | awk '{print $1}' | grep -qx "${svc}.service"; then
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
if [[ "$REMEDIATE" -eq 1 ]]; then
  if command -v apt-get >/dev/null 2>&1; then
    say "Installing fail2ban/lsof/psmisc if apt is available."
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y fail2ban lsof psmisc >/dev/null 2>&1 || true
    systemctl enable --now fail2ban 2>/dev/null || true
  else
    say "apt-get not available; install fail2ban manually if needed."
  fi
else
  say "DRY-RUN: would install fail2ban/lsof/psmisc on apt systems."
fi

section "Final force cleanup loop"
for round in 1 2 3; do
  say "Final cleanup round $round"

  FINAL_PIDS="$(ps -eo pid=,cmd= | grep -E "$IOC_PROCESS_RE" | grep -v grep | awk '{print $1}' | sort -u || true)"

  if [[ -n "$FINAL_PIDS" ]]; then
    say "Remaining suspicious PIDs: $FINAL_PIDS"
    for p in $FINAL_PIDS; do
      echo "---- PID $p ----"
      ps -fp "$p" || true
      readlink -f "/proc/$p/exe" 2>/dev/null || true
      tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true
      echo

      if [[ "$REMEDIATE" -eq 1 ]]; then
        kill -9 "$p" 2>/dev/null || true
      fi
    done
  else
    say "No remaining suspicious PIDs in this round."
  fi

  if [[ "$REMEDIATE" -eq 1 ]]; then
    find /dev/shm -maxdepth 1 \( -type f -o -type l \) -print -delete 2>/dev/null || true
    mount -o remount,noexec,nosuid,nodev /dev/shm 2>/dev/null || true
    find "$QUAR" -type f -exec chmod 000 {} \; 2>/dev/null || true
  fi

  sleep 2
done

section "Final verification"
echo "---- active IOC processes ----"
ps -eo pid,ppid,user,%cpu,%mem,etime,cmd | grep -E "$IOC_PROCESS_RE" | grep -v grep || true

echo
echo "---- /dev/shm files ----"
find /dev/shm -maxdepth 1 \( -type f -o -type l \) -ls 2>/dev/null || true

echo
echo "---- persistence IOC scan, excluding incident logs ----"
for path in \
  /etc/crontab /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly \
  /var/spool/cron /var/spool/cron/crontabs \
  /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system \
  /etc/init.d /etc/rc.local /etc/profile.d; do
  [[ -e "$path" ]] || continue
  grep -RInE "$IOC_PERSIST_RE" "$path" 2>/dev/null || true
done

section "Evidence handling"
if [[ "$KEEP_EVIDENCE" -eq 1 ]]; then
  say "Evidence kept at: $BASE"
  find "$QUAR" -type f -exec chmod 000 {} \; 2>/dev/null || true
else
  say "Deleting evidence directory because --delete-evidence was set."
  rm -rf "$BASE" 2>/dev/null || true
fi

section "Memory"
free -h || true

echo
echo "============================================================"
echo "Done."
echo "Report/log directory: $BASE"
echo
if [[ "$REMEDIATE" -eq 0 ]]; then
  echo "This was DRY-RUN only. Re-run with:"
  echo "  sudo bash $0 --remediate"
fi
echo "Recommended final checks:"
echo "  pgrep -af '/dev/shm|xmrig|kinsing|kdevtmpfsi|cryptonight|monero|\\.kw'"
echo "  sudo find /dev/shm -maxdepth 1 \\( -type f -o -type l \\) -ls"
echo "  sudo crontab -l"
echo "============================================================"