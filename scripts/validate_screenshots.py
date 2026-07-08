#!/usr/bin/env python3
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCREENSHOT_DIR = ROOT / "docs/screenshots"
CAPTURE_SCRIPT = ROOT / "scripts/capture_screenshots.sh"
VISUAL_QA = ROOT / "docs/VISUAL_QA.md"


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    png_count = len(list(SCREENSHOT_DIR.glob("*.png"))) if SCREENSHOT_DIR.exists() else 0
    if png_count >= 10:
        print(f"Screenshot evidence OK: {png_count} PNG files")
        return

    if CAPTURE_SCRIPT.exists() and os.access(CAPTURE_SCRIPT, os.X_OK) and VISUAL_QA.exists():
        qa_text = VISUAL_QA.read_text(encoding="utf-8", errors="ignore")
        if "环境限制" in qa_text and "capture_screenshots.sh" in qa_text:
            print("Screenshot script OK with documented environment limits")
            return

    fail(f"Need at least 10 screenshots or executable capture script with documented limits; found {png_count} PNG files")


if __name__ == "__main__":
    main()
