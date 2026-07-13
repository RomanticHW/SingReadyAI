import SwiftUI
import SingReadyAISharedKit

struct MatchReportView: View {
    @EnvironmentObject private var store: DemoWorkflowStore
    @State private var visibleResultCount = MatchResultDisplayPolicy.batchSize

    var body: some View {
        FlowPage {
            if let profile = store.preferenceProfile {
                HeroHeader(
                    eyebrow: "核对参考匹配",
                    title: matchHeadline(for: profile.ktvMatchRate),
                    subtitle: store.recommendationInputSource.matchReportSummary(for: profile),
                    systemImage: "chart.bar.xaxis"
                )
                GlassCard {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                            Text("本地参考曲库")
                                .font(TypographyTokens.section)
                                .stageText()
                            Text("参考命中 \(store.matches.filter(\.hasOriginalReferenceMatch).count)/\(store.matches.count)")
                                .font(TypographyTokens.callout.weight(.semibold))
                                .foregroundStyle(DesignSystem.cyan)
                            TagCloud(values: profile.profileTags)
                        }
                        Spacer()
                        MatchRateRing(value: profile.ktvMatchRate)
                    }
                }
                matchMetricsView
                VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                    Text("逐首核对")
                        .font(TypographyTokens.section)
                        .stageText()
                    Text("原歌名、参考命中和待确认候选都列在这里。")
                        .font(TypographyTokens.caption)
                        .foregroundStyle(DesignSystem.muted)
                    LazyVStack(alignment: .leading, spacing: SpacingTokens.sm) {
                        ForEach(store.matches.prefix(visibleResultCount)) { result in
                            MatchResultCard(
                                result: result,
                                onConfirmIdentity: { trackID in
                                    store.confirmMatch(resultID: result.id, trackID: trackID)
                                },
                                onAdoptAlternative: { trackID in
                                    store.adoptAlternative(resultID: result.id, trackID: trackID)
                                }
                            )
                        }
                    }
                    if visibleResultCount < store.matches.count {
                        let nextCount = min(
                            MatchResultDisplayPolicy.batchSize,
                            store.matches.count - visibleResultCount
                        )
                        SecondaryGlassButton(title: "再看 \(nextCount) 首", systemImage: "chevron.down") {
                            visibleResultCount = MatchResultDisplayPolicy.nextVisibleCount(
                                currentCount: visibleResultCount,
                                totalCount: store.matches.count
                            )
                        }
                        .accessibilityIdentifier("match-results-show-more")
                    }
                }
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
                                if !store.externalCandidateTracks.isEmpty {
                                    TagCloud(
                                        values: store.externalCandidateTracks.prefix(6).map(externalCandidateTag),
                                        tint: DesignSystem.amber
                                    )
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
                        PrimaryGradientButton(title: "测一下音域", systemImage: "waveform") {
                            store.setStage(.voice)
                        }
                        .accessibilityIdentifier("match-insights-measure")
                        SecondaryGlassButton(title: "先不测，去选场景", systemImage: "person.3.sequence") {
                            store.continueToScenarioWithoutMeasuring()
                        }
                        .accessibilityIdentifier("match-insights-skip")
                    }
                } else {
                    GlassCard {
                        Text("还没有足够的参考信息")
                            .font(TypographyTokens.section)
                            .stageText()
                        Text("可以先测一下这次唱到的音区；不想测，也能直接按今晚的场景排歌。")
                            .font(TypographyTokens.callout)
                            .foregroundStyle(DesignSystem.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        PrimaryGradientButton(title: "测一下音区", systemImage: "waveform") {
                            store.setStage(.voice)
                        }
                        .accessibilityIdentifier("match-no-insights-measure")
                        SecondaryGlassButton(title: "先不测，去选场景", systemImage: "person.3.sequence") {
                            store.continueToScenarioWithoutMeasuring()
                        }
                        .accessibilityIdentifier("match-no-insights-skip")
                    }
                }
            } else if store.importedPlaylist != nil {
                GlassCard {
                    EmptyStateView(
                        systemImage: "checklist",
                        text: "这份歌单还没完成整理和参考匹配。先确认歌名，再逐首核对本地参考。"
                    )
                    SecondaryGlassButton(title: "先整理这份歌单", systemImage: "checklist") {
                        store.setStage(.review)
                    }
                }
            } else {
                GlassCard {
                    EmptyStateView(systemImage: "chart.bar", text: "把歌单放进来，就能逐首核对本地参考命中和待确认候选。")
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

    private var visibleMatchMetrics: [(title: String, value: String, systemImage: String)] {
        let stats = store.matchStats
        var metrics = [(title: "参考命中", value: "\(stats.exact)", systemImage: "checkmark.seal")]
        if stats.pending > 0 {
            metrics.append((title: "待确认", value: "\(stats.pending)", systemImage: "person.crop.circle.badge.questionmark"))
        }
        if stats.fuzzy > 0 {
            metrics.append((title: "歌名相近", value: "\(stats.fuzzy)", systemImage: "scope"))
        }
        if stats.pendingAlternative > 0 {
            metrics.append((title: "可以替换", value: "\(stats.pendingAlternative)", systemImage: "arrow.triangle.branch"))
        }
        if stats.adoptedAlternative > 0 {
            metrics.append((title: "已采用替代", value: "\(stats.adoptedAlternative)", systemImage: "checkmark.circle"))
        }
        if stats.unmatched > 0 {
            metrics.append((title: "暂时没找到", value: "\(stats.unmatched)", systemImage: "questionmark.circle"))
        }
        return metrics
    }

    @ViewBuilder
    private var matchMetricsView: some View {
        let metrics = visibleMatchMetrics
        if metrics.count == 1, let metric = metrics.first {
            MetricPill(title: metric.title, value: metric.value, systemImage: metric.systemImage)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: SpacingTokens.sm)], spacing: SpacingTokens.sm) {
                ForEach(metrics, id: \.title) { metric in
                    MetricPill(title: metric.title, value: metric.value, systemImage: metric.systemImage)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(metric.title) \(metric.value)")
                        .accessibilityIdentifier(
                            metric.title == "已采用替代"
                                ? "match-metric-adopted-alternative"
                                : "match-metric-\(metric.title)"
                        )
                }
            }
        }
    }

    private var hasSongsNeedingBackup: Bool {
        let stats = store.matchStats
        return stats.pending + stats.fuzzy + stats.pendingAlternative + stats.unmatched > 0
    }

    private var shouldShowBackupSuggestion: Bool {
        hasSongsNeedingBackup || !store.externalCandidateTracks.isEmpty || store.isExpandingExternalCandidates
    }

    private var externalCandidateTitle: String {
        hasSongsNeedingBackup ? "找同歌手的备选" : "再备几首同歌手歌曲"
    }

    private var externalCandidateButtonTitle: String {
        hasSongsNeedingBackup ? "找同歌手备选" : "再找同歌手备选"
    }

    private func externalCandidateTag(_ track: KTVTrack) -> String {
        guard track.isProvisionalExternalCandidate else {
            return "\(track.title) · 本地参考"
        }
        let relation = track.externalCandidateMetadata?.relation.displayName ?? "外部候选"
        return "\(track.title) · \(relation) · 待核对"
    }

    private func matchHeadline(for rate: Double) -> String {
        switch rate {
        case 0.95...:
            return "本地参考基本都命中"
        case 0.75..<0.95:
            return "多数有本地参考"
        case 0.45..<0.75:
            return "部分有本地参考"
        default:
            return "先核对参考候选"
        }
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

            if result.confirmationState == .required {
                ForEach(result.alternatives) { candidate in
                    VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                        Text("同名候选：\(candidate.title) - \(candidate.artist)")
                            .font(TypographyTokens.callout)
                            .foregroundStyle(DesignSystem.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            Haptics.selection()
                            onConfirmIdentity(candidate.id)
                        } label: {
                            Label("确认是这首", systemImage: "checkmark")
                                .font(TypographyTokens.section)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: ComponentTokens.controlHeight)
                        }
                        .buttonStyle(.bordered)
                        .tint(DesignSystem.cyan)
                        .accessibilityLabel("确认是这首：\(candidate.title) - \(candidate.artist)")
                        .accessibilityIdentifier("match-confirm-\(result.importedSong.id.uuidString.lowercased())-\(candidate.id)")
                    }
                }
            } else if !ordinaryAlternatives.isEmpty {
                ForEach(ordinaryAlternatives) { candidate in
                    VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                        Text("替代歌候选：\(candidate.title) - \(candidate.artist)")
                            .font(TypographyTokens.callout)
                            .foregroundStyle(DesignSystem.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            Haptics.selection()
                            onAdoptAlternative(candidate.id)
                        } label: {
                            Label("采用为替代歌", systemImage: "arrow.triangle.branch")
                                .font(TypographyTokens.section)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: ComponentTokens.controlHeight)
                        }
                        .buttonStyle(.bordered)
                        .tint(DesignSystem.cyan)
                        .accessibilityLabel("采用为替代歌：\(candidate.title) - \(candidate.artist)")
                        .accessibilityIdentifier("match-adopt-\(result.importedSong.id.uuidString.lowercased())-\(candidate.id)")
                    }
                }
            } else if result.acceptedTrack == nil {
                Text("本地参考曲库暂时没有合适候选")
                    .font(TypographyTokens.callout)
                    .foregroundStyle(DesignSystem.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stateTitle: String {
        switch result.confirmationState {
        case .required:
            return "待确认"
        case .confirmed:
            return "已确认"
        case .notRequired:
            if result.status == .alternative, result.acceptedTrack != nil {
                return "已采用替代"
            }
            return result.status.displayName
        }
    }

    private var stateTint: Color {
        switch result.confirmationState {
        case .required:
            return DesignSystem.warning
        case .confirmed:
            return DesignSystem.success
        case .notRequired:
            switch result.status {
            case .exact:
                return DesignSystem.success
            case .fuzzy, .alternative:
                return DesignSystem.cyan
            case .unmatched:
                return DesignSystem.muted
            }
        }
    }

    private var ordinaryAlternatives: [KTVTrack] {
        guard result.status != .exact else { return [] }
        return result.alternatives.filter { $0.id != result.acceptedTrack?.id }
    }

    private func referenceLabel(for track: KTVTrack) -> String {
        switch result.status {
        case .exact:
            return "本地参考命中：\(track.title) - \(track.artist)"
        case .fuzzy:
            return "歌名相近参考：\(track.title) - \(track.artist)"
        case .alternative:
            return "已采用替代歌：\(track.title) - \(track.artist)"
        case .unmatched:
            return "本地参考：\(track.title) - \(track.artist)"
        }
    }
}
