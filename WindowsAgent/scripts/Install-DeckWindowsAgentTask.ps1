[CmdletBinding()]
param(
    [string]$TaskName = "Deck Windows Agent",
    [string]$DeploymentDirectory = (Join-Path $env:LOCALAPPDATA "DeckWindowsAgent\Agent")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$projectDirectory = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $projectDirectory "DeckWindowsAgent\DeckWindowsAgent.csproj"
$localSettingsPath = Join-Path $projectDirectory "DeckWindowsAgent\appsettings.Local.json"
$runnerSourcePath = Join-Path $PSScriptRoot "Run-DeckWindowsAgent.ps1"

if (-not (Test-Path -LiteralPath $localSettingsPath -PathType Leaf)) {
    throw "Configure the Agent before installing its supervised task. Missing: $localSettingsPath"
}

New-Item -ItemType Directory -Path $DeploymentDirectory -Force | Out-Null
& dotnet publish $projectPath --configuration Release --output $DeploymentDirectory
if ($LASTEXITCODE -ne 0) { throw "Publishing DeckWindowsAgent failed with exit code $LASTEXITCODE." }
Copy-Item -LiteralPath $localSettingsPath -Destination (Join-Path $DeploymentDirectory "appsettings.Local.json") -Force
Copy-Item -LiteralPath $runnerSourcePath -Destination (Join-Path $DeploymentDirectory "Run-DeckWindowsAgent.ps1") -Force

$executablePath = Join-Path $DeploymentDirectory "DeckWindowsAgent.exe"
if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    throw "Published Agent executable is missing: $executablePath"
}

$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$runnerPath = Join-Path $DeploymentDirectory "Run-DeckWindowsAgent.ps1"
$powerShellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
$actionArguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runnerPath`" -AgentPath `"$executablePath`""
$action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $actionArguments -WorkingDirectory $DeploymentDirectory
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -StartWhenAvailable

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Runs the paired DeckApp Windows Agent in the interactive user session and restarts it after failures." `
    -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Write-Host "Installed and started supervised task '$TaskName'." -ForegroundColor Green
Write-Host "Executable: $executablePath"
