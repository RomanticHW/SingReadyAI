#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

PYTHON_BIN="${PYTHON_BIN:-python3}"
VALIDATION_DERIVED_DATA="${VALIDATION_DERIVED_DATA:-$ROOT_DIR/Build/ValidationDerivedData}"
VALIDATION_PRODUCTS_DIR="$VALIDATION_DERIVED_DATA/Build/Products/Release-iphonesimulator"
VALIDATION_APP_BUNDLE="$VALIDATION_PRODUCTS_DIR/SingReadyAIApp.app"
VALIDATION_DEVICE_DERIVED_DATA="${VALIDATION_DEVICE_DERIVED_DATA:-$ROOT_DIR/Build/ValidationDeviceDerivedData}"
VALIDATION_DEVICE_PRODUCTS_DIR="$VALIDATION_DEVICE_DERIVED_DATA/Build/Products/Release-iphoneos"
VALIDATION_DEVICE_APP_BUNDLE="$VALIDATION_DEVICE_PRODUCTS_DIR/SingReadyAIApp.app"
VALIDATION_IOS_UNIT_DERIVED_DATA="${VALIDATION_IOS_UNIT_DERIVED_DATA:-$ROOT_DIR/Build/ValidationUnitDerivedData}"
VALIDATION_IOS_UNIT_DESTINATION="${VALIDATION_IOS_UNIT_DESTINATION:-platform=iOS Simulator,name=iPhone Air}"
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

if command -v xcodegen >/dev/null 2>&1; then
  run_required "xcodegen generate" xcodegen generate --use-cache
else
  echo "WARN: xcodegen not found; project generation skipped."
  echo
fi

run_required "delivery gate regression tests" "$PYTHON_BIN" scripts/test_delivery_gates.py
run_required "swift test" swift test
run_required "catalog fixture validation" "$PYTHON_BIN" scripts/validate_catalog.py
run_required "Share Extension plist and privacy validation" "$PYTHON_BIN" scripts/validate_plist.py
run_required "documentation consistency validation" "$PYTHON_BIN" scripts/validate_docs.py
run_required "design system validation" "$PYTHON_BIN" scripts/validate_design.py
run_required "performance budget validation" "$PYTHON_BIN" scripts/validate_performance_budget.py
run_required "screenshot evidence validation" "$PYTHON_BIN" scripts/validate_screenshots.py

if command -v xcodebuild >/dev/null 2>&1; then
  run_required "iOS unit test suite" \
    xcodebuild \
      test \
      -scheme SingReadyAIApp \
      -project SingReadyAI.xcodeproj \
      -destination "$VALIDATION_IOS_UNIT_DESTINATION" \
      -derivedDataPath "$VALIDATION_IOS_UNIT_DERIVED_DATA" \
      -only-testing:SingReadyAITests \
      SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
  run_required "warnings-as-errors Release generic iOS Simulator build" \
    xcodebuild \
      clean build \
      -scheme SingReadyAIApp \
      -project SingReadyAI.xcodeproj \
      -configuration Release \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$VALIDATION_DERIVED_DATA" \
      CODE_SIGNING_ALLOWED=NO \
      SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
  run_required "warnings-as-errors Release generic iOS device build" \
    xcodebuild \
      clean build \
      -scheme SingReadyAIApp \
      -project SingReadyAI.xcodeproj \
      -configuration Release \
      -destination 'generic/platform=iOS' \
      -derivedDataPath "$VALIDATION_DEVICE_DERIVED_DATA" \
      CODE_SIGNING_ALLOWED=NO \
      SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
  run_required "built app and Share Extension privacy manifest validation" \
    env SINGREADY_BUILT_PRODUCTS_DIR="$VALIDATION_PRODUCTS_DIR" \
      "$PYTHON_BIN" scripts/validate_plist.py
  run_required "Release artifact launch-hook and identifier validation" \
    "$PYTHON_BIN" scripts/validate_release.py "$VALIDATION_APP_BUNDLE"
  run_required "device app and Share Extension privacy manifest validation" \
    env SINGREADY_BUILT_PRODUCTS_DIR="$VALIDATION_DEVICE_PRODUCTS_DIR" \
      "$PYTHON_BIN" scripts/validate_plist.py
  run_required "device Release artifact contract validation" \
    "$PYTHON_BIN" scripts/validate_release.py "$VALIDATION_DEVICE_APP_BUNDLE"
  if [[ "${RUN_UI_TESTS:-1}" != "0" ]]; then
    run_required "full iPhone Air UI test suite" scripts/run_ui_tests.sh
  fi
else
  echo "FAIL: xcodebuild is required for the iOS validation gate."
  failures=$((failures + 1))
fi

if [[ $failures -ne 0 ]]; then
  echo "validate.sh failed with ${failures} required failure(s)."
  exit 1
fi

echo "validate.sh passed."
