import Foundation

public struct RecommendationEngine: Sendable {
    private let reasonBuilder: RecommendationReasonBuilder

    public init(reasonBuilder: RecommendationReasonBuilder = RecommendationReasonBuilder()) {
        self.reasonBuilder = reasonBuilder
    }

    public func generatePlan(
        matches: [MatchResult],
        preferenceProfile: PreferenceProfile,
        voiceProfile: VoiceProfile,
        scenario: ScenarioConfig,
        catalog: [KTVTrack],
        lockedTrackIDs: Set<String> = [],
        removedTrackIDs: Set<String> = []
    ) -> SongPlan {
        let importedArtistCounts = matches.reduce(into: [String: Int]()) { result, match in
            if let artist = match.importedSong.artist {
                result[artist, default: 0] += 1
            }
        }
        let candidates = buildCandidatePool(matches: matches, preferenceProfile: preferenceProfile, scenario: scenario, catalog: catalog)
            .filter { !removedTrackIDs.contains($0.id) || lockedTrackIDs.contains($0.id) }
        let scored: [ScoredTrack] = candidates.map { track in
            let breakdown = scoreBreakdown(
                track: track,
                preferenceProfile: preferenceProfile,
                voiceProfile: voiceProfile,
                scenario: scenario,
                importedArtistCounts: importedArtistCounts
            )
            return ScoredTrack(
                track: track,
                scoreBreakdown: breakdown
            )
        }
        .sorted { $0.score > $1.score }

        var selectedIDs = Set<String>()
        var lastArtist: String?
        var slowStreak = 0
        let targetCount = max(scenario.scenario.sectionTemplates.count, min(16, max(8, scenario.durationMinutes / 6)))
        let perSection = max(1, Int(ceil(Double(targetCount) / Double(scenario.scenario.sectionTemplates.count))))

        let sections = scenario.scenario.sectionTemplates.map { template in
            var items: [SongPlanItem] = []

            for scoredTrack in scored where lockedTrackIDs.contains(scoredTrack.track.id) {
                guard items.count < perSection else { break }
                guard !selectedIDs.contains(scoredTrack.track.id) else { continue }
                guard sectionAllows(scoredTrack.track, sectionTitle: template.title, scenario: scenario) else { continue }
                selectedIDs.insert(scoredTrack.track.id)
                lastArtist = scoredTrack.track.artist
                items.append(planItem(
                    scoredTrack: scoredTrack,
                    preferenceProfile: preferenceProfile,
                    voiceProfile: voiceProfile,
                    scenario: scenario,
                    importedArtistCounts: importedArtistCounts,
                    catalog: catalog,
                    isLocked: true
                ))
            }

            for scoredTrack in scored {
                guard items.count < perSection else { break }
                guard !selectedIDs.contains(scoredTrack.track.id) else { continue }
                guard scoredTrack.track.artist != lastArtist else { continue }
                guard !(selectedIDs.isEmpty && (scoredTrack.track.difficulty >= 5 || scoredTrack.track.highNoteRisk >= 0.72)) else { continue }
                let isSlow = scoredTrack.track.energy < 0.45
                guard !(isSlow && slowStreak >= 3) else { continue }
                guard sectionAllows(scoredTrack.track, sectionTitle: template.title, scenario: scenario) else { continue }

                selectedIDs.insert(scoredTrack.track.id)
                lastArtist = scoredTrack.track.artist
                slowStreak = isSlow ? slowStreak + 1 : 0
                items.append(planItem(
                    scoredTrack: scoredTrack,
                    preferenceProfile: preferenceProfile,
                    voiceProfile: voiceProfile,
                    scenario: scenario,
                    importedArtistCounts: importedArtistCounts,
                    catalog: catalog,
                    isLocked: false
                ))
            }

            if !items.contains(where: { $0.track.singAlongScore >= 0.78 }),
               let chorus = scored.first(where: { !selectedIDs.contains($0.track.id) && $0.track.singAlongScore >= 0.82 }) {
                selectedIDs.insert(chorus.track.id)
                items.append(planItem(
                    scoredTrack: chorus,
                    preferenceProfile: preferenceProfile,
                    voiceProfile: voiceProfile,
                    scenario: scenario,
                    importedArtistCounts: importedArtistCounts,
                    catalog: catalog,
                    isLocked: lockedTrackIDs.contains(chorus.track.id)
                ))
            }

            return SongPlanSection(title: template.title, goal: template.goal, items: items)
        }
        let adjustedSections = enforceHardRules(
            sections: sections,
            scored: scored,
            selectedIDs: selectedIDs,
            scenario: scenario,
            preferenceProfile: preferenceProfile,
            voiceProfile: voiceProfile,
            importedArtistCounts: importedArtistCounts,
            catalog: catalog,
            lockedTrackIDs: lockedTrackIDs
        )

        return SongPlan(
            title: "\(scenario.scenario.displayName)歌单",
            scenario: scenario.scenario,
            scenarioConfig: scenario,
            voiceProfile: voiceProfile,
            preferenceSummary: preferenceProfile.summary,
            sections: adjustedSections
        )
    }

