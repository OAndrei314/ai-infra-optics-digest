"""Hot-news scoring for AI and infrastructure signals."""
from __future__ import annotations

from datetime import datetime, timezone

from .models import DigestEntry


HOT_TERMS: tuple[tuple[str, int], ...] = (
    ("open-weight", 7),
    ("open weight", 7),
    ("weights", 5),
    ("frontier", 6),
    ("release", 4),
    ("launch", 4),
    ("benchmark", 4),
    ("leaderboard", 4),
    ("record", 4),
    ("1m context", 5),
    ("1-million", 5),
    ("million-token", 5),
    ("long context", 4),
    ("agent", 3),
    ("agentic", 4),
    ("cybersecurity", 4),
    ("security breach", 6),
    ("physical ai", 6),
    ("world model", 5),
    ("open world model", 7),
    ("robotics", 3),
    ("cosmos", 4),
    ("omniverse", 4),
    ("gpu", 3),
    ("accelerator", 3),
    ("data center", 4),
    ("datacenter", 4),
    ("rack", 3),
    ("co-packaged", 5),
    ("silicon photonics", 5),
    ("optical", 3),
    ("transceiver", 3),
    ("inference", 3),
    ("cost", 3),
    ("power", 3),
)

SOURCE_BONUS = {
    "hugging face blog",
    "mistral news",
    "meta ai blog",
    "qwen blog",
    "nvidia developer blog",
    "nvidia newsroom",
    "openai news",
    "anthropic news",
}


def hotness_score(entry: DigestEntry, now: datetime | None = None) -> int:
    """Return a deterministic integer score for hot AI/infra relevance."""
    return int(hotness_breakdown(entry, now=now)["total"])


def matched_hot_terms(entry: DigestEntry) -> tuple[str, ...]:
    text = _entry_text(entry)
    return tuple(term for term, _weight in HOT_TERMS if term in text)


def hotness_breakdown(entry: DigestEntry, now: datetime | None = None) -> dict[str, object]:
    terms = matched_hot_terms(entry)
    term_score = sum(weight for term, weight in HOT_TERMS if term in terms)
    recency_score = max(0, 5 - _age_days(entry, now))
    source_bonus = 2 if entry.item.source.lower() in SOURCE_BONUS else 0
    return {
        "total": term_score + recency_score + source_bonus,
        "term_score": term_score,
        "recency_score": recency_score,
        "source_bonus": source_bonus,
        "terms": terms,
    }


def sort_hot_entries(entries: list[DigestEntry], now: datetime | None = None) -> list[DigestEntry]:
    return sorted(
        entries,
        key=lambda entry: (
            -hotness_score(entry, now=now),
            -(entry.item.published.timestamp() if entry.item.published else -1.0),
            entry.item.source.lower(),
            entry.item.title.lower(),
        ),
    )


def _age_days(entry: DigestEntry, now: datetime | None = None) -> int:
    if entry.item.published is None:
        return 99
    current = now or datetime.now(timezone.utc)
    published = entry.item.published.astimezone(timezone.utc)
    return max(0, int((current - published).total_seconds() // 86_400))


def _entry_text(entry: DigestEntry) -> str:
    return " ".join((entry.item.title, entry.item.summary, entry.item.content, " ".join(entry.item.raw_tags))).lower()
