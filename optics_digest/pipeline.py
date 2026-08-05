"""Top-level digest generation pipeline."""
from __future__ import annotations

from datetime import date
from pathlib import Path

from .classifier import tag_items
from .feeds import collect_items
from .renderer import write_digest


def generate_digest(
    sources_path: str | Path,
    out_dir: str | Path,
    digest_date: date,
    allow_network: bool = False,
    limit: int | None = None,
) -> Path:
    items = collect_items(sources_path, allow_network=allow_network, limit=limit)
    if not items:
        raise ValueError("no feed items found")
    entries = tag_items(items)
    return write_digest(entries, out_dir=out_dir, digest_date=digest_date)
