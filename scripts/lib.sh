# Shared helpers for the VirtualBox single-node OKD lab.
# shellcheck shell=bash

if [[ -n "${_OKD_SNO_LIB:-}" ]]; then
  return 0
fi
_OKD_SNO_LIB=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/output}"
CLUSTER_DIR="${CLUSTER_DIR:-${OUTPUT_DIR}/cluster}"
BIN_DIR="${BIN_DIR:-${OUTPUT_DIR}/bin}"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

load_config() {
  # shellcheck disable=SC1091
  [[ -f "${REPO_ROOT}/config.env" ]] && source "${REPO_ROOT}/config.env"
  # shellcheck disable=SC1091
  [[ -f "${REPO_ROOT}/config.local.env" ]] && source "${REPO_ROOT}/config.local.env"

  OKD_VERSION="${OKD_VERSION:-4.22.0-okd-scos.8}"
  CLUSTER_NAME="${CLUSTER_NAME:-okd}"
  DNS_MODE="${DNS_MODE:-sslip}"
  NETWORK_CIDR="${NETWORK_CIDR:-192.168.56.0/24}"
  HOST_IP="${HOST_IP:-192.168.56.1}"
  SNO_IP="${SNO_IP:-192.168.56.20}"
  VM_NAME="${VM_NAME:-okd-sno}"
  VM_CPUS="${VM_CPUS:-8}"
  VM_MEMORY_MB="${VM_MEMORY_MB:-16384}"
  VM_DISK_GB="${VM_DISK_GB:-120}"
  VM_OSTYPE="${VM_OSTYPE:-RedHat_64}"
  HOSTONLY_NIC="${HOSTONLY_NIC:-enp0s3}"
  NAT_NIC="${NAT_NIC:-enp0s8}"
  HOSTONLY_MAC="${HOSTONLY_MAC:-02:00:00:56:00:20}"
  NAT_MAC="${NAT_MAC:-02:00:00:02:00:20}"
  NAT_IP="${NAT_IP:-10.0.2.15}"
  NAT_GATEWAY="${NAT_GATEWAY:-10.0.2.2}"
  FULL_CAPABILITIES="${FULL_CAPABILITIES:-false}"
  DRY_RUN="${DRY_RUN:-0}"

  if [[ -z "${BASE_DOMAIN:-}" ]]; then
    if [[ "${DNS_MODE}" == "sslip" ]]; then
      BASE_DOMAIN="${SNO_IP}.sslip.io"
    else
      BASE_DOMAIN="lab"
    fi
  fi
  CLUSTER_FQDN="${CLUSTER_NAME}.${BASE_DOMAIN}"
  SNO_HOSTNAME="${SNO_HOSTNAME:-sno.${CLUSTER_FQDN}}"
  API_URL="https://api.${CLUSTER_FQDN}:6443"
  CONSOLE_URL="https://console-openshift-console.apps.${CLUSTER_FQDN}"
  DISK_PATH="${DISK_PATH:-${OUTPUT_DIR}/${VM_NAME}.vdi}"
  ISO_PATH="${ISO_PATH:-${CLUSTER_DIR}/agent.x86_64.iso}"
  SSH_KEY="${SSH_KEY:-${OUTPUT_DIR}/id_ed25519}"
  KUBECONFIG_OUT="${KUBECONFIG_OUT:-${OUTPUT_DIR}/kubeconfig}"
}

is_windows() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

host_path() {
  local path="$1"
  if is_windows && command -v cygpath >/dev/null 2>&1; then
    cygpath -w "${path}"
  else
    printf '%s' "${path}"
  fi
}

