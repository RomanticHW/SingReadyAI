import Foundation

public struct RecommendationCapacityPolicy: Sendable {
    public init() {}

    public func targetCount(forDurationMinutes durationMinutes: Int) -> Int {
        min(30, max(6, Int(ceil(Double(max(0, durationMinutes)) / 5.0))))
    }

    public func effectiveTargetCount(durationMinutes: Int, lockedTrackCount: Int) -> Int {
        max(targetCount(forDurationMinutes: durationMinutes), max(0, lockedTrackCount))
    }

    public func sectionQuotas(targetCount: Int, sectionCount: Int) -> [Int] {
        guard sectionCount > 0 else { return [] }
        let safeTarget = max(0, targetCount)
        let base = safeTarget / sectionCount
        let remainder = safeTarget % sectionCount
        return (0..<sectionCount).map { base + ($0 < remainder ? 1 : 0) }
    }
}

public struct RecommendationEngine: Sendable {
    private let reasonBuilder: RecommendationReasonBuilder
    private let singingAdvisor: SingingAdjustmentAdvisor
    private let actionLinkBuilder: SongActionLinkBuilder

    public init(
        reasonBuilder: RecommendationReasonBuilder = RecommendationReasonBuilder(),
        singingAdvisor: SingingAdjustmentAdvisor = SingingAdjustmentAdvisor(),
        actionLinkBuilder: SongActionLinkBuilder = SongActionLinkBuilder()
    ) {
        self.reasonBuilder = reasonBuilder
        self.singingAdvisor = singingAdvisor
        self.actionLinkBuilder = actionLinkBuilder
    }

    public func generatePlan(
        matches: [MatchResult],
        preferenceProfile: PreferenceProfile,
        voiceProfile: VoiceProfile,
        scenario: ScenarioConfig,
        catalog: [KTVTrack],
        generationContext: SongPlanGenerationContext,
        inputSource: RecommendationInputSource = .legacyUnknown,
        lockedTrackIDs: Set<String> = [],
        removedTrackIDs: Set<String> = [],
        feedbackProfile: SongFeedbackProfile = .empty
    ) throws -> SongPlan {
        let importedArtistCounts = matches.reduce(into: [String: Int]()) { result, match in
            if let artist = match.importedSong.artist {
                result[artist, default: 0] += 1
            }
        }
        let candidates = try RecommendationCandidateGate().candidates(
            matches: matches,
            preferenceProfile: preferenceProfile,
            scenario: scenario,
            catalog: catalog,
            lockedTrackIDs: lockedTrackIDs
        )
            .filter {
                !removedTrackIDs.contains($0.track.id)
                    || lockedTrackIDs.contains($0.track.id)
            }
        let scored: [ScoredTrack] = candidates.map { candidate in
            let breakdown = scoreBreakdown(
                track: candidate.track,
                preferenceProfile: preferenceProfile,
                voiceProfile: voiceProfile,
                scenario: scenario,
                importedArtistCounts: importedArtistCounts,
                feedbackProfile: feedbackProfile
            )
            return ScoredTrack(
                track: candidate.track,
                origin: candidate.origin,
                scoreBreakdown: breakdown
            )
        }
        .sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            let leftKey = RecommendationCandidateGate.semanticKey(for: $0.track)
            let rightKey = RecommendationCandidateGate.semanticKey(for: $1.track)
            if leftKey != rightKey {
                return leftKey < rightKey
            }
            return $0.track.id < $1.track.id
        }

