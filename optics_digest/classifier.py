"""Deterministic layer tagging for infrastructure digest items."""
from __future__ import annotations

import re
from dataclasses import dataclass

from .models import DigestEntry, FeedItem
from .summarizer import summarize_item


@dataclass(frozen=True)
class LayerDefinition:
    key: str
    label: str
    keywords: tuple[str, ...]


LAYERS: tuple[LayerDefinition, ...] = (
    LayerDefinition(
        key="ai_compute",
        label="AI Compute",
        keywords=(
            "accelerator",
            "accelerators",
            "asic",
            "gpu",
            "inference",
            "training",
            "tops per watt",
            "near-memory",
            "throughput per watt",
            "sparse",
        ),
    ),
    LayerDefinition(
        key="semiconductors_packaging",
        label="Semiconductors and Packaging",
        keywords=(
            "semiconductor",
            "foundry",
            "chiplet",
            "chiplets",
            "interposer",
            "advanced packaging",
            "high-bandwidth memory",
            "hbm",
            "compute dies",
            "switch asic",
            "switch asics",
        ),
    ),
    LayerDefinition(
        key="silicon_photonics",
        label="Silicon Photonics",
        keywords=(
            "silicon photonics",
            "photonics",
            "co-packaged optics",
            "cpo",
            "optical engine",
            "optical engines",
            "laser",
            "laser engines",
            "picojoules per bit",
        ),
    ),
    LayerDefinition(
        key="optical_networking",
        label="Optical Networking",
        keywords=(
            "optical networking",
            "transceiver",
            "transceivers",
            "switch fabric",
            "fabric",
            "1.6t",
            "spine",
            "east-west",
            "packet scheduling",
            "tail latency",
            "links",
        ),
    ),
    LayerDefinition(
        key="data_center_energy",
        label="Data Center Energy",
        keywords=(
            "data center",
            "data centre",
            "rack",
            "racks",
            "liquid cooling",
            "cooling",
            "power",
            "power delivery",
            "pue",
            "power usage effectiveness",
            "energy",
            "thermal",
        ),
    ),
)

FALLBACK_LAYER = LayerDefinition(
    key="market_context",
    label="Market Context",
    keywords=(),
)

_TOKEN_RE = re.compile(r"[a-z0-9][a-z0-9.+-]*")


def layer_label(key: str) -> str:
    for layer in (*LAYERS, FALLBACK_LAYER):
        if layer.key == key:
            return layer.label
    return key.replace("_", " ").title()


def classify_item(item: FeedItem) -> tuple[str, tuple[str, ...]]:
    """Return primary layer and all matched layers for a feed item."""
    text = " ".join((item.title, item.summary, item.content, " ".join(item.raw_tags))).lower()
    tokens = _TOKEN_RE.findall(text)
    token_counts: dict[str, int] = {}
    for token in tokens:
        token_counts[token] = token_counts.get(token, 0) + 1

    scores: list[tuple[int, str]] = []
    for layer in LAYERS:
        score = 0
        for keyword in layer.keywords:
            keyword_l = keyword.lower()
            if " " in keyword_l or "-" in keyword_l or "." in keyword_l:
                occurrences = text.count(keyword_l)
                score += occurrences * 2
            else:
                score += token_counts.get(keyword_l, 0)
        if score:
            scores.append((score, layer.key))

    if not scores:
        return FALLBACK_LAYER.key, (FALLBACK_LAYER.key,)

    scores.sort(key=lambda pair: (-pair[0], _layer_index(pair[1])))
    matched = tuple(key for _, key in scores)
    return matched[0], matched


def tag_items(items: list[FeedItem], max_summary_sentences: int = 2) -> list[DigestEntry]:
    entries: list[DigestEntry] = []
    for item in items:
        primary_layer, matched_layers = classify_item(item)
        entries.append(
            DigestEntry(
                item=item,
                primary_layer=primary_layer,
                matched_layers=matched_layers,
                summary=summarize_item(item, max_sentences=max_summary_sentences),
            )
        )
    return entries


def layer_order() -> tuple[str, ...]:
    return tuple(layer.key for layer in LAYERS) + (FALLBACK_LAYER.key,)


def _layer_index(key: str) -> int:
    order = layer_order()
    try:
        return order.index(key)
    except ValueError:
        return len(order)
