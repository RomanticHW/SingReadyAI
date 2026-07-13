#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
  echo "Usage: $0 <simulator-udid>" >&2
  exit 2
fi

SIMULATOR_UDID="$1"
BUNDLE_IDENTIFIERS=(
  "com.example.SingReadyAI"
  "com.example.SingReadyAI.UITests.xctrunner"
  "com.huangwei.singreadyai"
  "com.huangwei.singreadyai.uitests.xctrunner"
)

# 卸载宿主应用会一并移除其 Share Extension，避免分享面板出现新旧两个入口。
for bundle_identifier in "${BUNDLE_IDENTIFIERS[@]}"; do
  xcrun simctl terminate "$SIMULATOR_UDID" "$bundle_identifier" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$SIMULATOR_UDID" "$bundle_identifier" >/dev/null 2>&1 || true
done
