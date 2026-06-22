#!/usr/bin/env bash
set -Eeuo pipefail

# Wazuh Agent Linux installer for lab deployment
# Usage:
#   sudo SERVER=192.168.10.102 bash install-linux.sh
# Optional variables:
#   AGENT_NAME=$(hostname -s) GROUP=default TIMEZONE=Asia/Shanghai TEST_FIM=1

SERVER="${SERVER:-${WAZUH_MANAGER:-}}"
AGENT_NAME="${AGENT_NAME:-${WAZUH_AGENT_NAME:-$(hostname -s)}}"
GROUP="${GROUP:-${WAZUH_AGENT_GROUP:-default}}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
PROTOCOL="${PROTOCOL:-tcp}"
TEST_FIM="${TEST_FIM:-1}"
REPORT_DIR="${REPORT_DIR:-/var/tmp/wazuh-agent-install-report}"

log() { echo; echo "========== $* =========="; }
warn() { echo "[WARN] $*" >&2; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

[[ -n "$SERVER" ]] || fail "SERVER 未设置。示例：sudo SERVER=192.168.10.102 bash install-linux.sh"
[[ "$(id -u)" -eq 0 ]] || fail "请用 root 运行，或使用：sudo SERVER=$SERVER bash install-linux.sh"

mkdir -p "$REPORT_DIR"
exec > >(tee -a "$REPORT_DIR/install-$(date +%F_%H%M%S).log") 2>&1

log "Basic information"
echo "hostname       : $(hostname -f 2>/dev/null || hostname)"
echo "agent_name     : $AGENT_NAME"
echo "group          : $GROUP"
echo "server         : $SERVER"
echo "protocol       : $PROTOCOL"
echo "timezone       : $TIMEZONE"
echo "report_dir     : $REPORT_DIR"

log "Set timezone"
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl set-timezone "$TIMEZONE" || warn "timedatectl set-timezone failed"
  timedatectl set-ntp true || true
fi
date
timedatectl 2>/dev/null || true

log "Network test to Wazuh manager"
for port in 1514 1515; do
  if timeout 4 bash -c "cat < /dev/null > /dev/tcp/${SERVER}/${port}" 2>/dev/null; then
    echo "[OK] $SERVER:$port reachable"
  else
    warn "$SERVER:$port not reachable. Check firewall, routing, VLAN/Headscale/Tailscale, and Wazuh manager ports."
  fi
done

log "Detect OS"
[[ -r /etc/os-release ]] || fail "无法识别系统：缺少 /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
ID_LIKE="${ID_LIKE:-}"
OS_FAMILY="unknown"
case "${ID}" in
  ubuntu|debian) OS_FAMILY="debian" ;;
  rhel|centos|rocky|almalinux|fedora|ol|amzn) OS_FAMILY="rhel" ;;
  opensuse*|sles) OS_FAMILY="suse" ;;
  *)
    if echo "$ID_LIKE" | grep -Eqi 'debian|ubuntu'; then OS_FAMILY="debian";
    elif echo "$ID_LIKE" | grep -Eqi 'rhel|fedora|centos'; then OS_FAMILY="rhel";
    elif echo "$ID_LIKE" | grep -Eqi 'suse'; then OS_FAMILY="suse"; fi
    ;;
esac
echo "OS             : ${PRETTY_NAME:-$ID $VERSION_ID}"
echo "OS family      : $OS_FAMILY"

install_debian() {
  log "Install Wazuh agent: Debian/Ubuntu/PVE"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl gnupg apt-transport-https ca-certificates lsb-release python3
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
  chmod 644 /usr/share/keyrings/wazuh.gpg
  echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
  apt-get update
  WAZUH_MANAGER="$SERVER" WAZUH_PROTOCOL="$PROTOCOL" WAZUH_AGENT_NAME="$AGENT_NAME" WAZUH_AGENT_GROUP="$GROUP" \
    DEBIAN_FRONTEND=noninteractive apt-get install -y wazuh-agent
  sed -i 's/^deb /#deb /' /etc/apt/sources.list.d/wazuh.list || true
  apt-mark hold wazuh-agent || true
  apt-get update || true
}

install_rhel() {
  log "Install Wazuh agent: RHEL/Rocky/Alma/CentOS"
  local pm=""
  if command -v dnf >/dev/null 2>&1; then pm="dnf"; elif command -v yum >/dev/null 2>&1; then pm="yum"; else fail "找不到 dnf/yum"; fi
  $pm install -y curl ca-certificates gnupg python3 || true
  rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH
  cat > /etc/yum.repos.d/wazuh.repo <<'REPO'
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=EL-$releasever - Wazuh
baseurl=https://packages.wazuh.com/4.x/yum/
protect=1
REPO
  WAZUH_MANAGER="$SERVER" WAZUH_PROTOCOL="$PROTOCOL" WAZUH_AGENT_NAME="$AGENT_NAME" WAZUH_AGENT_GROUP="$GROUP" \
    $pm install -y wazuh-agent
  sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/wazuh.repo || true
}

