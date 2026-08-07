param(
    [string]$TaskName = "OAndrei314 Codex Daily News Routine",
    [string]$RepoPath = "C:\Users\ojoca\Documents\github_projects\ai-infra-optics-digest"
)

$ErrorActionPreference = "Stop"

function Report {
    param([string]$Status, [string]$Label, [string]$Detail)
    Write-Host "[$Status] $Label - $Detail"
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
Report ($(if ($info.LastTaskResult -eq 0) { "ok" } else { "!!" })) "Last run" "result=$($info.LastTaskResult), last=$($info.LastRunTime), next=$($info.NextRunTime)"
