#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RESULT_BUNDLE="${RESULT_BUNDLE:-Build/ScreenshotQA.xcresult}"
EXPORT_DIR="${EXPORT_DIR:-docs/screenshots/ui-test-attachments}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-docs/screenshots}"
DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone Air}"
CONTENT_SIZE="${CONTENT_SIZE:-large}"
SIMULATOR_NAME="${SIMULATOR_NAME:-$(printf '%s' "$DESTINATION" | sed -n 's/.*name=\([^,]*\).*/\1/p')}"

if [[ -z "${SIMULATOR_UDID:-}" ]]; then
  SIMULATOR_UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
payload = json.load(sys.stdin)
matches = [device for devices in payload["devices"].values() for device in devices if device["name"] == name]
if not matches:
    raise SystemExit(f"No available simulator named {name}")
booted = next((device for device in matches if device["state"] == "Booted"), matches[0])
print(booted["udid"])
' "$SIMULATOR_NAME")"
fi

xcrun simctl boot "$SIMULATOR_UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b
bash scripts/clean_simulator_installations.sh "$SIMULATOR_UDID"
PREVIOUS_CONTENT_SIZE="$(xcrun simctl ui "$SIMULATOR_UDID" content_size)"
restore_content_size() {
  xcrun simctl ui "$SIMULATOR_UDID" content_size "$PREVIOUS_CONTENT_SIZE" >/dev/null 2>&1 || true
}
trap restore_content_size EXIT
xcrun simctl ui "$SIMULATOR_UDID" content_size "$CONTENT_SIZE"
ACTUAL_CONTENT_SIZE="$(xcrun simctl ui "$SIMULATOR_UDID" content_size)"
if [[ "$ACTUAL_CONTENT_SIZE" != "$CONTENT_SIZE" ]]; then
  echo "Expected content size $CONTENT_SIZE, got $ACTUAL_CONTENT_SIZE" >&2
  exit 1
fi

rm -rf "$RESULT_BUNDLE" "$EXPORT_DIR" "$SCREENSHOT_DIR"
mkdir -p "$(dirname "$RESULT_BUNDLE")" "$EXPORT_DIR" "$SCREENSHOT_DIR"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --use-cache
fi
xcodebuild test \
  -scheme SingReadyAIApp \
  -project SingReadyAI.xcodeproj \
  -destination "id=$SIMULATOR_UDID" \
  -only-testing:SingReadyAIUITests/SingReadyAIUITests/testScreenshotsForCriticalFlow \
  -resultBundlePath "$RESULT_BUNDLE"

xcrun xcresulttool export attachments \
  --path "$RESULT_BUNDLE" \
  --output-path "$EXPORT_DIR"

python3 - "$EXPORT_DIR" "$SCREENSHOT_DIR" "$CONTENT_SIZE" "$SIMULATOR_UDID" <<'PY'
import json
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

from scripts.screenshot_source_fingerprint import screenshot_source_digest

export_dir = Path(sys.argv[1])
target_dir = Path(sys.argv[2])
content_size = sys.argv[3]
simulator_udid = sys.argv[4]
manifest = json.loads((export_dir / "manifest.json").read_text(encoding="utf-8"))
captured = []

for test_entry in manifest:
    for attachment in test_entry.get("attachments", []):
        suggested_name = attachment.get("suggestedHumanReadableName", "")
        match = re.match(r"(\d{2}_[a-z]+(?:_[a-z]+)*)_\d+_", suggested_name)
        if not match:
            continue
        source = export_dir / attachment["exportedFileName"]
        destination = target_dir / f"{match.group(1)}.png"
        shutil.copyfile(source, destination)
        captured.append(destination.name)

(target_dir / "capture-metadata.json").write_text(json.dumps({
    "captured_at": datetime.now(timezone.utc).isoformat(),
    "content_size": content_size,
    "simulator_udid": simulator_udid,
    "source_tree_sha256": screenshot_source_digest(Path.cwd()),
    "files": sorted(captured),
}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

echo "Exported $CONTENT_SIZE screenshots to $SCREENSHOT_DIR."
