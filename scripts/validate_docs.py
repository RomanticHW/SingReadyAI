#!/usr/bin/env python3
import json
import plistlib
import re
import sys
from pathlib import Path

from screenshot_source_fingerprint import screenshot_source_digest

ROOT = Path(__file__).resolve().parents[1]
TOP_LEVEL_DOCUMENTS = (
    "README.md",
    "FINAL_REPORT.md",
    "ShareExtensionREADME.md",
    "PRIVACY.md",
)
LIVE_FACT_DOCUMENTS = (
    "README.md",
    "FINAL_REPORT.md",
    "docs/GAP_ANALYSIS.md",
    "docs/QUALITY_AUDIT.md",
    "docs/VISUAL_QA.md",
    "docs/PERFORMANCE_BUDGET.md",
    "docs/PRODUCT_REMEDIATION_PLAN.md",
    "docs/PRODUCT_REMEDIATION_DESIGN.md",
)


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def read_if_exists(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="ignore") if path.exists() else ""


def documentation_paths(root: Path = ROOT) -> list[Path]:
    paths = [root / name for name in TOP_LEVEL_DOCUMENTS if (root / name).exists()]
    docs_directory = root / "docs"
    if docs_directory.exists():
        paths.extend(sorted(docs_directory.rglob("*.md")))
    return paths


def source_test_counts(root: Path) -> tuple[int, int]:
    test_declaration = re.compile(
        r"^[ \t]*func[ \t]+test(?:[A-Z0-9_]|[^\x00-\x7F])\w*[ \t]*"
        r"\([ \t]*\)[ \t]*(?:(?:async|throws|rethrows)[ \t]*)*(?:\{|$)",
        re.MULTILINE,
    )

    def count_in(directory: Path) -> int:
        return sum(
            len(test_declaration.findall(read_if_exists(path)))
            for path in sorted(directory.rglob("*.swift"))
        )

    return count_in(root / "Tests"), count_in(root / "UITests")


def validate_report_facts(
    report_text: str,
    swift_count: int,
    ui_count: int,
    screenshots_current: bool,
) -> list[str]:
    errors: list[str] = []
    count_claims = (
        (
            "Swift Package",
            re.search(
                r"(?m)^[ \t]*(?:[-*][ \t]+)?Swift Package：[^\n]*?(\d+)\s*/\s*(\d+)",
                report_text,
            ),
            swift_count,
        ),
        (
            "UI",
            re.search(
                r"(?m)^[ \t]*(?:[-*][ \t]+)?完整 UI 回归：[^\n]*?(\d+)\s*/\s*(\d+)",
                report_text,
            ),
            ui_count,
        ),
    )
    for label, match, expected in count_claims:
        expected_claim = f"{expected}/{expected}"
        if match is None:
            errors.append(
                f"FINAL_REPORT.md {label} test count is missing: expected {expected_claim}"
            )
            continue
        actual_claim = f"{match.group(1)}/{match.group(2)}"
        if actual_claim != expected_claim:
            errors.append(
                f"FINAL_REPORT.md {label} test count is stale: "
                f"expected {expected_claim}, found {actual_claim}"
            )

    screenshot_claim = "来源指纹、命名与尺寸校验通过" in report_text
    if screenshot_claim and not screenshots_current:
        errors.append(
            "FINAL_REPORT.md 截图来源指纹声明已过期：两套 capture-metadata.json "
            "的 source_tree_sha256 必须与当前源码指纹一致"
        )
    return errors


def validate_live_document_facts(
    documents: dict[str, str],
    swift_count: int,
    ui_count: int,
) -> list[str]:
    errors: list[str] = []
    count_patterns = (
        (
            "Swift",
            re.compile(
                r"(?:Swift Package|swift test)[^。；;\n]*?(\d+)\s*/\s*(\d+)",
                re.IGNORECASE,
            ),
            swift_count,
        ),
        (
            "UI",
            re.compile(
                r"(?:完整 UI|SingReadyAIUITests|UI 回归)[^。；;\n]*?(\d+)\s*/\s*(\d+)",
                re.IGNORECASE,
            ),
            ui_count,
        ),
    )
    for path, text in documents.items():
        for line in text.splitlines():
            for label, claim_pattern, expected in count_patterns:
                match = claim_pattern.search(line)
                if match is None:
                    continue
                actual = f"{match.group(1)}/{match.group(2)}"
                wanted = f"{expected}/{expected}"
                if actual != wanted:
                    errors.append(
                        f"{path} {label} test count is stale: expected {wanted}, found {actual}"
                    )

        if re.search(r"公开 HTTPS 静态(?:内容|页面).*最佳努力读取", text):
            errors.append(
                f"{path} 仍声明通用网页读取；生产网络只允许 Apple Music 与网易云官方公开链接"
            )
    return errors


