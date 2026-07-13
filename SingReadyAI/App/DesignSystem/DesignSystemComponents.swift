import SwiftUI
import SingReadyAISharedKit

struct HeroHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let eyebrow: String
    let title: String
    let subtitle: String
    var systemImage: String = "music.mic"

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                    BrandSignalVisual(systemImage: systemImage, tint: DesignSystem.primary, scale: .tile)
                    textContent
                }
            } else {
                HStack(alignment: .top, spacing: SpacingTokens.md) {
                    BrandSignalVisual(systemImage: systemImage, tint: DesignSystem.primary, scale: .tile)
                    textContent
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var textContent: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.xs) {
            if !dynamicTypeSize.isAccessibilitySize {
                Text(eyebrow)
                    .font(TypographyTokens.caption.weight(.semibold))
                    .foregroundStyle(DesignSystem.cyan)
            }
            Text(title)
                .font(dynamicTypeSize.isAccessibilitySize ? TypographyTokens.title : TypographyTokens.hero)
                .foregroundStyle(DesignSystem.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(TypographyTokens.callout)
                .foregroundStyle(DesignSystem.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
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
            .padding(.top, SpacingTokens.sm)
            .padding(.bottom, SpacingTokens.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .environment(\.appAccessibilityFlags, AccessibilityFlags(reduceMotion: accessibilityReduceMotion, reduceTransparency: accessibilityReduceTransparency))
    }
}

struct StageJumpMenu: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isPresented = false
    let stages: [WorkflowStage]
    let current: WorkflowStage
    let scenario: KTVScenario
    let onSelect: (WorkflowStage) -> Void

    var body: some View {
        Button {
            Haptics.selection()
            isPresented = true
        } label: {
            HStack(spacing: SpacingTokens.xs) {
                if dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 20, weight: .semibold))
                } else {
                    Label("功能", systemImage: "square.grid.2x2")
                        .font(TypographyTokens.caption.weight(.semibold))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(DesignSystem.ink)
            .frame(minWidth: ComponentTokens.minTouchTarget, minHeight: ComponentTokens.minTouchTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开功能菜单")
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SpacingTokens.lg) {
                        stageSection("常用", stages: [.home])
                        stageSection("我有歌单", stages: [.importHub, .review, .matchReport])
                        stageSection("唱前准备", stages: [.voice, .scenario])
                        stageSection(
                            scenario == .soloPractice ? "练唱工具" : "到了现场",
                            stages: [.result, .export, .startTips]
                        )
                    }
                    .padding(SpacingTokens.md)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(DesignSystem.background.ignoresSafeArea())
                .navigationTitle("想做什么")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { isPresented = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
    }

    private func stageSection(_ title: String, stages: [WorkflowStage]) -> some View {
        VStack(alignment: .leading, spacing: SpacingTokens.xs) {
            Text(title)
                .font(TypographyTokens.caption.weight(.semibold))
                .foregroundStyle(DesignSystem.muted)
            ForEach(stages) { stage in
                stageButton(stage)
            }
        }
    }

    private func stageButton(_ stage: WorkflowStage) -> some View {
        let stageTitle = stage.title(for: scenario)
        return Button {
            Haptics.selection()
            isPresented = false
            if stage != current {
                onSelect(stage)
            }
        } label: {
            HStack(spacing: SpacingTokens.sm) {
                Image(systemName: stage.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(current == stage ? DesignSystem.cyan : DesignSystem.muted)
                    .frame(width: ComponentTokens.minTouchTarget, height: ComponentTokens.minTouchTarget)
                Text(stageTitle)
                    .font(TypographyTokens.callout.weight(.semibold))
                    .foregroundStyle(DesignSystem.ink)
                Spacer()
                if current == stage {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignSystem.cyan)
                }
            }
            .padding(.horizontal, SpacingTokens.sm)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(current == stage ? DesignSystem.cyan.opacity(0.14) : DesignSystem.raisedBackground)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
        }
        .buttonStyle(PressedScaleButtonStyle(scale: 0.98))
        .accessibilityIdentifier("stage-menu-\(stage.rawValue)")
        .accessibilityLabel(current == stage ? "\(stageTitle)，当前页面" : "打开\(stageTitle)")
        .accessibilityAddTraits(current == stage ? .isSelected : [])
    }
}

struct UndoBanner: View {
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: SpacingTokens.sm) {
            Text(message)
                .font(TypographyTokens.callout.weight(.semibold))
                .foregroundStyle(DesignSystem.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: SpacingTokens.xs)
            Button(actionTitle, action: action)
                .font(TypographyTokens.callout.weight(.semibold))
                .foregroundStyle(DesignSystem.cyan)
                .frame(minHeight: ComponentTokens.minTouchTarget)
        }
        .padding(.horizontal, SpacingTokens.md)
        .padding(.vertical, SpacingTokens.xs)
        .background(DesignSystem.cardBackgroundSolid.opacity(0.98))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                .stroke(DesignSystem.cyan.opacity(0.42), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

struct PrimaryGradientButton: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26.0, *), !accessibilityReduceTransparency {
                baseButton
                    .buttonStyle(.glass)
                    .buttonBorderShape(.roundedRectangle(radius: DesignSystem.radiusSmall))
                    .tint(DesignSystem.primary.opacity(0.82))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                            .stroke(LinearGradient(colors: [DesignSystem.primary.opacity(0.58), DesignSystem.cyan.opacity(0.30)], startPoint: .leading, endPoint: .trailing), lineWidth: 0.9)
                    )
            } else {
                baseButton
                    .buttonStyle(PressedScaleButtonStyle())
                    .liquidGlassSurface(
                        cornerRadius: DesignSystem.radiusSmall,
                        tint: DesignSystem.primary.opacity(0.10),
                        fallback: DesignSystem.raisedBackgroundHigh,
                        interactive: true
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                            .stroke(LinearGradient(colors: [DesignSystem.primary.opacity(0.60), DesignSystem.cyan.opacity(0.34)], startPoint: .leading, endPoint: .trailing), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
            }
        }
        .foregroundStyle(DesignSystem.ink)
        .opacity(isEnabled ? 1 : 0.58)
        .accessibilityLabel(title)
    }

    private var baseButton: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(TypographyTokens.section)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.82)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 76 : ComponentTokens.controlHeight)
                .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? SpacingTokens.xs : 0)
        }
    }
}

