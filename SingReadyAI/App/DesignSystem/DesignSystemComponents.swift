import SwiftUI
import SingReadyAISharedKit

struct HeroHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var systemImage: String = "music.mic"

    var body: some View {
        HStack(alignment: .top, spacing: SpacingTokens.md) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .frame(width: ComponentTokens.iconButtonSize, height: ComponentTokens.iconButtonSize)
                .background(DesignSystem.primary.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
                .foregroundStyle(DesignSystem.primary)
            VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                Text(eyebrow)
                    .font(TypographyTokens.caption.weight(.semibold))
                    .foregroundStyle(DesignSystem.cyan)
                Text(title)
                    .font(TypographyTokens.hero)
                    .foregroundStyle(DesignSystem.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(TypographyTokens.callout)
                    .foregroundStyle(DesignSystem.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct FlowPage<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignSystem.spacing) {
                content
            }
            .padding(.horizontal, DesignSystem.pageHorizontalPadding)
            .padding(.top, SpacingTokens.md)
            .padding(.bottom, SpacingTokens.xl)
        }
        .environment(\.appAccessibilityFlags, AccessibilityFlags(reduceMotion: accessibilityReduceMotion, reduceTransparency: accessibilityReduceTransparency))
    }
}

struct StepProgressRail: View {
    let stages: [WorkflowStage]
    let current: WorkflowStage
    let onSelect: (WorkflowStage) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SpacingTokens.xs) {
                    ForEach(stages) { stage in
                        Button {
                            Haptics.selection()
                            onSelect(stage)
                        } label: {
                            Label(stage.title, systemImage: stage.systemImage)
                                .font(TypographyTokens.caption.weight(.semibold))
                                .lineLimit(1)
                                .frame(height: 34)
                                .padding(.horizontal, SpacingTokens.sm)
                                .background(current == stage ? DesignSystem.primary.opacity(0.88) : DesignSystem.raisedBackground)
                                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
                                .id(stage.id)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DesignSystem.ink)
                        .accessibilityLabel("前往\(stage.title)")
                    }
                }
                .padding(.vertical, SpacingTokens.xs)
            }
            .onAppear { proxy.scrollTo(current.id, anchor: .center) }
            .onChange(of: current) { _, newStage in
                withAnimation(MotionTokens.micro) {
                    proxy.scrollTo(newStage.id, anchor: .center)
                }
            }
        }
    }
}

struct PrimaryGradientButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(TypographyTokens.section)
                .frame(maxWidth: .infinity)
                .frame(height: ComponentTokens.controlHeight)
        }
        .buttonStyle(.plain)
        .background(
            LinearGradient(colors: [DesignSystem.primary, DesignSystem.amber.opacity(0.86)], startPoint: .leading, endPoint: .trailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
        .foregroundStyle(DesignSystem.ink)
        .accessibilityLabel(title)
    }
}

struct SecondaryGlassButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(TypographyTokens.callout.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: ComponentTokens.minTouchTarget)
        }
        .buttonStyle(.plain)
        .background(DesignSystem.raisedBackground)
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                .stroke(DesignSystem.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
        .foregroundStyle(DesignSystem.ink)
        .accessibilityLabel(title)
    }
}

typealias Panel = GlassCard
typealias PrimaryActionButton = PrimaryGradientButton
typealias SecondaryActionButton = SecondaryGlassButton

struct SourceBadge: View {
    let title: String
    var tint: Color = DesignSystem.cyan

    var body: some View {
        Text(title)
            .font(TypographyTokens.caption.weight(.semibold))
            .padding(.horizontal, SpacingTokens.sm)
            .frame(height: 28)
            .background(tint.opacity(0.16))
            .clipShape(Capsule())
            .foregroundStyle(DesignSystem.ink)
    }
}

struct ConfidenceMeter: View {
    let value: Double

    var body: some View {
        MetricBar(title: "置信度", value: value, tint: value < 0.72 ? DesignSystem.warning : DesignSystem.success)
    }
}

struct MatchRateRing: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle().stroke(DesignSystem.separator, lineWidth: 10)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(DesignSystem.primary, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(value * 100))%")
                .font(TypographyTokens.metric)
                .foregroundStyle(DesignSystem.ink)
        }
        .frame(width: 82, height: 82)
        .accessibilityLabel("可唱率 \(Int(value * 100))%")
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
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
        .foregroundStyle(DesignSystem.ink)
    }
}

struct TagCloud: View {
    let values: [String]
    var tint: Color = DesignSystem.cyan

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: SpacingTokens.xs)], alignment: .leading, spacing: SpacingTokens.xs) {
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(TypographyTokens.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .padding(.horizontal, SpacingTokens.sm)
                    .frame(height: 30)
                    .frame(maxWidth: .infinity)
                    .background(tint.opacity(0.15))
                    .clipShape(Capsule())
                    .foregroundStyle(DesignSystem.ink)
            }
        }
    }
}

struct MetricBar: View {
    let title: String
    let value: Double
    var tint: Color = DesignSystem.cyan

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.xs) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(TypographyTokens.caption.monospacedDigit())
            }
            .font(TypographyTokens.caption)
            .foregroundStyle(DesignSystem.muted)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DesignSystem.separator)
                    Capsule().fill(tint)
                        .frame(width: proxy.size.width * min(max(value, 0), 1))
                }
            }
            .frame(height: 7)
        }
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(TypographyTokens.callout)
            .foregroundStyle(DesignSystem.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)
    }
}

typealias EmptyStateRow = EmptyStateView

struct ErrorStateView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(TypographyTokens.caption.weight(.semibold))
            .foregroundStyle(DesignSystem.warning)
            .accessibilityLabel(text)
    }
}

struct LoadingStateView: View {
    let text: String

    var body: some View {
        HStack(spacing: SpacingTokens.sm) {
            ProgressView().tint(DesignSystem.primary)
            Text(text).font(TypographyTokens.callout)
        }
        .foregroundStyle(DesignSystem.muted)
    }
}

struct PrivacyNoteView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "lock.shield")
            .font(TypographyTokens.caption)
            .foregroundStyle(DesignSystem.muted)
            .padding(SpacingTokens.sm)
            .background(DesignSystem.raisedBackground)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
    }
}

extension View {
    func stageText() -> some View {
        foregroundStyle(DesignSystem.ink)
    }
}
