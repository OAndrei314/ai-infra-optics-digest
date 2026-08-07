"""News-aware multi-repo routine for the Codex-owned portfolio slice.

This module is deliberately conservative. It does not invent code changes. It reads live
news/digest items, selects the least-recent Codex-owned repo, and writes an auditable
research note only when there is relevant source-linked material to justify a commit.
"""
from __future__ import annotations

import json
import re
import subprocess
from dataclasses import asdict, dataclass
from datetime import date
from pathlib import Path

import yaml

from .classifier import tag_items
from .feeds import collect_items, select_sources_for_date, source_rotation_period
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


@dataclass(frozen=True)
class RepoCandidate:
    name: str
    path: str
    branch: str
    remote: str
    last_pushed_unix: int
    marker: str


@dataclass(frozen=True)
class RoutineRun:
    run_date: str
    selected_repo: str
    selected_repo_path: str
    report_path: str
    note_path: str | None
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
    entries = tag_items(items)
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
) -> RoutineRun:
    candidates, skipped = discover_repos(root)
    selected = choose_repo(candidates)
    entries, sources_checked = scan_news(sources_path, run_date, allow_network, limit)
    relevant = _relevant_entries(entries, selected.name)
    extraordinary = tuple(entry.item.title for entry in entries if _is_extraordinary(entry))

    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    report_path = out_dir / f"{run_date.isoformat()}.md"
    note_path: Path | None = None
    action = "logged_news_scan"
    if write_note and relevant:
        note_dir = Path(selected.path) / "research-notes"
        note_dir.mkdir(parents=True, exist_ok=True)
        note_path = note_dir / f"{run_date.isoformat()}.md"
        note_path.write_text(render_repo_note(selected, run_date, relevant, extraordinary), encoding="utf-8")
        action = "wrote_repo_research_note"

    report_path.write_text(
        render_routine_report(
            run_date=run_date,
            selected=selected,
            candidates=candidates,
            skipped=skipped,
            entries=entries,
            relevant=relevant,
            extraordinary=extraordinary,
            sources_checked=sources_checked,
            note_path=note_path,
        ),
        encoding="utf-8",
    )

    result = RoutineRun(
        run_date=run_date.isoformat(),
        selected_repo=selected.name,
        selected_repo_path=selected.path,
        report_path=str(report_path),
        note_path=str(note_path) if note_path else None,
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
    selected: RepoCandidate,
    candidates: tuple[RepoCandidate, ...],
    skipped: tuple[str, ...],
    entries: list[DigestEntry],
    relevant: list[DigestEntry],
    extraordinary: tuple[str, ...],
    sources_checked: tuple[str, ...],
    note_path: Path | None,
) -> str:
    lines = [
        f"# Codex Daily News Routine - {run_date.isoformat()}",
        "",
        f"- Selected repo: `{selected.name}`",
        f"- Action: {'wrote research note' if note_path else 'news scan only'}",
        f"- Note path: `{note_path}`" if note_path else "- Note path: n/a",
        f"- Candidate repos: {len(candidates)}",
        f"- Skipped repos: {len(skipped)}",
        "",
        "## Sources Checked",
        "",
    ]
    lines.extend(f"- {source}" for source in sources_checked)
    lines.extend(["", "## Repo Rotation", "", "| repo | branch | last pushed unix | marker |", "| --- | --- | ---: | --- |"])
    for repo in sorted(candidates, key=lambda item: (item.last_pushed_unix, item.name)):
        lines.append(f"| {repo.name} | {repo.branch} | {repo.last_pushed_unix} | {repo.marker} |")
    if skipped:
        lines.extend(["", "## Skipped Repos", ""])
        lines.extend(f"- {name}" for name in skipped)
    lines.extend(["", "## Extraordinary Signals", ""])
    if extraordinary:
        lines.extend(f"- {title}" for title in extraordinary[:8])
    else:
        lines.append("- None crossed the deterministic keyword threshold.")
    lines.extend(["", "## Relevant Items For Selected Repo", ""])
    if relevant:
        for entry in relevant[:8]:
            lines.append(f"- {entry.item.title} ({entry.item.source})")
    else:
        lines.append("- No high-relevance item found; no repo note was written.")
    if run_date >= date(2027, 8, 1):
        lines.extend(["", "## Human Review Flag", "", "Routine is within one week of the planned one-year review window."])
    return "\n".join(lines) + "\n"


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


def _should_skip_repo(name: str, marker: str) -> bool:
    return name in OTHER_ROUTINE_REPOS or name in PERSONAL_EXCLUDES or marker == CLAUDE_MARKER


def _read_readme(repo_path: Path) -> str:
    for name in ("README.md", "readme.md"):
        path = repo_path / name
        if path.exists():
            return path.read_text(encoding="utf-8", errors="replace")
    return ""


def _marker_for_readme(readme: str) -> str:
    if CLAUDE_MARKER in readme:
        return CLAUDE_MARKER
    if CODEX_MARKER in readme:
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
