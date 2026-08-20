#!/usr/bin/env bash
# Power off and delete the single-node VirtualBox VM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
load_config

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) VM_NAME="$2"; DISK_PATH="${OUTPUT_DIR}/${VM_NAME}.vdi"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--name VM]"
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

destroy_sno_vm
log "Removed ${VM_NAME}"