find_vboxmanage() {
  local candidate
  if [[ -n "${VBOX_MANAGE:-}" && -x "${VBOX_MANAGE}" ]]; then
    printf '%s' "${VBOX_MANAGE}"
    return 0
  fi
  for candidate in \
    VBoxManage \
    VBoxManage.exe \
    "/usr/bin/VBoxManage" \
    "/usr/local/bin/VBoxManage" \
    "/opt/homebrew/bin/VBoxManage" \
    "/c/Program Files/Oracle/VirtualBox/VBoxManage.exe" \
    "C:/Program Files/Oracle/VirtualBox/VBoxManage.exe" \
    "/mnt/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      command -v "${candidate}"
      return 0
    fi
    if [[ -x "${candidate}" ]]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

require_vboxmanage() {
  if [[ -z "${VBOXMANAGE:-}" ]]; then
    VBOXMANAGE="$(find_vboxmanage)" || die "VBoxManage not found. Install VirtualBox 7.x and ensure VBoxManage is on PATH."
  fi
}

vboxmanage() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf 'DRY-RUN: VBoxManage'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  require_vboxmanage
  "${VBOXMANAGE}" "$@"
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
  done
}

vm_exists() {
  local name="${1:-${VM_NAME}}"
  [[ "${DRY_RUN}" == "1" ]] && return 1
  vboxmanage list vms | grep -F "\"${name}\"" >/dev/null 2>&1
}

vm_running() {
  local name="${1:-${VM_NAME}}"
  [[ "${DRY_RUN}" == "1" ]] && return 1
  vboxmanage list runningvms | grep -F "\"${name}\"" >/dev/null 2>&1
}

tcp_open() {
  local ip="$1" port="$2"
  if command -v timeout >/dev/null 2>&1; then
    timeout 1 bash -c "echo >/dev/tcp/${ip}/${port}" 2>/dev/null
  elif command -v nc >/dev/null 2>&1; then
    nc -z -w 1 "${ip}" "${port}" >/dev/null 2>&1
  else
    bash -c "echo >/dev/tcp/${ip}/${port}" 2>/dev/null
  fi
}

wait_for_tcp() {
  local ip="$1" port="$2" timeout_sec="${3:-900}" interval="${4:-5}"
  local start now
  start="$(date +%s)"
  log "Waiting for ${ip}:${port}"
  while true; do
    if tcp_open "${ip}" "${port}"; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout_sec )); then
      die "Timed out waiting for ${ip}:${port}"
    fi
    sleep "${interval}"
  done
}

ltrim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s}"
}

parse_hostonly_adapter() {
  local want_ip="$1"
  local name="" ip="" match=""
  local block
  block="$(vboxmanage list hostonlyifs || true)"
  [[ -z "${block}" ]] && return 1
  while IFS= read -r line; do
    case "${line}" in
      Name:*)
        name="$(ltrim "${line#Name:}")"
        ;;
      IPAddress:*)
        ip="$(ltrim "${line#IPAddress:}")"
        if [[ "${ip}" == "${want_ip}" ]]; then
          match="${name}"
        fi
        ;;
    esac
  done <<< "${block}"
  if [[ -n "${match}" ]]; then
    printf '%s' "${match}"
    return 0
  fi
  return 1
}

hostonly_ip() {
  local want_name="$1"
  local name="" ip=""
  while IFS= read -r line; do
    case "${line}" in
      Name:*) name="$(ltrim "${line#Name:}")" ;;
      IPAddress:*)
        ip="$(ltrim "${line#IPAddress:}")"
        if [[ "${name}" == "${want_name}" ]]; then
          printf '%s' "${ip}"
          return 0
        fi
        ;;
    esac
  done < <(vboxmanage list hostonlyifs || true)
  return 1
}

