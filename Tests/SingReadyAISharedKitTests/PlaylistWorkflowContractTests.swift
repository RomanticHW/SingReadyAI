import XCTest
@testable import SingReadyAISharedKit

final class PlaylistWorkflowContractTests: XCTestCase {
    func testRevisionLedgerAndBasesRoundTripThroughCodable() throws {
        let playlistID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let ledger = WorkflowRevisionLedger(
            review: 3,
            match: 5,
            feedback: 7,
            trackControls: 9
        )
        let matchBasis = MatchBasis(
            playlistID: playlistID,
            reviewRevision: ledger.review,
            catalogRevision: "catalog-v1"
        )
        let planBasis = PlanBasis(
            matchBasis: matchBasis,
            matchRevision: ledger.match,
            scenarioFingerprint: "scenario-v1",
            voiceSource: .measured,
            voiceFingerprint: "voice-v1",
            feedbackRevision: ledger.feedback,
            trackControlsRevision: ledger.trackControls,
            catalogRevision: "catalog-v1"
        )
        let payload = BasisPayload(ledger: ledger, match: matchBasis, plan: planBasis)

        let restored = try JSONDecoder().decode(
            BasisPayload.self,
            from: JSONEncoder().encode(payload)
        )

        XCTAssertEqual(restored, payload)
    }

    func testReviewAndCatalogChangesRejectOldMatchAndPlan() {
        let playlistID = UUID()
        let matchBasis = MatchBasis(
            playlistID: playlistID,
            reviewRevision: 4,
            catalogRevision: "catalog-a"
        )
        let planBasis = makePlanBasis(matchBasis: matchBasis)
        let changedReview = MatchBasis(
            playlistID: playlistID,
            reviewRevision: 5,
            catalogRevision: "catalog-a"
        )
        let changedCatalog = MatchBasis(
            playlistID: playlistID,
            reviewRevision: 4,
            catalogRevision: "catalog-b"
        )

        XCTAssertFalse(PlaylistWorkflowValidityPolicy.accepts(
            matchBasis: matchBasis,
            current: changedReview
        ))
        XCTAssertFalse(PlaylistWorkflowValidityPolicy.accepts(
            planBasis: planBasis,
            current: makePlanBasis(matchBasis: changedReview)
        ))
        XCTAssertFalse(PlaylistWorkflowValidityPolicy.accepts(
            matchBasis: matchBasis,
            current: changedCatalog
        ))
        XCTAssertFalse(PlaylistWorkflowValidityPolicy.accepts(
            planBasis: planBasis,
            current: makePlanBasis(
                matchBasis: changedCatalog,
                catalogRevision: "catalog-b"
            )
        ))
    }

    func testPlanOnlyInputsInvalidatePlanWithoutInvalidatingMatch() {
        let matchBasis = MatchBasis(
            playlistID: UUID(),
            reviewRevision: 2,
            catalogRevision: "catalog-a"
        )
        let baseline = makePlanBasis(matchBasis: matchBasis)
        let changedPlanBases = [
            makePlanBasis(matchBasis: matchBasis, matchRevision: 9),
            makePlanBasis(matchBasis: matchBasis, scenarioFingerprint: "scenario-b"),
            makePlanBasis(matchBasis: matchBasis, voiceSource: .commonReference),
            makePlanBasis(matchBasis: matchBasis, voiceFingerprint: "voice-b"),
            makePlanBasis(matchBasis: matchBasis, feedbackRevision: 6),
            makePlanBasis(matchBasis: matchBasis, trackControlsRevision: 8)
        ]

        XCTAssertTrue(PlaylistWorkflowValidityPolicy.accepts(
            matchBasis: matchBasis,
            current: matchBasis
        ))
        for current in changedPlanBases {
            XCTAssertFalse(PlaylistWorkflowValidityPolicy.accepts(
                planBasis: baseline,
                current: current
            ))
            XCTAssertTrue(PlaylistWorkflowValidityPolicy.accepts(
                matchBasis: matchBasis,
                current: current.matchBasis
            ))
        }
    }

