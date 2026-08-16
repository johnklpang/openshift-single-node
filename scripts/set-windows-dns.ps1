# Requires: Windows PowerShell 5+ on the laptop that runs VirtualBox.
# Points the VirtualBox host-only NIC at the helper VM DNS so *.apps.okd.lab resolves.
param(
    [string]$HelperIp = "192.168.56.10",
    [string]$SnoIp = "192.168.56.20",
    [string]$HostIp = "192.168.56.1",
    [string]$ClusterFqdn = "okd.lab"
)

$ErrorActionPreference = "Stop"

$adapter = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $HostIp } |
    Select-Object -First 1

if (-not $adapter) {
    Write-Warning "No adapter with IP $HostIp found. Skipping DNS change."
    Write-Warning "Add these lines to C:\Windows\System32\drivers\etc\hosts instead:"
    Write-Host "$SnoIp api.$ClusterFqdn"
    Write-Host "$SnoIp api-int.$ClusterFqdn"
    Write-Host "$SnoIp console-openshift-console.apps.$ClusterFqdn"
    Write-Host "$SnoIp oauth-openshift.apps.$ClusterFqdn"
    exit 0
}

$ifIndex = $adapter.InterfaceIndex
Write-Host "Setting DNS on interface index $ifIndex ($($adapter.InterfaceAlias)) to $HelperIp"
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $HelperIp

$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$entries = @(
    "$SnoIp api.$ClusterFqdn",
    "$SnoIp api-int.$ClusterFqdn",
    "$SnoIp sno.$ClusterFqdn",
    "$SnoIp console-openshift-console.apps.$ClusterFqdn",
    "$SnoIp oauth-openshift.apps.$ClusterFqdn",
    "$SnoIp downloads-openshift-console.apps.$ClusterFqdn",
    "$HelperIp helper.$ClusterFqdn"
)
$existing = Get-Content -Path $hostsPath -ErrorAction SilentlyContinue
foreach ($line in $entries) {
    if ($existing -notcontains $line) {
        Add-Content -Path $hostsPath -Value $line
        Write-Host "Added hosts entry: $line"
    }
}

Write-Host "Windows DNS helper finished. Test: nslookup api.$ClusterFqdn $HelperIp"
