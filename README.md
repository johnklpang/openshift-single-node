# Single-node OpenShift (OKD) on one VirtualBox VM

Step-by-step lab that installs **single-node OKD** (community OpenShift) for testing. The cluster is one VirtualBox VM. A bash script creates that VM with `VBoxManage`.

This is **not** OpenShift Local (CRC). CRC does not support VirtualBox. Official OpenShift Container Platform needs a Red Hat pull secret; OKD does not.

## What you get

| Item | Default |
| --- | --- |
| Topology | Single Node OpenShift: 1 control plane, 0 workers |
| Hypervisor | VirtualBox 7.x, one VM named `okd-sno` |
| Guest | CentOS Stream CoreOS via the OKD Agent installer ISO |
| Size | 8 vCPU / 16 GB RAM / 120 GB sparse disk |
| NICs | Host-only `192.168.56.20` (API/console) + NAT (image pulls) |
| DNS | `sslip.io` wildcard records, no extra DNS VM |
| Version | OKD `4.22.0-okd-scos.8` (override in `config.env`) |

The VM is the cluster. There is no helper VM and no nested CRC.

## Requirements

On the machine that will run VirtualBox (the administration host):

1. **VirtualBox 7.x** with `VBoxManage` on `PATH`
2. **Hardware virtualization** enabled in firmware (Intel VT-x or AMD-V)
3. **About 24 GB RAM** so the 16 GB VM and the host OS both fit
4. **About 150 GB free disk** (120 GB sparse VDI + installer ISO + image pulls on the guest)
5. **Linux or macOS** (or WSL2/Git Bash calling Windows VirtualBox) with `bash`, `curl`, `tar`, `ssh-keygen`
6. Outbound HTTPS to `github.com` and `quay.io`

Windows 11: install VirtualBox, then run the scripts from Git Bash or WSL. If Hyper-V / Core Isolation blocks VirtualBox, use the VirtualBox Hyper-V backend or disable Core Isolation.

Low-RAM laptop (32 GB Windows): set `VM_CPUS=4` in `config.local.env`. That is the documented SNO *minimum* and leaves little room for test apps.

## Quick start

```bash
git clone https://github.com/johnklpang/openshift-single-node.git
cd openshift-single-node
./scripts/up.sh
```

First boot often takes **45–90 minutes** while the node pulls release images. Keep the host awake.

When it finishes:

```bash
export KUBECONFIG=$PWD/output/kubeconfig
./output/bin/oc get nodes
./output/bin/oc get clusteroperators

# Console
# URL:      https://console-openshift-console.apps.okd.192.168.56.20.sslip.io
# User:     kubeadmin
# Password: $(cat output/kubeadmin-password)
```

Accept the self-signed API/console certificates in the browser or with `oc login --insecure-skip-tls-verify`.

## Step by step

Run these in order if you want to see each stage instead of `./scripts/up.sh`.

### 1. Install VirtualBox

