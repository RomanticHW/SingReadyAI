#!/usr/bin/env python3
import os
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHARE_PLIST = ROOT / "SingReadyAI/ShareExtension/Info.plist"
APP_PRIVACY_MANIFEST = ROOT / "SingReadyAI/App/PrivacyInfo.xcprivacy"
SHARE_PRIVACY_MANIFEST = ROOT / "SingReadyAI/ShareExtension/PrivacyInfo.xcprivacy"
OFFLINE_PRIVACY_POLICY = ROOT / "PRIVACY.md"
APP_ENTITLEMENTS = ROOT / "SingReadyAI/App/SingReadyAI.entitlements"
SHARE_ENTITLEMENTS = ROOT / "SingReadyAI/ShareExtension/SingReadyAIShareExtension.entitlements"
PROJECT = ROOT / "project.yml"
PBX_PROJECT = ROOT / "SingReadyAI.xcodeproj/project.pbxproj"
APP_PRIVACY_RESOURCE = "SingReadyAI/App/PrivacyInfo.xcprivacy"
SHARE_PRIVACY_RESOURCE = "SingReadyAI/ShareExtension/PrivacyInfo.xcprivacy"
APP_ENTITLEMENTS_SETTING = "SingReadyAI/App/SingReadyAI.entitlements"
SHARE_ENTITLEMENTS_SETTING = "SingReadyAI/ShareExtension/SingReadyAIShareExtension.entitlements"

USER_DEFAULTS_API = "NSPrivacyAccessedAPICategoryUserDefaults"
FILE_TIMESTAMP_API = "NSPrivacyAccessedAPICategoryFileTimestamp"
SYSTEM_BOOT_TIME_API = "NSPrivacyAccessedAPICategorySystemBootTime"
APP_EXPECTED_PRIVACY_REASONS = {
    USER_DEFAULTS_API: "CA92.1",
    FILE_TIMESTAMP_API: "C617.1",
    SYSTEM_BOOT_TIME_API: "35F9.1",
}
SHARE_EXPECTED_PRIVACY_REASONS = {
    FILE_TIMESTAMP_API: "C617.1",
    SYSTEM_BOOT_TIME_API: "35F9.1",
}
PRIVACY_API_LABELS = {
    USER_DEFAULTS_API: "UserDefaults",
    FILE_TIMESTAMP_API: "FileTimestamp",
    SYSTEM_BOOT_TIME_API: "SystemBootTime",
}


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def has_privacy_reason(accessed: object, api_type: str, reason: str) -> bool:
    if not isinstance(accessed, list):
        return False
    return any(
        isinstance(entry, dict)
        and entry.get("NSPrivacyAccessedAPIType") == api_type
        and isinstance(entry.get("NSPrivacyAccessedAPITypeReasons"), list)
        and reason in entry["NSPrivacyAccessedAPITypeReasons"]
        for entry in accessed
    )


def project_target_has_resource(project_text: str, target_name: str, resource_path: str) -> bool:
    target_match = re.search(
        rf"(?ms)^  {re.escape(target_name)}:\s*\n(?P<body>.*?)(?=^  [A-Za-z0-9_]+:\s*\n|^schemes:\s*\n|\Z)",
        project_text,
    )
    if target_match is None:
        return False
    resources_match = re.search(
        r"(?ms)^    resources:\s*\n(?P<body>(?:^      - .*(?:\n|\Z))+)",
        target_match.group("body"),
    )
    if resources_match is None:
        return False
    resources = {
        line.strip()[2:].strip()
        for line in resources_match.group("body").splitlines()
        if line.strip().startswith("- ")
    }
    return resource_path in resources


def project_target_has_setting(
    project_text: str,
    target_name: str,
    setting_name: str,
    expected_value: str,
) -> bool:
    target_match = re.search(
        rf"(?ms)^  {re.escape(target_name)}:\s*\n(?P<body>.*?)(?=^  [A-Za-z0-9_]+:\s*\n|^schemes:\s*\n|\Z)",
        project_text,
    )
    if target_match is None:
        return False
    setting_match = re.search(
        rf"(?m)^        {re.escape(setting_name)}:\s*(?P<value>.+?)\s*$",
        target_match.group("body"),
    )
    if setting_match is None:
        return False
    return setting_match.group("value").strip("'\"") == expected_value


