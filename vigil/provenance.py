"""Provenance tracking and integrity hashing for VIGIL pipeline and input datasets.
"""
import hashlib
import json
import os
import platform
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Any, List, Optional
from vigil.config import BASE_DIR, FROZEN_FILES, CONFIG_FILE


def compute_file_sha256(file_path: Path) -> str:
    """Computes SHA-256 hash of a file on disk."""
    hasher = hashlib.sha256()
    with open(file_path, "rb") as f:
        while chunk := f.read(65536):
            hasher.update(chunk)
    return hasher.hexdigest()


def get_pipeline_file_hashes() -> Dict[str, str]:
    """Computes and returns SHA-256 hashes for all 12 frozen MATLAB pipeline files."""
    hashes: Dict[str, str] = {}
    for filename in FROZEN_FILES:
        path = BASE_DIR / filename
        if path.exists():
            hashes[filename] = compute_file_sha256(path)
        else:
            hashes[filename] = "MISSING"
    return hashes


def get_default_parameters() -> Dict[str, Any]:
    """Returns the default pipeline parameters mirroring debris_defaults.m."""
    return {
        "cfg": {
            "bgMode": "temporal",
            "smoothSigma": 1.5,
            "noiseBins": 16,
            "kSigma": 4.0,
            "otsuFloor": 2.5,
            "otsuClip": 15,
            "tMax": 8.0,
            "minArea": 5,
            "dashGap": 30,
            "minStreakLen": 10,
            "elongMin": 2.0,
            "longStreak": 100,
            "minDashes": 3,
            "dashMinLen": 25,
            "artifactZ": 40,
            "artifactMaxArea": None,  # null / Inf
            "minContrastZ": 0,
            "stationaryRadius": 10,
            "stationaryMinFrames": 3,
            "matchRadius": 12,
            "verbose": True,
            "blink": False,  # batch mode override
        },
        "tc": {
            "sigmaMeas": 2.0,
            "sigmaAcc": 0.5,
            "gateChi2": 9.21,
            "minHits": 3,
            "maxMiss": 1,
            "velMin": 3,
            "velMax": 200,
            "predictAhead": 3,
            "matchRadius": 12,
            "excludeSub": ["dashed", "stationary"],
            "blink": False,
        },
        "popts": {
            "hidden": 8,
            "epochs": 3000,
            "lr": 0.01,
            "lambdaAcc": 1,
            "accScale": 0.5,
            "sigmaMeas": 2.0,
            "nColloc": 40,
            "weightDecay": 1e-4,
            "nEnsemble": 5,
            "seed": 1,
        }
    }


def create_initial_job_record(
    job_id: str,
    dataset_kind: str,
    has_truth: bool,
    frame_files: List[Dict[str, Any]],
    parameters: Optional[Dict[str, Any]] = None
) -> Dict[str, Any]:
    """Builds initial job.json structure."""
    return {
        "schema_version": "1.0",
        "job_id": job_id,
        "dataset_kind": dataset_kind,  # "synthetic_bundled" or "user_upload"
        "has_truth": has_truth,
        "frame_files": frame_files,
        "pipeline_files": get_pipeline_file_hashes(),
        "parameters": parameters or get_default_parameters(),
        "matlab_release": "",
        "os": f"{platform.system()} {platform.release()} ({platform.machine()})",
        "started_at": None,
        "finished_at": None,
        "executed_by": None,  # "this_machine" or "imported"
        "config_diff": None,  # Line diff of debris_defaults.m
    }


def create_initial_status_record(initial_state: str = "created") -> Dict[str, Any]:
    """Builds initial status.json structure."""
    now_iso = datetime.now(timezone.utc).isoformat()
    return {
        "state": initial_state,
        "current_timestamp": now_iso,
        "history": [
            {"state": initial_state, "timestamp": now_iso}
        ],
        "error_code": None,
        "error_message": None,
        "warnings": []
    }


def update_status(
    status_data: Dict[str, Any],
    new_state: str,
    error_code: Optional[str] = None,
    error_message: Optional[str] = None,
    warnings: Optional[List[str]] = None
) -> Dict[str, Any]:
    """Updates status dict with a state change and history append."""
    now_iso = datetime.now(timezone.utc).isoformat()
    status_data["state"] = new_state
    status_data["current_timestamp"] = now_iso
    status_data["history"].append({"state": new_state, "timestamp": now_iso})
    if error_code:
        status_data["error_code"] = error_code
    if error_message:
        status_data["error_message"] = error_message
    if warnings:
        status_data.setdefault("warnings", []).extend(warnings)
    return status_data