def share_activation_supports_all(root: Path = ROOT) -> bool:
    plist_path = root / "SingReadyAI/ShareExtension/Info.plist"
    if not plist_path.exists():
        return False
    try:
        plist = plistlib.loads(plist_path.read_bytes())
    except Exception:
        return False
    activation = (
        plist.get("NSExtension", {})
        .get("NSExtensionAttributes", {})
        .get("NSExtensionActivationRule")
    )
    if isinstance(activation, dict):
        return (
            activation.get("NSExtensionActivationSupportsWebURLWithMaxCount", 0) >= 1
            and activation.get("NSExtensionActivationSupportsText") is True
            and activation.get("NSExtensionActivationSupportsImageWithMaxCount", 0) >= 1
        )
    activation_text = str(activation)
    return all(token in activation_text for token in ("public.url", "public.plain-text", "public.image"))


def main(root: Path = ROOT) -> int:
    docs_text = "\n".join(read_if_exists(path) for path in documentation_paths(root))
    app_sources = "\n".join(path.read_text(encoding="utf-8", errors="ignore") for path in (root / "SingReadyAI").rglob("*.swift"))
    all_sources = "\n".join(path.read_text(encoding="utf-8", errors="ignore") for path in (root / "Sources").rglob("*.swift"))

    current_source_digest = screenshot_source_digest(root)
    screenshot_metadata_paths = (
        root / "docs/screenshots/capture-metadata.json",
        root / "docs/screenshots-large-text/capture-metadata.json",
    )
    screenshot_digests: list[str | None] = []
    for path in screenshot_metadata_paths:
        try:
            metadata = json.loads(path.read_text(encoding="utf-8"))
            screenshot_digests.append(metadata.get("source_tree_sha256"))
        except (OSError, json.JSONDecodeError):
            screenshot_digests.append(None)
    screenshots_current = all(
        digest == current_source_digest for digest in screenshot_digests
    )
    swift_count, ui_count = source_test_counts(root)
    report_errors = validate_report_facts(
        read_if_exists(root / "FINAL_REPORT.md"),
        swift_count,
        ui_count,
        screenshots_current,
    )
    if report_errors:
        for error in report_errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    live_documents = {
        path: read_if_exists(root / path)
        for path in LIVE_FACT_DOCUMENTS
        if (root / path).exists()
    }
    live_document_errors = validate_live_document_facts(
        live_documents,
        swift_count,
        ui_count,
    )
    if live_document_errors:
        for error in live_document_errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    if all(token in docs_text for token in ("public.url", "public.plain-text", "public.image")):
        require(share_activation_supports_all(root), "Docs claim URL/text/image share support, but Info.plist does not support all three")

    claims_recording = bool(re.search(r"(真实|真机|录音).*声线|声线.*(真实|真机|录音)", docs_text))
    if claims_recording:
        require(
            "AVAudioEngine" in app_sources
            and "installTap" in app_sources
            and (
                "analyzePCMFrames" in all_sources
                or "VoiceSampleAnalysisExecutor" in all_sources
            ),
            "Docs claim real recording/voice analysis, but app lacks AVAudioEngine PCM analysis path",
        )
        require(
            "录音完成但使用模拟" not in app_sources and "本地 Demo 使用模拟音高帧" not in app_sources,
            "App still labels recorded voice as simulated pitch frames",
        )

    claims_visual_quality = any(keyword in docs_text for keyword in ("作品集级", "高级视觉", "高级审美", "Polished"))
    if claims_visual_quality:
        require((root / "docs/DESIGN_SYSTEM.md").exists(), "Docs claim portfolio visual quality but docs/DESIGN_SYSTEM.md is missing")
        require((root / "docs/VISUAL_QA.md").exists(), "Docs claim portfolio visual quality but docs/VISUAL_QA.md is missing")

    if re.search(r"\bCI\b|GitHub Actions", docs_text):
        require((root / ".github/workflows/ci.yml").exists(), "Docs mention CI/workflows but .github/workflows/ci.yml is missing")

    screenshot_dir = root / "docs/screenshots"
    claims_screenshots = "docs/screenshots" in docs_text or re.search(r"截图位置|screenshot evidence", docs_text, re.IGNORECASE)
    if claims_screenshots:
        png_count = len(list(screenshot_dir.glob("*.png"))) if screenshot_dir.exists() else 0
        require(png_count >= 10, f"Docs claim screenshots but found {png_count} PNG files")

    require("厂商设备协议" not in docs_text or "不接入真实厂商设备" in docs_text, "Docs must not imply real vendor hardware integration")
    require("私有接口" not in docs_text or "不抓取" in docs_text, "Docs must not imply private music API scraping")

    print("Docs consistency OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
