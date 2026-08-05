from optics_digest.models import FeedItem
from optics_digest.summarizer import summarize_item


def test_summarizer_prefers_title_overlap_and_preserves_source_sentences():
    item = FeedItem(
        id="1",
        title="Optical switch fabric lowers tail latency",
        link="https://example.com",
        source="fixture",
        published=None,
        summary=(
            "Background context describes procurement timelines. "
            "The optical switch fabric lowers tail latency for distributed training. "
            "Executives also discussed a hiring plan."
        ),
    )

    summary = summarize_item(item, max_sentences=1)

    assert summary == "The optical switch fabric lowers tail latency for distributed training."
