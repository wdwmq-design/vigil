"""VIGIL FastAPI Backend and REST API Endpoints.
"""
import json
import uuid
from pathlib import Path
from typing import List, Optional

from fastapi import FastAPI, UploadFile, File, Form, HTTPException, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from vigil import __version__
from vigil.config import BASE_DIR, JOBS_DIR, DATA_DIR, FRAMES_DIR, ERR_BAD_INPUT, ERR_SCHEMA
from vigil.matlab_adapter import (
    detect_matlab_environment, prepare_job_directory,
    create_job_bundle, import_job_results, execute_matlab_job
)
from vigil.validator import validate_frame_stack, InputValidationError
from vigil.schema_validator import SchemaValidationError

app = FastAPI(
    title="VIGIL: Ground-Based Optical Detection and Tracking of Orbital Debris",
    version=__version__,
    description="Scientific API wrapping the MATLAB detection and tracking pipeline."
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def get_health():
    """Health check reporting MATLAB detection status, release, and backend version."""
    matlab_status = detect_matlab_environment()
    return {
        "status": "online",
        "backend_version": __version__,
        "matlab": matlab_status
    }


@app.get("/jobs")
def list_jobs():
    """Lists all existing jobs in the workspace."""
    JOBS_DIR.mkdir(parents=True, exist_ok=True)
    jobs = []
    for jdir in JOBS_DIR.iterdir():
        if jdir.is_dir() and (jdir / "job.json").exists() and (jdir / "status.json").exists():
            with open(jdir / "job.json", "r", encoding="utf-8") as f:
                job_data = json.load(f)
            with open(jdir / "status.json", "r", encoding="utf-8") as f:
                status_data = json.load(f)
            jobs.append({
                "job_id": jdir.name,
                "dataset_kind": job_data.get("dataset_kind"),
                "has_truth": job_data.get("has_truth"),
                "state": status_data.get("state"),
                "error_code": status_data.get("error_code"),
                "created_at": status_data.get("history", [{}])[0].get("timestamp"),
                "updated_at": status_data.get("current_timestamp"),
                "executed_by": job_data.get("executed_by")
            })

    # Sort newest first
    jobs.sort(key=lambda j: j.get("created_at") or "", reverse=True)
    return {"jobs": jobs}


@app.post("/jobs/bundled/synthetic")
def create_synthetic_bundled_job():
    """Creates a job from the shipped synthetic 4-frame dataset with ground truth."""
    if not FRAMES_DIR.exists():
        raise HTTPException(status_code=500, detail="Bundled synthetic frames directory not found")

    frame_files = sorted(list(FRAMES_DIR.glob("*.bmp")))
    if not frame_files:
        raise HTTPException(status_code=500, detail="No synthetic BMP frames found in data/frames_bmp_debris")

    file_tuples = []
    for f in frame_files:
        with open(f, "rb") as fp:
            file_tuples.append((f.name, fp.read()))

    try:
        val_result = validate_frame_stack(file_tuples)
    except InputValidationError as e:
        raise HTTPException(status_code=400, detail=e.to_dict())

    job_id = f"synth_{uuid.uuid4().hex[:8]}"
    truth_path = DATA_DIR / "debris_truth.mat"

    frame_inputs = [(vf.safe_name, vf.content) for vf in val_result.frames]
    job_dir = prepare_job_directory(
        job_id=job_id,
        dataset_kind="synthetic_bundled",
        has_truth=True,
        frames=frame_inputs,
        truth_file_path=truth_path
    )

    return {
        "job_id": job_id,
        "dataset_kind": "synthetic_bundled",
        "has_truth": True,
        "status": "validated",
        "frame_count": val_result.frame_count,
        "width": val_result.width,
        "height": val_result.height,
        "warnings": val_result.warnings
    }


@app.post("/jobs")
async def create_job_from_upload(files: List[UploadFile] = File(...)):
    """Uploads BMP frames, strictly validates them, and creates an isolated job."""
    file_tuples = []
    for f in files:
        content = await f.read()
        file_tuples.append((f.filename, content))

    try:
        val_result = validate_frame_stack(file_tuples)
    except InputValidationError as e:
        return JSONResponse(status_code=400, content={"error": e.to_dict()})

    job_id = f"job_{uuid.uuid4().hex[:8]}"
    frame_inputs = [(vf.safe_name, vf.content) for vf in val_result.frames]

    prepare_job_directory(
        job_id=job_id,
        dataset_kind="user_upload",
        has_truth=False,
        frames=frame_inputs,
        truth_file_path=None
    )

    return {
        "job_id": job_id,
        "dataset_kind": "user_upload",
        "has_truth": False,
        "status": "validated",
        "frame_count": val_result.frame_count,
        "width": val_result.width,
        "height": val_result.height,
        "warnings": val_result.warnings
    }


@app.get("/jobs/{job_id}")
def get_job(job_id: str):
    """Retrieves full status.json, job.json, and results summary for a job."""
    job_dir = JOBS_DIR / job_id
    if not job_dir.exists():
        raise HTTPException(status_code=404, detail="Job not found")

    with open(job_dir / "job.json", "r", encoding="utf-8") as f:
        job_data = json.load(f)
    with open(job_dir / "status.json", "r", encoding="utf-8") as f:
        status_data = json.load(f)

    # Check available results
    res_dir = job_dir / "data" / "results"
    results_manifest = {
        "has_detections_csv": (res_dir / "detections.csv").exists(),
        "has_detections_json": (res_dir / "detections.json").exists(),
        "has_detection_preview": (res_dir / "detection_preview.png").exists(),
        "has_blink_gif": (res_dir / "blink.gif").exists(),
        "has_frames_montage": (res_dir / "frames_montage.png").exists(),
        "has_tracks_csv": (res_dir / "tracks.csv").exists(),
        "has_tracks_json": (res_dir / "tracks.json").exists(),
        "has_tracking_preview": (res_dir / "tracking_preview.png").exists(),
        "has_evaluation_csv": (res_dir / "evaluation.csv").exists(),
    }

    # Available log files
    logs_manifest = {
        "stdout": (job_dir / "logs" / "matlab_stdout.txt").exists(),
        "stderr": (job_dir / "logs" / "matlab_stderr.txt").exists(),
    }

    return {
        "job_id": job_id,
        "job": job_data,
        "status": status_data,
        "results": results_manifest,
        "logs": logs_manifest
    }


@app.post("/jobs/{job_id}/run")
def run_job(job_id: str):
    """Executes the MATLAB pipeline or transitions to awaiting_matlab if uninstalled."""
    try:
        result = execute_matlab_job(job_id)
        return result
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="Job not found")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/jobs/{job_id}/bundle")
def get_job_bundle(job_id: str):
    """Downloads self-contained Gate A execution bundle (.zip) for a remote MATLAB machine."""
    try:
        bundle_path = create_job_bundle(job_id)
        return FileResponse(
            bundle_path,
            media_type="application/zip",
            filename=f"vigil_job_{job_id}_bundle.zip"
        )
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="Job not found")