    func testExternalCandidateChangesDoNotParticipateInPlanBasis() {
        let playlistID = UUID()
        let matchBasis = MatchBasis(
            playlistID: playlistID,
            reviewRevision: 2,
            catalogRevision: "catalog-a"
        )
        let planBeforeSearch = makePlanBasis(matchBasis: matchBasis)
        let firstCandidates = ExternalCandidateCollection(
            basis: ExternalCandidateBasis(
                playlistID: playlistID,
                reviewRevision: 2,
                requestRevision: 1
            ),
            candidates: [
                ExternalSongCandidate(
                    title: "公开候选甲",
                    artist: "歌手甲",
                    source: .iTunes,
                    confidence: 0.8
                )
            ]
        )
        let secondCandidates = ExternalCandidateCollection(
            basis: ExternalCandidateBasis(
                playlistID: playlistID,
                reviewRevision: 2,
                requestRevision: 2
            ),
            candidates: [
                ExternalSongCandidate(
                    title: "公开候选乙",
                    artist: "歌手乙",
                    source: .musicBrainz,
                    confidence: 0.9
                )
            ]
        )
        let planAfterSearch = makePlanBasis(matchBasis: matchBasis)

        XCTAssertNotEqual(firstCandidates, secondCandidates)
        XCTAssertEqual(planAfterSearch, planBeforeSearch)
        XCTAssertTrue(PlaylistWorkflowValidityPolicy.accepts(
            planBasis: planBeforeSearch,
            current: planAfterSearch
        ))
    }

    func testCatalogFingerprintIsStableAndIgnoresPublicCandidates() {
        let studio = makeTrack(id: "studio", title: "后来", artist: "刘若英")
        let live = makeTrack(
            id: "live",
            title: "后来 Live",
            artist: "刘若英",
            versionTags: ["Live"]
        )
        let publicCandidate = makeTrack(
            id: "external",
            title: "公开候选",
            artist: "公开歌手",
            catalogSource: .externalSimilar
        )

        let ordered = PlaylistWorkflowFingerprint.catalogRevision(for: [studio, live])
        let reversed = PlaylistWorkflowFingerprint.catalogRevision(for: [live, studio])
        let withPublicCandidate = PlaylistWorkflowFingerprint.catalogRevision(
            for: [publicCandidate, live, studio]
        )
        let changedVersion = PlaylistWorkflowFingerprint.catalogRevision(
            for: [
                studio,
                makeTrack(
                    id: "live",
                    title: "后来 Remix",
                    artist: "刘若英",
                    versionTags: ["Remix"]
                )
            ]
        )

        XCTAssertEqual(ordered, reversed)
        XCTAssertEqual(ordered, withPublicCandidate)
        XCTAssertNotEqual(ordered, changedVersion)
        XCTAssertTrue(ordered.hasPrefix("catalog-v1-"))
    }

    func testScenarioAndVoiceFingerprintsTrackEffectiveInputs() {
        let scenario = ScenarioConfig(
            scenario: .friends,
            peopleCount: 6,
            durationMinutes: 90,
            vibe: .energetic,
            chorusPreference: .moreChorus,
            difficultyPreference: .balanced
        )
        var changedScenario = scenario
        changedScenario.durationMinutes = 120
        let measuredVoice = makeVoiceProfile(source: .measured, stableHighMidi: 67)
        let sameRangeReference = makeVoiceProfile(
            source: .commonReference,
            stableHighMidi: 67,
            createdAt: Date(timeIntervalSince1970: 500)
        )
        let changedRange = makeVoiceProfile(source: .measured, stableHighMidi: 69)

        XCTAssertEqual(
            PlaylistWorkflowFingerprint.scenario(for: scenario),
            PlaylistWorkflowFingerprint.scenario(for: scenario)
        )
        XCTAssertNotEqual(
            PlaylistWorkflowFingerprint.scenario(for: scenario),
            PlaylistWorkflowFingerprint.scenario(for: changedScenario)
        )
        XCTAssertEqual(
            PlaylistWorkflowFingerprint.voice(for: measuredVoice),
            PlaylistWorkflowFingerprint.voice(for: sameRangeReference)
        )
        XCTAssertNotEqual(
            PlaylistWorkflowFingerprint.voice(for: measuredVoice),
            PlaylistWorkflowFingerprint.voice(for: changedRange)
        )

        let matchBasis = MatchBasis(
            playlistID: UUID(),
            reviewRevision: 1,
            catalogRevision: "catalog-a"
        )
        let measuredPlan = makePlanBasis(
            matchBasis: matchBasis,
            voiceSource: measuredVoice.source,
            voiceFingerprint: PlaylistWorkflowFingerprint.voice(for: measuredVoice)
        )
        let referencePlan = makePlanBasis(
            matchBasis: matchBasis,
            voiceSource: sameRangeReference.source,
            voiceFingerprint: PlaylistWorkflowFingerprint.voice(for: sameRangeReference)
        )

        XCTAssertNotEqual(measuredPlan, referencePlan)
    }

