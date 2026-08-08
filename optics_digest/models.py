"""Shared data models for the digest pipeline."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime


@dataclass(frozen=True)
class FeedSource:
    name: str
    url: str
    required: bool = True
    category: str = "general"
    rotation_bucket: int | None = None


@dataclass(frozen=True)
class FeedItem:
    id: str
    title: str
    link: str
    source: str
    published: datetime | None
    summary: str
    content: str = ""
    raw_tags: tuple[str, ...] = ()

    @property
    def body(self) -> str:
        return self.content or self.summary


@dataclass(frozen=True)
class DigestEntry:
    item: FeedItem
    primary_layer: str
    matched_layers: tuple[str, ...]
    summary: str
