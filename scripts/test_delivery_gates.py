#!/usr/bin/env python3
import contextlib
import io
import json
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

import validate_plist
import validate_docs
from screenshot_source_fingerprint import screenshot_source_digest


ROOT = Path(__file__).resolve().parents[1]
PRIVACY_RESOURCE = "SingReadyAI/App/PrivacyInfo.xcprivacy"


class PrivacyManifestValidationTests(unittest.TestCase):
    def test_required_reason_lookup_rejects_missing_file_timestamp_reason(self) -> None:
        accessed = [
            {
                "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
                "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
            }
        ]

        self.assertFalse(
            validate_plist.has_privacy_reason(
                accessed,
                "NSPrivacyAccessedAPICategoryFileTimestamp",
                "C617.1",
            )
        )

    def test_required_reason_lookup_accepts_file_timestamp_container_reason(self) -> None:
        accessed = [
            {
                "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp",
                "NSPrivacyAccessedAPITypeReasons": ["C617.1"],
            }
        ]

        self.assertTrue(
            validate_plist.has_privacy_reason(
                accessed,
                "NSPrivacyAccessedAPICategoryFileTimestamp",
                "C617.1",
            )
        )

    def test_project_resource_check_is_scoped_to_each_target(self) -> None:
        project = f"""targets:
  SingReadyAIApp:
    resources:
      - {PRIVACY_RESOURCE}
  SingReadyAIShareExtension:
    sources:
      - SingReadyAI/ShareExtension
"""

        self.assertTrue(
            validate_plist.project_target_has_resource(
                project,
                "SingReadyAIApp",
                PRIVACY_RESOURCE,
            )
        )
        self.assertFalse(
            validate_plist.project_target_has_resource(
                project,
                "SingReadyAIShareExtension",
                PRIVACY_RESOURCE,
            )
        )

    def test_pbx_resource_check_is_scoped_to_each_target_phase(self) -> None:
        pbx = """
		AAAA /* SingReadyAIApp */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				APPRES /* Resources */,
			);
		};
		BBBB /* SingReadyAIShareExtension */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				EXTRES /* Resources */,
			);
		};
		APPRES /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			files = (
				FILE1 /* PrivacyInfo.xcprivacy in Resources */,
			);
		};
		EXTRES /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			files = (
			);
		};
"""

        self.assertTrue(
            validate_plist.pbx_target_has_resource(
                pbx,
                "SingReadyAIApp",
                "PrivacyInfo.xcprivacy",
            )
        )
        self.assertFalse(
            validate_plist.pbx_target_has_resource(
                pbx,
                "SingReadyAIShareExtension",
                "PrivacyInfo.xcprivacy",
            )
        )

    def test_project_entitlements_setting_is_scoped_to_each_target(self) -> None:
        project = """targets:
  SingReadyAIApp:
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: SingReadyAI/App/SingReadyAI.entitlements
  SingReadyAIShareExtension:
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.huangwei.singreadyai.shareextension
"""

        self.assertTrue(
            validate_plist.project_target_has_setting(
                project,
                "SingReadyAIApp",
                "CODE_SIGN_ENTITLEMENTS",
                "SingReadyAI/App/SingReadyAI.entitlements",
            )
        )
        self.assertFalse(
            validate_plist.project_target_has_setting(
                project,
                "SingReadyAIShareExtension",
                "CODE_SIGN_ENTITLEMENTS",
                "SingReadyAI/ShareExtension/SingReadyAIShareExtension.entitlements",
            )
        )

    def test_pbx_entitlements_setting_requires_every_target_configuration(self) -> None:
        pbx = """
		AAAA /* SingReadyAIApp */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = APPCL /* Build configuration list for PBXNativeTarget "SingReadyAIApp" */;
		};
		BBBB /* SingReadyAIShareExtension */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = EXTCL /* Build configuration list for PBXNativeTarget "SingReadyAIShareExtension" */;
		};
		APPDEBUG /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_ENTITLEMENTS = SingReadyAI/App/SingReadyAI.entitlements;
			};
		};
		APPRELEASE /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_ENTITLEMENTS = SingReadyAI/App/SingReadyAI.entitlements;
			};
		};
		EXTDEBUG /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_ENTITLEMENTS = SingReadyAI/ShareExtension/SingReadyAIShareExtension.entitlements;
			};
		};
		EXTRELEASE /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
			};
		};
		APPCL /* Build configuration list for PBXNativeTarget "SingReadyAIApp" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				APPDEBUG /* Debug */,
				APPRELEASE /* Release */,
			);
		};
		EXTCL /* Build configuration list for PBXNativeTarget "SingReadyAIShareExtension" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				EXTDEBUG /* Debug */,
				EXTRELEASE /* Release */,
			);
		};
"""

        self.assertTrue(
            validate_plist.pbx_target_has_setting(
                pbx,
                "SingReadyAIApp",
                "CODE_SIGN_ENTITLEMENTS",
                "SingReadyAI/App/SingReadyAI.entitlements",
            )
        )
        self.assertFalse(
            validate_plist.pbx_target_has_setting(
                pbx,
                "SingReadyAIShareExtension",
                "CODE_SIGN_ENTITLEMENTS",
                "SingReadyAI/ShareExtension/SingReadyAIShareExtension.entitlements",
            )
        )

    def test_built_product_check_requires_manifest_in_app_and_embedded_extension(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory)
            app = products / "SingReadyAIApp.app"
            extension = app / "PlugIns/SingReadyAIShareExtension.appex"
            app.mkdir(parents=True)
            extension.mkdir(parents=True)
            (app / "PrivacyInfo.xcprivacy").write_text("manifest", encoding="utf-8")

            missing = validate_plist.missing_bundled_privacy_manifests(products)
            self.assertEqual(
                missing,
                [extension / "PrivacyInfo.xcprivacy"],
            )

            (extension / "PrivacyInfo.xcprivacy").write_text("manifest", encoding="utf-8")
            self.assertEqual(
                validate_plist.missing_bundled_privacy_manifests(products),
                [],
            )

    def test_built_product_check_rejects_stale_manifest_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory)
            app_manifest = products / "SingReadyAIApp.app/PrivacyInfo.xcprivacy"
            extension_manifest = (
                products
                / "SingReadyAIApp.app/PlugIns/SingReadyAIShareExtension.appex/PrivacyInfo.xcprivacy"
            )
            app_manifest.parent.mkdir(parents=True)
            extension_manifest.parent.mkdir(parents=True)
            app_manifest.write_bytes(
                self._privacy_manifest(
                    include_file_timestamp=True,
                    include_system_boot_time=True,
                )
            )
            extension_manifest.write_bytes(
                self._privacy_manifest(
                    include_file_timestamp=False,
                    include_system_boot_time=True,
                    include_user_defaults=False,
                )
            )

            errors = validate_plist.bundled_privacy_manifest_errors(products)
            self.assertTrue(any("C617.1" in error for error in errors))

            extension_manifest.write_bytes(
                self._privacy_manifest(
                    include_file_timestamp=True,
                    include_system_boot_time=True,
                    include_user_defaults=False,
                )
            )
            self.assertEqual(validate_plist.bundled_privacy_manifest_errors(products), [])

    def test_built_product_check_requires_system_boot_time_timer_reason(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory)
            app_manifest = products / "SingReadyAIApp.app/PrivacyInfo.xcprivacy"
            extension_manifest = (
                products
                / "SingReadyAIApp.app/PlugIns/SingReadyAIShareExtension.appex/PrivacyInfo.xcprivacy"
            )
            app_manifest.parent.mkdir(parents=True)
            extension_manifest.parent.mkdir(parents=True)
            app_manifest.write_bytes(
                self._privacy_manifest(
                    include_file_timestamp=True,
                    include_system_boot_time=False,
                )
            )
            extension_manifest.write_bytes(
                self._privacy_manifest(
                    include_file_timestamp=True,
                    include_system_boot_time=False,
                    include_user_defaults=False,
                )
            )

            errors = validate_plist.bundled_privacy_manifest_errors(products)

            self.assertTrue(any("35F9.1" in error for error in errors))

    def test_built_product_check_requires_current_offline_privacy_policy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory)
            app_policy = products / "SingReadyAIApp.app/PRIVACY.md"

            errors = validate_plist.bundled_privacy_policy_errors(products)
            self.assertTrue(any("missing" in error for error in errors))

            app_policy.parent.mkdir(parents=True)
            app_policy.write_text("stale policy", encoding="utf-8")
            errors = validate_plist.bundled_privacy_policy_errors(products)
            self.assertTrue(any("does not match" in error for error in errors))

            app_policy.write_bytes((ROOT / "PRIVACY.md").read_bytes())
            self.assertEqual(
                validate_plist.bundled_privacy_policy_errors(products),
                [],
            )

    def test_built_product_check_requires_current_app_and_extension_info_contracts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory)
            app_info = products / "SingReadyAIApp.app/Info.plist"
            extension_info = (
                products
                / "SingReadyAIApp.app/PlugIns/SingReadyAIShareExtension.appex/Info.plist"
            )
            app_info.parent.mkdir(parents=True)
            extension_info.parent.mkdir(parents=True)
            app_info.write_bytes(plistlib.dumps({"CFBundleDisplayName": "今晚唱什么"}))

            errors = validate_plist.bundled_info_contract_errors(products)
            self.assertTrue(any("NSMicrophoneUsageDescription" in error for error in errors))
            self.assertTrue(any("missing" in error and "appex/Info.plist" in error for error in errors))

            app_info.write_bytes(
                plistlib.dumps(
                    {
                        "CFBundleDisplayName": "今晚唱什么",
                        "CFBundleIdentifier": "com.huangwei.singreadyai",
                        "CFBundleIcons": {
                            "CFBundlePrimaryIcon": {
                                "CFBundleIconName": "AppIcon",
                            }
                        },
                        "MinimumOSVersion": "17.0",
                        "NSMicrophoneUsageDescription": "录音用途",
                        "NSPhotoLibraryAddUsageDescription": "相册用途",
                        "UIDeviceFamily": [1],
                        "UILaunchStoryboardName": "LaunchScreen",
                        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
                    }
                )
            )
            extension_contract = {
                "CFBundleDisplayName": "今晚唱什么",
                "CFBundleIdentifier": "com.huangwei.singreadyai.shareextension",
                "MinimumOSVersion": "17.0",
                "UIDeviceFamily": [1],
                "NSExtension": {
                    "NSExtensionPointIdentifier": "com.apple.share-services",
                    "NSExtensionPrincipalClass": "SingReadyAIShareExtension.ShareViewController",
                    "NSExtensionAttributes": {
                        "NSExtensionActivationRule": {
                            "NSExtensionActivationSupportsImageWithMaxCount": 1,
                            "NSExtensionActivationSupportsText": True,
                            "NSExtensionActivationSupportsWebURLWithMaxCount": 1,
                        }
                    },
                },
            }
            extension_info.write_bytes(plistlib.dumps(extension_contract))

            self.assertEqual(validate_plist.bundled_info_contract_errors(products), [])

            extension_contract["NSExtension"]["NSExtensionPrincipalClass"] = "WrongClass"
            extension_info.write_bytes(plistlib.dumps(extension_contract))
            errors = validate_plist.bundled_info_contract_errors(products)
            self.assertTrue(any("NSExtensionPrincipalClass" in error for error in errors))

    def test_extension_manifest_rejects_app_only_user_defaults_reason(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory)
            app_manifest = products / "SingReadyAIApp.app/PrivacyInfo.xcprivacy"
            extension_manifest = (
                products
                / "SingReadyAIApp.app/PlugIns/SingReadyAIShareExtension.appex/PrivacyInfo.xcprivacy"
            )
            app_manifest.parent.mkdir(parents=True)
            extension_manifest.parent.mkdir(parents=True)
            app_manifest.write_bytes(
                self._privacy_manifest(
                    include_user_defaults=True,
                    include_file_timestamp=True,
                    include_system_boot_time=True,
                )
            )
            extension_manifest.write_bytes(
                self._privacy_manifest(
                    include_user_defaults=True,
                    include_file_timestamp=True,
                    include_system_boot_time=True,
                )
            )

            errors = validate_plist.bundled_privacy_manifest_errors(products)

            self.assertTrue(any("must not declare UserDefaults" in error for error in errors))

    @staticmethod
    def _privacy_manifest(
        include_file_timestamp: bool,
        include_system_boot_time: bool,
        include_user_defaults: bool = True,
    ) -> bytes:
        accessed = []
        if include_user_defaults:
            accessed.append(
                {
                    "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
                    "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
                }
            )
        if include_file_timestamp:
            accessed.append(
                {
                    "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp",
                    "NSPrivacyAccessedAPITypeReasons": ["C617.1"],
                }
            )
        if include_system_boot_time:
            accessed.append(
                {
                    "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategorySystemBootTime",
                    "NSPrivacyAccessedAPITypeReasons": ["35F9.1"],
                }
            )
        return plistlib.dumps(
            {
                "NSPrivacyTracking": False,
                "NSPrivacyCollectedDataTypes": [],
                "NSPrivacyAccessedAPITypes": accessed,
            }
        )


