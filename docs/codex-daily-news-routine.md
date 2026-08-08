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
8. Stages exact generated paths, waits until a randomized target inside the 17:00-02:00
   publish window, commits only if content changed, and pushes.

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
.\scripts\install_codex_daily_news_task.ps1 -Network -At "17:00" -PublishWindowStart "17:00" -PublishWindowEnd "02:00" -MinDailyProjects 5 -MaxDailyProjects 10
.\scripts\check_codex_daily_news_status.ps1
```

The installed task name is `OAndrei314 Codex Daily News Routine`.

## Randomized Send Timing

By default, the scheduler triggers at 17:00 Europe/Berlin and picks a random publish target
inside the overnight 17:00-02:00 window. It never publishes at the old 09:00 trigger time,
and it also avoids publishing exactly at 17:00 because the first possible randomized target
is at least one second after the runner reaches the publish gate. Pass `-NoSendJitter` only
for manual verification runs. The installer keeps a conservative runtime budget so missed
or delayed starts can still wait for the next valid publish window.

If a scheduled run is interrupted after writing the dated metadata, the next run no longer
gets stuck on "already completed." It attempts a recovery publish for the exact generated
digest, routine report, metadata, and selected project research note paths.

Scheduled commits use the account-scoped GitHub no-reply email by default so GitHub can
attribute them to `OAndrei314` when they land on the repository default branch.

Each daily run selects a random batch of Codex-owned projects, with `ai-infra-optics-digest`
included as the coordination repo. The default batch size is minimum 5 and maximum 10 total
projects, bounded by the number of available Codex-owned repos. The selector gives priority
to repos whose topics match the hottest feed items before filling the rest randomly.