install_suse() {
  log "Install Wazuh agent: SUSE/openSUSE"
  zypper --non-interactive install curl ca-certificates gpg2 python3 || true
  rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH
  zypper --non-interactive addrepo -g https://packages.wazuh.com/4.x/yum/ wazuh || true
  WAZUH_MANAGER="$SERVER" WAZUH_PROTOCOL="$PROTOCOL" WAZUH_AGENT_NAME="$AGENT_NAME" WAZUH_AGENT_GROUP="$GROUP" \
    zypper --non-interactive install wazuh-agent
  zypper modifyrepo --disable wazuh || true
}

if command -v /var/ossec/bin/wazuh-control >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q '^wazuh-agent'; then
  log "Wazuh agent already installed; will reconfigure and restart"
else
  case "$OS_FAMILY" in
    debian) install_debian ;;
    rhel) install_rhel ;;
    suse) install_suse ;;
    *) fail "暂不支持该系统：${PRETTY_NAME:-$ID}" ;;
  esac
fi

log "Configure ossec.conf"
mkdir -p /root/.ssh
chmod 700 /root/.ssh || true

python3 - "$SERVER" "$PROTOCOL" <<'PY'
from pathlib import Path
import re
import sys

server, protocol = sys.argv[1], sys.argv[2]
p = Path('/var/ossec/etc/ossec.conf')
text = p.read_text()

# Remove misplaced alert_new_files from earlier manual experiments; keep config compatible.
text = re.sub(r'\n\s*<alert_new_files>yes</alert_new_files>\s*', '\n', text)

# Client manager config.
def fix_client(m):
    block = m.group(0)
    if '<address>' in block:
        block = re.sub(r'<address>.*?</address>', f'<address>{server}</address>', block, count=1, flags=re.S)
    else:
        block = block.replace('<server>', f'<server>\n      <address>{server}</address>', 1)
    if '<port>' in block:
        block = re.sub(r'<port>.*?</port>', '<port>1514</port>', block, count=1, flags=re.S)
    else:
        block = block.replace('</server>', '      <port>1514</port>\n    </server>', 1)
    if '<protocol>' in block:
        block = re.sub(r'<protocol>.*?</protocol>', f'<protocol>{protocol}</protocol>', block, count=1, flags=re.S)
    else:
        block = block.replace('</server>', f'      <protocol>{protocol}</protocol>\n    </server>', 1)
    return block

if '<client>' in text and '</client>' in text:
    text = re.sub(r'<client>.*?</client>', fix_client, text, count=1, flags=re.S)
else:
    client_block = f'''
  <client>
    <server>
      <address>{server}</address>
      <port>1514</port>
      <protocol>{protocol}</protocol>
    </server>
    <config-profile>linux</config-profile>
    <notify_time>10</notify_time>
    <time-reconnect>60</time-reconnect>
    <auto_restart>yes</auto_restart>
    <crypto_method>aes</crypto_method>
  </client>
'''
    text = text.replace('</ossec_config>', client_block + '\n</ossec_config>')

# FIM block. Avoid report_changes for keys/shadow/tmp to prevent leaking sensitive contents and reduce noise.
syscheck_extra = '''
    <!-- Lab critical security monitoring: installed by install-linux.sh -->
    <directories check_all="yes" report_changes="yes" realtime="yes">/etc/ssh</directories>
    <directories check_all="yes" report_changes="yes" realtime="yes">/etc/sudoers.d</directories>
    <directories check_all="yes" report_changes="yes" realtime="yes">/etc/pam.d</directories>
    <directories check_all="yes" report_changes="yes" realtime="yes">/etc/cron.d</directories>
    <directories check_all="yes" report_changes="yes" realtime="yes">/etc/systemd/system</directories>

    <!-- Critical account and auth files: monitor integrity, no content diff. -->
    <directories check_all="yes">/etc/passwd,/etc/group,/etc/shadow,/etc/gshadow,/etc/sudoers,/etc/crontab</directories>

    <!-- SSH keys and cron spool: no content diff. -->
    <directories check_all="yes" realtime="yes">/root/.ssh</directories>
    <directories check_all="yes" realtime="yes">/var/spool/cron</directories>
    <directories check_all="yes" realtime="yes">/var/spool/cron/crontabs</directories>

    <!-- High-risk temporary locations: no content diff. -->
    <directories check_all="yes" realtime="yes">/dev/shm</directories>
    <directories check_all="yes" realtime="yes">/tmp</directories>
    <directories check_all="yes" realtime="yes">/var/tmp</directories>
'''