ensure_hostonly_adapter() {
  local expected_ip="${HOST_IP}"
  local ip created
  HOSTONLY_ADAPTER="${HOSTONLY_ADAPTER:-}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    HOSTONLY_ADAPTER="${HOSTONLY_ADAPTER:-vboxnet0}"
    log "DRY-RUN: would use host-only adapter ${HOSTONLY_ADAPTER} (${expected_ip})"
    return 0
  fi

  require_vboxmanage
  HOSTONLY_ADAPTER="$(parse_hostonly_adapter "${expected_ip}" || true)"

  if [[ -z "${HOSTONLY_ADAPTER}" ]]; then
    log "Creating VirtualBox host-only adapter"
    created="$(vboxmanage hostonlyif create)"
    HOSTONLY_ADAPTER="$(printf '%s\n' "${created}" | sed -n "s/.*'\([^']*\)'.*/\1/p" | head -n1)"
    [[ -n "${HOSTONLY_ADAPTER}" ]] || die "Failed to parse host-only adapter name from: ${created}"
  fi

  ip="$(hostonly_ip "${HOSTONLY_ADAPTER}" || true)"
  if [[ "${ip}" != "${expected_ip}" ]]; then
    log "Configuring ${HOSTONLY_ADAPTER} with ${expected_ip}/24"
    vboxmanage hostonlyif ipconfig "${HOSTONLY_ADAPTER}" --ip "${expected_ip}" --netmask 255.255.255.0
  fi

  # Static addressing on the SNO node; disable DHCP on this adapter if present.
  if vboxmanage list dhcpservers | grep -F "${HOSTONLY_ADAPTER}" >/dev/null 2>&1; then
    vboxmanage dhcpserver modify --ifname "${HOSTONLY_ADAPTER}" --disable >/dev/null 2>&1 || true
  fi
  log "Host-only adapter: ${HOSTONLY_ADAPTER} (${expected_ip})"
}

create_sno_vm() {
  local iso_path="${1:-}"
  local name="${VM_NAME}"
  mkdir -p "${OUTPUT_DIR}"
  ensure_hostonly_adapter

  if vm_exists "${name}"; then
    die "VM ${name} already exists. Run scripts/destroy-vm.sh first, or pass --force."
  fi

  log "Creating VM ${name} (${VM_CPUS} vCPU, ${VM_MEMORY_MB} MB, ${VM_DISK_GB} GB)"
  vboxmanage createvm --name "${name}" --ostype "${VM_OSTYPE}" --register
  vboxmanage modifyvm "${name}" \
    --memory "${VM_MEMORY_MB}" \
    --cpus "${VM_CPUS}" \
    --firmware bios \
    --chipset piix3 \
    --ioapic on \
    --pae on \
    --longmode on \
    --hwvirtex on \
    --nestedpaging on \
    --vtxvpid on \
    --rtcuseutc on \
    --audio none \
    --graphicscontroller vmsvga \
    --vram 16 \
    --boot1 dvd \
    --boot2 disk \
    --boot3 none \
    --boot4 none \
    --nic1 hostonly \
    --hostonlyadapter1 "${HOSTONLY_ADAPTER}" \
    --nictype1 82540EM \
    --macaddress1 "$(printf '%s' "${HOSTONLY_MAC}" | tr -d ':')" \
    --cableconnected1 on \
    --nic2 nat \
    --nictype2 82540EM \
    --macaddress2 "$(printf '%s' "${NAT_MAC}" | tr -d ':')" \
    --cableconnected2 on \
    --natdnshostresolver2 on \
    --natdnsproxy2 on

  vboxmanage storagectl "${name}" \
    --name SATA \
    --add sata \
    --controller IntelAhci \
    --portcount 2 \
    --bootable on

  if [[ ! -f "${DISK_PATH}" ]]; then
    vboxmanage createmedium disk \
      --filename "$(host_path "${DISK_PATH}")" \
      --size "$((VM_DISK_GB * 1024))" \
      --format VDI \
      --variant Standard
  fi

  vboxmanage storageattach "${name}" \
    --storagectl SATA \
    --port 0 \
    --device 0 \
    --type hdd \
    --medium "$(host_path "${DISK_PATH}")"

  if [[ -n "${iso_path}" ]]; then
    attach_iso "${iso_path}"
  else
    vboxmanage storageattach "${name}" \
      --storagectl SATA \
      --port 1 \
      --device 0 \
      --type dvddrive \
      --medium emptydrive
  fi

  vboxmanage modifyvm "${name}" \
    --uart1 0x3F8 4 \
    --uartmode1 file "$(host_path "${OUTPUT_DIR}/sno-serial.log")"
}

