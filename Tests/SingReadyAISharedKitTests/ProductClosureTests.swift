import XCTest
@testable import SingReadyAISharedKit

final class ProductClosureTests: XCTestCase {
    func testUnconfirmedMissingArtistCandidateDoesNotContributeToPreferenceProfile() throws {
        let track = try XCTUnwrap(
            try KTVCatalogRepository().loadTracks().first(where: { $0.title == "晴天" })
        )
        let song = ImportedSong(title: track.title, source: .plainText, confidence: 0.9)
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "待确认歌单",
            songs: [song],
            parseConfidence: 0.9
        )
        let matches = SongMatcher().match(playlist: playlist, catalog: [track])

        let profile = PreferenceProfiler().buildProfile(importedPlaylist: playlist, matches: matches)

        XCTAssertNil(matches.first?.matchedTrack)
        XCTAssertEqual(profile.ktvMatchRate, 0)
        XCTAssertTrue(profile.genreDistribution.isEmpty)
    }

    func testRequiredMatchCanConfirmCandidateAndRebuildPreferenceProfile() throws {
        let track = try XCTUnwrap(
            try KTVCatalogRepository().loadTracks().first(where: { $0.title == "晴天" })
        )
        let song = ImportedSong(title: track.title, source: .plainText, confidence: 0.9)
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "待确认歌单",
            songs: [song],
            parseConfidence: 0.9
        )
        let pending = try XCTUnwrap(SongMatcher().match(playlist: playlist, catalog: [track]).first)

        let confirmed = try XCTUnwrap(pending.confirming(track: track))
        let restored = try JSONDecoder().decode(
            MatchResult.self,
            from: JSONEncoder().encode(confirmed)
        )
        let profile = PreferenceProfiler().buildProfile(importedPlaylist: playlist, matches: [restored])

        XCTAssertEqual(restored.id, pending.id)
        XCTAssertEqual(restored.importedSong.id, pending.importedSong.id)
        XCTAssertEqual(restored.matchedTrack?.id, track.id)
        XCTAssertEqual(restored.confirmationState, .confirmed)
        XCTAssertEqual(profile.ktvMatchRate, 1)
        XCTAssertEqual(profile.genreDistribution[track.genre], 1)
        XCTAssertEqual(profile.topArtists.first?.name, track.artist)
    }

    func testPreferenceProfilerDefensivelyIgnoresRequiredMatchedTrack() {
        let track = makeTrack(id: "inconsistent", title: "同名歌曲", artist: "候选歌手")
        let song = ImportedSong(title: track.title, source: .plainText, confidence: 1)
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "不一致旧数据",
            songs: [song],
            parseConfidence: 1
        )
        var inconsistent = MatchResult(
            importedSong: song,
            matchedTrack: nil,
            alternatives: [track],
            status: .fuzzy,
            confirmationState: .required,
            score: 0.9,
            reason: "待确认"
        )
        inconsistent.matchedTrack = track

        let profile = PreferenceProfiler().buildProfile(
            importedPlaylist: playlist,
            matches: [inconsistent]
        )

        XCTAssertNil(inconsistent.acceptedTrack)
        XCTAssertFalse(profile.hasReferenceInsights)
        XCTAssertEqual(profile.ktvMatchRate, 0)
        XCTAssertTrue(profile.topArtists.isEmpty)
    }

    func testAdoptingOrdinaryAlternativePreservesIdentityAndInvalidatesOnlyPlanState() throws {
        let alternative = makeTrack(id: "alternative", title: "替代歌曲", artist: "替代歌手")
        let importedSong = ImportedSong(title: "原歌曲", artist: "原歌手", source: .plainText, confidence: 0.8)
        let result = MatchResult(
            importedSong: importedSong,
            matchedTrack: nil,
            alternatives: [alternative],
            status: .alternative,
            score: 0.72,
            reason: "找到普通替代"
        )

        let adopted = try XCTUnwrap(result.adoptingAlternative(track: alternative))

        XCTAssertTrue(result.needsAlternativeAdoption)
        XCTAssertFalse(adopted.needsAlternativeAdoption)
        XCTAssertEqual(adopted.id, result.id)
        XCTAssertEqual(adopted.importedSong.id, importedSong.id)
        XCTAssertEqual(adopted.matchedTrack?.id, alternative.id)
        XCTAssertEqual(adopted.status, .alternative)
        XCTAssertEqual(adopted.confirmationState, .notRequired)
        XCTAssertTrue(adopted.reason.contains("已采用替代歌"))
        XCTAssertNil(result.adoptingAlternative(track: makeTrack(id: "outside", title: "其他", artist: "其他")))
    }

    func testAdoptingFuzzyAlternativeKeepsPreviousReferenceAvailable() throws {
        let previous = makeTrack(id: "previous", title: "相近原参考", artist: "歌手A")
        let replacement = makeTrack(id: "replacement", title: "替代参考", artist: "歌手B")
        let result = MatchResult(
            importedSong: ImportedSong(title: "导入歌名", artist: "歌手A", source: .plainText, confidence: 0.8),
            matchedTrack: previous,
            alternatives: [replacement],
            status: .fuzzy,
            score: 0.84,
            reason: "歌名相近"
        )

        let adopted = try XCTUnwrap(result.adoptingAlternative(track: replacement))

        XCTAssertEqual(adopted.matchedTrack?.id, replacement.id)
        XCTAssertEqual(adopted.alternatives.map(\.id), [previous.id])
    }

    func testOriginalReferenceAndAdoptedAlternativeHaveDistinctSemantics() throws {
        let original = makeTrack(id: "original", title: "原歌", artist: "原歌手")
        let replacement = makeTrack(id: "replacement", title: "替代歌", artist: "替代歌手")
        let exact = MatchResult(
            importedSong: ImportedSong(title: original.title, artist: original.artist, source: .plainText, confidence: 1),
            matchedTrack: original,
            alternatives: [],
            status: .exact,
            score: 1,
            reason: "原歌命中"
        )
        let pendingAlternative = MatchResult(
            importedSong: ImportedSong(title: "没有原歌", artist: "原歌手", source: .plainText, confidence: 0.7),
            matchedTrack: nil,
            alternatives: [replacement],
            status: .alternative,
            score: 0.7,
            reason: "可替代"
        )
        let adopted = try XCTUnwrap(pendingAlternative.adoptingAlternative(track: replacement))

        XCTAssertTrue(exact.hasOriginalReferenceMatch)
        XCTAssertFalse(exact.isAdoptedAlternative)
        XCTAssertFalse(pendingAlternative.hasOriginalReferenceMatch)
        XCTAssertFalse(pendingAlternative.isAdoptedAlternative)
        XCTAssertFalse(adopted.hasOriginalReferenceMatch)
        XCTAssertTrue(adopted.isAdoptedAlternative)
    }

    func testMatchStatisticsPartitionsEveryResultExactlyOnce() {
        let exactTrack = makeTrack(id: "exact", title: "精确", artist: "歌手A")
        let fuzzyTrack = makeTrack(id: "fuzzy", title: "相近", artist: "歌手B")
        let identityTrack = makeTrack(id: "identity", title: "同名", artist: "歌手C")
        let replacement = makeTrack(id: "replacement", title: "替代", artist: "歌手D")
        let exact = match(exactTrack)
        let fuzzy = MatchResult(
            importedSong: ImportedSong(title: "相近版本", artist: fuzzyTrack.artist, source: .plainText, confidence: 0.8),
            matchedTrack: fuzzyTrack,
            alternatives: [],
            status: .fuzzy,
            score: 0.85,
            reason: "歌名相近"
        )
        let pending = MatchResult(
            importedSong: ImportedSong(title: identityTrack.title, source: .plainText, confidence: 0.7),
            matchedTrack: nil,
            alternatives: [identityTrack],
            status: .fuzzy,
            confirmationState: .required,
            score: 1,
            reason: "待确认"
        )
        let pendingAlternative = MatchResult(
            importedSong: ImportedSong(title: "原歌缺失", source: .plainText, confidence: 0.6),
            matchedTrack: nil,
            alternatives: [replacement],
            status: .alternative,
            score: 0.7,
            reason: "可替代"
        )
        let adoptedAlternative = MatchResult(
            importedSong: ImportedSong(title: "已替代原歌", source: .plainText, confidence: 0.6),
            matchedTrack: replacement,
            alternatives: [],
            status: .alternative,
            score: 0.7,
            reason: "已采用替代"
        )
        let unmatched = MatchResult(
            importedSong: ImportedSong(title: "未找到", source: .plainText, confidence: 0.4),
            matchedTrack: nil,
            alternatives: [],
            status: .unmatched,
            score: 0,
            reason: "未找到"
        )
        let matches = [exact, fuzzy, pending, pendingAlternative, adoptedAlternative, unmatched]

        let statistics = MatchStatistics(matches: matches)

        XCTAssertEqual(statistics.exact, 1)
        XCTAssertEqual(statistics.pending, 1)
        XCTAssertEqual(statistics.fuzzy, 1)
        XCTAssertEqual(statistics.pendingAlternative, 1)
        XCTAssertEqual(statistics.adoptedAlternative, 1)
        XCTAssertEqual(statistics.unmatched, 1)
        XCTAssertEqual(statistics.total, matches.count)
    }

    func testAdoptedAlternativeContributesToProfileButNotOriginalMatchRate() throws {
        let replacement = makeTrack(
            id: "replacement",
            title: "替代歌",
            artist: "替代歌手",
            difficulty: 5
        )
        let song = ImportedSong(title: "原歌未找到", source: .plainText, confidence: 0.7)
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "替代歌单",
            songs: [song],
            parseConfidence: 0.7
        )
        let pending = MatchResult(
            importedSong: song,
            matchedTrack: nil,
            alternatives: [replacement],
            status: .alternative,
            score: 0.7,
            reason: "可替代"
        )
        let adopted = try XCTUnwrap(pending.adoptingAlternative(track: replacement))

        let profile = PreferenceProfiler().buildProfile(importedPlaylist: playlist, matches: [adopted])

        XCTAssertEqual(profile.ktvMatchRate, 0)
        XCTAssertEqual(profile.averageDifficulty, 5)
        XCTAssertEqual(profile.genreDistribution[replacement.genre], 1)
        XCTAssertEqual(profile.topArtists.first?.name, replacement.artist)
        XCTAssertTrue(profile.hasReferenceInsights)
    }

    func testRequiredMatchRejectsTrackOutsideItsCandidates() throws {
        let catalog = try KTVCatalogRepository().loadTracks()
        let candidate = try XCTUnwrap(catalog.first(where: { $0.title == "晴天" }))
        let unrelated = try XCTUnwrap(catalog.first(where: { $0.id != candidate.id }))
        let pending = SongMatcher().match(
            song: ImportedSong(title: candidate.title, source: .plainText, confidence: 0.9),
            catalog: [candidate]
        )

        XCTAssertNil(pending.confirming(track: unrelated))
    }

    func testConfirmingOneOfMultipleCandidatesClearsOtherIdentityCandidates() throws {
        let candidates = try KTVCatalogRepository().loadTracks().filter { $0.title == "喜欢你" }
        XCTAssertEqual(candidates.count, 2)
        let pending = SongMatcher().match(
            song: ImportedSong(title: "喜欢你", source: .plainText, confidence: 0.9),
            catalog: candidates
        )

        let confirmed = try XCTUnwrap(pending.confirming(track: candidates[0]))

        XCTAssertEqual(confirmed.matchedTrack?.id, candidates[0].id)
        XCTAssertTrue(confirmed.alternatives.isEmpty)
    }

    func testMatchConfirmationTransitionInvalidatesPlanWithoutDiscardingUserSelections() {
        let externalTrack = makeTrack(
            id: "external",
            title: "外部备选",
            artist: "候选歌手",
            catalogSource: .externalSimilar
        )
        let currentPlan = SongPlan(
            title: "当前计划",
            scenario: .friends,
            sections: []
        )
        let currentState = MatchConfirmationWorkflowState(
            lockedTrackIDs: ["locked"],
            removedTrackIDs: ["removed"],
            externalCandidateTracks: [externalTrack],
            songPlan: currentPlan
        )

        let nextState = MatchConfirmationStatePolicy.afterConfirmingMatch(currentState)

        XCTAssertEqual(nextState.lockedTrackIDs, currentState.lockedTrackIDs)
        XCTAssertEqual(nextState.removedTrackIDs, currentState.removedTrackIDs)
        XCTAssertEqual(nextState.externalCandidateTracks.map(\.id), [externalTrack.id])
        XCTAssertNil(nextState.songPlan)
    }

    func testRequiredCandidateDoesNotEnterRecommendationUntilConfirmed() throws {
        let track = makeTrack(
            id: "pending",
            title: "同名待确认歌",
            artist: "候选歌手",
            difficulty: 2,
            singAlong: 0.95,
            highRisk: 0.2,
            sceneTags: ["friends"],
            energy: 0.7
        )
        let song = ImportedSong(title: track.title, source: .plainText, confidence: 0.9)
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "待确认歌单",
            songs: [song],
            parseConfidence: 0.9
        )
        let pending = try XCTUnwrap(SongMatcher().match(playlist: playlist, catalog: [track]).first)
        let pendingProfile = PreferenceProfiler().buildProfile(importedPlaylist: playlist, matches: [pending])

        let pendingPlan = RecommendationEngine().generatePlan(
            matches: [pending],
            preferenceProfile: pendingProfile,
            voiceProfile: .simulatedMiddle,
            scenario: ScenarioConfig(scenario: .friends, peopleCount: 4, durationMinutes: 45),
            catalog: [track],
            inputSource: .userImport
        )
        let confirmed = try XCTUnwrap(pending.confirming(track: track))
        let confirmedProfile = PreferenceProfiler().buildProfile(importedPlaylist: playlist, matches: [confirmed])
        let confirmedPlan = RecommendationEngine().generatePlan(
            matches: [confirmed],
            preferenceProfile: confirmedProfile,
            voiceProfile: .simulatedMiddle,
            scenario: ScenarioConfig(scenario: .friends, peopleCount: 4, durationMinutes: 45),
            catalog: [track],
            inputSource: .userImport
        )

        XCTAssertFalse(pendingPlan.sections.flatMap(\.items).contains { $0.track.id == track.id })
        XCTAssertTrue(confirmedPlan.sections.flatMap(\.items).contains { $0.track.id == track.id })
    }

    func testPendingAndUnmatchedUserImportsUseNeutralScenarioPlanSummary() {
        let referenceTrack = makeTrack(
            id: "reference",
            title: "同名待确认歌",
            artist: "候选歌手"
        )
        let pendingSong = ImportedSong(
            title: referenceTrack.title,
            source: .plainText,
            confidence: 1
        )
        let pendingPlaylist = ImportedPlaylist(
            source: .plainText,
            title: "待确认歌单",
            songs: [pendingSong],
            parseConfidence: 1
        )
        let pendingMatch = SongMatcher().match(song: pendingSong, catalog: [referenceTrack])

        let unmatchedSong = ImportedSong(
            title: "未命中歌曲",
            artist: "真实导入歌手",
            source: .plainText,
            confidence: 1
        )
        let unmatchedPlaylist = ImportedPlaylist(
            source: .plainText,
            title: "未命中歌单",
            songs: [unmatchedSong],
            parseConfidence: 1
        )
        let unmatchedMatch = MatchResult(
            importedSong: unmatchedSong,
            matchedTrack: nil,
            alternatives: [],
            status: .unmatched,
            score: 0,
            reason: "未找到本地参考"
        )
        let cases = [
            (name: "pending", playlist: pendingPlaylist, matches: [pendingMatch]),
            (name: "unmatched", playlist: unmatchedPlaylist, matches: [unmatchedMatch])
        ]
        let scenario = ScenarioConfig(scenario: .friends)

        for testCase in cases {
            let profile = PreferenceProfiler().buildProfile(
                importedPlaylist: testCase.playlist,
                matches: testCase.matches
            )
            let plan = RecommendationEngine().generatePlan(
                matches: testCase.matches,
                preferenceProfile: profile,
                voiceProfile: .simulatedMiddle,
                scenario: scenario,
                catalog: [referenceTrack],
                inputSource: .userImport
            )

            XCTAssertFalse(profile.hasReferenceInsights, testCase.name)
            XCTAssertEqual(plan.preferenceSummary, KTVScenario.friends.planSummary, testCase.name)
            XCTAssertFalse(plan.preferenceSummary?.contains("你平时听") == true, testCase.name)
            XCTAssertFalse(plan.preferenceSummary?.contains("流行歌偏多") == true, testCase.name)
            XCTAssertFalse(plan.preferenceSummary?.contains("熟悉旋律") == true, testCase.name)
        }
        XCTAssertEqual(
            PreferenceProfiler()
                .buildProfile(importedPlaylist: unmatchedPlaylist, matches: [unmatchedMatch])
                .topArtists.first?.name,
            "真实导入歌手"
        )
    }

    func testPeopleCountChangesGroupRecommendationStrategy() {
        let catalog = [
            makeTrack(id: "solo", title: "想唱的歌", artist: "歌手A", difficulty: 5, singAlong: 0.45, highRisk: 0.62, sceneTags: ["friends"], energy: 0.82),
            makeTrack(id: "chorus1", title: "全员合唱一", artist: "歌手B", difficulty: 2, singAlong: 0.92, highRisk: 0.2, sceneTags: ["friends", "teamBuilding"], energy: 0.72),
            makeTrack(id: "chorus2", title: "全员合唱二", artist: "歌手C", difficulty: 2, singAlong: 0.9, highRisk: 0.2, sceneTags: ["friends", "teamBuilding"], energy: 0.7),
            makeTrack(id: "easy", title: "稳妥热身", artist: "歌手D", difficulty: 2, singAlong: 0.82, highRisk: 0.25, sceneTags: ["friends"], energy: 0.68)
        ]
        let matches = catalog.map(match)
        let profile = makeProfile()

        let smallPlan = RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: profile,
            voiceProfile: .simulatedMiddle,
            scenario: ScenarioConfig(scenario: .friends, peopleCount: 2, durationMinutes: 45, difficultyPreference: .showcase),
            catalog: catalog
        )
        let largePlan = RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: profile,
            voiceProfile: .simulatedMiddle,
            scenario: ScenarioConfig(scenario: .friends, peopleCount: 10, durationMinutes: 45, difficultyPreference: .showcase),
            catalog: catalog
        )

        let smallItems = smallPlan.sections.flatMap(\.items)
        let largeItems = largePlan.sections.flatMap(\.items)
        let smallChorusRatio = Double(smallItems.filter { $0.track.singAlongScore >= 0.78 }.count) / Double(max(smallItems.count, 1))
        let largeChorusRatio = Double(largeItems.filter { $0.track.singAlongScore >= 0.78 }.count) / Double(max(largeItems.count, 1))

        XCTAssertGreaterThanOrEqual(largeChorusRatio, smallChorusRatio)
        XCTAssertFalse(largeItems.first?.track.id == "solo")
    }

    func testFeedbackChangesRegeneratedRecommendation() {
        let catalog = [
            makeTrack(id: "safe", title: "稳妥歌", artist: "歌手A", difficulty: 2, singAlong: 0.86, highRisk: 0.2, sceneTags: ["friends"], energy: 0.7),
            makeTrack(id: "high", title: "高音歌", artist: "歌手B", difficulty: 4, singAlong: 0.8, highRisk: 0.75, sceneTags: ["friends"], energy: 0.82)
        ]
        let matches = catalog.map(match)
        let feedback = SongFeedbackProfile(feedbackByTrackID: [
            "safe": [.liked],
            "high": [.tooHigh, .unfamiliar]
        ])

        let plan = RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: makeProfile(),
            voiceProfile: .simulatedMiddle,
            scenario: ScenarioConfig(scenario: .friends, peopleCount: 4, durationMinutes: 45),
            catalog: catalog,
            feedbackProfile: feedback
        )

        let first = plan.sections.flatMap(\.items).first
        XCTAssertEqual(first?.track.id, "safe")
        XCTAssertTrue(first?.feedbackTags.contains(.liked) == true)
    }

    func testCommonReferenceVoiceIsNeutralAndDoesNotProduceExactKeyAdvice() {
        let track = makeTrack(id: "high", title: "高音歌", artist: "歌手B", difficulty: 4, singAlong: 0.8, highRisk: 0.8, highMidi: 74)
        let voice = VoiceProfile.simulatedMiddle

        XCTAssertEqual(voice.source, .commonReference)
        XCTAssertEqual(voice.type, .unknown)
        XCTAssertEqual(voice.confidence, 0)
        XCTAssertTrue(voice.note.contains("常见音域参考"))
        XCTAssertFalse(voice.note.contains("男声"))
        XCTAssertFalse(voice.note.contains("女声"))
        XCTAssertNil(SingingAdjustmentAdvisor().advice(for: track, voiceProfile: voice))
    }

    func testMeasuredVoiceStillProducesRangeAwareAdvice() throws {
        let track = makeTrack(id: "high", title: "高音歌", artist: "歌手B", difficulty: 4, singAlong: 0.8, highRisk: 0.8, highMidi: 74)
        let voice = makeMeasuredVoice()

        let advice = try XCTUnwrap(SingingAdjustmentAdvisor().advice(for: track, voiceProfile: voice))

        XCTAssertEqual(advice.level, .substitute)
        XCTAssertEqual(advice.semitoneShift, 0)
        XCTAssertTrue(advice.detail.contains("低音和高音"))
        XCTAssertFalse(advice.detail.contains("舒服范围"))
    }

    func testExampleAndPopularFallbackPlansDoNotClaimPlaylistOrVoicePersonalization() {
        let track = makeTrack(id: "safe", title: "稳妥歌", artist: "歌手A", difficulty: 2, singAlong: 0.86, highRisk: 0.2, highMidi: 65)
        let match = match(track)

        for inputSource in [RecommendationInputSource.example, .popularFallback] {
            let plan = RecommendationEngine().generatePlan(
                matches: [match],
                preferenceProfile: makeProfile(),
                voiceProfile: .simulatedMiddle,
                scenario: ScenarioConfig(scenario: .friends, peopleCount: 4, durationMinutes: 45),
                catalog: [track],
                inputSource: inputSource
            )

            let items = plan.sections.flatMap(\.items)
            let visibleText = ([plan.preferenceSummary ?? ""] + items.flatMap(\.reasons)).joined(separator: "｜")
            XCTAssertEqual(plan.inputSource, inputSource)
            XCTAssertFalse(visibleText.contains("你歌单"), inputSource.rawValue)
            XCTAssertFalse(visibleText.contains("你的声线"), inputSource.rawValue)
            XCTAssertFalse(visibleText.contains("你的音域"), inputSource.rawValue)
            XCTAssertFalse(visibleText.contains("你平时听"), inputSource.rawValue)
            XCTAssertTrue(items.allSatisfy { $0.singingAdvice == nil }, inputSource.rawValue)
        }
    }

    func testUserImportAndMeasuredVoiceCanProduceSourceGroundedReasons() {
        let track = makeTrack(id: "safe", title: "稳妥歌", artist: "歌手A", difficulty: 2, singAlong: 0.7, highRisk: 0.2, highMidi: 65)

        let plan = RecommendationEngine().generatePlan(
            matches: [match(track)],
            preferenceProfile: makeProfile(),
            voiceProfile: makeMeasuredVoice(),
            scenario: ScenarioConfig(scenario: .friends, peopleCount: 4, durationMinutes: 45),
            catalog: [track],
            inputSource: .userImport
        )

        let reasons = plan.sections.flatMap(\.items).flatMap(\.reasons)
        XCTAssertTrue(reasons.contains("你歌单里本来就有这位歌手"))
        XCTAssertTrue(reasons.contains("本次唱到的音区与歌曲接近"))
    }

    func testPublicRecommendationAPIsDefaultOmittedSourcesToLegacyUnknown() {
        let track = makeTrack(id: "safe", title: "稳妥歌", artist: "歌手A", difficulty: 2, singAlong: 0.7, highRisk: 0.2, highMidi: 65)
        let profile = makeProfile()
        let voice = makeMeasuredVoice()
        let scenario = ScenarioConfig(scenario: .friends, peopleCount: 4, durationMinutes: 45)
        let enginePlan = RecommendationEngine().generatePlan(
            matches: [match(track)],
            preferenceProfile: profile,
            voiceProfile: voice,
            scenario: scenario,
            catalog: [track]
        )
        let builderReasons = RecommendationReasonBuilder().reasons(
            for: track,
            preferenceProfile: profile,
            voiceProfile: voice,
            scenario: scenario,
            importedArtistCounts: [track.artist: 1]
        )
        let manualPlan = SongPlan(
            title: "未标来源歌单",
            scenario: .friends,
            sections: []
        )

        XCTAssertEqual(enginePlan.inputSource, .legacyUnknown)
        XCTAssertFalse(enginePlan.sections.flatMap(\.items).flatMap(\.reasons).contains("你歌单里本来就有这位歌手"))
        XCTAssertFalse(builderReasons.contains("你歌单里本来就有这位歌手"))
        XCTAssertEqual(manualPlan.inputSource, .legacyUnknown)
    }

    func testMissingLegacySourceDoesNotGrantMeasuredVoiceClaims() throws {
        let legacyVoiceJSON = """
        {
          "type": "midMale",
          "minMidi": 48,
          "maxMidi": 72,
          "stableLowMidi": 53,
          "stableHighMidi": 67,
          "averageMidi": 60.5,
          "confidence": 0.86,
          "note": "旧版实测结果",
          "suitableSongTypes": [],
          "avoidSongTypes": [],
          "singingStrategy": [],
          "createdAt": 0
        }
        """
        let legacyPlanJSON = """
        {
          "id": "6B8E4D01-9A0C-4D7A-9D0C-94C1936F6471",
          "title": "旧歌单",
          "scenario": "friends",
          "sections": [],
          "createdAt": 0
        }
        """

        let voice = try JSONDecoder().decode(VoiceProfile.self, from: Data(legacyVoiceJSON.utf8))
        let plan = try JSONDecoder().decode(SongPlan.self, from: Data(legacyPlanJSON.utf8))

        XCTAssertEqual(voice.source, .legacyUnknown)
        XCTAssertFalse(voice.source.allowsMeasuredRangeClaims)
        XCTAssertEqual(plan.inputSource, .legacyUnknown)
    }

    func testExplicitMeasuredVoiceSourceRemainsMeasuredWhenDecoding() throws {
        let json = """
        {
          "type": "midMale",
          "source": "measured",
          "minMidi": 48,
          "maxMidi": 72,
          "stableLowMidi": 53,
          "stableHighMidi": 67,
          "averageMidi": 60.5,
          "confidence": 0.86,
          "note": "旧版实测结果",
          "suitableSongTypes": [],
          "avoidSongTypes": [],
          "singingStrategy": [],
          "createdAt": 0
        }
        """

        let voice = try JSONDecoder().decode(VoiceProfile.self, from: Data(json.utf8))

        XCTAssertEqual(voice.source, .measured)
        XCTAssertTrue(voice.source.allowsMeasuredRangeClaims)
    }

    func testLegacySimulatedVoiceFingerprintMigratesToNeutralCommonReference() throws {
        let legacyNotes = [
            "模拟声线：适合大多数华语流行歌，连续高音歌曲建议减少。",
            "适合大多数华语流行歌，连续高音歌少排几首更稳。"
        ]

        for legacyNote in legacyNotes {
            let legacyJSON = """
            {
              "type": "midMale",
              "minMidi": 48,
              "maxMidi": 72,
              "stableLowMidi": 53,
              "stableHighMidi": 67,
              "averageMidi": 60.5,
              "confidence": 0.86,
              "note": "\(legacyNote)",
              "suitableSongTypes": ["华语流行"],
              "avoidSongTypes": ["长时间高音"],
              "singingStrategy": ["先热身"],
              "createdAt": 0
            }
            """

            let voice = try JSONDecoder().decode(VoiceProfile.self, from: Data(legacyJSON.utf8))

            XCTAssertEqual(voice.source, .commonReference, legacyNote)
            XCTAssertEqual(voice.type, .unknown, legacyNote)
            XCTAssertEqual(voice.confidence, 0, legacyNote)
            XCTAssertTrue(voice.note.contains("常见音域参考"), legacyNote)
            XCTAssertNil(SingingAdjustmentAdvisor().advice(
                for: makeTrack(id: "high", title: "高音歌", artist: "歌手B", highMidi: 74),
                voiceProfile: voice
            ), legacyNote)
        }
    }

    func testVoiceProfileProvidesGenderNeutralUserFacingTags() {
        var voice = makeMeasuredVoice()
        voice.suitableSongTypes = ["男声低音歌", "女声流行", "合唱"]
        voice.avoidSongTypes = ["强爆发女声歌", "密集 Rap"]

        let visibleText = (voice.userFacingSuitableSongTypes + voice.userFacingAvoidSongTypes).joined(separator: "｜")

        XCTAssertFalse(visibleText.contains("男声"))
        XCTAssertFalse(visibleText.contains("女声"))
        XCTAssertTrue(visibleText.contains("低音歌"))
        XCTAssertTrue(visibleText.contains("流行"))
        XCTAssertTrue(visibleText.contains("强爆发歌"))
    }

    func testSourcePoliciesGatePreferenceAndMeasuredVoiceClaims() {
        XCTAssertTrue(RecommendationInputSource.userImport.allowsPlaylistPersonalization)
        XCTAssertFalse(RecommendationInputSource.example.allowsPlaylistPersonalization)
        XCTAssertFalse(RecommendationInputSource.popularFallback.allowsPlaylistPersonalization)
        XCTAssertTrue(VoiceProfileSource.measured.allowsMeasuredRangeClaims)
        XCTAssertFalse(VoiceProfileSource.commonReference.allowsMeasuredRangeClaims)
        XCTAssertFalse(VoiceProfileSource.legacyUnknown.allowsMeasuredRangeClaims)
    }

    func testFallbackSourcesRejectHistoricalImportedPlaylistReason() {
        let historicalReason = "你导入的歌单中出现过该歌手"

        XCTAssertTrue(RecommendationInputSource.userImport.allowsRecommendationReason(
            historicalReason,
            voiceSource: .measured
        ))
        for source in [RecommendationInputSource.example, .popularFallback, .legacyUnknown] {
            XCTAssertFalse(source.allowsRecommendationReason(
                historicalReason,
                voiceSource: .commonReference
            ), source.rawValue)
        }
    }

    func testPreferenceInsightTitlePersonalizesOnlyUserImport() {
        XCTAssertEqual(RecommendationInputSource.userImport.preferenceInsightTitle, "你常听的风格")
        XCTAssertEqual(RecommendationInputSource.example.preferenceInsightTitle, "示例歌单的风格")
        XCTAssertEqual(RecommendationInputSource.popularFallback.preferenceInsightTitle, "热门歌单的风格")
        XCTAssertEqual(RecommendationInputSource.legacyUnknown.preferenceInsightTitle, "这份歌单的风格")
    }

    func testLowMatchReportSummaryPersonalizesOnlyUserImport() {
        var profile = makeProfile()
        profile.ktvMatchRate = 1
        for source in RecommendationInputSource.allCases {
            XCTAssertEqual(
                source.matchReportSummary(for: profile),
                "熟歌不少，先用大家会唱的热场，后面再放个人发挥。",
                source.rawValue
            )
        }

        profile.ktvMatchRate = 0.4
        profile.summary = "你平时听的流行歌偏多"

        XCTAssertEqual(
            RecommendationInputSource.userImport.matchReportSummary(for: profile),
            profile.summary
        )
        for source in [RecommendationInputSource.example, .popularFallback, .legacyUnknown] {
            let summary = source.matchReportSummary(for: profile)
            XCTAssertEqual(
                summary,
                "有些歌暂时没找到，先挑有本地参考的，再核对或准备替换。",
                source.rawValue
            )
            XCTAssertFalse(summary.contains("能唱"), source.rawValue)
            XCTAssertFalse(summary.contains("你平时听"), source.rawValue)
        }
    }

    func testActionLinkBuilderUsesExternalURLBeforeSearchURL() {
        let externalTrack = makeTrack(
            id: "external:lastFM:七里香|周杰伦",
            title: "七里香",
            artist: "周杰伦",
            externalURL: URL(string: "https://music.apple.com/song/3001"),
            catalogSource: .externalSimilar
        )
        let localTrack = makeTrack(id: "local", title: "晴天", artist: "周杰伦")

        XCTAssertEqual(SongActionLinkBuilder().url(for: externalTrack)?.absoluteString, "https://music.apple.com/song/3001")
        let localURL = SongActionLinkBuilder().url(for: localTrack)
        XCTAssertEqual(localURL?.host, "music.apple.com")
        XCTAssertEqual(localURL?.path, "/cn/search")
        XCTAssertTrue(localURL?.absoluteString.contains("term=") == true)
    }

    func testSongPlanItemDecodesLegacyJSONWithoutNewClosureFields() throws {
        let legacyJSON = """
        {
          "id": "6B8E4D01-9A0C-4D7A-9D0C-94C1936F6471",
          "track": {
            "id": "legacy",
            "title": "旧歌单",
            "artist": "歌手A",
            "language": "Mandarin",
            "era": "2000s",
            "genre": "华语流行",
            "moodTags": ["相似推荐"],
            "sceneTags": ["friends"],
            "difficulty": 3,
            "vocalRangeLowMidi": 48,
            "vocalRangeHighMidi": 69,
            "energy": 0.7,
            "singAlongScore": 0.8,
            "ktvAvailability": 0.85,
            "duetFriendly": false,
            "rapDensity": 0.1,
            "highNoteRisk": 0.4,
            "aliases": [],
            "similarSongIds": []
          },
          "score": 0.82,
          "scoreBreakdown": {
            "preferenceAffinity": 0.82,
            "ktvAvailabilityScore": 0.82,
            "vocalFitScore": 0.82,
            "singAlongScore": 0.82,
            "sceneFitScore": 0.82,
            "varietyScore": 0.82,
            "riskPenalty": 0,
            "finalScore": 0.82
          },
          "reasons": ["旧版推荐理由"],
          "riskWarnings": [],
          "alternatives": [],
          "isLocked": false
        }
        """

        let item = try JSONDecoder().decode(SongPlanItem.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(item.track.id, "legacy")
        XCTAssertNil(item.singingAdvice)
        XCTAssertNil(item.actionURL)
        XCTAssertEqual(item.feedbackTags, [])
    }

    func testFeedbackProfileTogglesEachSignalIndependently() {
        var profile = SongFeedbackProfile()

        profile.toggle(trackID: "song", kind: .liked)
        XCTAssertEqual(profile.feedback(for: "song"), [.liked])

        profile.toggle(trackID: "song", kind: .liked)
        XCTAssertEqual(profile.feedback(for: "song"), [])

        profile.toggle(trackID: "song", kind: .liked)
        profile.toggle(trackID: "song", kind: .tooHigh)

        XCTAssertTrue(profile.contains(trackID: "song", kind: .liked))
        XCTAssertTrue(profile.contains(trackID: "song", kind: .tooHigh))
    }

    func testFeedbackProfileCanRestorePreviousTagsForUndo() {
        var profile = SongFeedbackProfile(feedbackByTrackID: ["song": [.liked, .sung]])
        let previousTags = profile.feedback(for: "song")

        profile.toggle(trackID: "song", kind: .tooHigh)
        XCTAssertEqual(profile.feedback(for: "song"), [.liked, .sung, .tooHigh])

        profile.setFeedback(trackID: "song", kinds: previousTags)
        XCTAssertEqual(profile.feedback(for: "song"), [.liked, .sung])
    }

    func testExternalCandidateMergeKeepsExistingCandidatesWhenExpandedAgain() {
        let candidate = ExternalSongCandidate(title: "七里香", artist: "周杰伦", source: .iTunes, confidence: 0.9)
        let mapper = ExternalCandidateTrackMapper()
        let existing = [mapper.map(candidate)]

        let merged = ExternalCandidateTrackAccumulator().mergedTracks(
            baseCatalog: [],
            existingExternalTracks: existing,
            candidates: [candidate],
            limit: 12
        )

        XCTAssertEqual(merged.map(\.id), existing.map(\.id))
    }

    private func makeProfile() -> PreferenceProfile {
        PreferenceProfile(
            topArtists: [("歌手A", 1)],
            languageDistribution: ["Mandarin": 1],
            eraDistribution: ["2000s": 1],
            genreDistribution: ["华语流行": 1],
            moodTags: ["相似推荐": 1],
            sceneAffinity: ["friends": 1],
            ktvMatchRate: 1,
            averageDifficulty: 3,
            averageSingAlongScore: 0.8,
            highNoteRisk: 0.4,
            summary: "测试画像"
        )
    }

    private func makeMeasuredVoice() -> VoiceProfile {
        VoiceProfile(
            type: .midMale,
            minMidi: 48,
            maxMidi: 72,
            stableLowMidi: 48,
            stableHighMidi: 67,
            averageMidi: 60.5,
            confidence: 0.86,
            note: "本次录音结果",
            source: .measured
        )
    }

    private func match(_ track: KTVTrack) -> MatchResult {
        MatchResult(
            importedSong: ImportedSong(title: track.title, artist: track.artist, source: .plainText, confidence: 1),
            matchedTrack: track,
            alternatives: [],
            status: .exact,
            score: 1,
            reason: "测试匹配"
        )
    }

    private func makeTrack(
        id: String,
        title: String,
        artist: String,
        difficulty: Int = 3,
        singAlong: Double = 0.8,
        highRisk: Double = 0.4,
        sceneTags: [String] = ["friends"],
        energy: Double = 0.7,
        highMidi: Int = 69,
        externalURL: URL? = nil,
        catalogSource: TrackCatalogSource = .ktvCatalog
    ) -> KTVTrack {
        KTVTrack(
            id: id,
            title: title,
            artist: artist,
            language: "Mandarin",
            era: "2000s",
            genre: "华语流行",
            moodTags: ["相似推荐"],
            sceneTags: sceneTags,
            difficulty: difficulty,
            vocalRangeLowMidi: 48,
            vocalRangeHighMidi: highMidi,
            energy: energy,
            singAlongScore: singAlong,
            ktvAvailability: 0.85,
            duetFriendly: singAlong >= 0.88,
            rapDensity: 0.1,
            highNoteRisk: highRisk,
            aliases: [],
            similarSongIds: [],
            externalURL: externalURL,
            catalogSource: catalogSource,
            confidenceNote: catalogSource == .externalSimilar ? "相近备选，到店里可能还要搜一下" : nil
        )
    }
}
