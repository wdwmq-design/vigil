"""Schema validation for MATLAB result files (detections, tracks, evaluation).
"""
import csv
import json
from pathlib import Path
from typing import Dict, Any, List, Optional
from vigil.config import ERR_SCHEMA

EXPECTED_DETECTIONS_CSV_COLUMNS = [
    "frame", "id", "cx", "cy", "area", "major", "minor", "length",
    "elongation", "orientation", "meanZ", "peakZ", "contrast", "peakZraw",
    "dashCount", "class", "subtype", "isCandidate", "bboxX", "bboxY", "bboxW", "bboxH"
]

EXPECTED_TRACKS_CSV_COLUMNS = [
    "track", "frame", "x", "y", "vx", "vy", "measured", "sigX", "sigY", "pinnX", "pinnY"
]

EXPECTED_EVALUATION_CSV_COLUMNS = [
    "dataset", "isNoiseSweep", "setting", "rep", "detPrecision", "detRecall",
    "trackPrecision", "frameRecall", "rmse"
]


class SchemaValidationError(Exception):
    def __init__(self, filename: str, reason: str, details: Optional[Dict[str, Any]] = None):
        self.filename = filename
        self.reason = reason
        self.details = details or {}
        self.code = ERR_SCHEMA
        super().__init__(f"[{ERR_SCHEMA}] Validation failed for '{filename}': {reason}")

    def to_dict(self) -> Dict[str, Any]:
        return {
            "code": self.code,
            "filename": self.filename,
            "reason": self.reason,
            "details": self.details
        }


def validate_detections_csv(file_path: Path) -> List[Dict[str, Any]]:
    """Validates detections.csv schema (22 expected columns)."""
    if not file_path.exists():
        raise SchemaValidationError(file_path.name, "File does not exist")

    with open(file_path, "r", encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f)
        try:
            header = next(reader)
        except StopIteration:
            raise SchemaValidationError(file_path.name, "File is completely empty")

    header_clean = [col.strip() for col in header]
    if header_clean != EXPECTED_DETECTIONS_CSV_COLUMNS:
        missing = set(EXPECTED_DETECTIONS_CSV_COLUMNS) - set(header_clean)
        extra = set(header_clean) - set(EXPECTED_DETECTIONS_CSV_COLUMNS)
        raise SchemaValidationError(
            file_path.name,
            f"CSV columns mismatch. Expected 22 columns: {EXPECTED_DETECTIONS_CSV_COLUMNS}",
            {"found": header_clean, "missing": list(missing), "extra": list(extra)}
        )

    # Read records and parse types
    records = []
    with open(file_path, "r", encoding="utf-8-sig", newline="") as f:
        dict_reader = csv.DictReader(f)
        for idx, row in enumerate(dict_reader, start=1):
            try:
                rec = {
                    "frame": int(row["frame"]),
                    "id": int(row["id"]),
                    "cx": float(row["cx"]),
                    "cy": float(row["cy"]),
                    "area": float(row["area"]),
                    "major": float(row["major"]),
                    "minor": float(row["minor"]),
                    "length": float(row["length"]),
                    "elongation": float(row["elongation"]),
                    "orientation": float(row["orientation"]),
                    "meanZ": float(row["meanZ"]),
                    "peakZ": float(row["peakZ"]),
                    "contrast": float(row["contrast"]),
                    "peakZraw": float(row["peakZraw"]),
                    "dashCount": int(float(row["dashCount"])),
                    "class": row["class"].strip(),
                    "subtype": row["subtype"].strip(),
                    "isCandidate": row["isCandidate"].strip() in ("1", "true", "True"),
                    "bboxX": float(row["bboxX"]),
                    "bboxY": float(row["bboxY"]),
                    "bboxW": float(row["bboxW"]),
                    "bboxH": float(row["bboxH"]),
                }
                records.append(rec)
            except ValueError as e:
                raise SchemaValidationError(
                    file_path.name,
                    f"Row {idx} contains invalid numeric value: {str(e)}"
                )

    return records