        let capacityPolicy = RecommendationCapacityPolicy()
        let baseTargetCount = capacityPolicy.targetCount(forDurationMinutes: scenario.durationMinutes)
        let availableLockedCount = scored.filter { lockedTrackIDs.contains($0.track.id) }.count
        let desiredTargetCount = capacityPolicy.effectiveTargetCount(
            durationMinutes: scenario.durationMinutes,
            lockedTrackCount: availableLockedCount
        )
        let outputTargetCount = min(scored.count, desiredTargetCount)
        let templates = scenario.scenario.sectionTemplates
        let sectionQuotas = capacityPolicy.sectionQuotas(
            targetCount: outputTargetCount,
            sectionCount: templates.count
        )
        var sections = templates.map {
            SongPlanSection(role: $0.role, title: $0.title, goal: $0.goal, items: [])
        }
        var selectedIDs = Set<String>()
        var lastArtist: String?
        var slowStreak = 0

        func append(_ scoredTrack: ScoredTrack, to sectionIndex: Int, isLocked: Bool) {
            selectedIDs.insert(scoredTrack.track.id)
            lastArtist = scoredTrack.track.artist
            slowStreak = scoredTrack.track.energy < 0.45 ? slowStreak + 1 : 0
            sections[sectionIndex].items.append(planItem(
                scoredTrack: scoredTrack,
                preferenceProfile: preferenceProfile,
                voiceProfile: voiceProfile,
                scenario: scenario,
                importedArtistCounts: importedArtistCounts,
                inputSource: inputSource,
                catalog: catalog,
                isLocked: isLocked,
                feedbackProfile: feedbackProfile
            ))
        }

        for lockedTrack in scored where lockedTrackIDs.contains(lockedTrack.track.id) {
            let preferredIndex = sections.indices.first {
                sections[$0].items.count < sectionQuotas[$0]
                    && sectionAllows(lockedTrack.track, role: sections[$0].role, scenario: scenario)
            }
            let fallbackIndex = sections.indices.first { sections[$0].items.count < sectionQuotas[$0] }
            guard let sectionIndex = preferredIndex ?? fallbackIndex else { continue }
            append(lockedTrack, to: sectionIndex, isLocked: true)
        }

        for sectionIndex in sections.indices {
            while sections[sectionIndex].items.count < sectionQuotas[sectionIndex] {
                let unselected = scored.filter { !selectedIDs.contains($0.track.id) }
                guard !unselected.isEmpty else { break }
                let role = sections[sectionIndex].role
                let chosen = unselected.first {
                    sectionAllows($0.track, role: role, scenario: scenario)
                        && sequencingAllows(
                            $0.track,
                            selectedIDsAreEmpty: selectedIDs.isEmpty,
                            lastArtist: lastArtist,
                            slowStreak: slowStreak
                        )
                } ?? unselected.first {
                    sectionAllows($0.track, role: role, scenario: scenario)
                } ?? unselected.first {
                    sequencingAllows(
                        $0.track,
                        selectedIDsAreEmpty: selectedIDs.isEmpty,
                        lastArtist: lastArtist,
                        slowStreak: slowStreak
                    )
                } ?? unselected[0]
                append(chosen, to: sectionIndex, isLocked: false)
            }
        }

        let adjustedSections = enforceHardRules(
            sections: sections,
            scored: scored,
            selectedIDs: selectedIDs,
            scenario: scenario,
            preferenceProfile: preferenceProfile,
            voiceProfile: voiceProfile,
            importedArtistCounts: importedArtistCounts,
            inputSource: inputSource,
            catalog: catalog,
            lockedTrackIDs: lockedTrackIDs,
            feedbackProfile: feedbackProfile
        )
        var notices: [String] = []
        if scored.count < desiredTargetCount {
            notices.append("可用候选只有 \(scored.count) 首，候选不足目标 \(desiredTargetCount) 首，已排入全部候选。")
        }
        if availableLockedCount > baseTargetCount {
            notices.append("已锁定 \(availableLockedCount) 首，超过 \(scenario.durationMinutes) 分钟建议的 \(baseTargetCount) 首，歌单已扩展为 \(availableLockedCount) 首。")
        }
        let adjustedItems = adjustedSections.flatMap(\.items)
        if scenario.scenario == .birthday,
           !adjustedItems.contains(where: { isBirthdayHardRuleEligible($0.track) }) {
            notices.append("受锁定歌曲或可用候选约束，生日氛围规则未能完全满足。")
        }
        if scenario.scenario.isGroupScenario {
            let requiredChorusCount = Int(ceil(Double(adjustedItems.count) * 0.3))
            let actualChorusCount = adjustedItems.filter { isChorusFriendly($0.track) }.count
            if actualChorusCount < requiredChorusCount {
                notices.append("受锁定歌曲或可用候选约束，合唱比例规则未能完全满足。")
            }
        }
        let generationSummary = try SongPlanGenerationSummary(
            context: generationContext,
            items: adjustedItems
        )

