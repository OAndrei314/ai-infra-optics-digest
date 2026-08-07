from datetime import date

from optics_digest.routine import (
    CLAUDE_MARKER,
    CODEX_MARKER,
    RepoCandidate,
    choose_repo,
    discover_repos,
    run_news_routine,
)


def _fake_repo(root, name, readme):
    path = root / name
    path.mkdir()
    (path / ".git").mkdir()
    (path / "README.md").write_text(readme, encoding="utf-8")
    return path


def test_discover_repos_skips_claude_and_other_routine_repos(tmp_path):
    _fake_repo(tmp_path, "ai-factory-optical-twin", f"# Twin\n\n{CODEX_MARKER}\n")
    _fake_repo(tmp_path, "fresh-codex-repo", f"# Fresh\n\n{CODEX_MARKER}\n")
    _fake_repo(tmp_path, "open-weight-eval-arena", f"# Arena\n\n{CLAUDE_MARKER}\n")
    _fake_repo(tmp_path, "fresh-claude-repo", f"# Fresh\n\n{CLAUDE_MARKER}\n")
    _fake_repo(tmp_path, "UniversityProject", "# Course work\n")

    candidates, skipped = discover_repos(tmp_path)

    assert [repo.name for repo in candidates] == ["ai-factory-optical-twin", "fresh-codex-repo"]
    assert "open-weight-eval-arena" in skipped
    assert "fresh-claude-repo" in skipped
    assert "UniversityProject" in skipped


def test_choose_repo_uses_oldest_last_pushed_timestamp():
    root = "C:/repos"
    candidates = (
        RepoCandidate("new", root, "main", "", 20, CODEX_MARKER),
        RepoCandidate("old", root, "main", "", 10, CODEX_MARKER),
    )

    assert choose_repo(candidates).name == "old"


def test_run_news_routine_writes_report_and_note_from_fixture_news(tmp_path):
    selected = _fake_repo(tmp_path, "ai-factory-optical-twin", f"# Twin\n\n{CODEX_MARKER}\n")

    result = run_news_routine(
        root=tmp_path,
        sources_path="configs/feeds.yaml",
        out_dir=tmp_path / "routine-reports",
        run_date=date(2026, 8, 7),
        allow_network=False,
        limit=6,
        write_note=True,
        metadata_out=tmp_path / "routine-reports" / "run.json",
    )

    assert result.selected_repo == "ai-factory-optical-twin"
    assert result.note_path is not None
    assert (tmp_path / "routine-reports" / "2026-08-07.md").exists()
    assert (tmp_path / "routine-reports" / "run.json").exists()
    note = (selected / "research-notes" / "2026-08-07.md").read_text(encoding="utf-8")
    assert "Relevant Signals" in note
    assert "Co-packaged optics" in note
