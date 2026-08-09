param(
    [string]$WorkspaceRoot = "",
    [string]$RepoPath = "",
    [string]$PythonPath = "python",
    [string]$GhPath = "gh",
    [string]$Sources = "configs\live_feeds.yaml",
    [string]$Lifecycle = "configs\project_lifecycle.yaml",
    [string]$WeeklyRundownDir = "weekly-rundowns",
    [string]$LogPath = "logs\codex_daily_news_routine.log",
    [int]$DigestLimit = 24,
    [int]$RoutineLimit = 16,
    [int]$MaxSendJitterMinutes = 540,
    [string]$PublishWindowStart = "17:00",
    [string]$PublishWindowEnd = "02:00",
    [int]$MinDailyProjects = 6,
    [int]$MaxDailyProjects = 8,
    [string]$GitAuthorName = "OAndrei314",
    [string]$GitAuthorEmail = "56999057+OAndrei314@users.noreply.github.com",
    [switch]$Network,
    [switch]$Force,
    [switch]$NoSendJitter
)

$ErrorActionPreference = "Stop"
$script:PublishTargets = @()
$script:PublishTargetIndex = 0

if (-not $RepoPath) {
    $RepoPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
}
if (-not $WorkspaceRoot) {
    $WorkspaceRoot = Split-Path -Parent $RepoPath
}

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
        "firmware-validation-agent",
        "physical-ai-data-factory-sim",
        "open-model-supply-chain-radar",
        "agentic-security-canary",
        "long-context-cost-lab",
        "ai-cluster-optics-capacity-planner"
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

function Initialize-RandomPublishSchedule {
    param(
        [int]$Count,
        [string]$Reason,
        [string]$Path
    )
    $script:PublishTargets = @()
    $script:PublishTargetIndex = 0
    if ($Count -le 0) {
        return
    }
    if ($NoSendJitter -or $MaxSendJitterMinutes -le 0) {
        Append-Run-Log $Path "randomized per-repo publish schedule skipped for $Reason"
        return
    }

    $window = Get-NextPublishWindow -Now (Get-Date) -Start (Convert-PublishWindowTime $PublishWindowStart) -End (Convert-PublishWindowTime $PublishWindowEnd)
    $now = Get-Date
    $earliestTarget = if ($now -lt $window.Start) { $window.Start } else { $now.AddSeconds(1) }
    if ($earliestTarget -ge $window.End) {
        $window = Get-NextPublishWindow -Now $window.End.AddSeconds(1) -Start (Convert-PublishWindowTime $PublishWindowStart) -End (Convert-PublishWindowTime $PublishWindowEnd)
        $earliestTarget = $window.Start
    }
    $latestTarget = $window.End.AddSeconds(-1)
    $rangeSeconds = [int][Math]::Floor(($latestTarget - $earliestTarget).TotalSeconds)
    if ($rangeSeconds -lt 0) {
        $script:PublishTargets = @($earliestTarget)
        Append-Run-Log $Path "scheduled 1 randomized publish target for $Reason`: $($earliestTarget.ToString('yyyy-MM-dd HH:mm:ss'))"
        return
    }

    $offsets = New-Object "System.Collections.Generic.HashSet[int]"
    $attempts = 0
    while ($offsets.Count -lt $Count -and $attempts -lt ($Count * 20)) {
        [void]$offsets.Add((Get-Random -Minimum 0 -Maximum ($rangeSeconds + 1)))
        $attempts += 1
    }
    $fallbackOffset = 0
    while ($offsets.Count -lt $Count) {
        [void]$offsets.Add([Math]::Min($fallbackOffset, $rangeSeconds))
        $fallbackOffset += 1
    }

    $script:PublishTargets = @($offsets | Sort-Object | ForEach-Object { $earliestTarget.AddSeconds($_) })
    $targetSummary = ($script:PublishTargets | ForEach-Object { $_.ToString("yyyy-MM-dd HH:mm:ss") }) -join ", "
    Append-Run-Log $Path "scheduled $($script:PublishTargets.Count) randomized per-repo publish target(s) for $Reason within $PublishWindowStart-$PublishWindowEnd`: $targetSummary"
}

