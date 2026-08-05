from datetime import date

from optics_digest.pipeline import generate_digest


def test_generate_digest_from_fixtures(tmp_path):
    out_path = generate_digest(
        sources_path="configs/feeds.yaml",
        out_dir=tmp_path,
        digest_date=date(2026, 8, 5),
    )

    digest = out_path.read_text(encoding="utf-8")

    assert out_path.name == "2026-08-05.md"
    assert "# AI Infra Optics Digest - 2026-08-05" in digest
    assert "Co-packaged optics roadmap targets 1.6T links for AI clusters" in digest
    assert "## Silicon Photonics" in digest
    assert "## Data Center Energy" in digest
    assert "`silicon_photonics`" in digest
