import SwiftUI

enum BrandSignalVisualScale {
    case tile
    case showcase

    var size: CGFloat {
        switch self {
        case .tile: return ComponentTokens.iconButtonSize
        case .showcase: return 164
        }
    }

    var radius: CGFloat {
        switch self {
        case .tile: return ComponentTokens.radiusMedium
        case .showcase: return DesignSystem.radiusLarge + 10
        }
    }
}

struct BrandSignalVisual: View {
    @Environment(\.appAccessibilityFlags) private var flags
    @State private var pulse = false

    let systemImage: String
    var tint: Color = DesignSystem.cyan
    var scale: BrandSignalVisualScale = .tile

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: scale.radius, style: .continuous)
                .fill(surfaceGradient)
            if scale == .showcase {
                stageRings
                SignalBars(tint: tint, pulse: pulse, scale: scale)
                    .offset(x: -28, y: -6)
            } else {
                SignalBars(tint: tint, pulse: pulse, scale: scale)
                    .offset(x: -8, y: 8)
            }
            Image(systemName: systemImage)
                .font(iconFont)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .shadow(color: tint.opacity(0.34), radius: scale == .showcase ? 18 : 8)
                .offset(x: scale == .showcase ? 20 : 0, y: scale == .showcase ? 8 : 0)
        }
        .frame(width: scale.size, height: scale.size)
        .overlay(
            RoundedRectangle(cornerRadius: scale.radius, style: .continuous)
                .stroke(tint.opacity(scale == .showcase ? 0.34 : 0.24), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: scale.radius, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 0.7)
                .blendMode(.screen)
        }
        .shadow(color: tint.opacity(scale == .showcase ? 0.24 : 0.12), radius: scale == .showcase ? 26 : 12, x: 0, y: 12)
        .onAppear {
            updatePulseAnimation()
        }
        .onChange(of: flags.reduceMotion) { _, _ in
            updatePulseAnimation()
        }
        .accessibilityHidden(true)
    }

    private var surfaceGradient: LinearGradient {
        LinearGradient(
            colors: [
                tint.opacity(scale == .showcase ? 0.26 : 0.18),
                DesignSystem.raisedBackgroundHigh.opacity(0.94),
                DesignSystem.cardBackgroundSolid
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func updatePulseAnimation() {
        if flags.reduceMotion {
            withAnimation(nil) { pulse = false }
        } else {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var iconFont: Font {
        switch scale {
        case .tile: return .system(size: 20, weight: .semibold)
        case .showcase: return .system(size: 60, weight: .semibold)
        }
    }

    private var stageRings: some View {
        ZStack {
            RoundedRectangle(cornerRadius: scale.radius - 8, style: .continuous)
                .stroke(tint.opacity(0.16), lineWidth: 1)
                .padding(14)
            RoundedRectangle(cornerRadius: scale.radius - 18, style: .continuous)
                .stroke(DesignSystem.primary.opacity(0.18), lineWidth: 1)
                .padding(32)
        }
        .opacity(flags.reduceTransparency ? 0 : 1)
    }
}

private struct SignalBars: View {
    let tint: Color
    let pulse: Bool
    let scale: BrandSignalVisualScale

    var body: some View {
        HStack(alignment: .center, spacing: scale == .showcase ? 7 : 4) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(index.isMultiple(of: 2) ? 0.74 : 0.46))
                    .frame(width: scale == .showcase ? 8 : 4, height: barHeight(height, index: index))
            }
        }
    }

    private var heights: [CGFloat] {
        scale == .showcase ? [18, 34, 25, 42, 22] : [8, 15, 11]
    }

    private func barHeight(_ base: CGFloat, index: Int) -> CGFloat {
        pulse ? base + CGFloat(index % 2) * 5 : base
    }
}
