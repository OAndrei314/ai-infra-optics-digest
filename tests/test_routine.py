import random
from datetime import date
from pathlib import Path

from optics_digest.routine import (
    CLAUDE_MARKER,
    CODEX_MARKER,
    RepoCandidate,
    assess_project_lifecycle,
    choose_repo,
    choose_repos,
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


def test_choose_repos_honors_bounds_and_required_repo():
    root = "C:/repos"
    candidates = tuple(
        RepoCandidate(name, root, "main", "", index, CODEX_MARKER)
        for index, name in enumerate(
            (
                "ai-infra-optics-digest",
                "ai-factory-optical-twin",
                "tinyml-quantized-telemetry-bench",
                "silicon-photonics-telemetry-monitor",
                "firmware-validation-agent",
                "physical-ai-data-factory-sim",
                "open-model-supply-chain-radar",
                "agentic-security-canary",
                "long-context-cost-lab",
                "ai-cluster-optics-capacity-planner",
            )
        )
    )

    selected = choose_repos(candidates, min_count=6, max_count=8, rng=random.Random(7))

    assert 6 <= len(selected) <= 8
    assert "ai-infra-optics-digest" in {repo.name for repo in selected}


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


def test_run_news_routine_writes_randomized_multi_repo_notes(tmp_path):
    for name in (
        "ai-infra-optics-digest",
        "ai-factory-optical-twin",
        "tinyml-quantized-telemetry-bench",
        "silicon-photonics-telemetry-monitor",
        "firmware-validation-agent",
        "physical-ai-data-factory-sim",
        "open-model-supply-chain-radar",
        "agentic-security-canary",
        "long-context-cost-lab",
        "ai-cluster-optics-capacity-planner",
    ):
        _fake_repo(tmp_path, name, f"# {name}\n\n{CODEX_MARKER}\n")

    result = run_news_routine(
        root=tmp_path,
        sources_path="configs/feeds.yaml",
        out_dir=tmp_path / "routine-reports",
        run_date=date(2026, 8, 8),
        allow_network=False,
        limit=6,
        write_note=True,
        metadata_out=tmp_path / "routine-reports" / "run.json",
        min_repo_count=6,
        max_repo_count=8,
        selection_seed="daily-test",
        weekly_html_out=tmp_path / "weekly-rundowns",
    )

    assert 6 <= len(result.selected_repos) <= 8
    assert "ai-infra-optics-digest" in result.selected_repos
    assert len(result.note_paths) == len(result.selected_repos)
    assert result.weekly_rundown_path is not None
    assert Path(result.weekly_rundown_path).exists()
    assert "Codex Portfolio Weekly Rundown" in Path(result.weekly_rundown_path).read_text(encoding="utf-8")
    for note_path in result.note_paths:
        assert "Daily Research Note" in Path(note_path).read_text(encoding="utf-8")


def test_lifecycle_complete_marker_excludes_repo_and_signals_replacement(tmp_path):
    for name in (
        "ai-infra-optics-digest",
        "ai-factory-optical-twin",
        "tinyml-quantized-telemetry-bench",
        "silicon-photonics-telemetry-monitor",
        "firmware-validation-agent",
        "physical-ai-data-factory-sim",
    ):
        readme = f"# {name}\n\n{CODEX_MARKER}\n"
        if name == "firmware-validation-agent":
            readme += "\nProject lifecycle: complete\n"
        _fake_repo(tmp_path, name, readme)

    result = run_news_routine(
        root=tmp_path,
        sources_path="configs/feeds.yaml",
        out_dir=tmp_path / "routine-reports",
        run_date=date(2026, 8, 9),
        allow_network=False,
        limit=6,
        write_note=True,
        metadata_out=tmp_path / "routine-reports" / "run.json",
        min_repo_count=6,
        max_repo_count=8,
        selection_seed="completion-test",
        weekly_html_out=tmp_path / "weekly-rundowns",
    )

    assert "firmware-validation-agent" in result.completed_repos
    assert "firmware-validation-agent" not in result.selected_repos
    assert result.replacement_needed is True
    assert "below target minimum" in result.replacement_reason


def test_assess_project_lifecycle_reads_central_config(tmp_path):
    repo_path = _fake_repo(tmp_path, "candidate", f"# candidate\n\n{CODEX_MARKER}\n")
    config = tmp_path / "lifecycle.yaml"
    config.write_text(
        "projects:\n  candidate:\n    status: complete\n    signal: replace now\n",
        encoding="utf-8",
    )
    candidate = RepoCandidate("candidate", str(repo_path), "main", "", 0, CODEX_MARKER)

    lifecycle = assess_project_lifecycle((candidate,), lifecycle_path=config)

    assert lifecycle["candidate"].status == "complete"
    assert lifecycle["candidate"].signal == "replace now"