attach_iso() {
  local iso_path="$1"
  if [[ "${iso_path}" != /* ]]; then
    iso_path="${REPO_ROOT}/${iso_path#./}"
  fi
  if [[ "${DRY_RUN}" != "1" ]]; then
    [[ -f "${iso_path}" ]] || die "ISO not found: ${iso_path}"
  fi
  log "Attaching ISO ${iso_path}"
  vboxmanage storageattach "${VM_NAME}" \
    --storagectl SATA \
    --port 1 \
    --device 0 \
    --type dvddrive \
    --medium "$(host_path "${iso_path}")"
  vboxmanage modifyvm "${VM_NAME}" --boot1 dvd --boot2 disk
}

eject_iso() {
  log "Ejecting installer ISO so later reboots use the installed disk"
  vboxmanage storageattach "${VM_NAME}" \
    --storagectl SATA \
    --port 1 \
    --device 0 \
    --type dvddrive \
    --medium emptydrive
  vboxmanage modifyvm "${VM_NAME}" --boot1 disk --boot2 none || true
}

start_sno_vm() {
  if vm_running "${VM_NAME}"; then
    log "VM ${VM_NAME} is already running"
    return 0
  fi
  log "Starting VM ${VM_NAME} headless"
  vboxmanage startvm "${VM_NAME}" --type headless
}

stop_sno_vm() {
  if vm_running "${VM_NAME}"; then
    log "Powering off ${VM_NAME}"
    vboxmanage controlvm "${VM_NAME}" poweroff || true
    sleep 2
  fi
}

destroy_sno_vm() {
  local name="${VM_NAME}"
  if ! vm_exists "${name}"; then
    log "VM ${name} does not exist"
    return 0
  fi
  stop_sno_vm
  log "Deleting VM ${name}"
  vboxmanage unregistervm "${name}" --delete
  rm -f "${DISK_PATH}"
}

ensure_ssh_key() {
  mkdir -p "${OUTPUT_DIR}"
  if [[ ! -f "${SSH_KEY}" ]]; then
    log "Generating SSH key ${SSH_KEY}"
    ssh-keygen -t ed25519 -N "" -f "${SSH_KEY}" -C "okd-sno-lab"
  fi
  chmod 600 "${SSH_KEY}"
  SSH_PUB="$(cat "${SSH_KEY}.pub")"
}

pull_secret_json() {
  if [[ -f "${REPO_ROOT}/pull-secret.json" ]]; then
    tr -d '\n' < "${REPO_ROOT}/pull-secret.json"
  elif [[ -f "${OUTPUT_DIR}/pull-secret.json" ]]; then
    tr -d '\n' < "${OUTPUT_DIR}/pull-secret.json"
  else
    # OKD images on quay.io are public; the installer still requires the field.
    printf '%s' '{"auths":{"fake":{"auth":"aWQ6cGFzcw=="}}}'
  fi
}

tools_os_arch() {
  local os arch
  case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="mac" ;;
    *) die "ISO generation is supported on Linux or macOS. Found: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="" ;;
    arm64|aarch64)
      if [[ "${os}" == "mac" ]]; then
        arch="-arm64"
      else
        arch="-arm64"
      fi
      ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
  printf '%s %s' "${os}" "${arch}"
}

print_lab_summary() {
  cat <<EOF

Single-node OKD lab
  VM name:     ${VM_NAME}
  vCPU / RAM:  ${VM_CPUS} / ${VM_MEMORY_MB} MB
  Disk:        ${VM_DISK_GB} GB (${DISK_PATH})
  Node IP:     ${SNO_IP}
  Hostname:    ${SNO_HOSTNAME}
  Cluster:     ${CLUSTER_FQDN}
  API:         ${API_URL}
  Console:     ${CONSOLE_URL}

EOF
}
