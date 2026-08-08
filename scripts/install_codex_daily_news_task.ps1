param(
    [string]$TaskName = "OAndrei314 Codex Daily News Routine",
    [string]$WorkspaceRoot = "C:\Users\ojoca\Documents\github_projects",
    [string]$RepoPath = "C:\Users\ojoca\Documents\github_projects\ai-infra-optics-digest",
    [string]$At = "09:00",
    [int]$MaxSendJitterMinutes = 300,
    [int]$RuntimePaddingMinutes = 120,
    [int]$MinDailyProjects = 5,
    [int]$MaxDailyProjects = 10,
    [string]$GitAuthorName = "OAndrei314",
    [string]$GitAuthorEmail = "56999057+OAndrei314@users.noreply.github.com",
    [switch]$NoSendJitter,
    [switch]$Network
)

$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $RepoPath "scripts\run_codex_daily_news_routine.ps1"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Missing routine runner: $scriptPath"
}

Push-Location $RepoPath
try {
    & "C:\Program Files\GitHub CLI\gh.exe" auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI is not authenticated."
    }
    git remote get-url origin *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "No origin remote is configured."
    }
    $dirty = git status --porcelain
    if ($dirty) {
        throw "Working tree is dirty. Commit or discard local changes before installing the task."
    }
} finally {
    Pop-Location
}

$arguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$scriptPath`"",
    "-WorkspaceRoot", "`"$WorkspaceRoot`"",
    "-RepoPath", "`"$RepoPath`"",
    "-MaxSendJitterMinutes", "$MaxSendJitterMinutes",
    "-MinDailyProjects", "$MinDailyProjects",
    "-MaxDailyProjects", "$MaxDailyProjects",
    "-GitAuthorName", "`"$GitAuthorName`"",
    "-GitAuthorEmail", "`"$GitAuthorEmail`""
)
if ($NoSendJitter) {
    $arguments += "-NoSendJitter"
}
if ($Network) {
    $arguments += "-Network"
}

$sendJitterMinutes = $(if ($NoSendJitter) { 0 } else { [Math]::Max(0, $MaxSendJitterMinutes) })
$executionLimitMinutes = [Math]::Max(60, ($sendJitterMinutes * 2) + $RuntimePaddingMinutes)

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument ($arguments -join " ")
$trigger = New-ScheduledTaskTrigger -Daily -At $At
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes $executionLimitMinutes)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Description "Runs news-aware Codex-owned repo rotation, digest generation, tests, commits, and pushes real source-linked updates." `
    -Force | Out-Null

Write-Host "Installed scheduled task '$TaskName' at $At."
Write-Host "Runner: $scriptPath"
Write-Host "Send jitter: up to $sendJitterMinutes minute(s); execution limit: $executionLimitMinutes minute(s)."
Write-Host "Daily project batch: minimum $MinDailyProjects, maximum $MaxDailyProjects."
