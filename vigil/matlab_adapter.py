"""MATLAB execution boundary, environment detector, and job bundle exporter/importer.
"""
import difflib
import glob
import json
import os
import shutil
import subprocess
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Any, Optional, Tuple, List

from vigil.config import (
    BASE_DIR, JOBS_DIR, DATA_DIR, RESULTS_DIR, FROZEN_FILES, CONFIG_FILE,
    ERR_NO_MATLAB, ERR_NO_TOOLBOX, ERR_TIMEOUT, ERR_MATLAB_ERROR,
    ERR_NO_DETECTIONS, ERR_NO_TRACKS, ERR_SCHEMA
)
from vigil.provenance import (
    create_initial_job_record, create_initial_status_record,
    update_status, compute_file_sha256
)
from vigil.schema_validator import validate_results_directory, SchemaValidationError


def detect_matlab_environment() -> Dict[str, Any]:
    """Detects whether MATLAB executable is available on this system.

    Never assumes MATLAB is installed.
    """
    matlab_path = shutil.which("matlab")

    # If not on PATH, search common Windows install locations
    if not matlab_path and os.name == "nt":
        candidates = glob.glob(r"C:\Program Files\MATLAB\R*\bin\matlab.exe")
        if candidates:
            matlab_path = candidates[-1]  # Pick latest candidate if exists

    if not matlab_path:
        return {
            "installed": False,
            "executable_path": None,
            "release": None,
            "message": "MATLAB executable not found on this machine. Execution path is explicit and awaiting Gate A verification."
        }

    # If found, check version safely
    release = "Unknown"
    try:
        proc = subprocess.run(
            [matlab_path, "-batch", "disp(version); exit;"],
            capture_output=True,
            text=True,
            timeout=15
        )
        if proc.returncode == 0:
            release = proc.stdout.strip().splitlines()[-1] if proc.stdout else "Detected"
    except Exception:
        pass

    return {
        "installed": True,
        "executable_path": str(matlab_path),
        "release": release,
        "message": f"MATLAB detected at {matlab_path}"
    }


def generate_batch_config_copy() -> Tuple[str, str]:
    """Generates the content for a job-specific copy of debris_defaults.m where
    only cfg.blink and tc.blink are set to false (preventing interactive GUI hangs),
    and computes the line-by-line diff against the original.
    """
    orig_path = BASE_DIR / CONFIG_FILE
    if not orig_path.exists():
        raise FileNotFoundError(f"Original {CONFIG_FILE} not found at {orig_path}")

    with open(orig_path, "r", encoding="utf-8") as f:
        orig_lines = f.readlines()

    mod_lines = []
    for line in orig_lines:
        if "cfg.blink" in line and "=" in line and not line.strip().startswith("%"):
            # Change cfg.blink = true to cfg.blink = false
            mod_lines.append("cfg.blink        = false;      % set to false for headless batch run\n")
        elif "tc.blink" in line and "=" in line and not line.strip().startswith("%"):
            mod_lines.append("tc.blink        = false;      % set to false for headless batch run\n")
        else:
            mod_lines.append(line)

    mod_content = "".join(mod_lines)

    diff = difflib.unified_diff(
        orig_lines,
        mod_lines,
        fromfile=f"original/{CONFIG_FILE}",
        tofile=f"batch_job/{CONFIG_FILE}",
        lineterm=""
    )
    diff_text = "\n".join(diff)
    return mod_content, diff_text


