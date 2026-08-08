from datetime import datetime, timezone

from optics_digest.classifier import tag_items
from optics_digest.hotness import hotness_breakdown, hotness_score, matched_hot_terms, sort_hot_entries
from optics_digest.models import FeedItem


def _item(title, summary):
    return FeedItem(
        id=title,
        title=title,
        link="https://example.com",
        source="Hugging Face Blog",
        published=datetime(2026, 8, 8, tzinfo=timezone.utc),
        summary=summary,
    )


def test_hotness_prefers_open_weight_frontier_release():
    ordinary, hot = tag_items(
        [
            _item("Maintenance update", "Minor documentation improvements."),
            _item("Open-weight frontier model release", "A benchmark-leading long context agent launch."),
        ]
    )

    assert hotness_score(hot, now=datetime(2026, 8, 8, tzinfo=timezone.utc)) > hotness_score(
        ordinary,
        now=datetime(2026, 8, 8, tzinfo=timezone.utc),
    )


def test_sort_hot_entries_orders_hot_news_first():
    entries = tag_items(
        [
            _item("Small library release", "General utility update."),
            _item("Open world model for physical AI", "A new robotics benchmark and Omniverse workflow."),
        ]
    )

    assert sort_hot_entries(entries, now=datetime(2026, 8, 8, tzinfo=timezone.utc))[0].item.title.startswith(
        "Open world"
    )


def test_hotness_breakdown_explains_matched_terms_and_source_bonus():
    (entry,) = tag_items([_item("Open-weight GPU model", "A physical AI benchmark launch for data centers.")])

    breakdown = hotness_breakdown(entry, now=datetime(2026, 8, 8, tzinfo=timezone.utc))

    assert "open-weight" in matched_hot_terms(entry)
    assert "physical ai" in breakdown["terms"]
    assert breakdown["source_bonus"] == 2
    assert breakdown["total"] == hotness_score(entry, now=datetime(2026, 8, 8, tzinfo=timezone.utc))
