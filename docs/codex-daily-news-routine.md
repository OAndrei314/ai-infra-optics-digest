# Codex Daily News Routine

Maintained by: codex-daily-routine

This is the generalized daily task for the Codex-owned portfolio slice.

## What It Does

1. Verifies the Codex-owned repo working trees are clean.
2. Pulls `ai-infra-optics-digest` with `--ff-only`.
3. Installs dependencies and the package itself.
4. Runs bare `pytest -v`.
5. Builds the dated digest from `configs/live_feeds.yaml` with source rotation.
6. Runs the repo/news routine and writes `routine-reports/YYYY-MM-DD.md`.
7. Randomly selects 5 to 10 total Codex-owned projects, biased toward the hottest current
   AI/news signals, and writes dated research notes when source-linked material exists.
8. Stages exact generated paths, waits a random send jitter, commits only if content
   changed, and pushes.

## Ownership Rules

The routine may touch repos with `Maintained by: codex-daily-routine` or the current Codex
seed list:

- `ai-infra-optics-digest`
- `ai-factory-optical-twin`
- `tinyml-quantized-telemetry-bench`
- `silicon-photonics-telemetry-monitor`
- `firmware-validation-agent`

It skips repos marked `Maintained by: claude-daily-routine` and the hardcoded disjoint
Claude-owned set from the handoff.

## Commands

```powershell
.\scripts\run_codex_daily_news_routine.ps1 -Network
.\scripts\install_codex_daily_news_task.ps1 -Network -At "09:00" -MaxSendJitterMinutes 300 -MinDailyProjects 5 -MaxDailyProjects 10
.\scripts\check_codex_daily_news_status.ps1
```

The installed task name is `OAndrei314 Codex Daily News Routine`.

## Randomized Send Timing

By default, the scheduler waits a random 1 to 18000 seconds before the daily publish batch.
That keeps the daily publishing cadence from firing at the exact same second every day
while still committing only real generated work. Use `-MaxSendJitterMinutes` to change the
window, set it to `0`, or pass `-NoSendJitter` for manual verification runs. The installer
keeps a conservative runtime budget so the randomized publish window can complete.

If a scheduled run is interrupted after writing the dated metadata, the next run no longer
gets stuck on "already completed." It attempts a recovery publish for the exact generated
digest, routine report, metadata, and selected project research note paths.

Scheduled commits use the account-scoped GitHub no-reply email by default so GitHub can
attribute them to `OAndrei314` when they land on the repository default branch.

Each daily run selects a random batch of Codex-owned projects, with `ai-infra-optics-digest`
included as the coordination repo. The default batch size is minimum 5 and maximum 10 total
projects, bounded by the number of available Codex-owned repos. The selector gives priority
to repos whose topics match the hottest feed items before filling the rest randomly.