def prepare_job_directory(
    job_id: str,
    dataset_kind: str,
    has_truth: bool,
    frames: List[Tuple[str, bytes]],
    truth_file_path: Optional[Path] = None
) -> Path:
    """Creates the isolated job directory structure matching Phase 0 Contract."""
    job_dir = JOBS_DIR / job_id
    frames_dir = job_dir / "data" / "frames_bmp_debris"
    results_dir = job_dir / "data" / "results"
    logs_dir = job_dir / "logs"

    frames_dir.mkdir(parents=True, exist_ok=True)
    results_dir.mkdir(parents=True, exist_ok=True)
    logs_dir.mkdir(parents=True, exist_ok=True)

    # 1. Write frames
    frame_files_meta = []
    import hashlib
    for idx, (safe_name, content) in enumerate(frames, start=1):
        target = frames_dir / safe_name
        with open(target, "wb") as f:
            f.write(content)
        sha256 = hashlib.sha256(content).hexdigest()
        frame_files_meta.append({
            "index": idx,
            "filename": safe_name,
            "sha256": sha256,
            "size_bytes": len(content)
        })

    # 2. Copy ground truth if present
    if has_truth and truth_file_path and truth_file_path.exists():
        shutil.copy2(truth_file_path, job_dir / "data" / "debris_truth.mat")
        # Also copy csv if exists
        csv_truth = truth_file_path.parent / "debris_truth.csv"
        if csv_truth.exists():
            shutil.copy2(csv_truth, job_dir / "data" / "debris_truth.csv")

    # 2b. Copy shipped simulation outputs for bundled synthetic dataset
    if dataset_kind == "synthetic_bundled" and RESULTS_DIR.exists():
        for res_file in RESULTS_DIR.iterdir():
            if res_file.is_file():
                shutil.copy2(res_file, results_dir / res_file.name)

    # 3. Copy driver scripts (byte-identical)
    for driver in ["main.m", "track_debris.m"]:
        shutil.copy2(BASE_DIR / driver, job_dir / driver)

    # 4. Generate modified config with diff
    config_content, diff_text = generate_batch_config_copy()
    with open(job_dir / CONFIG_FILE, "w", encoding="utf-8") as f:
        f.write(config_content)
    with open(job_dir / "config_diff.txt", "w", encoding="utf-8") as f:
        f.write(diff_text)

    # 5. Create run helper script for external MATLAB machines (Gate A execution)
    run_bat = job_dir / "run_gate_a.bat"
    with open(run_bat, "w", encoding="utf-8") as f:
        f.write(
            "@echo off\n"
            "REM VIGIL Gate A External MATLAB Execution Script\n"
            "echo Running VIGIL Stage 3 (Detection)...\n"
            'matlab -batch "addpath(\'%~dp0\'); cd(\'%~dp0\'); main; exit;" > logs\\matlab_stdout.txt 2> logs\\matlab_stderr.txt\n'
            "echo Running VIGIL Stage 4 (Tracking)...\n"
            'matlab -batch "addpath(\'%~dp0\'); cd(\'%~dp0\'); track_debris; exit;" >> logs\\matlab_stdout.txt 2>> logs\\matlab_stderr.txt\n'
            "echo Completed. Results are in data\\results\\\n"
        )

    run_m = job_dir / "run_gate_a.m"
    with open(run_m, "w", encoding="utf-8") as f:
        f.write(
            "% VIGIL Gate A External MATLAB Execution Script\n"
            "here = fileparts(mfilename('fullpath'));\n"
            "addpath(here);\n"
            "cd(here);\n"
            "fprintf('Starting main.m (Stage 3 Detection)...\\n');\n"
            "main;\n"
            "fprintf('Starting track_debris.m (Stage 4 Tracking)...\\n');\n"
            "track_debris;\n"
            "fprintf('Pipeline execution finished successfully.\\n');\n"
        )

    # 6. Initialize job.json and status.json
    job_record = create_initial_job_record(
        job_id=job_id,
        dataset_kind=dataset_kind,
        has_truth=has_truth,
        frame_files=frame_files_meta
    )
    job_record["config_diff"] = diff_text
    with open(job_dir / "job.json", "w", encoding="utf-8") as f:
        json.dump(job_record, f, indent=2)

    status_record = create_initial_status_record("validated")
    with open(job_dir / "status.json", "w", encoding="utf-8") as f:
        json.dump(status_record, f, indent=2)

    return job_dir


