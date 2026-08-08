"""Command-line entry point: `python -m optics_digest.cli build ...`."""
from __future__ import annotations

import argparse
import sys
from datetime import date

from .pipeline import generate_digest
from .routine import run_news_routine


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="optics-digest")
    sub = parser.add_subparsers(dest="command", required=True)

    build_p = sub.add_parser("build", help="build a dated markdown digest")
    build_p.add_argument("--sources", default="configs/feeds.yaml", help="feed YAML config")
    build_p.add_argument("--out", default="digests", help="output directory")
    build_p.add_argument("--date", help="digest date in YYYY-MM-DD form")
    build_p.add_argument("--limit", type=int, help="maximum number of items to include")
    build_p.add_argument(
        "--network",
        action="store_true",
        help="allow HTTP(S) feed URLs; local fixture feeds work without this",
    )
    build_p.add_argument(
        "--rotate-sources",
        action="store_true",
        help="use the digest date to rotate optional live source buckets",
    )

    routine_p = sub.add_parser("routine", help="run the Codex daily news-aware repo routine")
    routine_p.add_argument("--root", required=True, help="workspace root containing repo directories")
    routine_p.add_argument("--sources", default="configs/live_feeds.yaml", help="feed YAML config")
    routine_p.add_argument("--out", default="routine-reports", help="routine report output directory")
    routine_p.add_argument("--date", help="routine date in YYYY-MM-DD form")
    routine_p.add_argument("--limit", type=int, default=16, help="maximum news items to inspect")
    routine_p.add_argument("--min-repos", type=int, default=6, help="minimum daily active project repos to touch")
    routine_p.add_argument("--max-repos", type=int, default=8, help="maximum daily active project repos to touch")
    routine_p.add_argument("--lifecycle", default="configs/project_lifecycle.yaml", help="project lifecycle YAML config")
    routine_p.add_argument("--weekly-html-out", default="weekly-rundowns", help="directory for weekly local HTML rundowns")
    routine_p.add_argument("--metadata-out", help="optional JSON metadata path")
    routine_p.add_argument("--write-note", action="store_true", help="write dated notes to the selected repos")
    routine_p.add_argument("--network", action="store_true", help="allow HTTP(S) news sources")

    args = parser.parse_args(argv)

    if args.command == "build":
        try:
            digest_date = date.fromisoformat(args.date) if args.date else date.today()
            out_path = generate_digest(
                sources_path=args.sources,
                out_dir=args.out,
                digest_date=digest_date,
                allow_network=args.network,
                limit=args.limit,
                rotate_sources=args.rotate_sources,
            )
        except Exception as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        print(f"wrote {out_path}")
        return 0

    if args.command == "routine":
        try:
            run_date = date.fromisoformat(args.date) if args.date else date.today()
            result = run_news_routine(
                root=args.root,
                sources_path=args.sources,
                out_dir=args.out,
                run_date=run_date,
                allow_network=args.network,
                limit=args.limit,
                write_note=args.write_note,
                metadata_out=args.metadata_out,
                min_repo_count=args.min_repos,
                max_repo_count=args.max_repos,
                lifecycle_path=args.lifecycle,
                weekly_html_out=args.weekly_html_out,
            )
        except Exception as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        print(f"selected repos: {', '.join(result.selected_repos)}")
        print(f"action: {result.action}")
        print(f"report: {result.report_path}")
        for note_path in result.note_paths:
            print(f"note: {note_path}")
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
