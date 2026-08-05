from pathlib import Path

import pytest

from optics_digest.feeds import NetworkDisabledError, collect_items, load_sources, parse_feed_document
from optics_digest.models import FeedSource


def test_load_sources_resolves_fixture_config_shape():
    sources = load_sources("configs/feeds.yaml")

    assert [source.name for source in sources] == ["Optics RSS Fixture", "Compute Atom Fixture"]


def test_parse_rss_and_atom_fixture_items():
    rss = Path("fixtures/feeds/optics_rss.xml").read_text(encoding="utf-8")
    atom = Path("fixtures/feeds/compute_atom.xml").read_text(encoding="utf-8")

    rss_items = parse_feed_document(rss, "rss fixture")
    atom_items = parse_feed_document(atom, "atom fixture")

    assert len(rss_items) == 3
    assert len(atom_items) == 3
    assert rss_items[0].published is not None
    assert atom_items[0].raw_tags == ("silicon photonics",)


def test_collect_items_is_fixture_only_by_default():
    items = collect_items("configs/feeds.yaml")

    assert len(items) == 6
    assert items[0].title == "Co-packaged optics roadmap targets 1.6T links for AI clusters"
    assert items[-1].title == "Optical switch fabric lowers tail latency in scale-out training networks"


def test_http_sources_require_network_flag(tmp_path):
    config = tmp_path / "feeds.yaml"
    config.write_text(
        "feeds:\n"
        "  - name: Remote\n"
        "    url: https://example.com/feed.xml\n",
        encoding="utf-8",
    )

    with pytest.raises(NetworkDisabledError):
        collect_items(config)


def test_read_source_type_is_explicit_for_static_checkers():
    source = FeedSource(name="local", url="../fixtures/feeds/optics_rss.xml")

    assert source.name == "local"
