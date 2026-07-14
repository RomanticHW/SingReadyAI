import SwiftUI
import SingReadyAISharedKit

#if canImport(UIKit)
import UIKit
#endif

struct SongPlanResultView: View {
    @EnvironmentObject private var store: DemoWorkflowStore
    @State private var toastPresentation: ToastPresentation?

    var body: some View {
        FlowPage {
            if let plan = store.visibleSongPlan {
                HeroHeader(
                    eyebrow: plan.scenario.displayName,
                    title: plan.title,
                    subtitle: userFacingPlanSummary(for: plan),
                    systemImage: "sparkles"
                )
                .accessibilityIdentifier("song-plan-input-source")
                .accessibilityValue(plan.inputSource.displayName)
                if plan.scenario == .carKTV {
                    CarSafetyNoticeView()
                }
                planFreshnessStatus
                ResponsiveActionRow {
                    SecondaryGlassButton(title: "调整场景", systemImage: "slider.horizontal.3") {
                        store.setStage(.scenario)
                    }
                    if store.canUseReadyPlan {
                        SecondaryGlassButton(
                            title: plan.scenario == .soloPractice ? "保存练唱单" : "发给朋友",
                            systemImage: "square.and.arrow.up"
                        ) {
                            store.setStage(.export)
                        }
                    }
                }
                SongPlanNotices(notices: plan.notices)
                if store.canUseReadyPlan, !store.removedTrackIDs.isEmpty {
                    RemovedTracksManagementCard()
                }
                SongPlanTimeline(
                    plan: plan,
                    isReadOnly: !store.canUseReadyPlan
                ) { message, tone in
                    toastPresentation = ToastPresentation(message: message, tone: tone)
                }
            } else {
                planFreshnessStatus
                if case .absent = store.planGenerationState {
                    missingPlanCard
                }
            }
        }
        .floatingToast($toastPresentation)
        .safeAreaInset(edge: .bottom) {
            if store.canUseReadyPlan {
                if let undo = store.lastRemovedTrackUndo {
                    UndoBanner(message: "已移除《\(undo.title)》", actionTitle: "撤销移除") {
                        store.undoLastTrackRemoval()
                    }
                    .padding(.horizontal, DesignSystem.pageHorizontalPadding)
                    .padding(.bottom, SpacingTokens.xs)
                } else if let message = store.feedbackStatusMessage, store.lastFeedbackUndo != nil {
                    UndoBanner(message: message, actionTitle: "撤销上次选择") {
                        store.undoLastFeedback()
                    }
                    .padding(.horizontal, DesignSystem.pageHorizontalPadding)
                    .padding(.bottom, SpacingTokens.xs)
                }
            }
        }
    }

    private var missingPlanCard: some View {
        GlassCard {
            EmptyStateView(
                systemImage: "sparkles",
                text: store.scenarioConfig.scenario == .soloPractice
                    ? "还没有练唱单，先按今天的练唱目标排一份。"
                    : "还没有歌单，先按今晚的局排一份。"
            )
            SecondaryGlassButton(
                title: store.scenarioConfig.scenario == .soloPractice ? "排练唱单" : "排今晚歌单",
                systemImage: "person.3.sequence"
            ) {
                store.setStage(.scenario)
            }
        }
    }

