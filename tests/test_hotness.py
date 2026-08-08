from datetime import datetime, timezone

from optics_digest.classifier import tag_items
from optics_digest.hotness import hotness_score, sort_hot_entries
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
