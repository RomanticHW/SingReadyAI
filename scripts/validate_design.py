#!/usr/bin/env python3
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DESIGN_DIR = ROOT / "SingReadyAI/App/DesignSystem"
REQUIRED_TOKEN_FILES = [
    "AppTheme.swift",
    "ColorTokens.swift",
    "TypographyTokens.swift",
    "SpacingTokens.swift",
    "MotionTokens.swift",
    "ComponentTokens.swift",
]


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def warn(message: str) -> None:
    print(f"WARN: {message}")


def main() -> None:
    if not DESIGN_DIR.exists():
        fail("DesignSystem directory is missing")
    missing = [name for name in REQUIRED_TOKEN_FILES if not (DESIGN_DIR / name).exists()]
    if missing:
        fail(f"DesignSystem token files missing: {', '.join(missing)}")

    root_tab = ROOT / "SingReadyAI/App/RootTabView.swift"
    if "enum DesignSystem" in root_tab.read_text(encoding="utf-8", errors="ignore"):
        fail("RootTabView.swift still defines DesignSystem")

    swift_files = [
        path for path in (ROOT / "SingReadyAI").rglob("*.swift")
        if "DesignSystem" not in path.parts and "ShareExtension" not in path.parts
    ]
    hardcoded_patterns = [
        r"Color\(red:",
        r"Color\.white\.opacity",
        r"\.foregroundStyle\(\.white",
        r"\.tint\(\.(pink|cyan|orange|green|red|blue|purple)\)",
        r"cornerRadius:\s*(?:[0-9]|1[0-9])\b",
        r"\.clipShape\(RoundedRectangle\(cornerRadius:\s*(?:[0-9]|1[0-9])\b",
    ]
    hardcoded_hits = []
    for path in swift_files:
        text = path.read_text(encoding="utf-8", errors="ignore")
        for pattern in hardcoded_patterns:
            for match in re.finditer(pattern, text):
                line = text.count("\n", 0, match.start()) + 1
                hardcoded_hits.append(f"{path.relative_to(ROOT)}:{line}:{match.group(0)}")
    if len(hardcoded_hits) > 24:
        fail("Too many hardcoded visual values outside DesignSystem:\n" + "\n".join(hardcoded_hits[:40]))

    failed_files = []
    warned_files = []
    for path in (ROOT / "SingReadyAI").rglob("*.swift"):
        if "ShareExtension" in path.parts:
            continue
        line_count = sum(1 for _ in path.open(encoding="utf-8", errors="ignore"))
        rel = path.relative_to(ROOT)
        if path.name == "DemoWorkflowStore.swift" and line_count > 450:
            failed_files.append(f"{rel} has {line_count} lines; main workflow object limit is 450")
        elif line_count > 500:
            failed_files.append(f"{rel} has {line_count} lines; SwiftUI file limit is 500")
        elif line_count > 350:
            warned_files.append(f"{rel} has {line_count} lines")

    for item in warned_files:
        warn(item)
    if failed_files:
        fail("\n".join(failed_files))

    print("Design system OK")


if __name__ == "__main__":
    main()
