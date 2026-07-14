import XCTest
@testable import SingReadyAISharedKit

final class ProductClosureTests: XCTestCase {
    func testDispositionDerivedPropertiesPartitionAcceptedPendingAndUnmatched() {
        let original = makeTrack(id: "original", title: "原曲", artist: "原歌手")
        let candidate = makeTrack(id: "candidate", title: "候选", artist: "候选歌手")
        let replacement = makeTrack(id: "replacement", title: "替代", artist: "替代歌手")
        let song = ImportedSong(title: original.title, artist: original.artist, source: .plainText, confidence: 1)
        let cases: [(result: MatchResult, acceptedID: String?, candidateIDs: [String], verified: Bool, pending: Bool, unmatched: Bool, original: Bool, adopted: Bool)] = [
            (
                MatchResult(importedSong: song, disposition: .acceptedOriginalExact(track: original), score: 1, reason: "精确"),
                original.id, [], true, false, false, true, false
            ),
            (
                MatchResult(importedSong: song, disposition: .acceptedOriginalConfirmed(track: original), score: 1, reason: "已确认"),
                original.id, [], true, false, false, true, false
            ),
            (
                MatchResult(importedSong: song, disposition: .identityConfirmationRequired(candidates: [candidate, candidate]), score: 0.8, reason: "待确认"),
                nil, [candidate.id], false, true, false, false, false
            ),
            (
                MatchResult(importedSong: song, disposition: .alternativeSuggested(candidates: [replacement, replacement]), score: 0.7, reason: "可替代"),
                nil, [replacement.id], false, true, false, false, false
            ),
            (
                MatchResult(importedSong: song, disposition: .adoptedAlternative(track: replacement), score: 0.7, reason: "已采用"),
                replacement.id, [], true, false, false, false, true
            ),
            (
                MatchResult(importedSong: song, disposition: .unmatched, score: 0, reason: "未找到"),
                nil, [], false, false, true, false, false
            )
        ]

        for testCase in cases {
            XCTAssertEqual(testCase.result.acceptedTrack?.id, testCase.acceptedID)
            XCTAssertEqual(testCase.result.candidateTracks.map(\.id), testCase.candidateIDs)
            XCTAssertEqual(testCase.result.isVerified, testCase.verified)
            XCTAssertEqual(testCase.result.isPending, testCase.pending)
            XCTAssertEqual(testCase.result.isUnmatched, testCase.unmatched)
            XCTAssertEqual(testCase.result.hasOriginalReferenceMatch, testCase.original)
            XCTAssertEqual(testCase.result.isAdoptedAlternative, testCase.adopted)
        }
    }

    func testSuggestedAlternativesAreNormalizedAndExcludedFromAcceptedTrackAndProfile() {
        let original = makeTrack(id: "original", title: "原曲", artist: "原歌手", difficulty: 2)
        let suggestion = makeTrack(id: "suggestion", title: "建议替代", artist: "另一歌手", difficulty: 5)
        let song = ImportedSong(
            title: original.title,
            artist: original.artist,
            source: .plainText,
            confidence: 1
        )
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "建议隔离",
            songs: [song],
            parseConfidence: 1
        )
        let result = MatchResult(
            importedSong: song,
            disposition: .acceptedOriginalExact(track: original),
            suggestedAlternatives: [suggestion, original, suggestion],
            score: 1,
            reason: "精确"
        )

        let profile = PreferenceProfiler().buildProfile(importedPlaylist: playlist, matches: [result])

