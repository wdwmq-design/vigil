"""Integration tests for FastAPI endpoints.
"""
from fastapi.testclient import TestClient
from vigil.api import app

client = TestClient(app)


def test_health_endpoint():
    res = client.get("/health")
    assert res.status_code == 200
    data = res.json()
    assert data["status"] == "online"
    assert "backend_version" in data
    assert "matlab" in data
    assert "installed" in data["matlab"]


def test_create_bundled_synthetic_job():
    res = client.post("/jobs/bundled/synthetic")
    assert res.status_code == 200
    data = res.json()
    assert "job_id" in data
    assert data["dataset_kind"] == "synthetic_bundled"
    assert data["has_truth"] is True
    assert data["frame_count"] == 4
    job_id = data["job_id"]

    # Verify retrieval
    res_get = client.get(f"/jobs/{job_id}")
    assert res_get.status_code == 200
    get_data = res_get.json()
    assert get_data["job"]["dataset_kind"] == "synthetic_bundled"
    assert get_data["status"]["state"] == "validated"


def test_run_job_without_matlab_transitions_to_awaiting():
    # Create job
    res = client.post("/jobs/bundled/synthetic")
    job_id = res.json()["job_id"]

    # Attempt to run without MATLAB
    res_run = client.post(f"/jobs/{job_id}/run")
    assert res_run.status_code == 200
    run_data = res_run.json()
    assert run_data["status"] == "awaiting_matlab"
    assert run_data["error_code"] == "E_NO_MATLAB"

    # Bundle download should work
    res_bundle = client.get(f"/jobs/{job_id}/bundle")
    assert res_bundle.status_code == 200
    assert res_bundle.headers["content-type"] == "application/zip"


def test_diff_endpoint():
    res = client.post("/jobs/bundled/synthetic")
    job_id = res.json()["job_id"]

    res_diff = client.get(f"/jobs/{job_id}/diff")
    assert res_diff.status_code == 200
    diff_data = res_diff.json()
    assert "cfg.blink" in diff_data["diff"]


def test_import_results_valid_and_invalid(tmp_path):
    import io
    import zipfile
    from vigil.config import RESULTS_DIR

    # 1. Create a job
    res = client.post("/jobs/bundled/synthetic")
    job_id = res.json()["job_id"]

    # 2. Build a valid results zip archive containing shipped results
    zip_buffer = io.BytesIO()
    with zipfile.ZipFile(zip_buffer, "w") as zf:
        zf.write(RESULTS_DIR / "detections.csv", arcname="results/detections.csv")
        zf.write(RESULTS_DIR / "detections.json", arcname="results/detections.json")
    zip_bytes = zip_buffer.getvalue()

    # Import valid archive
    files = {"file": ("matlab_results.zip", zip_bytes, "application/zip")}
    res_import = client.post(f"/jobs/{job_id}/import", files=files)
    assert res_import.status_code == 200
    import_data = res_import.json()
    assert import_data["status"] == "imported"

    # Verify job state changed to imported
    res_get = client.get(f"/jobs/{job_id}")
    assert res_get.json()["status"]["state"] == "imported"

    # Verify serving imported file
    res_csv = client.get(f"/jobs/{job_id}/results/detections.csv")
    assert res_csv.status_code == 200
    assert "frame,id,cx,cy" in res_csv.text

    # 3. Test invalid archive rejected with E_SCHEMA
    bad_zip_buffer = io.BytesIO()
    with zipfile.ZipFile(bad_zip_buffer, "w") as zf:
        zf.writestr("results/detections.csv", "bad,header\n1,2\n")
    bad_files = {"file": ("corrupt.zip", bad_zip_buffer.getvalue(), "application/zip")}
    res_bad = client.post(f"/jobs/{job_id}/import", files=bad_files)
    assert res_bad.status_code == 400
    assert res_bad.json()["error"]["code"] == "E_SCHEMA"


