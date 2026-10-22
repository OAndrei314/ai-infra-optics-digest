from pathlib import Path

import pytest

from optics_digest.publication_guard import (
    validate_public_text,
    validate_repo_public_content,
)


def test_publication_guard_flags_internal_positioning_language():
    text = "\n\n".join(
        (
            "## " + "Research" + " + " + "Money" + " Thesis",
            "## " + "Silicon Valley" + " Interview Hook",
            "Money" + " question.",
        )
    )

    violations = validate_public_text(text, "README.md")

    labels = {violation.label for violation in violations}
    assert "internal positioning heading" in labels
    assert "private interview positioning" in labels
    assert "internal market prompt" in labels


def test_publication_guard_allows_neutral_project_copy():
    text = (
        "# Capacity Planner\n\n"
        "A deterministic capacity planner for AI-cluster optical networking.\n"
        "It estimates bandwidth, transceiver count, optical power and optics spend.\n"
    )

    assert validate_public_text(text, "README.md") == ()


@pytest.mark.parametrize("text", [
    "Serving at 500K context and concurrency 512.",
    "A model with a 500 k token context window.",
    "We processed 500K telemetry samples.",
])
def test_publication_guard_allows_technical_quantities(text):
    assert validate_public_text(text) == ()


@pytest.mark.parametrize("text", [
    "Target a $500k role.",
    "Compensation target: 500 K.",
    "A 500k salary goal.",
])
def test_publication_guard_still_rejects_compensation_positioning(text):
    assert any(v.label == "compensation positioning" for v in validate_public_text(text))


def test_current_public_docs_do_not_contain_internal_positioning_language():
    repo_root = Path(__file__).resolve().parents[1]

    assert validate_repo_public_content(repo_root) == ()
