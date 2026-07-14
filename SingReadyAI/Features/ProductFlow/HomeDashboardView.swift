import Foundation
import SwiftUI

struct HomeDashboardView: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        FlowPage {
            HeroHeader(
                eyebrow: "今晚唱什么",
                title: "今天想怎么唱？",
                subtitle: isSoloPractice
                    ? "继续今天的练唱安排，或者重新导入、测音域和排歌。"
                    : "临时约 K、车里想唱、朋友聚会，先点现在用得上的。",
                systemImage: "music.mic"
            )
            TonightSnapshotCard()
            Text("先做哪件事")
                .font(TypographyTokens.section)
                .stageText()
            HomeFeatureSection(title: "我有歌单", subtitle: "先把歌名放进来，再核对本地参考匹配。") {
                HomeFeatureGrid {
                    HomeFeatureCard(
                        title: "导入歌单",
                        subtitle: "链接、截图、粘贴都能放进来",
                        systemImage: "tray.and.arrow.down",
                        tint: DesignSystem.primary
                    ) {
                        Task { await store.jumpToStage(.importHub) }
                    }
                    HomeFeatureCard(
                        title: "核对参考匹配",
                        subtitle: "逐首看参考命中和待确认候选",
                        systemImage: "checkmark.seal",
                        tint: DesignSystem.cyan
                    ) {
                        Task { await store.jumpToStage(.matchReport) }
                    }
                }
            }
            HomeFeatureSection(title: isSoloPractice ? "练唱准备" : "唱前准备", subtitle: "测不测音域都行，也可以直接排一版。") {
                HomeFeatureGrid {
                    HomeFeatureCard(
                        title: "测一下音域",
                        subtitle: "先看大概唱到哪儿舒服",
                        systemImage: "waveform",
                        tint: DesignSystem.amber
                    ) {
                        Task { await store.jumpToStage(.voice) }
                    }
                    HomeFeatureCard(
                        title: isSoloPractice ? "排练唱单" : "排今晚歌单",
                        subtitle: isSoloPractice ? "先开嗓，再留几首挑战" : "先热场，再留几首想唱的",
                        systemImage: "sparkles",
                        tint: DesignSystem.success
                    ) {
                        Task { await store.jumpToStage(.scenario) }
                    }
                }
            }
            HomeFeatureSection(title: finalToolsTitle, subtitle: finalToolsSubtitle) {
                HomeFeatureGrid {
                    HomeFeatureCard(
                        title: exportActionTitle,
                        subtitle: store.canUseReadyPlan
                            ? exportActionSubtitle
                            : "排好当前歌单后可用",
                        systemImage: "square.and.arrow.up",
                        tint: DesignSystem.cyan,
                        isDisabled: !store.canUseReadyPlan
                    ) {
                        Task { await store.jumpToStage(.export) }
                    }
                    HomeFeatureCard(
                        title: tipsActionTitle,
                        subtitle: store.canUseReadyPlan
                            ? tipsActionSubtitle
                            : "排好当前歌单后可用",
                        systemImage: "quote.bubble",
                        tint: DesignSystem.primary,
                        isDisabled: !store.canUseReadyPlan
                    ) {
                        Task { await store.jumpToStage(.startTips) }
                    }
                }
            }
            PrivacyNoteView(text: "只处理你主动导入的内容；录音只用来判断音域，不保存原始音频。")
            NavigationLink {
                PrivacyPolicyView()
            } label: {
                Label("查看隐私政策", systemImage: "doc.text.magnifyingglass")
                    .font(TypographyTokens.callout.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: ComponentTokens.minTouchTarget)
            }
            .foregroundStyle(DesignSystem.cyan)
            .background(DesignSystem.cyan.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                    .stroke(DesignSystem.cyan.opacity(0.30), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
            .accessibilityIdentifier("privacy-policy-link")
        }
    }

    private var isSoloPractice: Bool {
        store.visibleSongPlan?.scenario == .soloPractice || store.scenarioConfig.scenario == .soloPractice
    }

    private var finalToolsTitle: String {
        isSoloPractice ? "练唱工具" : "到了现场"
    }

    private var finalToolsSubtitle: String {
        isSoloPractice ? "保存练唱安排、看练唱提示，都放这里。" : "发群里、看开场，都放这里。"
    }

    private var exportActionTitle: String {
        isSoloPractice ? "保存练唱单" : "发给朋友"
    }

    private var exportActionSubtitle: String {
        isSoloPractice ? "复制、分享或存一张海报" : "存张海报，直接发群里"
    }

    private var tipsActionTitle: String {
        isSoloPractice ? "练唱小抄" : "开唱小抄"
    }

    private var tipsActionSubtitle: String {
        isSoloPractice ? "忘了下一步就看一眼" : "冷场了就换下一首"
    }
}

private struct PrivacyPolicyView: View {
    private let blocks = PrivacyPolicyDocument.loadFromBundle()

