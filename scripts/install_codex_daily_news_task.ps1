param(
    [string]$TaskName = "OAndrei314 Codex Daily News Routine",
    [string]$WorkspaceRoot = "C:\Users\ojoca\Documents\github_projects",
    [string]$RepoPath = "C:\Users\ojoca\Documents\github_projects\ai-infra-optics-digest",
    [string]$Lifecycle = "configs\project_lifecycle.yaml",
    [string]$WeeklyRundownDir = "weekly-rundowns",
    [string]$At = "17:00",
    [int]$MaxSendJitterMinutes = 540,
    [string]$PublishWindowStart = "17:00",
    [string]$PublishWindowEnd = "02:00",
    [int]$RuntimePaddingMinutes = 120,
    [int]$MinDailyProjects = 6,
    [int]$MaxDailyProjects = 8,
    [string]$GitAuthorName = "OAndrei314",
    [string]$GitAuthorEmail = "56999057+OAndrei314@users.noreply.github.com",
    [switch]$NoSendJitter,
    [switch]$Network
)

$ErrorActionPreference = "Stop"

function Get-PublishWindowMinutes {
    param([string]$Start, [string]$End)
    $startSpan = [TimeSpan]::Parse($Start, [System.Globalization.CultureInfo]::InvariantCulture)
    $endSpan = [TimeSpan]::Parse($End, [System.Globalization.CultureInfo]::InvariantCulture)
    if ($startSpan -eq $endSpan) {
        throw "Publish window start and end must be different."
    }
    if ($endSpan -lt $startSpan) {
        return [int](($endSpan.Add([TimeSpan]::FromDays(1)) - $startSpan).TotalMinutes)
    }
    return [int](($endSpan - $startSpan).TotalMinutes)
}

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
    "-Lifecycle", "`"$Lifecycle`"",
    "-WeeklyRundownDir", "`"$WeeklyRundownDir`"",
    "-MaxSendJitterMinutes", "$MaxSendJitterMinutes",
    "-PublishWindowStart", "`"$PublishWindowStart`"",
    "-PublishWindowEnd", "`"$PublishWindowEnd`"",
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
$publishWindowMinutes = Get-PublishWindowMinutes -Start $PublishWindowStart -End $PublishWindowEnd
$executionLimitMinutes = [Math]::Max(60, 1440 + $publishWindowMinutes + $RuntimePaddingMinutes)

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
Write-Host "Publish window: $PublishWindowStart-$PublishWindowEnd; legacy jitter cap: $sendJitterMinutes minute(s); execution limit: $executionLimitMinutes minute(s)."
Write-Host "Daily project batch: minimum $MinDailyProjects, maximum $MaxDailyProjects."
