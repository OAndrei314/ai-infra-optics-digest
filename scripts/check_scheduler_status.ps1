param(
    [string]$TaskName = "OAndrei314 Daily AI Infra Optics Digest",
    [string]$RepoPath = "",
    [string]$GhPath = "gh"
)

$ErrorActionPreference = "Continue"

if (-not $RepoPath) {
    $RepoPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
}

function Status-Line {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Detail
    )
    $mark = if ($Ok) { "[ok]" } else { "[!!]" }
    Write-Host "$mark $Name - $Detail"
}

Status-Line "Repo path" (Test-Path -LiteralPath $RepoPath) $RepoPath

if (Test-Path -LiteralPath $RepoPath) {
    Push-Location $RepoPath
    try {
        $branch = (git branch --show-current 2>$null).Trim()
        $branchDetail = if ($branch) { $branch } else { "not a git repo" }
        Status-Line "Git branch" ([bool]$branch) $branchDetail

        $remote = (git remote get-url origin 2>$null)
        $remoteDetail = if ($remote) { $remote } else { "missing" }
        Status-Line "Origin remote" ([bool]$remote) $remoteDetail

        $dirty = (git status --porcelain 2>$null)
        $treeDetail = if ($dirty) { "dirty" } else { "clean" }
        Status-Line "Working tree" (-not [bool]$dirty) $treeDetail

        $latestDigest = Get-ChildItem -LiteralPath "digests" -Filter "*.md" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        $digestDetail = if ($latestDigest) { "$($latestDigest.Name) updated $($latestDigest.LastWriteTime)" } else { "none committed/generated yet" }
        Status-Line "Latest digest" ([bool]$latestDigest) $digestDetail
    } finally {
        Pop-Location
    }
}

& $GhPath auth status *> $null
$authDetail = if ($LASTEXITCODE -eq 0) { "authenticated" } else { "not authenticated" }
Status-Line "GitHub CLI auth" ($LASTEXITCODE -eq 0) $authDetail

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$taskDetail = if ($task) { "$TaskName installed; state=$($task.State)" } else { "not installed" }
Status-Line "Scheduled task" ([bool]$task) $taskDetail

if ($task) {
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($info) {
        Status-Line "Last run" ($info.LastTaskResult -eq 0) ("result=$($info.LastTaskResult), last=$($info.LastRunTime), next=$($info.NextRunTime)")
    }
}
