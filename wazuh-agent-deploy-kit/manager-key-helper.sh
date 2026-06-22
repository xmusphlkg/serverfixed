#!/usr/bin/env bash
set -Eeuo pipefail

# Noninteractive Wazuh manager helper.
# Run this on the Wazuh manager/server, not on agents.
#
# Usage:
#   sudo bash manager-key-helper.sh issue <agent-name> [agent-ip=any] [force=1]
#
# Output contains:
#   WAZUH_AGENT_ID=<id>
#   WAZUH_AGENT_NAME=<name>
#   WAZUH_AGENT_KEY=<key>

ACTION="${1:-issue}"
AGENT_NAME="${2:-}"
AGENT_IP="${3:-any}"
FORCE="${4:-1}"
MANAGE="${MANAGE:-/var/ossec/bin/manage_agents}"
CONTROL="${CONTROL:-/var/ossec/bin/wazuh-control}"

log() { echo "[manager-helper] $*" >&2; }
fail() { echo "[manager-helper][ERROR] $*" >&2; exit 1; }

[[ "$ACTION" == "issue" ]] || fail "Unsupported action: $ACTION"
[[ -n "$AGENT_NAME" ]] || fail "Missing agent name. Usage: sudo bash manager-key-helper.sh issue <agent-name> [agent-ip=any] [force=1]"
[[ -x "$MANAGE" ]] || fail "manage_agents not found: $MANAGE"

list_agents() {
  "$MANAGE" -l 2>/dev/null || true
}

find_agent_id() {
  local name="$1"
  list_agents | awk -v name="$name" '
    $0 ~ /ID:/ && $0 ~ /Name:/ {
      line=$0
      id=line; sub(/^.*ID:[[:space:]]*/, "", id); sub(/,.*/, "", id)
      nm=line; sub(/^.*Name:[[:space:]]*/, "", nm); sub(/,.*/, "", nm)
      if (nm == name) { print id; exit }
    }
  '
}

remove_agent() {
  local id="$1"
  [[ -n "$id" ]] || return 0
  log "Removing existing agent id=$id name=$AGENT_NAME"
  # Interactive menu sequence: Remove -> id -> confirm -> Quit.
  printf 'R\n%s\ny\nQ\n' "$id" | "$MANAGE" >/tmp/wazuh_manage_agents_remove_${AGENT_NAME}.log 2>&1 || true
}

add_agent() {
  log "Adding agent name=$AGENT_NAME ip=$AGENT_IP"
  # Interactive menu sequence: Add -> name -> IP -> confirm -> Quit.
  printf 'A\n%s\n%s\ny\nQ\n' "$AGENT_NAME" "$AGENT_IP" | "$MANAGE" >/tmp/wazuh_manage_agents_add_${AGENT_NAME}.log 2>&1 || true
}

extract_key() {
  local id="$1"
  [[ -n "$id" ]] || fail "Cannot extract key: missing agent id"
  local out key
  out="$(printf 'E\n%s\nQ\n' "$id" | "$MANAGE" 2>&1 || true)"
  key="$(printf '%s\n' "$out" | awk '
    /^[A-Za-z0-9+\/=-]+$/ && length($0) > 40 { print; exit }
  ')"
  if [[ -z "$key" ]]; then
    echo "$out" >&2
    fail "Could not parse extracted key for id=$id name=$AGENT_NAME"
  fi
  printf '%s\n' "$key"
}

if [[ "$FORCE" == "1" ]]; then
  old_id="$(find_agent_id "$AGENT_NAME" || true)"
  [[ -n "$old_id" ]] && remove_agent "$old_id"
fi

id="$(find_agent_id "$AGENT_NAME" || true)"
if [[ -z "$id" ]]; then
  add_agent
  id="$(find_agent_id "$AGENT_NAME" || true)"
fi

[[ -n "$id" ]] || {
  log "Current agent list:"
  list_agents >&2
  fail "Agent was not added: $AGENT_NAME"
}

key="$(extract_key "$id")"

# Make remoted reload keys faster when possible. A full manager restart is not required in most cases,
# but this is harmless if available and makes troubleshooting easier.
if [[ -x "$CONTROL" ]]; then
  "$CONTROL" restart >/tmp/wazuh_control_restart_after_key_${AGENT_NAME}.log 2>&1 || true
fi

echo "WAZUH_AGENT_ID=$id"
echo "WAZUH_AGENT_NAME=$AGENT_NAME"
echo "WAZUH_AGENT_IP=$AGENT_IP"
echo "WAZUH_AGENT_KEY=$key"
