[CmdletBinding()]
param(
    [string]$BindAddress = "",
    [ValidateRange(1024, 65535)]
    [int]$AgentPort = 8732,
    [ValidateRange(1024, 65535)]
    [int]$CompanionPort = 8000,
    [switch]$AllowCompanion,
    [switch]$SkipFirewall
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Test-TailscaleIPv4Address {
    param([Parameter(Mandatory = $true)][string]$Address)
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    $bytes = $parsed.GetAddressBytes()
    return $bytes.Length -eq 4 -and $bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127
}

function Assert-NonExportableRsaKey {
    param(
        [Parameter(Mandatory = $true)]$Certificate,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $key = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    try {
        if ($null -eq $key -or
            ($key.Key.ExportPolicy -band [System.Security.Cryptography.CngExportPolicies]::AllowExport) -ne 0 -or
            ($key.Key.ExportPolicy -band [System.Security.Cryptography.CngExportPolicies]::AllowPlaintextExport) -ne 0) {
            throw "$Label private key is missing or exportable. Refusing to continue."
        }
    } finally {
        if ($null -ne $key) { $key.Dispose() }
    }
}

function Assert-TailscaleFirewallRule {
    param(
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$LocalAddress,
        [Parameter(Mandatory = $true)][int]$LocalPort,
        [Parameter(Mandatory = $true)][string]$InterfaceAlias
    )
    $rules = @(Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction Stop)
    if ($rules.Count -ne 1) { throw "Expected exactly one firewall rule named '$DisplayName'." }
    $rule = $rules[0]
    $portFilter = $rule | Get-NetFirewallPortFilter
    $addressFilter = $rule | Get-NetFirewallAddressFilter
    $interfaceFilter = $rule | Get-NetFirewallInterfaceFilter
    $escapedAlias = [System.Management.Automation.WildcardPattern]::Escape($InterfaceAlias)
    if ($rule.Enabled.ToString() -ne "True" -or
        $rule.Direction.ToString() -ne "Inbound" -or
        $rule.Action.ToString() -ne "Allow" -or
        $portFilter.Protocol -ne "TCP" -or
        $portFilter.LocalPort -ne $LocalPort.ToString() -or
        $addressFilter.LocalAddress -notcontains $LocalAddress -or
        $addressFilter.RemoteAddress -notcontains "100.64.0.0/10" -or
        $interfaceFilter.InterfaceAlias -notcontains $escapedAlias) {
        throw "Firewall rule '$DisplayName' is broader than the required Tailscale-only scope."
    }
}

$tailscaleRecords = @(
    Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction Stop |
        Where-Object { Test-TailscaleIPv4Address -Address $_.IPAddress }
)
$tailscaleAddresses = @($tailscaleRecords | Select-Object -ExpandProperty IPAddress -Unique)

if ([string]::IsNullOrWhiteSpace($BindAddress)) {
    if ($tailscaleAddresses.Count -ne 1) {
        $choices = if ($tailscaleAddresses.Count -eq 0) { "none" } else { $tailscaleAddresses -join ", " }
        throw "Expected exactly one active Tailscale IPv4 address. Found: $choices"
    }
    $BindAddress = $tailscaleAddresses[0]
}
if (-not (Test-TailscaleIPv4Address -Address $BindAddress)) {
    throw "BindAddress must be this PC's 100.64.0.0/10 Tailscale address."
}
$bindRecords = @($tailscaleRecords | Where-Object { $_.IPAddress -eq $BindAddress })
if ($bindRecords.Count -ne 1) {
    throw "BindAddress $BindAddress must identify exactly one active Tailscale interface on this PC."
}
$interfaceAlias = $bindRecords[0].InterfaceAlias

if (-not $SkipFirewall) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run PowerShell as Administrator, or use -SkipFirewall and configure equally restricted rules manually."
    }
}

$projectDirectory = Split-Path -Parent $PSScriptRoot
$agentDirectory = Join-Path $projectDirectory "DeckWindowsAgent"
$settingsPath = Join-Path $agentDirectory "appsettings.Local.json"
$rootExportPath = Join-Path $projectDirectory "DeckAgent-Tailscale-Root.cer"
$rootSubject = "CN=Deck Agent Tailscale Root"

$rootCertificate = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object {
        $_.Subject -eq $rootSubject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30)
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
Assert-NonExportableRsaKey -Certificate $rootCertificate -Label "Tailscale root certificate"

