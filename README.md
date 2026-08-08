# ai-infra-optics-digest

Maintained by: codex-daily-routine

A small, dependency-light digest generator for AI infrastructure, data center optics,
silicon photonics, semiconductors, optical networking, and energy-efficient compute.

The project is designed for reproducibility: fixture RSS/Atom feeds run
the complete pipeline with zero network access, while an explicit `--network` flag can read
real HTTP(S) feeds for live digest generation.

## Why this exists

AI infrastructure changes quickly across several layers at once: accelerator roadmaps,
advanced packaging, optical interconnects, switch fabrics, data center power, and cooling.
This tool turns a small source list into a dated markdown brief with deterministic tagging
and extractive summaries, so the same inputs produce the same output.

## How it works

```text
configs/feeds.yaml + fixtures/feeds/*.xml
    -> feeds.py
    -> classifier.py
    -> summarizer.py
    -> renderer.py
    -> digests/YYYY-MM-DD.md
```

- **Feeds** are RSS or Atom documents. Local fixtures are the default path.
- **Network access** is disabled unless `--network` is passed.
- **Layer tags** are deterministic keyword matches across compute, semiconductors,
  silicon photonics, optical networking, and data center energy.
- **Summaries** are deterministic extractive summaries, not LLM-generated text.

## Quickstart

```bash
pip install -r requirements.txt

# Fixture-only run, no network access
python -m optics_digest.cli build --sources configs/feeds.yaml --out digests --date 2026-08-05

# Optional live mode for HTTP(S) feed URLs in the same config format
python -m optics_digest.cli build --sources configs/feeds.yaml --out digests --network
```

## Daily GitHub Scheduler

This repo includes a Windows Task Scheduler workflow for real daily pushes:

```powershell
.\scripts\run_daily_digest_push.ps1 -Network -CreatePullRequest
.\scripts\install_daily_digest_task.ps1 -Network -CreatePullRequest -At "09:00"
```

The scheduled job runs tests, builds a dated digest from `configs/live_feeds.yaml`, commits
only when content changed, and pushes through `gh`/git. It refuses empty commits and dirty
working trees. Scheduled sends include a bounded random jitter of up to 5 hours before
commit/push and optional PR creation. See [docs/daily-cadence.md](docs/daily-cadence.md).

Check scheduler readiness:

```powershell
.\scripts\check_scheduler_status.ps1
```

## Codex Daily News Routine

The generalized routine extends the digest-only job:

```powershell
.\scripts\run_codex_daily_news_routine.ps1 -Network
.\scripts\install_codex_daily_news_task.ps1 -Network -At "17:00" -PublishWindowStart "17:00" -PublishWindowEnd "02:00"
.\scripts\check_codex_daily_news_status.ps1
```

It rotates live sources day to day, writes `routine-reports/YYYY-MM-DD.md`, filters out
repos marked `Maintained by: claude-daily-routine`, selects a random active Codex-owned
project batch, and writes dated `research-notes/YYYY-MM-DD.md` files only when
source-linked news is relevant to those repos. It stages exact generated paths, picks a
hot-news-biased random daily batch of 6 to 8 active projects, explains hotness scores with
matched terms/source/recency, writes a weekly local HTML rundown under `weekly-rundowns/`,
keeps that rundown local, randomizes actual publish timing inside the 17:00-02:00
Europe/Berlin window, and refuses dirty working trees. A project leaves the active batch
when `configs/project_lifecycle.yaml` or the repo itself says `Project lifecycle: complete`.

## Feed config

```yaml
feeds:
  - name: Optics RSS Fixture
    url: ../fixtures/feeds/optics_rss.xml
  - name: Compute Atom Fixture
    url: ../fixtures/feeds/compute_atom.xml
```

Relative paths are resolved from the config file location.

## Status

MVP: fixture RSS/Atom parsing, deterministic layer tagging, extractive summarization,
explainable hot-news scoring, lifecycle-aware project rotation, weekly HTML rundown output,
and dated markdown digest output.

## License

MIT - see [LICENSE](LICENSE).
