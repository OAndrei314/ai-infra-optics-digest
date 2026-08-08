"""News-aware multi-repo routine for the Codex-owned portfolio slice.

This module is deliberately conservative. It does not invent code changes. It reads live
news/digest items, selects a randomized daily batch of Codex-owned repos, and writes
auditable research notes only when there is source-linked material to justify a commit.
"""
from __future__ import annotations

import json
import random
import re
import subprocess
import html as html_lib
from dataclasses import asdict, dataclass
from datetime import date, timedelta
from pathlib import Path

import yaml

from .classifier import tag_items
from .feeds import collect_items, select_sources_for_date, source_rotation_period
from .hotness import hotness_score, sort_hot_entries
from .models import DigestEntry, FeedSource

CODEX_MARKER = "Maintained by: codex-daily-routine"
CLAUDE_MARKER = "Maintained by: claude-daily-routine"

OTHER_ROUTINE_REPOS = {
    "open-weight-eval-arena",
    "optical-fault-localization-ml",
    "rl-hardware-calibration-lab",
    "mcp-telemetry-server",
    "local-inference-bench",
    "thermal-acoustic-optimizer",
}

PERSONAL_EXCLUDES = {
    "aia_tasks",
    "polybot",
    "UniversityProject",
    "android_course",
    "test",
    "pendulums",
    "Qojo",
}

CODEX_SEED_REPOS = {
    "ai-infra-optics-digest",
    "ai-factory-optical-twin",
    "tinyml-quantized-telemetry-bench",
    "silicon-photonics-telemetry-monitor",
    "firmware-validation-agent",
    "physical-ai-data-factory-sim",
    "open-model-supply-chain-radar",
    "agentic-security-canary",
    "long-context-cost-lab",
    "ai-cluster-optics-capacity-planner",
}

REPO_TOPICS = {
    "ai-infra-optics-digest": (
        "open-weight",
        "model",
        "gpu",
        "accelerator",
        "datacenter",
        "data center",
        "silicon photonics",
        "optical",
        "power",
    ),
    "ai-factory-optical-twin": (
        "datacenter",
        "data center",
        "gpu",
        "cluster",
        "optical",
        "co-packaged",
        "cpo",
        "network",
        "power",
    ),
    "tinyml-quantized-telemetry-bench": (
        "quantization",
        "int8",
        "edge",
        "tinyml",
        "inference",
        "latency",
        "efficient",
    ),
    "silicon-photonics-telemetry-monitor": (
        "silicon photonics",
        "photonics",
        "telemetry",
        "optical",
        "laser",
        "transceiver",
        "drift",
    ),
    "firmware-validation-agent": (
        "agent",
        "validation",
        "verification",
        "firmware",
        "hardware",
        "test",
        "tool use",
    ),
    "physical-ai-data-factory-sim": (
        "physical ai",
        "world model",
        "open world model",
        "robotics",
        "synthetic data",
        "simulation",
        "omniverse",
        "cosmos",
    ),
    "open-model-supply-chain-radar": (
        "open-weight",
        "open weight",
        "weights",
        "license",
        "supply chain",
        "model release",
        "governance",
        "frontier",
    ),
    "agentic-security-canary": (
        "agent",
        "agentic",
        "cybersecurity",
        "security",
        "breach",
        "hack",
        "containment",
        "tool use",
    ),
    "long-context-cost-lab": (
        "context",
        "1m",
        "million-token",
        "long context",
        "prefill",
        "decode",
        "inference",
        "serving",
        "vllm",
        "cost",
    ),
    "ai-cluster-optics-capacity-planner": (
        "data center",
        "datacenter",
        "gpu",
        "rack",
        "optical",
        "transceiver",
        "network",
        "bandwidth",
        "capex",
        "power",
    ),
}

EXTRAORDINARY_TERMS = (
    "frontier",
    "open-weight",
    "open weight",
    "weights",
    "release",
    "launch",
    "benchmark",
    "record",
    "trillion",
    "co-packaged",
    "silicon photonics",
    "data center",
    "datacenter",
    "accelerator",
)

