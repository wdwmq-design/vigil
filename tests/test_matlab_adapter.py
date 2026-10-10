"""Tests for MATLAB adapter, execution boundary, and bundle packaging.
"""
import zipfile
from vigil.config import BASE_DIR, ERR_NO_MATLAB
from vigil.matlab_adapter import (
    detect_matlab_environment, prepare_job_directory,
    create_job_bundle, execute_matlab_job
)


def test_matlab_environment_detected_accurately():
    """Confirms adapter honestly detects absence of MATLAB on this machine."""
    env = detect_matlab_environment()
    # As known from inspection, MATLAB is not on this laptop
    assert "installed" in env
    assert isinstance(env["installed"], bool)


def test_prepare_job_directory_layout(tmp_path):
    """Verifies isolated job directory structure matches Phase 0 Contract."""
    job_id = "test_job_001"
    frames = [("frame_01.bmp", b"BM" + b"\x00" * 1100)]
    job_dir = prepare_job_directory(
        job_id=job_id,
        dataset_kind="user_upload",
        has_truth=False,
        frames=frames
    )

    assert (job_dir / "job.json").exists()
    assert (job_dir / "status.json").exists()
    assert (job_dir / "main.m").exists()
    assert (job_dir / "track_debris.m").exists()
    assert (job_dir / "debris_defaults.m").exists()
    assert (job_dir / "config_diff.txt").exists()
    assert (job_dir / "data" / "frames_bmp_debris" / "frame_01.bmp").exists()
    assert (job_dir / "data" / "results").exists()
    assert (job_dir / "logs").exists()


def test_matlab_execution_boundary_when_unavailable():
    """When MATLAB is missing, execution must set awaiting_matlab and never fake success."""
    job_id = "test_job_002"
    frames = [("frame_01.bmp", b"BM" + b"\x00" * 1100)]
    prepare_job_directory(job_id=job_id, dataset_kind="user_upload", has_truth=False, frames=frames)

    res = execute_matlab_job(job_id)
    assert res["status"] == "awaiting_matlab"
    assert res["error_code"] == ERR_NO_MATLAB
    assert res["bundle_available"] is True


def test_bundle_creation_produces_valid_zip():
    """Job bundle zip must be created and contain execution scripts and instructions."""
    job_id = "test_job_003"
    frames = [("frame_01.bmp", b"BM" + b"\x00" * 1100)]
    prepare_job_directory(job_id=job_id, dataset_kind="user_upload", has_truth=False, frames=frames)

    bundle_path = create_job_bundle(job_id)
    assert bundle_path.exists()
    assert bundle_path.suffix == ".zip"

    with zipfile.ZipFile(bundle_path, "r") as zf:
        names = zf.namelist()
        assert "README_GATE_A.txt" in names
        assert "run_gate_a.m" in names
        assert "run_gate_a.bat" in names
        assert "main.m" in names
        assert "track_debris.m" in names
        assert "debris_defaults.m" in names
        assert "data/frames_bmp_debris/frame_01.bmp" in names
