import SwiftUI
import SingReadyAISharedKit

struct MatchReportView: View {
    @Environment(\.appAccessibilityFlags) private var flags
    @EnvironmentObject private var store: DemoWorkflowStore
    @State private var visiblePendingCount = 20
    @State private var visibleUnmatchedCount = 20
    @State private var visibleConfirmedCount = 20
    @State private var showsConfirmedSongs = false

    private let resultBatchSize = 20

    var body: some View {
        FlowPage {
            if let profile = store.preferenceProfile,
               let preparation = store.playlistPreparationSummary {
                HeroHeader(
                    eyebrow: "歌单已整理",
                    title: "已匹配 \(preparation.verifiedCount) 首，可以直接排歌",
                    subtitle: "已确认的歌会直接参与排歌。待确认和暂时没找到的歌先放在这里，不影响继续。",
                    systemImage: "checkmark.seal"
                )
                GlassCard {
                    Text("这份歌单的处理结果")
                        .font(TypographyTokens.section)
                        .stageText()
                    Text(matchOutcomeSummary(for: preparation))
                    .font(TypographyTokens.callout.weight(.semibold))
                    .foregroundStyle(DesignSystem.cyan)
                    .accessibilityLabel(matchOutcomeSummary(for: preparation))
                    .accessibilityIdentifier("match-outcome-summary")
                    Text("共导入 \(preparation.importedCount) 首，其中 \(preparation.validReviewedCount) 首已进入本次匹配。")
                        .font(TypographyTokens.caption)
                        .foregroundStyle(DesignSystem.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PrimaryGradientButton(
                    title: "按这份歌单排一版",
                    systemImage: "sparkles"
                ) {
                    store.continueToScenarioWithoutMeasuring()
                }
                .disabled(
                    !preparation.canContinue
                        || store.isApplyingMatchReviewAction
                        || store.isWorking
                )
                .accessibilityIdentifier("match-build-plan-action")
                SecondaryGlassButton(title: "先测一下音区（可选）", systemImage: "waveform") {
                    store.setStage(.voice)
                }
                .disabled(store.isApplyingMatchReviewAction || store.isWorking)
                .accessibilityIdentifier("match-measure-optional")
                if store.isApplyingMatchReviewAction {
                    GlassCard {
                        LoadingStateView(text: "正在保存你的选择")
                    }
                    .accessibilityIdentifier("match-review-saving")
                }
                if !pendingMatches.isEmpty {
                    matchSection(
                        title: "待确认 \(pendingMatches.count) 首",
                        subtitle: "不处理也能继续；如果你认得候选，可以顺手确认或采用替代。",
                        matches: pendingMatches,
                        visibleCount: $visiblePendingCount,
                        accessibilityIdentifier: "match-pending-section"
                    )
                }
                if !unmatchedMatches.isEmpty {
                    matchSection(
                        title: "暂时没找到 \(unmatchedMatches.count) 首",
                        subtitle: "这些歌先保留在原歌单里，不会进入这次排歌，也不影响继续。",
                        matches: unmatchedMatches,
                        visibleCount: $visibleUnmatchedCount,
                        accessibilityIdentifier: "match-unmatched-section"
                    )
                }
                confirmedSongsSection
                if shouldShowBackupSuggestion {
                    GlassCard {
                        HStack(alignment: .top, spacing: SpacingTokens.sm) {
                            Image(systemName: "link.badge.plus")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(DesignSystem.cyan)
                            VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                                Text(externalCandidateTitle)
                                    .font(TypographyTokens.section)
                                    .stageText()
                                Text(store.externalCandidateStatus)
                                    .font(TypographyTokens.caption)
                                    .foregroundStyle(DesignSystem.muted)
                                if !store.externalCandidates.isEmpty {
                                    VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                                        ForEach(
                                            Array(store.externalCandidates.prefix(6).enumerated()),
                                            id: \.offset
                                        ) { index, candidate in
                                            VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                                                Text(candidate.title)
                                                    .font(TypographyTokens.callout.weight(.semibold))
                                                    .stageText()
                                                Text(
                                                    "\(candidate.artist ?? "歌手待核对") · "
                                                        + "\(candidate.source.displayName) · 待核对"
                                                )
                                                .font(TypographyTokens.caption)
                                                .foregroundStyle(DesignSystem.muted)
                                                if let externalURL = validatedPublicURL(candidate.externalURL) {
                                                    Link("查看公开来源", destination: externalURL)
                                                        .font(TypographyTokens.caption.weight(.semibold))
                                                        .foregroundStyle(DesignSystem.cyan)
                                                }
                                            }
                                            if index < min(store.externalCandidates.count, 6) - 1 {
                                                Divider().overlay(DesignSystem.border)
                                            }
                                        }
                                    }
                                    Text("公开候选只供你参考，不会自动加进排歌结果。")
                                        .font(TypographyTokens.caption)
                                        .foregroundStyle(DesignSystem.amber)
                                }
                                Text("点击后会从最多 4 首歌中提取歌手，只发送歌手名称到 Apple 公开搜索，用于查找同歌手备选；不会发送录音或完整歌单。")
                                    .font(TypographyTokens.caption)
                                    .foregroundStyle(DesignSystem.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("external-candidate-privacy-note")
                            }
                        }
                        SecondaryGlassButton(
                            title: store.isExpandingExternalCandidates ? "正在找" : externalCandidateButtonTitle,
                            systemImage: "wand.and.stars"
                        ) {
                            Task { await store.expandSimilarCandidates() }
                        }
                        .disabled(store.isExpandingExternalCandidates)
                        .accessibilityIdentifier("external-candidate-search-button")
                    }
                }
                if profile.hasReferenceInsights {
                    PreferenceInsightCard(
                        profile: profile,
                        inputSource: store.recommendationInputSource
                    )
                    GlassCard {
                        Text("适合哪些局")
                            .font(TypographyTokens.section)
                            .stageText()
                        ForEach(KTVScenario.allCases, id: \.self) { scenario in
                            MetricBar(title: scenario.displayName, value: profile.scenarioFitScores[scenario.rawValue] ?? 0, valueLabel: fitLabel)
                        }
                    }
                    GlassCard {
                        Text("想排得更贴自己")
                            .font(TypographyTokens.section)
                            .stageText()
                        MetricBar(title: "好不好唱", value: min(1, profile.averageDifficulty / 5), tint: DesignSystem.amber, valueLabel: difficultyLabel)
                        MetricBar(title: "高音多不多", value: profile.highNoteRisk, tint: DesignSystem.warning, valueLabel: pressureLabel)
                        MetricBar(title: "合唱好接", value: profile.chorusFriendliness, tint: DesignSystem.success, valueLabel: fitLabel)
                    }
                }
            } else if store.importedPlaylist != nil {
                GlassCard {
                    EmptyStateView(
                        systemImage: "checklist",
                        text: "这份歌单还没完成整理和批量匹配，先补齐缺少的歌名。"
                    )
                    SecondaryGlassButton(title: "先整理这份歌单", systemImage: "checklist") {
                        store.setStage(.review)
                    }
                }
            } else {
                GlassCard {
                    EmptyStateView(systemImage: "chart.bar", text: "把歌单放进来，就能批量匹配并直接排成一份可唱的顺序。")
                    SecondaryGlassButton(title: "导入歌单", systemImage: "tray.and.arrow.down") {
                        store.setStage(.importHub)
                    }
                }
            }
        }
        .onDisappear {
            store.cancelExternalCandidateRequest(reportStatus: true)
        }
    }

