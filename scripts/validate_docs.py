#!/usr/bin/env python3
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def read_if_exists(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="ignore") if path.exists() else ""


def share_activation_supports_all() -> bool:
    plist_path = ROOT / "SingReadyAI/ShareExtension/Info.plist"
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


def main() -> None:
    docs_text = "\n".join(
        read_if_exists(ROOT / name)
        for name in ("README.md", "FINAL_REPORT.md", "ShareExtensionREADME.md")
    )
    app_sources = "\n".join(path.read_text(encoding="utf-8", errors="ignore") for path in (ROOT / "SingReadyAI").rglob("*.swift"))
    all_sources = "\n".join(path.read_text(encoding="utf-8", errors="ignore") for path in (ROOT / "Sources").rglob("*.swift"))

    if all(token in docs_text for token in ("public.url", "public.plain-text", "public.image")):
        require(share_activation_supports_all(), "Docs claim URL/text/image share support, but Info.plist does not support all three")

    claims_recording = bool(re.search(r"(真实|真机|录音).*声线|声线.*(真实|真机|录音)", docs_text))
    if claims_recording:
        require(
            "AVAudioEngine" in app_sources and "installTap" in app_sources and "analyzePCMFrames" in app_sources,
            "Docs claim real recording/voice analysis, but app lacks AVAudioEngine PCM analysis path",
        )
        require(
            "录音完成但使用模拟" not in app_sources and "本地 Demo 使用模拟音高帧" not in app_sources,
            "App still labels recorded voice as simulated pitch frames",
        )

    claims_visual_quality = any(keyword in docs_text for keyword in ("作品集级", "高级视觉", "高级审美", "Polished"))
    if claims_visual_quality:
        require((ROOT / "docs/DESIGN_SYSTEM.md").exists(), "Docs claim portfolio visual quality but docs/DESIGN_SYSTEM.md is missing")
        require((ROOT / "docs/VISUAL_QA.md").exists(), "Docs claim portfolio visual quality but docs/VISUAL_QA.md is missing")

    if re.search(r"\bCI\b|GitHub Actions", docs_text):
        require((ROOT / ".github/workflows/ci.yml").exists(), "Docs mention CI/workflows but .github/workflows/ci.yml is missing")

    screenshot_dir = ROOT / "docs/screenshots"
    claims_screenshots = "docs/screenshots" in docs_text or re.search(r"截图位置|screenshot evidence", docs_text, re.IGNORECASE)
    if claims_screenshots:
        png_count = len(list(screenshot_dir.glob("*.png"))) if screenshot_dir.exists() else 0
        require(png_count >= 10, f"Docs claim screenshots but found {png_count} PNG files")

    require("雷石设备协议" not in docs_text or "不接入真实雷石设备" in docs_text, "Docs must not imply real Leishi hardware integration")
    require("私有接口" not in docs_text or "不抓取" in docs_text, "Docs must not imply private music API scraping")

    print("Docs consistency OK")


if __name__ == "__main__":
    main()