    private func buildCandidatePool(matches: [MatchResult], preferenceProfile: PreferenceProfile, scenario: ScenarioConfig, catalog: [KTVTrack]) -> [KTVTrack] {
        var byID: [String: KTVTrack] = [:]
        for match in matches {
            if let track = match.matchedTrack {
                byID[track.id] = track
            }
            for alternative in match.alternatives {
                byID[alternative.id] = alternative
            }
        }
        let preferredGenres = Set(preferenceProfile.genreDistribution.filter { $0.value >= 0.15 }.map(\.key))
        let preferredMoods = Set(preferenceProfile.moodTags.filter { $0.value >= 0.12 }.map(\.key))
        let preferredArtists = Set(preferenceProfile.topArtists.map(\.name))
        for track in catalog where byID.count < 90 {
            if preferredArtists.contains(track.artist)
                || preferredGenres.contains(track.genre)
                || !preferredMoods.isDisjoint(with: track.moodTags)
                || track.sceneTags.contains(scenario.scenario.rawValue)
                || track.singAlongScore >= 0.86 {
                byID[track.id] = track
            }
        }
        return Array(byID.values)
    }

    private func scoreBreakdown(
        track: KTVTrack,
        preferenceProfile: PreferenceProfile,
        voiceProfile: VoiceProfile,
        scenario: ScenarioConfig,
        importedArtistCounts: [String: Int]
    ) -> RecommendationScoreBreakdown {
        let preferenceAffinity = affinity(track: track, preferenceProfile: preferenceProfile, importedArtistCounts: importedArtistCounts)
        let vocal = vocalFit(track: track, voiceProfile: voiceProfile)
        let scene = sceneFit(track: track, scenario: scenario)
        let variety = varietyScore(track: track, preferenceProfile: preferenceProfile)
        let riskPenalty = riskPenalty(track: track, voiceProfile: voiceProfile, scenario: scenario)
        let value = preferenceAffinity * 0.26
            + track.ktvAvailability * 0.18
            + vocal * 0.20
            + track.singAlongScore * 0.16
            + scene * 0.12
            + variety * 0.08
            - riskPenalty
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
        if scenario.chorusPreference == .moreChorus, track.singAlongScore >= 0.82 { score += 0.1 }
        if scenario.difficultyPreference == .easy, track.difficulty <= 3 { score += 0.08 }
        if scenario.difficultyPreference == .showcase, track.difficulty >= 4 { score += 0.07 }
        if scenario.vibe == .energetic, track.energy >= 0.72 { score += 0.08 }
        if scenario.vibe == .nostalgic, track.moodTags.contains("怀旧") { score += 0.08 }
        if scenario.vibe == .chorus, track.singAlongScore >= 0.82 { score += 0.10 }
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
        if track.vocalRangeHighMidi > voiceProfile.stableHighMidi + 4 { penalty += 0.1 }
        if scenario.scenario == .carKTV, track.difficulty >= 4 { penalty += 0.12 }
        if scenario.scenario == .carKTV, track.rapDensity >= 0.35 { penalty += 0.12 }
        if scenario.difficultyPreference == .easy, track.highNoteRisk >= 0.65 { penalty += 0.10 }
        return penalty
    }

    private func sectionAllows(_ track: KTVTrack, sectionTitle: String, scenario: ScenarioConfig) -> Bool {
        if sectionTitle.contains("开场") || sectionTitle.contains("热场") || sectionTitle.contains("热身") {
            return track.energy >= 0.55 && track.difficulty <= 4
        }
        if sectionTitle.contains("合唱") || sectionTitle.contains("收尾") || sectionTitle.contains("全员") {
            return track.singAlongScore >= 0.68
        }
        if sectionTitle.contains("怀旧") || sectionTitle.contains("熟悉") {
            return track.moodTags.contains("怀旧") || track.era == "2000s" || track.era == "1990s"
        }
        if sectionTitle.contains("生日") || sectionTitle.contains("祝福") {
            return track.sceneTags.contains("birthday") || track.moodTags.contains(where: { ["温暖", "甜蜜", "喜庆", "合唱"].contains($0) })
        }
        if sectionTitle.contains("甜歌") || sectionTitle.contains("对唱") {
            return track.duetFriendly || track.genre == "甜歌"
        }
        if sectionTitle.contains("稳定区") || sectionTitle.contains("开嗓") {
            return track.difficulty <= 3 && track.highNoteRisk <= 0.55
        }
        if sectionTitle.contains("技巧挑战") {
            return track.difficulty >= 3 || track.moodTags.contains("高光")
        }
        if scenario.scenario == .carKTV {
            return track.difficulty <= 4
        }
        return true
    }

