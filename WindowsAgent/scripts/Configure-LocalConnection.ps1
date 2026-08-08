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

$localAddressRecords = @(
    Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction Stop |
        Where-Object {
            $_.IPAddress -ne "127.0.0.1" -and
            (Test-PrivateIPv4Address -Address $_.IPAddress)
        }
)
$localAddresses = @($localAddressRecords | Select-Object -ExpandProperty IPAddress -Unique)

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
$bindAddressRecords = @($localAddressRecords | Where-Object { $_.IPAddress -eq $BindAddress })
if ($bindAddressRecords.Count -ne 1) {
    throw "BindAddress $BindAddress must identify exactly one active Windows interface."
}
$bindInterfaceAlias = $bindAddressRecords[0].InterfaceAlias

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

$rootPrivateKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($rootCertificate)
try {
    if ($null -eq $rootPrivateKey -or
        ($rootPrivateKey.Key.ExportPolicy -band [System.Security.Cryptography.CngExportPolicies]::AllowExport) -ne 0 -or
        ($rootPrivateKey.Key.ExportPolicy -band [System.Security.Cryptography.CngExportPolicies]::AllowPlaintextExport) -ne 0) {
        throw "The local root certificate private key is missing or exportable. Refusing to continue."
    }
} finally {
    if ($null -ne $rootPrivateKey) { $rootPrivateKey.Dispose() }
}

Export-Certificate -Cert $rootCertificate -FilePath $rootExportPath -Force | Out-Null
$trustedRoot = Get-ChildItem Cert:\CurrentUser\Root |
    Where-Object { $_.Thumbprint -eq $rootCertificate.Thumbprint } |
    Select-Object -First 1
if ($null -eq $trustedRoot) {
    Import-Certificate -FilePath $rootExportPath -CertStoreLocation "Cert:\CurrentUser\Root" | Out-Null
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

$serverPrivateKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($serverCertificate)
try {
    if ($null -eq $serverPrivateKey -or
        ($serverPrivateKey.Key.ExportPolicy -band [System.Security.Cryptography.CngExportPolicies]::AllowExport) -ne 0 -or
        ($serverPrivateKey.Key.ExportPolicy -band [System.Security.Cryptography.CngExportPolicies]::AllowPlaintextExport) -ne 0) {
        throw "The server certificate private key is missing or exportable. Refusing to continue."
    }
} finally {
    if ($null -ne $serverPrivateKey) { $serverPrivateKey.Dispose() }
}

$serverSan = ($serverCertificate.Extensions |
    Where-Object { $_.Oid.Value -eq "2.5.29.17" } |
    Select-Object -First 1).Format($false)
if ($serverSan -notmatch [regex]::Escape($BindAddress)) {
    throw "The generated server certificate SAN does not contain $BindAddress."
}

$certificateStore = [System.Security.Cryptography.X509Certificates.X509Store]::new("My", "CurrentUser")
$certificateStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
try {
    $validMatches = $certificateStore.Certificates.Find(
        [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
        $serverCertificate.Thumbprint,
        $true)
    if ($validMatches.Count -ne 1 -or -not $validMatches[0].HasPrivateKey) {
        throw "The generated server certificate failed strict trusted-chain validation."
    }
} finally {
    $certificateStore.Close()
}

$capabilitySettings = [ordered]@{
    WindowsAudioEnabled = $true
    GoXlrEnabled = $true
    GoXlrClientPath = ""
    Applications = @()
}
$audioMeterSettings = $null
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    $existingSettings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    if ($null -ne $existingSettings.Agent -and
        $null -ne $existingSettings.Agent.PSObject.Properties["Capabilities"] -and
        $null -ne $existingSettings.Agent.Capabilities) {
        $capabilitySettings = $existingSettings.Agent.Capabilities
    }
    if ($null -ne $existingSettings.Agent -and
        $null -ne $existingSettings.Agent.PSObject.Properties["AudioMeters"] -and
        $null -ne $existingSettings.Agent.AudioMeters) {
        $audioMeterSettings = $existingSettings.Agent.AudioMeters
    }
}

$settings = [ordered]@{
    Agent = [ordered]@{
        BindAddress = $BindAddress
        Port = $Port
        CertificateThumbprint = $serverCertificate.Thumbprint
        PairingCodeLifetimeSeconds = 120
        MaximumPairingAttempts = 5
        Capabilities = $capabilitySettings
    }
}
if ($null -ne $audioMeterSettings) { $settings.Agent["AudioMeters"] = $audioMeterSettings }
$settings | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $settingsPath -Encoding UTF8

if (-not $SkipFirewall) {
    $ruleName = "Deck Windows Agent Local $BindAddress`:$Port"
    $existingRules = @(Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)
    if ($existingRules.Count -gt 1) {
        throw "More than one firewall rule named '$ruleName' exists. Refusing to choose one automatically."
    }
    if ($existingRules.Count -eq 0) {
        New-NetFirewallRule `
            -DisplayName $ruleName `
            -Description "Deck Agent input, limited to this private interface and local subnet." `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalAddress $BindAddress `
            -LocalPort $Port `
            -RemoteAddress LocalSubnet `
            -Profile Private `
            -InterfaceAlias ([System.Management.Automation.WildcardPattern]::Escape($bindInterfaceAlias)) `
            -EdgeTraversalPolicy Block | Out-Null
    }

    $firewallRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction Stop
    $portFilter = $firewallRule | Get-NetFirewallPortFilter
    $addressFilter = $firewallRule | Get-NetFirewallAddressFilter
    $interfaceFilter = $firewallRule | Get-NetFirewallInterfaceFilter
    if ($firewallRule.Enabled.ToString() -ne "True" -or
        $firewallRule.Direction.ToString() -ne "Inbound" -or
        $firewallRule.Action.ToString() -ne "Allow" -or
        $firewallRule.Profile.ToString() -ne "Private" -or
        $firewallRule.EdgeTraversalPolicy.ToString() -ne "Block" -or
        $portFilter.Protocol -ne "TCP" -or
        $portFilter.LocalPort -ne $Port.ToString() -or
        $addressFilter.LocalAddress -notcontains $BindAddress -or
        $addressFilter.RemoteAddress -notcontains "LocalSubnet" -or
        $interfaceFilter.InterfaceAlias -notcontains ([System.Management.Automation.WildcardPattern]::Escape($bindInterfaceAlias))) {
        throw "The firewall rule exists but does not match the required local-only scope."
    }
}

Write-Host ""
Write-Host "Local Windows Agent configured successfully." -ForegroundColor Green
Write-Host "iPad Agent address: https://$BindAddress`:$Port"
Write-Host "Windows interface: $bindInterfaceAlias"
Write-Host "Install this public root certificate on the iPad: $rootExportPath"
Write-Host "Then enable it under Settings > General > About > Certificate Trust Settings."
Write-Host "The private certificate key remains non-exportable in the Windows certificate store."
