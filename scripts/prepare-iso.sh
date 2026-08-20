#!/usr/bin/env bash
# Download OKD client/installer and generate the Agent-based SNO ISO.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
load_config

FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--force]"
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_cmd curl tar ssh-keygen
mkdir -p "${OUTPUT_DIR}" "${CLUSTER_DIR}" "${BIN_DIR}"
ensure_ssh_key

if [[ -f "${ISO_PATH}" && "${FORCE}" != "1" ]]; then
  log "ISO already exists at ${ISO_PATH} (pass --force to rebuild)"
  exit 0
fi

read -r TOOLS_OS TOOLS_ARCH <<<"$(tools_os_arch)"
TOOLS_BASE="https://github.com/okd-project/okd/releases/download/${OKD_VERSION}"
INSTALL_TGZ="openshift-install-${TOOLS_OS}${TOOLS_ARCH}-${OKD_VERSION}.tar.gz"
CLIENT_TGZ="openshift-client-${TOOLS_OS}${TOOLS_ARCH}-${OKD_VERSION}.tar.gz"

download_extract() {
  local url="$1" dest_dir="$2" bin="$3"
  local archive="${OUTPUT_DIR}/${bin}-${OKD_VERSION}.tar.gz"
  if [[ ! -x "${dest_dir}/${bin}" ]]; then
    log "Downloading ${url}"
    curl -fL --retry 5 --retry-delay 5 -o "${archive}" "${url}"
    tar -xzf "${archive}" -C "${dest_dir}" "${bin}"
    chmod +x "${dest_dir}/${bin}"
  fi
}

download_extract "${TOOLS_BASE}/${INSTALL_TGZ}" "${BIN_DIR}" openshift-install
download_extract "${TOOLS_BASE}/${CLIENT_TGZ}" "${BIN_DIR}" oc
# kubectl is optional and ships in the same client archive.
tar -xzf "${OUTPUT_DIR}/oc-${OKD_VERSION}.tar.gz" -C "${BIN_DIR}" kubectl 2>/dev/null || true
if [[ -f "${BIN_DIR}/kubectl" ]]; then
  chmod +x "${BIN_DIR}/kubectl"
fi

INSTALLER="${BIN_DIR}/openshift-install"
log "Installer: $(${INSTALLER} version | head -n1)"

PULL_SECRET="$(pull_secret_json)"
CAPABILITIES_YAML=""
if [[ "${FULL_CAPABILITIES}" != "true" ]]; then
  CAPABILITIES_YAML=$(cat <<'EOF'
capabilities:
  baselineCapabilitySet: None
  additionalEnabledCapabilities:
  - Ingress
  - Console
  - OperatorLifecycleManager
  - ImageRegistry
  - CloudCredential
  - NodeTuning
  - Storage
EOF
)
fi

rm -rf "${CLUSTER_DIR}"
mkdir -p "${CLUSTER_DIR}"

cat >"${CLUSTER_DIR}/install-config.yaml" <<EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  replicas: 0
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  replicas: 1
metadata:
  name: ${CLUSTER_NAME}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: ${NETWORK_CIDR}
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
${CAPABILITIES_YAML}
pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_PUB}'
EOF
cp -f "${CLUSTER_DIR}/install-config.yaml" "${OUTPUT_DIR}/install-config.generated.yaml"

cat >"${CLUSTER_DIR}/agent-config.yaml" <<EOF
apiVersion: v1beta1
kind: AgentConfig
metadata:
  name: ${CLUSTER_NAME}
rendezvousIP: ${SNO_IP}
additionalNTPSources:
- time.google.com
- pool.ntp.org
hosts:
- hostname: ${SNO_HOSTNAME}
  role: master
  interfaces:
  - name: ${HOSTONLY_NIC}
    macAddress: ${HOSTONLY_MAC}
  - name: ${NAT_NIC}
    macAddress: ${NAT_MAC}
  rootDeviceHints:
    deviceName: /dev/sda
  networkConfig:
    interfaces:
    - name: ${HOSTONLY_NIC}
      type: ethernet
      state: up
      mac-address: ${HOSTONLY_MAC}
      ipv4:
        enabled: true
        dhcp: false
        address:
        - ip: ${SNO_IP}
          prefix-length: 24
    - name: ${NAT_NIC}
      type: ethernet
      state: up
      mac-address: ${NAT_MAC}
      ipv4:
        enabled: true
        dhcp: true
        auto-dns: false
        auto-gateway: true
    dns-resolver:
      config:
        server:
        - 8.8.8.8
        - 1.1.1.1
EOF
cp -f "${CLUSTER_DIR}/agent-config.yaml" "${OUTPUT_DIR}/agent-config.generated.yaml"

log "Generating Agent ISO for ${CLUSTER_FQDN} (this downloads release payload)"
"${INSTALLER}" agent create image --dir "${CLUSTER_DIR}" --log-level=info

[[ -f "${ISO_PATH}" ]] || die "Installer did not produce ${ISO_PATH}"
if [[ -f "${CLUSTER_DIR}/auth/kubeconfig" ]]; then
  cp -f "${CLUSTER_DIR}/auth/kubeconfig" "${KUBECONFIG_OUT}"
  cp -f "${CLUSTER_DIR}/auth/kubeadmin-password" "${OUTPUT_DIR}/kubeadmin-password"
fi
log "ISO ready: ${ISO_PATH}"
ls -lh "${ISO_PATH}"