- Linux: install the vendor package for your distro, then confirm `VBoxManage --version`
- macOS: install VirtualBox, grant the kernel extension if prompted
- Windows: install VirtualBox 7.x; `VBoxManage.exe` is under `C:\Program Files\Oracle\VirtualBox\`

Enable VT-x/AMD-V. On Windows, if VMs fail to start, check Hyper-V, WSL2, and Core Isolation.

### 2. Clone this repo and check the host

```bash
./scripts/prereq.sh
```

Optional local overrides (not committed):

```bash
cp config.env config.local.env
# edit VM_CPUS, VM_MEMORY_MB, OKD_VERSION, ...
```

### 3. Choose DNS (default needs no daemon)

OpenShift requires these names to resolve to the node IP:

| Record | Example with defaults |
| --- | --- |
| `api.<cluster>.<baseDomain>` | `api.okd.192.168.56.20.sslip.io` |
| `api-int.<cluster>.<baseDomain>` | `api-int.okd.192.168.56.20.sslip.io` |
| `*.apps.<cluster>.<baseDomain>` | `*.apps.okd.192.168.56.20.sslip.io` |

Default `DNS_MODE=sslip` uses [sslip.io](https://sslip.io) so the host and the VM only need public DNS. If that is blocked, set `DNS_MODE=dnsmasq` and `BASE_DOMAIN=lab` in `config.local.env`, then run `./scripts/setup-dns.sh`.

### 4. Generate the Agent installer ISO

```bash
./scripts/prepare-iso.sh
```

This downloads `openshift-install` and `oc` from the OKD GitHub release, writes `install-config.yaml` + `agent-config.yaml`, and runs:

```text
openshift-install agent create image --dir output/cluster
```

Output: `output/cluster/agent.x86_64.iso`. Rebuild with `--force`.

For **Red Hat OpenShift** instead of OKD, put a pull secret from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret) in `pull-secret.json` and point `OKD_VERSION` / the installer archive at an OpenShift Container Platform release. The VM script stays the same.

### 5. Create one VirtualBox VM

This is the automated script that spins up the node:

```bash
./scripts/create-vm.sh --iso output/cluster/agent.x86_64.iso
```

What it does:

1. Creates a host-only adapter on `192.168.56.1/24` if needed
2. Registers VM `okd-sno` (8 vCPU, 16 GB RAM, 120 GB VDI)
3. Attaches two Intel PRO/1000 NICs: host-only (static `192.168.56.20`) and NAT (internet)
4. Attaches the Agent ISO and starts the VM headless

Useful flags:

```bash
./scripts/create-vm.sh --help
./scripts/create-vm.sh --cpus 4 --memory-mb 16384 --disk-gb 120 --iso output/cluster/agent.x86_64.iso
./scripts/create-vm.sh --dry-run --no-start
./scripts/create-vm.sh --force --iso output/cluster/agent.x86_64.iso
```

You can also create the empty VM first and attach an ISO later:

```bash
./scripts/create-vm.sh --no-start
./scripts/create-vm.sh --iso output/cluster/agent.x86_64.iso
```

### 6. Wait until the cluster is installed

```bash
./scripts/wait-install.sh
```

The installer talks to the node on the host-only IP. If VirtualBox leaves the VM powered off across the CoreOS reboot, the wait script starts it again and ejects the ISO so the second boot uses the installed disk.

### 7. Use the cluster

```bash
export KUBECONFIG=$PWD/output/kubeconfig
./output/bin/oc get nodes
./output/bin/oc get co
ssh -i output/id_ed25519 core@192.168.56.20
./scripts/status.sh
```

### 8. Tear down

```bash
./scripts/destroy-vm.sh
# optional: rm -rf output/cluster output/*.vdi output/bin
```

## Networking (why two NICs)

| Adapter | VirtualBox | Guest name | Address | Purpose |
| --- | --- | --- | --- | --- |
| nic1 | Host-only | `enp0s3` | `192.168.56.20/24` | API (`6443`), console (`443`), SSH (`22`) |
| nic2 | NAT (DHCP) | `enp0s8` | `10.0.2.15/24` via `10.0.2.2` | Pull images from `quay.io` |

MACs are fixed in `config.env` and must match `agent-config.yaml`. Do not change one without the other.

## Scripts

| Script | Role |
| --- | --- |
| `scripts/up.sh` | Full path: prereq → ISO → create VM → wait |
| `scripts/create-vm.sh` | Create/start the single VirtualBox VM |
| `scripts/destroy-vm.sh` | Power off and delete the VM |
| `scripts/prepare-iso.sh` | Download OKD tools and build `agent.x86_64.iso` |
| `scripts/wait-install.sh` | `agent wait-for bootstrap-complete` then `install-complete` |
| `scripts/prereq.sh` | Host checks |
| `scripts/setup-dns.sh` | sslip / dnsmasq / hosts helper |
| `scripts/status.sh` | VM + cluster status |
| `config.env` | Defaults (override with `config.local.env`) |

## Troubleshooting

**VM will not start.** Confirm VT-x/AMD-V, and on Windows disable or configure Hyper-V / Memory Integrity. `VBoxManage startvm okd-sno --type gui` shows firmware errors.

**Bootstrap hangs on DNS or NTP.** The node must resolve `api-int.<cluster>.<baseDomain>` and reach `time.google.com` through NAT. Serial log: `output/sno-serial.log`. SSH: `ssh -i output/id_ed25519 core@192.168.56.20`.

**sslip.io does not resolve.** Set `DNS_MODE=dnsmasq` and `BASE_DOMAIN=lab`, rebuild the ISO (`prepare-iso.sh --force`), recreate the VM.

**Install stops after reboot.** `wait-install.sh` should power the VM back on. Manually: `VBoxManage startvm okd-sno --type headless`. Make sure the DVD was ejected.

**Out of memory.** Drop optional operators by keeping `FULL_CAPABILITIES=false` (default). Do not install OpenShift Virtualization or ODF on a 16 GB node.

**Want a full operator set.** `FULL_CAPABILITIES=true` in `config.local.env`, then rebuild the ISO. Prefer 32 GB RAM in the VM.

## Security

This lab is for local testing. It uses a dummy pull secret for public OKD images, a generated SSH key, and `kubeadmin`. Do not expose the host-only network or console to untrusted networks.
