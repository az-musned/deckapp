[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AgentPath,
    [ValidateRange(1, 60)][int]$RestartDelaySeconds = 5
)

$ErrorActionPreference = "Continue"
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $AgentPath -PathType Leaf)) {
    throw "Deck Windows Agent executable is missing: $AgentPath"
}

$agentDirectory = Split-Path -Parent $AgentPath
while ($true) {
    try {
        $process = Start-Process -FilePath $AgentPath -WorkingDirectory $agentDirectory -Wait -PassThru
        Write-Warning "Deck Windows Agent exited with code $($process.ExitCode). Restarting in $RestartDelaySeconds seconds."
    }
    catch {
        Write-Warning "Deck Windows Agent failed to start: $($_.Exception.Message). Retrying in $RestartDelaySeconds seconds."
    }
    Start-Sleep -Seconds $RestartDelaySeconds
}