def create_job_bundle(job_id: str) -> Path:
    """Creates a downloadable .zip package for execution on an external MATLAB laptop."""
    job_dir = JOBS_DIR / job_id
    if not job_dir.exists():
        raise FileNotFoundError(f"Job {job_id} not found")

    bundle_path = job_dir / f"vigil_job_{job_id}_bundle.zip"

    with zipfile.ZipFile(bundle_path, "w", zipfile.ZIP_DEFLATED) as zf:
        # Include all algorithm files needed for self-contained execution
        for m_file in FROZEN_FILES:
            src = BASE_DIR / m_file
            if src.exists():
                # For main.m and track_debris.m, use the job copy or base
                zf.write(src, arcname=m_file)

        # Include the modified config
        zf.write(job_dir / CONFIG_FILE, arcname=CONFIG_FILE)
        zf.write(job_dir / "config_diff.txt", arcname="config_diff.txt")
        zf.write(job_dir / "run_gate_a.bat", arcname="run_gate_a.bat")
        zf.write(job_dir / "run_gate_a.m", arcname="run_gate_a.m")
        zf.write(job_dir / "job.json", arcname="job.json")

        # Include data/frames_bmp_debris/
        frames_dir = job_dir / "data" / "frames_bmp_debris"
        for frame in frames_dir.glob("*.bmp"):
            zf.write(frame, arcname=f"data/frames_bmp_debris/{frame.name}")

        # Include truth if present
        truth_mat = job_dir / "data" / "debris_truth.mat"
        if truth_mat.exists():
            zf.write(truth_mat, arcname="data/debris_truth.mat")
        truth_csv = job_dir / "data" / "debris_truth.csv"
        if truth_csv.exists():
            zf.write(truth_csv, arcname="data/debris_truth.csv")

        # Include README with Gate A instructions
        readme = (
            "VIGIL Phase 0: Gate A Execution Instructions\n"
            "============================================\n\n"
            "1. Extract this entire zip into a folder on your MATLAB machine.\n"
            "2. Open MATLAB and navigate to the extracted folder.\n"
            "3. Run `run_gate_a` in the MATLAB Command Window (or execute run_gate_a.bat).\n"
            "4. Verify that the files in data/results/ are created:\n"
            "   - detections.csv, detections.json, detections.mat\n"
            "   - tracks.csv, tracks.json, tracks.mat\n"
            "   - detection_preview.png, tracking_preview.png\n"
            "5. Zip the resulting 'data/results' folder (and optionally logs/) and upload it back\n"
            "   to the VIGIL web interface using 'Import MATLAB Results'.\n"
        )
        zf.writestr("README_GATE_A.txt", readme)

    return bundle_path


def import_job_results(job_id: str, results_archive_bytes: bytes) -> Dict[str, Any]:
    """Imports results from an external MATLAB machine, validates schema, and updates job."""
    import tempfile
    job_dir = JOBS_DIR / job_id
    if not job_dir.exists():
        raise FileNotFoundError(f"Job {job_id} not found")

    job_results_dir = job_dir / "data" / "results"
    job_results_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp_path = Path(tmpdir)
        zip_file = tmp_path / "import.zip"
        with open(zip_file, "wb") as f:
            f.write(results_archive_bytes)

        with zipfile.ZipFile(zip_file, "r") as zf:
            zf.extractall(tmp_path / "extracted")

        extracted_root = tmp_path / "extracted"

        # Locate where the result files are (could be in root or in results/ or data/results/)
        cand_dirs = [
            extracted_root,
            extracted_root / "results",
            extracted_root / "data" / "results"
        ]
        results_source = None
        for cd in cand_dirs:
            if (cd / "detections.csv").exists() or (cd / "tracks.csv").exists():
                results_source = cd
                break

        if not results_source:
            # Check any subfolder
            for sub in extracted_root.glob("**/detections.csv"):
                results_source = sub.parent
                break

        if not results_source:
            raise SchemaValidationError(
                "import_archive",
                "Archive does not contain detections.csv or tracks.csv"
            )

        # Validate schema before copying!
        summary = validate_results_directory(results_source)

        # Copy all result files into job results dir
        for item in results_source.iterdir():
            if item.is_file():
                shutil.copy2(item, job_results_dir / item.name)

        # If logs exist in extraction, copy to job logs
        logs_src = None
        for ld in [extracted_root / "logs", extracted_root / "data" / "logs"]:
            if ld.exists():
                logs_src = ld
                break
        if logs_src:
            for log_file in logs_src.glob("*.txt"):
                shutil.copy2(log_file, job_dir / "logs" / log_file.name)

    # Update job.json and status.json
    status_file = job_dir / "status.json"
    with open(status_file, "r", encoding="utf-8") as f:
        status_data = json.load(f)

    status_data = update_status(status_data, "imported")
    with open(status_file, "w", encoding="utf-8") as f:
        json.dump(status_data, f, indent=2)

    job_file = job_dir / "job.json"
    with open(job_file, "r", encoding="utf-8") as f:
        job_data = json.load(f)

    job_data["finished_at"] = datetime.now(timezone.utc).isoformat()
    job_data["executed_by"] = "imported"
    with open(job_file, "w", encoding="utf-8") as f:
        json.dump(job_data, f, indent=2)

    return {
        "status": "imported",
        "validation_summary": summary,
        "message": "Results imported successfully after passing all schema checks."
    }


