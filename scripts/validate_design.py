#!/usr/bin/env python3
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DESIGN_DIR = ROOT / "SingReadyAI/App/DesignSystem"
REQUIRED_TOKEN_FILES = [
    "AppTheme.swift",
    "ColorTokens.swift",
    "TypographyTokens.swift",
    "SpacingTokens.swift",
    "MotionTokens.swift",
    "ComponentTokens.swift",
]


def png_dimensions(path: Path) -> tuple[int, int]:
    with path.open("rb") as image:
        signature = image.read(24)
    if len(signature) < 24 or signature[:8] != b"\x89PNG\r\n\x1a\n":
        fail(f"{path.relative_to(ROOT)} is not a valid PNG")
    return struct.unpack(">II", signature[16:24])


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def warn(message: str) -> None:
    print(f"WARN: {message}")


def extract_struct(text: str, struct_name: str) -> str:
    marker = f"struct {struct_name}"
    start = text.find(marker)
    if start == -1:
        fail(f"{struct_name} is missing")
    brace = text.find("{", start)
    if brace == -1:
        fail(f"{struct_name} has no body")
    depth = 0
    for index in range(brace, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    fail(f"{struct_name} body is not closed")


def main() -> None:
    if not DESIGN_DIR.exists():
        fail("DesignSystem directory is missing")
    missing = [name for name in REQUIRED_TOKEN_FILES if not (DESIGN_DIR / name).exists()]
    if missing:
        fail(f"DesignSystem token files missing: {', '.join(missing)}")

    app_icon_dir = ROOT / "SingReadyAI/App/Assets.xcassets/AppIcon.appiconset"
    app_icon = app_icon_dir / "AppIcon.png"
    if not (app_icon_dir / "Contents.json").exists() or not app_icon.exists():
        fail("AppIcon asset catalog is missing")
    if png_dimensions(app_icon) != (1024, 1024):
        fail("AppIcon.png must be exactly 1024 x 1024 pixels")

    root_tab = ROOT / "SingReadyAI/App/RootTabView.swift"
    if "enum DesignSystem" in root_tab.read_text(encoding="utf-8", errors="ignore"):
        fail("RootTabView.swift still defines DesignSystem")

    swift_files = [
        path for path in (ROOT / "SingReadyAI").rglob("*.swift")
        if "DesignSystem" not in path.parts and "ShareExtension" not in path.parts
    ]
    hardcoded_patterns = [
        r"Color\(red:",
        r"Color\.white\.opacity",
        r"\.foregroundStyle\(\.white",
        r"\.tint\(\.(pink|cyan|orange|green|red|blue|purple)\)",
        r"cornerRadius:\s*(?:[0-9]|1[0-9])\b",
        r"\.clipShape\(RoundedRectangle\(cornerRadius:\s*(?:[0-9]|1[0-9])\b",
    ]
    hardcoded_hits = []
    for path in swift_files:
        text = path.read_text(encoding="utf-8", errors="ignore")
        for pattern in hardcoded_patterns:
            for match in re.finditer(pattern, text):
                line = text.count("\n", 0, match.start()) + 1
                hardcoded_hits.append(f"{path.relative_to(ROOT)}:{line}:{match.group(0)}")
    if len(hardcoded_hits) > 24:
        fail("Too many hardcoded visual values outside DesignSystem:\n" + "\n".join(hardcoded_hits[:40]))

    consumer_copy_phrases = {
        "没有可匹配的歌曲": "Empty-playlist errors should describe what the user can do next",
        "网络没找到": "Fallback copy should not expose implementation or network branches",
        "本地曲库": "Fallback copy should not expose internal catalog terminology",
        "正在请求麦克风权限": "Permission progress copy should describe the user-visible action",
    }
    copy_hits = []
    for path in swift_files:
        text = path.read_text(encoding="utf-8", errors="ignore")
        for phrase, guidance in consumer_copy_phrases.items():
            if phrase in text:
                copy_hits.append(f"{path.relative_to(ROOT)}: {phrase} ({guidance})")
    if copy_hits:
        fail("Consumer-facing copy regression checks failed:\n" + "\n".join(copy_hits))

    design_components = (DESIGN_DIR / "DesignSystemComponents.swift").read_text(encoding="utf-8", errors="ignore")
    design_system_text = "\n".join(
        path.read_text(encoding="utf-8", errors="ignore")
        for path in sorted(DESIGN_DIR.glob("*.swift"))
    )
    glass_material = (DESIGN_DIR / "GlassMaterial.swift").read_text(encoding="utf-8", errors="ignore")
    root_tab_text = (ROOT / "SingReadyAI/App/RootTabView.swift").read_text(encoding="utf-8", errors="ignore")
    onboarding_text = (ROOT / "SingReadyAI/Features/ProductFlow/OnboardingView.swift").read_text(encoding="utf-8", errors="ignore")
    import_flow_text = "\n".join(
        (ROOT / "SingReadyAI/Features/ProductFlow" / name).read_text(encoding="utf-8", errors="ignore")
        for name in ["ImportFlowViews.swift", "ImportReviewComponents.swift"]
    )
    scenario_text = "\n".join(
        (ROOT / "SingReadyAI/Features/ProductFlow" / name).read_text(encoding="utf-8", errors="ignore")
        for name in ["MatchVoiceScenarioViews.swift", "ScenarioBuilderViews.swift"]
    )
    voice_flow_text = (ROOT / "SingReadyAI/Features/ProductFlow/VoiceAndPreferenceViews.swift").read_text(encoding="utf-8", errors="ignore")
    workflow_store_text = "\n".join(
        path.read_text(encoding="utf-8", errors="ignore")
        for path in sorted((ROOT / "SingReadyAI/App").glob("DemoWorkflowStore*.swift"))
    )
    result_export_paths = [
        ROOT / "SingReadyAI/Features/ProductFlow/ResultExportStartTipsViews.swift",
        ROOT / "SingReadyAI/Features/ProductFlow/ExportStartTipsViews.swift",
    ]
    result_export_text = "\n".join(
        path.read_text(encoding="utf-8", errors="ignore")
        for path in result_export_paths
        if path.exists()
    )
    signal_visual_path = DESIGN_DIR / "SignalBrandVisual.swift"
    toast_path = DESIGN_DIR / "ToastPresenter.swift"
    share_extension_view = (ROOT / "SingReadyAI/ShareExtension/ShareExtensionView.swift").read_text(encoding="utf-8", errors="ignore")
    share_view_controller = (ROOT / "SingReadyAI/ShareExtension/ShareViewController.swift").read_text(encoding="utf-8", errors="ignore")

    aesthetic_failures = []
    if ".textFieldStyle(.roundedBorder)" in import_flow_text:
        aesthetic_failures.append("Import review still uses default roundedBorder TextField styling")
    if "BrandSignalVisual" not in onboarding_text:
        aesthetic_failures.append("Onboarding must use a branded signal visual instead of a plain SF Symbol circle")
    if not signal_visual_path.exists():
        aesthetic_failures.append("Branded signal visual component is missing")
    if "BrandSignalVisual" not in design_components:
        aesthetic_failures.append("HeroHeader must use the branded signal visual tile")
    if ".stageTextEditor()" not in import_flow_text:
        aesthetic_failures.append("Playlist TextEditor must share the staged dark input treatment")
    if ".buttonStyle(.plain)" in import_flow_text:
        aesthetic_failures.append("Import flow still has plain buttons without tactile visual feedback")
    if "struct PressedScaleButtonStyle" not in design_components:
        aesthetic_failures.append("Shared pressed button style is missing")
    if design_components.count("PressedScaleButtonStyle(") < 2:
        aesthetic_failures.append("Primary and secondary buttons must opt into pressed visual feedback")
    primary_button_body = extract_struct(design_components, "PrimaryGradientButton")
    if "DesignSystem.amber" in primary_button_body:
        aesthetic_failures.append("PrimaryGradientButton must avoid bright amber under white text")
    if "NavigationStack(path: $store.navigationPath)" not in root_tab_text:
        aesthetic_failures.append("Product features must use a native navigation stack with path-backed history")
    if ".navigationDestination(for: WorkflowStage.self)" not in root_tab_text:
        aesthetic_failures.append("Product features must expose native push and edge-swipe back navigation")
    if "navigationBarBackButtonHidden" in root_tab_text:
        aesthetic_failures.append("Native navigation back controls and edge-swipe gestures must remain enabled")
    if "#available(iOS 26.0, *)" not in root_tab_text or "toolbarBackground(.hidden, for: .navigationBar)" not in root_tab_text:
        aesthetic_failures.append("iOS 26 navigation must keep the bar transparent and let native glass controls carry hierarchy")
    if ".onDisappear" not in voice_flow_text or "store.cancelVoiceRecording()" not in voice_flow_text:
        aesthetic_failures.append("Voice recording must cancel when its feature page leaves the navigation stack")
    if "catch is CancellationError" not in workflow_store_text:
        aesthetic_failures.append("Cancelled voice recording must return to idle without exposing an error")
    if ".ultraThinMaterial" not in glass_material or ".shadow(" not in glass_material:
        aesthetic_failures.append("GlassCard must use native material and depth shadow")

    match_ring_body = extract_struct(design_system_text, "MatchRateRing")
    metric_bar_body = extract_struct(design_system_text, "MetricBar")
    if "animatedValue" not in match_ring_body or "MotionTokens.reveal" not in match_ring_body:
        aesthetic_failures.append("MatchRateRing must reveal from zero with MotionTokens.reveal")
    if "animatedValue" not in metric_bar_body or "MotionTokens.reveal" not in metric_bar_body:
        aesthetic_failures.append("MetricBar must reveal from zero with MotionTokens.reveal")

    scenario_card_body = extract_struct(scenario_text, "ScenarioCard")
    if "selectedScenarioBackground" not in scenario_card_body:
        aesthetic_failures.append("ScenarioCard selected state must use a dedicated non-primary large-surface treatment")
    if not toast_path.exists() or ".floatingToast(" not in result_export_text:
        aesthetic_failures.append("Copy/export actions need a visible transient toast confirmation")
    poster_body = extract_struct(result_export_text, "PosterPreviewContent")
    if "PosterSurface" not in poster_body:
        aesthetic_failures.append("Poster preview must use a differentiated poster surface instead of a normal GlassCard")
    start_tip_body = extract_struct(result_export_text, "StartTipCard")
    if "DesignSystem.primary.opacity" in start_tip_body:
        aesthetic_failures.append("Start tip numbering should follow cyan selection discipline, not coral")
    if 'accessibilityLabel("复制分享内容")' not in share_extension_view:
        aesthetic_failures.append("Share extension fallback state must expose a real copy action")
    if "func stageFileRepresentation(" not in share_view_controller or "store.stageSharedImage(from: url)" not in share_view_controller:
        aesthetic_failures.append("Shared images must be copied while the system file representation is valid")
    if "loadFileRepresentation(forTypeIdentifier identifier: String) async throws -> URL?" in share_view_controller:
        aesthetic_failures.append("Share extension must not return a temporary image URL outside its provider callback")
    if aesthetic_failures:
        fail("Aesthetic regression checks failed:\n" + "\n".join(f"- {item}" for item in aesthetic_failures))

    failed_files = []
    warned_files = []
    for path in (ROOT / "SingReadyAI").rglob("*.swift"):
        if "ShareExtension" in path.parts:
            continue
        line_count = sum(1 for _ in path.open(encoding="utf-8", errors="ignore"))
        rel = path.relative_to(ROOT)
        if path.name == "DemoWorkflowStore.swift" and line_count > 450:
            failed_files.append(f"{rel} has {line_count} lines; main workflow object limit is 450")
        elif line_count > 500:
            failed_files.append(f"{rel} has {line_count} lines; SwiftUI file limit is 500")
        elif line_count > 350:
            warned_files.append(f"{rel} has {line_count} lines")

    for item in warned_files:
        warn(item)
    if failed_files:
        fail("\n".join(failed_files))

    print("Design system OK")


if __name__ == "__main__":
    main()