@app.post("/jobs/{job_id}/import")
async def import_results_to_job(job_id: str, file: UploadFile = File(...)):
    """Imports an external results archive (.zip) into an existing job."""
    content = await file.read()
    try:
        summary = import_job_results(job_id, content)
        return summary
    except SchemaValidationError as e:
        return JSONResponse(status_code=400, content={"error": e.to_dict()})
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="Job not found")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/jobs/import")
async def import_results_generic(file: UploadFile = File(...), job_id: Optional[str] = Form(None)):
    """Generic import endpoint per Phase 0 contract."""
    if not job_id:
        # Create a new imported job placeholder
        job_id = f"imp_{uuid.uuid4().hex[:8]}"
        prepare_job_directory(
            job_id=job_id,
            dataset_kind="imported_external",
            has_truth=False,
            frames=[],
            truth_file_path=None
        )

    return await import_results_to_job(job_id, file)


@app.get("/jobs/{job_id}/results/{filename}")
def serve_result_file(job_id: str, filename: str):
    """Serves a MATLAB-generated result file directly and unchanged."""
    job_dir = JOBS_DIR / job_id
    target_file = job_dir / "data" / "results" / filename

    if not target_file.exists():
        raise HTTPException(status_code=404, detail=f"Result file '{filename}' does not exist for this job")

    # Handle media types
    media_types = {
        ".csv": "text/csv",
        ".json": "application/json",
        ".png": "image/png",
        ".gif": "image/gif",
        ".mat": "application/octet-stream"
    }
    ext = target_file.suffix.lower()
    media_type = media_types.get(ext, "application/octet-stream")

    return FileResponse(target_file, media_type=media_type)