def validate_tracks_csv(file_path: Path) -> List[Dict[str, Any]]:
    """Validates tracks.csv schema (11 expected columns)."""
    if not file_path.exists():
        raise SchemaValidationError(file_path.name, "File does not exist")

    with open(file_path, "r", encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f)
        try:
            header = next(reader)
        except StopIteration:
            raise SchemaValidationError(file_path.name, "File is completely empty")

    header_clean = [col.strip() for col in header]
    if header_clean != EXPECTED_TRACKS_CSV_COLUMNS:
        missing = set(EXPECTED_TRACKS_CSV_COLUMNS) - set(header_clean)
        extra = set(header_clean) - set(EXPECTED_TRACKS_CSV_COLUMNS)
        raise SchemaValidationError(
            file_path.name,
            f"CSV columns mismatch. Expected 11 columns: {EXPECTED_TRACKS_CSV_COLUMNS}",
            {"found": header_clean, "missing": list(missing), "extra": list(extra)}
        )

    records = []
    with open(file_path, "r", encoding="utf-8-sig", newline="") as f:
        dict_reader = csv.DictReader(f)
        for idx, row in enumerate(dict_reader, start=1):
            try:
                rec = {
                    "track": int(row["track"]),
                    "frame": int(row["frame"]),
                    "x": float(row["x"]),
                    "y": float(row["y"]),
                    "vx": float(row["vx"]),
                    "vy": float(row["vy"]),
                    "measured": int(float(row["measured"])),
                    "sigX": float(row["sigX"]),
                    "sigY": float(row["sigY"]),
                    "pinnX": None if row["pinnX"].lower() in ("nan", "") else float(row["pinnX"]),
                    "pinnY": None if row["pinnY"].lower() in ("nan", "") else float(row["pinnY"]),
                }
                records.append(rec)
            except ValueError as e:
                raise SchemaValidationError(
                    file_path.name,
                    f"Row {idx} contains invalid numeric value: {str(e)}"
                )

    return records


def validate_detections_json(file_path: Path) -> Dict[str, Any]:
    """Validates detections.json schema."""
    if not file_path.exists():
        raise SchemaValidationError(file_path.name, "File does not exist")

    with open(file_path, "r", encoding="utf-8") as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError as e:
            raise SchemaValidationError(file_path.name, f"Invalid JSON syntax: {str(e)}")

    required_keys = {"params", "thresholds", "metrics", "detections"}
    missing = required_keys - set(data.keys())
    if missing:
        raise SchemaValidationError(
            file_path.name,
            f"Missing required top-level keys in detections.json: {list(missing)}"
        )

    return data


def validate_tracks_json(file_path: Path) -> Dict[str, Any]:
    """Validates tracks.json schema."""
    if not file_path.exists():
        raise SchemaValidationError(file_path.name, "File does not exist")

    with open(file_path, "r", encoding="utf-8") as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError as e:
            raise SchemaValidationError(file_path.name, f"Invalid JSON syntax: {str(e)}")

    required_keys = {"params", "tracks"}
    missing = required_keys - set(data.keys())
    if missing:
        raise SchemaValidationError(
            file_path.name,
            f"Missing required top-level keys in tracks.json: {list(missing)}"
        )

    return data


def validate_results_directory(results_dir: Path) -> Dict[str, Any]:
    """Validates all available result files in a directory.

    At least detections.csv or tracks.csv must exist to be a valid results directory.
    """
    if not results_dir.exists() or not results_dir.is_dir():
        raise SchemaValidationError(results_dir.name, "Directory does not exist")

    summary: Dict[str, Any] = {
        "has_detections_csv": False,
        "has_detections_json": False,
        "has_tracks_csv": False,
        "has_tracks_json": False,
        "has_detection_preview": False,
        "has_tracking_preview": False,
        "has_blink_gif": False,
        "detections_count": 0,
        "tracks_count": 0,
    }

    det_csv = results_dir / "detections.csv"
    if det_csv.exists():
        records = validate_detections_csv(det_csv)
        summary["has_detections_csv"] = True
        summary["detections_count"] = len(records)

    det_json = results_dir / "detections.json"
    if det_json.exists():
        validate_detections_json(det_json)
        summary["has_detections_json"] = True

    trk_csv = results_dir / "tracks.csv"
    if trk_csv.exists():
        tracks = validate_tracks_csv(trk_csv)
        summary["has_tracks_csv"] = True
        unique_tracks = len(set(r["track"] for r in tracks))
        summary["tracks_count"] = unique_tracks

    trk_json = results_dir / "tracks.json"
    if trk_json.exists():
        validate_tracks_json(trk_json)
        summary["has_tracks_json"] = True

    if (results_dir / "detection_preview.png").exists():
        summary["has_detection_preview"] = True
    if (results_dir / "tracking_preview.png").exists():
        summary["has_tracking_preview"] = True
    if (results_dir / "blink.gif").exists():
        summary["has_blink_gif"] = True

    if not summary["has_detections_csv"] and not summary["has_tracks_csv"]:
        raise SchemaValidationError(
            results_dir.name,
            "Results folder must contain at least detections.csv or tracks.csv"
        )

    return summary
