from datetime import datetime, timezone

from optics_digest.classifier import classify_item, layer_label, tag_items
from optics_digest.models import FeedItem


def test_classify_item_returns_primary_and_matched_layers():
    item = FeedItem(
        id="1",
        title="Co-packaged optics target switch ASIC packages",
        link="https://example.com",
        source="fixture",
        published=datetime(2026, 8, 5, tzinfo=timezone.utc),
        summary="Silicon photonics modules move optical engines closer to switch ASICs.",
    )

    primary, matched = classify_item(item)

    assert primary == "silicon_photonics"
    assert "semiconductors_packaging" in matched
    assert layer_label(primary) == "Silicon Photonics"


def test_tag_items_adds_summaries():
    item = FeedItem(
        id="2",
        title="Sparse inference ASIC reports higher TOPS per watt",
        link="https://example.com",
        source="fixture",
        published=None,
        summary=(
            "The inference ASIC uses structured sparsity to improve throughput per watt. "
            "Operators are evaluating it for constrained data center racks."
        ),
    )

    entries = tag_items([item])

    assert entries[0].primary_layer == "ai_compute"
    assert "throughput per watt" in entries[0].summary.lower()
