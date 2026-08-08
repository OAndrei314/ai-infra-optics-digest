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
    [int]$MinDailyProjects = 3,
    [int]$MaxDailyProjects = 6,
    [string]$GitAuthorName = "OAndrei314",
    [string]$GitAuthorEmail = "56999057+OAndrei314@users.noreply.github.com",
    [switch]$Network,
    [switch]$Force,
    [switch]$NoSendJitter
)

$ErrorActionPreference = "Stop"
$script:SendJitterUsed = $false

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

function Get-CodexRepoPaths {
    param([string]$Root)
    $codexMarker = "Maintained by: codex-daily-routine"
    $claudeMarker = "Maintained by: claude-daily-routine"
    $otherRoutineRepos = @(
        "open-weight-eval-arena",
        "optical-fault-localization-ml",
        "rl-hardware-calibration-lab",
        "mcp-telemetry-server",
        "local-inference-bench",
        "thermal-acoustic-optimizer"
    )
    $personalExcludes = @(
        "aia_tasks",
        "polybot",
        "UniversityProject",
        "android_course",
        "test",
        "pendulums",
        "Qojo"
    )
    $seedRepos = @(
        "ai-infra-optics-digest",
        "ai-factory-optical-twin",
        "tinyml-quantized-telemetry-bench",
        "silicon-photonics-telemetry-monitor",
        "firmware-validation-agent"
    )
    $paths = @()
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if (-not (Test-Path -LiteralPath (Join-Path $item.FullName ".git"))) {
            continue
        }
        if ($otherRoutineRepos -contains $item.Name -or $personalExcludes -contains $item.Name) {
            continue
        }
        $readmeText = ""
        foreach ($readmeName in @("README.md", "readme.md")) {
            $readmePath = Join-Path $item.FullName $readmeName
            if (Test-Path -LiteralPath $readmePath) {
                $readmeText = Get-Content -Raw -LiteralPath $readmePath -Encoding utf8
                break
            }
        }
        if ($readmeText -match [regex]::Escape($claudeMarker)) {
            continue
        }
        if (($readmeText -match [regex]::Escape($codexMarker)) -or ($seedRepos -contains $item.Name)) {
            $paths += $item.FullName
        }
    }
    return @($paths)
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
    if ($script:SendJitterUsed) {
        Append-Run-Log $Path "send jitter already applied; continuing with $Reason"
        return
    }
    $script:SendJitterUsed = $true
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

function Get-MetadataNoteTargets {
    param([object]$Metadata)
    $targets = @()
    $propertyNames = @($Metadata.PSObject.Properties.Name)

    if (($propertyNames -contains "note_paths") -and $Metadata.note_paths) {
        $notes = @($Metadata.note_paths) | Where-Object { $_ }
        $repoPaths = @()
        if (($propertyNames -contains "note_repo_paths") -and $Metadata.note_repo_paths) {
            $repoPaths = @($Metadata.note_repo_paths)
        }
        for ($i = 0; $i -lt $notes.Count; $i++) {
            $notePath = [string]$notes[$i]
            $repoPath = $null
            if ($i -lt $repoPaths.Count -and $repoPaths[$i]) {
                $repoPath = [string]$repoPaths[$i]
            } elseif (($propertyNames -contains "selected_repo_path") -and $Metadata.selected_repo_path) {
                $repoPath = [string]$Metadata.selected_repo_path
            } else {
                $repoPath = Split-Path -Parent (Split-Path -Parent $notePath)
            }
            $targets += [pscustomobject]@{
                RepoPath = $repoPath
                NotePath = $notePath
            }
        }
    } elseif ($Metadata.note_path) {
        $targets += [pscustomobject]@{
            RepoPath = [string]$Metadata.selected_repo_path
            NotePath = [string]$Metadata.note_path
        }
    }

    return @($targets)
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

    $noteTargets = @(Get-MetadataNoteTargets -Metadata $Metadata)
    foreach ($target in $noteTargets) {
        if (-not (Test-Path -LiteralPath $target.RepoPath) -or -not (Test-Path -LiteralPath $target.NotePath)) {
            continue
        }
        $selectedFull = (Resolve-Path -LiteralPath $target.RepoPath).Path
        if ($selectedFull -ne $repoFull) {
            $relativeNote = Relative-GitPath $selectedFull $target.NotePath
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
    foreach ($target in $noteTargets) {
        if (-not (Test-Path -LiteralPath $target.NotePath)) {
            continue
        }
        $noteFull = (Resolve-Path -LiteralPath $target.NotePath).Path
        if ($noteFull.StartsWith($repoFull)) {
            $stagePaths += (Relative-GitPath $RepoPath $target.NotePath)
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

    foreach ($path in @(Get-CodexRepoPaths -Root $WorkspaceRoot)) {
        Assert-Clean-GitRepo $path
        Set-CodexGitIdentity $path
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
            "--min-repos", "$MinDailyProjects",
            "--max-repos", "$MaxDailyProjects",
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

    $noteCommitCount = 0
    $repoFull = (Resolve-Path -LiteralPath $RepoPath).Path
    $noteTargets = @(Get-MetadataNoteTargets -Metadata $metadata)
    foreach ($target in $noteTargets) {
        if (-not (Test-Path -LiteralPath $target.RepoPath) -or -not (Test-Path -LiteralPath $target.NotePath)) {
            continue
        }
        $selectedFull = (Resolve-Path -LiteralPath $target.RepoPath).Path
        if ($selectedFull -ne $repoFull) {
            $relativeNote = Relative-GitPath $selectedFull $target.NotePath
            $published = Publish-GeneratedPaths `
                -Repo $selectedFull `
                -Paths @($relativeNote) `
                -CommitMessage "Add daily news research note $($metadata.run_date)" `
                -Reason "selected repo commit/push" `
                -LogPath $fullLogPath `
                -UseJitter
            if ($published) {
                $noteCommitCount += 1
            }
        }
    }

    Push-Location $RepoPath
    try {
        $stagePaths = @($digestPath, $reportPath, $metadataPath)
        foreach ($target in $noteTargets) {
            if (-not (Test-Path -LiteralPath $target.NotePath)) {
                continue
            }
            $noteFull = (Resolve-Path -LiteralPath $target.NotePath).Path
            if ($noteFull.StartsWith($repoFull)) {
                $stagePaths += (Relative-GitPath $RepoPath $target.NotePath)
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

    $selectedLabel = if ($metadata.selected_repos) { @($metadata.selected_repos) -join "," } else { $metadata.selected_repo }
    Append-Run-Log (Join-Path $RepoPath $LogPath) "completed $runDate; selected=$selectedLabel; noteCommitCount=$noteCommitCount"
} catch {
    Append-Run-Log (Join-Path $RepoPath $LogPath) "failed: $($_.Exception.Message)"
    throw
}
