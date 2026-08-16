#!/usr/bin/env bash
# Download OKD tools, generate bootstrap-in-place ignition, and embed it in a live ISO.
set -euo pipefail

OKD_VERSION="${OKD_VERSION:-4.22.0-okd-scos.7}"
CLUSTER_NAME="${CLUSTER_NAME:-okd}"
BASE_DOMAIN="${BASE_DOMAIN:-lab}"
HELPER_IP="${HELPER_IP:-192.168.56.10}"
SNO_IP="${SNO_IP:-192.168.56.20}"
NETWORK_CIDR="${NETWORK_CIDR:-192.168.56.0/24}"
CLUSTER_FQDN="${CLUSTER_NAME}.${BASE_DOMAIN}"
SNO_HOSTNAME="${SNO_HOSTNAME:-sno.${CLUSTER_FQDN}}"
WORK_DIR="${WORK_DIR:-/opt/okd}"
OUTPUT_DIR="${OUTPUT_DIR:-/opt/okd-output}"
ARCH="${ARCH:-x86_64}"

mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}" /root/.ssh
cd "${WORK_DIR}"

if [[ -f "${OUTPUT_DIR}/okd-sno-live.iso" && -f "${OUTPUT_DIR}/id_ed25519" && -f "${WORK_DIR}/.iso-built" ]]; then
  echo "==> ISO already built at ${OUTPUT_DIR}/okd-sno-live.iso (delete it to rebuild)"
  exit 0
fi

echo "==> Generating SSH key for core@${SNO_HOSTNAME}"
if [[ ! -f "${OUTPUT_DIR}/id_ed25519" ]]; then
  ssh-keygen -t ed25519 -N "" -f "${OUTPUT_DIR}/id_ed25519" -C "okd-sno-lab"
fi
chmod 600 "${OUTPUT_DIR}/id_ed25519"
SSH_PUB="$(cat "${OUTPUT_DIR}/id_ed25519.pub")"
cp -f "${OUTPUT_DIR}/id_ed25519" /root/.ssh/id_ed25519
cp -f "${OUTPUT_DIR}/id_ed25519.pub" /root/.ssh/id_ed25519.pub
chmod 600 /root/.ssh/id_ed25519
cat >/root/.ssh/config <<EOF
Host ${SNO_IP} sno ${SNO_HOSTNAME}
  User core
  IdentityFile /root/.ssh/id_ed25519
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF
chmod 600 /root/.ssh/config

if [[ -f /opt/okd-output/pull-secret.json ]]; then
  PULL_SECRET="$(jq -c . /opt/okd-output/pull-secret.json)"
elif [[ -f /vagrant/pull-secret.json ]]; then
  PULL_SECRET="$(jq -c . /vagrant/pull-secret.json)"
else
  # OKD images are public on quay.io; a dummy secret satisfies the installer schema.
  PULL_SECRET='{"auths":{"fake":{"auth":"aWQ6cGFzcw=="}}}'
fi

TOOLS_BASE="https://github.com/okd-project/okd/releases/download/${OKD_VERSION}"
echo "==> Downloading OKD ${OKD_VERSION} client and installer"
if [[ ! -x "${WORK_DIR}/openshift-install" ]]; then
  curl -fL --retry 5 --retry-delay 5 -o openshift-install-linux.tar.gz \
    "${TOOLS_BASE}/openshift-install-linux-${OKD_VERSION}.tar.gz"
  tar -xzf openshift-install-linux.tar.gz openshift-install
  chmod +x openshift-install
fi
if [[ ! -x "${WORK_DIR}/oc" ]]; then
  curl -fL --retry 5 --retry-delay 5 -o openshift-client-linux.tar.gz \
    "${TOOLS_BASE}/openshift-client-linux-${OKD_VERSION}.tar.gz"
  tar -xzf openshift-client-linux.tar.gz oc kubectl
  chmod +x oc kubectl
  install -m 0755 oc kubectl /usr/local/bin/
fi
install -m 0755 openshift-install /usr/local/bin/ || true

echo "==> Resolving CentOS Stream CoreOS live ISO URL"
ISO_URL="$(
  ./openshift-install coreos print-stream-json \
    | jq -r --arg arch "${ARCH}" '.architectures[$arch].artifacts.metal.formats.iso.disk.location // empty'
)"
if [[ -z "${ISO_URL}" || "${ISO_URL}" == "null" ]]; then
  echo "Failed to parse ISO URL from openshift-install coreos print-stream-json" >&2
  ./openshift-install coreos print-stream-json | jq '.architectures.x86_64.artifacts.metal.formats' || true
  exit 1
fi
echo "    ${ISO_URL}"

if [[ ! -f "${WORK_DIR}/scos-live.iso" ]]; then
  echo "==> Downloading live ISO (this is a few GB and can take a while)"
  curl -fL --retry 5 --retry-delay 5 -o "${WORK_DIR}/scos-live.iso" "${ISO_URL}"
fi
cp -f "${WORK_DIR}/scos-live.iso" "${WORK_DIR}/okd-sno-live.iso"

echo "==> Writing install-config.yaml"
rm -rf "${WORK_DIR}/sno"
mkdir -p "${WORK_DIR}/sno"
cat >"${WORK_DIR}/sno/install-config.yaml" <<EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
compute:
- name: worker
  replicas: 0
controlPlane:
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
bootstrapInPlace:
  installationDisk: /dev/sda
capabilities:
  baselineCapabilitySet: None
  additionalEnabledCapabilities:
  - Ingress
  - Console
  - OperatorLifecycleManager
  - ImageRegistry
  - CloudCredential
pullSecret: '${PULL_SECRET}'
sshKey: |
  ${SSH_PUB}
EOF
cp -f "${WORK_DIR}/sno/install-config.yaml" "${OUTPUT_DIR}/install-config.generated.yaml" || true

echo "==> Creating single-node ignition config"
./openshift-install --dir="${WORK_DIR}/sno" create single-node-ignition-config --log-level=info

echo "==> Embedding ignition and static networking into the live ISO"
# The live environment runs from RAM, so the ISO can be ejected after SSH comes up.
podman run --privileged --rm \
  -v /dev:/dev \
  -v /run/udev:/run/udev \
  -v "${WORK_DIR}:/data" \
  -w /data \
  quay.io/coreos/coreos-installer:release \
  iso ignition embed -f -i sno/bootstrap-in-place-for-live-iso.ign okd-sno-live.iso

# enp0s3 is the first Intel PRO/1000 NIC on a VirtualBox VM (one host-only adapter).
KARGS="ip=${SNO_IP}::${HELPER_IP}:255.255.255.0:${SNO_HOSTNAME}:enp0s3:none nameserver=${HELPER_IP} coreos.no_persist_ip"
podman run --privileged --rm \
  -v /dev:/dev \
  -v /run/udev:/run/udev \
  -v "${WORK_DIR}:/data" \
  -w /data \
  quay.io/coreos/coreos-installer:release \
  iso kargs modify --append "${KARGS}" okd-sno-live.iso

cp -f "${WORK_DIR}/okd-sno-live.iso" "${OUTPUT_DIR}/okd-sno-live.iso"
touch "${WORK_DIR}/.iso-built"
echo "==> ISO ready: ${OUTPUT_DIR}/okd-sno-live.iso"
ls -lh "${OUTPUT_DIR}/okd-sno-live.iso"
