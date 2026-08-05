param(
    [string]$TaskName = "OAndrei314 Daily AI Infra Optics Digest",
    [string]$RepoPath = "C:\Users\ojoca\Documents\github_projects\ai-infra-optics-digest",
    [string]$At = "09:00",
    [switch]$Network,
    [switch]$CreatePullRequest
)

$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $RepoPath "scripts\run_daily_digest_push.ps1"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Missing scheduler runner: $scriptPath"
}

$arguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$scriptPath`"",
    "-RepoPath", "`"$RepoPath`""
)
if ($Network) {
    $arguments += "-Network"
}
if ($CreatePullRequest) {
    $arguments += "-CreatePullRequest"
}

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument ($arguments -join " ")
$trigger = New-ScheduledTaskTrigger -Daily -At $At
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Description "Builds, tests, commits, and pushes a real AI-infrastructure/optics digest when content changes." `
    -Force | Out-Null

Write-Host "Installed scheduled task '$TaskName' at $At."
Write-Host "Runner: $scriptPath"
Write-Host "The task will refuse to create empty commits and will fail until gh auth + origin remote are configured."