def test_frames_and_logs_endpoints():
    res = client.post("/jobs/bundled/synthetic")
    job_id = res.json()["job_id"]

    # 1. List frames
    res_frames = client.get(f"/jobs/{job_id}/frames")
    assert res_frames.status_code == 200
    frames = res_frames.json()["frames"]
    assert len(frames) == 4
    first_frame = frames[0]["filename"]

    # 2. Get frame content
    res_frame_file = client.get(f"/jobs/{job_id}/frames/{first_frame}")
    assert res_frame_file.status_code == 200
    assert res_frame_file.headers["content-type"] == "image/bmp"

    # 3. Check logs endpoint
    res_log = client.get(f"/jobs/{job_id}/logs/stdout")
    assert res_log.status_code == 200
    assert "log" in res_log.json()


def test_simulation_and_capabilities_endpoints():
    # 1. Simulation truth
    res_truth = client.get("/simulation/truth")
    assert res_truth.status_code == 200
    truth_data = res_truth.json()
    assert len(truth_data["records"]) == 4
    assert truth_data["parameters"]["streak_len_px"] == 14

    # 2. Simulation preview
    res_prev = client.get("/simulation/preview")
    assert res_prev.status_code == 200
    assert res_prev.headers["content-type"] == "image/png"

    # 3. Capabilities matrix
    res_caps = client.get("/capabilities")
    assert res_caps.status_code == 200
    caps = res_caps.json()["capabilities"]
    assert len(caps) >= 10
    statuses = {c["status"] for c in caps}
    assert "IMPLEMENTED" in statuses
    assert "PLANNED" in statuses


def test_demo_manifest_and_assets():
    # 1. Manifest
    res = client.get("/demo/manifest")
    assert res.status_code == 200
    data = res.json()
    assert data["available"] is True
    files = data["files"]
    assert len(files) == 3

    # Categorize
    videos = [f for f in files if f["media_type"] == "video"]
    images = [f for f in files if f["media_type"] == "image"]
    assert len(videos) == 1
    assert len(images) == 2

    # 2. Check video serving
    vid_url = videos[0]["url"]
    res_vid = client.get(vid_url)
    assert res_vid.status_code == 200
    assert "video/mp4" in res_vid.headers.get("content-type", "")

    # 3. Check image serving
    for img in images:
        res_img = client.get(img["url"])
        assert res_img.status_code == 200
        assert "image/jpeg" in res_img.headers.get("content-type", "")


def test_simulation_results_and_metadata_endpoints():
    # 1. Primary simulation results
    res_results = client.get("/simulation/results")
    assert res_results.status_code == 200
    res_data = res_results.json()
    assert res_data["metrics"]["TP"] == 3
    assert res_data["metrics"]["FP"] == 3
    assert res_data["metrics"]["FN"] == 1
    assert res_data["metrics"]["recall"] == 0.75
    assert res_data["metrics"]["precision"] == 0.5
    assert res_data["metrics"]["F1"] == 0.6
    assert len(res_data["thresholds"]) == 4
    assert res_data["detection_count"] == 50
    assert len(res_data["files"]) >= 5

    # 2. Detections JSON
    res_det = client.get("/simulation/results/detections")
    assert res_det.status_code == 200
    assert len(res_det.json()["detections"]) == 50

    # 3. File downloads from data/results/
    for filename, expected_type in [
        ("frames_montage.png", "image/png"),
        ("detection_preview.png", "image/png"),
        ("blink.gif", "image/gif"),
        ("detections.csv", "text/csv"),
    ]:
        res_f = client.get(f"/simulation/results/files/{filename}")
        assert res_f.status_code == 200
        assert expected_type in res_f.headers.get("content-type", "")

    # 4. Simulation metadata
    res_meta = client.get("/simulation/metadata")
    assert res_meta.status_code == 200
    meta = res_meta.json()
    assert meta["available"] is True
    assert meta["velocity"]["vx"] == 163.65
    assert meta["velocity"]["vy"] == -64.8
    assert len(meta["distractors"]) == 4
    assert meta["defects"]["dead_column_pixels"] == 265




