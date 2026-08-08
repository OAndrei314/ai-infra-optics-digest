param(
    [string]$RepoPath = "",
    [string]$PythonPath = "python",
    [string]$GhPath = "gh",
    [string]$Sources = "configs\live_feeds.yaml",
    [string]$LogPath = "logs\daily_digest_push.log",
    [int]$Limit = 24,
    [int]$MaxSendJitterMinutes = 300,
    [string]$GitAuthorName = "OAndrei314",
    [string]$GitAuthorEmail = "56999057+OAndrei314@users.noreply.github.com",
    [switch]$Network,
    [switch]$NoSendJitter,
    [switch]$CreatePullRequest
)

$ErrorActionPreference = "Stop"

if (-not $RepoPath) {
    $RepoPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message"
}

function Append-Run-Log {
    param(
        [string]$Path,
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $Message" | Out-File -FilePath $Path -Append -Encoding utf8
}

function Invoke-RandomSendJitter {
    param(
        [string]$Reason,
        [string]$Path
    )
    if ($NoSendJitter -or $MaxSendJitterMinutes -le 0) {
        Append-Run-Log $Path "send jitter skipped for $Reason"
        return
    }
    $maxSeconds = [Math]::Max(1, $MaxSendJitterMinutes * 60)
    $seconds = Get-Random -Minimum 1 -Maximum ($maxSeconds + 1)
    Append-Run-Log $Path "waiting $seconds second(s) before $Reason"
    Write-Host "Randomized send jitter: waiting $seconds second(s) before $Reason."
    Start-Sleep -Seconds $seconds
}

if (-not (Test-Path -LiteralPath $RepoPath)) {
    throw "Missing repo path: $RepoPath"
}

Push-Location $RepoPath
try {
    $logDirectory = Split-Path -Parent $LogPath
    if ($logDirectory) {
        New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    }
    Append-Run-Log $LogPath "starting daily digest run"

    $branch = (git branch --show-current).Trim()
    if (-not $branch) {
        throw "Could not determine current git branch."
    }
    git config user.name $GitAuthorName
    git config user.email $GitAuthorEmail

    & $GhPath auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI is not authenticated. Run: gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web"
    }

    git remote get-url origin *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "No git remote named origin. Publish the repository first, then rerun this scheduler."
    }

    git diff --quiet
    if ($LASTEXITCODE -ne 0) {
        throw "Working tree has uncommitted changes. Refusing to mix scheduled work with manual edits."
    }

    git pull --ff-only

    & $PythonPath -m pip install -r requirements-dev.txt
    & $PythonPath -m pytest -v

    $digestDate = Get-Date -Format "yyyy-MM-dd"
    $digestPath = Join-Path "digests" "$digestDate.md"
    $args = @("-m", "optics_digest.cli", "build", "--sources", $Sources, "--out", "digests", "--date", $digestDate, "--limit", "$Limit")
    if ($Network) {
        $args += "--network"
    }
    & $PythonPath @args

    if (-not (Test-Path -LiteralPath $digestPath)) {
        throw "Expected digest was not created: $digestPath"
    }

    $changed = git status --porcelain -- $digestPath
    if (-not $changed) {
        Write-Log "No digest changes to commit. Nothing pushed."
        Append-Run-Log $LogPath "no changes"
        return
    }

    git add -- $digestPath
    Invoke-RandomSendJitter -Reason "digest commit/push" -Path $LogPath
    git commit -m "Add AI infrastructure optics digest $digestDate"
    git push

    if ($CreatePullRequest -and $branch -ne "main") {
        $repo = (& $GhPath repo view --json nameWithOwner --jq ".nameWithOwner").Trim()
        $existing = (& $GhPath pr list --repo $repo --head $branch --state open --json number --jq ".[0].number").Trim()
        if (-not $existing) {
            Invoke-RandomSendJitter -Reason "digest pull request creation" -Path $LogPath
            & $GhPath pr create `
                --repo $repo `
                --base main `
                --head $branch `
                --title "Daily AI infra optics digest" `
                --body "Scheduled digest update with deterministic tests and source-linked research items."
        }
    }

    Write-Log "Committed and pushed digest for $digestDate on branch $branch."
    Append-Run-Log $LogPath "pushed digest for $digestDate on $branch"
} catch {
    try {
        Append-Run-Log $LogPath "failed: $($_.Exception.Message)"
    } catch {
        Write-Host "Could not append failure to log: $($_.Exception.Message)"
    }
    throw
} finally {
    Pop-Location
}
