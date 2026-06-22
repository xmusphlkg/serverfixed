#!/usr/bin/env bash
set -Eeuo pipefail

# Wazuh Agent Linux local installer for the lab environment.
#
# This script installs or reconfigures Wazuh Agent on the CURRENT machine only.
# It does not read hosts.txt and does not deploy to other machines.
#
# Important TrueNAS note:
#   Do NOT run this on the TrueNAS SCALE host OS. TrueNAS disables apt/package
#   management on the appliance OS. Install Wazuh Agent in a VM instead, or
#   forward TrueNAS logs to Wazuh/syslog.
#
# Default Wazuh manager:
#   192.168.30.102
#
# Basic usage:
#   sudo bash install-linux.sh
#
# Override manager when needed:
#   sudo SERVER=100.64.0.X bash install-linux.sh
#   sudo bash install-linux.sh 100.64.0.X
#
# One-line GitHub usage:
#   curl -fsSL https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/wazuh-agent-deploy-kit/install-linux.sh -o /tmp/install-linux.sh
#   sudo bash /tmp/install-linux.sh
#
# Optional variables:
#   SERVER=192.168.30.102       Wazuh manager address
#   AGENT_NAME=$(hostname -s)   Wazuh agent name
#   GROUP=default               Wazuh agent group
#   TIMEZONE=Asia/Shanghai      System timezone
#   PROTOCOL=tcp                Agent-manager protocol
#   ENROLL=1                    Run agent-auth enrollment when local key is missing
#   FORCE_ENROLL=0              Force re-enrollment by backing up client.keys
#   TEST_FIM=1                  Create/modify/delete a harmless test file
#   REPORT_DIR=/var/tmp/wazuh-agent-install-report

DEFAULT_SERVER="192.168.30.102"
SERVER="${SERVER:-${WAZUH_MANAGER:-${1:-$DEFAULT_SERVER}}}"
AGENT_NAME="${AGENT_NAME:-${WAZUH_AGENT_NAME:-$(hostname -s)}}"
GROUP="${GROUP:-${WAZUH_AGENT_GROUP:-default}}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
PROTOCOL="${PROTOCOL:-tcp}"
ENROLL="${ENROLL:-1}"
FORCE_ENROLL="${FORCE_ENROLL:-0}"
TEST_FIM="${TEST_FIM:-1}"
TEST_WAIT="${TEST_WAIT:-8}"
REPORT_DIR="${REPORT_DIR:-/var/tmp/wazuh-agent-install-report}"
RUN_ID="$(date +%F_%H%M%S)"
LOG_FILE="${REPORT_DIR}/install-${RUN_ID}.log"
SUMMARY_FILE="${REPORT_DIR}/summary-${RUN_ID}.txt"

