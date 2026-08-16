# -*- mode: ruby -*-
# vi: set ft=ruby :
# frozen_string_literal: true

# Single-node OKD (community OpenShift) on VirtualBox for a 32 GB Windows 11 laptop.
# `vagrant up` starts a small helper VM, builds the install ISO, then creates the
# SNO VM with VBoxManage and waits until the cluster is ready.

require "yaml"
require "fileutils"
require_relative "lib/vbox_sno"

ENV["VAGRANT_DEFAULT_PROVIDER"] = "virtualbox"

def load_lab_config
  path = File.join(__dir__, "config.yml")
  cfg = YAML.load_file(path)
  overrides = {
    "okd_version" => "OKD_VERSION",
    "helper_box" => "HELPER_BOX",
    "helper_cpus" => "HELPER_CPUS",
    "helper_memory_mb" => "HELPER_MEMORY_MB",
    "sno_cpus" => "SNO_CPUS",
    "sno_memory_mb" => "SNO_MEMORY_MB",
    "sno_disk_gb" => "SNO_DISK_GB"
  }
  overrides.each do |key, env_name|
    next if ENV[env_name].to_s.empty?

    cfg[key] = key.match?(/cpus|memory|disk/) ? Integer(ENV[env_name]) : ENV[env_name]
  end
  cfg["output_dir"] = File.join(__dir__, "output")
  FileUtils.mkdir_p(cfg["output_dir"])
  cfg
end

def provision_env(cfg)
  cluster_fqdn = "#{cfg['cluster_name']}.#{cfg['base_domain']}"
  {
    "OKD_VERSION" => cfg["okd_version"].to_s,
    "CLUSTER_NAME" => cfg["cluster_name"].to_s,
    "BASE_DOMAIN" => cfg["base_domain"].to_s,
    "NETWORK_CIDR" => cfg["network_cidr"].to_s,
    "HELPER_IP" => cfg["helper_ip"].to_s,
    "SNO_IP" => cfg["sno_ip"].to_s,
    "SNO_HOSTNAME" => "sno.#{cluster_fqdn}",
    "WORK_DIR" => "/opt/okd",
    "OUTPUT_DIR" => "/opt/okd-output"
  }
end

def env_exports(cfg)
  provision_env(cfg).map { |key, value| "#{key}='#{value}'" }.join(" ")
end

def iso_on_host(cfg)
  File.join(cfg["output_dir"], "okd-sno-live.iso")
end

def fetch_iso_from_guest(machine, cfg)
  host_iso = iso_on_host(cfg)
  return host_iso if File.exist?(host_iso) && File.size(host_iso) > 10_000_000

  %w[/opt/okd-output/okd-sno-live.iso /opt/okd/okd-sno-live.iso].each do |guest_path|
    next unless machine.communicate.test("test -s #{guest_path}")

    puts "==> Downloading ISO from helper #{guest_path} (this can take several minutes)"
    machine.communicate.download(guest_path, host_iso)
    return host_iso
  end

  raise "Install ISO not found on the helper VM. Re-run: vagrant provision helper --provision-with iso"
end

def configure_windows_dns(cfg)
  return unless VboxSno.windows?

  script = File.join(__dir__, "scripts", "set-windows-dns.ps1")
  cmd = [
    "powershell.exe",
    "-ExecutionPolicy", "Bypass",
    "-File", script,
    "-HelperIp", cfg["helper_ip"].to_s,
    "-SnoIp", cfg["sno_ip"].to_s,
    "-HostIp", cfg["host_ip"].to_s,
    "-ClusterFqdn", "#{cfg['cluster_name']}.#{cfg['base_domain']}"
  ]
  puts "==> Configuring Windows host-only DNS (run PowerShell as Administrator if this fails)"
  system(*cmd)
end

def start_okd_cluster(machine, cfg)
  name = cfg["sno_vm_name"]
  kubeconfig = File.join(cfg["output_dir"], "kubeconfig")
  iso_path = fetch_iso_from_guest(machine, cfg)
  first_boot = !VboxSno.vm_exists?(name)

  VboxSno.ensure_sno_vm(cfg, iso_path)
  VboxSno.start_sno_vm(name)

  if first_boot
    puts "==> Waiting for live ISO SSH on #{cfg['sno_ip']}:22"
    VboxSno.wait_for_tcp(cfg["sno_ip"], 22, timeout_sec: 1200)
    puts "==> Ejecting installer ISO so later reboots use the installed disk"
    VboxSno.eject_iso(name)
  end

  return if File.exist?(kubeconfig)

  puts "==> Waiting for OpenShift install-complete (often 45-90 minutes)"
  machine.communicate.sudo("#{env_exports(cfg)} bash /tmp/wait-install.sh")
  configure_windows_dns(cfg)
end

CFG = load_lab_config
CLUSTER_FQDN = "#{CFG['cluster_name']}.#{CFG['base_domain']}"

Vagrant.configure("2") do |config|
  config.vm.box_check_update = false
  config.vm.boot_timeout = 600
  config.ssh.insert_key = true
  config.ssh.keep_alive = true
  config.ssh.forward_agent = false

  config.vm.define "helper", primary: true do |helper|
    helper.vm.box = CFG["helper_box"]
    helper.vm.hostname = "helper.#{CLUSTER_FQDN}"
    helper.vm.network "private_network", ip: CFG["helper_ip"]

    helper.vm.provider "virtualbox" do |vb|
      vb.name = CFG["helper_vm_name"]
      vb.memory = CFG["helper_memory_mb"]
      vb.cpus = CFG["helper_cpus"]
      vb.gui = false
    end

    helper.vm.synced_folder ".", "/vagrant", disabled: true
    helper.vm.synced_folder "output", "/opt/okd-output", create: true

    if File.exist?(File.join(__dir__, "pull-secret.json"))
      FileUtils.cp(File.join(__dir__, "pull-secret.json"), File.join(CFG["output_dir"], "pull-secret.json"))
    end

    helper.vm.provision "scripts", type: "file", source: "scripts", destination: "/tmp/okd-scripts"
    helper.vm.provision "wait-script", type: "file", source: "scripts/wait-install.sh", destination: "/tmp/wait-install.sh"
    helper.vm.provision "chmod-scripts", type: "shell", inline: <<-SHELL
      sed -i 's/\\r$//' /tmp/wait-install.sh /tmp/okd-scripts/*.sh 2>/dev/null || true
      chmod +x /tmp/wait-install.sh /tmp/okd-scripts/*.sh 2>/dev/null || chmod +x /tmp/wait-install.sh
    SHELL
    helper.vm.provision "setup", type: "shell", path: "scripts/helper-setup.sh", env: provision_env(CFG)
    helper.vm.provision "iso", type: "shell", path: "scripts/build-iso.sh", env: provision_env(CFG)

    helper.trigger.after :up do |trigger|
      trigger.name = "Boot single-node OKD VM"
      trigger.ruby do |_env, machine|
        start_okd_cluster(machine, CFG)
      end
    end

    helper.trigger.before :destroy do |trigger|
      trigger.name = "Remove single-node OKD VM"
      trigger.ruby do |_env, _machine|
        VboxSno.destroy_sno_vm(CFG["sno_vm_name"])
      end
    end
  end
end