        XCTAssertEqual(result.acceptedTrack?.id, original.id)
        XCTAssertEqual(result.suggestedAlternatives.map(\.id), [suggestion.id])
        XCTAssertEqual(profile.averageDifficulty, 2)
        XCTAssertEqual(profile.topArtists.first?.name, original.artist)
        XCTAssertEqual(profile.genreDistribution[original.genre], 1)
    }

    func testPreferenceProfileArtistsComeOnlyFromAcceptedTracks() {
        let acceptedTrack = makeTrack(
            id: "accepted",
            title: "已接受原曲",
            artist: "已接受曲库歌手",
            difficulty: 2
        )
        let pendingTrack = makeTrack(
            id: "pending",
            title: "待确认歌曲",
            artist: "待确认候选歌手",
            difficulty: 5
        )
        let adoptedTrack = makeTrack(
            id: "adopted",
            title: "采用替代歌曲",
            artist: "采用后曲库歌手",
            difficulty: 5
        )
        let acceptedSong = ImportedSong(
            title: acceptedTrack.title,
            artist: "原导入歌手",
            source: .plainText,
            confidence: 1
        )
        let pendingSong = ImportedSong(
            title: pendingTrack.title,
            artist: "待确认导入歌手",
            source: .plainText,
            confidence: 1
        )
        let unmatchedSong = ImportedSong(
            title: "未命中歌曲",
            artist: "未命中导入歌手",
            source: .plainText,
            confidence: 1
        )
        let adoptedSong = ImportedSong(
            title: "原歌曲",
            artist: "采用前导入歌手",
            source: .plainText,
            confidence: 1
        )
        let matches = [
            MatchResult(
                importedSong: acceptedSong,
                disposition: .acceptedOriginalConfirmed(track: acceptedTrack),
                score: 1,
                reason: "已确认"
            ),
            MatchResult(
                importedSong: pendingSong,
                disposition: .identityConfirmationRequired(candidates: [pendingTrack]),
                score: 0.8,
                reason: "待确认"
            ),
            MatchResult(
                importedSong: unmatchedSong,
                disposition: .unmatched,
                score: 0,
                reason: "未找到"
            ),
            MatchResult(
                importedSong: adoptedSong,
                disposition: .adoptedAlternative(track: adoptedTrack),
                score: 0.7,
                reason: "已采用替代歌曲"
            )
        ]
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "画像准入隔离",
            songs: [acceptedSong, pendingSong, unmatchedSong, adoptedSong],
            parseConfidence: 1
        )

        let profile = PreferenceProfiler().buildProfile(
            importedPlaylist: playlist,
            matches: matches
        )
        let artistCounts = Dictionary(
            uniqueKeysWithValues: profile.topArtists.map { ($0.name, $0.count) }
        )

        XCTAssertEqual(
            artistCounts,
            [acceptedTrack.artist: 1, adoptedTrack.artist: 1]
        )
        XCTAssertEqual(profile.averageDifficulty, 3.5)
    }

    func testDispositionActionsOnlyAllowConstrainedStateTransitions() throws {
        let first = makeTrack(id: "first", title: "同名歌曲", artist: "歌手A")
        let second = makeTrack(id: "second", title: "同名歌曲", artist: "歌手B")
        let outside = makeTrack(id: "outside", title: "候选外", artist: "歌手C")
        let song = ImportedSong(title: first.title, source: .plainText, confidence: 0.9)
        let identityPending = MatchResult(
            importedSong: song,
            disposition: .identityConfirmationRequired(candidates: [first, second]),
            score: 0.9,
            reason: "待确认"
        )
        let alternativePending = MatchResult(
            importedSong: song,
            disposition: .alternativeSuggested(candidates: [first, second]),
            score: 0.7,
            reason: "可替代"
        )

        let confirmed = try XCTUnwrap(identityPending.confirming(track: first))
        assertAcceptedOriginalConfirmed(confirmed, trackID: first.id)
        let adoptedFromIdentity = try XCTUnwrap(identityPending.adoptingAlternative(track: first))
        assertAdoptedAlternative(adoptedFromIdentity, trackID: first.id)
        XCTAssertEqual(adoptedFromIdentity.id, identityPending.id)
        XCTAssertEqual(adoptedFromIdentity.importedSong.id, song.id)
        let adoptedFromSuggestion = try XCTUnwrap(alternativePending.adoptingAlternative(track: first))
        assertAdoptedAlternative(adoptedFromSuggestion, trackID: first.id)

        let exact = MatchResult(
            importedSong: song,
            disposition: .acceptedOriginalExact(track: first),
            suggestedAlternatives: [second],
            score: 1,
            reason: "精确"
        )
        let switchedFromExact = try XCTUnwrap(exact.adoptingAlternative(track: second))
        assertAdoptedAlternative(switchedFromExact, trackID: second.id)
        XCTAssertEqual(switchedFromExact.suggestedAlternatives.map(\.id), [first.id])

        let confirmedWithSuggestion = MatchResult(
            importedSong: song,
            disposition: .acceptedOriginalConfirmed(track: first),
            suggestedAlternatives: [second],
            score: 1,
            reason: "已确认"
        )
        assertAdoptedAlternative(
            try XCTUnwrap(confirmedWithSuggestion.adoptingAlternative(track: second)),
            trackID: second.id
        )

        let adoptedAgain = try XCTUnwrap(switchedFromExact.adoptingAlternative(track: first))
        assertAdoptedAlternative(adoptedAgain, trackID: first.id)

        let unmatched = MatchResult(importedSong: song, disposition: .unmatched, score: 0, reason: "未找到")
        XCTAssertNil(identityPending.confirming(track: outside))
        XCTAssertNil(identityPending.adoptingAlternative(track: outside))
        XCTAssertNil(alternativePending.adoptingAlternative(track: outside))
        XCTAssertNil(confirmed.confirming(track: first))
        XCTAssertNil(switchedFromExact.adoptingAlternative(track: second))
        XCTAssertNil(unmatched.confirming(track: first))
        XCTAssertNil(unmatched.adoptingAlternative(track: first))
    }

    func testDispositionStatisticsUseCompleteNonOverlappingPartitions() {
        let original = makeTrack(id: "original", title: "原曲", artist: "原歌手")
        let alternative = makeTrack(id: "alternative", title: "替代", artist: "替代歌手")
        let song = ImportedSong(title: original.title, artist: original.artist, source: .plainText, confidence: 1)
        let matches = [
            MatchResult(importedSong: song, disposition: .acceptedOriginalExact(track: original), score: 1, reason: "精确"),
            MatchResult(importedSong: song, disposition: .acceptedOriginalConfirmed(track: original), score: 1, reason: "确认"),
            MatchResult(importedSong: song, disposition: .identityConfirmationRequired(candidates: [original]), score: 0.9, reason: "待确认"),
            MatchResult(importedSong: song, disposition: .alternativeSuggested(candidates: [alternative]), score: 0.7, reason: "可替代"),
            MatchResult(importedSong: song, disposition: .adoptedAlternative(track: alternative), score: 0.7, reason: "已采用"),
            MatchResult(importedSong: song, disposition: .unmatched, score: 0, reason: "未找到")
        ]

        let statistics = MatchStatistics(matches: matches)

        XCTAssertEqual(statistics.verified, 3)
        XCTAssertEqual(statistics.pending, 2)
        XCTAssertEqual(statistics.unmatched, 1)
        XCTAssertEqual(statistics.originalAccepted, 2)
        XCTAssertEqual(statistics.adoptedAlternative, 1)
        XCTAssertEqual(statistics.total, matches.count)
        XCTAssertEqual(statistics.verified + statistics.pending + statistics.unmatched, matches.count)
        XCTAssertEqual(statistics.originalAccepted + statistics.adoptedAlternative, statistics.verified)
    }

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

    func testCompletedAnalysisAdoptsAlternativeAndRebuildsProfileAtomically() throws {
        let original = makeTrack(
            id: "atomic-original",
            title: "原曲",
            artist: "原歌手",
            genre: "民谣"
        )
        let alternative = makeTrack(
            id: "atomic-alternative",
            title: "替代歌",
            artist: "替代歌手",
            genre: "摇滚"
        )
        let importedSong = ImportedSong(
            title: original.title,
            artist: original.artist,
            source: .plainText,
            confidence: 1
        )
        let resultID = UUID()
        let basis = MatchBasis(
            playlistID: UUID(),
            reviewRevision: 2,
            catalogRevision: "catalog-a"
        )
        let analysis = CompletedPlaylistAnalysis(
            basis: basis,
            matchRevision: 5,
            matches: [
                MatchResult(
                    id: resultID,
                    importedSong: importedSong,
                    disposition: .acceptedOriginalExact(track: original),
                    suggestedAlternatives: [alternative],
                    score: 1,
                    reason: "原曲命中"
                )
            ],
            preferenceProfile: PreferenceProfiler().buildProfile(
                importedPlaylist: ImportedPlaylist(
                    id: basis.playlistID,
                    source: .plainText,
                    title: "原子替代",
                    songs: [importedSong],
                    parseConfidence: 1
                ),
                matches: []
            )
        )

        let updated = try analysis.applying(
            .adoptAlternative(resultID: resultID, trackID: alternative.id),
            profiler: PreferenceProfiler()
        )

        XCTAssertEqual(updated.basis, basis)
        XCTAssertEqual(updated.matchRevision, 6)
        XCTAssertEqual(updated.matches.count, 1)
        XCTAssertTrue(updated.matches[0].isAdoptedAlternative)
        XCTAssertEqual(updated.matches[0].acceptedTrack?.id, alternative.id)
        XCTAssertEqual(updated.preferenceProfile.topArtists.first?.name, alternative.artist)
        XCTAssertEqual(updated.preferenceProfile.genreDistribution[alternative.genre], 1)
        XCTAssertEqual(updated.preferenceProfile.ktvMatchRate, 0)
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
        let scenario = ScenarioConfig(scenario: .friends, peopleCount: 4, durationMinutes: 45)
        let voice = VoiceProfile.simulatedMiddle

        let pendingPlan = try RecommendationEngine().generatePlan(
            matches: [pending],
            preferenceProfile: pendingProfile,
            voiceProfile: voice,
            scenario: scenario,
            catalog: [track],
            generationContext: makeRecommendationGenerationContext(
                matches: [pending],
                scenario: scenario,
                voiceProfile: voice,
                playlistTitle: playlist.title
            ),
            inputSource: .userImport
        )
        let confirmed = try XCTUnwrap(pending.confirming(track: track))
        let confirmedProfile = PreferenceProfiler().buildProfile(importedPlaylist: playlist, matches: [confirmed])
        let confirmedPlan = try RecommendationEngine().generatePlan(
            matches: [confirmed],
            preferenceProfile: confirmedProfile,
            voiceProfile: voice,
            scenario: scenario,
            catalog: [track],
            generationContext: makeRecommendationGenerationContext(
                matches: [confirmed],
                scenario: scenario,
                voiceProfile: voice,
                playlistTitle: playlist.title
            ),
            inputSource: .userImport
        )

        XCTAssertFalse(pendingPlan.sections.flatMap(\.items).contains { $0.track.id == track.id })
        XCTAssertTrue(confirmedPlan.sections.flatMap(\.items).contains { $0.track.id == track.id })
    }

    func testPendingPathDoesNotSuppressSameTrackAcceptedByAnotherImport() throws {
        let track = makeTrack(
            id: "shared-track",
            title: "合法重合歌曲",
            artist: "歌手A"
        )
        let pending = MatchResult(
            importedSong: ImportedSong(
                title: track.title,
                source: .plainText,
                confidence: 1
            ),
            disposition: .identityConfirmationRequired(candidates: [track]),
            score: 0.8,
            reason: "待确认歌手"
        )
        let accepted = MatchResult(
            importedSong: ImportedSong(
                title: track.title,
                artist: track.artist,
                source: .plainText,
                confidence: 1
            ),
            disposition: .acceptedOriginalExact(track: track),
            score: 1,
            reason: "明确接受"
        )

        let matches = [pending, accepted]
        let scenario = ScenarioConfig(scenario: .friends, peopleCount: 4, durationMinutes: 30)
        let voice = VoiceProfile.simulatedMiddle
        let plan = try RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: makeProfile(),
            voiceProfile: voice,
            scenario: scenario,
            catalog: [track],
            generationContext: makeRecommendationGenerationContext(
                matches: matches,
                scenario: scenario,
                voiceProfile: voice
            ),
            inputSource: .userImport
        )
        let matchingItems = plan.sections
            .flatMap(\.items)
            .filter { $0.track.id == track.id }

        XCTAssertEqual(matchingItems.count, 1)
        XCTAssertEqual(matchingItems.first?.origin, .importedMatch)
    }

    func testPendingSemanticIdentityCannotReenterThroughDifferentCatalogIDOrLockedPath() throws {
        let pendingStyle = makeTrack(
            id: "pending-style",
            title: "待确认同歌异 ID",
            artist: "待确认歌手"
        )
        let catalogStyle = makeTrack(
            id: "catalog-style",
            title: pendingStyle.title,
            artist: pendingStyle.artist
        )
        let unadoptedPopular = makeTrack(
            id: "unadopted-popular",
            title: "未采用同歌异 ID",
            artist: "未采用歌手",
            genre: "独立类型",
            moodTags: [],
            singAlong: 0.2,
            sceneTags: []
        )
        let catalogPopular = makeTrack(
            id: "catalog-popular",
            title: unadoptedPopular.title,
            artist: unadoptedPopular.artist,
            genre: "独立类型",
            moodTags: [],
            singAlong: 0.9,
            sceneTags: []
        )
        let cases: [(name: String, candidate: KTVTrack, catalog: KTVTrack, disposition: SongMatchDisposition)] = [
            (
                "identity-confirmation-style",
                pendingStyle,
                catalogStyle,
                .identityConfirmationRequired(candidates: [pendingStyle])
            ),
            (
                "alternative-suggested-popular",
                unadoptedPopular,
                catalogPopular,
                .alternativeSuggested(candidates: [unadoptedPopular])
            )
        ]
        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 30)
        let voice = VoiceProfile.simulatedMiddle

        for testCase in cases {
            let match = MatchResult(
                importedSong: ImportedSong(
                    title: testCase.candidate.title,
                    artist: testCase.candidate.artist,
                    source: .plainText,
                    confidence: 1
                ),
                disposition: testCase.disposition,
                score: 0.8,
                reason: "待用户确认"
            )
            let matches = [match]
            let generationContext = makeRecommendationGenerationContext(
                matches: matches,
                scenario: scenario,
                voiceProfile: voice
            )
            let plan = try RecommendationEngine().generatePlan(
                matches: matches,
                preferenceProfile: makeProfile(),
                voiceProfile: voice,
                scenario: scenario,
                catalog: [testCase.catalog],
                generationContext: generationContext
            )

            XCTAssertFalse(
                plan.sections.flatMap(\.items).contains { $0.track.id == testCase.catalog.id },
                testCase.name
            )
            XCTAssertThrowsError(
                try RecommendationEngine().generatePlan(
                    matches: matches,
                    preferenceProfile: makeProfile(),
                    voiceProfile: voice,
                    scenario: scenario,
                    catalog: [testCase.catalog],
                    generationContext: generationContext,
                    lockedTrackIDs: [testCase.catalog.id]
                ),
                testCase.name
            ) { error in
                XCTAssertEqual(
                    error as? RecommendationGenerationError,
                    .lockedTrackUnavailable(trackIDs: [testCase.catalog.id]),
                    testCase.name
                )
            }
        }
    }

    func testPendingAndUnadoptedTracksCannotLeakThroughNestedAlternativesOrExports() throws {
        let pendingSameID = makeTrack(
            id: "pending-same-id",
            title: "待确认同 ID 备选",
            artist: "待确认歌手"
        )
        let pendingSemanticSource = makeTrack(
            id: "pending-semantic-source",
            title: "待确认同语义备选",
            artist: "待确认语义歌手"
        )
        let pendingSemanticCatalog = makeTrack(
            id: "pending-semantic-catalog",
            title: pendingSemanticSource.title,
            artist: pendingSemanticSource.artist
        )
        let unadoptedSameID = makeTrack(
            id: "unadopted-same-id",
            title: "未采用同 ID 备选",
            artist: "未采用歌手"
        )
        let unadoptedSemanticSource = makeTrack(
            id: "unadopted-semantic-source",
            title: "未采用同语义备选",
            artist: "未采用语义歌手"
        )
        let unadoptedSemanticCatalog = makeTrack(
            id: "unadopted-semantic-catalog",
            title: unadoptedSemanticSource.title,
            artist: unadoptedSemanticSource.artist
        )
        let cases: [(String, KTVTrack, KTVTrack, SongMatchDisposition)] = [
            (
                "pending-same-id",
                pendingSameID,
                pendingSameID,
                .identityConfirmationRequired(candidates: [pendingSameID])
            ),
            (
                "pending-semantic-id",
                pendingSemanticSource,
                pendingSemanticCatalog,
                .identityConfirmationRequired(candidates: [pendingSemanticSource])
            ),
            (
                "unadopted-same-id",
                unadoptedSameID,
                unadoptedSameID,
                .alternativeSuggested(candidates: [unadoptedSameID])
            ),
            (
                "unadopted-semantic-id",
                unadoptedSemanticSource,
                unadoptedSemanticCatalog,
                .alternativeSuggested(candidates: [unadoptedSemanticSource])
            )
        ]
        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 30)
        let voice = VoiceProfile.simulatedMiddle

        for (name, source, catalogTrack, disposition) in cases {
            let formalTrack = makeTrack(
                id: "formal-\(name)",
                title: "正式歌曲 \(name)",
                artist: "正式歌手 \(name)",
                similarSongIds: [catalogTrack.id]
            )
            let pending = MatchResult(
                importedSong: ImportedSong(
                    title: source.title,
                    artist: source.artist,
                    source: .plainText,
                    confidence: 1
                ),
                disposition: disposition,
                score: 0.8,
                reason: "待用户决定"
            )
            let matches = [match(formalTrack), pending]
            let plan = try RecommendationEngine().generatePlan(
                matches: matches,
                preferenceProfile: makeProfile(),
                voiceProfile: voice,
                scenario: scenario,
                catalog: [formalTrack, catalogTrack],
                generationContext: makeRecommendationGenerationContext(
                    matches: matches,
                    scenario: scenario,
                    voiceProfile: voice
                )
            )
            let formalItem = try XCTUnwrap(
                plan.sections.flatMap(\.items).first { $0.track.id == formalTrack.id }
            )
            let text = PlaylistTextExporter().export(plan: plan)
            let json = try PlaylistJSONExporter().export(plan: plan)

            XCTAssertFalse(
                formalItem.alternatives.contains { $0.id == catalogTrack.id },
                name
            )
            XCTAssertFalse(text.contains(catalogTrack.title), name)
            XCTAssertFalse(json.contains(catalogTrack.title), name)
        }
    }

    func testLegalGateCandidateRemainsAlternativeWithoutIncludingCurrentTrack() throws {
        let alternative = makeTrack(
            id: "legal-nested-alternative",
            title: "合法备选",
            artist: "合法备选歌手"
        )
        let formalTrack = makeTrack(
            id: "formal-with-self-reference",
            title: "正式歌曲",
            artist: "正式歌手",
            similarSongIds: ["formal-with-self-reference", alternative.id]
        )
        let matches = [match(formalTrack)]
        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 30)
        let voice = VoiceProfile.simulatedMiddle

        let plan = try RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: makeProfile(),
            voiceProfile: voice,
            scenario: scenario,
            catalog: [formalTrack, alternative],
            generationContext: makeRecommendationGenerationContext(
                matches: matches,
                scenario: scenario,
                voiceProfile: voice
            )
        )
        let item = try XCTUnwrap(
            plan.sections.flatMap(\.items).first { $0.track.id == formalTrack.id }
        )

        XCTAssertEqual(item.alternatives.map(\.id), [alternative.id])
    }

    func testPendingSemanticIdentityAllowsSingleAdoptedLegalSourceWithDifferentIDs() throws {
        let pending = makeTrack(
            id: "semantic-pending",
            title: "多路径合法歌曲",
            artist: "多路径歌手"
        )
        let catalog = makeTrack(
            id: "semantic-catalog",
            title: pending.title,
            artist: pending.artist
        )
        let accepted = makeTrack(
            id: "semantic-accepted",
            title: pending.title,
            artist: pending.artist
        )
        let adopted = makeTrack(
            id: "semantic-adopted",
            title: pending.title,
            artist: pending.artist
        )
        let matches = [
            MatchResult(
                importedSong: ImportedSong(
                    title: pending.title,
                    source: .plainText,
                    confidence: 1
                ),
                disposition: .identityConfirmationRequired(candidates: [pending]),
                score: 0.8,
                reason: "待确认"
            ),
            MatchResult(
                importedSong: ImportedSong(
                    title: accepted.title,
                    artist: accepted.artist,
                    source: .plainText,
                    confidence: 1
                ),
                disposition: .acceptedOriginalExact(track: accepted),
                score: 1,
                reason: "原曲命中"
            ),
            MatchResult(
                importedSong: ImportedSong(
                    title: "被替代歌曲",
                    artist: "被替代歌手",
                    source: .plainText,
                    confidence: 1
                ),
                disposition: .adoptedAlternative(track: adopted),
                score: 0.8,
                reason: "已采用替代"
            )
        ]
        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 30)
        let voice = VoiceProfile.simulatedMiddle

        let plan = try RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: makeProfile(),
            voiceProfile: voice,
            scenario: scenario,
            catalog: [catalog],
            generationContext: makeRecommendationGenerationContext(
                matches: matches,
                scenario: scenario,
                voiceProfile: voice
            )
        )
        let items = plan.sections.flatMap(\.items)

        XCTAssertEqual(items.map(\.track.id), [adopted.id])
        XCTAssertEqual(items.first?.origin, .adoptedAlternative)
    }

    func testPendingStudioIdentityDoesNotSuppressLiveAndRemixCatalogVersions() throws {
        let pendingStudio = makeTrack(
            id: "pending-studio",
            title: "版本边界歌曲",
            artist: "版本边界歌手"
        )
        let live = makeTrack(
            id: "catalog-live",
            title: "版本边界歌曲 Live",
            artist: pendingStudio.artist,
            versionTags: ["Live"]
        )
        let remix = makeTrack(
            id: "catalog-remix",
            title: "版本边界歌曲 Remix",
            artist: pendingStudio.artist,
            versionTags: ["Remix"]
        )
        let match = MatchResult(
            importedSong: ImportedSong(
                title: pendingStudio.title,
                artist: pendingStudio.artist,
                source: .plainText,
                confidence: 1
            ),
            disposition: .identityConfirmationRequired(candidates: [pendingStudio]),
            score: 0.8,
            reason: "待确认录音室版"
        )
        let matches = [match]
        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 30)
        let voice = VoiceProfile.simulatedMiddle

        let plan = try RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: makeProfile(),
            voiceProfile: voice,
            scenario: scenario,
            catalog: [live, remix],
            generationContext: makeRecommendationGenerationContext(
                matches: matches,
                scenario: scenario,
                voiceProfile: voice
            )
        )
        let items = plan.sections.flatMap(\.items)

        XCTAssertEqual(Set(items.map(\.track.id)), [live.id, remix.id])
        XCTAssertTrue(items.allSatisfy { $0.origin == .styleSupplement })
    }

    func testCandidateOriginsPreferAdoptedAlternativeOverImportedMatchForSameSongIdentity() throws {
        let imported = makeTrack(
            id: "same-song-imported",
            title: "同一首歌",
            artist: "同一歌手"
        )
        let adopted = makeTrack(
            id: "same-song-adopted",
            title: imported.title,
            artist: imported.artist
        )
        let importedMatch = MatchResult(
            importedSong: ImportedSong(
                title: imported.title,
                artist: imported.artist,
                source: .plainText,
                confidence: 1
            ),
            disposition: .acceptedOriginalExact(track: imported),
            score: 1,
            reason: "原曲命中"
        )
        let adoptedMatch = MatchResult(
            importedSong: ImportedSong(
                title: "原歌",
                artist: "原歌手",
                source: .plainText,
                confidence: 1
            ),
            disposition: .adoptedAlternative(track: adopted),
            score: 0.8,
            reason: "已采用替代"
        )

        let matches = [importedMatch, adoptedMatch]
        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 30)
        let voice = VoiceProfile.simulatedMiddle
        let plan = try RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: makeProfile(),
            voiceProfile: voice,
            scenario: scenario,
            catalog: [],
            generationContext: makeRecommendationGenerationContext(
                matches: matches,
                scenario: scenario,
                voiceProfile: voice
            )
        )
        let items = plan.sections.flatMap(\.items)

        XCTAssertEqual(items.map(\.track.id), [adopted.id])
        XCTAssertEqual(items.first?.origin, .adoptedAlternative)
    }

    func testCandidateSemanticDeduplicationKeepsStudioLiveAndRemixVersionsSeparate() throws {
        let tracks = [
            makeTrack(
                id: "version-studio",
                title: "版本歌曲",
                artist: "版本歌手"
            ),
            makeTrack(
                id: "version-live",
                title: "版本歌曲 Live",
                artist: "版本歌手",
                versionTags: ["Live"]
            ),
            makeTrack(
                id: "version-remix",
                title: "版本歌曲 Remix",
                artist: "版本歌手",
                versionTags: ["Remix"]
            )
        ]

        let matches = tracks.map(match)
        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 30)
        let voice = VoiceProfile.simulatedMiddle
        let plan = try RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: makeProfile(),
            voiceProfile: voice,
            scenario: scenario,
            catalog: [],
            generationContext: makeRecommendationGenerationContext(
                matches: matches,
                scenario: scenario,
                voiceProfile: voice
            )
        )
        let IDs = Set(plan.sections.flatMap(\.items).map(\.track.id))

        XCTAssertEqual(IDs, Set(tracks.map(\.id)))
        XCTAssertTrue(plan.sections.flatMap(\.items).allSatisfy { $0.origin == .importedMatch })
    }

    func testLockedLegalCandidatesKeepTheirSpecificOrigins() throws {
        let confirmed = makeTrack(
            id: "origin-confirmed",
            title: "已确认原曲",
            artist: "确认歌手"
        )
        let adopted = makeTrack(
            id: "origin-adopted",
            title: "采用替代",
            artist: "替代歌手"
        )
        let sameArtist = makeTrack(
            id: "origin-same-artist",
            title: "同歌手补充",
            artist: "歌手A"
        )
        let style = makeTrack(
            id: "origin-style",
            title: "风格补充",
            artist: "风格歌手"
        )
        let scene = makeTrack(
            id: "origin-scene",
            title: "场景补充",
            artist: "场景歌手",
            genre: "独立类型",
            moodTags: [],
            singAlong: 0.2,
            sceneTags: ["friends"]
        )
        let popular = makeTrack(
            id: "origin-popular",
            title: "热门补充",
            artist: "热门歌手",
            genre: "独立类型",
            moodTags: [],
            singAlong: 0.9,
            sceneTags: []
        )
        let matches = [
            MatchResult(
                importedSong: ImportedSong(
                    title: confirmed.title,
                    source: .plainText,
                    confidence: 1
                ),
                disposition: .acceptedOriginalConfirmed(track: confirmed),
                score: 1,
                reason: "已确认"
            ),
            MatchResult(
                importedSong: ImportedSong(
                    title: "被替代原歌",
                    artist: "原歌手",
                    source: .plainText,
                    confidence: 1
                ),
                disposition: .adoptedAlternative(track: adopted),
                score: 0.8,
                reason: "已采用"
            )
        ]
        let catalog = [confirmed, adopted, sameArtist, style, scene, popular]

        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 30)
        let voice = VoiceProfile.simulatedMiddle
        let plan = try RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: makeProfile(),
            voiceProfile: voice,
            scenario: scenario,
            catalog: catalog,
            generationContext: makeRecommendationGenerationContext(
                matches: matches,
                scenario: scenario,
                voiceProfile: voice
            ),
            lockedTrackIDs: Set(catalog.map(\.id))
        )
        let originByID = Dictionary(
            uniqueKeysWithValues: plan.sections.flatMap(\.items).map { ($0.track.id, $0.origin) }
        )

        XCTAssertEqual(originByID[confirmed.id], .importedMatch)
        XCTAssertEqual(originByID[adopted.id], .adoptedAlternative)
        XCTAssertEqual(originByID[sameArtist.id], .sameArtistSupplement)
        XCTAssertEqual(originByID[style.id], .styleSupplement)
        XCTAssertEqual(originByID[scene.id], .sceneSupplement)
        XCTAssertEqual(originByID[popular.id], .popularSupplement)
    }

    func testLockedSemanticDuplicateKeepsImportedOrigin() throws {
        let imported = makeTrack(
            id: "semantic-imported",
            title: "同一语义歌曲",
            artist: "同一语义歌手"
        )
        let lockedSupplement = makeTrack(
            id: "semantic-locked-supplement",
            title: imported.title,
            artist: imported.artist
        )
        let matches = [match(imported)]
        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 30)
        let voice = VoiceProfile.simulatedMiddle

        let plan = try RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: makeProfile(),
            voiceProfile: voice,
            scenario: scenario,
            catalog: [lockedSupplement],
            generationContext: makeRecommendationGenerationContext(
                matches: matches,
                scenario: scenario,
                voiceProfile: voice
            ),
            lockedTrackIDs: [lockedSupplement.id]
        )
        let items = plan.sections.flatMap(\.items)

        XCTAssertEqual(items.map(\.track.id), [lockedSupplement.id])
        XCTAssertEqual(items.first?.origin, .importedMatch)
        XCTAssertTrue(items.first?.isLocked == true)
    }

    func testLockedSemanticDuplicateKeepsAdoptedOriginRegardlessOfMatchOrder() throws {
        let imported = makeTrack(
            id: "semantic-order-imported",
            title: "同一语义顺序歌曲",
            artist: "同一语义顺序歌手"
        )
        let adopted = makeTrack(
            id: "semantic-order-adopted",
            title: imported.title,
            artist: imported.artist
        )
        let lockedSupplement = makeTrack(
            id: "semantic-order-locked",
            title: imported.title,
            artist: imported.artist
        )
        let importedMatch = match(imported)
        let adoptedMatch = MatchResult(
            importedSong: ImportedSong(
                title: "被替代顺序歌曲",
                artist: "被替代顺序歌手",
                source: .plainText,
                confidence: 1
            ),
            disposition: .adoptedAlternative(track: adopted),
            score: 0.8,
            reason: "已采用替代"
        )
        let matchOrders = [
            [importedMatch, adoptedMatch],
            [adoptedMatch, importedMatch]
        ]
        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 30)
        let voice = VoiceProfile.simulatedMiddle

        for (index, matches) in matchOrders.enumerated() {
            let plan = try RecommendationEngine().generatePlan(
                matches: matches,
                preferenceProfile: makeProfile(),
                voiceProfile: voice,
                scenario: scenario,
                catalog: [lockedSupplement],
                generationContext: makeRecommendationGenerationContext(
                    matches: matches,
                    scenario: scenario,
                    voiceProfile: voice
                ),
                lockedTrackIDs: [lockedSupplement.id]
            )
            let items = plan.sections.flatMap(\.items)

            XCTAssertEqual(items.map(\.track.id), [lockedSupplement.id], "顺序 \(index)")
            XCTAssertEqual(items.first?.origin, .adoptedAlternative, "顺序 \(index)")
            XCTAssertTrue(items.first?.isLocked == true, "顺序 \(index)")
        }
    }

    func testSupplementLimitIsStableAfterSemanticDeduplicationAndOriginOrdering() throws {
        let priorityTracks = (0..<5).map { index in
            makeTrack(
                id: "priority-\(index)",
                title: "zz-priority-\(index)",
                artist: "歌手A",
                genre: "独立类型",
                moodTags: [],
                singAlong: 0.2,
                sceneTags: []
            )
        }
        let styleTracks = (0..<95).map { index in
            makeTrack(
                id: String(format: "style-%03d", index),
                title: String(format: "aa-style-%03d", index),
                artist: "风格歌手 \(index)"
            )
        }
        let semanticDuplicates = (0..<3).map { index in
            makeTrack(
                id: "duplicate-\(index)",
                title: styleTracks[0].title,
                artist: styleTracks[0].artist
            )
        }
        let catalog = semanticDuplicates + styleTracks + priorityTracks
        let fixedShuffle = catalog.enumerated()
            .sorted {
                ($0.offset * 37) % catalog.count < ($1.offset * 37) % catalog.count
            }
            .map(\.element)
        let orders = [catalog, Array(catalog.reversed()), fixedShuffle]
        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 30)
        let signatures = try orders.map { order in
            try RecommendationCandidateGate().candidates(
                matches: [],
                preferenceProfile: makeProfile(),
                scenario: scenario,
                catalog: order,
                lockedTrackIDs: []
            ).map { "\($0.origin.rawValue)|\($0.track.id)" }
        }

        XCTAssertTrue(signatures.allSatisfy { $0.count == 90 })
        XCTAssertEqual(signatures[0], signatures[1])
        XCTAssertEqual(signatures[0], signatures[2])
        XCTAssertTrue(Set(priorityTracks.map(\.id)).isSubset(of: Set(signatures[0].map {
            String($0.split(separator: "|")[1])
        })))
    }

    func testLockedSupplementBypassesRegularSupplementLimitAfterStableSorting() throws {
        let regular = (0..<95).map { index in
            makeTrack(
                id: String(format: "regular-%03d", index),
                title: String(format: "regular-style-%03d", index),
                artist: "常规歌手 \(index)"
            )
        }
        let locked = makeTrack(
            id: "zz-locked-popular",
            title: "zz-locked-popular",
            artist: "锁定歌手",
            genre: "独立类型",
            moodTags: [],
            singAlong: 0.9,
            sceneTags: []
        )
        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 30)

        for catalog in [regular + [locked], [locked] + regular] {
            let candidates = try RecommendationCandidateGate().candidates(
                matches: [],
                preferenceProfile: makeProfile(),
                scenario: scenario,
                catalog: catalog,
                lockedTrackIDs: [locked.id]
            )

            XCTAssertEqual(candidates.count, 91)
            XCTAssertTrue(candidates.contains { $0.track.id == locked.id })
        }
    }

    func testAcceptedAndAdoptedCandidatesDoNotConsumeSupplementLimit() throws {
        let imported = makeTrack(
            id: "limit-imported",
            title: "限额已命中",
            artist: "命中歌手"
        )
        let adopted = makeTrack(
            id: "limit-adopted",
            title: "限额已采用",
            artist: "采用歌手"
        )
        let supplements = (0..<90).map { index in
            makeTrack(
                id: String(format: "limit-supplement-%03d", index),
                title: String(format: "limit-supplement-%03d", index),
                artist: "补充歌手 \(index)"
            )
        }
        let matches = [
            match(imported),
            MatchResult(
                importedSong: ImportedSong(
                    title: "待替代原歌",
                    artist: "待替代歌手",
                    source: .plainText,
                    confidence: 1
                ),
                disposition: .adoptedAlternative(track: adopted),
                score: 0.8,
                reason: "已采用"
            )
        ]

        let candidates = try RecommendationCandidateGate().candidates(
            matches: matches,
            preferenceProfile: makeProfile(),
            scenario: ScenarioConfig(scenario: .friends, durationMinutes: 30),
            catalog: [imported, adopted] + supplements,
            lockedTrackIDs: []
        )

        XCTAssertEqual(candidates.count, 92)
        XCTAssertEqual(candidates.filter { $0.origin == .importedMatch }.count, 1)
        XCTAssertEqual(candidates.filter { $0.origin == .adoptedAlternative }.count, 1)
        XCTAssertEqual(candidates.filter { $0.origin == .styleSupplement }.count, 90)
    }

    func testLockedTracksWithoutLegalLocalSourcesFailTogetherInStableOrder() {
        let pendingTrack = makeTrack(
            id: "z-pending",
            title: "待确认来源",
            artist: "待确认歌手",
            genre: "独立类型",
            moodTags: [],
            singAlong: 0.2,
            sceneTags: []
        )
        let alternativeTrack = makeTrack(
            id: "a-alternative",
            title: "未采用来源",
            artist: "替代歌手",
            genre: "独立类型",
            moodTags: [],
            singAlong: 0.2,
            sceneTags: []
        )
        let externalTrack = makeTrack(
            id: "m-external",
            title: "外部来源",
            artist: "外部歌手",
            genre: "独立类型",
            moodTags: [],
            singAlong: 0.2,
            sceneTags: [],
            catalogSource: .externalSimilar
        )
        let unsupportedLocalTrack = makeTrack(
            id: "b-unsupported-local",
            title: "无分类本地歌",
            artist: "无分类歌手",
            genre: "独立类型",
            moodTags: [],
            singAlong: 0.2,
            sceneTags: []
        )
        let matches = [
            MatchResult(
                importedSong: ImportedSong(title: pendingTrack.title, source: .plainText, confidence: 1),
                disposition: .identityConfirmationRequired(candidates: [pendingTrack]),
                score: 0.8,
                reason: "待确认"
            ),
            MatchResult(
                importedSong: ImportedSong(title: "未命中原歌", source: .plainText, confidence: 1),
                disposition: .alternativeSuggested(candidates: [alternativeTrack]),
                score: 0.6,
                reason: "未采用"
            ),
            MatchResult(
                importedSong: ImportedSong(
                    title: externalTrack.title,
                    artist: externalTrack.artist,
                    source: .plainText,
                    confidence: 1
                ),
                disposition: .acceptedOriginalExact(track: externalTrack),
                score: 1,
                reason: "旧外部命中"
            )
        ]
        let lockedIDs: Set<String> = [
            pendingTrack.id,
            alternativeTrack.id,
            externalTrack.id,
            unsupportedLocalTrack.id
        ]
        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 30)
        let voice = VoiceProfile.simulatedMiddle

        XCTAssertThrowsError(
            try RecommendationEngine().generatePlan(
                matches: matches,
                preferenceProfile: makeProfile(),
                voiceProfile: voice,
                scenario: scenario,
                catalog: [externalTrack, unsupportedLocalTrack],
                generationContext: makeRecommendationGenerationContext(
                    matches: matches,
                    scenario: scenario,
                    voiceProfile: voice
                ),
                lockedTrackIDs: lockedIDs
            )
        ) { error in
            XCTAssertTrue(error is RecommendationGenerationError)
            XCTAssertEqual(
                String(describing: error),
                "lockedTrackUnavailable(trackIDs: [\"a-alternative\", \"b-unsupported-local\", \"m-external\", \"z-pending\"])"
            )
        }
    }

    func testPendingAndUnmatchedUserImportsUseNeutralScenarioPlanSummary() throws {
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
        let voice = VoiceProfile.simulatedMiddle

        for testCase in cases {
            let profile = PreferenceProfiler().buildProfile(
                importedPlaylist: testCase.playlist,
                matches: testCase.matches
            )
            let plan = try RecommendationEngine().generatePlan(
                matches: testCase.matches,
                preferenceProfile: profile,
                voiceProfile: voice,
                scenario: scenario,
                catalog: [referenceTrack],
                generationContext: makeRecommendationGenerationContext(
                    matches: testCase.matches,
                    scenario: scenario,
                    voiceProfile: voice,
                    playlistTitle: testCase.playlist.title
                ),
                inputSource: .userImport
            )

            XCTAssertFalse(profile.hasReferenceInsights, testCase.name)
            XCTAssertEqual(plan.preferenceSummary, KTVScenario.friends.planSummary, testCase.name)
            XCTAssertFalse(plan.preferenceSummary?.contains("你平时听") == true, testCase.name)
            XCTAssertFalse(plan.preferenceSummary?.contains("流行歌偏多") == true, testCase.name)
            XCTAssertFalse(plan.preferenceSummary?.contains("熟悉旋律") == true, testCase.name)
        }
        XCTAssertTrue(
            PreferenceProfiler()
                .buildProfile(importedPlaylist: unmatchedPlaylist, matches: [unmatchedMatch])
                .topArtists.isEmpty
        )
    }

    func testPeopleCountChangesGroupRecommendationStrategy() throws {
        let catalog = [
            makeTrack(id: "solo", title: "想唱的歌", artist: "歌手A", difficulty: 5, singAlong: 0.45, highRisk: 0.62, sceneTags: ["friends"], energy: 0.82),
            makeTrack(id: "chorus1", title: "全员合唱一", artist: "歌手B", difficulty: 2, singAlong: 0.92, highRisk: 0.2, sceneTags: ["friends", "teamBuilding"], energy: 0.72),
            makeTrack(id: "chorus2", title: "全员合唱二", artist: "歌手C", difficulty: 2, singAlong: 0.9, highRisk: 0.2, sceneTags: ["friends", "teamBuilding"], energy: 0.7),
            makeTrack(id: "easy", title: "稳妥热身", artist: "歌手D", difficulty: 2, singAlong: 0.82, highRisk: 0.25, sceneTags: ["friends"], energy: 0.68)
        ]
        let matches = catalog.map(match)
        let profile = makeProfile()
        let voice = VoiceProfile.simulatedMiddle
        let smallScenario = ScenarioConfig(scenario: .friends, peopleCount: 2, durationMinutes: 45, difficultyPreference: .showcase)
        let largeScenario = ScenarioConfig(scenario: .friends, peopleCount: 10, durationMinutes: 45, difficultyPreference: .showcase)

        let smallPlan = try RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: profile,
            voiceProfile: voice,
            scenario: smallScenario,
            catalog: catalog,
            generationContext: makeRecommendationGenerationContext(
                matches: matches,
                scenario: smallScenario,
                voiceProfile: voice
            )
        )
        let largePlan = try RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: profile,
            voiceProfile: voice,
            scenario: largeScenario,
            catalog: catalog,
            generationContext: makeRecommendationGenerationContext(
                matches: matches,
                scenario: largeScenario,
                voiceProfile: voice
            )
        )

        let smallItems = smallPlan.sections.flatMap(\.items)
        let largeItems = largePlan.sections.flatMap(\.items)
        let smallChorusRatio = Double(smallItems.filter { $0.track.singAlongScore >= 0.78 }.count) / Double(max(smallItems.count, 1))
        let largeChorusRatio = Double(largeItems.filter { $0.track.singAlongScore >= 0.78 }.count) / Double(max(largeItems.count, 1))

        XCTAssertGreaterThanOrEqual(largeChorusRatio, smallChorusRatio)
        XCTAssertFalse(largeItems.first?.track.id == "solo")
    }

    func testFeedbackChangesRegeneratedRecommendation() throws {
        let catalog = [
            makeTrack(id: "safe", title: "稳妥歌", artist: "歌手A", difficulty: 2, singAlong: 0.86, highRisk: 0.2, sceneTags: ["friends"], energy: 0.7),
            makeTrack(id: "high", title: "高音歌", artist: "歌手B", difficulty: 4, singAlong: 0.8, highRisk: 0.75, sceneTags: ["friends"], energy: 0.82)
        ]
        let matches = catalog.map(match)
        let feedback = SongFeedbackProfile(feedbackByTrackID: [
            "safe": [.liked],
            "high": [.tooHigh, .unfamiliar]
        ])
        let scenario = ScenarioConfig(scenario: .friends, peopleCount: 4, durationMinutes: 45)
        let voice = VoiceProfile.simulatedMiddle

        let plan = try RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: makeProfile(),
            voiceProfile: voice,
            scenario: scenario,
            catalog: catalog,
            generationContext: makeRecommendationGenerationContext(
                matches: matches,
                scenario: scenario,
                voiceProfile: voice,
                feedbackProfile: feedback
            ),
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

    func testExampleAndPopularFallbackPlansDoNotClaimPlaylistOrVoicePersonalization() throws {
        let track = makeTrack(id: "safe", title: "稳妥歌", artist: "歌手A", difficulty: 2, singAlong: 0.86, highRisk: 0.2, highMidi: 65)
        let match = match(track)
        let scenario = ScenarioConfig(scenario: .friends, peopleCount: 4, durationMinutes: 45)
        let voice = VoiceProfile.simulatedMiddle

        for inputSource in [RecommendationInputSource.example, .popularFallback] {
            let plan = try RecommendationEngine().generatePlan(
                matches: [match],
                preferenceProfile: makeProfile(),
                voiceProfile: voice,
                scenario: scenario,
                catalog: [track],
                generationContext: makeRecommendationGenerationContext(
                    matches: [match],
                    scenario: scenario,
                    voiceProfile: voice
                ),
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

    func testUserImportAndMeasuredVoiceCanProduceSourceGroundedReasons() throws {
        let track = makeTrack(id: "safe", title: "稳妥歌", artist: "歌手A", difficulty: 2, singAlong: 0.7, highRisk: 0.2, highMidi: 65)
        let matches = [match(track)]
        let voice = makeMeasuredVoice()
        let scenario = ScenarioConfig(scenario: .friends, peopleCount: 4, durationMinutes: 45)

        let plan = try RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: makeProfile(),
            voiceProfile: voice,
            scenario: scenario,
            catalog: [track],
            generationContext: makeRecommendationGenerationContext(
                matches: matches,
                scenario: scenario,
                voiceProfile: voice
            ),
            inputSource: .userImport
        )

        let reasons = plan.sections.flatMap(\.items).flatMap(\.reasons)
        XCTAssertTrue(reasons.contains("你歌单里本来就有这位歌手"))
        XCTAssertTrue(reasons.contains("本次唱到的音区与歌曲接近"))
    }

    func testPublicRecommendationAPIsDefaultOmittedSourcesToLegacyUnknown() throws {
        let track = makeTrack(id: "safe", title: "稳妥歌", artist: "歌手A", difficulty: 2, singAlong: 0.7, highRisk: 0.2, highMidi: 65)
        let profile = makeProfile()
        let voice = makeMeasuredVoice()
        let scenario = ScenarioConfig(scenario: .friends, peopleCount: 4, durationMinutes: 45)
        let matches = [match(track)]
        let enginePlan = try RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: profile,
            voiceProfile: voice,
            scenario: scenario,
            catalog: [track],
            generationContext: makeRecommendationGenerationContext(
                matches: matches,
                scenario: scenario,
                voiceProfile: voice
            )
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

    func testSongRecommendationOriginsRoundTripWithStableDisplayNames() throws {
        let expectations: [(origin: SongRecommendationOrigin, displayName: String)] = [
            (.importedMatch, "来自导入歌单"),
            (.adoptedAlternative, "你采用的替代"),
            (.sameArtistSupplement, "同歌手补充"),
            (.styleSupplement, "风格补充"),
            (.sceneSupplement, "场景补充"),
            (.popularSupplement, "热门补充"),
            (.legacyUnknown, "历史排歌")
        ]
        let origins = expectations.map(\.origin)

        let decoded = try JSONDecoder().decode(
            [SongRecommendationOrigin].self,
            from: JSONEncoder().encode(origins)
        )

        XCTAssertEqual(SongRecommendationOrigin.allCases, origins)
        XCTAssertEqual(decoded, origins)
        XCTAssertEqual(expectations.map { $0.origin.displayName }, expectations.map(\.displayName))
    }

    func testSongPlanGenerationSummaryDerivesAllFieldsFromContextAndFinalItems() throws {
        let playlistID = UUID(uuidString: "E6C74E68-5A71-4C45-93A5-CDF8BC4281D4")!
        let context = makeGenerationContext(
            playlistID: playlistID,
            playlistTitle: "周末朋友局",
            importedSongCount: 9,
            verifiedSongCount: 6,
            pendingSongCount: 2,
            unmatchedSongCount: 1,
            scenario: .birthday,
            peopleCount: 7,
            durationMinutes: 90,
            voiceSource: .measured,
            feedbackCount: 3
        )
        let items = [
            makePlanItem(id: "imported-1", origin: .importedMatch),
            makePlanItem(id: "imported-2", origin: .importedMatch),
            makePlanItem(id: "alternative", origin: .adoptedAlternative),
            makePlanItem(id: "same-artist", origin: .sameArtistSupplement),
            makePlanItem(id: "style", origin: .styleSupplement),
            makePlanItem(id: "scene", origin: .sceneSupplement),
            makePlanItem(id: "popular", origin: .popularSupplement)
        ]

        let summary = try SongPlanGenerationSummary(context: context, items: items)

        XCTAssertEqual(summary.playlistID, playlistID)
        XCTAssertEqual(summary.playlistTitle, "周末朋友局")
        XCTAssertEqual(summary.importedSongCount, 9)
        XCTAssertEqual(summary.verifiedSongCount, 6)
        XCTAssertEqual(summary.pendingSongCount, 2)
        XCTAssertEqual(summary.unmatchedSongCount, 1)
        XCTAssertEqual(summary.formalPlanCount, 7)
        XCTAssertEqual(summary.importedMatchCount, 2)
        XCTAssertEqual(summary.adoptedAlternativeCount, 1)
        XCTAssertEqual(summary.supplementCount, 4)
        XCTAssertEqual(summary.scenario, .birthday)
        XCTAssertEqual(summary.peopleCount, 7)
        XCTAssertEqual(summary.durationMinutes, 90)
        XCTAssertEqual(summary.voiceSource, .measured)
        XCTAssertEqual(summary.feedbackCount, 3)
        XCTAssertEqual(
            try JSONDecoder().decode(
                SongPlanGenerationSummary.self,
                from: JSONEncoder().encode(summary)
            ),
            summary
        )
    }

    func testSongPlanGenerationSummaryRejectsCorruptedCodableCounts() throws {
        let item = makePlanItem(id: "imported", origin: .importedMatch)
        let summary = try SongPlanGenerationSummary(
            context: makeGenerationContext(importedSongCount: 1, verifiedSongCount: 1),
            items: [item]
        )
        let encoded = try JSONEncoder().encode(summary)
        let validObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let corruptions: [(key: String, value: Int)] = [
            ("formalPlanCount", 2),
            ("feedbackCount", -1)
        ]

        for corruption in corruptions {
            var object = validObject
            object[corruption.key] = corruption.value
            let data = try JSONSerialization.data(withJSONObject: object)

            XCTAssertThrowsError(try JSONDecoder().decode(SongPlanGenerationSummary.self, from: data)) { error in
                guard case RecommendationGenerationError.countMismatch = error else {
                    return XCTFail("损坏摘要应抛出 countMismatch，实际为：\(error)")
                }
            }
        }
    }

    func testSongPlanGenerationSummaryRejectsOverflowingCodableCounts() {
        let json = """
        {
          "playlistID": "99E02A68-1176-4B77-AD8F-1D5AB225E3CA",
          "playlistTitle": "损坏摘要",
          "importedSongCount": 0,
          "verifiedSongCount": 0,
          "pendingSongCount": 0,
          "unmatchedSongCount": 0,
          "formalPlanCount": \(Int.max),
          "importedMatchCount": \(Int.max),
          "adoptedAlternativeCount": \(Int.max),
          "supplementCount": \(Int.max),
          "scenario": "friends",
          "peopleCount": 4,
          "durationMinutes": 60,
          "voiceSource": "commonReference",
          "feedbackCount": 0
        }
        """

        XCTAssertThrowsError(
            try JSONDecoder().decode(SongPlanGenerationSummary.self, from: Data(json.utf8))
        ) { error in
            guard case RecommendationGenerationError.countMismatch = error else {
                return XCTFail("溢出摘要应抛出 countMismatch，实际为：\(error)")
            }
        }
    }

    func testSongPlanGenerationSummaryRejectsNegativeContextValues() {
        let invalidContexts = [
            makeGenerationContext(importedSongCount: -1),
            makeGenerationContext(verifiedSongCount: -1),
            makeGenerationContext(pendingSongCount: -1),
            makeGenerationContext(unmatchedSongCount: -1),
            makeGenerationContext(peopleCount: -1),
            makeGenerationContext(durationMinutes: -1),
            makeGenerationContext(feedbackCount: -1)
        ]

        for context in invalidContexts {
            XCTAssertThrowsError(try SongPlanGenerationSummary(context: context, items: [])) { error in
                guard case RecommendationGenerationError.countMismatch = error else {
                    return XCTFail("负数上下文应抛出 countMismatch，实际为：\(error)")
                }
            }
        }
    }

    func testSongPlanGenerationSummaryRejectsUnclassifiedFormalItem() {
        let legacyItem = makePlanItem(id: "legacy", origin: .legacyUnknown)

        XCTAssertThrowsError(
            try SongPlanGenerationSummary(context: makeGenerationContext(), items: [legacyItem])
        ) { error in
            guard case RecommendationGenerationError.countMismatch = error else {
                return XCTFail("未分类正式条目应抛出 countMismatch，实际为：\(error)")
            }
        }
    }

    func testSongPlanRoundTripAndTrustBoundaryPreserveSummaryAndOrigins() throws {
        let item = makePlanItem(id: "imported", origin: .importedMatch)
        let summary = try SongPlanGenerationSummary(
            context: makeGenerationContext(importedSongCount: 1, verifiedSongCount: 1),
            items: [item]
        )
        let plan = SongPlan(
            title: "正式排歌",
            scenario: .friends,
            generationSummary: summary,
            sections: [SongPlanSection(title: "开场", goal: "热身", items: [item])]
        )

        let decoded = try JSONDecoder().decode(SongPlan.self, from: JSONEncoder().encode(plan))
        let sanitized = decoded.sanitizedForTrustBoundaries()

        XCTAssertEqual(decoded.generationSummary, summary)
        XCTAssertEqual(decoded.sections.flatMap(\.items).map(\.origin), [.importedMatch])
        XCTAssertEqual(sanitized.generationSummary, summary)
        XCTAssertEqual(sanitized.sections.flatMap(\.items).map(\.origin), [.importedMatch])
    }

    func testSongPlanDecodingRejectsNonzeroSummaryWhenFinalSectionsAreEmpty() throws {
        let item = makePlanItem(id: "imported", origin: .importedMatch)
        let summary = try SongPlanGenerationSummary(
            context: makeGenerationContext(importedSongCount: 1, verifiedSongCount: 1),
            items: [item]
        )
        let plan = SongPlan(
            title: "空计划",
            scenario: .friends,
            generationSummary: summary,
            sections: []
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(SongPlan.self, from: JSONEncoder().encode(plan))
        ) { error in
            guard case RecommendationGenerationError.countMismatch = error else {
                return XCTFail("空计划与非零摘要不一致时应抛出 countMismatch，实际为：\(error)")
            }
        }
    }

    func testSongPlanDecodingRejectsSummaryOriginDistributionMismatch() throws {
        let summarizedItem = makePlanItem(id: "imported", origin: .importedMatch)
        let actualItem = makePlanItem(id: "alternative", origin: .adoptedAlternative)
        let summary = try SongPlanGenerationSummary(
            context: makeGenerationContext(importedSongCount: 1, verifiedSongCount: 1),
            items: [summarizedItem]
        )
        let plan = SongPlan(
            title: "来源不一致计划",
            scenario: .friends,
            generationSummary: summary,
            sections: [SongPlanSection(title: "开场", goal: "热身", items: [actualItem])]
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(SongPlan.self, from: JSONEncoder().encode(plan))
        ) { error in
            guard case RecommendationGenerationError.countMismatch = error else {
                return XCTFail("条目来源与摘要不一致时应抛出 countMismatch，实际为：\(error)")
            }
        }
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
        XCTAssertEqual(item.origin, .legacyUnknown)
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

    func testExternalCandidateCountRemainsIndependentFromFormalPlanCount() throws {
        let formalItems = [
            makePlanItem(id: "formal-1", origin: .importedMatch),
            makePlanItem(id: "formal-2", origin: .styleSupplement)
        ]
        let summary = try SongPlanGenerationSummary(
            context: makeGenerationContext(importedSongCount: 1, verifiedSongCount: 1),
            items: formalItems
        )
        let externalCandidates = ExternalCandidateCollection(
            basis: ExternalCandidateBasis(
                playlistID: summary.playlistID,
                reviewRevision: 2,
                requestRevision: 3
            ),
            candidates: [
                ExternalSongCandidate(title: "公开候选一", artist: "歌手甲", source: .iTunes, confidence: 0.9),
                ExternalSongCandidate(title: "公开候选二", artist: "歌手乙", source: .lastFM, confidence: 0.8)
            ]
        )

        XCTAssertEqual(summary.formalPlanCount, formalItems.count)
        XCTAssertEqual(externalCandidates.count, 2)
        XCTAssertTrue(formalItems.allSatisfy { !$0.track.title.hasPrefix("公开候选") })
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

    private func makeGenerationContext(
        playlistID: UUID = UUID(uuidString: "73E3BE1C-7FB1-4A60-9C95-F8C57DF1741B")!,
        playlistTitle: String = "测试歌单",
        importedSongCount: Int = 0,
        verifiedSongCount: Int = 0,
        pendingSongCount: Int = 0,
        unmatchedSongCount: Int = 0,
        scenario: KTVScenario = .friends,
        peopleCount: Int = 4,
        durationMinutes: Int = 60,
        voiceSource: VoiceProfileSource = .commonReference,
        feedbackCount: Int = 0
    ) -> SongPlanGenerationContext {
        SongPlanGenerationContext(
            playlistID: playlistID,
            playlistTitle: playlistTitle,
            importedSongCount: importedSongCount,
            verifiedSongCount: verifiedSongCount,
            pendingSongCount: pendingSongCount,
            unmatchedSongCount: unmatchedSongCount,
            scenario: scenario,
            peopleCount: peopleCount,
            durationMinutes: durationMinutes,
            voiceSource: voiceSource,
            feedbackCount: feedbackCount
        )
    }

    private func makePlanItem(id: String, origin: SongRecommendationOrigin) -> SongPlanItem {
        SongPlanItem(
            track: makeTrack(id: id, title: "测试歌曲 \(id)", artist: "测试歌手"),
            origin: origin,
            score: 0.8,
            reasons: ["测试理由"],
            riskWarnings: [],
            alternatives: []
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

    private func assertAcceptedOriginalConfirmed(
        _ result: MatchResult,
        trackID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .acceptedOriginalConfirmed(track) = result.disposition else {
            return XCTFail("应进入已确认原曲状态", file: file, line: line)
        }
        XCTAssertEqual(track.id, trackID, file: file, line: line)
    }

    private func assertAdoptedAlternative(
        _ result: MatchResult,
        trackID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .adoptedAlternative(track) = result.disposition else {
            return XCTFail("应进入已采用替代状态", file: file, line: line)
        }
        XCTAssertEqual(track.id, trackID, file: file, line: line)
    }

    private func makeTrack(
        id: String,
        title: String,
        artist: String,
        genre: String = "华语流行",
        moodTags: [String] = ["相似推荐"],
        difficulty: Int = 3,
        singAlong: Double = 0.8,
        highRisk: Double = 0.4,
        sceneTags: [String] = ["friends"],
        energy: Double = 0.7,
        highMidi: Int = 69,
        versionTags: [String] = [],
        similarSongIds: [String] = [],
        externalURL: URL? = nil,
        catalogSource: TrackCatalogSource = .ktvCatalog
    ) -> KTVTrack {
        KTVTrack(
            id: id,
            title: title,
            artist: artist,
            language: "Mandarin",
            era: "2000s",
            genre: genre,
            moodTags: moodTags,
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
            versionTags: versionTags,
            similarSongIds: similarSongIds,
            externalURL: externalURL,
            catalogSource: catalogSource,
            confidenceNote: catalogSource == .externalSimilar ? "相近备选，到店里可能还要搜一下" : nil
        )
    }
}
