"""Markdown rendering for dated digests."""
from __future__ import annotations

from collections import Counter
from datetime import date
from pathlib import Path

from .classifier import layer_label, layer_order
from .hotness import hotness_breakdown, hotness_score
from .models import DigestEntry


def render_digest(entries: list[DigestEntry], digest_date: date) -> str:
    sources = sorted({entry.item.source for entry in entries})
    lines = [
        f"# AI Infra Optics Digest - {digest_date.isoformat()}",
        "",
        f"_{len(entries)} items from {len(sources)} source(s). "
        "Summaries and layer tags are deterministic._",
        "",
        "## Stack Snapshot",
        "",
        "| Layer | Items |",
        "| --- | ---: |",
    ]

    counts = Counter(entry.primary_layer for entry in entries)
    for layer in layer_order():
        count = counts.get(layer, 0)
        if count:
            lines.append(f"| {layer_label(layer)} | {count} |")

    lines.extend(["", "## Sources", ""])
    for source in sources:
        lines.append(f"- {source}")

    lines.extend(["", "## Hot AI Signals", ""])
    for entry in sorted(entries, key=lambda item: (-hotness_score(item), item.item.title.lower()))[:5]:
        published = entry.item.published.date().isoformat() if entry.item.published else "undated"
        breakdown = hotness_breakdown(entry)
        terms = ", ".join(breakdown["terms"][:4]) if breakdown["terms"] else "recency/source"
        lines.append(f"- score={breakdown['total']} | {entry.item.title} ({entry.item.source}, {published}; terms: {terms})")

    by_layer: dict[str, list[DigestEntry]] = {}
    for entry in entries:
        by_layer.setdefault(entry.primary_layer, []).append(entry)

    for layer in layer_order():
        grouped = by_layer.get(layer, [])
        if not grouped:
            continue
        lines.extend(["", f"## {layer_label(layer)}", ""])
        for entry in grouped:
            item = entry.item
            published = item.published.date().isoformat() if item.published else "undated"
            tags = ", ".join(f"`{tag}`" for tag in entry.matched_layers)
            lines.extend(
                [
                    f"### {item.title}",
                    "",
                    f"- Source: {item.source}",
                    f"- Published: {published}",
                    f"- Tags: {tags}",
                    f"- Link: {item.link or 'n/a'}",
                    "",
                    entry.summary,
                    "",
                ]
            )

    return "\n".join(lines).rstrip() + "\n"


def write_digest(entries: list[DigestEntry], out_dir: str | Path, digest_date: date) -> Path:
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{digest_date.isoformat()}.md"
    out_path.write_text(render_digest(entries, digest_date), encoding="utf-8")
    return out_path