    @ViewBuilder
    private var planFreshnessStatus: some View {
        switch store.planGenerationState {
        case .absent:
            EmptyView()
        case .ready where store.canUseReadyPlan:
            EmptyView()
        case .ready:
            GlassCard {
                Text("这份歌单需要重新排一版")
                    .font(TypographyTokens.section)
                    .stageText()
                Text("当前选择已经有变化，重新排好前，暂时不能分享或生成开唱小抄。")
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryGradientButton(
                    title: "按最新选择重排",
                    systemImage: "arrow.triangle.2.circlepath"
                ) {
                    store.generatePlan()
                }
            }
            .accessibilityIdentifier("stale-plan-banner")
        case .generating:
            GlassCard {
                LoadingStateView(text: "正在按最新选择排歌")
                SecondaryGlassButton(title: "取消重排", systemImage: "xmark.circle") {
                    store.cancelCurrentPlanGeneration()
                }
            }
            .accessibilityIdentifier("plan-generation-progress")
        case let .stale(snapshot):
            GlassCard {
                Text("这是上一版歌单")
                    .font(TypographyTokens.section)
                    .stageText()
                Text("\(snapshot.reason)。重新排好前，暂时不能分享或生成开唱小抄。")
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryGradientButton(
                    title: "按最新选择重排",
                    systemImage: "arrow.triangle.2.circlepath"
                ) {
                    store.generatePlan()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("stale-plan-banner")
        case let .failed(message, retryable, previous):
            GlassCard {
                ErrorStateView(text: message)
                if previous != nil {
                    Text("上一版还在，重新排好前不会用于分享或开唱小抄。")
                        .font(TypographyTokens.caption)
                        .foregroundStyle(DesignSystem.muted)
                }
                if retryable {
                    PrimaryGradientButton(
                        title: "重新排一版",
                        systemImage: "arrow.clockwise"
                    ) {
                        store.generatePlan()
                    }
                }
            }
            .accessibilityIdentifier("plan-generation-failure")
        }
    }
}

private struct RemovedTracksManagementCard: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        GlassCard {
            Text("已移除歌曲")
                .font(TypographyTokens.section)
                .stageText()
            Text("这些歌不会参与重排；可以单独恢复，也可以全部放回候选。")
                .font(TypographyTokens.caption)
                .foregroundStyle(DesignSystem.muted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(store.removedTracksForManagement) { track in
                HStack(alignment: .center, spacing: SpacingTokens.sm) {
                    VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                        Text(track.title)
                            .font(TypographyTokens.callout.weight(.semibold))
                            .stageText()
                        Text(track.artist)
                            .font(TypographyTokens.caption)
                            .foregroundStyle(DesignSystem.muted)
                    }
                    Spacer(minLength: SpacingTokens.sm)
                    Button("恢复") {
                        store.restoreRemovedTrack(trackID: track.id)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("恢复《\(track.title)》")
                }
            }
            if store.removedTracksForManagement.count < store.removedTrackIDs.count {
                Text("还有 \(store.removedTrackIDs.count - store.removedTracksForManagement.count) 首旧记录可通过全部恢复放回。")
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
            }
            SecondaryGlassButton(title: "全部恢复", systemImage: "arrow.uturn.backward.circle") {
                store.restoreAllRemovedTracks()
            }
        }
        .accessibilityIdentifier("removed-tracks-management")
    }
}

struct SongPlanTimeline: View {
    let plan: SongPlan
    let isReadOnly: Bool
    let onToast: (String, ToastTone) -> Void