COMPLETE_STATUSES = {"complete", "completed", "done", "finished", "archived"}
ACTIVE_STATUSES = {"active", "building", "in_progress", "incubating"}
LIFECYCLE_RE = re.compile(
    r"(?im)^\s*(?:project\s+)?(?:lifecycle|status)\s*:\s*(active|building|in_progress|incubating|complete|completed|done|finished|archived)\s*$"
)


@dataclass(frozen=True)
class RepoCandidate:
    name: str
    path: str
    branch: str
    remote: str
    last_pushed_unix: int
    marker: str


@dataclass(frozen=True)
class ProjectLifecycle:
    name: str
    status: str
    signal: str
    reason: str
    maturity_score: float
    last_commit: str


@dataclass(frozen=True)
class RoutineRun:
    run_date: str
    selected_repo: str
    selected_repo_path: str
    report_path: str
    note_path: str | None
    selected_repos: tuple[str, ...]
    selected_repo_paths: tuple[str, ...]
    note_repos: tuple[str, ...]
    note_repo_paths: tuple[str, ...]
    note_paths: tuple[str, ...]
    active_repos: tuple[str, ...]
    completed_repos: tuple[str, ...]
    replacement_needed: bool
    replacement_reason: str
    weekly_rundown_path: str | None
    sources_checked: tuple[str, ...]
    skipped_repos: tuple[str, ...]
    extraordinary_items: tuple[str, ...]
    action: str


def discover_repos(root: str | Path) -> tuple[tuple[RepoCandidate, ...], tuple[str, ...]]:
    root = Path(root)
    candidates: list[RepoCandidate] = []
    skipped: list[str] = []
    for path in sorted(item for item in root.iterdir() if item.is_dir()):
        if not (path / ".git").exists():
            continue
        name = path.name
        readme = _read_readme(path)
        marker = _marker_for_readme(readme)
        if _should_skip_repo(name, marker):
            skipped.append(name)
            continue
        if marker != CODEX_MARKER and name not in CODEX_SEED_REPOS:
            skipped.append(name)
            continue
        candidates.append(
            RepoCandidate(
                name=name,
                path=str(path),
                branch=_git(path, "branch", "--show-current") or "unknown",
                remote=_git(path, "remote", "get-url", "origin") or "",
                last_pushed_unix=_last_pushed_unix(path),
                marker=marker or "seed-list",
            )
        )
    return tuple(candidates), tuple(skipped)


def choose_repo(candidates: tuple[RepoCandidate, ...]) -> RepoCandidate:
    if not candidates:
        raise ValueError("no Codex-owned candidate repos found")
    return sorted(candidates, key=lambda repo: (repo.last_pushed_unix, repo.name))[0]


def choose_repos(
    candidates: tuple[RepoCandidate, ...],
    min_count: int = 6,
    max_count: int = 8,
    required_repo: str | None = "ai-infra-optics-digest",
    priority_repos: tuple[str, ...] = (),
    rng: random.Random | None = None,
) -> tuple[RepoCandidate, ...]:
    if not candidates:
        raise ValueError("no Codex-owned candidate repos found")
    rng = rng or random.SystemRandom()
    upper = min(max(1, max_count), len(candidates))
    lower = min(max(1, min_count), upper)
    target_count = rng.randint(lower, upper)

    by_name = {repo.name: repo for repo in candidates}
    selected: list[RepoCandidate] = []
    if required_repo and required_repo in by_name:
        selected.append(by_name[required_repo])

    for name in priority_repos:
        if len(selected) >= target_count:
            break
        repo = by_name.get(name)
        if repo and repo not in selected:
            selected.append(repo)

    remaining = [repo for repo in candidates if repo not in selected]
    needed = max(0, target_count - len(selected))
    if needed:
        selected.extend(rng.sample(remaining, k=min(needed, len(remaining))))

    return tuple(sorted(selected, key=lambda repo: repo.name))