function Invoke-RandomPublishWait {
    param(
        [string]$Reason,
        [string]$Path
    )
    if ($NoSendJitter -or $MaxSendJitterMinutes -le 0) {
        Append-Run-Log $Path "randomized publish wait skipped for $Reason"
        return
    }
    if ($script:PublishTargetIndex -ge $script:PublishTargets.Count) {
        Initialize-RandomPublishSchedule -Count 1 -Reason $Reason -Path $Path
    }

    $targetNumber = $script:PublishTargetIndex + 1
    $targetTotal = [Math]::Max($script:PublishTargets.Count, $targetNumber)
    $target = $script:PublishTargets[$script:PublishTargetIndex]
    $script:PublishTargetIndex += 1
    $now = Get-Date
    $seconds = [int][Math]::Ceiling(($target - $now).TotalSeconds)
    if ($seconds -lt 1) {
        $seconds = 1
        $target = $now.AddSeconds(1)
    }
    Append-Run-Log $Path "waiting $seconds second(s) until $($target.ToString('yyyy-MM-dd HH:mm:ss')) before $Reason; randomized publish target $targetNumber/$targetTotal; publish window $PublishWindowStart-$PublishWindowEnd"
    Write-Host "Randomized publish target $targetNumber/$targetTotal`: waiting $seconds second(s), target $($target.ToString('yyyy-MM-dd HH:mm:ss')), before $Reason."
    Start-Sleep -Seconds $seconds
}

function Convert-PublishWindowTime {
    param([string]$Value)
    try {
        return [TimeSpan]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        throw "Invalid publish window time '$Value'. Use HH:mm, for example 17:00."
    }
}

function Get-NextPublishWindow {
    param(
        [datetime]$Now,
        [TimeSpan]$Start,
        [TimeSpan]$End
    )
    if ($End -eq $Start) {
        throw "Publish window start and end must be different."
    }
    if ($End -lt $Start) {
        $previousStart = $Now.Date.AddDays(-1).Add($Start)
        $previousEnd = $Now.Date.Add($End)
        if ($Now -lt $previousEnd) {
            return [pscustomobject]@{ Start = $previousStart; End = $previousEnd }
        }
        $todayStart = $Now.Date.Add($Start)
        $todayEnd = $Now.Date.AddDays(1).Add($End)
        return [pscustomobject]@{ Start = $todayStart; End = $todayEnd }
    }
    $todayStart = $Now.Date.Add($Start)
    $todayEnd = $Now.Date.Add($End)
    if ($Now -lt $todayEnd) {
        return [pscustomobject]@{ Start = $todayStart; End = $todayEnd }
    }
    return [pscustomobject]@{ Start = $todayStart.AddDays(1); End = $todayEnd.AddDays(1) }
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

function Assert-PublicContentSafe {
    param(
        [string]$Repo,
        [string[]]$Paths
    )
    $existingPaths = @()
    foreach ($path in $Paths) {
        if (Test-Path -LiteralPath (Join-Path $Repo $path)) {
            $existingPaths += (Normalize-GitPath $path)
        }
    }
    if (-not $existingPaths) {
        return
    }

    Push-Location $Repo
    try {
        & $PythonPath -m optics_digest.cli guard-public-content @existingPaths
        if ($LASTEXITCODE -ne 0) {
            throw "Public content guard rejected generated files in $Repo"
        }
    } finally {
        Pop-Location
    }
}

function Push-PendingRoutineCommit {
    param(
        [string]$Repo,
        [string]$ExpectedSubject,
        [string]$Path,
        [string]$Reason,
        [switch]$UseJitter
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
            if ($UseJitter) {
                Invoke-RandomPublishWait -Reason $Reason -Path $Path
            }
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
            Assert-PublicContentSafe -Repo $Repo -Paths $existingPaths
            git add -- $existingPaths
            git diff --cached --quiet -- $existingPaths
            if ($LASTEXITCODE -ne 0) {
                if ($UseJitter) {
                    Invoke-RandomPublishWait -Reason $Reason -Path $LogPath
                }
                git commit -m $CommitMessage
                git push origin HEAD
                return $true
            }
        }
    } finally {
        Pop-Location
    }

    return (Push-PendingRoutineCommit -Repo $Repo -ExpectedSubject $CommitMessage -Path $LogPath -Reason $Reason -UseJitter:$UseJitter)
}

function Get-RoutinePublishUnitCount {
    param(
        [object[]]$NoteTargets,
        [string]$RepoPath
    )
    $count = 1
    $repoFull = (Resolve-Path -LiteralPath $RepoPath).Path
    foreach ($target in $NoteTargets) {
        if (-not (Test-Path -LiteralPath $target.RepoPath) -or -not (Test-Path -LiteralPath $target.NotePath)) {
            continue
        }
        $selectedFull = (Resolve-Path -LiteralPath $target.RepoPath).Path
        if ($selectedFull -ne $repoFull) {
            $count += 1
        }
    }
    return $count
}