def pbx_target_has_resource(pbx_text: str, target_name: str, resource_name: str) -> bool:
    target_match = re.search(
        rf"(?ms)^[ \t]*[A-Za-z0-9]+ /\* {re.escape(target_name)} \*/ = \{{\n"
        r"[ \t]*isa = PBXNativeTarget;(?P<body>.*?)^[ \t]*\};",
        pbx_text,
    )
    if target_match is None:
        return False
    resource_phase_ids = re.findall(
        r"([A-Za-z0-9]+) /\* Resources \*/",
        target_match.group("body"),
    )
    for phase_id in resource_phase_ids:
        phase_match = re.search(
            rf"(?ms)^[ \t]*{re.escape(phase_id)} /\* Resources \*/ = \{{\n"
            r"[ \t]*isa = PBXResourcesBuildPhase;(?P<body>.*?)^[ \t]*\};",
            pbx_text,
        )
        if phase_match and f"/* {resource_name} in Resources */" in phase_match.group("body"):
            return True
    return False


def pbx_target_has_setting(
    pbx_text: str,
    target_name: str,
    setting_name: str,
    expected_value: str,
) -> bool:
    target_match = re.search(
        rf"(?ms)^[ \t]*[A-Za-z0-9]+ /\* {re.escape(target_name)} \*/ = \{{\n"
        r"[ \t]*isa = PBXNativeTarget;(?P<body>.*?)^[ \t]*\};",
        pbx_text,
    )
    if target_match is None:
        return False
    configuration_list_match = re.search(
        r"buildConfigurationList = ([A-Za-z0-9]+) ",
        target_match.group("body"),
    )
    if configuration_list_match is None:
        return False
    configuration_list_id = configuration_list_match.group(1)
    configuration_list = re.search(
        rf"(?ms)^[ \t]*{re.escape(configuration_list_id)} /\* .*? \*/ = \{{\n"
        r"[ \t]*isa = XCConfigurationList;(?P<body>.*?)^[ \t]*\};",
        pbx_text,
    )
    if configuration_list is None:
        return False
    configuration_ids = re.findall(
        r"^[ \t]*([A-Za-z0-9]+) /\* (?:Debug|Release) \*/",
        configuration_list.group("body"),
        flags=re.MULTILINE,
    )
    if not configuration_ids:
        return False
    for configuration_id in configuration_ids:
        configuration = re.search(
            rf"(?ms)^[ \t]*{re.escape(configuration_id)} /\* .*? \*/ = \{{\n"
            r"[ \t]*isa = XCBuildConfiguration;(?P<body>.*?)^[ \t]*\};",
            pbx_text,
        )
        if configuration is None:
            return False
        setting_match = re.search(
            rf"(?m)^[ \t]*{re.escape(setting_name)} = (?P<value>.+?);\s*$",
            configuration.group("body"),
        )
        if setting_match is None:
            return False
        if setting_match.group("value").strip("'\"") != expected_value:
            return False
    return True


def missing_bundled_privacy_manifests(products_directory: Path) -> list[Path]:
    app_bundle = products_directory / "SingReadyAIApp.app"
    extension_bundle = app_bundle / "PlugIns/SingReadyAIShareExtension.appex"
    expected = [
        app_bundle / "PrivacyInfo.xcprivacy",
        extension_bundle / "PrivacyInfo.xcprivacy",
    ]
    return [path for path in expected if not path.is_file()]


def privacy_manifest_errors(
    path: Path,
    expected_reasons: dict[str, str],
) -> list[str]:
    if not path.is_file():
        return [f"missing {path}"]
    try:
        privacy = plistlib.loads(path.read_bytes())
    except Exception as exc:
        return [f"invalid {path}: {exc}"]

    errors: list[str] = []
    if privacy.get("NSPrivacyTracking") is not False:
        errors.append(f"{path} must explicitly disable tracking")
    if not isinstance(privacy.get("NSPrivacyCollectedDataTypes"), list):
        errors.append(f"{path} is missing collected data declaration")

    accessed = privacy.get("NSPrivacyAccessedAPITypes")
    if not isinstance(accessed, list):
        errors.append(f"{path} is missing required-reason API declaration")
        return errors

    actual_api_types = {
        entry.get("NSPrivacyAccessedAPIType")
        for entry in accessed
        if isinstance(entry, dict) and isinstance(entry.get("NSPrivacyAccessedAPIType"), str)
    }
    for api_type in sorted(actual_api_types - set(expected_reasons)):
        label = PRIVACY_API_LABELS.get(api_type, api_type)
        errors.append(f"{path} must not declare {label}")
    for api_type, reason in expected_reasons.items():
        label = PRIVACY_API_LABELS.get(api_type, api_type)
        if not has_privacy_reason(accessed, api_type, reason):
            errors.append(f"{path} is missing {label} reason {reason}")
    return errors