def scan_news(
    sources_path: str | Path,
    run_date: date,
    allow_network: bool,
    limit: int,
) -> tuple[list[DigestEntry], tuple[str, ...]]:
    items = collect_items(
        sources_path,
        allow_network=allow_network,
        limit=limit,
        rotation_date=run_date,
    )
    entries = sort_hot_entries(tag_items(items))
    sources = _selected_source_names(sources_path, run_date)
    return entries, sources


def run_news_routine(
    root: str | Path,
    sources_path: str | Path,
    out_dir: str | Path,
    run_date: date,
    allow_network: bool = False,
    limit: int = 16,
    write_note: bool = False,
    metadata_out: str | Path | None = None,
    min_repo_count: int = 6,
    max_repo_count: int = 8,
    selection_seed: str | None = None,
    lifecycle_path: str | Path | None = None,
    weekly_html_out: str | Path | None = None,
) -> RoutineRun:
    candidates, skipped = discover_repos(root)
    lifecycle = assess_project_lifecycle(candidates, lifecycle_path=lifecycle_path)
    active_candidates = tuple(repo for repo in candidates if lifecycle[repo.name].status not in COMPLETE_STATUSES)
    completed_repos = tuple(repo.name for repo in candidates if lifecycle[repo.name].status in COMPLETE_STATUSES)
    if not active_candidates:
        raise ValueError("no active Codex-owned candidate repos found")
    replacement_needed = len(active_candidates) < min_repo_count
    replacement_reason = (
        f"active Codex-owned repo count is {len(active_candidates)}, below target minimum {min_repo_count}; found a new project before the next full batch"
        if replacement_needed
        else ""
    )
    entries, sources_checked = scan_news(sources_path, run_date, allow_network, limit)
    priority_repos = _hot_priority_repos(active_candidates, entries)
    rng = random.Random(selection_seed) if selection_seed is not None else None
    selected_repos = choose_repos(
        active_candidates,
        min_count=min_repo_count,
        max_count=max_repo_count,
        required_repo="ai-infra-optics-digest",
        priority_repos=priority_repos,
        rng=rng,
    )
    selected = next(
        (repo for repo in selected_repos if repo.name == "ai-infra-optics-digest"),
        selected_repos[0],
    )
    entries_by_repo = {repo.name: _entries_for_repo_note(entries, repo.name) for repo in selected_repos}
    extraordinary = tuple(entry.item.title for entry in entries if _is_extraordinary(entry))

    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    report_path = out_dir / f"{run_date.isoformat()}.md"
    note_paths: list[Path] = []
    note_repos: list[RepoCandidate] = []
    action = "logged_news_scan"
    if write_note:
        for repo in selected_repos:
            note_entries = entries_by_repo[repo.name]
            if not note_entries:
                continue
            note_dir = Path(repo.path) / "research-notes"
            note_dir.mkdir(parents=True, exist_ok=True)
            note_path = note_dir / f"{run_date.isoformat()}.md"
            note_path.write_text(render_repo_note(repo, run_date, note_entries, extraordinary), encoding="utf-8")
            note_paths.append(note_path)
            note_repos.append(repo)
        if note_paths:
            action = "wrote_multi_repo_research_notes"

    weekly_rundown_path = None
    if weekly_html_out:
        weekly_rundown_path = write_weekly_rundown(
            root=root,
            out_dir=weekly_html_out,
            run_date=run_date,
            candidates=candidates,
            lifecycle=lifecycle,
            selected_repos=selected_repos,
            entries=entries,
        )

    report_path.write_text(
        render_routine_report(
            run_date=run_date,
            selected_repos=selected_repos,
            candidates=candidates,
            skipped=skipped,
            entries=entries,
            entries_by_repo=entries_by_repo,
            extraordinary=extraordinary,
            sources_checked=sources_checked,
            note_paths=tuple(note_paths),
            lifecycle=lifecycle,
            active_candidates=active_candidates,
            completed_repos=completed_repos,
            replacement_needed=replacement_needed,
            replacement_reason=replacement_reason,
            weekly_rundown_path=weekly_rundown_path,
        ),
        encoding="utf-8",
    )

    result = RoutineRun(
        run_date=run_date.isoformat(),
        selected_repo=selected.name,
        selected_repo_path=selected.path,
        report_path=str(report_path),
        note_path=str(note_paths[0]) if note_paths else None,
        selected_repos=tuple(repo.name for repo in selected_repos),
        selected_repo_paths=tuple(repo.path for repo in selected_repos),
        note_repos=tuple(repo.name for repo in note_repos),
        note_repo_paths=tuple(repo.path for repo in note_repos),
        note_paths=tuple(str(path) for path in note_paths),
        active_repos=tuple(repo.name for repo in active_candidates),
        completed_repos=completed_repos,
        replacement_needed=replacement_needed,
        replacement_reason=replacement_reason,
        weekly_rundown_path=str(weekly_rundown_path) if weekly_rundown_path else None,
        sources_checked=sources_checked,
        skipped_repos=skipped,
        extraordinary_items=extraordinary,
        action=action,
    )
    if metadata_out:
        metadata_path = Path(metadata_out)
        metadata_path.parent.mkdir(parents=True, exist_ok=True)
        metadata_path.write_text(json.dumps(asdict(result), indent=2), encoding="utf-8")
    return result


