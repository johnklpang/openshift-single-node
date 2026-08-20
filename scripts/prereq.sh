#!/usr/bin/env bash
# Check host prerequisites for the VirtualBox single-node OKD lab.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
load_config

errors=0
need() {
  if command -v "$1" >/dev/null 2>&1; then
    log "found $1"
  else
    warn "missing $1"
    errors=$((errors + 1))
  fi
}

need curl
need tar
need ssh-keygen
need bash

if find_vboxmanage >/dev/null 2>&1; then
  VBOXMANAGE="$(find_vboxmanage)"
  log "found VBoxManage: ${VBOXMANAGE}"
  if [[ "${DRY_RUN:-0}" != "1" ]]; then
    vboxmanage --version || warn "VBoxManage --version failed"
  fi
else
  warn "VBoxManage not found (install VirtualBox 7.x)"
  errors=$((errors + 1))
fi

mem_kb=0
if [[ -r /proc/meminfo ]]; then
  mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
  mem_gb="$((mem_kb / 1024 / 1024))"
  log "host RAM: ${mem_gb} GB"
  if (( mem_gb < 20 )); then
    warn "host has ${mem_gb} GB RAM; SNO wants 16 GB in the VM plus RAM for the host OS"
  fi
fi

needed="$((VM_DISK_GB + 20))"
if df -Pk "${OUTPUT_DIR}" >/dev/null 2>&1 || mkdir -p "${OUTPUT_DIR}"; then
  avail_kb="$(df -Pk "${OUTPUT_DIR}" | awk 'NR==2{print $4}')"
  avail_gb="$((avail_kb / 1024 / 1024))"
  log "free disk at ${OUTPUT_DIR}: ${avail_gb} GB (want ~${needed} GB)"
  if (( avail_gb < needed )); then
    warn "low disk space: installer ISO, VM disk, and container images need roughly ${needed} GB"
  fi
fi

if [[ -r /proc/cpuinfo ]] && ! grep -E -q 'vmx|svm' /proc/cpuinfo; then
  warn "CPU does not advertise VMX/SVM; VirtualBox may fail to start the VM"
fi

if (( errors > 0 )); then
  die "${errors} prerequisite(s) missing"
fi
log "prerequisites look OK"
print_lab_summary
