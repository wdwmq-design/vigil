"""VIGIL Configuration and Constant Definitions.
"""
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent
JOBS_DIR = BASE_DIR / "jobs"
DATA_DIR = BASE_DIR / "data"
RESULTS_DIR = DATA_DIR / "results"
FRAMES_DIR = DATA_DIR / "frames_bmp_debris"

# Frozen MATLAB pipeline files that are never modified by the application
FROZEN_FILES = [
    "detect_core.m",
    "track_core.m",
    "kf_predict.m",
    "pinn_trajectory.m",
    "score_detections.m",
    "score_tracks.m",
    "load_frames.m",
    "blink_frames.m",
    "add_realistic_noise.m",
    "evaluate_pipeline.m",
    "main.m",
    "track_debris.m",
]

CONFIG_FILE = "debris_defaults.m"

# Validation limits
MIN_FRAMES = 3
MAX_FRAMES = 30
WARN_FRAMES_BELOW = 5

MAX_FILE_SIZE_BYTES = 10 * 1024 * 1024    # 10 MB per frame
MAX_TOTAL_SIZE_BYTES = 100 * 1024 * 1024  # 100 MB total

# Error codes defined in VIGIL Phase 0 Contract
ERR_BAD_INPUT = "E_BAD_INPUT"
ERR_NO_MATLAB = "E_NO_MATLAB"
ERR_NO_TOOLBOX = "E_NO_TOOLBOX"
ERR_TIMEOUT = "E_TIMEOUT"
ERR_MATLAB_ERROR = "E_MATLAB_ERROR"
ERR_NO_DETECTIONS = "E_NO_DETECTIONS"
ERR_NO_TRACKS = "E_NO_TRACKS"
ERR_SCHEMA = "E_SCHEMA"
