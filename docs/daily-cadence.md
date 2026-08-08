# Daily GitHub Cadence

This repo is the honest daily-push engine for the portfolio.

The scheduler does not create empty commits. Each run:

1. Verifies `gh` authentication and the `origin` remote.
2. Pulls with `--ff-only`.
3. Installs dependencies.
4. Runs `pytest -v`.
5. Builds a dated digest from live public feeds when `-Network` is enabled.
6. Waits a bounded random send jitter before commit/push and optional PR creation.
7. Commits `digests/YYYY-MM-DD.md` and pushes only if the digest changed.
8. Appends a local status line to `logs/daily_digest_push.log`.

That means no fake contribution-graph padding. If there is no new content or the working
tree is dirty, it exits without committing.

The installer also checks GitHub auth, `origin`, and clean working tree state before
registering the task. Use `-SkipReadinessCheck` only when deliberately staging the task
before the repository is published.

## Install

Authenticate GitHub CLI first:

```powershell
& "C:\Program Files\GitHub CLI\gh.exe" auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web
```

Publish the repository once so it has an `origin` remote. Then install the daily task:

```powershell
.\scripts\install_daily_digest_task.ps1 -Network -CreatePullRequest -At "09:00" -MaxSendJitterMinutes 300
```

## Run Once

```powershell
.\scripts\run_daily_digest_push.ps1 -Network -CreatePullRequest -NoSendJitter
```

Scheduled runs default to a random 1 to 18000 second delay before publishing. Use
`-MaxSendJitterMinutes` to change that window, or `-NoSendJitter` for manual checks. The
installed task allows up to 12 hours of runtime so commit/push and optional PR jitter can
complete.

## Check Status

```powershell
.\scripts\check_scheduler_status.ps1
```

## Feed Sources

`configs/live_feeds.yaml` uses arXiv RSS feeds for AI, ML, distributed computing,
hardware architecture, signal processing, optics, plus an optional NVIDIA Developer Blog
feed. Optional feeds may fail without blocking the daily digest.
