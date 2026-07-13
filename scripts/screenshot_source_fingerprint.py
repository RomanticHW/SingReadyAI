#!/usr/bin/env python3
import hashlib
from pathlib import Path


SCREENSHOT_SOURCE_SUFFIXES = {
    ".json",
    ".png",
    ".storyboard",
    ".swift",
    ".xcprivacy",
}


def screenshot_source_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for directory_name in ("SingReadyAI", "Sources", "UITests"):
        directory = root / directory_name
        files.extend(
            path
            for path in directory.rglob("*")
            if path.is_file() and path.suffix.lower() in SCREENSHOT_SOURCE_SUFFIXES
        )
    files.extend(
        path
        for path in (
            root / "SingReadyAI.xcodeproj/project.pbxproj",
            root / "PRIVACY.md",
            root / "project.yml",
        )
        if path.is_file()
    )
    return sorted(set(files), key=lambda path: path.relative_to(root).as_posix())


def screenshot_source_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in screenshot_source_files(root):
        relative_path = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(relative_path)
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()
