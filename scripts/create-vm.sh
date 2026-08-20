#!/usr/bin/env bash
# Create and start one VirtualBox VM sized for single-node OpenShift/OKD testing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
load_config

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Create one VirtualBox VM for a single-node OpenShift (OKD) test cluster.

Options:
  --name NAME         VM name (default: ${VM_NAME})
  --cpus N            vCPUs (default: ${VM_CPUS})
  --memory-mb N       RAM in MiB (default: ${VM_MEMORY_MB})
  --disk-gb N         Disk size in GiB (default: ${VM_DISK_GB})
  --iso PATH          Attach a boot ISO (agent.x86_64.iso)
  --no-start          Create the VM but do not power it on
  --force             Delete and recreate the VM if it already exists
  --dry-run           Print VBoxManage commands without running them
  -h, --help          Show this help

Examples:
  $(basename "$0")
  $(basename "$0") --iso output/cluster/agent.x86_64.iso
  $(basename "$0") --cpus 4 --memory-mb 16384 --disk-gb 120

Full cluster install (ISO + VM + wait):
  ./scripts/up.sh
EOF
}

START_VM=1
FORCE=0
ISO_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) VM_NAME="$2"; shift 2 ;;
    --cpus) VM_CPUS="$2"; shift 2 ;;
    --memory-mb) VM_MEMORY_MB="$2"; shift 2 ;;
    --disk-gb) VM_DISK_GB="$2"; shift 2 ;;
    --iso) ISO_ARG="$2"; shift 2 ;;
    --no-start) START_VM=0; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

DISK_PATH="${OUTPUT_DIR}/${VM_NAME}.vdi"

if [[ -n "${ISO_ARG}" ]]; then
  ISO_PATH="${ISO_ARG}"
fi

if [[ "${FORCE}" == "1" ]] && vm_exists "${VM_NAME}"; then
  log "Recreating existing VM ${VM_NAME}"
  destroy_sno_vm
fi

if vm_exists "${VM_NAME}"; then
  log "VM ${VM_NAME} already exists"
else
  if [[ -z "${ISO_ARG}" && ! -f "${ISO_PATH}" ]]; then
    log "No ISO yet; creating an empty DVD drive (attach later with --iso)"
  fi
  create_sno_vm ""
fi

if [[ -n "${ISO_ARG}" ]]; then
  attach_iso "${ISO_ARG}"
elif [[ -f "${ISO_PATH}" ]]; then
  attach_iso "${ISO_PATH}"
fi

print_lab_summary

if [[ "${START_VM}" == "1" ]]; then
  start_sno_vm
  log "VM started. Headless serial log: ${OUTPUT_DIR}/sno-serial.log"
  log "Destroy with: ./scripts/destroy-vm.sh"
else
  log "VM created but not started (--no-start)"
fi