log() { echo; echo "========== $* =========="; }
warn() { echo "[WARN] $*" >&2; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[[ "$(id -u)" -eq 0 ]] || fail "请用 root 运行：sudo bash install-linux.sh"

mkdir -p "$REPORT_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo; echo "[ERROR] Script failed at line ${LINENO}. Full log: ${LOG_FILE}" >&2' ERR

log "Basic information"
echo "mode           : local single-host installer"
echo "hostname       : $(hostname -f 2>/dev/null || hostname)"
echo "agent_name     : $AGENT_NAME"
echo "group          : $GROUP"
echo "server         : $SERVER"
echo "protocol       : $PROTOCOL"
echo "timezone       : $TIMEZONE"
echo "enroll         : $ENROLL"
echo "force_enroll   : $FORCE_ENROLL"
echo "test_fim       : $TEST_FIM"
echo "report_dir     : $REPORT_DIR"
echo "log_file       : $LOG_FILE"

log "Detect OS"
[[ -r /etc/os-release ]] || fail "无法识别系统：缺少 /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
ID_LIKE="${ID_LIKE:-}"
PRETTY_NAME="${PRETTY_NAME:-$ID ${VERSION_ID:-}}"
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

echo "OS             : $PRETTY_NAME"
echo "OS family      : $OS_FAMILY"

is_truenas=0
truenas_reason=""
if [[ -r /etc/version ]] && grep -Eqi 'truenas|scale' /etc/version; then
  is_truenas=1
  truenas_reason="/etc/version contains TrueNAS/SCALE"
elif [[ -r /etc/os-release ]] && grep -Eqi 'truenas|ixsystems' /etc/os-release; then
  is_truenas=1
  truenas_reason="/etc/os-release contains TrueNAS/iXsystems"
elif [[ -e /etc/ix_version || -d /data/ix-applications || -d /var/lib/kubernetes/k3s/agent/etc/containerd/certs.d ]]; then
  # /data/ix-applications is common on TrueNAS SCALE systems with Apps enabled.
  is_truenas=1
  truenas_reason="TrueNAS/SCALE marker path detected"
fi

if [[ "$is_truenas" == "1" ]]; then
  log "TrueNAS SCALE host detected"
  cat <<EOF
[STOP] This machine appears to be a TrueNAS SCALE appliance host.
Reason: $truenas_reason

Do not install Wazuh Agent on the TrueNAS host OS with apt/dpkg. TrueNAS disables
package management on the appliance OS, and forcing package changes can make the
system nonfunctional or break upgrades.

Recommended options:
  1. Install Wazuh Agent inside a normal Debian/Ubuntu VM running on TrueNAS.
  2. Forward TrueNAS syslog/logs to the Wazuh server or another syslog receiver.
  3. Monitor TrueNAS with its supported interfaces, such as SNMP/syslog/API, and
     keep Zabbix/Grafana for availability and performance metrics.

This script intentionally exits before changing packages.
EOF
  {
    echo "Wazuh Agent Local Installation Summary"
    echo "====================================="
    echo "time           : $(date)"
    echo "host           : $(hostname -f 2>/dev/null || hostname)"
    echo "server         : $SERVER"
    echo "os             : $PRETTY_NAME"
    echo "result         : skipped"
    echo "reason         : TrueNAS SCALE host detected; package installation disabled"
    echo "log_file       : $LOG_FILE"
  } > "$SUMMARY_FILE"
  cat "$SUMMARY_FILE"
  exit 2
fi

log "Set timezone"
if have timedatectl; then
  timedatectl set-timezone "$TIMEZONE" || warn "timedatectl set-timezone failed"
  timedatectl set-ntp true || true
else
  warn "timedatectl not found; skip timezone configuration"
fi
date
timedatectl 2>/dev/null || true

log "Network test to Wazuh manager"
network_ok_1514=0
network_ok_1515=0
for port in 1514 1515; do
  if timeout 4 bash -c "cat < /dev/null > /dev/tcp/${SERVER}/${port}" 2>/dev/null; then
    echo "[OK] ${SERVER}:${port} reachable"
    [[ "$port" == "1514" ]] && network_ok_1514=1
    [[ "$port" == "1515" ]] && network_ok_1515=1
  else
    warn "${SERVER}:${port} not reachable. Check firewall, routing, VLAN/Headscale/Tailscale, and Wazuh manager ports."
  fi
done

install_debian() {
  log "Install Wazuh agent: Debian/Ubuntu/PVE"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl gnupg apt-transport-https ca-certificates lsb-release python3
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH -o /tmp/GPG-KEY-WAZUH
  gpg --dearmor --yes -o /usr/share/keyrings/wazuh.gpg /tmp/GPG-KEY-WAZUH
  chmod 644 /usr/share/keyrings/wazuh.gpg
  echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
  apt-get update
  WAZUH_MANAGER="$SERVER" \
  WAZUH_PROTOCOL="$PROTOCOL" \
  WAZUH_AGENT_NAME="$AGENT_NAME" \
  WAZUH_AGENT_GROUP="$GROUP" \
  WAZUH_REGISTRATION_SERVER="$SERVER" \
  WAZUH_REGISTRATION_PORT="1515" \
    DEBIAN_FRONTEND=noninteractive apt-get install -y wazuh-agent
  sed -i 's/^deb /#deb /' /etc/apt/sources.list.d/wazuh.list || true
  apt-mark hold wazuh-agent || true
  apt-get update || true
}

install_rhel() {
  log "Install Wazuh agent: RHEL/Rocky/Alma/CentOS"
  local pm=""
  if have dnf; then pm="dnf"; elif have yum; then pm="yum"; else fail "找不到 dnf/yum"; fi
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
  WAZUH_MANAGER="$SERVER" \
  WAZUH_PROTOCOL="$PROTOCOL" \
  WAZUH_AGENT_NAME="$AGENT_NAME" \
  WAZUH_AGENT_GROUP="$GROUP" \
  WAZUH_REGISTRATION_SERVER="$SERVER" \
  WAZUH_REGISTRATION_PORT="1515" \
    $pm install -y wazuh-agent
  sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/wazuh.repo || true
}

install_suse() {
  log "Install Wazuh agent: SUSE/openSUSE"
  zypper --non-interactive install curl ca-certificates gpg2 python3 || true
  rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH
  zypper --non-interactive addrepo -g https://packages.wazuh.com/4.x/yum/ wazuh || true
  WAZUH_MANAGER="$SERVER" \
  WAZUH_PROTOCOL="$PROTOCOL" \
  WAZUH_AGENT_NAME="$AGENT_NAME" \
  WAZUH_AGENT_GROUP="$GROUP" \
  WAZUH_REGISTRATION_SERVER="$SERVER" \
  WAZUH_REGISTRATION_PORT="1515" \
    zypper --non-interactive install wazuh-agent
  zypper modifyrepo --disable wazuh || true
}

if have /var/ossec/bin/wazuh-control || systemctl list-unit-files 2>/dev/null | grep -q '^wazuh-agent'; then
  log "Wazuh agent already installed; reconfigure and restart only"
else
  case "$OS_FAMILY" in
    debian) install_debian ;;
    rhel) install_rhel ;;
    suse) install_suse ;;
    *) fail "暂不支持该系统：$PRETTY_NAME" ;;
  esac