    var body: some View {
        ForEach(plan.sections) { section in
            VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                Text(section.title)
                    .font(TypographyTokens.section)
                    .stageText()
                    .accessibilityAddTraits(.isHeader)
                Text(section.goal)
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
                ForEach(section.items) { item in
                    SongRecommendationCard(
                        item: item,
                        scenario: plan.scenario,
                        inputSource: plan.inputSource,
                        voiceSource: plan.voiceProfile?.source,
                        hasValidMeasuredRange: plan.voiceProfile?.hasValidMeasuredRange == true,
                        isReadOnly: isReadOnly,
                        onToast: onToast
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SongPlanNotices: View {
    let notices: [String]

    var body: some View {
        ForEach(notices, id: \.self) { notice in
            Label(notice, systemImage: "info.circle")
                .font(TypographyTokens.caption)
                .foregroundStyle(DesignSystem.amber)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SpacingTokens.sm)
                .background(DesignSystem.amber.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
                .accessibilityIdentifier("song-plan-notice")
        }
    }
}

func userFacingPlanSummary(for plan: SongPlan) -> String {
    plan.scenario.planSummary
}

struct SongRecommendationCard: View {
    @EnvironmentObject private var store: DemoWorkflowStore
    @Environment(\.openURL) private var openURL
    @Environment(\.appAccessibilityFlags) private var flags
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isExpanded = false
    let item: SongPlanItem
    let scenario: KTVScenario
    let inputSource: RecommendationInputSource
    let voiceSource: VoiceProfileSource?
    let hasValidMeasuredRange: Bool
    let isReadOnly: Bool
    let onToast: (String, ToastTone) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            summaryHeader
            TagCloud(values: compactTags)
            actionRow
            if isExpanded {
                detailContent
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(SpacingTokens.sm)
        .background(DesignSystem.raisedBackground.opacity(0.72))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                .stroke(DesignSystem.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
        .accessibilityIdentifier(
            item.track.isProvisionalExternalCandidate
                ? "external-candidate-card"
                : "song-recommendation-card"
        )
    }

    @ViewBuilder
    private var summaryHeader: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                accessibilityTrackIdentity
                SuitabilityBadge(title: suitabilityTitle, systemImage: suitabilityIcon, tint: suitabilityTint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: SpacingTokens.sm) {
                accessibilityTrackIdentity
                Spacer(minLength: SpacingTokens.sm)
                SuitabilityBadge(title: suitabilityTitle, systemImage: suitabilityIcon, tint: suitabilityTint)
            }
        }
    }

    private var accessibilityTrackIdentity: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
            Text(item.track.title)
                .font(TypographyTokens.callout.weight(.bold))
                .stageText()
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.82)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
            Text(item.track.artist)
                .font(TypographyTokens.caption)
                .foregroundStyle(DesignSystem.muted)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
        }
    }

    private var compactTags: [String] {
        if item.track.isProvisionalExternalCandidate {
            var tags = [
                item.track.externalCandidateMetadata?.relation.displayName ?? "外部候选",
                item.track.externalCandidateMetadata?.provider.displayName ?? "公开信息来源",
                "待核对"
            ]
            if let firstFeedback = visibleFeedbackTags.first {
                tags.append(firstFeedback.displayName)
            }
            return tags
        }
        var tags = [
            item.track.catalogSource.displayName,
            item.track.genre,
            difficultyTag
        ]
        if item.track.singAlongScore >= 0.72 {
            tags.append(scenario == .soloPractice ? "旋律好跟" : "适合合唱")
        }
        if let firstFeedback = visibleFeedbackTags.first {
            tags.append(firstFeedback.displayName)
        }
        return tags
    }

    private var visibleFeedbackTags: [SongFeedbackKind] {
        guard !isReadOnly else { return [] }
        return item.feedbackTags.filter {
            scenario != .soloPractice || $0 != .chorusFriendly
        }
    }

    private var suitabilityTitle: String {
        if item.track.isProvisionalExternalCandidate {
            return "待核对"
        }
        if item.score >= 0.80 {
            return "很适合"
        }
        if item.score >= 0.70 {
            return "适合唱"
        }
        return "可备选"
    }

    private var suitabilityIcon: String {
        if item.track.isProvisionalExternalCandidate {
            return "questionmark.circle"
        }
        if item.score >= 0.80 {
            return "checkmark.seal.fill"
        }
        if item.score >= 0.70 {
            return "checkmark.circle"
        }
        return "music.note"
    }

    private var suitabilityTint: Color {
        if item.track.isProvisionalExternalCandidate {
            return DesignSystem.amber
        }
        if item.score >= 0.80 {
            return DesignSystem.success
        }
        if item.score >= 0.70 {
            return DesignSystem.cyan
        }
        return DesignSystem.amber
    }

    private var difficultyTag: String {
        switch item.track.difficulty {
        case ...2:
            return "轻松唱"
        case 3:
            return "不算难"
        case 4:
            return "有点挑战"
        default:
            return "偏难"
        }
    }

    private var actionRow: some View {
        HStack(spacing: SpacingTokens.xs) {
            if !isReadOnly {
                compactActionButton(item.isLocked ? "取消锁定" : "锁定", systemImage: item.isLocked ? "lock.open" : "lock", tint: DesignSystem.amber) {
                    store.toggleLock(trackID: item.track.id)
                }
            }
            Button {
                Haptics.selection()
                withAnimation(flags.reduceMotion ? nil : MotionTokens.micro) {
                    isExpanded.toggle()
                }
            } label: {
                Label(isExpanded ? "收起" : "详情", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                    .font(TypographyTokens.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: ComponentTokens.minTouchTarget)
            }
            .buttonStyle(PressedScaleButtonStyle(scale: 0.97))
            .foregroundStyle(DesignSystem.ink)
            .background(DesignSystem.cardBackgroundSolid)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
            .accessibilityIdentifier("song-detail-action")
            .accessibilityLabel("\(isExpanded ? "收起" : "详情")《\(item.track.title)》")
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            detailActionRow
            if let note = item.track.confidenceNote {
                Label(note, systemImage: "info.circle")
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.amber)
            }
            if !item.track.isProvisionalExternalCandidate,
               hasValidMeasuredRange,
               let advice = item.singingAdvice {
                Label("\(advice.title)：\(advice.detail)", systemImage: advice.level == .originalKey ? "checkmark.circle" : "music.note.list")
                    .font(TypographyTokens.caption)
                    .foregroundStyle(advice.level == .originalKey ? DesignSystem.success : DesignSystem.warning)
            }
            ForEach(visibleReasons, id: \.self) { reason in
                Label(reason, systemImage: "checkmark.circle")
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
            }
            if !item.track.isProvisionalExternalCandidate {
                ForEach(item.riskWarnings, id: \.self) { warning in
                    RiskBadge(text: warning)
                }
                if !item.alternatives.isEmpty {
                    AlternativeSongChips(tracks: Array(item.alternatives.prefix(2)))
                }
                SongFitBreakdownView(
                    breakdown: item.scoreBreakdown,
                    scenario: scenario,
                    inputSource: inputSource,
                    hasValidMeasuredRange: hasValidMeasuredRange
                )
            }
            if !isReadOnly {
                Text("这首怎么样")
                    .font(TypographyTokens.caption.weight(.semibold))
                    .foregroundStyle(DesignSystem.muted)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: SpacingTokens.xs)], spacing: SpacingTokens.xs) {
                    feedbackButton(.sung, systemImage: "music.mic")
                    feedbackButton(.liked, systemImage: "heart")
                    feedbackButton(.tooHigh, systemImage: "arrow.up.circle")
                    feedbackButton(.unfamiliar, systemImage: "questionmark.circle")
                    if scenario != .soloPractice {
                        feedbackButton(.chorusFriendly, systemImage: "person.3")
                    }
                    compactActionButton("移除", systemImage: "minus.circle", tint: DesignSystem.danger) {
                        let isLocked = store.lockedTrackIDs.contains(item.track.id)
                        let message = store.removeTrack(trackID: item.track.id)
                        onToast(message, isLocked ? .warning : .success)
                    }
                    .accessibilityLabel("移除《\(item.track.title)》并补位")
                }
            }
        }
        .padding(.top, SpacingTokens.xs)
    }

    private var visibleReasons: [String] {
        item.reasons.filter {
            inputSource.allowsRecommendationReason($0, voiceSource: voiceSource)
                && (hasValidMeasuredRange || !$0.contains("本次唱到的音区"))
                && (scenario != .soloPractice || !isGroupOnlyReason($0))
        }
    }

    private func isGroupOnlyReason(_ reason: String) -> Bool {
        ["合唱", "大家", "朋友局", "现场", "冷场", "今晚"].contains { reason.contains($0) }
    }

    private var detailActionRow: some View {
        HStack(spacing: SpacingTokens.xs) {
            if let actionURL = item.actionURL {
                compactActionButton("搜索", systemImage: "safari", tint: DesignSystem.cyan) {
                    openURL(actionURL)
                }
            }
            compactActionButton("复制", systemImage: "doc.on.doc", tint: DesignSystem.success) {
                copy("\(item.track.title) - \(item.track.artist)")
            }
        }
    }

    private func feedbackButton(_ kind: SongFeedbackKind, systemImage: String) -> some View {
        Button {
            Haptics.selection()
            store.applyFeedback(trackID: item.track.id, kind: kind)
        } label: {
            Label(kind.displayName, systemImage: systemImage)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .frame(minHeight: ComponentTokens.minTouchTarget)
        }
        .buttonStyle(PressedScaleButtonStyle(scale: 0.97))
        .foregroundStyle(DesignSystem.ink)
        .background(item.feedbackTags.contains(kind) ? DesignSystem.amber.opacity(0.22) : DesignSystem.cyan.opacity(0.14))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                .stroke(item.feedbackTags.contains(kind) ? DesignSystem.amber.opacity(0.46) : DesignSystem.cyan.opacity(0.28), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
        .font(TypographyTokens.caption.weight(.semibold))
        .accessibilityIdentifier(kind.displayName)
        .accessibilityLabel("\(kind.displayName)《\(item.track.title)》")
        .accessibilityValue(item.feedbackTags.contains(kind) ? "已选择" : "未选择")
        .accessibilityHint("轻点切换这首歌的反馈")
        .accessibilityAddTraits(item.feedbackTags.contains(kind) ? .isSelected : [])
    }

    private func compactActionButton(_ title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(TypographyTokens.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.74)
                .frame(maxWidth: .infinity)
                .frame(minHeight: ComponentTokens.minTouchTarget)
        }
        .buttonStyle(PressedScaleButtonStyle(scale: 0.97))
        .foregroundStyle(DesignSystem.ink)
        .background(tint.opacity(0.14))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                .stroke(tint.opacity(0.30), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
        .accessibilityIdentifier(title)
        .accessibilityLabel("\(title)《\(item.track.title)》")
    }

    private func copy(_ value: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #endif
        Haptics.success()
        onToast("已复制到剪贴板", .success)
    }
}
