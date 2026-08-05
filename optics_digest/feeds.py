"""RSS/Atom loading and parsing utilities."""
from __future__ import annotations

import html
import re
import ssl
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from urllib.parse import urlparse

import yaml

try:
    import certifi
except ImportError:  # pragma: no cover - only used when optional runtime dep is absent
    certifi = None

from .models import FeedItem, FeedSource

_TAG_RE = re.compile(r"<[^>]+>")
_SPACE_RE = re.compile(r"\s+")


class NetworkDisabledError(RuntimeError):
    """Raised when a feed config asks for HTTP(S) without explicit network mode."""


def load_sources(config_path: str | Path) -> list[FeedSource]:
    config_path = Path(config_path)
    with config_path.open(encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}

    feeds = raw.get("feeds")
    if not isinstance(feeds, list):
        raise ValueError("feed config must contain a 'feeds' list")

    sources: list[FeedSource] = []
    for index, entry in enumerate(feeds, start=1):
        if not isinstance(entry, dict):
            raise ValueError(f"feed entry {index} must be a mapping")
        try:
            name = str(entry["name"])
            url = str(entry["url"])
            required = bool(entry.get("required", True))
        except KeyError as exc:
            raise ValueError(f"feed entry {index} is missing {exc.args[0]!r}") from exc
        sources.append(FeedSource(name=name, url=url, required=required))
    return sources


def collect_items(
    config_path: str | Path,
    allow_network: bool = False,
    limit: int | None = None,
) -> list[FeedItem]:
    """Load all configured feeds, parse them, deduplicate, and sort newest first."""
    config_path = Path(config_path)
    sources = load_sources(config_path)
    items: list[FeedItem] = []
    for source in sources:
        try:
            xml_text = read_source(source, base_dir=config_path.parent, allow_network=allow_network)
            items.extend(parse_feed_document(xml_text, source.name))
        except Exception:
            if source.required:
                raise

    deduped = _dedupe_items(items)
    deduped.sort(key=lambda item: (-_published_timestamp(item), item.source.lower(), item.title.lower()))
    return deduped[:limit] if limit is not None else deduped


def read_source(source: FeedSource, base_dir: Path, allow_network: bool = False) -> str:
    parsed = urlparse(source.url)
    if parsed.scheme in {"http", "https"}:
        if not allow_network:
            raise NetworkDisabledError(
                f"network access is disabled for {source.name}; pass --network to fetch {source.url}"
            )
        request = urllib.request.Request(
            source.url,
            headers={"User-Agent": "ai-infra-optics-digest/0.1"},
        )
        context = _ssl_context()
        with urllib.request.urlopen(request, timeout=15, context=context) as response:
            encoding = response.headers.get_content_charset() or "utf-8"
            return response.read().decode(encoding, errors="replace")

    path = Path(source.url)
    if not path.is_absolute():
        path = base_dir / path
    return path.read_text(encoding="utf-8")


def parse_feed_document(xml_text: str, source_name: str) -> list[FeedItem]:
    root = ET.fromstring(xml_text)
    root_name = _local_name(root.tag)
    if root_name in {"rss", "rdf"}:
        channel = _first_child(root, "channel")
        if channel is None:
            channel = root
        return [_parse_rss_item(item, source_name) for item in _children(channel, "item")]
    if root_name == "channel":
        return [_parse_rss_item(item, source_name) for item in _children(root, "item")]
    if root_name == "feed":
        return [_parse_atom_entry(entry, source_name) for entry in _children(root, "entry")]
    raise ValueError(f"unsupported feed root: {root.tag}")


def parse_date(value: str | None) -> datetime | None:
    if not value:
        return None
    raw = value.strip()
    if not raw:
        return None

    try:
        parsed = parsedate_to_datetime(raw)
        return _as_utc(parsed)
    except (TypeError, ValueError, IndexError):
        pass

    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        return _as_utc(parsed)
    except ValueError:
        return None


def clean_text(value: str | None) -> str:
    if not value:
        return ""
    text = html.unescape(value)
    text = _TAG_RE.sub(" ", text)
    return _SPACE_RE.sub(" ", text).strip()


def _parse_rss_item(item: ET.Element, source_name: str) -> FeedItem:
    title = clean_text(_first_text(item, "title"))
    link = clean_text(_first_text(item, "link"))
    summary = clean_text(_first_text(item, "description") or _first_text(item, "summary"))
    content = clean_text(_first_text(item, "encoded") or _first_text(item, "content"))
    raw_tags = tuple(clean_text(child_text) for child_text in _texts(item, "category") if clean_text(child_text))
    return FeedItem(
        id=clean_text(_first_text(item, "guid")) or link or f"{source_name}:{title}",
        title=title,
        link=link,
        source=source_name,
        published=parse_date(_first_text(item, "pubDate") or _first_text(item, "date")),
        summary=summary,
        content=content,
        raw_tags=raw_tags,
    )


def _parse_atom_entry(entry: ET.Element, source_name: str) -> FeedItem:
    title = clean_text(_first_text(entry, "title"))
    summary = clean_text(_first_text(entry, "summary"))
    content = clean_text(_first_text(entry, "content"))
    tags = []
    for category in _children(entry, "category"):
        tags.append(clean_text(category.attrib.get("term") or "".join(category.itertext())))
    raw_tags = tuple(tag for tag in tags if tag)
    return FeedItem(
        id=clean_text(_first_text(entry, "id")) or _first_link(entry) or f"{source_name}:{title}",
        title=title,
        link=_first_link(entry),
        source=source_name,
        published=parse_date(_first_text(entry, "published") or _first_text(entry, "updated")),
        summary=summary,
        content=content,
        raw_tags=raw_tags,
    )


def _local_name(tag: str) -> str:
    if "}" in tag:
        tag = tag.rsplit("}", 1)[1]
    if ":" in tag:
        tag = tag.rsplit(":", 1)[1]
    return tag.lower()


def _children(element: ET.Element, local_name: str) -> list[ET.Element]:
    return [child for child in list(element) if _local_name(child.tag) == local_name.lower()]


def _first_child(element: ET.Element, local_name: str) -> ET.Element | None:
    children = _children(element, local_name)
    return children[0] if children else None


def _first_text(element: ET.Element, local_name: str) -> str:
    child = _first_child(element, local_name)
    if child is None:
        return ""
    return "".join(child.itertext())


def _texts(element: ET.Element, local_name: str) -> list[str]:
    return ["".join(child.itertext()) for child in _children(element, local_name)]


def _first_link(entry: ET.Element) -> str:
    links = _children(entry, "link")
    for link in links:
        rel = link.attrib.get("rel", "alternate")
        href = link.attrib.get("href", "")
        if href and rel == "alternate":
            return clean_text(href)
    for link in links:
        href = link.attrib.get("href", "")
        if href:
            return clean_text(href)
    return clean_text(_first_text(entry, "link"))


def _as_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _published_timestamp(item: FeedItem) -> float:
    if item.published is None:
        return -1.0
    return item.published.timestamp()


def _ssl_context() -> ssl.SSLContext:
    if certifi is not None:
        return ssl.create_default_context(cafile=certifi.where())
    return ssl.create_default_context()


def _dedupe_items(items: list[FeedItem]) -> list[FeedItem]:
    seen: set[str] = set()
    deduped: list[FeedItem] = []
    for item in items:
        key = (item.link or item.id or item.title).strip().lower()
        if key and key not in seen:
            seen.add(key)
            deduped.append(item)
    return deduped