def bundled_privacy_manifest_errors(products_directory: Path) -> list[str]:
    app_bundle = products_directory / "SingReadyAIApp.app"
    manifests = [
        (app_bundle / "PrivacyInfo.xcprivacy", APP_EXPECTED_PRIVACY_REASONS),
        (
            app_bundle / "PlugIns/SingReadyAIShareExtension.appex/PrivacyInfo.xcprivacy",
            SHARE_EXPECTED_PRIVACY_REASONS,
        ),
    ]
    errors: list[str] = []
    for path, expected_reasons in manifests:
        errors.extend(privacy_manifest_errors(path, expected_reasons))
    return errors


def bundled_privacy_policy_errors(products_directory: Path) -> list[str]:
    bundled_policy = products_directory / "SingReadyAIApp.app/PRIVACY.md"
    if not bundled_policy.is_file():
        return [f"missing {bundled_policy}"]
    if not OFFLINE_PRIVACY_POLICY.is_file():
        return [f"missing {OFFLINE_PRIVACY_POLICY}"]
    if bundled_policy.read_bytes() != OFFLINE_PRIVACY_POLICY.read_bytes():
        return [f"{bundled_policy} does not match {OFFLINE_PRIVACY_POLICY}"]
    return []


def bundled_info_contract_errors(products_directory: Path) -> list[str]:
    app_info_path = products_directory / "SingReadyAIApp.app/Info.plist"
    extension_info_path = (
        products_directory
        / "SingReadyAIApp.app/PlugIns/SingReadyAIShareExtension.appex/Info.plist"
    )
    errors: list[str] = []

    def load_info(path: Path) -> dict[str, object] | None:
        if not path.is_file():
            errors.append(f"missing {path}")
            return None
        try:
            value = plistlib.loads(path.read_bytes())
        except Exception as exc:
            errors.append(f"invalid {path}: {exc}")
            return None
        if not isinstance(value, dict):
            errors.append(f"{path} must contain a dictionary")
            return None
        return value

    def require_equal(
        info: dict[str, object],
        path: Path,
        key: str,
        expected: object,
    ) -> None:
        if info.get(key) != expected:
            errors.append(f"{path} {key} must equal {expected!r}")

    def require_nonempty(info: dict[str, object], path: Path, key: str) -> None:
        value = info.get(key)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{path} {key} must be a non-empty string")

    app_info = load_info(app_info_path)
    if app_info is not None:
        require_equal(app_info, app_info_path, "CFBundleDisplayName", "今晚唱什么")
        require_equal(
            app_info,
            app_info_path,
            "CFBundleIdentifier",
            "com.huangwei.singreadyai",
        )
        require_equal(app_info, app_info_path, "MinimumOSVersion", "17.0")
        require_equal(app_info, app_info_path, "UIDeviceFamily", [1])
        require_equal(app_info, app_info_path, "UILaunchStoryboardName", "LaunchScreen")
        require_equal(
            app_info,
            app_info_path,
            "UISupportedInterfaceOrientations",
            ["UIInterfaceOrientationPortrait"],
        )
        require_nonempty(app_info, app_info_path, "NSMicrophoneUsageDescription")
        require_nonempty(app_info, app_info_path, "NSPhotoLibraryAddUsageDescription")
        icons = app_info.get("CFBundleIcons")
        primary_icon = icons.get("CFBundlePrimaryIcon") if isinstance(icons, dict) else None
        icon_name = primary_icon.get("CFBundleIconName") if isinstance(primary_icon, dict) else None
        if icon_name != "AppIcon":
            errors.append(
                f"{app_info_path} CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName must equal 'AppIcon'"
            )

    extension_info = load_info(extension_info_path)
    if extension_info is not None:
        require_equal(extension_info, extension_info_path, "CFBundleDisplayName", "今晚唱什么")
        require_equal(
            extension_info,
            extension_info_path,
            "CFBundleIdentifier",
            "com.huangwei.singreadyai.shareextension",
        )
        require_equal(extension_info, extension_info_path, "MinimumOSVersion", "17.0")
        require_equal(extension_info, extension_info_path, "UIDeviceFamily", [1])
        extension = extension_info.get("NSExtension")
        if not isinstance(extension, dict):
            errors.append(f"{extension_info_path} NSExtension must be a dictionary")
        else:
            if extension.get("NSExtensionPointIdentifier") != "com.apple.share-services":
                errors.append(
                    f"{extension_info_path} NSExtensionPointIdentifier must equal 'com.apple.share-services'"
                )
            principal = extension.get("NSExtensionPrincipalClass")
            if principal != "SingReadyAIShareExtension.ShareViewController":
                errors.append(
                    f"{extension_info_path} NSExtensionPrincipalClass must equal "
                    "'SingReadyAIShareExtension.ShareViewController'"
                )
            attributes = extension.get("NSExtensionAttributes")
            activation = (
                attributes.get("NSExtensionActivationRule")
                if isinstance(attributes, dict)
                else None
            )
            if not isinstance(activation, dict):
                errors.append(
                    f"{extension_info_path} NSExtensionActivationRule must be a dictionary"
                )
            else:
                if activation.get("NSExtensionActivationSupportsText") is not True:
                    errors.append(f"{extension_info_path} activation must support plain text")
                if activation.get("NSExtensionActivationSupportsWebURLWithMaxCount", 0) < 1:
                    errors.append(f"{extension_info_path} activation must support URLs")
                if activation.get("NSExtensionActivationSupportsImageWithMaxCount", 0) < 1:
                    errors.append(f"{extension_info_path} activation must support images")

    return errors


