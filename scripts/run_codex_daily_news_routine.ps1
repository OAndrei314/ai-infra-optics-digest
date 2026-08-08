param(
    [string]$WorkspaceRoot = "C:\Users\ojoca\Documents\github_projects",
    [string]$RepoPath = "C:\Users\ojoca\Documents\github_projects\ai-infra-optics-digest",
    [string]$PythonPath = "C:\Users\ojoca\AppData\Local\Programs\Python\Python312\python.exe",
    [string]$GhPath = "C:\Program Files\GitHub CLI\gh.exe",
    [string]$Sources = "configs\live_feeds.yaml",
    [string]$LogPath = "logs\codex_daily_news_routine.log",
    [int]$DigestLimit = 24,
    [int]$RoutineLimit = 16,
    [int]$MaxSendJitterMinutes = 300,
    [string]$GitAuthorName = "OAndrei314",
    [string]$GitAuthorEmail = "56999057+OAndrei314@users.noreply.github.com",
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

function Set-CodexGitIdentity {
    param([string]$Repo)
    Push-Location $Repo
    try {
        git config user.name $GitAuthorName
        git config user.email $GitAuthorEmail
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

function Normalize-GitPath {
    param([string]$Path)
    return ($Path -replace "\\", "/")
}

function Get-GitStatusPath {
    param([string]$Line)
    if ($Line.Length -lt 4) {
        return $Line
    }
    $path = $Line.Substring(3)
    if ($path -match " -> ") {
        $path = ($path -split " -> ")[-1]
    }
    return (Normalize-GitPath $path)
}

function Assert-NoUnexpectedStagedChanges {
    param(
        [string]$Repo,
        [string[]]$ExpectedPaths
    )
    $expected = @($ExpectedPaths | ForEach-Object { Normalize-GitPath $_ })
    Push-Location $Repo
    try {
        $unexpected = @()
        foreach ($line in @(git status --porcelain)) {
            if ($line.Length -lt 4) {
                continue
            }
            $indexStatus = $line.Substring(0, 1)
            $path = Get-GitStatusPath $line
            if (($indexStatus -ne " " -and $indexStatus -ne "?") -and ($expected -notcontains $path)) {
                $unexpected += $path
            }
        }
        if ($unexpected) {
            throw "Unexpected staged changes in $Repo`: $($unexpected -join ', ')"
        }
    } finally {
        Pop-Location
    }
}

function Push-PendingRoutineCommit {
    param(
        [string]$Repo,
        [string]$ExpectedSubject,
        [string]$Path
    )
    Push-Location $Repo
    try {
        $upstream = (git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $upstream) {
            return $false
        }
        $subjects = @(git log --format=%s "$upstream..HEAD" 2>$null)
        if ($subjects -contains $ExpectedSubject) {
            Append-Run-Log $Path "pushing pending routine commit in $Repo"
            git push origin HEAD
            return $true
        }
        return $false
    } finally {
        Pop-Location
    }
}

function Publish-GeneratedPaths {
    param(
        [string]$Repo,
        [string[]]$Paths,
        [string]$CommitMessage,
        [string]$Reason,
        [string]$LogPath,
        [switch]$UseJitter
    )
    $existingPaths = @()
    foreach ($path in $Paths) {
        if (Test-Path -LiteralPath (Join-Path $Repo $path)) {
            $existingPaths += (Normalize-GitPath $path)
        }
    }
    if (-not $existingPaths) {
        return $false
    }

    Push-Location $Repo
    try {
        $pathStatus = @(git status --porcelain -- $existingPaths)
        if ($pathStatus) {
            Assert-NoUnexpectedStagedChanges -Repo $Repo -ExpectedPaths $existingPaths
            git add -- $existingPaths
            git diff --cached --quiet -- $existingPaths
            if ($LASTEXITCODE -ne 0) {
                if ($UseJitter) {
                    Invoke-RandomSendJitter -Reason $Reason -Path $LogPath
                }
                git commit -m $CommitMessage
                git push origin HEAD
                return $true
            }
        }
    } finally {
        Pop-Location
    }

    return (Push-PendingRoutineCommit -Repo $Repo -ExpectedSubject $CommitMessage -Path $LogPath)
}

function Publish-ExistingRoutineRun {
    param(
        [object]$Metadata,
        [string]$RunDate,
        [string]$RepoPath,
        [string]$LogPath
    )
    $published = $false
    $repoFull = (Resolve-Path -LiteralPath $RepoPath).Path

    if ($Metadata.note_path) {
        $selectedRepo = $Metadata.selected_repo_path
        $selectedFull = (Resolve-Path -LiteralPath $selectedRepo).Path
        if ($selectedFull -ne $repoFull) {
            $relativeNote = Relative-GitPath $selectedFull $Metadata.note_path
            $published = (Publish-GeneratedPaths `
                -Repo $selectedFull `
                -Paths @($relativeNote) `
                -CommitMessage "Add daily news research note $RunDate" `
                -Reason "recovered selected repo commit/push" `
                -LogPath $LogPath) -or $published
        }
    }

    $stagePaths = @(
        (Normalize-GitPath (Join-Path "digests" "$RunDate.md")),
        (Normalize-GitPath (Join-Path "routine-reports" "$RunDate.md")),
        (Normalize-GitPath (Join-Path "routine-reports" "$RunDate.json"))
    )
    if ($Metadata.note_path) {
        $noteFull = (Resolve-Path -LiteralPath $Metadata.note_path).Path
        if ($noteFull.StartsWith($repoFull)) {
            $stagePaths += (Relative-GitPath $RepoPath $Metadata.note_path)
        }
    }

    $published = (Publish-GeneratedPaths `
        -Repo $RepoPath `
        -Paths $stagePaths `
        -CommitMessage "Run Codex daily news routine $RunDate" `
        -Reason "recovered digest routine commit/push" `
        -LogPath $LogPath) -or $published

    return $published
}

function Publish-PendingRoutineRuns {
    param(
        [string]$RepoPath,
        [string]$LogPath,
        [string]$CurrentRunDate
    )
    $published = $false
    $metadataDirectory = Join-Path $RepoPath "routine-reports"
    if (-not (Test-Path -LiteralPath $metadataDirectory)) {
        return $false
    }

    $metadataFiles = @(Get-ChildItem -LiteralPath $metadataDirectory -Filter "*.json" -ErrorAction SilentlyContinue |
        Sort-Object Name)
    foreach ($metadataFile in $metadataFiles) {
        $metadataDate = [System.IO.Path]::GetFileNameWithoutExtension($metadataFile.Name)
        if ($metadataDate -eq $CurrentRunDate) {
            continue
        }
        $metadata = Get-Content -Raw -LiteralPath $metadataFile.FullName | ConvertFrom-Json
        $didPublish = Publish-ExistingRoutineRun `
            -Metadata $metadata `
            -RunDate $metadataDate `
            -RepoPath $RepoPath `
            -LogPath $LogPath
        if ($didPublish) {
            Append-Run-Log $LogPath "completed recovery publish for $metadataDate"
            $published = $true
        }
    }
    return $published
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
    $fullLogPath = Join-Path $RepoPath $LogPath
    Publish-PendingRoutineRuns -RepoPath $RepoPath -LogPath $fullLogPath -CurrentRunDate $runDate | Out-Null

    $existingMetadata = Join-Path $RepoPath (Join-Path "routine-reports" "$runDate.json")
    if ((Test-Path -LiteralPath $existingMetadata) -and (-not $Force)) {
        $metadata = Get-Content -Raw -LiteralPath $existingMetadata | ConvertFrom-Json
        $published = Publish-ExistingRoutineRun `
            -Metadata $metadata `
            -RunDate $runDate `
            -RepoPath $RepoPath `
            -LogPath $fullLogPath
        if ($published) {
            Append-Run-Log $fullLogPath "completed recovery publish for $runDate"
            Write-Host "Codex daily news routine recovered and published generated work for $runDate."
            return
        }
        Append-Run-Log $fullLogPath "already completed $runDate; use -Force to rerun"
        Write-Host "Codex daily news routine already completed for $runDate. Use -Force to rerun."
        return
    }

    foreach ($name in $codexRepos) {
        $path = Join-Path $WorkspaceRoot $name
        if (Test-Path -LiteralPath (Join-Path $path ".git")) {
            Assert-Clean-GitRepo $path
            Set-CodexGitIdentity $path
        }
    }

    Push-Location $RepoPath
    try {
        git config user.name $GitAuthorName
        git config user.email $GitAuthorEmail
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
