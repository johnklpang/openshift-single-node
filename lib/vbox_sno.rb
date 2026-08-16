# frozen_string_literal: true

require "open3"
require "socket"
require "timeout"
require "fileutils"

# VirtualBox helpers used by the Vagrantfile to create the single-node OKD VM.
# The SNO node is not a Vagrant box: it boots a generated CentOS Stream CoreOS ISO.
module VboxSno
  module_function

  def vboxmanage_bin
    candidates = [
      ENV["VBOX_MANAGE"],
      "VBoxManage",
      "VBoxManage.exe",
      "C:\\Program Files\\Oracle\\VirtualBox\\VBoxManage.exe",
      "/usr/bin/VBoxManage",
      "/usr/local/bin/VBoxManage"
    ].compact

    candidates.each do |path|
      return path if path.include?("\\") && File.exist?(path)

      _out, _err, status = Open3.capture3(path, "--version")
      return path if status.success?
    rescue Errno::ENOENT, Errno::EACCES
      next
    end

    raise "VBoxManage not found. Install VirtualBox 7.x and ensure VBoxManage is on PATH."
  end

  def vboxmanage(*args)
    cmd = [vboxmanage_bin, *args.map(&:to_s)]
    stdout, stderr, status = Open3.capture3(*cmd)
    unless status.success?
      raise "VBoxManage failed (#{cmd.join(' ')}):\n#{stderr}\n#{stdout}"
    end

    stdout
  end

  def vm_exists?(name)
    vboxmanage("list", "vms").include?("\"#{name}\"")
  end

  def vm_running?(name)
    vboxmanage("list", "runningvms").include?("\"#{name}\"")
  end

  # Prefer the adapter that already has 192.168.56.1 (Vagrant host-only default).
  def hostonly_adapter_name(expected_ip = "192.168.56.1")
    block = vboxmanage("list", "hostonlyifs")
    adapters = block.split(/\n(?=Name:)/)
    match = adapters.find { |text| text =~ /IPAddress:\s+#{Regexp.escape(expected_ip)}\b/ }
    match ||= adapters.first
    raise "No VirtualBox host-only adapter found. Start the helper VM first." unless match

    name_line = match.lines.find { |line| line.start_with?("Name:") }
    raise "Unable to parse host-only adapter name" unless name_line

    name_line.split(":", 2).last.strip
  end

  def wait_for_tcp(ip, port, timeout_sec: 900, interval: 5)
    deadline = Time.now + timeout_sec
    loop do
      begin
        socket = TCPSocket.new(ip, port)
        socket.close
        return true
      rescue StandardError
        raise "Timed out waiting for #{ip}:#{port}" if Time.now > deadline

        sleep interval
      end
    end
  end

  def ensure_sno_vm(cfg, iso_path)
    name = cfg.fetch("sno_vm_name")
    return name if vm_exists?(name)

    disk_path = File.join(cfg.fetch("output_dir"), "#{name}.vdi")
    adapter = hostonly_adapter_name(cfg.fetch("host_ip"))

    vboxmanage("createvm", "--name", name, "--ostype", "RedHat_64", "--register")
    vboxmanage(
      "modifyvm", name,
      "--memory", cfg.fetch("sno_memory_mb").to_s,
      "--cpus", cfg.fetch("sno_cpus").to_s,
      "--firmware", "bios",
      "--ioapic", "on",
      "--pae", "on",
      "--hwvirtex", "on",
      "--nestedpaging", "on",
      "--rtcuseutc", "on",
      "--boot1", "dvd",
      "--boot2", "disk",
      "--boot3", "none",
      "--boot4", "none"
    )
    vboxmanage(
      "modifyvm", name,
      "--nic1", "hostonly",
      "--hostonlyadapter1", adapter,
      "--nictype1", "82540EM",
      "--cableconnected1", "on"
    )
    vboxmanage(
      "modifyvm", name,
      "--uart1", "0x3F8", "4",
      "--uartmode1", "file", File.join(cfg.fetch("output_dir"), "sno-serial.log")
    )
    vboxmanage(
      "storagectl", name,
      "--name", "SATA",
      "--add", "sata",
      "--controller", "IntelAhci",
      "--portcount", "2",
      "--bootable", "on"
    )

    unless File.exist?(disk_path)
      vboxmanage(
        "createmedium", "disk",
        "--filename", disk_path,
        "--size", (cfg.fetch("sno_disk_gb").to_i * 1024).to_s,
        "--format", "VDI",
        "--variant", "Standard"
      )
    end

    vboxmanage(
      "storageattach", name,
      "--storagectl", "SATA",
      "--port", "0",
      "--device", "0",
      "--type", "hdd",
      "--medium", disk_path
    )
    vboxmanage(
      "storageattach", name,
      "--storagectl", "SATA",
      "--port", "1",
      "--device", "0",
      "--type", "dvddrive",
      "--medium", iso_path
    )
    vboxmanage("modifyvm", name, "--boot1", "dvd", "--boot2", "disk")
    name
  end

  def start_sno_vm(name)
    return if vm_running?(name)

    vboxmanage("startvm", name, "--type", "headless")
  end

  def eject_iso(name)
    vboxmanage(
      "storageattach", name,
      "--storagectl", "SATA",
      "--port", "1",
      "--device", "0",
      "--type", "dvddrive",
      "--medium", "emptydrive"
    )
    vboxmanage("modifyvm", name, "--boot1", "disk", "--boot2", "none")
  end

  def destroy_sno_vm(name)
    return unless vm_exists?(name)

    vboxmanage("controlvm", name, "poweroff") if vm_running?(name)
    sleep 2
    vboxmanage("unregistervm", name, "--delete")
  end

  def windows?
    Vagrant::Util::Platform.windows?
  rescue NameError
    File::ALT_SEPARATOR == "\\"
  end
end