    func testRestoredMatchStateOnlyAcceptsCompleteAnalysisWithEqualBasis() throws {
        let song = ImportedSong(
            title: "晴天",
            artist: "周杰伦",
            source: .plainText,
            confidence: 1
        )
        let basis = MatchBasis(
            playlistID: UUID(),
            reviewRevision: 3,
            catalogRevision: "catalog-a"
        )
        let analysis = CompletedPlaylistAnalysis(
            basis: basis,
            matchRevision: 4,
            matches: [
                MatchResult(
                    importedSong: song,
                    disposition: .acceptedOriginalExact(
                        track: makeTrack(id: "sunny", title: "晴天", artist: "周杰伦")
                    ),
                    score: 1,
                    reason: "已核对"
                )
            ],
            preferenceProfile: makePreferenceProfile()
        )
        let restored = try JSONDecoder().decode(
            CompletedPlaylistAnalysis.self,
            from: JSONEncoder().encode(analysis)
        )
        let changedReview = MatchBasis(
            playlistID: basis.playlistID,
            reviewRevision: 4,
            catalogRevision: basis.catalogRevision
        )

        XCTAssertEqual(restored.basis, basis)
        XCTAssertEqual(restored.matchRevision, 4)
        XCTAssertEqual(restored.matches.count, 1)
        XCTAssertEqual(
            PlaylistWorkflowValidityPolicy.restoredMatchState(
                persistedAnalysis: restored,
                currentBasis: basis
            ),
            .ready(basis)
        )
        XCTAssertEqual(
            PlaylistWorkflowValidityPolicy.restoredMatchState(
                persistedAnalysis: restored,
                currentBasis: changedReview
            ),
            .notStarted
        )
        XCTAssertEqual(
            PlaylistWorkflowValidityPolicy.restoredMatchState(
                persistedAnalysis: nil,
                currentBasis: basis
            ),
            .notStarted
        )
    }

    func testPreparationSummaryDerivesCountsFromOneCompleteAnalysis() throws {
        let songs = [
            makeImportedSong(title: "已核对", artist: "歌手甲"),
            makeImportedSong(title: "待确认", artist: "歌手乙"),
            makeImportedSong(title: "暂未找到", artist: "歌手丙"),
            makeImportedSong(title: "整理时删除", artist: "歌手丁")
        ]
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "准备摘要",
            songs: songs,
            parseConfidence: 1
        )
        let reviewSongs = [
            WorkflowReviewSong(song: songs[0], title: "已核对（整理后）"),
            WorkflowReviewSong(song: songs[1]),
            WorkflowReviewSong(song: songs[2]),
            WorkflowReviewSong(song: songs[3], isDeleted: true)
        ]
        let activeSongs = reviewSongs.filter { !$0.isDeleted }.map(\.importedSong)
        let basis = MatchBasis(
            playlistID: playlist.id,
            reviewRevision: 6,
            catalogRevision: "catalog-a"
        )
        let analysis = CompletedPlaylistAnalysis(
            basis: basis,
            matchRevision: 7,
            matches: [
                MatchResult(
                    importedSong: activeSongs[0],
                    disposition: .acceptedOriginalConfirmed(
                        track: makeTrack(id: "verified", title: "已核对（整理后）", artist: "歌手甲")
                    ),
                    score: 0.95,
                    reason: "已确认"
                ),
                MatchResult(
                    importedSong: activeSongs[1],
                    disposition: .identityConfirmationRequired(
                        candidates: [makeTrack(id: "pending", title: "待确认", artist: "歌手乙")]
                    ),
                    score: 0.75,
                    reason: "待确认"
                ),
                MatchResult(
                    importedSong: activeSongs[2],
                    disposition: .unmatched,
                    score: 0,
                    reason: "暂未找到"
                )
            ],
            preferenceProfile: makePreferenceProfile()
        )

