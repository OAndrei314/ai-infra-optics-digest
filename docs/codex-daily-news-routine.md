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
7. Writes a dated research note to the selected repo only when relevant source-linked
   material exists.
8. Stages exact generated paths, commits only if content changed, and pushes.

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
.\scripts\install_codex_daily_news_task.ps1 -Network -At "09:00"
.\scripts\check_codex_daily_news_status.ps1
```

The installed task name is `OAndrei314 Codex Daily News Routine`.
