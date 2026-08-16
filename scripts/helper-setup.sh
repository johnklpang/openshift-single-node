#!/usr/bin/env bash
# Configure the helper VM as DNS, default gateway, and NAT for the SNO node.
set -euo pipefail

HELPER_IP="${HELPER_IP:-192.168.56.10}"
NETWORK_CIDR="${NETWORK_CIDR:-192.168.56.0/24}"
SNO_IP="${SNO_IP:-192.168.56.20}"
CLUSTER_NAME="${CLUSTER_NAME:-okd}"
BASE_DOMAIN="${BASE_DOMAIN:-lab}"
CLUSTER_FQDN="${CLUSTER_NAME}.${BASE_DOMAIN}"

echo "==> Installing helper packages"
dnf -y install \
  podman \
  curl \
  jq \
  tar \
  unzip \
  dnsmasq \
  bind-utils \
  firewalld \
  chrony \
  iproute \
  procps-ng \
  NetworkManager \
  openssh-clients

systemctl enable --now firewalld
systemctl enable --now chronyd
systemctl enable --now NetworkManager

echo "==> Enabling IPv4 forwarding"
cat >/etc/sysctl.d/99-okd-forward.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
EOF
sysctl -p /etc/sysctl.d/99-okd-forward.conf

HOSTONLY_IF="$(ip -4 -o addr show | awk -v ip="${HELPER_IP}/" 'index($0, ip) {print $2; exit}')"
if [[ -z "${HOSTONLY_IF}" ]]; then
  echo "ERROR: could not find the interface that owns ${HELPER_IP}" >&2
  ip -4 addr
  exit 1
fi
echo "==> Host-only interface is ${HOSTONLY_IF}"

# Keep helper's own DNS on a public resolver so ISO/tool downloads still work.
NAT_IF="$(ip -4 route show default | awk '{print $5; exit}')"
if [[ -n "${NAT_IF}" ]]; then
  NAT_CON="$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v dev="$NAT_IF" '$2==dev {print $1; exit}')"
  if [[ -n "${NAT_CON}" ]]; then
    nmcli connection modify "${NAT_CON}" ipv4.ignore-auto-dns yes ipv4.dns "8.8.8.8,1.1.1.1" || true
    nmcli connection up "${NAT_CON}" || true
  fi
fi

echo "==> Configuring dnsmasq for ${CLUSTER_FQDN}"
mkdir -p /etc/dnsmasq.d
cat >/etc/dnsmasq.d/okd-lab.conf <<EOF
# Authoritative wildcard DNS for the lab. Bind only to the host-only NIC.
listen-address=${HELPER_IP}
bind-interfaces
no-resolv
no-hosts
domain=${CLUSTER_FQDN}
local=/${CLUSTER_FQDN}/
address=/api.${CLUSTER_FQDN}/${SNO_IP}
address=/api-int.${CLUSTER_FQDN}/${SNO_IP}
address=/apps.${CLUSTER_FQDN}/${SNO_IP}
address=/sno.${CLUSTER_FQDN}/${SNO_IP}
address=/helper.${CLUSTER_FQDN}/${HELPER_IP}
server=8.8.8.8
server=1.1.1.1
cache-size=1000
EOF

# Avoid NetworkManager's local stub taking port 53 on the host-only address.
mkdir -p /etc/NetworkManager/conf.d
cat >/etc/NetworkManager/conf.d/90-okd-dns.conf <<'EOF'
[main]
dns=none
EOF
systemctl reload NetworkManager || true
cat >/etc/resolv.conf <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

systemctl enable dnsmasq
systemctl restart dnsmasq

echo "==> Configuring firewall masquerade (SNO uses this helper as its gateway)"
firewall-cmd --permanent --add-masquerade
firewall-cmd --permanent --add-service=dns
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${NETWORK_CIDR} accept"
firewall-cmd --reload

echo "==> Helper networking ready"
ip -4 addr show
echo "dnsmasq self-test:"
dig +short "api.${CLUSTER_FQDN}" @"${HELPER_IP}" || true
dig +short "console-openshift-console.apps.${CLUSTER_FQDN}" @"${HELPER_IP}" || true