    var body: some View {
        ZStack {
            PremiumBackground()
            FlowPage {
                if blocks.isEmpty {
                    PrivacyNoteView(text: "隐私政策暂时无法打开，请稍后重试。")
                } else {
                    ForEach(blocks) { block in
                        blockView(block)
                    }
                }
            }
        }
        .navigationTitle("隐私政策")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DesignSystem.cyan)
    }

    @ViewBuilder
    private func blockView(_ block: PrivacyPolicyBlock) -> some View {
        switch block.kind {
        case let .heading(level, content):
            inlineText(content)
                .font(level == 1 ? TypographyTokens.title : TypographyTokens.section)
                .foregroundStyle(DesignSystem.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, level == 1 ? 0 : SpacingTokens.sm)
        case let .paragraph(content):
            inlineText(content)
                .font(TypographyTokens.callout)
                .foregroundStyle(DesignSystem.muted)
                .fixedSize(horizontal: false, vertical: true)
        case let .bullet(content):
            HStack(alignment: .firstTextBaseline, spacing: SpacingTokens.xs) {
                Text("•")
                    .font(TypographyTokens.callout.weight(.bold))
                    .foregroundStyle(DesignSystem.cyan)
                    .accessibilityHidden(true)
                inlineText(content)
                    .font(TypographyTokens.callout)
                    .foregroundStyle(DesignSystem.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func inlineText(_ markdown: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let attributed = (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
        return Text(attributed)
    }
}

private struct PrivacyPolicyBlock: Identifiable {
    enum Kind {
        case heading(level: Int, content: String)
        case paragraph(String)
        case bullet(String)
    }

    let id: Int
    let kind: Kind
}

private enum PrivacyPolicyDocument {
    static func loadFromBundle(_ bundle: Bundle = .main) -> [PrivacyPolicyBlock] {
        guard let url = bundle.url(forResource: "PRIVACY", withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return parse(markdown)
    }

    private static func parse(_ markdown: String) -> [PrivacyPolicyBlock] {
        var contents: [PrivacyPolicyBlock.Kind] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            contents.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
            } else if line.hasPrefix("#") {
                flushParagraph()
                let level = min(line.prefix(while: { $0 == "#" }).count, 6)
                let content = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if !content.isEmpty {
                    contents.append(.heading(level: level, content: content))
                }
            } else if line.hasPrefix("- ") {
                flushParagraph()
                contents.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraphLines.append(line)
            }
        }
        flushParagraph()

        return contents.enumerated().map { index, kind in
            PrivacyPolicyBlock(id: index, kind: kind)
        }
    }
}

private struct HomeFeatureSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                Text(title)
                    .font(TypographyTokens.callout.weight(.semibold))
                    .stageText()
                Text(subtitle)
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}

private struct HomeFeatureGrid<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder var content: Content

    var body: some View {
        GlassSurfaceGroup {
            LazyVGrid(columns: columns, spacing: SpacingTokens.sm) {
                content
            }
        }
    }

    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 150), spacing: SpacingTokens.sm)]
    }
}

