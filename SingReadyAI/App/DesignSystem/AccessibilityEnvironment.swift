import SwiftUI

struct AccessibilityFlags {
    var reduceMotion: Bool
    var reduceTransparency: Bool
}

private struct AccessibilityFlagsKey: EnvironmentKey {
    static let defaultValue = AccessibilityFlags(reduceMotion: false, reduceTransparency: false)
}

extension EnvironmentValues {
    var appAccessibilityFlags: AccessibilityFlags {
        get { self[AccessibilityFlagsKey.self] }
        set { self[AccessibilityFlagsKey.self] = newValue }
    }
}