fi

log "Configure ossec.conf"
[[ -f /var/ossec/etc/ossec.conf ]] || fail "找不到 /var/ossec/etc/ossec.conf，Wazuh agent 安装可能失败"
cp -a /var/ossec/etc/ossec.conf "/var/ossec/etc/ossec.conf.bak.${RUN_ID}"
mkdir -p /root/.ssh /etc/ssh/sshd_config.d
chmod 700 /root/.ssh || true

python3 - "$SERVER" "$PROTOCOL" <<'PY'
from pathlib import Path
import re
import sys

server, protocol = sys.argv[1], sys.argv[2]
p = Path('/var/ossec/etc/ossec.conf')
text = p.read_text()

text = re.sub(r'\n\s*<alert_new_files>yes</alert_new_files>\s*', '\n', text)

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

log "Enrollment check"
CLIENT_KEYS="/var/ossec/etc/client.keys"
key_lines=0
if [[ -s "$CLIENT_KEYS" ]]; then
  key_lines="$(awk 'NF >= 4 {c++} END {print c+0}' "$CLIENT_KEYS" 2>/dev/null || echo 0)"
fi
echo "client_keys     : $CLIENT_KEYS"
echo "client_key_rows : $key_lines"

if [[ "$FORCE_ENROLL" == "1" ]]; then
  log "Force enrollment requested"
  systemctl stop wazuh-agent 2>/dev/null || true
  if [[ -f "$CLIENT_KEYS" ]]; then
    cp -a "$CLIENT_KEYS" "${CLIENT_KEYS}.bak.${RUN_ID}"
    : > "$CLIENT_KEYS"
    chmod 640 "$CLIENT_KEYS" || true
  fi
  key_lines=0
fi

if [[ "$ENROLL" == "1" && "$key_lines" -eq 0 ]]; then
  if [[ "$network_ok_1515" != "1" ]]; then
    warn "Skip agent-auth because ${SERVER}:1515 was not reachable at network test time"
  elif [[ ! -x /var/ossec/bin/agent-auth ]]; then
    warn "agent-auth not found or not executable: /var/ossec/bin/agent-auth"
  else
    echo "[INFO] No valid local client key found; running agent-auth enrollment..."
    systemctl stop wazuh-agent 2>/dev/null || true
    if [[ "$GROUP" != "default" ]]; then
      /var/ossec/bin/agent-auth -m "$SERVER" -p 1515 -A "$AGENT_NAME" -G "$GROUP" || warn "agent-auth with group failed"
    else
      /var/ossec/bin/agent-auth -m "$SERVER" -p 1515 -A "$AGENT_NAME" || warn "agent-auth failed"
    fi
    if [[ -s "$CLIENT_KEYS" ]]; then
      key_lines="$(awk 'NF >= 4 {c++} END {print c+0}' "$CLIENT_KEYS" 2>/dev/null || echo 0)"
    fi
    echo "client_key_rows_after_auth : $key_lines"
  fi
else
  echo "[INFO] Existing client key found or ENROLL=0; skip agent-auth. Use FORCE_ENROLL=1 to re-enroll."
fi