def render_repo_note(
    selected: RepoCandidate,
    run_date: date,
    entries: list[DigestEntry],
    extraordinary: tuple[str, ...],
) -> str:
    top = entries[:5]
    lines = [
        f"# Daily Research Note - {run_date.isoformat()}",
        "",
        f"Repo: `{selected.name}`",
        "",
        "## Why This Matters",
        "",
        "This note links current public AI/infra news to one concrete future experiment for",
        "this repo. It is a research log, not a benchmark claim.",
        "",
        "## Relevant Signals",
        "",
    ]
    for entry in top:
        item = entry.item
        published = item.published.date().isoformat() if item.published else "undated"
        lines.extend(
            [
                f"### {item.title}",
                "",
                f"- Source: {item.source}",
                f"- Published: {published}",
                f"- Link: {item.link or 'n/a'}",
                f"- Matched layers: {', '.join(entry.matched_layers)}",
                "",
                entry.summary,
                "",
            ]
        )
    lines.extend(
        [
            "## Next Experiment Candidate",
            "",
            _experiment_candidate(selected.name, top, extraordinary),
            "",
        ]
    )
    return "\n".join(lines)


def render_routine_report(
    run_date: date,
    selected_repos: tuple[RepoCandidate, ...],
    candidates: tuple[RepoCandidate, ...],
    skipped: tuple[str, ...],
    entries: list[DigestEntry],
    entries_by_repo: dict[str, list[DigestEntry]],
    extraordinary: tuple[str, ...],
    sources_checked: tuple[str, ...],
    note_paths: tuple[Path, ...],
    lifecycle: dict[str, ProjectLifecycle],
    active_candidates: tuple[RepoCandidate, ...],
    completed_repos: tuple[str, ...],
    replacement_needed: bool,
    replacement_reason: str,
    weekly_rundown_path: Path | None,
) -> str:
    selected_names = ", ".join(f"`{repo.name}`" for repo in selected_repos)
    note_path_text = ", ".join(f"`{path}`" for path in note_paths) if note_paths else "n/a"
    lines = [
        f"# Codex Daily News Routine - {run_date.isoformat()}",
        "",
        f"- Selected repos: {selected_names}",
        f"- Action: {'wrote research notes' if note_paths else 'news scan only'}",
        f"- Note paths: {note_path_text}",
        f"- Candidate repos: {len(candidates)}",
        f"- Active repos: {len(active_candidates)}",
        f"- Completed repos: {len(completed_repos)}",
        f"- Replacement needed: {'yes' if replacement_needed else 'no'}",
        f"- Weekly HTML rundown: `{weekly_rundown_path}`" if weekly_rundown_path else "- Weekly HTML rundown: n/a",
        f"- Skipped repos: {len(skipped)}",
        "",
        "## Sources Checked",
        "",
    ]
    lines.extend(f"- {source}" for source in sources_checked)
    lines.extend(["", "## Repo Rotation", "", "| repo | branch | last pushed unix | marker |", "| --- | --- | ---: | --- |"])
    for repo in sorted(candidates, key=lambda item: (item.last_pushed_unix, item.name)):
        lines.append(f"| {repo.name} | {repo.branch} | {repo.last_pushed_unix} | {repo.marker} |")
    lines.extend(
        [
            "",
            "## Project Lifecycle",
            "",
            "| repo | status | maturity | signal | latest commit |",
            "| --- | --- | ---: | --- | --- |",
        ]
    )
    for repo in sorted(candidates, key=lambda item: item.name):
        state = lifecycle[repo.name]
        lines.append(
            f"| {repo.name} | {state.status} | {state.maturity_score:.2f} | {state.signal} | {state.last_commit} |"
        )
    if replacement_needed:
        lines.extend(["", "## Replacement Signal", "", replacement_reason])
    if skipped:
        lines.extend(["", "## Skipped Repos", ""])
        lines.extend(f"- {name}" for name in skipped)
    lines.extend(["", "## Extraordinary Signals", ""])
    if extraordinary:
        lines.extend(f"- {title}" for title in extraordinary[:8])
    else:
        lines.append("- None crossed the deterministic keyword threshold.")
    lines.extend(["", "## Hottest Items", ""])
    for entry in sorted(entries, key=lambda item: (-hotness_score(item), item.item.title.lower()))[:8]:
        lines.append(f"- score={hotness_score(entry)} | {entry.item.title} ({entry.item.source})")
    lines.extend(["", "## Relevant Items For Selected Repos", ""])
    for repo in selected_repos:
        lines.extend(["", f"### {repo.name}", ""])
        repo_entries = entries_by_repo.get(repo.name, [])
        if repo_entries:
            for entry in repo_entries[:8]:
                lines.append(f"- {entry.item.title} ({entry.item.source})")
        else:
            lines.append("- No source-linked item was available for a repo note.")
    if run_date >= date(2027, 8, 1):
        lines.extend(["", "## Human Review Flag", "", "Routine is within one week of the planned one-year review window."])
    return "\n".join(lines) + "\n"


