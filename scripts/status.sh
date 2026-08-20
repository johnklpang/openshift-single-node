#!/usr/bin/env bash
# Show VirtualBox VM and cluster status.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
load_config

print_lab_summary

if find_vboxmanage >/dev/null 2>&1; then
  VBOXMANAGE="$(find_vboxmanage)"
  if vm_exists "${VM_NAME}"; then
    if vm_running "${VM_NAME}"; then
      log "VM ${VM_NAME}: running"
    else
      log "VM ${VM_NAME}: powered off"
    fi
    vboxmanage showvminfo "${VM_NAME}" --machinereadable | grep -E '^(name|ostype|memory|cpus|nic1|hostonlyadapter1|macaddress1|nic2|macaddress2)=' || true
  else
    log "VM ${VM_NAME}: not created"
  fi
else
  warn "VBoxManage not found"
fi

if [[ -f "${ISO_PATH}" ]]; then
  log "ISO: ${ISO_PATH} ($(ls -lh "${ISO_PATH}" | awk '{print $5}'))"
else
  log "ISO: not generated yet"
fi

if [[ -f "${KUBECONFIG_OUT}" && -x "${BIN_DIR}/oc" ]]; then
  export KUBECONFIG="${KUBECONFIG_OUT}"
  "${BIN_DIR}/oc" get nodes -o wide || true
  "${BIN_DIR}/oc" get clusterversion || true
fi