        return SongPlan(
            title: "\(scenario.scenario.displayName)歌单",
            scenario: scenario.scenario,
            inputSource: inputSource,
            scenarioConfig: scenario,
            voiceProfile: voiceProfile,
            preferenceSummary: planSummary(preferenceProfile: preferenceProfile, scenario: scenario, inputSource: inputSource),
            generationSummary: generationSummary,
            sections: adjustedSections,
            notices: notices
        )
    }

    private func planSummary(
        preferenceProfile: PreferenceProfile,
        scenario: ScenarioConfig,
        inputSource: RecommendationInputSource
    ) -> String {
        guard inputSource.allowsPlaylistPersonalization,
              preferenceProfile.hasReferenceInsights else {
            return scenarioAdvice(for: scenario)
        }
        let favoriteArtist = preferenceProfile.topArtists.first?.name
        let topGenre = preferenceProfile.genreDistribution.max { $0.value < $1.value }?.key ?? "流行"
        let topMood = preferenceProfile.moodTags.max { $0.value < $1.value }?.key ?? "旋律熟"
        let artistSentence = favoriteArtist.map { "\($0)也经常出现。" } ?? ""
        return "你平时听的\(genreSummaryPhrase(topGenre))偏多，\(moodSummaryPhrase(topMood))也不少。\(artistSentence)\(scenarioAdvice(for: scenario))"
    }

    private func scenarioAdvice(for scenario: ScenarioConfig) -> String {
        switch scenario.scenario {
        case .friends:
            return "朋友局先唱大家熟的，后面再留几首自己想唱的。"
        case .birthday:
            return "生日局先留祝福和合唱，中段放寿星想唱的。"
        case .teamBuilding:
            return "团建局先唱大家都会一点的，别让一个人连着唱。"
        case .carKTV:
            return "车里适合轻松顺序，难唱的和 Rap 太密的别连着排。"
        case .couples:
            return "情侣局多放甜歌和对唱，情绪歌放中段更顺。"
        case .soloPractice:
            return "练歌先从稳的开始，再留几首挑战。"
        }
    }

    private func genreSummaryPhrase(_ value: String) -> String {
        switch value {
        case "流行":
            return "流行歌"
        default:
            return "\(userFacingTag(value))歌"
        }
    }

    private func userFacingTag(_ value: String) -> String {
        switch value {
        case "旋律熟": return "熟悉旋律"
        case "高光": return "想唱"
        default: return value
        }
    }

    private func moodSummaryPhrase(_ value: String) -> String {
        switch value {
        case "旋律熟": return "大家熟的歌"
        case "合唱": return "适合合唱的歌"
        default: return "\(userFacingTag(value))的歌"
        }
    }

    private func scoreBreakdown(
        track: KTVTrack,
        preferenceProfile: PreferenceProfile,
        voiceProfile: VoiceProfile,
        scenario: ScenarioConfig,
        importedArtistCounts: [String: Int],
        feedbackProfile: SongFeedbackProfile
    ) -> RecommendationScoreBreakdown {
        let preferenceAffinity = affinity(track: track, preferenceProfile: preferenceProfile, importedArtistCounts: importedArtistCounts)
        let vocal = vocalFit(track: track, voiceProfile: voiceProfile)
        let scene = sceneFit(track: track, scenario: scenario)
        let variety = varietyScore(track: track, preferenceProfile: preferenceProfile)
        let riskPenalty = riskPenalty(track: track, voiceProfile: voiceProfile, scenario: scenario)
        let participation = participationAdjustment(track: track, scenario: scenario)
        let feedback = feedbackAdjustment(track: track, scenario: scenario, feedbackProfile: feedbackProfile)
        let value = preferenceAffinity * 0.26
            + track.ktvAvailability * 0.18
            + vocal * 0.20
            + track.singAlongScore * 0.16
            + scene * 0.12
            + variety * 0.08
            - riskPenalty
            + participation
            + feedback
        let finalScore = max(0, min(1, value))
        return RecommendationScoreBreakdown(
            preferenceAffinity: preferenceAffinity,
            ktvAvailabilityScore: track.ktvAvailability,
            vocalFitScore: vocal,
            singAlongScore: track.singAlongScore,
            sceneFitScore: scene,
            varietyScore: variety,
            riskPenalty: riskPenalty,
            finalScore: finalScore
        )
    }

    private func affinity(track: KTVTrack, preferenceProfile: PreferenceProfile, importedArtistCounts: [String: Int]) -> Double {
        var score = 0.25
        if importedArtistCounts[track.artist, default: 0] > 0 { score += 0.34 }
        score += (preferenceProfile.genreDistribution[track.genre] ?? 0) * 0.22
        score += track.moodTags.map { preferenceProfile.moodTags[$0] ?? 0 }.max() ?? 0
        return min(1, score)
    }

    private func vocalFit(track: KTVTrack, voiceProfile: VoiceProfile) -> Double {
        guard voiceProfile.hasValidMeasuredRange else { return 0.5 }
        let overlapLow = max(track.vocalRangeLowMidi, voiceProfile.stableLowMidi)
        let overlapHigh = min(track.vocalRangeHighMidi, voiceProfile.stableHighMidi)
        let overlap = max(0, overlapHigh - overlapLow)
        let trackRange = max(1, track.vocalRangeHighMidi - track.vocalRangeLowMidi)
        let overlapScore = Double(overlap) / Double(trackRange)
        let highPenalty = max(0, Double(track.vocalRangeHighMidi - voiceProfile.stableHighMidi)) * 0.035
        return max(0.05, min(1, overlapScore - highPenalty))
    }

    private func sceneFit(track: KTVTrack, scenario: ScenarioConfig) -> Double {
        var score = track.sceneTags.contains(scenario.scenario.rawValue) ? 0.88 : 0.48
        if scenario.scenario.isGroupScenario,
           scenario.chorusPreference == .moreChorus,
           track.singAlongScore >= 0.82 {
            score += 0.1
        }
        if scenario.scenario.isGroupScenario,
           scenario.chorusPreference == .moreSolo,
           track.singAlongScore < 0.78,
           !track.duetFriendly {
            score += 0.1
        }
        if scenario.difficultyPreference == .easy, track.difficulty <= 3 { score += 0.08 }
        if scenario.difficultyPreference == .showcase, track.difficulty >= 4 { score += 0.07 }
        if scenario.vibe == .energetic, track.energy >= 0.72 { score += 0.08 }
        if scenario.vibe == .nostalgic, track.moodTags.contains("怀旧") { score += 0.08 }
        if scenario.scenario.isGroupScenario,
           scenario.vibe == .chorus,
           track.singAlongScore >= 0.82 {
            score += 0.10
        }
        if scenario.vibe == .relaxed, track.energy <= 0.62, track.difficulty <= 3 { score += 0.08 }
        if scenario.vibe == .emotional, track.moodTags.contains(where: { ["走心", "情绪", "低落", "温暖"].contains($0) }) { score += 0.08 }
        if scenario.vibe == .spotlight, track.moodTags.contains("高光") || track.difficulty >= 4 { score += 0.08 }
        return min(1, score)
    }

    private func varietyScore(track: KTVTrack, preferenceProfile: PreferenceProfile) -> Double {
        let genreShare = preferenceProfile.genreDistribution[track.genre] ?? 0
        return genreShare > 0.5 ? 0.45 : 0.78
    }

    private func riskPenalty(track: KTVTrack, voiceProfile: VoiceProfile, scenario: ScenarioConfig) -> Double {
        var penalty = track.highNoteRisk * 0.08 + track.rapDensity * 0.04
        if voiceProfile.hasValidMeasuredRange,
           track.vocalRangeHighMidi > voiceProfile.stableHighMidi + 4 {
            penalty += 0.1
        }
        if scenario.scenario == .carKTV, track.difficulty >= 4 { penalty += 0.12 }
        if scenario.scenario == .carKTV, track.rapDensity >= 0.35 { penalty += 0.12 }
        if scenario.difficultyPreference == .easy, track.highNoteRisk >= 0.65 { penalty += 0.10 }
        return penalty
    }

    private func participationAdjustment(track: KTVTrack, scenario: ScenarioConfig) -> Double {
        switch scenario.peopleCount {
        case 1...2:
            var adjustment = 0.0
            if scenario.difficultyPreference == .showcase, track.difficulty >= 4 { adjustment += 0.06 }
            if track.moodTags.contains("高光") { adjustment += 0.04 }
            return adjustment
        case 6...8:
            var adjustment = 0.0
            if track.singAlongScore >= 0.78 || track.duetFriendly { adjustment += 0.08 }
            if track.difficulty >= 5 || track.highNoteRisk >= 0.72 { adjustment -= 0.08 }
            return adjustment
        case 9...:
            var adjustment = 0.0
            if track.singAlongScore >= 0.78 || track.duetFriendly { adjustment += 0.14 }
            if track.difficulty >= 4 { adjustment -= 0.10 }
            if track.highNoteRisk >= 0.65 { adjustment -= 0.10 }
            if track.ktvAvailability >= 0.8 { adjustment += 0.04 }
            return adjustment
        default:
            return 0
        }
    }

    private func feedbackAdjustment(track: KTVTrack, scenario: ScenarioConfig, feedbackProfile: SongFeedbackProfile) -> Double {
        let feedback = Set(feedbackProfile.feedback(for: track.id))
        var adjustment = 0.0
        if feedback.contains(.liked) { adjustment += 0.14 }
        if feedback.contains(.sung) { adjustment += 0.04 }
        if feedback.contains(.chorusFriendly), scenario.scenario.isGroupScenario { adjustment += 0.10 }
        if feedback.contains(.tooHigh) { adjustment -= 0.18 }
        if feedback.contains(.unfamiliar) { adjustment -= 0.12 }
        return adjustment
    }

    private func sectionAllows(
        _ track: KTVTrack,
        role: SongPlanSectionRole,
        scenario: ScenarioConfig
    ) -> Bool {
        if scenario.scenario == .carKTV,
           track.difficulty > 4 || track.rapDensity >= 0.75 {
            return false
        }
        switch role {
        case .warmup:
            return track.energy >= 0.55 && track.difficulty <= 4 && track.highNoteRisk < 0.72
        case .groupSingAlong, .participation, .closing:
            return track.singAlongScore >= 0.68 || track.duetFriendly
        case .nostalgia, .familiar:
            return track.moodTags.contains("怀旧") || track.era == "2000s" || track.era == "1990s"
        case .birthday:
            return isBirthdayFriendly(track)
        case .duet:
            return track.duetFriendly || track.genre == "甜歌"
        case .stablePractice:
            return track.difficulty <= 3 && track.highNoteRisk <= 0.55
        case .challengePractice:
            return track.difficulty >= 3 || track.moodTags.contains("高光")
        case .energy:
            return track.energy >= 0.65
        case .relaxed:
            return track.difficulty <= 3 && track.energy <= 0.8 && track.rapDensity < 0.4
        case .emotional:
            return track.moodTags.contains(where: { ["走心", "情绪", "低落", "温暖", "甜蜜"].contains($0) })
        case .memorable, .spotlight:
            return track.difficulty >= 3 || track.moodTags.contains("高光") || track.singAlongScore >= 0.82
        case .externalVerification:
            return false
        case .general:
            return true
        }
    }

    private func sequencingAllows(
        _ track: KTVTrack,
        selectedIDsAreEmpty: Bool,
        lastArtist: String?,
        slowStreak: Int
    ) -> Bool {
        if track.artist == lastArtist { return false }
        if selectedIDsAreEmpty,
           track.difficulty >= 5 || track.highNoteRisk >= 0.72 {
            return false
        }
        if track.energy < 0.45 && slowStreak >= 3 { return false }
        return true
    }

    private func isBirthdayFriendly(_ track: KTVTrack) -> Bool {
        track.sceneTags.contains("birthday")
            || track.moodTags.contains(where: { ["温暖", "甜蜜", "喜庆", "合唱"].contains($0) })
    }

    private func isBirthdayHardRuleEligible(_ track: KTVTrack) -> Bool {
        isBirthdayFriendly(track) || track.singAlongScore >= 0.86
    }

    private func planItem(
        scoredTrack: ScoredTrack,
        preferenceProfile: PreferenceProfile,
        voiceProfile: VoiceProfile,
        scenario: ScenarioConfig,
        importedArtistCounts: [String: Int],
        inputSource: RecommendationInputSource,
        catalog: [KTVTrack],
        isLocked: Bool,
        feedbackProfile: SongFeedbackProfile
    ) -> SongPlanItem {
        let feedbackTags = feedbackProfile.feedback(for: scoredTrack.track.id)
        return SongPlanItem(
            track: scoredTrack.track,
            origin: scoredTrack.origin,
            score: scoredTrack.score,
            scoreBreakdown: scoredTrack.scoreBreakdown,
            reasons: reasonBuilder.reasons(
                for: scoredTrack.track,
                preferenceProfile: preferenceProfile,
                voiceProfile: voiceProfile,
                scenario: scenario,
                importedArtistCounts: importedArtistCounts,
                inputSource: inputSource
            ),
            riskWarnings: reasonBuilder.riskWarnings(for: scoredTrack.track, voiceProfile: voiceProfile, scenario: scenario),
            alternatives: alternatives(for: scoredTrack.track, in: catalog),
            isLocked: isLocked,
            singingAdvice: singingAdvisor.advice(for: scoredTrack.track, voiceProfile: voiceProfile),
            actionURL: actionLinkBuilder.url(for: scoredTrack.track),
            feedbackTags: feedbackTags
        )
    }

    private func enforceHardRules(
        sections: [SongPlanSection],
        scored: [ScoredTrack],
        selectedIDs: Set<String>,
        scenario: ScenarioConfig,
        preferenceProfile: PreferenceProfile,
        voiceProfile: VoiceProfile,
        importedArtistCounts: [String: Int],
        inputSource: RecommendationInputSource,
        catalog: [KTVTrack],
        lockedTrackIDs: Set<String>,
        feedbackProfile: SongFeedbackProfile
    ) -> [SongPlanSection] {
        var sections = sections
        var selectedIDs = selectedIDs

        func replace(
            with candidate: ScoredTrack,
            preferredRoles: [SongPlanSectionRole],
            where canReplace: (SongPlanItem) -> Bool
        ) -> Bool {
            guard !selectedIDs.contains(candidate.track.id) else { return false }
            let preferred = sections.indices.flatMap { sectionIndex in
                sections[sectionIndex].items.indices.compactMap { itemIndex -> (Int, Int)? in
                    guard preferredRoles.contains(sections[sectionIndex].role),
                          !sections[sectionIndex].items[itemIndex].isLocked,
                          canReplace(sections[sectionIndex].items[itemIndex]) else { return nil }
                    return (sectionIndex, itemIndex)
                }
            }.min {
                sections[$0.0].items[$0.1].score < sections[$1.0].items[$1.1].score
            }
            let fallback = sections.indices.flatMap { sectionIndex in
                sections[sectionIndex].items.indices.compactMap { itemIndex -> (Int, Int)? in
                    guard !sections[sectionIndex].items[itemIndex].isLocked,
                          canReplace(sections[sectionIndex].items[itemIndex]) else { return nil }
                    return (sectionIndex, itemIndex)
                }
            }.min {
                sections[$0.0].items[$0.1].score < sections[$1.0].items[$1.1].score
            }
            guard let (sectionIndex, itemIndex) = preferred ?? fallback else { return false }
            let replacedTrackID = sections[sectionIndex].items[itemIndex].track.id
            sections[sectionIndex].items[itemIndex] = planItem(
                scoredTrack: candidate,
                preferenceProfile: preferenceProfile,
                voiceProfile: voiceProfile,
                scenario: scenario,
                importedArtistCounts: importedArtistCounts,
                inputSource: inputSource,
                catalog: catalog,
                isLocked: lockedTrackIDs.contains(candidate.track.id),
                feedbackProfile: feedbackProfile
            )
            selectedIDs.remove(replacedTrackID)
            selectedIDs.insert(candidate.track.id)
            return true
        }

        if scenario.scenario == .birthday {
            let hasBirthdaySong = sections
                .flatMap(\.items)
                .contains { isBirthdayHardRuleEligible($0.track) }
            if !hasBirthdaySong,
               let candidate = scored.first(where: {
                   !selectedIDs.contains($0.track.id)
                       && isBirthdayHardRuleEligible($0.track)
               }) {
                _ = replace(with: candidate, preferredRoles: [.birthday, .groupSingAlong]) { item in
                    !isBirthdayHardRuleEligible(item.track)
                }
            }
        }

        if scenario.scenario.isGroupScenario {
            let itemCount = sections.flatMap(\.items).count
            let needed = Int(ceil(Double(itemCount) * 0.3))
            while sections.flatMap(\.items).filter({ isChorusFriendly($0.track) }).count < needed {
                guard let candidate = scored.first(where: {
                    !selectedIDs.contains($0.track.id) && isChorusFriendly($0.track)
                }) else { break }
                let didReplace = replace(
                    with: candidate,
                    preferredRoles: [.groupSingAlong, .participation, .closing]
                ) { item in
                    !isChorusFriendly(item.track)
                        && (scenario.scenario != .birthday || !isBirthdayFriendly(item.track))
                }
                guard didReplace else { break }
            }
        }

        return sections
    }

    private func isChorusFriendly(_ track: KTVTrack) -> Bool {
        track.singAlongScore >= 0.78 || track.duetFriendly
    }

    private func alternatives(for track: KTVTrack, in catalog: [KTVTrack]) -> [KTVTrack] {
        let similar = catalog.filter {
            $0.catalogSource == .ktvCatalog
                && track.similarSongIds.contains($0.id)
        }
        if !similar.isEmpty { return Array(similar.prefix(2)) }
        return Array(catalog
            .filter {
                $0.catalogSource == .ktvCatalog
                    && $0.id != track.id
                    && ($0.artist == track.artist || $0.genre == track.genre)
            }
            .sorted { $0.singAlongScore > $1.singAlongScore }
            .prefix(2))
    }

    private struct ScoredTrack {
        let track: KTVTrack
        let origin: SongRecommendationOrigin
        let scoreBreakdown: RecommendationScoreBreakdown

        var score: Double {
            scoreBreakdown.finalScore
        }
    }
}