def main() -> None:
    require(SHARE_PLIST.exists(), f"missing {SHARE_PLIST}")
    try:
        info = plistlib.loads(SHARE_PLIST.read_bytes())
    except Exception as exc:
        fail(f"Info.plist parse failed: {exc}")

    display_name = str(info.get("CFBundleDisplayName") or "").strip()
    require(display_name, "Share Extension Info.plist missing non-empty CFBundleDisplayName")

    extension = info.get("NSExtension")
    require(isinstance(extension, dict), "Share Extension Info.plist missing NSExtension dictionary")
    require(
        extension.get("NSExtensionPointIdentifier") == "com.apple.share-services",
        "NSExtensionPointIdentifier must be com.apple.share-services",
    )
    principal = extension.get("NSExtensionPrincipalClass") or extension.get("NSExtensionMainStoryboard")
    require(principal, "Share Extension must declare principal class or storyboard")

    attributes = extension.get("NSExtensionAttributes")
    require(isinstance(attributes, dict), "NSExtensionAttributes missing")
    activation = attributes.get("NSExtensionActivationRule")
    require(activation, "NSExtensionActivationRule missing")
    if isinstance(activation, dict):
        require(
            activation.get("NSExtensionActivationSupportsWebURLWithMaxCount", 0) >= 1
            or activation.get("NSExtensionActivationSupportsWebPageWithMaxCount", 0) >= 1,
            "Activation rule must support URL shares",
        )
        require(
            activation.get("NSExtensionActivationSupportsText") is True,
            "Activation rule must support plain text shares",
        )
        require(
            activation.get("NSExtensionActivationSupportsImageWithMaxCount", 0) >= 1,
            "Activation rule must support image shares",
        )
    else:
        activation_string = str(activation)
        for token in ("public.url", "public.plain-text", "public.image"):
            require(token in activation_string, f"Activation predicate must mention {token}")

    require(PROJECT.exists(), "missing project.yml")
    project_text = PROJECT.read_text(encoding="utf-8")
    require(
        re.search(r"INFOPLIST_KEY_NSMicrophoneUsageDescription\s*:", project_text),
        "project.yml missing INFOPLIST_KEY_NSMicrophoneUsageDescription",
    )

    source_text = "\n".join(path.read_text(encoding="utf-8", errors="ignore") for path in (ROOT / "SingReadyAI").rglob("*.swift"))
    saves_to_photos = "UIImageWriteToSavedPhotosAlbum" in source_text or "PHPhotoLibrary" in source_text
    if saves_to_photos:
        require(
            re.search(r"INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription\s*:", project_text),
            "project.yml saves to Photos but is missing INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription",
        )

    source_manifest_errors = privacy_manifest_errors(
        APP_PRIVACY_MANIFEST,
        APP_EXPECTED_PRIVACY_REASONS,
    ) + privacy_manifest_errors(
        SHARE_PRIVACY_MANIFEST,
        SHARE_EXPECTED_PRIVACY_REASONS,
    )
    require(
        not source_manifest_errors,
        "source privacy validation failed: " + "; ".join(source_manifest_errors),
    )
    privacy = plistlib.loads(APP_PRIVACY_MANIFEST.read_bytes())
    accessed = privacy.get("NSPrivacyAccessedAPITypes")

    required_reason_sources = "\n".join(
        path.read_text(encoding="utf-8", errors="ignore")
        for source_root in (ROOT / "SingReadyAI", ROOT / "Sources")
        for path in source_root.rglob("*.swift")
    )
    uses_file_timestamps = any(
        token in required_reason_sources
        for token in ("contentModificationDateKey", ".contentModificationDate", "fileModificationDate")
    )
    if uses_file_timestamps:
        require(
            has_privacy_reason(
                accessed,
                "NSPrivacyAccessedAPICategoryFileTimestamp",
                "C617.1",
            ),
            "container file timestamp access must declare FileTimestamp reason C617.1",
        )
    uses_system_boot_time = any(
        token in required_reason_sources
        for token in ("uptimeNanoseconds", "systemUptime", "mach_absolute_time")
    )
    if uses_system_boot_time:
        require(
            has_privacy_reason(
                accessed,
                "NSPrivacyAccessedAPICategorySystemBootTime",
                "35F9.1",
            ),
            "monotonic timer access must declare SystemBootTime reason 35F9.1",
        )

    for target_name, resource_path in (
        ("SingReadyAIApp", APP_PRIVACY_RESOURCE),
        ("SingReadyAIShareExtension", SHARE_PRIVACY_RESOURCE),
    ):
        require(
            project_target_has_resource(project_text, target_name, resource_path),
            f"project.yml target {target_name} must package {resource_path}",
        )

    for target_name, entitlements_path in (
        ("SingReadyAIApp", APP_ENTITLEMENTS_SETTING),
        ("SingReadyAIShareExtension", SHARE_ENTITLEMENTS_SETTING),
    ):
        require(
            project_target_has_setting(
                project_text,
                target_name,
                "CODE_SIGN_ENTITLEMENTS",
                entitlements_path,
            ),
            f"project.yml target {target_name} must reference {entitlements_path}",
        )

    require(PBX_PROJECT.exists(), f"missing {PBX_PROJECT}")
    pbx_text = PBX_PROJECT.read_text(encoding="utf-8", errors="ignore")
    for target_name in ("SingReadyAIApp", "SingReadyAIShareExtension"):
        require(
            pbx_target_has_resource(pbx_text, target_name, "PrivacyInfo.xcprivacy"),
            f"project.pbxproj target {target_name} must package PrivacyInfo.xcprivacy",
        )
    for target_name, entitlements_path in (
        ("SingReadyAIApp", APP_ENTITLEMENTS_SETTING),
        ("SingReadyAIShareExtension", SHARE_ENTITLEMENTS_SETTING),
    ):
        require(
            pbx_target_has_setting(
                pbx_text,
                target_name,
                "CODE_SIGN_ENTITLEMENTS",
                entitlements_path,
            ),
            f"project.pbxproj target {target_name} must reference {entitlements_path} in every configuration",
        )
    require(
        pbx_text.count("/* PrivacyInfo.xcprivacy */ = {isa = PBXFileReference;") >= 2,
        "project.pbxproj must contain distinct app and Share Extension privacy manifest references",
    )

    for path in (APP_ENTITLEMENTS, SHARE_ENTITLEMENTS):
        require(path.exists(), f"missing {path}")
    app_entitlements = plistlib.loads(APP_ENTITLEMENTS.read_bytes())
    share_entitlements = plistlib.loads(SHARE_ENTITLEMENTS.read_bytes())
    app_groups = set(app_entitlements.get("com.apple.security.application-groups", []))
    share_groups = set(share_entitlements.get("com.apple.security.application-groups", []))
    require("group.com.huangwei.singreadyai" in app_groups, "app target missing shared App Group")
    require(app_groups == share_groups, "app and Share Extension App Groups must match")

    built_products = os.environ.get("SINGREADY_BUILT_PRODUCTS_DIR", "").strip()
    if built_products:
        products_directory = Path(built_products).expanduser()
        require(products_directory.is_dir(), f"built products directory is missing: {products_directory}")
        bundled_manifest_errors = bundled_privacy_manifest_errors(products_directory)
        bundled_manifest_errors.extend(
            bundled_privacy_policy_errors(products_directory)
        )
        bundled_manifest_errors.extend(
            bundled_info_contract_errors(products_directory)
        )
        require(
            not bundled_manifest_errors,
            "built bundle privacy validation failed: " + "; ".join(bundled_manifest_errors),
        )

    print("Plist/privacy OK")


if __name__ == "__main__":
    main()
