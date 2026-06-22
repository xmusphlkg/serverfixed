#!/usr/bin/env bash
set -Eeuo pipefail

# SSH batch deployer for Wazuh agents on Linux and Windows hosts.
# Usage:
#   SERVER=192.168.10.102 ./deploy-ssh.sh hosts.txt
# hosts.txt supports:
#   root@192.168.30.120
#   likangguo@192.168.30.121
#   Administrator@192.168.3.50
# Empty lines and lines beginning with # are ignored.

SERVER="${SERVER:-${WAZUH_MANAGER:-}}"
HOSTS_FILE="${1:-hosts.txt}"
GROUP="${GROUP:-default}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
WINDOWS_TIMEZONE="${WINDOWS_TIMEZONE:-China Standard Time}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new -o ConnectTimeout=8}"
TEST_FIM="${TEST_FIM:-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/deploy-logs-$(date +%F_%H%M%S)}"

[[ -n "$SERVER" ]] || { echo "[ERROR] SERVER 未设置。示例：SERVER=192.168.10.102 ./deploy-ssh.sh hosts.txt" >&2; exit 1; }
[[ -f "$HOSTS_FILE" ]] || { echo "[ERROR] 找不到 hosts 文件：$HOSTS_FILE" >&2; exit 1; }
[[ -f "$SCRIPT_DIR/install-linux.sh" ]] || { echo "[ERROR] 缺少 $SCRIPT_DIR/install-linux.sh" >&2; exit 1; }
[[ -f "$SCRIPT_DIR/install-windows.ps1" ]] || { echo "[ERROR] 缺少 $SCRIPT_DIR/install-windows.ps1" >&2; exit 1; }
mkdir -p "$LOG_DIR"

log() { echo; echo "========== $* =========="; }

run_ssh() {
  local target="$1"; shift
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$target" "$@"
}

copy_scp() {
  local src="$1" dst="$2"
  # shellcheck disable=SC2086
  scp $SSH_OPTS "$src" "$dst"
}

detect_os() {
  local target="$1"
  if run_ssh "$target" 'uname -s 2>/dev/null' 2>/dev/null | grep -qi '^linux'; then
    echo "linux"
    return 0
  fi
  if run_ssh "$target" 'powershell -NoProfile -Command "Write-Output windows"' 2>/dev/null | grep -qi 'windows'; then
    echo "windows"
    return 0
  fi
  echo "unknown"
}

deploy_linux() {
  local target="$1"
  copy_scp "$SCRIPT_DIR/install-linux.sh" "$target:/tmp/install-wazuh-agent-linux.sh"
  local uid
  uid="$(run_ssh "$target" 'id -u 2>/dev/null || echo 99999' | tr -d '\r' | tail -1)"
  local sudo_cmd="sudo -E"
  [[ "$uid" == "0" ]] && sudo_cmd=""
  run_ssh "$target" "chmod +x /tmp/install-wazuh-agent-linux.sh && $sudo_cmd env SERVER='$SERVER' GROUP='$GROUP' TIMEZONE='$TIMEZONE' TEST_FIM='$TEST_FIM' bash /tmp/install-wazuh-agent-linux.sh"
}

deploy_windows() {
  local target="$1"
  copy_scp "$SCRIPT_DIR/install-windows.ps1" "$target:C:/Windows/Temp/install-wazuh-agent-windows.ps1"
  run_ssh "$target" "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\install-wazuh-agent-windows.ps1 -Server '$SERVER' -Group '$GROUP' -TimeZone '$WINDOWS_TIMEZONE' -TestFim \$$TEST_FIM"
}

SUMMARY="$LOG_DIR/summary.tsv"
echo -e "target\tos\tresult\tlog" > "$SUMMARY"

while IFS= read -r raw || [[ -n "$raw" ]]; do
  target="$(echo "$raw" | sed 's/#.*//' | xargs || true)"
  [[ -z "$target" ]] && continue

  safe_name="$(echo "$target" | tr '@/:' '____')"
  host_log="$LOG_DIR/$safe_name.log"
  log "Deploy to $target"

  os="unknown"
  result="failed"
  {
    echo "Target: $target"
    echo "Server: $SERVER"
    echo "Started: $(date -Is)"
    os="$(detect_os "$target")"
    echo "Detected OS: $os"
    case "$os" in
      linux) deploy_linux "$target" ;;
      windows) deploy_windows "$target" ;;
      *) echo "[ERROR] Cannot detect remote OS or SSH not reachable."; exit 2 ;;
    esac
    echo "Finished: $(date -Is)"
  } > >(tee "$host_log") 2>&1 && result="ok" || result="failed"

  echo -e "$target\t$os\t$result\t$host_log" >> "$SUMMARY"
  echo "[$result] $target -> $host_log"
done < "$HOSTS_FILE"

log "Deployment summary"
column -t -s $'\t' "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
echo
echo "Logs: $LOG_DIR"
echo "On Wazuh server, check: sudo /var/ossec/bin/agent_control -l"
