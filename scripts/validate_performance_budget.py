#!/usr/bin/env python3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def main() -> None:
    budget = ROOT / "docs/PERFORMANCE_BUDGET.md"
    require(budget.exists(), "docs/PERFORMANCE_BUDGET.md is missing")
    budget_text = budget.read_text(encoding="utf-8", errors="ignore") if budget.exists() else ""
    for keyword in ("启动", "JSON", "推荐", "录音", "动效", "内存", "Reduce Motion", "Reduce Transparency"):
        require(keyword in budget_text, f"performance budget missing topic: {keyword}")

    app_sources = "\n".join(path.read_text(encoding="utf-8", errors="ignore") for path in (ROOT / "SingReadyAI").rglob("*.swift"))
    require("LazyVStack" in app_sources or "LazyVGrid" in app_sources, "large lists must use LazyVStack/LazyVGrid")
    require("accessibilityReduceMotion" in app_sources, "app must read accessibilityReduceMotion")
    require("accessibilityReduceTransparency" in app_sources, "app must read accessibilityReduceTransparency")

    view_body_decode_hits = []
    for path in (ROOT / "SingReadyAI").rglob("*.swift"):
        text = path.read_text(encoding="utf-8", errors="ignore")
        if "var body" in text and ("JSONDecoder()" in text or "Data(contentsOf:" in text):
            view_body_decode_hits.append(str(path.relative_to(ROOT)))
    require(not view_body_decode_hits, "SwiftUI view files must not decode JSON or synchronously load data: " + ", ".join(view_body_decode_hits))

    require("TimelineView" not in app_sources or "accessibilityReduceMotion" in app_sources, "TimelineView animations require Reduce Motion fallback")
    print("Performance budget OK")


if __name__ == "__main__":
    main()
