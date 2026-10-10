"""Tests for provenance integrity hashing and config diff generation.
"""
from vigil.config import FROZEN_FILES, BASE_DIR
from vigil.provenance import get_pipeline_file_hashes
from vigil.matlab_adapter import generate_batch_config_copy


def test_frozen_pipeline_hashes_present():
    """All 12 frozen files must be present and hashed without error."""
    hashes = get_pipeline_file_hashes()
    assert len(hashes) == 12
    for name in FROZEN_FILES:
        assert name in hashes
        assert hashes[name] != "MISSING"
        assert len(hashes[name]) == 64  # SHA-256 hex string


def test_config_diff_modifies_only_blink():
    """Batch copy of debris_defaults.m must only modify cfg.blink and tc.blink."""
    mod_content, diff_text = generate_batch_config_copy()
    assert "cfg.blink        = false;" in mod_content
    assert "tc.blink        = false;" in mod_content
    assert "cfg.blink" in diff_text
    # Ensure no other algorithms or parameters were altered
    assert "kSigma" not in diff_text
    assert "gateChi2" not in diff_text
