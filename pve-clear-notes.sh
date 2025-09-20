#!/bin/bash
# pve-clear-notes.sh — v1.0.0
# Clears Notes for all local VMs/CTs via API, falls back to qm/pct.
set -euo pipefail
SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.0.0"

if [[ "${1:-}" == "--version" ]]; then
  echo "$SCRIPT_NAME $SCRIPT_VERSION"
  exit 0
fi

NODE="$(hostname -s)"

clear_vm() {
  local vmid="$1"
  pvesh set "/nodes/$NODE/qemu/$vmid/config" -description "" >/dev/null 2>&1 || \
  qm set "$vmid" --description "" >/dev/null 2>&1 || \
  echo "  ! Failed to clear VM $vmid"
}

clear_ct() {
  local ctid="$1"
  pvesh set "/nodes/$NODE/lxc/$ctid/config" -description "" >/dev/null 2>&1 || \
  pct set "$ctid" --description "" >/dev/null 2>&1 || \
  echo "  ! Failed to clear CT $ctid"
}

echo "Clearing VM notes…"
qm list 2>/dev/null | awk 'NR>1 {print $1}' | while read -r vid; do
  [[ -n "$vid" ]] && clear_vm "$vid"
done

echo "Clearing CT notes…"
pct list 2>/dev/null | awk 'NR>1 {print $1}' | while read -r cid; do
  [[ -n "$cid" ]] && clear_ct "$cid"
done

echo "Done."
