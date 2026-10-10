"""VIGIL BMP input validator according to the MATLAB loader requirements (load_frames.m).
"""
import re
from dataclasses import dataclass
from pathlib import Path
from typing import List, Tuple, Dict, Any, Optional
from vigil.config import (
    MIN_FRAMES, MAX_FRAMES, WARN_FRAMES_BELOW,
    MAX_FILE_SIZE_BYTES, MAX_TOTAL_SIZE_BYTES, ERR_BAD_INPUT
)


class InputValidationError(Exception):
    def __init__(self, filename: str, rule: str, detail: str):
        self.filename = filename
        self.rule = rule
        self.detail = detail
        self.code = ERR_BAD_INPUT
        super().__init__(f"[{ERR_BAD_INPUT}] Rule '{rule}' violated in '{filename}': {detail}")

    def to_dict(self) -> Dict[str, Any]:
        return {
            "code": self.code,
            "filename": self.filename,
            "rule": self.rule,
            "detail": self.detail
        }


@dataclass
class ValidatedFrame:
    original_name: str
    safe_name: str
    sequence_key: int
    width: int
    height: int
    file_size: int
    content: bytes
    sha256_hash: str


@dataclass
class ValidationResult:
    frames: List[ValidatedFrame]
    width: int
    height: int
    frame_count: int
    warnings: List[str]


def extract_sequence_number(filename: str) -> int:
    """Extract the last sequence of digits in filename to match load_frames.m."""
    matches = re.findall(r"\d+", filename)
    if not matches:
        raise ValueError("Filename contains no numbers")
    return int(matches[-1])


def validate_bmp_file(filename: str, content: bytes) -> Tuple[int, int]:
    """Strictly validates a single BMP file per Phase 0 contract.

    Returns (width, height) if valid, raises InputValidationError otherwise.
    """
    # 1. Extension check
    if not filename.lower().endswith(".bmp"):
        raise InputValidationError(filename, "bmp_extension", "File does not have a .bmp extension")

    # 2. File size cap
    if len(content) > MAX_FILE_SIZE_BYTES:
        raise InputValidationError(
            filename, "file_size_cap",
            f"File size {len(content)} bytes exceeds maximum {MAX_FILE_SIZE_BYTES} bytes (10MB)"
        )

    # 3. Minimum BMP header size (14 byte file header + 40 byte DIB header)
    if len(content) < 54:
        raise InputValidationError(filename, "bmp_truncated", "File too short to be a valid BMP")

    # 4. Signature check
    if content[0:2] != b"BM":
        raise InputValidationError(filename, "bm_signature", "File does not begin with 'BM' magic bytes")

    # 5. Read headers
    file_size_header = int.from_bytes(content[2:6], "little")
    pixel_offset = int.from_bytes(content[10:14], "little")
    dib_size = int.from_bytes(content[14:18], "little")

    if dib_size < 40 or len(content) < 14 + dib_size:
        raise InputValidationError(
            filename, "dib_header",
            f"Unsupported DIB header size {dib_size} (must be BITMAPINFOHEADER >= 40 bytes)"
        )

    width = int.from_bytes(content[18:22], "little", signed=True)
    height = int.from_bytes(content[22:26], "little", signed=True)
    planes = int.from_bytes(content[26:28], "little")
    bpp = int.from_bytes(content[28:30], "little")
    compression = int.from_bytes(content[30:34], "little")

    if width <= 0 or height <= 0:
        raise InputValidationError(
            filename, "dimensions",
            f"Invalid dimensions: width={width}, height={height} (top-down or zero size unsupported)"
        )

    # 6. Bit depth: must be 8 bpp uncompressed
    if bpp != 8:
        if bpp == 24:
            raise InputValidationError(
                filename, "24bit_rejected",
                "24-bit colour BMPs are rejected in v1 (MATLAB loader would take red channel only)"
            )
        raise InputValidationError(
            filename, "bit_depth",
            f"Bit depth {bpp} bpp rejected; only 8-bit uncompressed greyscale is supported in v1"
        )

    if compression != 0:
        raise InputValidationError(
            filename, "uncompressed",
            f"Compression type {compression} rejected; only uncompressed (BI_RGB / 0) is supported"
        )

    # 7. Greyscale palette check: 256 entries in identity order (entry i = i, i, i)
    palette_start = 14 + dib_size
    palette_bytes = content[palette_start:palette_start + 1024]
    if len(palette_bytes) < 1024:
        raise InputValidationError(filename, "palette_truncated", "Color table is missing or truncated")

    for i in range(256):
        b = palette_bytes[i * 4]
        g = palette_bytes[i * 4 + 1]
        r = palette_bytes[i * 4 + 2]
        if not (r == i and g == i and b == i):
            raise InputValidationError(
                filename, "greyscale_identity_palette",
                f"Palette entry {i} is (R={r}, G={g}, B={b}); must be identity grey ({i}, {i}, {i})"
            )

    return width, height


