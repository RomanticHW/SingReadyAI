import SwiftUI

struct PremiumBackground: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency

    var body: some View {
        ZStack {
            DesignSystem.background
            if !accessibilityReduceTransparency {
                RadialGradient(
                    colors: [DesignSystem.primary.opacity(0.22), .clear],
                    center: .topTrailing,
                    startRadius: 20,
                    endRadius: 420
                )
                RadialGradient(
                    colors: [DesignSystem.cyan.opacity(accessibilityReduceMotion ? 0.10 : 0.18), .clear],
                    center: .bottomLeading,
                    startRadius: 10,
                    endRadius: 520
                )
            }
        }
        .ignoresSafeArea()
    }
}

struct GlassCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            content
        }
        .padding(SpacingTokens.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accessibilityReduceTransparency ? DesignSystem.cardBackgroundSolid : DesignSystem.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                .stroke(DesignSystem.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))
    }
}
