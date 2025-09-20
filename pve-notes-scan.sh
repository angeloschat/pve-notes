#!/usr/bin/env bash
# pve-notes-scan.sh — v1.1.0
# Multi-line Notes with forced breaks (CRLF + U+2028), IPv4-only, emoji status.
# Writes via API first (pvesh), falls back to qm/pct.

set -euo pipefail
SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.1.0"

if [[ "${1:-}" == "--version" ]]; then
  echo "$SCRIPT_NAME $SCRIPT_VERSION"
  exit 0
fi

NODE="$(hostname -s)"

# ---- line break that survives most UIs (CRLF + Unicode LINE SEPARATOR) ----
LB=$'\r\n\u2028'

status_icon() {
  case "${1,,}" in
    running) echo "🟢" ;;
    stopped) echo "🔴" ;;
    paused|suspended) echo "🟡" ;;
    *) echo "⚪" ;;
  esac
}

build_notes() {
  # args: ip os status
  local ip="$1" os="$2" status="${3:-unknown}" icon
  icon="$(status_icon "$status")"
  printf 'IP: %s%sOS: %s%sStatus: %s %s' "$ip" "$LB" "$os" "$LB" "$icon" "$status"
}

set_vm_desc() {
  local vmid="$1" text="$2"
  pvesh set "/nodes/$NODE/qemu/$vmid/config" -description "$text" >/dev/null 2>&1 || \
  qm set "$vmid" --description "$text" >/dev/null 2>&1
}

set_ct_desc() {
  local ctid="$1" text="$2"
  pvesh set "/nodes/$NODE/lxc/$ctid/config" -description "$text" >/dev/null 2>&1 || \
  pct set "$ctid" --description "$text" >/dev/null 2>&1
}

scan_vm() {
  local vmid="$1"
  local name status ip="no-ip-found" os="unknown"
  name="$(qm config "$vmid" 2>/dev/null | grep -oP '^name:\s*\K.*' || true)"
  status="$(qm status "$vmid" 2>/dev/null | grep -oP 'status:\s*\K.*' || true)"
  echo "VM $vmid (${name:-no-name}) - Status: ${status:-unknown}"

  if [[ "${status:-}" == "running" ]] && qm agent "$vmid" ping >/dev/null 2>&1; then
    ip="$(qm agent "$vmid" network-get-interfaces 2>/dev/null \
        | grep -oP '"ip-address"\s*:\s*"\K[^"]+' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        | grep -v '^127\.' \
        | head -1 || true)"
    [[ -n "${ip:-}" ]] || ip="no-ip-found"

    os="$(qm agent "$vmid" get-osinfo 2>/dev/null \
        | grep -oP '"(pretty-name|name)"\s*:\s*"\K[^"]+' \
        | head -1 || true)"
    [[ -n "${os:-}" ]] || os="unknown"
  fi

  local notes; notes="$(build_notes "$ip" "$os" "${status:-unknown}")"
  set_vm_desc "$vmid" "$notes" || echo "  ! Failed to set description for VM $vmid"
  echo "  ✓ Updated"
  echo
}

scan_lxc() {
  local ctid="$1"
  local name status ip="no-ip-found" os="unknown"
  name="$(pct config "$ctid" 2>/dev/null | grep -oP '^hostname:\s*\K.*' || true)"
  status="$(pct status "$ctid" 2>/dev/null | grep -oP 'status:\s*\K.*' || true)"
  echo "LXC $ctid (${name:-no-name}) - Status: ${status:-unknown}"

  if [[ "${status:-}" == "running" ]]; then
    ip="$(pct exec "$ctid" -- sh -c \
        "ip -4 -o addr show scope global 2>/dev/null \
         | sed -n 's/.* inet \\([0-9.]*\\)\\/.*/\\1/p' \
         | grep -v '^127\\.0\\.0\\.1\$' \
         | head -1" 2>/dev/null || true)"
    [[ -n "${ip:-}" ]] || ip="no-ip-found"

    os="$(pct exec "$ctid" -- sh -c '
        if [ -r /etc/os-release ]; then
          . /etc/os-release 2>/dev/null
          printf "%s\n" "${PRETTY_NAME:-${NAME:-Linux} ${VERSION_ID:-}}"
        elif command -v lsb_release >/dev/null 2>&1; then
          lsb_release -ds
        else
          uname -sr
        fi' 2>/dev/null || true)"
    [[ -n "${os:-}" ]] || os="unknown"
  fi

  local notes; notes="$(build_notes "$ip" "$os" "${status:-unknown}")"
  set_ct_desc "$ctid" "$notes" || echo "  ! Failed to set description for CT $ctid"
  echo "  ✓ Updated"
  echo
}

echo "Scanning VMs…"
qm list 2>/dev/null | awk 'NR>1 {print $1}' | while read -r vid; do
  [[ -n "$vid" ]] && scan_vm "$vid"
done

echo "Scanning LXCs…"
pct list 2>/dev/null | awk 'NR>1 {print $1}' | while read -r cid; do
  [[ -n "$cid" ]] && scan_lxc "$cid"
done

echo "Done."
echo "If the Summary preview still shows one line, open the VM/CT → Notes tab to see line breaks."