class DocumentationFactGateTests(unittest.TestCase):
    def test_live_document_fact_validation_rejects_stale_counts_and_generic_web_claims(self) -> None:
        documents = {
            "README.md": "Swift Package：`345/345` 通过。公开 HTTPS 静态内容做最佳努力读取。",
            "docs/QUALITY_AUDIT.md": "完整 UI 回归：`106/106` 通过。",
        }

        errors = validate_docs.validate_live_document_facts(
            documents,
            swift_count=363,
            ui_count=108,
        )

        self.assertTrue(any("345/345" in error for error in errors))
        self.assertTrue(any("106/106" in error for error in errors))
        self.assertTrue(any("通用网页" in error for error in errors))

    def test_live_document_fact_validation_accepts_current_supported_platform_boundary(self) -> None:
        documents = {
            "README.md": "Swift Package：`363/363` 通过。",
            "docs/QUALITY_AUDIT.md": (
                "完整 UI 回归：`108/108` 通过。"
                "只有 Apple Music 与网易云官方公开链接会被直接读取；"
                "QQ 音乐与其他网页改用分享原文或截图。"
            ),
        }

        self.assertEqual(
            validate_docs.validate_live_document_facts(
                documents,
                swift_count=363,
                ui_count=108,
            ),
            [],
        )

    def test_live_document_fact_validation_does_not_treat_focused_system_count_as_full_ui_count(self) -> None:
        documents = {
            "FINAL_REPORT.md": (
                "当前完整 UI 套件已覆盖系统分享；"
                "iOS 模拟器系统能力聚焦回归 `6/6`。"
            ),
        }

        self.assertEqual(
            validate_docs.validate_live_document_facts(
                documents,
                swift_count=363,
                ui_count=108,
            ),
            [],
        )

    def test_source_test_counts_match_current_swift_and_ui_declarations(self) -> None:
        self.assertEqual(validate_docs.source_test_counts(ROOT), (363, 108))

    def test_source_test_counts_scan_recursively_and_only_count_xctest_methods(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = {
                "Tests/TopTests.swift": """
func testAlpha() {}
func test_underscore() async throws {}
func test9Lives() throws {}
func testingHelper() {}
func testwithLowercase() {}
func test中文名称() {}
func testNeedsInput(_ value: Int) {}
""",
                "Tests/Feature/NestedTests.swift": """
    func testNested() async {}
""",
                "UITests/SmokeTests.swift": """
func testLaunch() {}
func testingSnapshot() {}
""",
                "UITests/Flows/MoreTests.swift": """
func testFlow_2() async throws {}
func testParameterized(value: Int) {}
""",
            }
            for relative_path, source in sources.items():
                path = root / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source, encoding="utf-8")

            self.assertEqual(validate_docs.source_test_counts(root), (5, 2))

    def test_report_fact_validation_rejects_stale_counts_and_screenshot_claim(self) -> None:
        report = """
- Swift Package：`345/345` 通过。
- 完整 UI 回归：`106/106` 通过。
- 截图来源指纹、命名与尺寸校验通过。
"""

        errors = validate_docs.validate_report_facts(
            report,
            swift_count=363,
            ui_count=108,
            screenshots_current=False,
        )

        self.assertEqual(len(errors), 3)
        self.assertTrue(any("Swift Package" in error and "363/363" in error for error in errors))
        self.assertTrue(any("UI" in error and "108/108" in error for error in errors))
        self.assertTrue(any("截图" in error and "来源指纹" in error for error in errors))

    def test_report_fact_validation_accepts_current_counts_and_screenshots(self) -> None:
        report = """
- Swift Package：`363/363` 通过。
- 完整 UI 回归：`108/108` 通过。
- 截图来源指纹、命名与尺寸校验通过。
"""

        self.assertEqual(
            validate_docs.validate_report_facts(
                report,
                swift_count=363,
                ui_count=108,
                screenshots_current=True,
            ),
            [],
        )

    def test_report_fact_validation_anchors_ui_count_to_full_regression_label(self) -> None:
        report = """
- Swift Package：`363/363` 通过。
- UI 截图：`11/11` 通过。
- 完整 UI 回归：`108/108` 通过。
- 截图来源指纹、命名与尺寸校验通过。
"""

        self.assertEqual(
            validate_docs.validate_report_facts(
                report,
                swift_count=363,
                ui_count=108,
                screenshots_current=True,
            ),
            [],
        )

    def test_docs_validator_rejects_stale_fixture_report_and_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_report_fixture(
                root,
                swift_claim="0/0",
                ui_claim="0/0",
                metadata_digest="stale-digest",
            )
            stderr = io.StringIO()

            with contextlib.redirect_stderr(stderr):
                result = validate_docs.main(root)

            self.assertEqual(result, 1)
            output = stderr.getvalue()
            self.assertIn("expected 1/1", output)
            self.assertIn("截图来源指纹", output)

    def test_docs_validator_accepts_current_fixture_report_and_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_report_fixture(
                root,
                swift_claim="1/1",
                ui_claim="1/1",
                metadata_digest=None,
            )

            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(validate_docs.main(root), 0)

    @staticmethod
    def _write_report_fixture(
        root: Path,
        swift_claim: str,
        ui_claim: str,
        metadata_digest: str | None,
    ) -> None:
        swift_test = root / "Tests/Feature/FeatureTests.swift"
        ui_test = root / "UITests/Flow/FlowTests.swift"
        swift_test.parent.mkdir(parents=True)
        ui_test.parent.mkdir(parents=True)
        swift_test.write_text("func testFeature() {}\n", encoding="utf-8")
        ui_test.write_text("func testFlow() {}\n", encoding="utf-8")
        (root / "FINAL_REPORT.md").write_text(
            f"""
- Swift Package：`{swift_claim}` 通过。
- 完整 UI 回归：`{ui_claim}` 通过。
- 截图来源指纹、命名与尺寸校验通过。
""",
            encoding="utf-8",
        )
        current_digest = screenshot_source_digest(root)
        metadata = json.dumps(
            {"source_tree_sha256": metadata_digest or current_digest},
            ensure_ascii=False,
        )
        for relative_path in (
            "docs/screenshots/capture-metadata.json",
            "docs/screenshots-large-text/capture-metadata.json",
        ):
            path = root / relative_path
            path.parent.mkdir(parents=True)
            path.write_text(metadata, encoding="utf-8")