log "Start service"
systemctl daemon-reload || true
systemctl enable wazuh-agent
systemctl restart wazuh-agent
sleep 5

log "Service and process status"
/var/ossec/bin/wazuh-control status || true
systemctl status wazuh-agent --no-pager || true
ps -eo pid,ppid,user,%cpu,%mem,etime,comm,args --sort=comm | egrep 'wazuh|ossec' | grep -v egrep || true

log "Connection/process/network details"
if have ss; then
  ss -ntp 2>/dev/null | egrep '(:1514|:1515)' || true
else
  warn "ss not found; skip socket details"
fi

log "Recent agent log"
tail -n 220 /var/ossec/logs/ossec.log | egrep -i 'connected|manager|enroll|registration|auth|agent-auth|key|syscheck|fim|logcollector|error|warning|started|duplicated|real time monitoring|active response' || true

TEST_FILE=""
if [[ "$TEST_FIM" == "1" ]]; then
  log "FIM local test"
  mkdir -p /etc/ssh/sshd_config.d
  TEST_FILE="/etc/ssh/sshd_config.d/wazuh_fim_test_${RUN_ID}.conf"
  echo "# wazuh fim create test $(date)" > "$TEST_FILE"
  sleep "$TEST_WAIT"
  echo "# wazuh fim modify test $(date)" >> "$TEST_FILE"
  sleep "$TEST_WAIT"
  rm -f "$TEST_FILE"
  sleep "$TEST_WAIT"
  echo "[OK] Created, modified, and deleted $TEST_FILE"
  echo "[INFO] On Wazuh server, check syscheck events with:"
  echo "       sudo tail -n 500 /var/ossec/logs/alerts/alerts.log | egrep -i 'syscheck|fim|wazuh_fim_test|sshd_config'"
else
  echo "[INFO] TEST_FIM=0, skip FIM create/modify/delete test"
fi

log "Configuration summary"
echo "Client block:"
grep -nA14 -B2 '<client>' /var/ossec/etc/ossec.conf || true
echo
echo "Lab FIM block:"
grep -nA90 -B5 'Lab critical security monitoring' /var/ossec/etc/ossec.conf || true
echo
echo "Auth log localfile entries:"
grep -nA4 -B2 '/var/log/auth.log\|/var/log/secure' /var/ossec/etc/ossec.conf || true
echo
echo "Client key status:"
if [[ -s "$CLIENT_KEYS" ]]; then
  awk '{print "key_line_fields=" NF, "agent_id=" $1, "agent_name=" $2}' "$CLIENT_KEYS" 2>/dev/null || true
else
  echo "client.keys is missing or empty"
fi

log "Write final summary"
{
  echo "Wazuh Agent Local Installation Summary"
  echo "====================================="
  echo "time           : $(date)"
  echo "host           : $(hostname -f 2>/dev/null || hostname)"
  echo "server         : $SERVER"
  echo "agent_name     : $AGENT_NAME"
  echo "group          : $GROUP"
  echo "timezone       : $TIMEZONE"
  echo "os             : $PRETTY_NAME"
  echo "network_1514   : $network_ok_1514"
  echo "network_1515   : $network_ok_1515"
  echo "enroll         : $ENROLL"
  echo "force_enroll   : $FORCE_ENROLL"
  echo "client_key_rows: ${key_lines:-0}"
  echo "test_fim       : $TEST_FIM"
  echo "test_file      : ${TEST_FILE:-none}"
  echo "log_file       : $LOG_FILE"
  echo
  echo "wazuh-control status:"
  /var/ossec/bin/wazuh-control status 2>/dev/null || true
  echo
  echo "processes:"
  ps -eo pid,ppid,user,%cpu,%mem,etime,comm,args --sort=comm | egrep 'wazuh|ossec' | grep -v egrep || true
} > "$SUMMARY_FILE"
cat "$SUMMARY_FILE"

echo
echo "[OK] Local Wazuh agent deployment finished."
echo "Full log    : $LOG_FILE"
echo "Summary     : $SUMMARY_FILE"
echo
echo "Important: /var/ossec/logs/alerts/alerts.log exists on the Wazuh server, not on agents."
echo "Next check on Wazuh server ${SERVER}:"
echo "  sudo /var/ossec/bin/agent_control -l"
echo "  sudo tail -n 500 /var/ossec/logs/alerts/alerts.log | egrep -i 'syscheck|fim|wazuh_fim_test|sshd|sudo|authentication'"
