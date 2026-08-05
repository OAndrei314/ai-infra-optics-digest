"""Deterministic extractive summarization."""
from __future__ import annotations

import re

from .models import FeedItem

_SENTENCE_RE = re.compile(r"(?<=[.!?])\s+")
_TOKEN_RE = re.compile(r"[a-z0-9][a-z0-9.+-]*")

_STOPWORDS = {
    "a",
    "an",
    "and",
    "are",
    "as",
    "at",
    "be",
    "by",
    "for",
    "from",
    "in",
    "is",
    "it",
    "of",
    "on",
    "or",
    "that",
    "the",
    "to",
    "with",
}

_DOMAIN_TERMS = {
    "accelerator",
    "asic",
    "chiplet",
    "co-packaged",
    "cooling",
    "data",
    "energy",
    "fabric",
    "gpu",
    "laser",
    "networking",
    "optical",
    "packaging",
    "photonics",
    "power",
    "semiconductor",
    "silicon",
    "switch",
    "watt",
}


def summarize_item(
    item: FeedItem,
    max_sentences: int = 2,
    max_chars: int = 420,
) -> str:
    """Select the highest-signal source sentences without randomness or LLM calls."""
    body = item.body.strip()
    if not body:
        return _truncate(item.title, max_chars)

    sentences = _split_sentences(body)
    if not sentences:
        return _truncate(body, max_chars)

    title_tokens = set(_tokens(item.title))
    corpus_tokens = [token for sentence in sentences for token in _tokens(sentence)]
    frequencies: dict[str, int] = {}
    for token in corpus_tokens:
        frequencies[token] = frequencies.get(token, 0) + 1

    scored: list[tuple[float, int, str]] = []
    for index, sentence in enumerate(sentences):
        sentence_tokens = _tokens(sentence)
        if not sentence_tokens:
            continue
        frequency_score = sum(frequencies[token] for token in sentence_tokens) / len(sentence_tokens)
        title_overlap = len(title_tokens.intersection(sentence_tokens))
        domain_hits = len(_DOMAIN_TERMS.intersection(sentence_tokens))
        score = frequency_score + (title_overlap * 1.5) + (domain_hits * 0.35)
        scored.append((score, index, sentence))

    if not scored:
        return _truncate(body, max_chars)

    scored.sort(key=lambda row: (-row[0], row[1]))
    selected = sorted(scored[:max_sentences], key=lambda row: row[1])
    summary = " ".join(sentence for _, _, sentence in selected)
    return _truncate(summary, max_chars)


def _split_sentences(text: str) -> list[str]:
    return [sentence.strip() for sentence in _SENTENCE_RE.split(text.strip()) if sentence.strip()]


def _tokens(text: str) -> list[str]:
    return [token for token in _TOKEN_RE.findall(text.lower()) if token not in _STOPWORDS]


def _truncate(text: str, max_chars: int) -> str:
    if len(text) <= max_chars:
        return text
    clipped = text[: max_chars - 3].rsplit(" ", 1)[0].rstrip(".,;:")
    return f"{clipped}..."
