#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p docs/screenshots
rm -f docs/screenshots/*.png
xcodegen generate
xcodebuild \
  -scheme SingReadyAIApp \
  -project SingReadyAI.xcodeproj \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build

DEVICE_NAME="${DEVICE_NAME:-iPhone 17}"
DEVICE_UDID="${DEVICE_UDID:-}"
if [[ -z "$DEVICE_UDID" ]]; then
  DEVICE_UDID="$(xcrun simctl list devices available -j | python3 -c '
import json
import sys

target_name = sys.argv[1]
devices_by_runtime = json.load(sys.stdin).get("devices", {})
available_devices = [
    device
    for devices in devices_by_runtime.values()
    for device in devices
    if device.get("isAvailable") and device.get("name")
]

selected = next((device for device in available_devices if device["name"] == target_name), None)
if selected is None:
    selected = next((device for device in available_devices if device["name"].startswith("iPhone")), None)

if selected is not None:
    print(selected["udid"])
' "$DEVICE_NAME")"
fi

if [[ -z "$DEVICE_UDID" ]]; then
  echo "No available iPhone simulator found."
  exit 1
fi

xcrun simctl boot "$DEVICE_UDID" || true
xcrun simctl bootstatus "$DEVICE_UDID" -b
open -a Simulator
APP_PATH="$(find ~/Library/Developer/Xcode/DerivedData -path '*Build/Products/Debug-iphonesimulator/SingReadyAIApp.app' -type d -print0 | xargs -0 ls -td | head -n 1)"
if [[ -z "$APP_PATH" ]]; then
  echo "Built app bundle not found."
  exit 1
fi

xcrun simctl uninstall "$DEVICE_UDID" com.example.SingReadyAI || true
xcrun simctl install "$DEVICE_UDID" "$APP_PATH"
xcrun simctl launch "$DEVICE_UDID" com.example.SingReadyAI
sleep 3
xcrun simctl io "$DEVICE_UDID" screenshot docs/screenshots/01_onboarding.png

capture_stage() {
  local stage="$1"
  local output="$2"
  xcrun simctl terminate "$DEVICE_UDID" com.example.SingReadyAI || true
  xcrun simctl launch "$DEVICE_UDID" com.example.SingReadyAI -singreadyStage "$stage"
  sleep 2
  xcrun simctl io "$DEVICE_UDID" screenshot "docs/screenshots/${output}"
}

capture_stage importHub 02_import_hub.png
capture_stage review 03_import_review.png
capture_stage matchReport 04_match_report.png
capture_stage voiceSetup 05_voice_setup.png
capture_stage voiceResult 06_voice_result.png
capture_stage scenario 07_scenario_builder.png
capture_stage result 08_song_plan_result.png
capture_stage export 09_export_center.png
capture_stage interview 10_interview_mode.png

echo "Captured 10 screenshots in docs/screenshots."
