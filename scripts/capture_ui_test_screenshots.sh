#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RESULT_BUNDLE="${RESULT_BUNDLE:-Build/ScreenshotQA.xcresult}"
EXPORT_DIR="${EXPORT_DIR:-docs/screenshots/ui-test-attachments}"
DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 17}"

rm -rf "$RESULT_BUNDLE" "$EXPORT_DIR"
mkdir -p "$(dirname "$RESULT_BUNDLE")" "$EXPORT_DIR"
rm -f docs/screenshots/*.png

xcodegen generate
xcodebuild test \
  -scheme SingReadyAIApp \
  -project SingReadyAI.xcodeproj \
  -destination "$DESTINATION" \
  -only-testing:SingReadyAIUITests/SingReadyAIUITests/testScreenshotsForCriticalFlow \
  -resultBundlePath "$RESULT_BUNDLE"

xcrun xcresulttool export attachments \
  --path "$RESULT_BUNDLE" \
  --output-path "$EXPORT_DIR"

python3 - "$EXPORT_DIR" docs/screenshots <<'PY'
import json
import re
import shutil
import sys
from pathlib import Path

export_dir = Path(sys.argv[1])
target_dir = Path(sys.argv[2])
manifest = json.loads((export_dir / "manifest.json").read_text(encoding="utf-8"))

for test_entry in manifest:
    for attachment in test_entry.get("attachments", []):
        suggested_name = attachment.get("suggestedHumanReadableName", "")
        match = re.match(r"(\d{2}_[a-z]+(?:_[a-z]+)*)_\d+_", suggested_name)
        if not match:
            continue
        source = export_dir / attachment["exportedFileName"]
        destination = target_dir / f"{match.group(1)}.png"
        shutil.copyfile(source, destination)
PY

echo "Exported UI test screenshots to $EXPORT_DIR."
