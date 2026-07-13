#!/usr/bin/env python3
import argparse
import plistlib
import re
import sys
from pathlib import Path


TEST_HOOK_PATTERN = re.compile(rb"-singready[A-Z][A-Za-z0-9]*")
PLACEHOLDER_PATTERN = re.compile(rb"com\.example(?:[A-Za-z0-9._-]*)")
EXPECTED_APP_IDENTIFIER = "com.huangwei.singreadyai"
EXPECTED_SHARE_EXTENSION_IDENTIFIER = "com.huangwei.singreadyai.shareextension"
SHARE_EXTENSION_RELATIVE_PATH = Path("PlugIns/SingReadyAIShareExtension.appex")


def read_bundle_info(path: Path, label: str, violations: list[str]) -> dict[str, object] | None:
    if not path.is_file():
        violations.append(f"missing {label} Info.plist: {path}")
        return None
    try:
        info = plistlib.loads(path.read_bytes())
    except Exception as exc:
        violations.append(f"invalid {label} Info.plist {path}: {exc}")
        return None
    if not isinstance(info, dict):
        violations.append(f"invalid {label} Info.plist root: {path}")
        return None
    return info


def require_nonempty_version(
    info: dict[str, object],
    key: str,
    label: str,
    violations: list[str],
) -> str | None:
    value = str(info.get(key) or "").strip()
    if not value:
        violations.append(f"{label} Info.plist is missing non-empty {key}")
        return None
    return value


def release_artifact_violations(app_bundle: Path) -> list[str]:
    if not app_bundle.is_dir():
        return [f"missing app bundle: {app_bundle}"]

    violations: list[str] = []
    files = sorted(path for path in app_bundle.rglob("*") if path.is_file())
    if not files:
        return [f"app bundle contains no files: {app_bundle}"]

    app_info = read_bundle_info(app_bundle / "Info.plist", "app", violations)
    extension_bundle = app_bundle / SHARE_EXTENSION_RELATIVE_PATH
    if not extension_bundle.is_dir():
        violations.append(f"missing embedded Share Extension: {extension_bundle}")
        extension_info = None
    else:
        extension_info = read_bundle_info(
            extension_bundle / "Info.plist",
            "Share Extension",
            violations,
        )

    app_marketing_version: str | None = None
    app_build_version: str | None = None
    if app_info is not None:
        app_identifier = str(app_info.get("CFBundleIdentifier") or "").strip()
        if app_identifier != EXPECTED_APP_IDENTIFIER:
            violations.append(
                f"expected app bundle identifier {EXPECTED_APP_IDENTIFIER}, found {app_identifier or '<missing>'}"
            )
        app_marketing_version = require_nonempty_version(
            app_info,
            "CFBundleShortVersionString",
            "app",
            violations,
        )
        app_build_version = require_nonempty_version(
            app_info,
            "CFBundleVersion",
            "app",
            violations,
        )

    if extension_info is not None:
        extension_identifier = str(extension_info.get("CFBundleIdentifier") or "").strip()
        if extension_identifier != EXPECTED_SHARE_EXTENSION_IDENTIFIER:
            violations.append(
                "expected Share Extension bundle identifier "
                f"{EXPECTED_SHARE_EXTENSION_IDENTIFIER}, found {extension_identifier or '<missing>'}"
            )
        extension_marketing_version = require_nonempty_version(
            extension_info,
            "CFBundleShortVersionString",
            "Share Extension",
            violations,
        )
        extension_build_version = require_nonempty_version(
            extension_info,
            "CFBundleVersion",
            "Share Extension",
            violations,
        )
        if (
            app_marketing_version is not None
            and extension_marketing_version is not None
            and extension_marketing_version != app_marketing_version
        ):
            violations.append(
                "Share Extension marketing version "
                f"{extension_marketing_version} does not match app {app_marketing_version}"
            )
        if (
            app_build_version is not None
            and extension_build_version is not None
            and extension_build_version != app_build_version
        ):
            violations.append(
                "Share Extension build version "
                f"{extension_build_version} does not match app {app_build_version}"
            )

    for path in files:
        relative_path = path.relative_to(app_bundle)
        try:
            contents = path.read_bytes()
        except OSError as exc:
            violations.append(f"{relative_path}: could not inspect file: {exc}")
            continue

        for hook in sorted(set(TEST_HOOK_PATTERN.findall(contents))):
            violations.append(
                f"{relative_path}: contains Release test launch hook {hook.decode('ascii')}"
            )
        for identifier in sorted(set(PLACEHOLDER_PATTERN.findall(contents))):
            violations.append(
                f"{relative_path}: contains placeholder identifier {identifier.decode('ascii')}"
            )

    return violations


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Validate Release app and Share Extension identifiers, versions, embedding, "
            "test launch hooks, and placeholder identifiers."
        )
    )
    parser.add_argument("app_bundle", type=Path)
    args = parser.parse_args()

    violations = release_artifact_violations(args.app_bundle)
    if violations:
        print("Release artifact validation failed:", file=sys.stderr)
        for violation in violations:
            print(f"- {violation}", file=sys.stderr)
        return 1

    print(f"Release artifact OK: {args.app_bundle}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
