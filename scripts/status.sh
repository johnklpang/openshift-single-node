#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/opt/okd/sno/auth/kubeconfig}"
if [[ ! -f "${KUBECONFIG}" ]]; then
  echo "Cluster is not ready yet (missing ${KUBECONFIG})"
  exit 1
fi
echo "==> nodes"
oc get nodes -o wide
echo "==> cluster operators"
oc get clusteroperators
echo "==> pods not running"
oc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded || true
