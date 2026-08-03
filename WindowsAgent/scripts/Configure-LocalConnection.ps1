[CmdletBinding()]
param(
    [string]$BindAddress = "",
    [ValidateRange(1024, 65535)]
    [int]$Port = 8732,
    [switch]$SkipFirewall
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Test-PrivateIPv4Address {
    param([Parameter(Mandatory = $true)][string]$Address)

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    $bytes = $parsed.GetAddressBytes()
    if ($bytes.Length -ne 4) { return $false }

    return $bytes[0] -eq 10 `
        -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) `
        -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168) `
        -or ($bytes[0] -eq 169 -and $bytes[1] -eq 254)
}

$localAddresses = @(
    Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction Stop |
        Where-Object {
            $_.IPAddress -ne "127.0.0.1" -and
            (Test-PrivateIPv4Address -Address $_.IPAddress)
        } |
        Select-Object -ExpandProperty IPAddress -Unique
)

if ([string]::IsNullOrWhiteSpace($BindAddress)) {
    if ($localAddresses -contains "192.168.137.1") {
        $BindAddress = "192.168.137.1"
    } elseif ($localAddresses.Count -eq 1) {
        $BindAddress = $localAddresses[0]
    } else {
        $choices = if ($localAddresses.Count -eq 0) { "none" } else { $localAddresses -join ", " }
        throw "Choose the PC hotspot/LAN address with -BindAddress. Private addresses found: $choices"
    }
}

if (-not (Test-PrivateIPv4Address -Address $BindAddress)) {
    throw "BindAddress must be an RFC1918 or link-local IPv4 address, not a public or Tailscale address."
}
if ($localAddresses -notcontains $BindAddress) {
    throw "BindAddress $BindAddress is not currently assigned to this PC. Start Mobile Hotspot first and run this script again."
}

if (-not $SkipFirewall) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run PowerShell as Administrator to add the local-only firewall rule, or use -SkipFirewall and configure it manually."
    }
}

$projectDirectory = Split-Path -Parent $PSScriptRoot
$agentDirectory = Join-Path $projectDirectory "DeckWindowsAgent"
$settingsPath = Join-Path $agentDirectory "appsettings.Local.json"
$rootExportPath = Join-Path $projectDirectory "DeckAgent-Local-Root.cer"
$computerName = [System.Net.Dns]::GetHostName()
$dnsName = "$computerName.local"
$rootSubject = "CN=Deck Agent Local Root"

$rootCertificate = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object {
        $_.Subject -eq $rootSubject -and
        $_.HasPrivateKey -and
        $_.NotAfter -gt (Get-Date).AddDays(30)
    } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if ($null -eq $rootCertificate) {
    $rootCertificate = New-SelfSignedCertificate `
        -Type Custom `
        -Subject $rootSubject `
        -KeyAlgorithm RSA `
        -KeyLength 3072 `
        -HashAlgorithm SHA256 `
        -KeyExportPolicy NonExportable `
        -KeyUsage CertSign, CRLSign, DigitalSignature `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -NotAfter (Get-Date).AddYears(5) `
        -TextExtension @("2.5.29.19={critical}{text}ca=1&pathlength=0")
}

$serverCertificate = New-SelfSignedCertificate `
    -Type Custom `
    -Subject "CN=$dnsName" `
    -Signer $rootCertificate `
    -KeyAlgorithm RSA `
    -KeyLength 2048 `
    -HashAlgorithm SHA256 `
    -KeyExportPolicy NonExportable `
    -KeyUsage DigitalSignature, KeyEncipherment `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -NotAfter (Get-Date).AddDays(365) `
    -TextExtension @(
        "2.5.29.17={text}DNS=$dnsName&DNS=$computerName&IPAddress=$BindAddress",
        "2.5.29.37={text}1.3.6.1.5.5.7.3.1",
        "2.5.29.19={critical}{text}ca=0"
    )

Export-Certificate -Cert $rootCertificate -FilePath $rootExportPath -Force | Out-Null

$settings = [ordered]@{
    Agent = [ordered]@{
        BindAddress = $BindAddress
        Port = $Port
        CertificateThumbprint = $serverCertificate.Thumbprint
        PairingCodeLifetimeSeconds = 120
        MaximumPairingAttempts = 5
    }
}
$settings | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $settingsPath -Encoding UTF8

if (-not $SkipFirewall) {
    $ruleName = "Deck Windows Agent Local $BindAddress`:$Port"
    if ($null -eq (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule `
            -DisplayName $ruleName `
            -Description "Deck Agent input, limited to this private interface and local subnet." `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalAddress $BindAddress `
            -LocalPort $Port `
            -RemoteAddress LocalSubnet `
            -Profile Any `
            -EdgeTraversalPolicy Block | Out-Null
    }
}

Write-Host ""
Write-Host "Local Windows Agent configured successfully." -ForegroundColor Green
Write-Host "iPad Agent address: https://$BindAddress`:$Port"
Write-Host "Install this public root certificate on the iPad: $rootExportPath"
Write-Host "Then enable it under Settings > General > About > Certificate Trust Settings."
Write-Host "The private certificate key remains non-exportable in the Windows certificate store."
