"""Tests for BMP input validator matching load_frames.m requirements.
"""
import pytest
from pathlib import Path
from vigil.config import FRAMES_DIR
from vigil.validator import (
    validate_bmp_file, validate_frame_stack,
    extract_sequence_number, InputValidationError
)


def create_dummy_bmp(width: int = 10, height: int = 10, bpp: int = 8, comp: int = 0, is_identity: bool = True) -> bytes:
    """Helper to generate minimal binary BMP headers for testing edge cases."""
    row_bytes = (width * (bpp // 8) + 3) & (~3)  # 4-byte aligned
    pixel_data_size = row_bytes * height
    palette_size = 1024 if bpp == 8 else 0
    offset = 14 + 40 + palette_size
    file_size = offset + pixel_data_size

    # 14-byte file header
    header = bytearray(b"BM")
    header += file_size.to_bytes(4, "little")
    header += (0).to_bytes(4, "little")  # reserved
    header += offset.to_bytes(4, "little")

    # 40-byte DIB header
    dib = bytearray((40).to_bytes(4, "little"))
    dib += width.to_bytes(4, "little", signed=True)
    dib += height.to_bytes(4, "little", signed=True)
    dib += (1).to_bytes(2, "little")  # planes
    dib += bpp.to_bytes(2, "little")
    dib += comp.to_bytes(4, "little")
    dib += pixel_data_size.to_bytes(4, "little")
    dib += (2835).to_bytes(4, "little")  # 72 DPI
    dib += (2835).to_bytes(4, "little")
    dib += (256 if bpp == 8 else 0).to_bytes(4, "little")
    dib += (0).to_bytes(4, "little")

    # Palette
    palette = bytearray()
    if bpp == 8:
        for i in range(256):
            if is_identity:
                palette += bytes([i, i, i, 0])
            else:
                palette += bytes([255 - i, i, i, 0])  # Non-identity

    pixels = bytes([128] * pixel_data_size)
    return bytes(header + dib + palette + pixels)


def test_bundled_synthetic_frames_pass_validation():
    """All 4 shipped synthetic BMPs must pass strict validation."""
    frame_files = sorted(list(FRAMES_DIR.glob("*.bmp")))
    assert len(frame_files) == 4

    files = []
    for f in frame_files:
        with open(f, "rb") as fp:
            files.append((f.name, fp.read()))

    res = validate_frame_stack(files)
    assert res.frame_count == 4
    assert res.width == 646
    assert res.height == 486
    # 4 frames is < 5, so a warning must be emitted per Phase 0 contract
    assert len(res.warnings) == 1
    assert "Temporal median background subtraction is weak" in res.warnings[0]


def test_reject_non_bmp():
    with pytest.raises(InputValidationError) as exc:
        validate_bmp_file("image.png", b"not a bmp file")
    assert exc.value.rule == "bmp_extension"


def test_reject_24bit_colour():
    bmp_24 = create_dummy_bmp(10, 10, bpp=24)
    with pytest.raises(InputValidationError) as exc:
        validate_bmp_file("frame_01.bmp", bmp_24)
    assert exc.value.rule == "24bit_rejected"


def test_reject_non_identity_palette():
    bmp_bad_pal = create_dummy_bmp(10, 10, bpp=8, is_identity=False)
    with pytest.raises(InputValidationError) as exc:
        validate_bmp_file("frame_01.bmp", bmp_bad_pal)
    assert exc.value.rule == "greyscale_identity_palette"


def test_reject_mismatched_dimensions():
    bmp1 = create_dummy_bmp(10, 10)
    bmp2 = create_dummy_bmp(10, 12)
    with pytest.raises(InputValidationError) as exc:
        validate_frame_stack([
            ("f_01.bmp", bmp1),
            ("f_02.bmp", bmp1),
            ("f_03.bmp", bmp2),
        ])
    assert exc.value.rule == "identical_dimensions"


def test_reject_fewer_than_3_frames():
    bmp = create_dummy_bmp(10, 10)
    with pytest.raises(InputValidationError) as exc:
        validate_frame_stack([
            ("f_01.bmp", bmp),
            ("f_02.bmp", bmp),
        ])
    assert exc.value.rule == "min_frames"


def test_numeric_sequence_ordering():
    assert extract_sequence_number("debris_04.bmp") == 4
    assert extract_sequence_number("cam1_seq10_frame_02.bmp") == 2
