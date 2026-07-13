#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone Air}"
CONTENT_SIZE="${CONTENT_SIZE:-large}"
RESULT_BUNDLE="${RESULT_BUNDLE:-Build/FullUI.xcresult}"
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

rm -rf "$RESULT_BUNDLE"
xcodebuild test \
  -scheme SingReadyAIApp \
  -project SingReadyAI.xcodeproj \
  -destination "id=$SIMULATOR_UDID" \
  -only-testing:SingReadyAIUITests \
  -resultBundlePath "$RESULT_BUNDLE"