def assess_project_lifecycle(
    candidates: tuple[RepoCandidate, ...],
    lifecycle_path: str | Path | None = None,
) -> dict[str, ProjectLifecycle]:
    configured = _load_lifecycle_config(lifecycle_path)
    states: dict[str, ProjectLifecycle] = {}
    for repo in candidates:
        repo_path = Path(repo.path)
        readme = _read_readme(repo_path)
        status_file = repo_path / "PROJECT_STATUS.md"
        status_text = status_file.read_text(encoding="utf-8", errors="replace") if status_file.exists() else ""
        config_entry = configured.get(repo.name, {})
        status = str(config_entry.get("status") or _lifecycle_status_from_text(status_text) or _lifecycle_status_from_text(readme) or "active").lower()
        if status not in COMPLETE_STATUSES and status not in ACTIVE_STATUSES:
            status = "active"
        signal = str(config_entry.get("signal") or _lifecycle_signal(status, status_file.exists()))
        reason = str(config_entry.get("reason") or _lifecycle_reason(status, readme, status_text))
        states[repo.name] = ProjectLifecycle(
            name=repo.name,
            status=status,
            signal=signal,
            reason=reason,
            maturity_score=_maturity_score(repo_path, readme, status_file.exists(), status),
            last_commit=_git(repo_path, "log", "-1", "--format=%h %s") or "unknown",
        )
    return states


def write_weekly_rundown(
    root: str | Path,
    out_dir: str | Path,
    run_date: date,
    candidates: tuple[RepoCandidate, ...],
    lifecycle: dict[str, ProjectLifecycle],
    selected_repos: tuple[RepoCandidate, ...],
    entries: list[DigestEntry],
) -> Path:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    iso = run_date.isocalendar()
    path = out / f"{iso.year}-W{iso.week:02d}.html"
    path.write_text(
        render_weekly_rundown_html(
            root=root,
            run_date=run_date,
            candidates=candidates,
            lifecycle=lifecycle,
            selected_repos=selected_repos,
            entries=entries,
        ),
        encoding="utf-8",
    )
    return path.resolve()