function Get-MetadataNoteTargets {
    param(
        [object]$Metadata,
        [string]$WorkspaceRoot
    )
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
            $repoPath = Resolve-RoutineRepoPath -WorkspaceRoot $WorkspaceRoot -PathOrName $repoPath
            $notePath = Resolve-RoutineFilePath -WorkspaceRoot $WorkspaceRoot -RepoPath $repoPath -PathOrName $notePath
            $targets += [pscustomobject]@{
                RepoPath = $repoPath
                NotePath = $notePath
            }
        }
    } elseif ($Metadata.note_path) {
        $repoPath = Resolve-RoutineRepoPath -WorkspaceRoot $WorkspaceRoot -PathOrName ([string]$Metadata.selected_repo_path)
        $notePath = Resolve-RoutineFilePath -WorkspaceRoot $WorkspaceRoot -RepoPath $repoPath -PathOrName ([string]$Metadata.note_path)
        $targets += [pscustomobject]@{
            RepoPath = $repoPath
            NotePath = $notePath
        }
    }

    return @($targets)
}

function Resolve-RoutineRepoPath {
    param(
        [string]$WorkspaceRoot,
        [string]$PathOrName
    )
    if (-not $PathOrName) {
        return $null
    }
    if (Test-Path -LiteralPath $PathOrName) {
        return (Resolve-Path -LiteralPath $PathOrName).Path
    }
    $workspacePath = Join-Path $WorkspaceRoot $PathOrName
    if (Test-Path -LiteralPath $workspacePath) {
        return (Resolve-Path -LiteralPath $workspacePath).Path
    }
    return $PathOrName
}

function Resolve-RoutineFilePath {
    param(
        [string]$WorkspaceRoot,
        [string]$RepoPath,
        [string]$PathOrName
    )
    if (-not $PathOrName) {
        return $null
    }
    if (Test-Path -LiteralPath $PathOrName) {
        return (Resolve-Path -LiteralPath $PathOrName).Path
    }
    $workspacePath = Join-Path $WorkspaceRoot $PathOrName
    if (Test-Path -LiteralPath $workspacePath) {
        return (Resolve-Path -LiteralPath $workspacePath).Path
    }
    if ($RepoPath) {
        $repoPathCandidate = Join-Path $RepoPath $PathOrName
        if (Test-Path -LiteralPath $repoPathCandidate) {
            return (Resolve-Path -LiteralPath $repoPathCandidate).Path
        }
    }
    return $PathOrName
}

function Publish-ExistingRoutineRun {
    param(
        [object]$Metadata,
        [string]$RunDate,
        [string]$WorkspaceRoot,
        [string]$RepoPath,
        [string]$LogPath
    )
    $published = $false
    $repoFull = (Resolve-Path -LiteralPath $RepoPath).Path

    $noteTargets = @(Get-MetadataNoteTargets -Metadata $Metadata -WorkspaceRoot $WorkspaceRoot)
    Initialize-RandomPublishSchedule `
        -Count (Get-RoutinePublishUnitCount -NoteTargets $noteTargets -RepoPath $RepoPath) `
        -Reason "recovered routine publish $RunDate" `
        -Path $LogPath
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
                -LogPath $LogPath `
                -UseJitter) -or $published
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
        -LogPath $LogPath `
        -UseJitter) -or $published

    return $published
}

function Publish-PendingRoutineRuns {
    param(
        [string]$RepoPath,
        [string]$LogPath,
        [string]$WorkspaceRoot,
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
            -WorkspaceRoot $WorkspaceRoot `
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
    Publish-PendingRoutineRuns -RepoPath $RepoPath -LogPath $fullLogPath -WorkspaceRoot $WorkspaceRoot -CurrentRunDate $runDate | Out-Null

    $existingMetadata = Join-Path $RepoPath (Join-Path "routine-reports" "$runDate.json")
    if ((Test-Path -LiteralPath $existingMetadata) -and (-not $Force)) {
        $metadata = Get-Content -Raw -LiteralPath $existingMetadata | ConvertFrom-Json
        $published = Publish-ExistingRoutineRun `
            -Metadata $metadata `
            -RunDate $runDate `
            -WorkspaceRoot $WorkspaceRoot `
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
            "--lifecycle", $Lifecycle,
            "--weekly-html-out", $WeeklyRundownDir,
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
    $noteTargets = @(Get-MetadataNoteTargets -Metadata $metadata -WorkspaceRoot $WorkspaceRoot)
    Initialize-RandomPublishSchedule `
        -Count (Get-RoutinePublishUnitCount -NoteTargets $noteTargets -RepoPath $RepoPath) `
        -Reason "daily routine publish $($metadata.run_date)" `
        -Path $fullLogPath
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
        Assert-PublicContentSafe -Repo $RepoPath -Paths $stagePaths
        git add -- $stagePaths
        git diff --cached --quiet
        if ($LASTEXITCODE -ne 0) {
            Invoke-RandomPublishWait -Reason "digest routine commit/push" -Path $fullLogPath
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