    private func planItem(
        scoredTrack: ScoredTrack,
        preferenceProfile: PreferenceProfile,
        voiceProfile: VoiceProfile,
        scenario: ScenarioConfig,
        importedArtistCounts: [String: Int],
        catalog: [KTVTrack],
        isLocked: Bool
    ) -> SongPlanItem {
        SongPlanItem(
            track: scoredTrack.track,
            score: scoredTrack.score,
            scoreBreakdown: scoredTrack.scoreBreakdown,
            reasons: reasonBuilder.reasons(
                for: scoredTrack.track,
                preferenceProfile: preferenceProfile,
                voiceProfile: voiceProfile,
                scenario: scenario,
                importedArtistCounts: importedArtistCounts
            ),
            riskWarnings: reasonBuilder.riskWarnings(for: scoredTrack.track, voiceProfile: voiceProfile, scenario: scenario),
            alternatives: alternatives(for: scoredTrack.track, in: catalog),
            isLocked: isLocked
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
        catalog: [KTVTrack],
        lockedTrackIDs: Set<String>
    ) -> [SongPlanSection] {
        var sections = sections
        var selectedIDs = selectedIDs

        if scenario.scenario == .birthday {
            let hasBirthdaySong = sections
                .flatMap(\.items)
                .contains { item in
                    item.track.sceneTags.contains("birthday")
                        || item.track.moodTags.contains(where: { ["温暖", "甜蜜", "喜庆", "合唱"].contains($0) })
                }
            if !hasBirthdaySong,
               let candidate = scored.first(where: { !selectedIDs.contains($0.track.id) && ($0.track.sceneTags.contains("birthday") || $0.track.singAlongScore >= 0.86) }) {
                append(candidate, toSectionContaining: "生日", sections: &sections, selectedIDs: &selectedIDs, scenario: scenario, preferenceProfile: preferenceProfile, voiceProfile: voiceProfile, importedArtistCounts: importedArtistCounts, catalog: catalog, lockedTrackIDs: lockedTrackIDs)
            }
        }

        if scenario.scenario.isGroupScenario {
            let items = sections.flatMap(\.items)
            let chorusCount = items.filter { $0.track.singAlongScore >= 0.78 || $0.track.duetFriendly }.count
            let needed = Int(ceil(Double(max(items.count, 1)) * 0.3))
            if chorusCount < needed {
                for candidate in scored where candidate.track.singAlongScore >= 0.84 || candidate.track.duetFriendly {
                    guard chorusCount + selectedIDs.intersection([candidate.track.id]).count < needed else { break }
                    guard !selectedIDs.contains(candidate.track.id) else { continue }
                    append(candidate, toSectionContaining: "合唱", sections: &sections, selectedIDs: &selectedIDs, scenario: scenario, preferenceProfile: preferenceProfile, voiceProfile: voiceProfile, importedArtistCounts: importedArtistCounts, catalog: catalog, lockedTrackIDs: lockedTrackIDs)
                    if sections.flatMap(\.items).filter({ $0.track.singAlongScore >= 0.78 || $0.track.duetFriendly }).count >= needed { break }
                }
            }
        }

        return sections
    }

    private func append(
        _ candidate: ScoredTrack,
        toSectionContaining keyword: String,
        sections: inout [SongPlanSection],
        selectedIDs: inout Set<String>,
        scenario: ScenarioConfig,
        preferenceProfile: PreferenceProfile,
        voiceProfile: VoiceProfile,
        importedArtistCounts: [String: Int],
        catalog: [KTVTrack],
        lockedTrackIDs: Set<String>
    ) {
        let index = sections.firstIndex { $0.title.contains(keyword) } ?? sections.indices.last
        guard let index else { return }
        sections[index].items.append(planItem(
            scoredTrack: candidate,
            preferenceProfile: preferenceProfile,
            voiceProfile: voiceProfile,
            scenario: scenario,
            importedArtistCounts: importedArtistCounts,
            catalog: catalog,
            isLocked: lockedTrackIDs.contains(candidate.track.id)
        ))
        selectedIDs.insert(candidate.track.id)
    }

    private func alternatives(for track: KTVTrack, in catalog: [KTVTrack]) -> [KTVTrack] {
        let similar = catalog.filter { track.similarSongIds.contains($0.id) }
        if !similar.isEmpty { return Array(similar.prefix(2)) }
        return Array(catalog
            .filter { $0.id != track.id && ($0.artist == track.artist || $0.genre == track.genre) }
            .sorted { $0.singAlongScore > $1.singAlongScore }
            .prefix(2))
    }

    private struct ScoredTrack {
        let track: KTVTrack
        let scoreBreakdown: RecommendationScoreBreakdown

        var score: Double {
            scoreBreakdown.finalScore
        }
    }
}