def execute_matlab_job(job_id: str) -> Dict[str, Any]:
    """Attempts to run the MATLAB pipeline for a given job.

    If MATLAB is not installed, marks job 'awaiting_matlab' and returns.
    Never fabricates success or data.
    """
    job_dir = JOBS_DIR / job_id
    if not job_dir.exists():
        raise FileNotFoundError(f"Job {job_id} not found")

    status_file = job_dir / "status.json"
    with open(status_file, "r", encoding="utf-8") as f:
        status_data = json.load(f)

    job_file = job_dir / "job.json"
    with open(job_file, "r", encoding="utf-8") as f:
        job_data = json.load(f)

    matlab_env = detect_matlab_environment()

    if not matlab_env["installed"]:
        # Update status to awaiting_matlab
        status_data = update_status(
            status_data,
            "awaiting_matlab",
            error_code=ERR_NO_MATLAB,
            error_message="MATLAB executable not found on this machine. Download the job bundle to run on a machine with MATLAB (Gate A)."
        )
        with open(status_file, "w", encoding="utf-8") as f:
            json.dump(status_data, f, indent=2)

        return {
            "status": "awaiting_matlab",
            "error_code": ERR_NO_MATLAB,
            "message": "MATLAB not found. Job is awaiting external MATLAB execution. Please download the bundle.",
            "bundle_available": True
        }

    # If MATLAB is installed, run it
    matlab_exe = matlab_env["executable_path"]
    now_iso = datetime.now(timezone.utc).isoformat()
    job_data["started_at"] = now_iso
    job_data["matlab_release"] = matlab_env["release"] or "Detected"

    status_data = update_status(status_data, "running")
    with open(status_file, "w", encoding="utf-8") as f:
        json.dump(status_data, f, indent=2)

    logs_dir = job_dir / "logs"
    stdout_file = logs_dir / "matlab_stdout.txt"
    stderr_file = logs_dir / "matlab_stderr.txt"

    # Run main.m then track_debris.m
    cmd = [
        matlab_exe,
        "-batch",
        f"addpath('{BASE_DIR}'); cd('{job_dir}'); main; track_debris; exit;"
    ]

    try:
        proc = subprocess.run(
            cmd,
            cwd=job_dir,
            capture_output=True,
            text=True,
            timeout=300  # 5 minutes
        )
        with open(stdout_file, "w", encoding="utf-8") as f:
            f.write(proc.stdout)
        with open(stderr_file, "w", encoding="utf-8") as f:
            f.write(proc.stderr)

        all_output = proc.stdout + "\n" + proc.stderr

        # Check for empty conditions per contract Page 8
        if "Nothing detected" in all_output:
            status_data = update_status(status_data, "completed_empty", error_code=ERR_NO_DETECTIONS,
                                        error_message="Detection found nothing (valid empty outcome)")
            job_data["finished_at"] = datetime.now(timezone.utc).isoformat()
            job_data["executed_by"] = "this_machine"
        elif "No tracks" in all_output:
            status_data = update_status(status_data, "completed_empty", error_code=ERR_NO_TRACKS,
                                        error_message="No tracks confirmed (valid empty outcome)")
            job_data["finished_at"] = datetime.now(timezone.utc).isoformat()
            job_data["executed_by"] = "this_machine"
        elif proc.returncode != 0:
            err_code = ERR_NO_TOOLBOX if "Image Processing Toolbox" in all_output else ERR_MATLAB_ERROR
            status_data = update_status(status_data, "failed", error_code=err_code,
                                        error_message=f"MATLAB exited with error: {proc.stderr[:200]}")
        else:
            # Check results schema
            try:
                validate_results_directory(job_dir / "data" / "results")
                status_data = update_status(status_data, "completed")
                job_data["finished_at"] = datetime.now(timezone.utc).isoformat()
                job_data["executed_by"] = "this_machine"
            except SchemaValidationError as se:
                status_data = update_status(status_data, "failed", error_code=ERR_SCHEMA,
                                            error_message=f"Output validation failed: {str(se)}")

    except subprocess.TimeoutExpired:
        status_data = update_status(status_data, "failed", error_code=ERR_TIMEOUT,
                                    error_message="MATLAB execution exceeded timeout of 300 seconds")

    with open(status_file, "w", encoding="utf-8") as f:
        json.dump(status_data, f, indent=2)
    with open(job_file, "w", encoding="utf-8") as f:
        json.dump(job_data, f, indent=2)

    return {
        "status": status_data["state"],
        "error_code": status_data.get("error_code"),
        "error_message": status_data.get("error_message")
    }