@app.get("/jobs/{job_id}/frames")
def list_job_frames(job_id: str):
    """Lists all stored frame files for this observation job."""
    job_dir = JOBS_DIR / job_id
    frames_dir = job_dir / "data" / "frames_bmp_debris"
    if not frames_dir.exists():
        raise HTTPException(status_code=404, detail="Frames directory not found")

    frame_list = []
    for f in sorted(list(frames_dir.glob("*.bmp"))):
        frame_list.append({
            "filename": f.name,
            "size_bytes": f.stat().st_size,
            "url": f"/jobs/{job_id}/frames/{f.name}"
        })
    return {"frames": frame_list}


@app.get("/jobs/{job_id}/frames/{filename}")
def serve_job_frame(job_id: str, filename: str):
    """Serves an individual raw BMP observation frame."""
    job_dir = JOBS_DIR / job_id
    target_file = job_dir / "data" / "frames_bmp_debris" / filename
    if not target_file.exists():
        raise HTTPException(status_code=404, detail=f"Frame '{filename}' not found")
    return FileResponse(target_file, media_type="image/bmp")


@app.get("/jobs/{job_id}/logs/{log_name}")
def serve_job_log(job_id: str, log_name: str):
    """Serves stdout or stderr log text from execution."""
    job_dir = JOBS_DIR / job_id
    log_file = job_dir / "logs" / f"matlab_{log_name}.txt"
    if not log_file.exists():
        return {"log": "No log recorded yet."}
    with open(log_file, "r", encoding="utf-8", errors="replace") as f:
        return {"log": f.read()}


