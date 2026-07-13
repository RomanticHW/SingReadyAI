import SwiftUI

struct SourceBadge: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    var tint: Color = DesignSystem.cyan

    var body: some View {
        Text(title)
            .font(TypographyTokens.caption.weight(.semibold))
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SpacingTokens.sm)
            .padding(.vertical, SpacingTokens.xxs)
            .frame(minHeight: 28)
            .background(tint.opacity(0.16))
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.30), lineWidth: 0.6)
            )
            .clipShape(Capsule())
            .foregroundStyle(DesignSystem.ink)
    }
}

struct ConfidenceMeter: View {
    let value: Double

    var body: some View {
        MetricBar(title: "大概是这首", value: value, tint: value < 0.72 ? DesignSystem.warning : DesignSystem.success) { value in
            switch value {
            case 0.82...: return "基本对"
            case 0.62...: return "有点像"
            default: return "看一下"
            }
        }
    }
}

struct MatchRateRing: View {
    @Environment(\.appAccessibilityFlags) private var flags
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var animatedValue = 0.0
    let value: Double

    var body: some View {
        let displayValue = flags.reduceMotion ? clampedValue : animatedValue
        ZStack {
            Circle().stroke(DesignSystem.separator, lineWidth: 10)
            Circle()
                .trim(from: 0, to: displayValue)
                .stroke(DesignSystem.primary, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if dynamicTypeSize.isAccessibilitySize {
                Image(systemName: ringIcon(for: displayValue))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(DesignSystem.ink)
            } else {
                Text(ringLabel(for: displayValue))
                    .font(TypographyTokens.callout.weight(.bold))
                    .foregroundStyle(DesignSystem.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(width: 82, height: 82)
        .accessibilityLabel(accessibilityRingLabel(for: clampedValue))
        .onAppear { updateValue(animated: true) }
        .onChange(of: value) { _, _ in updateValue(animated: true) }
        .onChange(of: flags.reduceMotion) { _, _ in updateValue(animated: false) }
    }

    private var clampedValue: Double {
        min(max(value, 0), 1)
    }

    private func ringLabel(for value: Double) -> String {
        switch value {
        case 0.995...: return "全命中"
        case 0.75...: return "多数命中"
        case 0.45...: return "部分命中"
        default: return "待核对"
        }
    }

    private func ringIcon(for value: Double) -> String {
        switch value {
        case 0.995...: return "checkmark"
        case 0.75...: return "music.note.list"
        case 0.45...: return "line.3.horizontal.decrease"
        default: return "questionmark"
        }
    }

    private func accessibilityRingLabel(for value: Double) -> String {
        switch value {
        case 0.995...: return "本地参考全部命中"
        case 0.75...: return "本地参考多数命中"
        case 0.45...: return "本地参考部分命中"
        default: return "先核对本地参考候选"
        }
    }

    private func updateValue(animated: Bool) {
        if flags.reduceMotion || !animated {
            animatedValue = clampedValue
        } else {
            animatedValue = 0
            withAnimation(MotionTokens.reveal.delay(0.08)) {
                animatedValue = clampedValue
            }
        }
    }
}

typealias CircularRateView = MatchRateRing

struct MetricPill: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: SpacingTokens.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(DesignSystem.cyan)
            VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                Text(value)
                    .font(TypographyTokens.metric)
                Text(title)
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(SpacingTokens.sm)
        .frame(minHeight: 62)
        .background(DesignSystem.raisedBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(height: 0.6)
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
        .foregroundStyle(DesignSystem.ink)
    }
}

struct TagCloud: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let values: [String]
    var tint: Color = DesignSystem.cyan

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: SpacingTokens.xs) {
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(TypographyTokens.caption.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .minimumScaleFactor(0.82)
                    .padding(.horizontal, SpacingTokens.sm)
                    .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? SpacingTokens.xs : 0)
                    .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 44 : 30)
                    .frame(maxWidth: .infinity)
                    .background(tint.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: tagCornerRadius, style: .continuous))
                    .foregroundStyle(DesignSystem.ink)
            }
        }
    }

    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible(), spacing: SpacingTokens.xs)] : [GridItem(.adaptive(minimum: 92), spacing: SpacingTokens.xs)]
    }

    private var tagCornerRadius: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? DesignSystem.radiusSmall : 999
    }
}

struct MetricBar: View {
    @Environment(\.appAccessibilityFlags) private var flags
    @State private var animatedValue = 0.0
    let title: String
    let value: Double
    var tint: Color = DesignSystem.cyan
    var valueLabel: (Double) -> String = MetricBar.defaultValueLabel

    var body: some View {
        let displayValue = flags.reduceMotion ? clampedValue : animatedValue
        VStack(alignment: .leading, spacing: SpacingTokens.xs) {
            HStack {
                Text(title)
                Spacer()
                Text(valueLabel(displayValue))
                    .font(TypographyTokens.caption.weight(.semibold))
            }
            .font(TypographyTokens.caption)
            .foregroundStyle(DesignSystem.muted)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DesignSystem.separator)
                    Capsule().fill(tint)
                        .frame(width: proxy.size.width * displayValue)
                }
            }
            .frame(height: 7)
        }
        .onAppear { updateValue(animated: true) }
        .onChange(of: value) { _, _ in updateValue(animated: true) }
        .onChange(of: flags.reduceMotion) { _, _ in updateValue(animated: false) }
    }

    private var clampedValue: Double {
        min(max(value, 0), 1)
    }

    private static func defaultValueLabel(_ value: Double) -> String {
        switch value {
        case 0.82...: return "很高"
        case 0.58...: return "偏高"
        case 0.34...: return "中等"
        case 0.12...: return "偏低"
        default: return "很低"
        }
    }

    private func updateValue(animated: Bool) {
        if flags.reduceMotion || !animated {
            animatedValue = clampedValue
        } else {
            animatedValue = 0
            withAnimation(MotionTokens.reveal) {
                animatedValue = clampedValue
            }
        }
    }
}

struct StageInputFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(TypographyTokens.callout.weight(.semibold))
            .padding(.horizontal, SpacingTokens.sm)
            .frame(minHeight: ComponentTokens.minTouchTarget)
            .liquidGlassSurface(
                cornerRadius: DesignSystem.radiusSmall,
                tint: DesignSystem.cyan.opacity(0.04),
                fallback: DesignSystem.raisedBackground
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                    .stroke(DesignSystem.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
            .foregroundStyle(DesignSystem.ink)
            .tint(DesignSystem.cyan)
    }
}

struct StageTextEditorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(TypographyTokens.callout)
            .frame(minHeight: 116)
            .scrollContentBackground(.hidden)
            .padding(SpacingTokens.sm)
            .liquidGlassSurface(
                cornerRadius: DesignSystem.radiusSmall,
                tint: DesignSystem.cyan.opacity(0.04),
                fallback: DesignSystem.raisedBackground
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                    .stroke(DesignSystem.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
            .foregroundStyle(DesignSystem.ink)
            .tint(DesignSystem.cyan)
    }
}
