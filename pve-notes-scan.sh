#!/usr/bin/env bash
# pve-notes-scan.sh — v1.2.3
# Multiline Notes (Markdown): **IP:** <ip> / **Host:** <hostname> / **OS:** <os>
# - IPv4 only (exclude 127.*)
# - No status line
# - Writes via API first (pvesh), falls back to qm/pct
# - Forces Markdown line breaks (two trailing spaces before newline)

set -euo pipefail
SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.2.3"

if [[ "${1:-}" == "--version" ]]; then
  echo "$SCRIPT_NAME $SCRIPT_VERSION"
  exit 0
fi

NODE="$(hostname -s)"

build_notes() {
  # args: ip host os
  local ip="$1" host="$2" os="$3"
  # Two spaces before \n force Markdown line breaks in the Summary panel.
  printf '**IP:** %s  \n**Host:** %s  \n**OS:** %s' "$ip" "$host" "$os"
}

set_vm_desc() {
  local vmid="$1" text="$2"
  pvesh set "/nodes/$NODE/qemu/$vmid/config" -description "$text" >/dev/null 2>&1 \
    || qm set "$vmid" --description "$text" >/dev/null 2>&1
}

set_ct_desc() {
  local ctid="$1" text="$2"
  pvesh set "/nodes/$NODE/lxc/$ctid/config" -description "$text" >/dev/null 2>&1 \
    || pct set "$ctid" --description "$text" >/dev/null 2>&1
}

# -------- VM (QEMU) --------
scan_vm() {
  local vmid="$1"
  local name status ip="no-ip-found" os="unknown" host="unknown"

  name="$(qm config "$vmid" 2>/dev/null | grep -oP '^name:\s*\K.*' || true)"
  status="$(qm status "$vmid" 2>/dev/null | grep -oP 'status:\s*\K.*' || true)"
  echo "VM $vmid (${name:-no-name}) - Status: ${status:-unknown}"

  if [[ "${status:-}" == "running" ]] && qm agent "$vmid" ping >/dev/null 2>&1; then
    # IPv4 only, exclude 127.*
    ip="$(qm agent "$vmid" network-get-interfaces 2>/dev/null \
        | grep -oP '"ip-address"\s*:\s*"\K[^"]+' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        | grep -v '^127\.' \
        | head -1 || true)"
    [[ -n "${ip:-}" ]] || ip="no-ip-found"

    # Hostname via guest agent; fallback to VM name
    host="$(qm agent "$vmid" get-host-name 2>/dev/null \
        | grep -oP '"host-name"\s*:\s*"\K[^"]+' \
        | head -1 || true)"
    [[ -n "${host:-}" ]] || host="${name:-unknown}"

    # OS (prefer pretty-name, fallback to name)
    os="$(qm agent "$vmid" get-osinfo 2>/dev/null \
        | grep -oP '"(pretty-name|name)"\s*:\s*"\K[^"]+' \
        | head -1 || true)"
    [[ -n "${os:-}" ]] || os="unknown"
  else
    # Not running → hostname fallback to VM name
    host="${name:-unknown}"
  fi

  local notes; notes="$(build_notes "$ip" "$host" "$os")"
  set_vm_desc "$vmid" "$notes" || echo "  ! Failed to set description for VM $vmid"
  echo "  ✓ Updated"
  echo
}

# -------- LXC (CT) --------
scan_lxc() {
  local ctid="$1"
  local name status ip="no-ip-found" os="unknown" host="unknown"

  name="$(pct config "$ctid" 2>/dev/null | grep -oP '^hostname:\s*\K.*' || true)"
  status="$(pct status "$ctid" 2>/dev/null | grep -oP 'status:\s*\K.*' || true)"
  echo "LXC $ctid (${name:-no-name}) - Status: ${status:-unknown}"

  if [[ "${status:-}" == "running" ]]; then
    # IPv4 only (exclude 127.0.0.1); sed-based extraction avoids $4 under set -u
    ip="$(pct exec "$ctid" -- sh -c \
        "ip -4 -o addr show scope global 2>/dev/null \
         | sed -n 's/.* inet \\([0-9.]*\\)\\/.*/\\1/p' \
         | grep -v '^127\\.0\\.0\\.1\$' \
         | head -1" 2>/dev/null || true)"
    [[ -n "${ip:-}" ]] || ip="no-ip-found"

    # Hostname from container; fallback to configured name
    host="$(pct exec "$ctid" -- sh -c 'hostname 2>/dev/null || cat /etc/hostname 2>/dev/null' 2>/dev/null \
           | head -n1 || true)"
    [[ -n "${host:-}" ]] || host="${name:-unknown}"

    # OS from /etc/os-release; fallback to lsb_release or uname -sr
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
  else
    host="${name:-unknown}"
  fi

  local notes; notes="$(build_notes "$ip" "$host" "$os")"
  set_ct_desc "$ctid" "$notes" || echo "  ! Failed to set description for CT $ctid"
  echo "  ✓ Updated"
  echo
}

# -------- Run --------
echo "Scanning VMs…"
qm list 2>/dev/null | awk 'NR>1 {print $1}' | while read -r vid; do
  [[ -n "$vid" ]] && scan_vm "$vid"
done

echo "Scanning LXCs…"
pct list 2>/dev/null | awk 'NR>1 {print $1}' | while read -r cid; do
  [[ -n "$cid" ]] && scan_lxc "$cid"
done

echo "Done."
