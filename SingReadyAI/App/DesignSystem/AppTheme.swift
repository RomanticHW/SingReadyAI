import SwiftUI

enum DesignSystem {
    static let spacing = SpacingTokens.md
    static let cornerRadius = ComponentTokens.radiusMedium
    static let radiusSmall = ComponentTokens.radiusSmall
    static let radiusLarge = ComponentTokens.radiusLarge
    static let pageHorizontalPadding = SpacingTokens.page
    static let cardBackground = ColorTokens.panel
    static let cardBackgroundSolid = ColorTokens.panelSolid
    static let raisedBackground = ColorTokens.panelRaised
    static let border = ColorTokens.stroke
    static let separator = ColorTokens.hairline
    static let primary = ColorTokens.coral
    static let cyan = ColorTokens.cyan
    static let amber = ColorTokens.amber
    static let success = ColorTokens.success
    static let warning = ColorTokens.warning
    static let danger = ColorTokens.danger
    static let ink = ColorTokens.textPrimary
    static let muted = ColorTokens.textSecondary
    static let weak = ColorTokens.textMuted

    static let background = LinearGradient(
        colors: [
            ColorTokens.stageBlack,
            ColorTokens.midnight,
            ColorTokens.deepTeal
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