@app.post("/jobs/{job_id}/import-shipped-baseline")
def import_shipped_baseline_to_job(job_id: str):
    """Imports shipped baseline results into the bundled synthetic job."""
    job_dir = JOBS_DIR / job_id
    if not job_dir.exists():
        raise HTTPException(status_code=404, detail="Job not found")

    import io
    import zipfile
    from vigil.config import RESULTS_DIR

    if not RESULTS_DIR.exists():
        raise HTTPException(status_code=500, detail="Shipped results directory not found")

    # Create in-memory zip of shipped results
    zip_buffer = io.BytesIO()
    with zipfile.ZipFile(zip_buffer, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in RESULTS_DIR.glob("*"):
            if f.is_file():
                zf.write(f, arcname=f"results/{f.name}")
    
    zip_bytes = zip_buffer.getvalue()
    try:
        summary = import_job_results(job_id, zip_bytes)
        return summary
    except SchemaValidationError as e:
        return JSONResponse(status_code=400, content={"error": e.to_dict()})


@app.get("/simulation/truth")
def get_simulation_truth():
    """Returns the ground truth trajectory coordinates and parameters from synthetic model."""
    truth_csv = DATA_DIR / "debris_truth.csv"
    if not truth_csv.exists():
        return {"records": []}

    import csv
    records = []
    with open(truth_csv, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for r in reader:
            records.append({
                "frame": int(r["frame"]),
                "cx": float(r["cx"]),
                "cy": float(r["cy"]),
                "x1": float(r["x1"]),
                "y1": float(r["y1"]),
                "x2": float(r["x2"]),
                "y2": float(r["y2"]),
                "flux_e": float(r["flux_e"]),
            })
    return {
        "dataset": "Synthetic Baseline 4-Frame Sequence",
        "parameters": {
            "flux": 3500,
            "flicker": 0.25,
            "tumble_period_frames": 3.2,
            "streak_len_px": 14,
            "noise_ePerLevel": 4,
            "read_noise": 6,
            "sky_gradient": 0.35,
            "distractors": [
                {"frame": 2, "type": "Satellite (long streak)"},
                {"frame": 3, "type": "Aircraft (dashed pulses)"},
                {"frame": 4, "type": "Meteor (single-frame transit)"}
            ]
        },
        "records": records
    }


@app.get("/simulation/preview")
def get_simulation_preview():
    """Serves the synthetic dataset preview graphic."""
    preview_file = DATA_DIR / "debris_preview.png"
    if not preview_file.exists():
        raise HTTPException(status_code=404, detail="Preview file not found")
    return FileResponse(preview_file, media_type="image/png")


@app.get("/simulation/results")
def get_simulation_results():
    """Returns the primary simulation results from data/results/."""
    from vigil.config import RESULTS_DIR
    json_path = RESULTS_DIR / "detections.json"
    if not json_path.exists():
        raise HTTPException(status_code=404, detail="No simulation results found in data/results")

    with open(json_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    files = []
    for f in sorted(RESULTS_DIR.iterdir()):
        if f.is_file():
            files.append({
                "filename": f.name,
                "size_bytes": f.stat().st_size,
                "url": f"/simulation/results/files/{f.name}"
            })

    return {
        "params": data.get("params"),
        "thresholds": data.get("thresholds"),
        "metrics": data.get("metrics"),
        "detection_count": len(data.get("detections", [])),
        "files": files
    }


@app.get("/simulation/results/detections")
def get_simulation_detections():
    """Returns all 50 detection records directly from data/results/detections.json."""
    from vigil.config import RESULTS_DIR
    json_path = RESULTS_DIR / "detections.json"
    if not json_path.exists():
        raise HTTPException(status_code=404, detail="detections.json not found")
    with open(json_path, "r", encoding="utf-8") as f:
        return json.load(f)


@app.get("/simulation/results/files/{filename}")
def serve_simulation_result_file(filename: str):
    """Serves a genuine output file from data/results/ directly."""
    from vigil.config import RESULTS_DIR
    target = RESULTS_DIR / filename
    if not target.exists():
        raise HTTPException(status_code=404, detail=f"Result file '{filename}' not found in data/results")

    media_types = {
        ".csv": "text/csv",
        ".json": "application/json",
        ".png": "image/png",
        ".gif": "image/gif",
        ".mat": "application/octet-stream"
    }
    ext = target.suffix.lower()
    return FileResponse(target, media_type=media_types.get(ext, "application/octet-stream"))


@app.get("/simulation/metadata")
def get_simulation_metadata():
    """Extracts sensor defects, truth velocity, and distractor annotations from debris_truth.mat."""
    import scipy.io as sio
    mat_path = DATA_DIR / "debris_truth.mat"
    if not mat_path.exists():
        return {"available": False}

    try:
        mat = sio.loadmat(str(mat_path))
        vel = mat.get("vel", [[0, 0]])[0].tolist()
        extra_notes = []
        for i, n in enumerate(mat.get("extraNote", [])):
            note_str = str(n[0][0]) if len(n[0]) > 0 else "None (nominal debris)"
            extra_notes.append({"frame": i + 1, "note": note_str})

        hot_count = int(mat["hotMask"].sum()) if "hotMask" in mat else 0
        dead_count = int(mat["deadMask"].sum()) if "deadMask" in mat else 0
        stuck_count = int(mat["stuckMask"].sum()) if "stuckMask" in mat else 0
        dead_col_count = int(mat["deadColMask"].sum()) if "deadColMask" in mat else 0
        cr_counts = [int(mat["crMasks"][:, :, i].sum()) for i in range(mat["crMasks"].shape[2])] if "crMasks" in mat else []

        return {
            "available": True,
            "velocity": {"vx": round(vel[0], 2), "vy": round(vel[1], 2)},
            "distractors": extra_notes,
            "defects": {
                "hot_pixels": hot_count,
                "dead_pixels": dead_count,
                "stuck_pixels": stuck_count,
                "dead_column_pixels": dead_col_count,
                "cosmic_ray_pixels_per_frame": cr_counts
            }
        }
    except Exception as e:
        return {"available": False, "error": str(e)}


@app.get("/capabilities")
def get_capabilities():
    """Classification matrix for advanced scientific capabilities per Section 8."""
    return {
        "capabilities": [
            {
                "id": "morph_detection",
                "name": "Morphological Streak & Candidate Detection",
                "status": "IMPLEMENTED",
                "engine": "detect_core.m",
                "description": "Temporal median background subtraction, matched Gaussian filtering (sigma=1.5px), adaptive Otsu thresholding, connected components."
            },
            {
                "id": "distractor_classification",
                "name": "Distractor-Aware Morphological Classification",
                "status": "IMPLEMENTED",
                "engine": "detect_core.m",
                "description": "Morphological closing filter for aircraft dash grouping (dashGap=30px), streak length gating, stationary object tracking across frames."
            },
            {
                "id": "kalman_tracking",
                "name": "Multi-Frame Kalman Filter & Mahalanobis Gating",
                "status": "UNVERIFIED",
                "engine": "track_core.m, kf_predict.m",
                "description": "Constant-velocity kinematic tracker with Chi-square gating (9.21, 2-DOF) and dead-reckoning coasting. Awaiting Gate A execution."
            },
            {
                "id": "pinn_trajectory",
                "name": "Physics-Informed Neural Network (PINN) Trajectory",
                "status": "UNVERIFIED",
                "engine": "pinn_trajectory.m",
                "description": "Tanh neural network regularized with analytic acceleration loss along collocation points and ensemble uncertainty spread. Awaiting Gate A."
            },
            {
                "id": "subpixel_fitting",
                "name": "Subpixel Streak & Centroid Fitting",
                "status": "PARTIALLY_IMPLEMENTED",
                "engine": "detect_core.m",
                "description": "SNR-weighted centroid localization implemented; subpixel line-spread function (LSF) profile deconvolution planned."
            },
            {
                "id": "noise_sweeps",
                "name": "Sensitivity & Robustness Noise Sweeps",
                "status": "PARTIALLY_IMPLEMENTED",
                "engine": "evaluate_pipeline.m",
                "description": "Additive Gaussian noise factor sweeps (0x, 0.5x, 1x, 2x) and kSigma/smoothSigma grid evaluation implemented in script; batch web execution planned."
            },
            {
                "id": "tumble_analysis",
                "name": "Tumble & Rotational Light-Curve Analysis",
                "status": "PARTIALLY_IMPLEMENTED",
                "engine": "add_realistic_noise.m",
                "description": "Synthetic tumbling brightness modulation (flux=3500e, flicker=25%, period=3.2 frames) modeled; automated photometric light curve extraction planned."
            },
            {
                "id": "uncertainty_cones",
                "name": "Monte Carlo Trajectory Uncertainty Cones",
                "status": "PARTIALLY_IMPLEMENTED",
                "engine": "track_debris.m, pinn_trajectory.m",
                "description": "3-sigma covariance ellipses and PINN ensemble variance implemented in MATLAB; full Monte Carlo propagation cone planned."
            },
            {
                "id": "shift_and_stack",
                "name": "Shift-and-Stack Synthetic Tracking",
                "status": "PLANNED",
                "engine": "Future Module",
                "description": "Hypothesis velocity grid search and blind multi-frame co-addition for sub-threshold faint debris detection."
            },
            {
                "id": "tle_matching",
                "name": "TLE / SGP4 Catalogue Cross-Matching",
                "status": "PLANNED",
                "engine": "Future Module",
                "description": "Cross-referencing track kinematics with Space-Track / Celestrak orbital ephemerides."
            },
            {
                "id": "range_altitude",
                "name": "Range & Altitude Hypotheses",
                "status": "PLANNED",
                "engine": "Future Module",
                "description": "Triangulation and angular rate mapping to LEO / MEO / GEO orbital altitude bins."
            },
            {
                "id": "telescope_tasking",
                "name": "Follow-Up Telescope Tasking Recommendations",
                "status": "PLANNED",
                "engine": "Future Module",
                "description": "Automated pointing vector generation and intercept window prediction for secondary sensor networks."
            },
            {
                "id": "photometric_sizing",
                "name": "Photometric Radar Cross-Section / Size Estimation",
                "status": "PLANNED",
                "engine": "Future Module",
                "description": "Calibrated flux-to-cross-section albedo inversion models."
            }
        ]
    }


@app.get("/jobs/{job_id}/diff")
def get_job_diff(job_id: str):
    """Returns the line-by-line diff of debris_defaults.m for provenance and transparency."""
    diff_file = JOBS_DIR / job_id / "config_diff.txt"
    if not diff_file.exists():
        raise HTTPException(status_code=404, detail="Diff file not found")
    with open(diff_file, "r", encoding="utf-8") as f:
        return {"diff": f.read()}



# ── Demo assets manifest ────────────────────────────────────────────
DEMO_ASSETS_DIR = BASE_DIR / "assets" / "matlab-demo"


@app.get("/demo/manifest")
def get_demo_manifest():
    """Returns the list of demonstration media files with metadata."""
    if not DEMO_ASSETS_DIR.exists():
        return {"available": False, "files": []}

    files = []
    for f in sorted(DEMO_ASSETS_DIR.iterdir()):
        if not f.is_file():
            continue
        ext = f.suffix.lower()
        if ext not in (".mp4", ".webm", ".ogg", ".jpeg", ".jpg", ".png", ".bmp", ".gif"):
            continue
        media_type = "video" if ext in (".mp4", ".webm", ".ogg") else "image"
        files.append({
            "filename": f.name,
            "media_type": media_type,
            "size_bytes": f.stat().st_size,
            "url": f"/demo-assets/{f.name}"
        })
    return {"available": len(files) > 0, "files": files}


# ── Static mounts (order matters: specific paths before catch-all) ──
if DEMO_ASSETS_DIR.exists():
    app.mount("/demo-assets", StaticFiles(directory=DEMO_ASSETS_DIR), name="demo-assets")

STATIC_DIR = Path(__file__).parent / "static"
if STATIC_DIR.exists():
    app.mount("/", StaticFiles(directory=STATIC_DIR, html=True), name="static")
