import SwiftUI

struct PremiumBackground: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @State private var glowShift = false

    var body: some View {
        ZStack {
            DesignSystem.background
            if !accessibilityReduceTransparency {
                RadialGradient(
                    colors: [DesignSystem.primary.opacity(0.22), .clear],
                    center: glowShift ? UnitPoint(x: 0.84, y: 0.10) : UnitPoint(x: 0.96, y: 0.02),
                    startRadius: 20,
                    endRadius: 420
                )
                RadialGradient(
                    colors: [DesignSystem.cyan.opacity(accessibilityReduceMotion ? 0.10 : 0.18), .clear],
                    center: glowShift ? UnitPoint(x: 0.16, y: 0.82) : UnitPoint(x: 0.02, y: 0.98),
                    startRadius: 10,
                    endRadius: 520
                )
            }
        }
        .ignoresSafeArea()
        .onAppear {
            guard !accessibilityReduceMotion else { return }
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
                glowShift = true
            }
        }
    }
}

struct GlassCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @ViewBuilder var content: Content

    var body: some View {
        cardContent
            .glassCardStyle(reduceTransparency: accessibilityReduceTransparency)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            content
        }
        .padding(SpacingTokens.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    @ViewBuilder
    func glassCardStyle(reduceTransparency: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
        if #available(iOS 26.0, *), !reduceTransparency {
            self
                .background(DesignSystem.cardBackgroundLow.opacity(0.10), in: shape)
                .glassEffect(Glass.regular.tint(DesignSystem.cyan.opacity(0.025)), in: shape)
                .overlay(shape.stroke(DesignSystem.border.opacity(0.72), lineWidth: 0.8))
                .overlay(alignment: .top) {
                    shape
                        .stroke(DesignSystem.borderStrong, lineWidth: 0.5)
                        .blendMode(.screen)
                        .opacity(0.32)
                }
                .clipShape(shape)
                .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 8)
        } else {
            self
                .background(legacyCardMaterial(reduceTransparency: reduceTransparency))
                .overlay(shape.stroke(DesignSystem.border, lineWidth: 1))
                .overlay(alignment: .top) {
                    shape
                        .stroke(DesignSystem.borderStrong, lineWidth: 0.5)
                        .blendMode(.screen)
                        .opacity(reduceTransparency ? 0 : 0.55)
                }
                .clipShape(shape)
                .shadow(color: .black.opacity(reduceTransparency ? 0.12 : 0.30), radius: 22, x: 0, y: 12)
        }
    }

    @ViewBuilder
    func legacyCardMaterial(reduceTransparency: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
        shape.fill(reduceTransparency ? DesignSystem.cardBackgroundSolid : DesignSystem.cardBackgroundLow)
        if !reduceTransparency {
            shape.fill(.ultraThinMaterial)
            shape.fill(
                LinearGradient(
                    colors: [
                        DesignSystem.raisedBackground.opacity(0.70),
                        DesignSystem.cardBackground.opacity(0.36)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }
}