        let summary = try XCTUnwrap(PlaylistPreparationSummary(
            playlist: playlist,
            reviewSongs: reviewSongs,
            analysis: analysis
        ))

        XCTAssertEqual(summary.importedCount, 4)
        XCTAssertEqual(summary.validReviewedCount, 3)
        XCTAssertEqual(summary.verifiedCount, 1)
        XCTAssertEqual(summary.pendingCount, 1)
        XCTAssertEqual(summary.unmatchedCount, 1)
        XCTAssertTrue(summary.canContinue)
    }

    func testPreparationSummaryRejectsIncompleteOrStaleInputs() {
        let first = makeImportedSong(title: "歌曲甲", artist: "歌手甲")
        let second = makeImportedSong(title: "歌曲乙", artist: "歌手乙")
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "完整性",
            songs: [first, second],
            parseConfidence: 1
        )
        let reviewSongs = [WorkflowReviewSong(song: first), WorkflowReviewSong(song: second)]
        let basis = MatchBasis(
            playlistID: playlist.id,
            reviewRevision: 2,
            catalogRevision: "catalog-a"
        )
        let incomplete = CompletedPlaylistAnalysis(
            basis: basis,
            matchRevision: 3,
            matches: [
                MatchResult(
                    importedSong: first,
                    disposition: .unmatched,
                    score: 0,
                    reason: "暂未找到"
                )
            ],
            preferenceProfile: makePreferenceProfile()
        )
        let staleSong = ImportedSong(
            id: first.id,
            title: "旧歌名",
            artist: first.artist,
            source: first.source,
            confidence: first.confidence
        )
        let stale = CompletedPlaylistAnalysis(
            basis: basis,
            matchRevision: 3,
            matches: [
                MatchResult(
                    importedSong: staleSong,
                    disposition: .unmatched,
                    score: 0,
                    reason: "旧结果"
                ),
                MatchResult(
                    importedSong: second,
                    disposition: .unmatched,
                    score: 0,
                    reason: "暂未找到"
                )
            ],
            preferenceProfile: makePreferenceProfile()
        )
        var invalidReview = reviewSongs
        invalidReview[0].title = "   "

        XCTAssertNil(PlaylistPreparationSummary(
            playlist: playlist,
            reviewSongs: reviewSongs,
            analysis: incomplete
        ))
        XCTAssertNil(PlaylistPreparationSummary(
            playlist: playlist,
            reviewSongs: reviewSongs,
            analysis: stale
        ))
        XCTAssertNil(PlaylistPreparationSummary(
            playlist: playlist,
            reviewSongs: invalidReview,
            analysis: stale
        ))
    }

    func testPreparationSummaryAllowsFallbackPlanWhenNoSongIsVerified() throws {
        let song = makeImportedSong(title: "暂未找到", artist: "可靠导入歌手")
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "兜底排歌",
            songs: [song],
            parseConfidence: 1
        )
        let basis = MatchBasis(
            playlistID: playlist.id,
            reviewRevision: 1,
            catalogRevision: "catalog-a"
        )
        let analysis = CompletedPlaylistAnalysis(
            basis: basis,
            matchRevision: 1,
            matches: [
                MatchResult(
                    importedSong: song,
                    disposition: .unmatched,
                    score: 0,
                    reason: "暂未找到"
                )
            ],
            preferenceProfile: makePreferenceProfile()
        )

        let summary = try XCTUnwrap(PlaylistPreparationSummary(
            playlist: playlist,
            reviewSongs: [WorkflowReviewSong(song: song)],
            analysis: analysis
        ))

        XCTAssertEqual(summary.validReviewedCount, 1)
        XCTAssertEqual(summary.verifiedCount, 0)
        XCTAssertTrue(summary.canContinue)
    }

    func testExplicitOperationStatesCarryProgressRetryAndStalePlan() throws {
        let basis = makePlanBasis(
            matchBasis: MatchBasis(
                playlistID: UUID(),
                reviewRevision: 1,
                catalogRevision: "catalog-a"
            )
        )
        let stale = StalePlanSnapshot(
            plan: SongPlan(
                title: "上一版歌单",
                scenario: .friends,
                sections: []
            ),
            previousBasis: basis,
            reason: "场景已更新"
        )
        let restoredStale = try JSONDecoder().decode(
            StalePlanSnapshot.self,
            from: JSONEncoder().encode(stale)
        )
        let planState = PlanGenerationState.failed(
            message: "暂时排不出来",
            retryable: true,
            previous: restoredStale
        )

        XCTAssertEqual(
            ImportOperationState.failed(message: "链接读取失败", retryable: true),
            .failed(message: "链接读取失败", retryable: true)
        )
        XCTAssertEqual(MatchOperationState.running(processed: 12, total: 300), .running(processed: 12, total: 300))
        XCTAssertEqual(restoredStale.previousBasis, basis)
        XCTAssertEqual(restoredStale.reason, "场景已更新")
        switch planState {
        case let .failed(message, retryable, previous):
            XCTAssertEqual(message, "暂时排不出来")
            XCTAssertTrue(retryable)
            XCTAssertEqual(previous?.reason, "场景已更新")
        default:
            XCTFail("应保留失败原因和上一版 stale 计划")
        }
    }

    private func makePlanBasis(
        matchBasis: MatchBasis,
        matchRevision: UInt64 = 8,
        scenarioFingerprint: String = "scenario-a",
        voiceSource: VoiceProfileSource = .measured,
        voiceFingerprint: String = "voice-a",
        feedbackRevision: UInt64 = 5,
        trackControlsRevision: UInt64 = 7,
        catalogRevision: String? = nil
    ) -> PlanBasis {
        PlanBasis(
            matchBasis: matchBasis,
            matchRevision: matchRevision,
            scenarioFingerprint: scenarioFingerprint,
            voiceSource: voiceSource,
            voiceFingerprint: voiceFingerprint,
            feedbackRevision: feedbackRevision,
            trackControlsRevision: trackControlsRevision,
            catalogRevision: catalogRevision ?? matchBasis.catalogRevision
        )
    }

    private func makeImportedSong(title: String, artist: String) -> ImportedSong {
        ImportedSong(
            title: title,
            artist: artist,
            source: .plainText,
            confidence: 1
        )
    }

    private func makeTrack(
        id: String,
        title: String,
        artist: String,
        versionTags: [String] = [],
        catalogSource: TrackCatalogSource = .ktvCatalog
    ) -> KTVTrack {
        KTVTrack(
            id: id,
            title: title,
            artist: artist,
            language: "华语",
            era: "2020s",
            genre: "流行",
            moodTags: ["温暖"],
            sceneTags: ["朋友聚会"],
            difficulty: 3,
            vocalRangeLowMidi: 52,
            vocalRangeHighMidi: 67,
            energy: 0.7,
            singAlongScore: 0.8,
            ktvAvailability: 0.9,
            duetFriendly: false,
            rapDensity: 0.1,
            highNoteRisk: 0.2,
            aliases: [],
            versionTags: versionTags,
            similarSongIds: [],
            catalogSource: catalogSource
        )
    }

    private func makeVoiceProfile(
        source: VoiceProfileSource,
        stableHighMidi: Int,
        createdAt: Date = Date(timeIntervalSince1970: 100)
    ) -> VoiceProfile {
        VoiceProfile(
            type: .midMale,
            minMidi: 48,
            maxMidi: 72,
            stableLowMidi: 53,
            stableHighMidi: stableHighMidi,
            averageMidi: 60.5,
            confidence: 0.86,
            note: "本次音区结果",
            source: source,
            suitableSongTypes: ["旋律平稳"],
            avoidSongTypes: ["连续高音"],
            singingStrategy: ["先试唱"],
            createdAt: createdAt
        )
    }

    private func makePreferenceProfile() -> PreferenceProfile {
        PreferenceProfile(
            topArtists: [],
            languageDistribution: [:],
            eraDistribution: [:],
            genreDistribution: [:],
            moodTags: [:],
            sceneAffinity: [:],
            ktvMatchRate: 0,
            averageDifficulty: 0,
            averageSingAlongScore: 0,
            highNoteRisk: 0,
            summary: "完整画像"
        )
    }
}

private struct BasisPayload: Codable, Equatable {
    let ledger: WorkflowRevisionLedger
    let match: MatchBasis
    let plan: PlanBasis
}
