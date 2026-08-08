param(
    [string]$TaskName = "OAndrei314 Codex Daily News Routine",
    [string]$RepoPath = "C:\Users\ojoca\Documents\github_projects\ai-infra-optics-digest"
)

$ErrorActionPreference = "Stop"

function Report {
    param([string]$Status, [string]$Label, [string]$Detail)
    Write-Host "[$Status] $Label - $Detail"
}

function Get-TaskArgumentValue {
    param([string]$Arguments, [string]$Name)
    $pattern = "(?i)(?:^|\s)-$([regex]::Escape($Name))\s+(`"[^`"]+`"|\S+)"
    if ($Arguments -match $pattern) {
        return $matches[1].Trim('"')
    }
    return $null
}

function Convert-TaskDurationToMinutes {
    param($Duration)
    if ($Duration -is [TimeSpan]) {
        return [int][Math]::Floor($Duration.TotalMinutes)
    }
    if (-not $Duration) {
        return 0
    }
    return [int][Math]::Floor(([System.Xml.XmlConvert]::ToTimeSpan([string]$Duration)).TotalMinutes)
}

function Get-PublishWindowMinutes {
    param([string]$Start, [string]$End)
    $startSpan = [TimeSpan]::Parse($Start, [System.Globalization.CultureInfo]::InvariantCulture)
    $endSpan = [TimeSpan]::Parse($End, [System.Globalization.CultureInfo]::InvariantCulture)
    if ($startSpan -eq $endSpan) {
        return 0
    }
    if ($endSpan -lt $startSpan) {
        return [int](($endSpan.Add([TimeSpan]::FromDays(1)) - $startSpan).TotalMinutes)
    }
    return [int](($endSpan - $startSpan).TotalMinutes)
}

if (-not (Test-Path -LiteralPath $RepoPath)) {
    Report "!!" "Repo path" "missing: $RepoPath"
    exit 1
}
Report "ok" "Repo path" $RepoPath

Push-Location $RepoPath
try {
    $branch = (git branch --show-current).Trim()
    Report ($(if ($branch) { "ok" } else { "!!" })) "Git branch" ($(if ($branch) { $branch } else { "unknown" }))

    $origin = (git remote get-url origin 2>$null)
    Report ($(if ($LASTEXITCODE -eq 0) { "ok" } else { "!!" })) "Origin remote" ($(if ($origin) { $origin } else { "missing" }))

    $dirty = git status --porcelain
    Report ($(if ($dirty) { "!!" } else { "ok" })) "Working tree" ($(if ($dirty) { "dirty" } else { "clean" }))

    $latestDigest = Get-ChildItem -Path "digests" -Filter "*.md" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    Report ($(if ($latestDigest) { "ok" } else { "!!" })) "Latest digest" ($(if ($latestDigest) { "$($latestDigest.Name) updated $($latestDigest.LastWriteTime)" } else { "none" }))

    $latestRoutine = Get-ChildItem -Path "routine-reports" -Filter "*.md" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    Report ($(if ($latestRoutine) { "ok" } else { "!!" })) "Latest routine report" ($(if ($latestRoutine) { "$($latestRoutine.Name) updated $($latestRoutine.LastWriteTime)" } else { "none" }))
} finally {
    Pop-Location
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
    Report "!!" "Scheduled task" "not installed"
    exit 0
}
$info = Get-ScheduledTaskInfo -TaskName $TaskName
Report "ok" "Scheduled task" "$TaskName installed; state=$($task.State)"
$actionArgs = $task.Actions[0].Arguments
$jitterArg = Get-TaskArgumentValue -Arguments $actionArgs -Name "MaxSendJitterMinutes"
$jitterMinutes = $(if ($jitterArg) { [int]$jitterArg } else { 540 })
$publishWindowStartArg = Get-TaskArgumentValue -Arguments $actionArgs -Name "PublishWindowStart"
$publishWindowEndArg = Get-TaskArgumentValue -Arguments $actionArgs -Name "PublishWindowEnd"
$publishWindowStart = $(if ($publishWindowStartArg) { $publishWindowStartArg } else { "17:00" })
$publishWindowEnd = $(if ($publishWindowEndArg) { $publishWindowEndArg } else { "02:00" })
$minProjectsArg = Get-TaskArgumentValue -Arguments $actionArgs -Name "MinDailyProjects"
$maxProjectsArg = Get-TaskArgumentValue -Arguments $actionArgs -Name "MaxDailyProjects"
$minProjects = $(if ($minProjectsArg) { [int]$minProjectsArg } else { 5 })
$maxProjects = $(if ($maxProjectsArg) { [int]$maxProjectsArg } else { 10 })
$limitMinutes = Convert-TaskDurationToMinutes $task.Settings.ExecutionTimeLimit
$publishWindowMinutes = Get-PublishWindowMinutes -Start $publishWindowStart -End $publishWindowEnd
$requiredMinutes = 1440 + $publishWindowMinutes + 120
Report ($(if ($minProjects -ge 1 -and $maxProjects -ge $minProjects) { "ok" } else { "!!" })) "Daily project batch" "min=$minProjects, max=$maxProjects"
Report ($(if ($publishWindowStart -eq "17:00" -and $publishWindowEnd -eq "02:00") { "ok" } else { "!!" })) "Publish window" "window=$publishWindowStart-$publishWindowEnd, legacyJitterCap=${jitterMinutes}m"
Report ($(if ($limitMinutes -ge $requiredMinutes) { "ok" } else { "!!" })) "Runtime budget" "window=${publishWindowMinutes}m, limit=${limitMinutes}m, required>=${requiredMinutes}m"
Report ($(if ($info.LastTaskResult -eq 0) { "ok" } else { "!!" })) "Last run" "result=$($info.LastTaskResult), last=$($info.LastRunTime), next=$($info.NextRunTime)"
