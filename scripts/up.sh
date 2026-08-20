#!/usr/bin/env bash
# End-to-end: generate the Agent ISO, create one VirtualBox VM, wait for SNO.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
load_config

FORCE=0
SKIP_WAIT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --skip-wait) SKIP_WAIT=1; shift ;;
    --cpus) VM_CPUS="$2"; shift 2 ;;
    --memory-mb) VM_MEMORY_MB="$2"; shift 2 ;;
    --disk-gb) VM_DISK_GB="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [options]

  --force       Rebuild the ISO and recreate the VM
  --skip-wait   Create and start the VM, do not wait for install-complete
  --cpus N
  --memory-mb N
  --disk-gb N
  --dry-run
EOF
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

if [[ "${DRY_RUN}" == "1" ]]; then
  "${SCRIPT_DIR}/prereq.sh" || true
  log "DRY-RUN: skipping ISO download"
  "${SCRIPT_DIR}/setup-dns.sh"
  "${SCRIPT_DIR}/create-vm.sh" --iso "${ISO_PATH}" --cpus "${VM_CPUS}" --memory-mb "${VM_MEMORY_MB}" --disk-gb "${VM_DISK_GB}" --dry-run --no-start
  exit 0
fi

"${SCRIPT_DIR}/prereq.sh"
"${SCRIPT_DIR}/setup-dns.sh"
if [[ "${FORCE}" == "1" ]]; then
  "${SCRIPT_DIR}/prepare-iso.sh" --force
else
  "${SCRIPT_DIR}/prepare-iso.sh"
fi

create_args=(--iso "${ISO_PATH}" --cpus "${VM_CPUS}" --memory-mb "${VM_MEMORY_MB}" --disk-gb "${VM_DISK_GB}")
if [[ "${FORCE}" == "1" ]]; then
  create_args+=(--force)
fi
"${SCRIPT_DIR}/create-vm.sh" "${create_args[@]}"

if [[ "${SKIP_WAIT}" == "1" ]]; then
  log "Skipping install wait"
  print_lab_summary
  exit 0
fi

"${SCRIPT_DIR}/wait-install.sh"
