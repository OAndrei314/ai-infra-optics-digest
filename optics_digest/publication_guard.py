"""Public-content checks for generated project material."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
from collections.abc import Iterable


PUBLIC_CONTENT_GLOBS = (
    "README.md",
    "docs/**/*.md",
    "digests/**/*.md",
    "routine-reports/**/*.md",
    "research-notes/**/*.md",
)

PUBLIC_TEXT_SUFFIXES = {".html", ".json", ".md", ".txt", ".yaml", ".yml"}

PRIVATE_POSITIONING_PATTERNS = (
    ("internal positioning heading", re.compile(r"research\s*\+\s*money\s+thesis", re.IGNORECASE)),
    ("private interview positioning", re.compile(r"silicon\s+valley\s+interview\s+hook", re.IGNORECASE)),
    ("internal market prompt", re.compile(r"\bmoney\s+question\b", re.IGNORECASE)),
    ("internal market prompt", re.compile(r"\bfollow\s+the\s+money\b", re.IGNORECASE)),
    ("compensation positioning", re.compile(r"\b500\s*k\b|\bsal(?:ary)\b", re.IGNORECASE)),
    ("private-note marker", re.compile(r"\bprivate\s+notes?\b|\bmy\s+notes?\b", re.IGNORECASE)),
    ("do-not-publish marker", re.compile(r"shouldn[^\w]?t\s+be\s+read|do\s+not\s+publish", re.IGNORECASE)),
)


@dataclass(frozen=True)
class PublicContentViolation:
    path: str
    line: int
    label: str
    preview: str

    def format(self) -> str:
        return f"{self.path}:{self.line}: {self.label}: {self.preview}"


def validate_public_text(text: str, path: str = "<text>") -> tuple[PublicContentViolation, ...]:
    violations: list[PublicContentViolation] = []
    lines = text.splitlines()
    for label, pattern in PRIVATE_POSITIONING_PATTERNS:
        for match in pattern.finditer(text):
            line_number = text.count("\n", 0, match.start()) + 1
            if 1 <= line_number <= len(lines):
                preview = lines[line_number - 1].strip()
            else:
                preview = match.group(0)
            violations.append(
                PublicContentViolation(
                    path=path,
                    line=line_number,
                    label=label,
                    preview=preview[:160],
                )
            )
    return tuple(violations)


def validate_public_paths(paths: Iterable[str | Path]) -> tuple[PublicContentViolation, ...]:
    violations: list[PublicContentViolation] = []
    for raw_path in paths:
        path = Path(raw_path)
        if path.suffix.lower() not in PUBLIC_TEXT_SUFFIXES or not path.exists():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        violations.extend(validate_public_text(text, str(path)))
    return tuple(violations)


def validate_repo_public_content(root: str | Path) -> tuple[PublicContentViolation, ...]:
    root_path = Path(root)
    paths: list[Path] = []
    for pattern in PUBLIC_CONTENT_GLOBS:
        paths.extend(path for path in root_path.glob(pattern) if path.is_file())
    return validate_public_paths(paths)


def assert_public_paths_safe(paths: Iterable[str | Path]) -> None:
    violations = validate_public_paths(paths)
    if violations:
        details = "\n".join(violation.format() for violation in violations)
        raise ValueError(f"public content guard failed:\n{details}")
