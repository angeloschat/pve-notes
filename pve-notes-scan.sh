#!/usr/bin/env bash
# pve-notes-scan.sh — v1.3.0
# Notes format (Markdown):
# **IP:** <ip>
# **Host:** <hostname>
# **OS:** <small icon> <pretty os name>
#
# - IPv4 only (exclude 127.*), IPv6 excluded
# - No status line
# - Writes via API first (pvesh), falls back to qm/pct
# - Two spaces before newline force Markdown line breaks in PVE
# - Small OS logo from dashboardicons.com via jsDelivr CDN

set -euo pipefail
SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.3.0"

# ---- Icon controls ----
# Toggle icons on/off (1/0), choose HTML <img> (1) or Markdown image (0),
# and set icon height in pixels if HTML is used.
PVE_NOTES_ICONS="${PVE_NOTES_ICONS:-1}"
PVE_NOTES_ICON_HTML="${PVE_NOTES_ICON_HTML:-1}"
PVE_NOTES_ICON_HEIGHT="${PVE_NOTES_ICON_HEIGHT:-16}"
ICON_CDN_BASE="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons"

if [[ "${1:-}" == "--version" ]]; then
  echo "$SCRIPT_NAME $SCRIPT_VERSION"
  exit 0
fi

NODE="$(hostname -s)"

build_notes() {
  # args: ip host os
  local ip="$1" host="$2" os="$3"

  local icon_snippet=""
  if [[ "$PVE_NOTES_ICONS" == "1" ]]; then
    local slug ext
    read -r slug ext < <(os_icon_spec "$os")
    if [[ -n "${slug:-}" && -n "${ext:-}" ]]; then
      local url="${ICON_CDN_BASE}/${ext}/${slug}.${ext}"
      if [[ "$PVE_NOTES_ICON_HTML" == "1" ]]; then
        # HTML <img> lets us keep the icon tiny and inline with text
        icon_snippet="<img src=\"${url}\" alt=\"${slug}\" height=\"${PVE_NOTES_ICON_HEIGHT}\" style=\"vertical-align:text-bottom;margin-right:4px;\"> "
      else
        # Markdown fallback (size not controllable in pure Markdown)
        icon_snippet="![](${url}) "
      fi
    fi
  fi

  printf '**IP:** %s  \n**Host:** %s  \n**OS:** %s%s' "$ip" "$host" "$icon_snippet" "$os"
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

# Map an OS name string to a dashboardicons slug and file extension.
# Echos: "<slug> <ext>"
os_icon_spec() {
  local raw="${1:-}"
  local os_lc
  os_lc="$(echo "$raw" | tr '[:upper:]' '[:lower:]')"

  # Linux distros
  case "$os_lc" in
    *ubuntu*)        echo "ubuntu-linux svg"; return;;
    *debian*)        echo "debian-linux svg"; return;;
    *rocky*)         echo "rocky-linux svg"; return;;
    *alma*)          echo "alma-linux svg"; return;;
    *centos*)        echo "centos svg"; return;;
    *fedora*)        echo "fedora svg"; return;;
    *arch*)          echo "arch-linux svg"; return;;
    *opensuse*|*open suse*|*suse*) echo "opensuse svg"; return;;
  esac

  # Windows
  case "$os_lc" in
    *windows*11*|*windows*10*|*windows*server*|*windows*)
      # windows-11 icon exists but is PNG/WEBP base on Dashboard Icons
      echo "windows-11 png"; return;;
  esac

  # Generic Linux fallback
  if echo "$os_lc" | grep -q "linux"; then
    echo "linux svg"; return
  fi

  # No match → empty
  echo " " # two fields, both empty
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
    # IPv4 only (exclude 127.0.0.1)
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
