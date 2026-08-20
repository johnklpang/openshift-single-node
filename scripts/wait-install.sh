#!/usr/bin/env bash
# Wait for agent-based SNO bootstrap and install-complete.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
load_config

INSTALLER="${BIN_DIR}/openshift-install"
[[ -x "${INSTALLER}" ]] || die "openshift-install not found. Run scripts/prepare-iso.sh first."
[[ -d "${CLUSTER_DIR}" ]] || die "Install dir ${CLUSTER_DIR} missing."

keepalive_vm() {
  while true; do
    if ! vm_running "${VM_NAME}"; then
      warn "VM ${VM_NAME} is powered off; starting it again (installer reboot)"
      start_sno_vm || true
    fi
    sleep 15
  done
}

keepalive_vm &
KEEPALIVE_PID=$!
trap 'kill "${KEEPALIVE_PID}" 2>/dev/null || true' EXIT

log "Waiting for SSH on ${SNO_IP}:22 (live agent environment)"
wait_for_tcp "${SNO_IP}" 22 1800 10

log "Waiting for bootstrap-complete"
"${INSTALLER}" agent wait-for bootstrap-complete --dir "${CLUSTER_DIR}" --log-level=info

eject_iso || true
if ! vm_running "${VM_NAME}"; then
  start_sno_vm
fi

log "Waiting for install-complete (often 45-90 minutes)"
"${INSTALLER}" agent wait-for install-complete --dir "${CLUSTER_DIR}" --log-level=info

if [[ -f "${CLUSTER_DIR}/auth/kubeconfig" ]]; then
  cp -f "${CLUSTER_DIR}/auth/kubeconfig" "${KUBECONFIG_OUT}"
  cp -f "${CLUSTER_DIR}/auth/kubeadmin-password" "${OUTPUT_DIR}/kubeadmin-password"
fi

kill "${KEEPALIVE_PID}" 2>/dev/null || true
trap - EXIT

cat <<EOF

Cluster is ready.
  export KUBECONFIG=${KUBECONFIG_OUT}
  ${BIN_DIR}/oc get nodes
  ${BIN_DIR}/oc get clusteroperators

  Console:  ${CONSOLE_URL}
  User:     kubeadmin
  Password: $(cat "${OUTPUT_DIR}/kubeadmin-password")

  SSH:      ssh -i ${SSH_KEY} core@${SNO_IP}

EOF