    private var pendingMatches: [MatchResult] {
        store.matches.filter(\.isPending)
    }

    private var unmatchedMatches: [MatchResult] {
        store.matches.filter(\.isUnmatched)
    }

    private var confirmedMatches: [MatchResult] {
        store.matches.filter(\.isVerified)
    }

    private func matchOutcomeSummary(for preparation: PlaylistPreparationSummary) -> String {
        "已确认 \(preparation.verifiedCount) / "
            + "待确认 \(preparation.pendingCount) / "
            + "未找到 \(preparation.unmatchedCount)"
    }

    private func matchSection(
        title: String,
        subtitle: String,
        matches: [MatchResult],
        visibleCount: Binding<Int>,
        accessibilityIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                Text(title)
                    .font(TypographyTokens.section)
                    .stageText()
                Text(subtitle)
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVStack(alignment: .leading, spacing: SpacingTokens.sm) {
                ForEach(matches.prefix(visibleCount.wrappedValue)) { result in
                    resultCard(result)
                }
            }
            if visibleCount.wrappedValue < matches.count {
                let nextCount = min(resultBatchSize, matches.count - visibleCount.wrappedValue)
                SecondaryGlassButton(title: "再看 \(nextCount) 首", systemImage: "chevron.down") {
                    visibleCount.wrappedValue = min(
                        matches.count,
                        visibleCount.wrappedValue + resultBatchSize
                    )
                }
                .accessibilityIdentifier("\(accessibilityIdentifier)-show-more")
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private var confirmedSongsSection: some View {
        if !confirmedMatches.isEmpty {
            VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                Button {
                    Haptics.selection()
                    withAnimation(flags.reduceMotion ? nil : MotionTokens.micro) {
                        showsConfirmedSongs.toggle()
                    }
                } label: {
                    HStack(spacing: SpacingTokens.sm) {
                        VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                            Text("已确认 \(confirmedMatches.count) 首")
                                .font(TypographyTokens.section)
                                .stageText()
                            Text("默认收起；想换成其他候选时再打开。")
                                .font(TypographyTokens.caption)
                                .foregroundStyle(DesignSystem.muted)
                        }
                        Spacer(minLength: SpacingTokens.sm)
                        Image(systemName: showsConfirmedSongs ? "chevron.up" : "chevron.down")
                            .font(TypographyTokens.callout.weight(.semibold))
                            .foregroundStyle(DesignSystem.cyan)
                    }
                    .frame(minHeight: ComponentTokens.minTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsConfirmedSongs ? "收起已确认歌曲" : "查看已确认歌曲")
                .accessibilityIdentifier("match-confirmed-toggle")

                if showsConfirmedSongs {
                    LazyVStack(alignment: .leading, spacing: SpacingTokens.sm) {
                        ForEach(confirmedMatches.prefix(visibleConfirmedCount)) { result in
                            resultCard(result)
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    if visibleConfirmedCount < confirmedMatches.count {
                        let nextCount = min(
                            resultBatchSize,
                            confirmedMatches.count - visibleConfirmedCount
                        )
                        SecondaryGlassButton(title: "再看 \(nextCount) 首", systemImage: "chevron.down") {
                            visibleConfirmedCount = min(
                                confirmedMatches.count,
                                visibleConfirmedCount + resultBatchSize
                            )
                        }
                        .accessibilityIdentifier("match-confirmed-show-more")
                    }
                }
            }
            .padding(SpacingTokens.md)
            .liquidGlassSurface(
                cornerRadius: DesignSystem.cornerRadius,
                tint: DesignSystem.cyan.opacity(0.025),
                fallback: DesignSystem.cardBackgroundLow
            )
            .accessibilityIdentifier("match-confirmed-section")
        }
    }

    private func resultCard(_ result: MatchResult) -> some View {
        MatchResultCard(
            result: result,
            onConfirmIdentity: { trackID in
                store.confirmMatch(resultID: result.id, trackID: trackID)
            },
            onAdoptAlternative: { trackID in
                store.adoptAlternative(resultID: result.id, trackID: trackID)
            }
        )
        .disabled(store.isApplyingMatchReviewAction || store.isWorking)
    }

    private var hasSongsNeedingBackup: Bool {
        let stats = store.matchStats
        return stats.pending + stats.unmatched > 0
    }

    private var shouldShowBackupSuggestion: Bool {
        hasSongsNeedingBackup || !store.externalCandidates.isEmpty || store.isExpandingExternalCandidates
    }

    private var externalCandidateTitle: String {
        hasSongsNeedingBackup ? "找同歌手的备选" : "再备几首同歌手歌曲"
    }

    private var externalCandidateButtonTitle: String {
        hasSongsNeedingBackup ? "找同歌手备选" : "再找同歌手备选"
    }

    private func validatedPublicURL(_ url: URL?) -> URL? {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        return url
    }

    private func fitLabel(_ value: Double) -> String {
        switch value {
        case 0.78...: return "很适合"
        case 0.55...: return "可以"
        case 0.32...: return "一般"
        default: return "不太适合"
        }
    }

    private func difficultyLabel(_ value: Double) -> String {
        switch value {
        case 0.78...: return "偏难"
        case 0.55...: return "适中"
        case 0.32...: return "轻松"
        default: return "很轻松"
        }
    }

    private func pressureLabel(_ value: Double) -> String {
        switch value {
        case 0.72...: return "偏多"
        case 0.45...: return "有一些"
        case 0.18...: return "还好"
        default: return "很少"
        }
    }
}

private struct MatchResultCard: View {
    let result: MatchResult
    let onConfirmIdentity: (String) -> Void
    let onAdoptAlternative: (String) -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                Text(result.importedSong.title)
                    .font(TypographyTokens.section)
                    .stageText()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("match-result-\(result.importedSong.id.uuidString.lowercased())")
                Text(result.importedSong.artist ?? "未提供歌手")
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
                Text(stateTitle)
                    .font(TypographyTokens.caption.weight(.semibold))
                    .foregroundStyle(stateTint)
                Text(result.reason)
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let track = result.acceptedTrack {
                Label(referenceLabel(for: track), systemImage: "checkmark.circle")
                    .font(TypographyTokens.callout)
                    .foregroundStyle(DesignSystem.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            candidateActions
        }
    }

    @ViewBuilder
    private var candidateActions: some View {
        switch result.disposition {
        case .identityConfirmationRequired:
            ForEach(result.candidateTracks) { candidate in
                if result.canConfirmIdentity(track: candidate) {
                    identityCandidateChoice(candidate)
                } else {
                    candidateChoice(
                        candidate,
                        context: "相近候选",
                        actionTitle: "用这首替代",
                        systemImage: "arrow.triangle.branch",
                        accessibilityIdentifier: "match-adopt-\(result.importedSong.id.uuidString.lowercased())-\(candidate.id)",
                        action: onAdoptAlternative
                    )
                }
            }
            ForEach(result.suggestedAlternatives) { candidate in
                candidateChoice(
                    candidate,
                    context: "替代建议",
                    actionTitle: "用这首替代",
                    systemImage: "arrow.triangle.branch",
                    accessibilityIdentifier: "match-adopt-\(result.importedSong.id.uuidString.lowercased())-\(candidate.id)",
                    action: onAdoptAlternative
                )
            }
        case .alternativeSuggested:
            ForEach(result.candidateTracks) { candidate in
                candidateChoice(
                    candidate,
                    context: "替代建议",
                    actionTitle: "用这首替代",
                    systemImage: "arrow.triangle.branch",
                    accessibilityIdentifier: "match-adopt-\(result.importedSong.id.uuidString.lowercased())-\(candidate.id)",
                    action: onAdoptAlternative
                )
            }
        case .acceptedOriginalExact, .acceptedOriginalConfirmed, .adoptedAlternative:
            ForEach(result.suggestedAlternatives.prefix(3)) { candidate in
                candidateChoice(
                    candidate,
                    context: "可换候选",
                    actionTitle: "换成这首",
                    systemImage: "arrow.triangle.branch",
                    accessibilityIdentifier: "match-adopt-\(result.importedSong.id.uuidString.lowercased())-\(candidate.id)",
                    action: onAdoptAlternative
                )
            }
        case .unmatched:
            Text("暂时没找到合适候选，不影响继续排歌。")
                .font(TypographyTokens.callout)
                .foregroundStyle(DesignSystem.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func identityCandidateChoice(_ candidate: KTVTrack) -> some View {
        VStack(alignment: .leading, spacing: SpacingTokens.xs) {
            Text("同名候选：\(candidate.title) - \(candidate.artist)")
                .font(TypographyTokens.callout)
                .foregroundStyle(DesignSystem.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Haptics.selection()
                onConfirmIdentity(candidate.id)
            } label: {
                Label("就是这首", systemImage: "checkmark")
                    .font(TypographyTokens.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: ComponentTokens.controlHeight)
            }
            .buttonStyle(.bordered)
            .tint(DesignSystem.cyan)
            .accessibilityLabel("就是这首：\(candidate.title) - \(candidate.artist)")
            .accessibilityIdentifier(
                "match-confirm-\(result.importedSong.id.uuidString.lowercased())-\(candidate.id)"
            )
        }
    }

    private func candidateChoice(
        _ candidate: KTVTrack,
        context: String,
        actionTitle: String,
        systemImage: String,
        accessibilityIdentifier: String,
        action: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: SpacingTokens.xs) {
            Text("\(context)：\(candidate.title) - \(candidate.artist)")
                .font(TypographyTokens.callout)
                .foregroundStyle(DesignSystem.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Haptics.selection()
                action(candidate.id)
            } label: {
                Label(actionTitle, systemImage: systemImage)
                    .font(TypographyTokens.section)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: ComponentTokens.controlHeight)
            }
            .buttonStyle(.bordered)
            .tint(DesignSystem.cyan)
            .accessibilityLabel("\(actionTitle)：\(candidate.title) - \(candidate.artist)")
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private var stateTitle: String {
        switch result.disposition {
        case .identityConfirmationRequired, .alternativeSuggested:
            return "待确认"
        case .acceptedOriginalConfirmed:
            return "已确认"
        case .acceptedOriginalExact:
            return "已确认"
        case .adoptedAlternative:
            return "已采用替代"
        case .unmatched:
            return "暂时没找到"
        }
    }

    private var stateTint: Color {
        switch result.disposition {
        case .identityConfirmationRequired, .alternativeSuggested:
            return DesignSystem.warning
        case .acceptedOriginalExact, .acceptedOriginalConfirmed, .adoptedAlternative:
            return DesignSystem.success
        case .unmatched:
            return DesignSystem.muted
        }
    }

    private func referenceLabel(for track: KTVTrack) -> String {
        switch result.disposition {
        case .acceptedOriginalExact:
            return "本地参考命中：\(track.title) - \(track.artist)"
        case .acceptedOriginalConfirmed:
            return "已确认原曲：\(track.title) - \(track.artist)"
        case .adoptedAlternative:
            return "已采用替代歌：\(track.title) - \(track.artist)"
        case .identityConfirmationRequired, .alternativeSuggested, .unmatched:
            return "本地参考：\(track.title) - \(track.artist)"
        }
    }
}