private struct TonightSnapshotCard: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        GlassCard {
            HStack(alignment: .top, spacing: SpacingTokens.sm) {
                Image(systemName: store.visibleSongPlan == nil ? "music.note.list" : "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(store.visibleSongPlan == nil ? DesignSystem.cyan : DesignSystem.success)
                VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                    Text(title)
                        .font(TypographyTokens.section)
                        .stageText()
                    Text(detail)
                        .font(TypographyTokens.caption)
                        .foregroundStyle(DesignSystem.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let playlist = store.importedPlaylist {
                TagCloud(values: ["\(playlist.songs.count) 首歌", playlist.source.displayName, store.scenarioConfig.scenario.displayName])
            }
            planStateActions
        }
    }

    @ViewBuilder
    private var planStateActions: some View {
        switch store.planGenerationState {
        case .ready:
            if store.canUseReadyPlan {
                PrimaryGradientButton(
                    title: isSoloPractice ? "继续调整练唱单" : "继续调整今晚歌单",
                    systemImage: "slider.horizontal.3"
                ) {
                    store.setStage(.result)
                }
                ResponsiveActionRow {
                    SecondaryGlassButton(title: exportActionTitle, systemImage: "square.and.arrow.up") {
                        store.setStage(.export)
                    }
                    SecondaryGlassButton(title: tipsActionTitle, systemImage: "quote.bubble") {
                        store.setStage(.startTips)
                    }
                }
            } else {
                replanAndViewPreviousActions
            }
        case .stale:
            replanAndViewPreviousActions
        case let .generating(_, previous):
            LoadingStateView(text: "正在按最新选择排歌")
                .accessibilityIdentifier("home-plan-generation-progress")
            ResponsiveActionRow {
                SecondaryGlassButton(title: "取消重排", systemImage: "xmark.circle") {
                    store.cancelCurrentPlanGeneration()
                }
                if previous != nil {
                    SecondaryGlassButton(title: "查看上一版", systemImage: "clock.arrow.circlepath") {
                        store.setStage(.result)
                    }
                }
            }
        case let .failed(message, retryable, previous):
            ErrorStateView(text: message)
                .accessibilityIdentifier("home-plan-generation-failure")
            if retryable {
                PrimaryGradientButton(title: "重新排一版", systemImage: "arrow.clockwise") {
                    store.generatePlan()
                }
            }
            if previous != nil {
                SecondaryGlassButton(title: "查看上一版", systemImage: "clock.arrow.circlepath") {
                    store.setStage(.result)
                }
            }
        case .absent:
            if store.importedPlaylist != nil {
                SecondaryGlassButton(title: resumeActionTitle, systemImage: resumeActionIcon) {
                    store.setStage(store.resumeStage)
                }
            }
        }
    }

    @ViewBuilder
    private var replanAndViewPreviousActions: some View {
        PrimaryGradientButton(
            title: "按最新选择重排",
            systemImage: "arrow.triangle.2.circlepath"
        ) {
            store.generatePlan()
        }
        SecondaryGlassButton(title: "查看上一版", systemImage: "clock.arrow.circlepath") {
            store.setStage(.result)
        }
    }

    private var title: String {
        if let plan = store.visibleSongPlan {
            return plan.title
        }
        if let playlist = store.importedPlaylist {
            return "已放入《\(playlist.title)》"
        }
        return "今晚先做什么？"
    }

    private var detail: String {
        switch store.planGenerationState {
        case .generating:
            return store.visibleSongPlan == nil
                ? "正在按你刚刚的选择排歌，随时可以取消。"
                : "上一版可以继续查看；新一版排好后再分享或看开唱小抄。"
        case let .failed(_, _, previous):
            return previous == nil
                ? "这次没有排好，可以直接重试。"
                : "上一版可以继续查看；重新排好前不会用于分享或开唱小抄。"
        case .stale:
            return "上一版歌单还在；按最新选择重排后，才能分享或查看开唱小抄。"
        case .ready:
            guard store.canUseReadyPlan else {
                return "上一版歌单还在；按最新选择重排后，才能分享或查看开唱小抄。"
            }
            return isSoloPractice
                ? "练唱单已经排好，可以继续调整，也可以保存下来随时看。"
                : "歌单已经排好，可以继续调整，也可以直接发给朋友。"
        case .absent:
            break
        }
        if store.importedPlaylist != nil {
            return "可以看看哪些歌在本地参考里有匹配，或者直接按场景排一版。"
        }
        return "有歌单就导入；想排歌、测音域、看小抄也可以直接用。"
    }

    private var isSoloPractice: Bool {
        store.visibleSongPlan?.scenario == .soloPractice || store.scenarioConfig.scenario == .soloPractice
    }

    private var exportActionTitle: String {
        isSoloPractice ? "保存练唱单" : "直接发给朋友"
    }

    private var tipsActionTitle: String {
        isSoloPractice ? "查看练唱小抄" : "查看开唱小抄"
    }

    private var resumeActionTitle: String {
        switch store.resumeStage {
        case .review:
            return "继续整理这份歌单"
        case .matchReport:
            return "继续核对参考匹配"
        case .scenario:
            return isSoloPractice ? "继续排练唱单" : "继续排今晚歌单"
        default:
            return "继续这份歌单"
        }
    }

    private var resumeActionIcon: String {
        switch store.resumeStage {
        case .review: return "checklist"
        case .matchReport: return "checkmark.seal"
        case .scenario: return "sparkles"
        default: return "arrow.right.circle"
        }
    }
}

private struct HomeFeatureCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let isDisabled: Bool
    let action: () -> Void

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button {
            guard !isDisabled else { return }
            Haptics.selection()
            action()
        } label: {
            VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isDisabled ? DesignSystem.muted : tint)
                VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                    Text(title)
                        .font(TypographyTokens.callout.weight(.semibold))
                    Text(subtitle)
                        .font(TypographyTokens.caption)
                        .foregroundStyle(DesignSystem.muted)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(SpacingTokens.md)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
            .liquidGlassSurface(
                cornerRadius: DesignSystem.cornerRadius,
                tint: isDisabled ? .clear : tint.opacity(0.035),
                fallback: DesignSystem.cardBackgroundLow,
                interactive: !isDisabled
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                    .stroke(DesignSystem.border.opacity(0.72), lineWidth: 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))
        }
        .buttonStyle(PressedScaleButtonStyle(scale: 0.97))
        .foregroundStyle(isDisabled ? DesignSystem.muted : DesignSystem.ink)
        .disabled(isDisabled)
        .accessibilityLabel(title)
        .accessibilityHint(isDisabled ? "排好当前歌单后可用" : subtitle)
    }
}