def render_weekly_rundown_html(
    root: str | Path,
    run_date: date,
    candidates: tuple[RepoCandidate, ...],
    lifecycle: dict[str, ProjectLifecycle],
    selected_repos: tuple[RepoCandidate, ...],
    entries: list[DigestEntry],
) -> str:
    del root
    week_start = run_date - timedelta(days=run_date.weekday())
    week_end = week_start + timedelta(days=6)
    selected = {repo.name for repo in selected_repos}
    active_count = sum(1 for repo in candidates if lifecycle[repo.name].status not in COMPLETE_STATUSES)
    completed_count = len(candidates) - active_count
    repo_rows = "\n".join(
        _weekly_repo_row(repo, lifecycle[repo.name], week_start, repo.name in selected)
        for repo in sorted(candidates, key=lambda item: item.name)
    )
    hot_rows = "\n".join(
        f"<li><strong>{hotness_score(entry)}</strong> {html_lib.escape(entry.item.title)} <span>{html_lib.escape(entry.item.source)}</span></li>"
        for entry in entries[:8]
    )
    selected_list = ", ".join(html_lib.escape(name) for name in sorted(selected)) or "none"
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Codex Portfolio Weekly Rundown {run_date.isoformat()}</title>
  <style>
    :root {{ --ink:#172026; --muted:#5d6b74; --line:#d8e1e7; --bg:#f6f8f4; --panel:#fff; --green:#18745f; --amber:#9a6700; --red:#b42318; }}
    * {{ box-sizing: border-box; }}
    body {{ margin:0; font-family: Inter, ui-sans-serif, system-ui, -apple-system, Segoe UI, sans-serif; color:var(--ink); background:var(--bg); }}
    header {{ padding:32px clamp(18px,4vw,52px); background:var(--panel); border-bottom:1px solid var(--line); }}
    main {{ padding:24px clamp(18px,4vw,52px) 42px; display:grid; gap:18px; }}
    h1 {{ margin:0 0 8px; font-size:clamp(28px,4vw,46px); letter-spacing:0; }}
    h2 {{ margin:0 0 12px; font-size:20px; }}
    .stats {{ display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:12px; }}
    .stat, section {{ background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:16px; }}
    .label {{ color:var(--muted); font-size:13px; text-transform:uppercase; }}
    .value {{ font-size:28px; font-weight:760; margin-top:4px; }}
    table {{ width:100%; border-collapse:collapse; font-size:14px; }}
    th, td {{ padding:10px; border-bottom:1px solid var(--line); text-align:left; vertical-align:top; }}
    th {{ color:var(--muted); }}
    .active {{ color:var(--green); font-weight:700; }}
    .complete {{ color:var(--red); font-weight:700; }}
    .selected {{ background:#eef7f3; }}
    li {{ margin:8px 0; }}
    li span {{ color:var(--muted); }}
    @media (max-width: 800px) {{ .stats {{ grid-template-columns:1fr 1fr; }} table {{ font-size:13px; }} }}
  </style>
</head>
<body>
  <header>
    <h1>Codex Portfolio Weekly Rundown</h1>
    <p>{week_start.isoformat()} to {week_end.isoformat()} · generated {run_date.isoformat()}</p>
  </header>
  <main>
    <div class="stats">
      <div class="stat"><div class="label">Repos</div><div class="value">{len(candidates)}</div></div>
      <div class="stat"><div class="label">Active</div><div class="value">{active_count}</div></div>
      <div class="stat"><div class="label">Complete</div><div class="value">{completed_count}</div></div>
      <div class="stat"><div class="label">Daily Batch</div><div class="value">{len(selected_repos)}</div></div>
    </div>
    <section>
      <h2>Selected This Run</h2>
      <p>{selected_list}</p>
    </section>
    <section>
      <h2>Project Lifecycle And Weekly Build Log</h2>
      <table>
        <tr><th>Repo</th><th>Status</th><th>Maturity</th><th>This week</th><th>Latest commit</th><th>Signal</th></tr>
        {repo_rows}
      </table>
    </section>
    <section>
      <h2>Hot AI Signals Used</h2>
      <ul>{hot_rows}</ul>
    </section>
  </main>
</body>
</html>
"""


def _selected_source_names(sources_path: str | Path, run_date: date) -> tuple[str, ...]:
    sources_path = Path(sources_path)
    with sources_path.open(encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}
    sources = [
        FeedSource(
            name=str(entry["name"]),
            url=str(entry["url"]),
            required=bool(entry.get("required", True)),
            category=str(entry.get("category", "general")),
            rotation_bucket=int(entry["rotation_bucket"]) if entry.get("rotation_bucket") is not None else None,
        )
        for entry in raw.get("feeds", [])
    ]
    selected = select_sources_for_date(sources, run_date, source_rotation_period(sources_path))
    return tuple(source.name for source in selected)


def _load_lifecycle_config(lifecycle_path: str | Path | None) -> dict[str, dict[str, object]]:
    if not lifecycle_path:
        return {}
    path = Path(lifecycle_path)
    if not path.exists():
        return {}
    with path.open(encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}
    projects = raw.get("projects", {})
    if not isinstance(projects, dict):
        return {}
    return {str(name): dict(value or {}) for name, value in projects.items()}


def _lifecycle_status_from_text(text: str) -> str:
    match = LIFECYCLE_RE.search(text)
    return match.group(1).lower() if match else ""


def _lifecycle_signal(status: str, has_status_file: bool) -> str:
    if status in COMPLETE_STATUSES:
        return "replace_with_new_project"
    if has_status_file:
        return "repo_status_file"
    return "implicit_active"


def _lifecycle_reason(status: str, readme: str, status_text: str) -> str:
    if status in COMPLETE_STATUSES:
        return "project is marked complete and should leave the active daily rotation"
    text = f"{readme}\n{status_text}".lower()
    if "next steps" in text:
        return "active: README/status file still lists next steps"
    if "status" in text:
        return "active: status section present but no complete marker"
    return "active by default; add 'Project lifecycle: complete' when finished"


def _maturity_score(repo_path: Path, readme: str, has_status_file: bool, status: str) -> float:
    if status in COMPLETE_STATUSES:
        return 1.0
    checks = (
        bool(readme.strip()),
        "quickstart" in readme.lower(),
        "research + money" in readme.lower() or "research" in readme.lower(),
        "status" in readme.lower(),
        (repo_path / "tests").exists(),
        (repo_path / ".github" / "workflows").exists(),
        (repo_path / "pyproject.toml").exists(),
        any(path.is_file() for path in repo_path.iterdir() if path.suffix == ".py") or any((repo_path / name).is_dir() for name in _package_dir_names(repo_path)),
        (repo_path / "research-notes").exists(),
        has_status_file,
    )
    return round(sum(1 for item in checks if item) / len(checks), 3)


def _package_dir_names(repo_path: Path) -> tuple[str, ...]:
    return tuple(
        item.name
        for item in repo_path.iterdir()
        if item.is_dir() and (item / "__init__.py").exists() and not item.name.startswith(".")
    )


def _weekly_repo_row(repo: RepoCandidate, state: ProjectLifecycle, week_start: date, selected: bool) -> str:
    commits = _weekly_commits(Path(repo.path), week_start)
    commit_text = "<br>".join(html_lib.escape(item) for item in commits[:5]) if commits else "No commits yet this week"
    status_class = "complete" if state.status in COMPLETE_STATUSES else "active"
    row_class = " class=\"selected\"" if selected else ""
    return (
        f"<tr{row_class}>"
        f"<td>{html_lib.escape(repo.name)}</td>"
        f"<td class=\"{status_class}\">{html_lib.escape(state.status)}</td>"
        f"<td>{state.maturity_score:.2f}</td>"
        f"<td>{commit_text}</td>"
        f"<td>{html_lib.escape(state.last_commit)}</td>"
        f"<td>{html_lib.escape(state.signal)}</td>"
        "</tr>"
    )


def _weekly_commits(repo_path: Path, week_start: date) -> tuple[str, ...]:
    since = week_start.isoformat()
    raw = _git(repo_path, "log", f"--since={since}", "--format=%h %s")
    if not raw:
        return ()
    return tuple(line for line in raw.splitlines() if line.strip())


def _should_skip_repo(name: str, marker: str) -> bool:
    return name in OTHER_ROUTINE_REPOS or name in PERSONAL_EXCLUDES or marker == CLAUDE_MARKER


def _read_readme(repo_path: Path) -> str:
    for name in ("README.md", "readme.md"):
        path = repo_path / name
        if path.exists():
            return path.read_text(encoding="utf-8", errors="replace")
    return ""


def _marker_for_readme(readme: str) -> str:
    lines = {line.strip() for line in readme.splitlines()}
    if CLAUDE_MARKER in lines:
        return CLAUDE_MARKER
    if CODEX_MARKER in lines:
        return CODEX_MARKER
    return ""


def _last_pushed_unix(path: Path) -> int:
    branch = _git(path, "branch", "--show-current")
    candidates = []
    if branch:
        candidates.append(f"origin/{branch}")
    candidates.append("HEAD")
    for ref in candidates:
        raw = _git(path, "log", "-1", "--format=%ct", ref)
        if raw and raw.isdigit():
            return int(raw)
    return 0


def _git(path: Path, *args: str) -> str:
    try:
        proc = subprocess.run(
            ["git", "-C", str(path), *args],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if proc.returncode != 0:
        return ""
    return proc.stdout.strip()


def _is_extraordinary(entry: DigestEntry) -> bool:
    text = " ".join((entry.item.title, entry.item.summary, entry.item.content)).lower()
    hits = sum(1 for term in EXTRAORDINARY_TERMS if term in text)
    return hits >= 2


def _relevant_entries(entries: list[DigestEntry], repo_name: str) -> list[DigestEntry]:
    keywords = REPO_TOPICS.get(repo_name, ())
    scored = []
    for entry in entries:
        text = " ".join((entry.item.title, entry.item.summary, entry.item.content)).lower()
        score = sum(1 for keyword in keywords if keyword in text)
        if score:
            scored.append((score, entry))
    scored.sort(key=lambda pair: (-pair[0], pair[1].item.source.lower(), pair[1].item.title.lower()))
    return [entry for _, entry in scored]


def _hot_priority_repos(candidates: tuple[RepoCandidate, ...], entries: list[DigestEntry]) -> tuple[str, ...]:
    scored: list[tuple[int, str]] = []
    for repo in candidates:
        score = 0
        for entry in _relevant_entries(entries, repo.name)[:5]:
            score += hotness_score(entry)
        if score:
            scored.append((score, repo.name))
    scored.sort(key=lambda pair: (-pair[0], pair[1]))
    return tuple(name for _, name in scored)


def _entries_for_repo_note(entries: list[DigestEntry], repo_name: str) -> list[DigestEntry]:
    relevant = _relevant_entries(entries, repo_name)
    if relevant:
        return relevant
    extraordinary = [entry for entry in entries if _is_extraordinary(entry)]
    if extraordinary:
        return extraordinary
    return entries[:3]


def _experiment_candidate(repo_name: str, entries: list[DigestEntry], extraordinary: tuple[str, ...]) -> str:
    if repo_name == "ai-factory-optical-twin":
        return "Add or recalibrate one scenario parameter in the architecture/fault matrix using the strongest current infra signal above."
    if repo_name == "tinyml-quantized-telemetry-bench":
        return "Add one benchmark slice comparing quantized telemetry inference under a new latency or memory constraint."
    if repo_name == "silicon-photonics-telemetry-monitor":
        return "Add one telemetry drift/failure-mode fixture tied to the optical or silicon-photonics signal above."
    if repo_name == "firmware-validation-agent":
        return "Add one validation requirement or simulator fault tied to agentic testing, hardware verification, or firmware reliability news."
    if extraordinary:
        return "Use the extraordinary signal above to seed a new scoped experiment or project."
    return "Keep the repo unchanged unless the next run finds a source-linked implementation opportunity."