$serverCertificate = New-SelfSignedCertificate `
    -Type Custom `
    -Subject "CN=$BindAddress" `
    -Signer $rootCertificate `
    -KeyAlgorithm RSA `
    -KeyLength 2048 `
    -HashAlgorithm SHA256 `
    -KeyExportPolicy NonExportable `
    -KeyUsage DigitalSignature, KeyEncipherment `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -NotAfter (Get-Date).AddDays(365) `
    -TextExtension @(
        "2.5.29.17={text}IPAddress=$BindAddress",
        "2.5.29.37={text}1.3.6.1.5.5.7.3.1",
        "2.5.29.19={critical}{text}ca=0"
    )
Assert-NonExportableRsaKey -Certificate $serverCertificate -Label "Tailscale server certificate"

$serverSan = ($serverCertificate.Extensions |
    Where-Object { $_.Oid.Value -eq "2.5.29.17" } |
    Select-Object -First 1).Format($false)
if ($serverSan -notmatch [regex]::Escape($BindAddress)) {
    throw "The generated server certificate SAN does not contain $BindAddress."
}

Export-Certificate -Cert $rootCertificate -FilePath $rootExportPath -Force | Out-Null
$trustedRoot = Get-ChildItem Cert:\CurrentUser\Root |
    Where-Object { $_.Thumbprint -eq $rootCertificate.Thumbprint } |
    Select-Object -First 1
if ($null -eq $trustedRoot) {
    Import-Certificate -FilePath $rootExportPath -CertStoreLocation "Cert:\CurrentUser\Root" | Out-Null
}

$capabilitySettings = [ordered]@{
    WindowsAudioEnabled = $true
    GoXlrEnabled = $true
    GoXlrClientPath = ""
    Applications = @()
}
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    $existingSettings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    if ($null -ne $existingSettings.Agent -and $null -ne $existingSettings.Agent.Capabilities) {
        $capabilitySettings = $existingSettings.Agent.Capabilities
    }
}

$settings = [ordered]@{
    Agent = [ordered]@{
        BindAddress = $BindAddress
        Port = $AgentPort
        CertificateThumbprint = $serverCertificate.Thumbprint
        PairingCodeLifetimeSeconds = 120
        MaximumPairingAttempts = 5
        Capabilities = $capabilitySettings
    }
}
$settings | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $settingsPath -Encoding UTF8

if (-not $SkipFirewall) {
    $agentRuleName = "Deck Windows Agent Tailscale $BindAddress`:$AgentPort"
    if ($null -eq (Get-NetFirewallRule -DisplayName $agentRuleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule `
            -DisplayName $agentRuleName `
            -Description "Deck Agent, limited to this PC's Tailscale interface and tailnet peers." `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalAddress $BindAddress `
            -LocalPort $AgentPort `
            -RemoteAddress "100.64.0.0/10" `
            -InterfaceAlias ([System.Management.Automation.WildcardPattern]::Escape($interfaceAlias)) `
            -Profile Any `
            -EdgeTraversalPolicy Block | Out-Null
    }
    Assert-TailscaleFirewallRule `
        -DisplayName $agentRuleName `
        -LocalAddress $BindAddress `
        -LocalPort $AgentPort `
        -InterfaceAlias $interfaceAlias

    if ($AllowCompanion) {
        $companionRuleName = "Bitfocus Companion Tailscale $BindAddress`:$CompanionPort"
        if ($null -eq (Get-NetFirewallRule -DisplayName $companionRuleName -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule `
                -DisplayName $companionRuleName `
                -Description "Companion HTTP API, limited to this PC's Tailscale interface and tailnet peers." `
                -Direction Inbound `
                -Action Allow `
                -Protocol TCP `
                -LocalAddress $BindAddress `
                -LocalPort $CompanionPort `
                -RemoteAddress "100.64.0.0/10" `
                -InterfaceAlias ([System.Management.Automation.WildcardPattern]::Escape($interfaceAlias)) `
                -Profile Any `
                -EdgeTraversalPolicy Block | Out-Null
        }
        Assert-TailscaleFirewallRule `
            -DisplayName $companionRuleName `
            -LocalAddress $BindAddress `
            -LocalPort $CompanionPort `
            -InterfaceAlias $interfaceAlias
    }
}

Write-Host ""
Write-Host "Private Tailscale route configured successfully." -ForegroundColor Green
Write-Host "DeckApp Agent address: https://$BindAddress`:$AgentPort"
if ($AllowCompanion) { Write-Host "DeckApp Companion address: http://$BindAddress`:$CompanionPort" }
Write-Host "Windows interface: $interfaceAlias"
Write-Host "Install this public root certificate on each iPhone/iPad: $rootExportPath"
Write-Host "Then enable it under Settings > General > About > Certificate Trust Settings."
Write-Host "No public listener or router port-forwarding rule was created."
