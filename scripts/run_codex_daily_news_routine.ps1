param(
    [string]$WorkspaceRoot = "C:\Users\ojoca\Documents\github_projects",
    [string]$RepoPath = "C:\Users\ojoca\Documents\github_projects\ai-infra-optics-digest",
    [string]$PythonPath = "C:\Users\ojoca\AppData\Local\Programs\Python\Python312\python.exe",
    [string]$GhPath = "C:\Program Files\GitHub CLI\gh.exe",
    [string]$Sources = "configs\live_feeds.yaml",
    [string]$LogPath = "logs\codex_daily_news_routine.log",
    [int]$DigestLimit = 24,
    [int]$RoutineLimit = 16,
    [int]$MaxSendJitterMinutes = 45,
    [switch]$Network,
    [switch]$Force,
    [switch]$NoSendJitter
)

$ErrorActionPreference = "Stop"

function Append-Run-Log {
    param([string]$Path, [string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $Message" | Out-File -FilePath $Path -Append -Encoding utf8
}

function Assert-Clean-GitRepo {
    param([string]$Path)
    Push-Location $Path
    try {
        $dirty = git status --porcelain
        if ($dirty) {
            throw "Working tree is dirty: $Path"
        }
    } finally {
        Pop-Location
    }
}

function Relative-GitPath {
    param([string]$Repo, [string]$Path)
    $repoFull = (Resolve-Path -LiteralPath $Repo).Path
    $pathFull = (Resolve-Path -LiteralPath $Path).Path
    $repoUri = New-Object System.Uri (($repoFull.TrimEnd("\") + "\"))
    $pathUri = New-Object System.Uri $pathFull
    $relative = [System.Uri]::UnescapeDataString($repoUri.MakeRelativeUri($pathUri).ToString())
    return ($relative -replace "\\", "/")
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

$logDirectory = Split-Path -Parent (Join-Path $RepoPath $LogPath)
if ($logDirectory) {
    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
}

$codexRepos = @(
    "ai-infra-optics-digest",
    "ai-factory-optical-twin",
    "tinyml-quantized-telemetry-bench",
    "silicon-photonics-telemetry-monitor",
    "firmware-validation-agent"
)

Append-Run-Log (Join-Path $RepoPath $LogPath) "starting Codex daily news routine"

try {
    $runDate = Get-Date -Format "yyyy-MM-dd"
    $existingMetadata = Join-Path $RepoPath (Join-Path "routine-reports" "$runDate.json")
    if ((Test-Path -LiteralPath $existingMetadata) -and (-not $Force)) {
        Append-Run-Log (Join-Path $RepoPath $LogPath) "already completed $runDate; use -Force to rerun"
        Write-Host "Codex daily news routine already completed for $runDate. Use -Force to rerun."
        return
    }

    foreach ($name in $codexRepos) {
        $path = Join-Path $WorkspaceRoot $name
        if (Test-Path -LiteralPath (Join-Path $path ".git")) {
            Assert-Clean-GitRepo $path
        }
    }

    Push-Location $RepoPath
    try {
        & $GhPath auth status *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "GitHub CLI is not authenticated."
        }
        git remote get-url origin *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "No git remote named origin."
        }
        git pull --ff-only

        & $PythonPath -m pip install -r requirements-dev.txt
        & $PythonPath -m pip install -e .
        & $PythonPath -m pytest -v

        $digestPath = Join-Path "digests" "$runDate.md"
        $routineDir = "routine-reports"
        $metadataPath = Join-Path $routineDir "$runDate.json"
        $reportPath = Join-Path $routineDir "$runDate.md"

        $buildArgs = @(
            "-m", "optics_digest.cli", "build",
            "--sources", $Sources,
            "--out", "digests",
            "--date", $runDate,
            "--limit", "$DigestLimit",
            "--rotate-sources"
        )
        $routineArgs = @(
            "-m", "optics_digest.cli", "routine",
            "--root", $WorkspaceRoot,
            "--sources", $Sources,
            "--out", $routineDir,
            "--date", $runDate,
            "--limit", "$RoutineLimit",
            "--metadata-out", $metadataPath,
            "--write-note"
        )
        if ($Network) {
            $buildArgs += "--network"
            $routineArgs += "--network"
        }

        & $PythonPath @buildArgs
        & $PythonPath @routineArgs

        if (-not (Test-Path -LiteralPath $metadataPath)) {
            throw "Routine metadata was not created: $metadataPath"
        }
        $metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
    } finally {
        Pop-Location
    }

    $noteCommitted = $false
    $fullLogPath = Join-Path $RepoPath $LogPath
    if ($metadata.note_path) {
        $selectedRepo = $metadata.selected_repo_path
        $repoFull = (Resolve-Path -LiteralPath $RepoPath).Path
        $selectedFull = (Resolve-Path -LiteralPath $selectedRepo).Path
        if ($selectedFull -ne $repoFull) {
            Push-Location $selectedFull
            try {
                $relativeNote = Relative-GitPath $selectedFull $metadata.note_path
                git add -- $relativeNote
                git diff --cached --quiet
                if ($LASTEXITCODE -ne 0) {
                    Invoke-RandomSendJitter -Reason "selected repo commit/push" -Path $fullLogPath
                    git commit -m "Add daily news research note $($metadata.run_date)"
                    git push origin HEAD
                    $noteCommitted = $true
                }
            } finally {
                Pop-Location
            }
        }
    }

    Push-Location $RepoPath
    try {
        $stagePaths = @($digestPath, $reportPath, $metadataPath)
        if ($metadata.note_path) {
            $repoFull = (Resolve-Path -LiteralPath $RepoPath).Path
            $noteFull = (Resolve-Path -LiteralPath $metadata.note_path).Path
            if ($noteFull.StartsWith($repoFull)) {
                $stagePaths += (Relative-GitPath $RepoPath $metadata.note_path)
            }
        }
        git add -- $stagePaths
        git diff --cached --quiet
        if ($LASTEXITCODE -ne 0) {
            Invoke-RandomSendJitter -Reason "digest routine commit/push" -Path $fullLogPath
            git commit -m "Run Codex daily news routine $runDate"
            git push origin HEAD
        }
    } finally {
        Pop-Location
    }

    Append-Run-Log (Join-Path $RepoPath $LogPath) "completed $runDate; selected=$($metadata.selected_repo); noteCommitted=$noteCommitted"
} catch {
    Append-Run-Log (Join-Path $RepoPath $LogPath) "failed: $($_.Exception.Message)"
    throw
}
