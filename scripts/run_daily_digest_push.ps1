param(
    [string]$RepoPath = "C:\Users\ojoca\Documents\github_projects\ai-infra-optics-digest",
    [string]$PythonPath = "C:\Users\ojoca\AppData\Local\Programs\Python\Python312\python.exe",
    [string]$GhPath = "C:\Program Files\GitHub CLI\gh.exe",
    [string]$Sources = "configs\live_feeds.yaml",
    [string]$LogPath = "logs\daily_digest_push.log",
    [int]$Limit = 24,
    [switch]$Network,
    [switch]$CreatePullRequest
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message"
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
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] starting daily digest run" | Out-File -FilePath $LogPath -Append -Encoding utf8

    $branch = (git branch --show-current).Trim()
    if (-not $branch) {
        throw "Could not determine current git branch."
    }

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
    $args = @("-m", "optics_digest.cli", "build", "--sources", $Sources, "--out", "digests", "--date", $digestDate, "--limit", "$Limit")
    if ($Network) {
        $args += "--network"
    }
    & $PythonPath @args

    $changed = git status --porcelain
    if (-not $changed) {
        Write-Log "No digest changes to commit. Nothing pushed."
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] no changes" | Out-File -FilePath $LogPath -Append -Encoding utf8
        exit 0
    }

    git add digests README.md configs scripts docs optics_digest tests requirements.txt requirements-dev.txt pyproject.toml .github
    git commit -m "Add AI infrastructure optics digest $digestDate"
    git push

    if ($CreatePullRequest -and $branch -ne "main") {
        $repo = (& $GhPath repo view --json nameWithOwner --jq ".nameWithOwner").Trim()
        $existing = (& $GhPath pr list --repo $repo --head $branch --state open --json number --jq ".[0].number").Trim()
        if (-not $existing) {
            & $GhPath pr create `
                --repo $repo `
                --base main `
                --head $branch `
                --title "Daily AI infra optics digest" `
                --body "Scheduled digest update with deterministic tests and source-linked research items."
        }
    }

    Write-Log "Committed and pushed digest for $digestDate on branch $branch."
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] pushed digest for $digestDate on $branch" | Out-File -FilePath $LogPath -Append -Encoding utf8
} finally {
    Pop-Location
}
