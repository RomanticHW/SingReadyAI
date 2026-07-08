#!/usr/bin/env python3
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHARE_PLIST = ROOT / "SingReadyAI/ShareExtension/Info.plist"
PROJECT = ROOT / "project.yml"


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


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

    print("Plist/privacy OK")


if __name__ == "__main__":
    main()