class DeliveryWorkflowTests(unittest.TestCase):
    def test_test_launch_hooks_are_excluded_from_release_sources(self) -> None:
        release_visible_hooks: list[str] = []
        for path in sorted((ROOT / "SingReadyAI").rglob("*.swift")):
            relative_path = path.relative_to(ROOT)
            for line_number, hook in self._release_visible_test_hooks(
                path.read_text(encoding="utf-8")
            ):
                release_visible_hooks.append(f"{relative_path}:{line_number}:{hook}")

        self.assertEqual(release_visible_hooks, [])

    def test_demo_launch_fixture_is_entirely_debug_only(self) -> None:
        source = (ROOT / "SingReadyAI/App/DemoWorkflowStore+DemoLaunch.swift").read_text(
            encoding="utf-8"
        ).strip()

        self.assertTrue(source.startswith("#if DEBUG\n"))
        self.assertTrue(source.endswith("\n#endif"))

    def test_release_artifact_validator_accepts_a_clean_bundle(self) -> None:
        result = self._run_release_validator(self._valid_release_bundle_files())

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_release_artifact_validator_rejects_wrong_app_identifier(self) -> None:
        files = self._valid_release_bundle_files()
        files["Info.plist"] = self._release_info("org.wrong.product")

        result = self._run_release_validator(files)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected app bundle identifier com.huangwei.singreadyai", result.stdout + result.stderr)

    def test_release_artifact_validator_requires_embedded_share_extension(self) -> None:
        files = {
            path: contents
            for path, contents in self._valid_release_bundle_files().items()
            if not path.startswith("PlugIns/")
        }

        result = self._run_release_validator(files)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing embedded Share Extension", result.stdout + result.stderr)

    def test_release_artifact_validator_rejects_wrong_extension_identifier(self) -> None:
        files = self._valid_release_bundle_files()
        files["PlugIns/SingReadyAIShareExtension.appex/Info.plist"] = self._release_info(
            "org.wrong.shareextension"
        )

        result = self._run_release_validator(files)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "expected Share Extension bundle identifier com.huangwei.singreadyai.shareextension",
            result.stdout + result.stderr,
        )

    def test_release_artifact_validator_rejects_extension_version_mismatch(self) -> None:
        files = self._valid_release_bundle_files()
        files["PlugIns/SingReadyAIShareExtension.appex/Info.plist"] = self._release_info(
            "com.huangwei.singreadyai.shareextension",
            marketing_version="1.1",
            build_version="2",
        )

        result = self._run_release_validator(files)

        self.assertNotEqual(result.returncode, 0)
        combined_output = result.stdout + result.stderr
        self.assertIn("Share Extension marketing version 1.1 does not match app 1.0", combined_output)
        self.assertIn("Share Extension build version 2 does not match app 1", combined_output)

    def test_release_artifact_validator_rejects_test_launch_hooks(self) -> None:
        result = self._run_release_validator(
            {"SingReadyAIApp": b"binary-prefix-singreadySimulatedRecording-suffix"}
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("-singreadySimulatedRecording", result.stdout + result.stderr)

    def test_release_artifact_validator_rejects_placeholder_identifiers(self) -> None:
        result = self._run_release_validator(
            {"Info.plist": b"com.example.SingReadyAI"}
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("com.example", result.stdout + result.stderr)

    def test_main_validation_builds_and_checks_a_warnings_as_errors_release(self) -> None:
        script = (ROOT / "scripts/validate.sh").read_text(encoding="utf-8")

        self.assertIn(
            'VALIDATION_PRODUCTS_DIR="$VALIDATION_DERIVED_DATA/Build/Products/Release-iphonesimulator"',
            script,
        )
        self.assertIn("-configuration Release", script)
        self.assertIn("SWIFT_TREAT_WARNINGS_AS_ERRORS=YES", script)
        self.assertIn("scripts/validate_release.py", script)

    def test_release_contract_uses_simplified_chinese_development_region(self) -> None:
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        pbx = (ROOT / "SingReadyAI.xcodeproj/project.pbxproj").read_text(encoding="utf-8")

        self.assertIn("developmentLanguage: zh-Hans", project)
        self.assertIn('developmentRegion = "zh-Hans";', pbx)
        self.assertRegex(pbx, r"knownRegions = \([^)]*\"zh-Hans\"")

    def test_share_extension_versions_inherit_target_build_settings(self) -> None:
        info = plistlib.loads(
            (ROOT / "SingReadyAI/ShareExtension/Info.plist").read_bytes()
        )

        self.assertEqual(info.get("CFBundleShortVersionString"), "$(MARKETING_VERSION)")
        self.assertEqual(info.get("CFBundleVersion"), "$(CURRENT_PROJECT_VERSION)")

    def test_targets_package_distinct_privacy_manifests(self) -> None:
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        app_manifest = plistlib.loads(
            (ROOT / "SingReadyAI/App/PrivacyInfo.xcprivacy").read_bytes()
        )
        extension_manifest_path = ROOT / "SingReadyAI/ShareExtension/PrivacyInfo.xcprivacy"

        self.assertIn("- SingReadyAI/App/PrivacyInfo.xcprivacy", project)
        self.assertIn("- SingReadyAI/ShareExtension/PrivacyInfo.xcprivacy", project)
        self.assertTrue(extension_manifest_path.is_file())
        extension_manifest = plistlib.loads(extension_manifest_path.read_bytes())
        app_accessed = app_manifest.get("NSPrivacyAccessedAPITypes", [])
        extension_accessed = extension_manifest.get("NSPrivacyAccessedAPITypes", [])
        self.assertTrue(
            validate_plist.has_privacy_reason(
                app_accessed,
                "NSPrivacyAccessedAPICategoryUserDefaults",
                "CA92.1",
            )
        )
        self.assertFalse(
            validate_plist.has_privacy_reason(
                extension_accessed,
                "NSPrivacyAccessedAPICategoryUserDefaults",
                "CA92.1",
            )
        )
        for api_type, reason in (
            ("NSPrivacyAccessedAPICategoryFileTimestamp", "C617.1"),
            ("NSPrivacyAccessedAPICategorySystemBootTime", "35F9.1"),
        ):
            self.assertTrue(validate_plist.has_privacy_reason(extension_accessed, api_type, reason))

    def test_app_bundles_the_offline_privacy_policy_without_the_old_remote_url(self) -> None:
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        pbx = (ROOT / "SingReadyAI.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        home = (
            ROOT / "SingReadyAI/Features/ProductFlow/HomeDashboardView.swift"
        ).read_text(encoding="utf-8")

        self.assertTrue((ROOT / "PRIVACY.md").is_file())
        self.assertTrue(
            validate_plist.project_target_has_resource(
                project,
                "SingReadyAIApp",
                "PRIVACY.md",
            )
        )
        self.assertTrue(
            validate_plist.pbx_target_has_resource(
                pbx,
                "SingReadyAIApp",
                "PRIVACY.md",
            )
        )
        self.assertNotIn(
            "https://github.com/RomanticHW/SingReadyAI/blob/main/PRIVACY.md",
            home,
        )

    def test_privacy_policy_discloses_each_user_triggered_apple_search_path(self) -> None:
        policy = (ROOT / "PRIVACY.md").read_text(encoding="utf-8")

        self.assertIn("只发送歌手名称", policy)
        self.assertIn("Apple Music 搜索", policy)
        self.assertIn("歌名和歌手", policy)

    def test_standalone_voice_and_feedback_cannot_be_rolled_back_by_stale_snapshot(self) -> None:
        store = (ROOT / "SingReadyAI/App/DemoWorkflowStore.swift").read_text(encoding="utf-8")
        persistence = (
            ROOT / "SingReadyAI/App/DemoWorkflowStore+Persistence.swift"
        ).read_text(encoding="utf-8")
        feedback_store = (
            ROOT / "SingReadyAI/App/Services/SongFeedbackLocalStore.swift"
        ).read_text(encoding="utf-8")
        shared_models = (
            ROOT / "Sources/SingReadyAISharedKit/Models/Models.swift"
        ).read_text(encoding="utf-8")
        shared_storage = (
            ROOT / "Sources/SingReadyAISharedKit/Storage/WorkflowSnapshotStore.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("loadWithStatus()", store)
        self.assertIn("hasStandaloneFeedbackRecord", store)
        self.assertIn("SongFeedbackRestorePolicy.preferred", persistence)
        self.assertIn("SongFeedbackRestorePolicy.shouldRefreshPlan", persistence)
        self.assertIn("shouldRefreshPlanForFeedback", persistence)
        self.assertIn("generatePlan(navigate: false, schedulesPersistence: false)", persistence)
        self.assertIn("save(.empty)", feedback_store)
        self.assertNotIn("removeObject(forKey: key)", feedback_store)
        self.assertIn("standalone ?? snapshot", shared_models)

        self.assertIn("VoiceProfileRestorePolicy.preferred", persistence)
        self.assertIn("standaloneMigrationCandidate(current: voiceProfile)", persistence)
        self.assertIn("saveIfEligible(migrationCandidate)", persistence)
        self.assertIn("standalone.createdAt >= current.createdAt", shared_storage)
        self.assertNotIn(
            "voiceProfile?.hasValidMeasuredRange != true else { return }",
            persistence,
        )

    def test_python_cache_artifacts_are_ignored(self) -> None:
        gitignore = (ROOT / ".gitignore").read_text(encoding="utf-8")

        self.assertIn("__pycache__/", gitignore)
        self.assertIn("*.pyc", gitignore)

    def test_main_validation_runs_ios_units_and_device_sdk_release(self) -> None:
        script = (ROOT / "scripts/validate.sh").read_text(encoding="utf-8")

        self.assertIn("-only-testing:SingReadyAITests", script)
        self.assertIn("generic/platform=iOS'", script)
        self.assertIn("VALIDATION_DEVICE_DERIVED_DATA", script)
        self.assertIn("SWIFT_TREAT_WARNINGS_AS_ERRORS=YES", script)

    def test_real_device_test_targets_use_the_product_development_team(self) -> None:
        project_spec = (ROOT / "project.yml").read_text(encoding="utf-8")
        generated_project = (ROOT / "SingReadyAI.xcodeproj/project.pbxproj").read_text(
            encoding="utf-8"
        )

        for target_name in ("SingReadyAITests", "SingReadyAIUITests"):
            match = re.search(
                rf"(?ms)^  {target_name}:\n(?P<body>.*?)(?=^  \S|\Z)",
                project_spec,
            )
            self.assertIsNotNone(match, f"missing {target_name} in project.yml")
            target_body = match.group("body")
            self.assertIn("CODE_SIGN_STYLE: Automatic", target_body)
            self.assertIn("DEVELOPMENT_TEAM: 7UGQ23VSF7", target_body)

        self.assertEqual(generated_project.count("CODE_SIGN_STYLE = Automatic;"), 8)
        self.assertEqual(generated_project.count("DEVELOPMENT_TEAM = 7UGQ23VSF7;"), 8)

    def test_release_identifiers_use_the_product_namespace_in_every_contract(self) -> None:
        expected_app_id = "com.huangwei.singreadyai"
        expected_group_id = "group.com.huangwei.singreadyai"
        text_contracts = {
            relative_path: (ROOT / relative_path).read_text(encoding="utf-8")
            for relative_path in (
                "project.yml",
                "SingReadyAI.xcodeproj/project.pbxproj",
                "SingReadyAI/App/SingReadyAI.entitlements",
                "SingReadyAI/ShareExtension/SingReadyAIShareExtension.entitlements",
                "Sources/SingReadyAISharedKit/Storage/AppGroupStore.swift",
                "scripts/capture_screenshots.sh",
                "scripts/validate_plist.py",
                "ShareExtensionREADME.md",
            )
        }

        for relative_path, text in text_contracts.items():
            with self.subTest(path=relative_path):
                self.assertNotIn("com.example", text)
        self.assertIn(f"PRODUCT_BUNDLE_IDENTIFIER: {expected_app_id}", text_contracts["project.yml"])
        self.assertIn(expected_group_id, text_contracts["SingReadyAI/App/SingReadyAI.entitlements"])
        self.assertIn(
            expected_group_id,
            text_contracts["SingReadyAI/ShareExtension/SingReadyAIShareExtension.entitlements"],
        )
        self.assertIn(expected_group_id, text_contracts["Sources/SingReadyAISharedKit/Storage/AppGroupStore.swift"])

    def test_photo_picker_uses_bounded_file_transfer_instead_of_loading_full_data(self) -> None:
        import_flow = (ROOT / "SingReadyAI/Features/ProductFlow/ImportFlowViews.swift").read_text(
            encoding="utf-8"
        )

        self.assertRegex(
            import_flow,
            r"loadTransferable\(\s*type:\s*ImportedScreenshotFile\.self\s*\)",
        )
        self.assertNotIn("loadTransferable(type: Data.self)", import_flow)

    def test_review_matching_uses_the_cancellable_background_analysis_executor(self) -> None:
        store_source = (ROOT / "SingReadyAI/App/DemoWorkflowStore.swift").read_text(
            encoding="utf-8"
        )
        import_source = (ROOT / "SingReadyAI/App/DemoWorkflowStore+Import.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn("let playlistAnalysisExecutor = PlaylistAnalysisExecutor()", store_source)
        self.assertIn("await playlistAnalysisExecutor.analyze", import_source)
        self.assertNotIn("matches = matcher.match(playlist:", import_source)

    def test_result_track_identity_reflows_at_accessibility_text_sizes(self) -> None:
        result_source = (
            ROOT / "SingReadyAI/Features/ProductFlow/ResultExportStartTipsViews.swift"
        ).read_text(encoding="utf-8")
        detail_source = (
            ROOT / "SingReadyAI/Features/ProductFlow/SongFitDetailViews.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("dynamicTypeSize.isAccessibilitySize", result_source)
        self.assertIn("accessibilityTrackIdentity", result_source)
        self.assertIn(".frame(minHeight: 34)", detail_source)
        self.assertNotIn(".frame(height: 34)", detail_source)

    def test_onboarding_focus_and_source_badges_support_accessibility_sizes(self) -> None:
        onboarding_source = (
            ROOT / "SingReadyAI/Features/ProductFlow/OnboardingView.swift"
        ).read_text(encoding="utf-8")
        metrics_source = (
            ROOT / "SingReadyAI/App/DesignSystem/DesignSystemMetrics.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("@AccessibilityFocusState", onboarding_source)
        self.assertIn(".accessibilityFocused", onboarding_source)
        self.assertIn("onboarding-page-", onboarding_source)
        self.assertIn(".frame(minHeight: 28)", metrics_source)
        self.assertNotIn(".frame(height: 28)", metrics_source)

    def test_local_data_clear_waits_for_cancelled_voice_work_before_file_clear(self) -> None:
        import_source = (
            ROOT / "SingReadyAI/App/DemoWorkflowStore+Import.swift"
        ).read_text(encoding="utf-8")

        capture = import_source.index("let inFlightVoiceRecording = voiceRecordingTask")
        cancel = import_source.index("cancelVoiceRecording()", capture)
        await_completion = import_source.index("await inFlightVoiceRecording?.value", cancel)
        clear_file = import_source.index("voiceProfileStore.clear()", await_completion)
        self.assertLess(capture, cancel)
        self.assertLess(cancel, await_completion)
        self.assertLess(await_completion, clear_file)

    def test_pending_import_reload_cannot_repopulate_ui_during_clear(self) -> None:
        import_source = (
            ROOT / "SingReadyAI/App/DemoWorkflowStore+Import.swift"
        ).read_text(encoding="utf-8")
        start = import_source.index("func loadPendingImports() async")
        end = import_source.index("func loadRecentPlaylists", start)
        load_body = import_source[start:end]

        self.assertGreaterEqual(load_body.count("!isManagingLocalData"), 3)
        self.assertIn("acceptsLocalDataEpoch(epoch)", load_body)

    def test_pending_import_refresh_uses_latest_request_and_invalidates_after_mutation(self) -> None:
        store_source = (ROOT / "SingReadyAI/App/DemoWorkflowStore.swift").read_text(encoding="utf-8")
        import_source = (
            ROOT / "SingReadyAI/App/DemoWorkflowStore+Import.swift"
        ).read_text(encoding="utf-8")
        load_start = import_source.index("func loadPendingImports() async")
        load_end = import_source.index("func loadRecentPlaylists", load_start)
        load_body = import_source[load_start:load_end]

        self.assertIn("pendingImportPersistenceGate", store_source)
        self.assertIn("pendingImportPersistenceGate.begin()", load_body)
        self.assertGreaterEqual(load_body.count("pendingImportPersistenceGate.accepts(request)"), 3)
        self.assertGreaterEqual(import_source.count("pendingImportPersistenceGate.invalidate()"), 3)

    def test_ui_scripts_run_xcodebuild_on_the_configured_simulator_udid(self) -> None:
        for relative_path in (
            "scripts/run_ui_tests.sh",
            "scripts/capture_ui_test_screenshots.sh",
        ):
            with self.subTest(path=relative_path):
                script = (ROOT / relative_path).read_text(encoding="utf-8")
                self.assertIn('-destination "id=$SIMULATOR_UDID"', script)

    def test_ui_scripts_clear_legacy_and_current_simulator_installations(self) -> None:
        cleanup_path = ROOT / "scripts/clean_simulator_installations.sh"
        self.assertTrue(cleanup_path.is_file())
        cleanup_script = cleanup_path.read_text(encoding="utf-8")
        for bundle_identifier in (
            "com.example.SingReadyAI",
            "com.example.SingReadyAI.UITests.xctrunner",
            "com.huangwei.singreadyai",
            "com.huangwei.singreadyai.uitests.xctrunner",
        ):
            with self.subTest(bundle_identifier=bundle_identifier):
                self.assertIn(bundle_identifier, cleanup_script)

        entry_points = {
            "scripts/run_ui_tests.sh": "xcodebuild test",
            "scripts/capture_ui_test_screenshots.sh": "xcodebuild test",
            "scripts/capture_screenshots.sh": "xcrun simctl install",
        }
        for relative_path, next_action in entry_points.items():
            with self.subTest(path=relative_path):
                script = (ROOT / relative_path).read_text(encoding="utf-8")
                boot_complete = script.index("xcrun simctl bootstatus")
                cleanup = script.index("scripts/clean_simulator_installations.sh")
                action = script.index(next_action, cleanup)
                self.assertLess(boot_complete, cleanup)
                self.assertLess(cleanup, action)

    def test_settings_actions_use_the_supported_system_settings_url(self) -> None:
        source = "\n".join(
            (ROOT / relative_path).read_text(encoding="utf-8")
            for relative_path in (
                "SingReadyAI/Features/ProductFlow/VoiceAndPreferenceViews.swift",
                "SingReadyAI/Features/ProductFlow/ExportStartTipsViews.swift",
            )
        )

        self.assertNotIn('URL(string: "app-settings:")', source)
        self.assertGreaterEqual(source.count("UIApplication.openSettingsURLString"), 2)

    def test_project_generation_precedes_screenshot_freshness_gate(self) -> None:
        script = (ROOT / "scripts/validate.sh").read_text(encoding="utf-8")

        self.assertLess(
            script.index('run_required "xcodegen generate"'),
            script.index('run_required "screenshot evidence validation"'),
        )

    def test_project_generation_uses_cache_in_validation_and_capture(self) -> None:
        validation_script = (ROOT / "scripts/validate.sh").read_text(encoding="utf-8")
        capture_script = (ROOT / "scripts/capture_ui_test_screenshots.sh").read_text(encoding="utf-8")

        self.assertIn('run_required "xcodegen generate" xcodegen generate --use-cache', validation_script)
        self.assertIn("xcodegen generate --use-cache", capture_script)

    def test_screenshot_metadata_binds_evidence_to_the_source_tree(self) -> None:
        capture_script = (
            ROOT / "scripts/capture_ui_test_screenshots.sh"
        ).read_text(encoding="utf-8")
        validation_script = (
            ROOT / "scripts/validate_screenshots.py"
        ).read_text(encoding="utf-8")

        self.assertIn('"source_tree_sha256": screenshot_source_digest', capture_script)
        self.assertIn('metadata.get("source_tree_sha256")', validation_script)

    def test_screenshot_source_digest_changes_when_ui_source_changes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "SingReadyAI/Feature.swift"
            source.parent.mkdir(parents=True)
            source.write_text("struct Feature {}\n", encoding="utf-8")
            first_digest = screenshot_source_digest(root)

            source.write_text("struct Feature { let value = 1 }\n", encoding="utf-8")
            second_digest = screenshot_source_digest(root)
            self.assertNotEqual(first_digest, second_digest)

            (root / "PRIVACY.md").write_text("隐私政策正文\n", encoding="utf-8")
            privacy_digest = screenshot_source_digest(root)
            self.assertNotEqual(second_digest, privacy_digest)

            (root / "README.md").write_text("文档变化\n", encoding="utf-8")
            self.assertEqual(privacy_digest, screenshot_source_digest(root))

    def test_validation_build_checks_bundled_privacy_manifests(self) -> None:
        script = (ROOT / "scripts/validate.sh").read_text(encoding="utf-8")

        self.assertIn("SINGREADY_BUILT_PRODUCTS_DIR", script)
        self.assertIn("built app and Share Extension privacy manifest validation", script)

    def test_main_validation_runs_delivery_gate_regressions(self) -> None:
        script = (ROOT / "scripts/validate.sh").read_text(encoding="utf-8")

        self.assertIn("delivery gate regression tests", script)
        self.assertIn("scripts/test_delivery_gates.py", script)

    def test_delivery_docs_show_both_screenshot_capture_commands(self) -> None:
        for relative_path in ("README.md", "FINAL_REPORT.md", "docs/VISUAL_QA.md"):
            with self.subTest(path=relative_path):
                text = (ROOT / relative_path).read_text(encoding="utf-8")
                self.assertIn("CONTENT_SIZE=large", text)
                self.assertIn("SCREENSHOT_DIR=docs/screenshots", text)
                self.assertIn("CONTENT_SIZE=accessibility-extra-extra-extra-large", text)
                self.assertIn("SCREENSHOT_DIR=docs/screenshots-large-text", text)

    def test_docs_validator_scans_every_delivery_markdown_file(self) -> None:
        paths = validate_docs.documentation_paths(ROOT)

        self.assertIn(ROOT / "README.md", paths)
        self.assertIn(ROOT / "FINAL_REPORT.md", paths)
        self.assertIn(ROOT / "PRIVACY.md", paths)
        self.assertIn(ROOT / "docs/QUALITY_AUDIT.md", paths)
        self.assertIn(ROOT / "docs/VISUAL_QA.md", paths)

    @staticmethod
    def _release_visible_test_hooks(source: str) -> list[tuple[int, str]]:
        frames: list[dict[str, object]] = []
        hooks: list[tuple[int, str]] = []
        hook_pattern = re.compile(r"-singready[A-Z][A-Za-z0-9]*")

        for line_number, line in enumerate(source.splitlines(), start=1):
            directive = line.strip()
            if directive.startswith("#if "):
                condition = directive[4:].strip()
                frames.append(
                    {
                        "condition": condition,
                        "excluded": condition == "DEBUG",
                    }
                )
                continue
            if directive.startswith("#elseif "):
                if frames:
                    condition = directive[8:].strip()
                    frames[-1]["excluded"] = condition == "DEBUG"
                continue
            if directive == "#else":
                if frames:
                    condition = frames[-1]["condition"]
                    if condition == "DEBUG":
                        frames[-1]["excluded"] = False
                    elif condition == "!DEBUG":
                        frames[-1]["excluded"] = True
                continue
            if directive == "#endif":
                if frames:
                    frames.pop()
                continue

            if any(bool(frame["excluded"]) for frame in frames):
                continue
            hooks.extend(
                (line_number, match.group(0))
                for match in hook_pattern.finditer(line)
            )

        return hooks

    def _run_release_validator(
        self,
        files: dict[str, bytes],
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            app_bundle = Path(directory) / "SingReadyAIApp.app"
            app_bundle.mkdir()
            for relative_path, contents in files.items():
                destination = app_bundle / relative_path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(contents)
            return subprocess.run(
                [sys.executable, str(ROOT / "scripts/validate_release.py"), str(app_bundle)],
                capture_output=True,
                check=False,
                text=True,
            )

    @staticmethod
    def _release_info(
        bundle_identifier: str,
        marketing_version: str = "1.0",
        build_version: str = "1",
    ) -> bytes:
        return plistlib.dumps(
            {
                "CFBundleIdentifier": bundle_identifier,
                "CFBundleShortVersionString": marketing_version,
                "CFBundleVersion": build_version,
            }
        )

    @classmethod
    def _valid_release_bundle_files(cls) -> dict[str, bytes]:
        return {
            "Info.plist": cls._release_info("com.huangwei.singreadyai"),
            "SingReadyAIApp": b"release executable",
            "PlugIns/SingReadyAIShareExtension.appex/Info.plist": cls._release_info(
                "com.huangwei.singreadyai.shareextension"
            ),
            "PlugIns/SingReadyAIShareExtension.appex/SingReadyAIShareExtension": (
                b"release extension executable"
            ),
        }


if __name__ == "__main__":
    unittest.main()