def validate_frame_stack(files: List[Tuple[str, bytes]]) -> ValidationResult:
    """Validates an entire frame stack for consistent dimensions, frame count,
    sequence numbers, and size constraints.
    """
    if not files:
        raise InputValidationError("stack", "empty_stack", "No files provided")

    # Total size check
    total_size = sum(len(content) for _, content in files)
    if total_size > MAX_TOTAL_SIZE_BYTES:
        raise InputValidationError(
            "stack", "total_size_cap",
            f"Total upload size {total_size} bytes exceeds maximum {MAX_TOTAL_SIZE_BYTES} bytes (100MB)"
        )

    # Frame count check
    count = len(files)
    if count < MIN_FRAMES:
        raise InputValidationError(
            "stack", "min_frames",
            f"Provided {count} frames; minimum is {MIN_FRAMES} frames (temporal median requires >= 3)"
        )
    if count > MAX_FRAMES:
        raise InputValidationError(
            "stack", "max_frames",
            f"Provided {count} frames; maximum allowed in v1 is {MAX_FRAMES} frames"
        )

    warnings: List[str] = []
    if count < WARN_FRAMES_BELOW:
        warnings.append(
            f"Stack contains {count} frames. Temporal median background subtraction is weak with "
            f"fewer than {WARN_FRAMES_BELOW} frames (detection performance may be degraded)."
        )

    # Validate filenames have unique numbers
    numbered_files = []
    seen_keys = set()
    seq_counter = 1
    for fname, content in files:
        try:
            seq_key = extract_sequence_number(fname)
        except ValueError:
            # If filename has no digits, assign a sequential key based on order
            seq_key = seq_counter
            seq_counter += 1
        if seq_key in seen_keys:
            raise InputValidationError(
                fname, "unique_numbers",
                f"Duplicate sequence number {seq_key} found in filenames; numbers must be unique"
            )
        seen_keys.add(seq_key)
        numbered_files.append((seq_key, fname, content))

    # Sort files by sequence key to match load_frames.m ordering
    numbered_files.sort(key=lambda item: item[0])

    import hashlib
    validated_frames: List[ValidatedFrame] = []
    expected_width = None
    expected_height = None

    for idx, (seq_key, fname, content) in enumerate(numbered_files, start=1):
        w, h = validate_bmp_file(fname, content)
        if expected_width is None:
            expected_width, expected_height = w, h
        else:
            if w != expected_width or h != expected_height:
                raise InputValidationError(
                    fname, "identical_dimensions",
                    f"Dimensions ({w}x{h}) do not match stack dimensions ({expected_width}x{expected_height})"
                )

        sha256 = hashlib.sha256(content).hexdigest()
        safe_name = f"frame_{idx:02d}.bmp"

        validated_frames.append(
            ValidatedFrame(
                original_name=fname,
                safe_name=safe_name,
                sequence_key=seq_key,
                width=w,
                height=h,
                file_size=len(content),
                content=content,
                sha256_hash=sha256,
            )
        )

    return ValidationResult(
        frames=validated_frames,
        width=expected_width,
        height=expected_height,
        frame_count=len(validated_frames),
        warnings=warnings
    )