home = Path('/home')
lines = []
if home.exists():
    for d in sorted(home.iterdir()):
        ssh = d / '.ssh'
        if ssh.is_dir():
            lines.append(f'    <directories check_all="yes" realtime="yes">{ssh}</directories>')
if lines:
    syscheck_extra += '\n    <!-- Existing users SSH directories -->\n' + '\n'.join(lines) + '\n'

if '<syscheck>' not in text:
    syscheck_block = f'''
  <syscheck>
    <disabled>no</disabled>
    <frequency>43200</frequency>
    <scan_on_start>yes</scan_on_start>
    <skip_nfs>yes</skip_nfs>
    <skip_dev>no</skip_dev>
    <skip_proc>yes</skip_proc>
    <skip_sys>yes</skip_sys>
{syscheck_extra}
  </syscheck>
'''
    text = text.replace('</ossec_config>', syscheck_block + '\n</ossec_config>')
else:
    def fix_syscheck(m):
        block = m.group(0)
        if '<disabled>' in block:
            block = re.sub(r'<disabled>.*?</disabled>', '<disabled>no</disabled>', block, count=1, flags=re.S)
        else:
            block = block.replace('<syscheck>', '<syscheck>\n    <disabled>no</disabled>', 1)
        if '<skip_dev>' in block:
            block = re.sub(r'<skip_dev>.*?</skip_dev>', '<skip_dev>no</skip_dev>', block, count=1, flags=re.S)
        else:
            block = block.replace('</syscheck>', '    <skip_dev>no</skip_dev>\n  </syscheck>', 1)
        if 'Lab critical security monitoring' not in block:
            block = block.replace('</syscheck>', syscheck_extra + '\n  </syscheck>', 1)
        return block
    text = re.sub(r'<syscheck>.*?</syscheck>', fix_syscheck, text, count=1, flags=re.S)

# Ensure auth logs. Deduplicate localfile entries by location.
def add_localfile(path, fmt='syslog'):
    global text
    if path in text:
        return
    block = f'''
  <localfile>
    <log_format>{fmt}</log_format>
    <location>{path}</location>
  </localfile>
'''
    text = text.replace('</ossec_config>', block + '\n</ossec_config>')

if Path('/var/log/auth.log').exists():
    add_localfile('/var/log/auth.log')
if Path('/var/log/secure').exists():
    add_localfile('/var/log/secure')

blocks = re.findall(r'\s*<localfile>.*?</localfile>', text, flags=re.S)
seen = set()
for block in blocks:
    locs = tuple(re.findall(r'<location>(.*?)</location>', block, flags=re.S))
    if not locs:
        continue
    if locs in seen:
        text = text.replace(block, '', 1)
    else:
        seen.add(locs)

p.write_text(text)
PY

log "Start service"
systemctl daemon-reload || true
systemctl enable wazuh-agent
systemctl restart wazuh-agent
sleep 5

log "Service and process status"
/var/ossec/bin/wazuh-control status || true
systemctl status wazuh-agent --no-pager || true
ps -eo pid,ppid,user,comm,args --sort=comm | egrep 'wazuh|ossec' | grep -v egrep || true

log "Recent agent log"
tail -n 160 /var/ossec/logs/ossec.log | egrep -i 'connected|manager|enroll|registration|auth|syscheck|fim|logcollector|error|warning|started|duplicated|real time monitoring' || true

if [[ "$TEST_FIM" == "1" ]]; then
  log "FIM local test"
  mkdir -p /etc/ssh/sshd_config.d
  TEST_FILE="/etc/ssh/sshd_config.d/wazuh_fim_test_$(date +%s).conf"
  echo "# wazuh fim create test $(date)" > "$TEST_FILE"
  sleep 3
  echo "# wazuh fim modify test $(date)" >> "$TEST_FILE"
  sleep 3
  rm -f "$TEST_FILE"
  echo "[OK] Created, modified, and deleted $TEST_FILE. Check Wazuh server alerts.log or Dashboard for syscheck events."
fi

log "Configuration summary"
echo "Client block:"
grep -nA14 -B2 '<client>' /var/ossec/etc/ossec.conf || true
echo
echo "Lab FIM block:"
grep -nA90 -B5 'Lab critical security monitoring' /var/ossec/etc/ossec.conf || true

echo
log "Final result"
echo "[OK] Linux Wazuh agent install/config completed."
echo "On Wazuh server, run: sudo /var/ossec/bin/agent_control -l"
echo "On Wazuh server, test alerts: sudo tail -n 500 /var/ossec/logs/alerts/alerts.log | egrep -i 'syscheck|sshd|sudo|fim'"