struct SecondaryGlassButton: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26.0, *), !accessibilityReduceTransparency {
                baseButton
                    .buttonStyle(.glass)
                    .buttonBorderShape(.roundedRectangle(radius: DesignSystem.radiusSmall))
                    .tint(DesignSystem.cyan)
            } else {
                baseButton
                    .buttonStyle(PressedScaleButtonStyle(scale: 0.97))
                    .liquidGlassSurface(
                        cornerRadius: DesignSystem.radiusSmall,
                        tint: DesignSystem.cyan.opacity(0.05),
                        fallback: DesignSystem.raisedBackground,
                        interactive: true
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                            .stroke(DesignSystem.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
            }
        }
        .foregroundStyle(DesignSystem.ink)
        .opacity(isEnabled ? 1 : 0.58)
        .accessibilityLabel(title)
    }

    private var baseButton: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(TypographyTokens.callout.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.82)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 68 : ComponentTokens.minTouchTarget)
                .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? SpacingTokens.xs : 0)
        }
    }
}

struct PressedScaleButtonStyle: ButtonStyle {
    @Environment(\.appAccessibilityFlags) private var flags
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: ComponentTokens.minTouchTarget, minHeight: ComponentTokens.minTouchTarget)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !flags.reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(flags.reduceMotion ? nil : MotionTokens.micro, value: configuration.isPressed)
    }
}

typealias Panel = GlassCard
typealias PrimaryActionButton = PrimaryGradientButton
typealias SecondaryActionButton = SecondaryGlassButton

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

    func stageInputField() -> some View {
        modifier(StageInputFieldModifier())
    }

    func stageTextEditor() -> some View {
        modifier(StageTextEditorModifier())
    }
}
