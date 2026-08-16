#Requires -Version 5.1
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

function Assert-Command($name, $hint) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "$name is not on PATH. $hint"
    }
}

Assert-Command "vagrant" "Install Vagrant from https://developer.hashicorp.com/vagrant/install"
$vbox = Get-Command "VBoxManage" -ErrorAction SilentlyContinue
if (-not $vbox) {
    $default = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
    if (Test-Path $default) {
        $env:Path = "$(Split-Path $default);$env:Path"
    } else {
        throw "VBoxManage is not on PATH. Install VirtualBox 7.x from https://www.virtualbox.org/"
    }
}

Write-Host "Starting OKD single-node lab (first run often takes 60-90 minutes)..."
vagrant up --provider virtualbox
