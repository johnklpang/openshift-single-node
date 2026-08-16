#!/usr/bin/env bash
# Monitor bootstrap-in-place until the single-node cluster is ready.
set -euo pipefail

WORK_DIR="${WORK_DIR:-/opt/okd}"
OUTPUT_DIR="${OUTPUT_DIR:-/opt/okd-output}"
SNO_IP="${SNO_IP:-192.168.56.20}"
CLUSTER_NAME="${CLUSTER_NAME:-okd}"
BASE_DOMAIN="${BASE_DOMAIN:-lab}"
CLUSTER_FQDN="${CLUSTER_NAME}.${BASE_DOMAIN}"

cd "${WORK_DIR}"
export PATH="${WORK_DIR}:/usr/local/bin:${PATH}"

if [[ -f "${WORK_DIR}/sno/auth/kubeconfig" && -f "${OUTPUT_DIR}/kubeconfig" ]]; then
  export KUBECONFIG="${WORK_DIR}/sno/auth/kubeconfig"
  if oc get nodes >/dev/null 2>&1; then
    echo "==> Cluster already reachable; skipping wait"
    oc get nodes -o wide || true
    exit 0
  fi
fi

echo "==> Waiting for SSH on ${SNO_IP} (live ISO environment)"
ssh_up=0
for _ in $(seq 1 180); do
  if ssh -o BatchMode=yes -o ConnectTimeout=5 core@"${SNO_IP}" true 2>/dev/null; then
    echo "    SSH is up"
    ssh_up=1
    break
  fi
  sleep 5
done
if [[ "${ssh_up}" -ne 1 ]]; then
  echo "ERROR: SSH to ${SNO_IP} never became available. Check output/sno-serial.log on the laptop." >&2
  exit 1
fi

echo "==> Waiting for install-complete (often 45-90 minutes; images pull from quay.io)"
./openshift-install --dir="${WORK_DIR}/sno" wait-for bootstrap-complete --log-level=info || true
./openshift-install --dir="${WORK_DIR}/sno" wait-for install-complete --log-level=info

export KUBECONFIG="${WORK_DIR}/sno/auth/kubeconfig"
mkdir -p "${OUTPUT_DIR}/auth"
cp -f "${WORK_DIR}/sno/auth/kubeconfig" "${OUTPUT_DIR}/kubeconfig"
cp -f "${WORK_DIR}/sno/auth/kubeconfig" "${OUTPUT_DIR}/auth/kubeconfig"
cp -f "${WORK_DIR}/sno/auth/kubeadmin-password" "${OUTPUT_DIR}/kubeadmin-password"
cp -f "${WORK_DIR}/sno/auth/kubeadmin-password" "${OUTPUT_DIR}/auth/kubeadmin-password"

cat >"${OUTPUT_DIR}/cluster-info.txt" <<EOF
Single-node OKD is ready.

API:     https://api.${CLUSTER_FQDN}:6443
Console: https://console-openshift-console.apps.${CLUSTER_FQDN}
User:    kubeadmin
Password file: output/kubeadmin-password
Kubeconfig:    output/kubeconfig

From the helper VM:
  export KUBECONFIG=/opt/okd/sno/auth/kubeconfig
  oc get nodes
  oc get co
EOF

echo "==> Cluster info"
cat "${OUTPUT_DIR}/cluster-info.txt"
oc get nodes -o wide
oc get clusteroperators || true
