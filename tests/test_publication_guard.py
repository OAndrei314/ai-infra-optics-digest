from pathlib import Path

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


def test_current_public_docs_do_not_contain_internal_positioning_language():
    repo_root = Path(__file__).resolve().parents[1]

    assert validate_repo_public_content(repo_root) == ()
