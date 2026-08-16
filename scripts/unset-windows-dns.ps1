param(
    [string]$HostIp = "192.168.56.1",
    [string]$ClusterFqdn = "okd.lab"
)

$ErrorActionPreference = "Stop"

$adapter = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $HostIp } |
    Select-Object -First 1

if ($adapter) {
    Write-Host "Resetting DNS on $($adapter.InterfaceAlias) to DHCP/automatic"
    Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ResetServerAddresses
}

$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
if (Test-Path $hostsPath) {
    $filtered = Get-Content $hostsPath | Where-Object { $_ -notmatch [regex]::Escape($ClusterFqdn) }
    Set-Content -Path $hostsPath -Value $filtered
    Write-Host "Removed $ClusterFqdn entries from hosts file"
}
