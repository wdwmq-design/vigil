"""Tests for result file schema validator.
"""
import pytest
from pathlib import Path
from vigil.config import RESULTS_DIR
from vigil.schema_validator import (
    validate_detections_csv, validate_detections_json,
    validate_results_directory, SchemaValidationError
)


def test_shipped_detections_csv_valid():
    """Shipped detections.csv must match the 22-column schema exactly."""
    det_csv = RESULTS_DIR / "detections.csv"
    assert det_csv.exists()
    records = validate_detections_csv(det_csv)
    assert len(records) > 0
    # Spot check columns parsed
    first = records[0]
    assert "frame" in first
    assert "id" in first
    assert "cx" in first
    assert "cy" in first
    assert "isCandidate" in first
    assert "bboxX" in first


def test_shipped_detections_json_valid():
    """Shipped detections.json must have params, thresholds, metrics, detections."""
    det_json = RESULTS_DIR / "detections.json"
    assert det_json.exists()
    data = validate_detections_json(det_json)
    assert "params" in data
    assert "thresholds" in data
    assert "metrics" in data
    assert "detections" in data
    # Confirm metrics match shipped values TP=3, FP=3, FN=1
    assert data["metrics"]["TP"] == 3
    assert data["metrics"]["FP"] == 3
    assert data["metrics"]["FN"] == 1


def test_reject_corrupt_csv_schema(tmp_path):
    """CSV with missing columns must be rejected with E_SCHEMA."""
    bad_csv = tmp_path / "detections.csv"
    bad_csv.write_text("frame,id,cx,cy\n1,1,10.0,20.0\n", encoding="utf-8")
    with pytest.raises(SchemaValidationError) as exc:
        validate_detections_csv(bad_csv)
    assert exc.value.code == "E_SCHEMA"
