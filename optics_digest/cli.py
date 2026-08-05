"""Command-line entry point: `python -m optics_digest.cli build ...`."""
from __future__ import annotations

import argparse
import sys
from datetime import date

from .pipeline import generate_digest


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
            )
        except Exception as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        print(f"wrote {out_path}")
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
