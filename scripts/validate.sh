#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

PYTHON_BIN="${PYTHON_BIN:-python3}"
failures=0

run_required() {
  local label="$1"
  shift
  echo "==> ${label}"
  "$@"
  local status=$?
  if [[ $status -ne 0 ]]; then
    echo "FAIL: ${label} (${status})"
    failures=$((failures + 1))
  else
    echo "PASS: ${label}"
  fi
  echo
}

run_optional() {
  local label="$1"
  shift
  echo "==> ${label}"
  "$@"
  local status=$?
  if [[ $status -ne 0 ]]; then
    echo "WARN: ${label} (${status})"
  else
    echo "PASS: ${label}"
  fi
  echo
}

run_required "swift test" swift test
run_required "catalog fixture validation" "$PYTHON_BIN" scripts/validate_catalog.py
run_required "Share Extension plist and privacy validation" "$PYTHON_BIN" scripts/validate_plist.py
run_required "documentation consistency validation" "$PYTHON_BIN" scripts/validate_docs.py
run_required "design system validation" "$PYTHON_BIN" scripts/validate_design.py
run_required "performance budget validation" "$PYTHON_BIN" scripts/validate_performance_budget.py
run_required "screenshot evidence validation" "$PYTHON_BIN" scripts/validate_screenshots.py

if command -v xcodegen >/dev/null 2>&1; then
  run_required "xcodegen generate" xcodegen generate
else
  echo "WARN: xcodegen not found; project generation skipped."
  echo
fi

if command -v xcodebuild >/dev/null 2>&1; then
  run_optional "xcodebuild generic iOS Simulator build" \
    xcodebuild \
      -scheme SingReadyAIApp \
      -project SingReadyAI.xcodeproj \
      -destination 'generic/platform=iOS Simulator' \
      CODE_SIGNING_ALLOWED=NO \
      build
else
  echo "WARN: xcodebuild not found; iOS build skipped."
  echo
fi

if [[ $failures -ne 0 ]]; then
  echo "validate.sh failed with ${failures} required failure(s)."
  exit 1
fi

echo "validate.sh passed."
