#!/usr/bin/env python3
import json
import struct
import sys
from pathlib import Path

from screenshot_source_fingerprint import screenshot_source_digest

ROOT = Path(__file__).resolve().parents[1]
SCREENSHOT_DIR = ROOT / "docs/screenshots"
LARGE_SCREENSHOT_DIR = ROOT / "docs/screenshots-large-text"
EXPECTED_NAMES = [
    "01_onboarding.png",
    "02_home.png",
    "03_import_hub.png",
    "04_import_review.png",
    "05_match_report.png",
    "06_voice_setup.png",
    "07_voice_result.png",
    "08_scenario_builder.png",
    "09_song_plan_result.png",
    "10_export_center.png",
    "11_start_tips.png",
]


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def png_dimensions(path: Path) -> tuple[int, int]:
    data = path.read_bytes()[:24]
    require(len(data) == 24 and data[:8] == b"\x89PNG\r\n\x1a\n", f"invalid PNG: {path}")
    return struct.unpack(">II", data[16:24])


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def validate_set(directory: Path, expected_content_size: str) -> None:
    require(directory.exists(), f"missing screenshot directory: {directory}")
    actual_names = sorted(path.name for path in directory.glob("*.png"))
    require(actual_names == EXPECTED_NAMES, f"{directory.name} must contain the exact 11 expected screenshots")
    metadata_path = directory / "capture-metadata.json"
    require(metadata_path.exists(), f"missing screenshot metadata: {metadata_path}")
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    require(metadata.get("content_size") == expected_content_size, f"{directory.name} has wrong content size metadata")
    require(metadata.get("files") == EXPECTED_NAMES, f"{directory.name} metadata does not match screenshots")
    expected_source_digest = screenshot_source_digest(ROOT)
    require(
        metadata.get("source_tree_sha256") == expected_source_digest,
        f"{directory.name} metadata does not match the current screenshot source tree",
    )

    dimensions = set()
    for name in EXPECTED_NAMES:
        path = directory / name
        require(path.stat().st_size >= 50_000, f"screenshot is unexpectedly small: {path}")
        width, height = png_dimensions(path)
        require(width >= 750 and height >= 1500, f"screenshot resolution is too small: {path} ({width}x{height})")
        dimensions.add((width, height))
    require(len(dimensions) == 1, f"screenshots in {directory.name} must use one device resolution")

    source_files = list((ROOT / "SingReadyAI").rglob("*.swift"))
    source_files += list((ROOT / "Sources").rglob("*.swift"))
    source_files += [ROOT / "SingReadyAI.xcodeproj/project.pbxproj", ROOT / "project.yml"]
    newest_source = max(path.stat().st_mtime for path in source_files if path.exists())
    oldest_screenshot = min((directory / name).stat().st_mtime for name in EXPECTED_NAMES)
    require(oldest_screenshot >= newest_source, f"{directory.name} screenshots are older than current UI sources")


def main() -> None:
    validate_set(SCREENSHOT_DIR, "large")
    validate_set(LARGE_SCREENSHOT_DIR, "accessibility-extra-extra-extra-large")
    print("Screenshot evidence OK: 22 current PNG files at standard and maximum accessibility sizes")


if __name__ == "__main__":
    main()
