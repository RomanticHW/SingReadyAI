import XCTest
@testable import SingReadyAISharedKit

final class ExternalCandidateContractTests: XCTestCase {
    func testExternalMetadataDecoderClampsPersistedRelevance() throws {
        let tooHigh = try JSONDecoder().decode(
            ExternalCandidateMetadata.self,
            from: Data(#"{"relation":"sameArtist","relevance":7,"reasons":[],"provider":"iTunes"}"#.utf8)
        )
        let tooLow = try JSONDecoder().decode(
            ExternalCandidateMetadata.self,
            from: Data(#"{"relation":"similarTrack","relevance":-4,"reasons":[],"provider":"lastFM"}"#.utf8)
        )

        XCTAssertEqual(tooHigh.relevance, 1)
        XCTAssertEqual(tooLow.relevance, 0)
    }

    func testPlaylistRevisionChangesWhenSamePlaylistIDContentChanges() {
        let playlistID = UUID()
        let first = ImportedPlaylist(
            id: playlistID,
            source: .plainText,
            title: "同一歌单",
            songs: [ImportedSong(title: "晴天", artist: "周杰伦", source: .plainText, confidence: 1)],
            parseConfidence: 1
        )
        let edited = ImportedPlaylist(
            id: playlistID,
            source: .plainText,
            title: "同一歌单",
            songs: [ImportedSong(title: "七里香", artist: "周杰伦", source: .plainText, confidence: 1)],
            parseConfidence: 1
        )

        XCTAssertNotEqual(
            ExternalCandidatePlaylistRevision.fingerprint(for: first),
            ExternalCandidatePlaylistRevision.fingerprint(for: edited)
        )
    }

    func testSamePlaylistIDWithChangedRevisionRejectsOldCompletion() throws {
        let playlistID = UUID()
        var coordinator = ExternalCandidateRequestCoordinator()
        let request = try XCTUnwrap(coordinator.beginIfIdle(
            playlistID: playlistID,
            playlistRevision: "revision-a",
            nowNanoseconds: 100,
            timeoutNanoseconds: 100
        ))

        XCTAssertFalse(coordinator.commit(
            request,
            playlistID: playlistID,
            playlistRevision: "revision-b",
            nowNanoseconds: 120
        ))
        XCTAssertTrue(coordinator.isActive(request))
        XCTAssertTrue(coordinator.finish(request))
    }

    func testSeedSelectorPrioritizesBackupNeedsAfterFirstFourSongsInPlaylistOrder() {
        let songs = (1...8).map { index in
            ImportedSong(
                title: "歌曲\(index)",
                artist: "歌手\(index)",
                source: .plainText,
                confidence: 1
            )
        }
        let tracks = songs.enumerated().map { index, song in
            makeTrack(id: "seed-track-\(index)", title: song.title, artist: song.artist ?? "")
        }
        let matches = [
            MatchResult(importedSong: songs[0], matchedTrack: tracks[0], alternatives: [], status: .exact, score: 1, reason: "命中"),
            MatchResult(importedSong: songs[1], matchedTrack: tracks[1], alternatives: [], status: .exact, score: 1, reason: "命中"),
            MatchResult(importedSong: songs[2], matchedTrack: tracks[2], alternatives: [], status: .exact, score: 1, reason: "命中"),
            MatchResult(importedSong: songs[3], matchedTrack: tracks[3], alternatives: [], status: .exact, score: 1, reason: "命中"),
            MatchResult(importedSong: songs[4], matchedTrack: nil, alternatives: [], status: .unmatched, score: 0, reason: "未命中"),
            MatchResult(importedSong: songs[5], matchedTrack: tracks[5], alternatives: [], status: .fuzzy, score: 0.8, reason: "模糊"),
            MatchResult(importedSong: songs[6], matchedTrack: tracks[6], alternatives: [], status: .exact, confirmationState: .required, score: 0.8, reason: "待确认"),
            MatchResult(importedSong: songs[7], matchedTrack: nil, alternatives: [tracks[7]], status: .alternative, score: 0.5, reason: "待采用")
        ]

        let selected = ExternalCandidateSeedSelector().seeds(
            from: songs,
            matches: matches,
            limit: 4
        )

        XCTAssertEqual(selected.map(\.id), Array(songs[4...7]).map(\.id))
    }

    func testSeedSelectorUsesStableFirstFourWhenNoSongNeedsBackup() {
        let songs = (1...6).map { index in
            ImportedSong(
                title: "稳定歌曲\(index)",
                artist: "稳定歌手\(index)",
                source: .plainText,
                confidence: 1
            )
        }
        let matches = songs.enumerated().map { index, song in
            MatchResult(
                importedSong: song,
                matchedTrack: makeTrack(id: "stable-track-\(index)", title: song.title, artist: song.artist ?? ""),
                alternatives: [],
                status: .exact,
                score: 1,
                reason: "命中"
            )
        }

        let selected = ExternalCandidateSeedSelector().seeds(
            from: songs,
            matches: matches,
            limit: 4
        )

        XCTAssertEqual(selected.map(\.id), Array(songs.prefix(4)).map(\.id))
    }

    func testExternalSongCandidateRelationRoundTripsThroughCodable() throws {
        let candidate = ExternalSongCandidate(
            title: "七里香",
            artist: "周杰伦",
            source: .iTunes,
            confidence: 0.91,
            relation: .sameArtist,
            reasons: ["Apple 公开搜索的同歌手曲目"]
        )

        let restored = try JSONDecoder().decode(
            ExternalSongCandidate.self,
            from: JSONEncoder().encode(candidate)
        )

        XCTAssertEqual(restored.relation, .sameArtist)
        XCTAssertEqual(restored.source, .iTunes)
        XCTAssertEqual(restored.confidence, 0.91, accuracy: 0.000_001)
        XCTAssertEqual(restored.reasons, candidate.reasons)
    }

    func testLegacyExternalSongCandidateDefaultsRelationFromProvider() throws {
        let iTunes = try JSONDecoder().decode(
            ExternalSongCandidate.self,
            from: Data(#"{"title":"七里香","artist":"周杰伦","source":"iTunes","confidence":0.8}"#.utf8)
        )
        let lastFM = try JSONDecoder().decode(
            ExternalSongCandidate.self,
            from: Data(#"{"title":"七里香","artist":"周杰伦","source":"lastFM","confidence":0.8}"#.utf8)
        )

        XCTAssertEqual(iTunes.relation, .sameArtist)
        XCTAssertEqual(lastFM.relation, .similarTrack)
    }

    func testExternalMetadataRoundTripsAndLegacyExternalTrackRemainsProvisional() throws {
        let metadata = ExternalCandidateMetadata(
            relation: .sameArtist,
            relevance: 0.91,
            reasons: ["来自歌手公开曲目"],
            provider: .iTunes
        )
        let track = makeTrack(
            id: "external",
            source: .externalSimilar,
            metadata: metadata
        )

        let restored = try JSONDecoder().decode(
            KTVTrack.self,
            from: JSONEncoder().encode(track)
        )

        XCTAssertEqual(restored.externalCandidateMetadata, metadata)
        XCTAssertTrue(restored.isProvisionalExternalCandidate)

        let legacyJSON = """
        {
          "id": "legacy-external",
          "title": "旧外部候选",
          "artist": "测试歌手",
          "language": "Unknown",
          "era": "Unknown",
          "genre": "Unknown",
          "moodTags": [],
          "sceneTags": [],
          "difficulty": 5,
          "vocalRangeLowMidi": 36,
          "vocalRangeHighMidi": 84,
          "energy": 1,
          "singAlongScore": 1,
          "ktvAvailability": 1,
          "duetFriendly": true,
          "rapDensity": 1,
          "highNoteRisk": 1,
          "aliases": [],
          "similarSongIds": [],
          "catalogSource": "externalSimilar"
        }
        """
        let legacy = try JSONDecoder().decode(KTVTrack.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(legacy.externalCandidateMetadata)
        XCTAssertTrue(legacy.isProvisionalExternalCandidate)
        XCTAssertNil(try planItem(for: legacy))
    }

    func testExternalCandidateIsRejectedFromMatchCatalogAndLockedPaths() throws {
        let external = makeTrack(
            id: "external-all-paths",
            title: "三路外部候选",
            artist: "外部歌手",
            source: .externalSimilar,
            metadata: ExternalCandidateMetadata(
                relation: .similarTrack,
                relevance: 1,
                reasons: ["公开结果相关"],
                provider: .lastFM
            )
        )
        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 30)
        let voice = VoiceProfile.simulatedMiddle
        let matchPath = [match(external)]
        let fromMatch = try RecommendationEngine().generatePlan(
            matches: matchPath,
            preferenceProfile: profile(),
            voiceProfile: voice,
            scenario: scenario,
            catalog: [],
            generationContext: makeRecommendationGenerationContext(
                matches: matchPath,
                scenario: scenario,
                voiceProfile: voice
            )
        )
        let fromCatalog = try RecommendationEngine().generatePlan(
            matches: [],
            preferenceProfile: profile(),
            voiceProfile: voice,
            scenario: scenario,
            catalog: [external],
            generationContext: makeRecommendationGenerationContext(
                matches: [],
                scenario: scenario,
                voiceProfile: voice
            )
        )

        XCTAssertFalse(fromMatch.sections.flatMap(\.items).contains { $0.track.id == external.id })
        XCTAssertFalse(fromCatalog.sections.flatMap(\.items).contains { $0.track.id == external.id })
        XCTAssertThrowsError(
            try RecommendationEngine().generatePlan(
                matches: matchPath,
                preferenceProfile: profile(),
                voiceProfile: voice,
                scenario: scenario,
                catalog: [external],
                generationContext: makeRecommendationGenerationContext(
                    matches: matchPath,
                    scenario: scenario,
                    voiceProfile: voice
                ),
                lockedTrackIDs: [external.id]
            )
        ) { error in
            XCTAssertTrue(error is RecommendationGenerationError)
            XCTAssertEqual(
                String(describing: error),
                "lockedTrackUnavailable(trackIDs: [\"external-all-paths\"])"
            )
        }
    }

    func testProvisionalRecommendationIgnoresAllPlaceholderMetrics() throws {
        let metadata = ExternalCandidateMetadata(
            relation: .similarTrack,
            relevance: 0.84,
            reasons: ["公开相似曲目结果"],
            provider: .lastFM
        )
        let lowPlaceholders = makeTrack(
            id: "external-low",
            source: .externalSimilar,
            metadata: metadata,
            difficulty: 1,
            lowMidi: 55,
            highMidi: 60,
            energy: 0,
            singAlong: 0,
            availability: 0,
            duetFriendly: false,
            rapDensity: 0,
            highRisk: 0,
            moodTags: [],
            sceneTags: []
        )
        let highPlaceholders = makeTrack(
            id: "external-high",
            source: .externalSimilar,
            metadata: metadata,
            difficulty: 5,
            lowMidi: 30,
            highMidi: 95,
            energy: 1,
            singAlong: 1,
            availability: 1,
            duetFriendly: true,
            rapDensity: 1,
            highRisk: 1,
            moodTags: ["高光", "合唱", "喜庆"],
            sceneTags: ["birthday", "carKTV"]
        )

        XCTAssertNil(try planItem(for: lowPlaceholders))
        XCTAssertNil(try planItem(for: highPlaceholders))
    }

    func testReasonBuilderDoesNotExposeUntrustedExternalMetadataClaims() {
        let track = makeTrack(
            id: "external-untrusted-reason",
            source: .externalSimilar,
            metadata: ExternalCandidateMetadata(
                relation: .sameArtist,
                relevance: 0.9,
                reasons: ["音域完全适合", "大家一定会唱"],
                provider: .iTunes
            )
        )

        let reasons = RecommendationReasonBuilder().reasons(
            for: track,
            preferenceProfile: profile(),
            voiceProfile: measuredVoice(),
            scenario: ScenarioConfig(scenario: .friends),
            importedArtistCounts: [:],
            inputSource: .userImport
        )

        XCTAssertEqual(reasons, track.provisionalDisclosureReasons)
        XCTAssertFalse(reasons.contains { $0.contains("完全适合") || $0.contains("一定会唱") })
    }

    func testProvisionalRankingOrderDoesNotChangeWhenPlaceholderMetricsChange() throws {
        let firstMetadata = ExternalCandidateMetadata(
            relation: .sameArtist,
            relevance: 0.9,
            reasons: ["同歌手公开曲目"],
            provider: .iTunes
        )
        let secondMetadata = ExternalCandidateMetadata(
            relation: .similarTrack,
            relevance: 0.78,
            reasons: ["公开相似曲目"],
            provider: .lastFM
        )
        let firstLow = makeTrack(
            id: "first",
            title: "第一候选",
            artist: "歌手A",
            source: .externalSimilar,
            metadata: firstMetadata,
            difficulty: 1,
            energy: 0,
            singAlong: 0,
            availability: 0,
            highRisk: 0
        )
        let secondHigh = makeTrack(
            id: "second",
            title: "第二候选",
            artist: "歌手B",
            source: .externalSimilar,
            metadata: secondMetadata,
            difficulty: 5,
            energy: 1,
            singAlong: 1,
            availability: 1,
            highRisk: 1
        )
        let firstHigh = makeTrack(
            id: "first",
            title: "第一候选",
            artist: "歌手A",
            source: .externalSimilar,
            metadata: firstMetadata,
            difficulty: 5,
            energy: 1,
            singAlong: 1,
            availability: 1,
            highRisk: 1
        )
        let secondLow = makeTrack(
            id: "second",
            title: "第二候选",
            artist: "歌手B",
            source: .externalSimilar,
            metadata: secondMetadata,
            difficulty: 1,
            energy: 0,
            singAlong: 0,
            availability: 0,
            highRisk: 0
        )

        let originalOrder = try planTrackIDs(catalog: [firstLow, secondHigh])
        let mutatedOrder = try planTrackIDs(catalog: [firstHigh, secondLow])

        XCTAssertEqual(originalOrder, [])
        XCTAssertEqual(mutatedOrder, originalOrder)
    }

    func testProvisionalScoreAndReasonsDoNotChangeAcrossScenarios() throws {
        let track = makeTrack(
            id: "external-scenario",
            source: .externalSimilar,
            metadata: ExternalCandidateMetadata(
                relation: .sameArtist,
                relevance: 0.86,
                reasons: ["Apple 公开搜索的同歌手曲目"],
                provider: .iTunes
            ),
            difficulty: 5,
            energy: 1,
            singAlong: 1,
            availability: 1,
            duetFriendly: true,
            rapDensity: 1,
            highRisk: 1,
            moodTags: ["合唱", "高光"],
            sceneTags: ["birthday"]
        )
        XCTAssertNil(try planItem(for: track, scenario: .friends))
        XCTAssertNil(try planItem(for: track, scenario: .birthday))
        XCTAssertNil(try planItem(for: track, scenario: .carKTV))
    }

    func testProvisionalCandidateCannotSatisfyBirthdayOrChorusHardRules() throws {
        let external = makeTrack(
            id: "external-party",
            source: .externalSimilar,
            metadata: ExternalCandidateMetadata(
                relation: .sameArtist,
                relevance: 1,
                reasons: ["同歌手公开曲目"],
                provider: .iTunes
            ),
            singAlong: 1,
            duetFriendly: true,
            moodTags: ["合唱", "喜庆"],
            sceneTags: ["birthday"]
        )
        let ordinary = makeTrack(id: "local", title: "普通歌曲")
        let matches = [match(external), match(ordinary)]
        let scenario = ScenarioConfig(scenario: .birthday, peopleCount: 6, durationMinutes: 30)
        let voice = measuredVoice()
        let plan = try RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: profile(),
            voiceProfile: voice,
            scenario: scenario,
            catalog: [external, ordinary],
            generationContext: makeRecommendationGenerationContext(
                matches: matches,
                scenario: scenario,
                voiceProfile: voice
            ),
            inputSource: .userImport
        )

        XCTAssertTrue(plan.notices.contains { $0.contains("生日氛围规则未能完全满足") })
        XCTAssertTrue(plan.notices.contains { $0.contains("合唱比例规则未能完全满足") })
    }

    func testAddingExternalCandidateDoesNotChangeVerifiedChorusHardRuleDecision() throws {
        let chorus = makeTrack(id: "verified-chorus", title: "本地合唱", singAlong: 0.9)
        let ordinaryA = makeTrack(id: "verified-a", title: "本地普通一", singAlong: 0.2)
        let ordinaryB = makeTrack(id: "verified-b", title: "本地普通二", singAlong: 0.2)
        let verified = [chorus, ordinaryA, ordinaryB]
        let external = makeTrack(
            id: "external-denominator",
            title: "公开待核对",
            source: .externalSimilar,
            metadata: ExternalCandidateMetadata(
                relation: .sameArtist,
                relevance: 1,
                reasons: ["同歌手公开曲目"],
                provider: .iTunes
            ),
            singAlong: 1
        )
        let scenario = ScenarioConfig(scenario: .friends, peopleCount: 4, durationMinutes: 30)
        let voice = measuredVoice()
        let baselineMatches = verified.map(match)
        let augmentedMatches = (verified + [external]).map(match)
        let baseline = try RecommendationEngine().generatePlan(
            matches: baselineMatches,
            preferenceProfile: profile(),
            voiceProfile: voice,
            scenario: scenario,
            catalog: verified,
            generationContext: makeRecommendationGenerationContext(
                matches: baselineMatches,
                scenario: scenario,
                voiceProfile: voice
            )
        )
        let withExternal = try RecommendationEngine().generatePlan(
            matches: augmentedMatches,
            preferenceProfile: profile(),
            voiceProfile: voice,
            scenario: scenario,
            catalog: verified + [external],
            generationContext: makeRecommendationGenerationContext(
                matches: augmentedMatches,
                scenario: scenario,
                voiceProfile: voice
            )
        )
        let baselineVerifiedIDs = Set(baseline.sections.flatMap(\.items).map(\.track).filter { !$0.isProvisionalExternalCandidate }.map(\.id))
        let augmentedVerifiedIDs = Set(withExternal.sections.flatMap(\.items).map(\.track).filter { !$0.isProvisionalExternalCandidate }.map(\.id))
        let baselineChorusNotices = baseline.notices.filter { $0.contains("合唱比例规则") }
        let augmentedChorusNotices = withExternal.notices.filter { $0.contains("合唱比例规则") }

        XCTAssertEqual(augmentedVerifiedIDs, baselineVerifiedIDs)
        XCTAssertFalse(withExternal.sections.flatMap(\.items).contains { $0.track.id == external.id })
        XCTAssertEqual(augmentedChorusNotices, baselineChorusNotices)
    }

    func testProvisionalCandidatesAreDroppedInsteadOfEnteringFormalSections() throws {
        let external = makeTrack(
            id: "external-neutral",
            title: "公开候选",
            source: .externalSimilar,
            metadata: ExternalCandidateMetadata(
                relation: .sameArtist,
                relevance: 1,
                reasons: ["同歌手公开曲目"],
                provider: .iTunes
            ),
            difficulty: 1,
            energy: 1,
            singAlong: 1,
            availability: 1,
            duetFriendly: true,
            moodTags: ["合唱", "怀旧", "高光"],
            sceneTags: ["friends"]
        )
        let local = makeTrack(id: "verified-local", title: "本地歌", genre: "测试类型")
        let matches = [match(external), match(local)]
        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 30)
        let voice = measuredVoice()
        let plan = try RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: profile(),
            voiceProfile: voice,
            scenario: scenario,
            catalog: [external, local],
            generationContext: makeRecommendationGenerationContext(
                matches: matches,
                scenario: scenario,
                voiceProfile: voice
            )
        )
        XCTAssertFalse(plan.sections.flatMap(\.items).contains { $0.track.id == external.id })
        XCTAssertFalse(plan.sections.contains { $0.role == .externalVerification })
    }

    func testLegacyProvisionalItemAndPlanDecodeRemovePersistedConclusions() throws {
        let itemObject = try legacyUnsafeExternalItemObject()
        let itemData = try JSONSerialization.data(withJSONObject: itemObject, options: [.sortedKeys])
        let item = try JSONDecoder().decode(SongPlanItem.self, from: itemData)

        XCTAssertFalse(item.reasons.contains { $0.contains("很适合") || $0.contains("音域") })
        XCTAssertTrue(item.reasons.allSatisfy { $0.contains("待核对") || $0.contains("公开") || $0.contains("同歌手") })
        XCTAssertTrue(item.riskWarnings.isEmpty)
        XCTAssertTrue(item.alternatives.isEmpty)
        XCTAssertNil(item.singingAdvice)
        XCTAssertEqual(item.scoreBreakdown.preferenceAffinity, 0)
        XCTAssertEqual(item.scoreBreakdown.ktvAvailabilityScore, 0)
        XCTAssertEqual(item.scoreBreakdown.vocalFitScore, 0)
        XCTAssertEqual(item.scoreBreakdown.singAlongScore, 0)
        XCTAssertEqual(item.scoreBreakdown.sceneFitScore, 0)
        XCTAssertEqual(item.scoreBreakdown.varietyScore, 0)
        XCTAssertEqual(item.scoreBreakdown.riskPenalty, 0)
        XCTAssertEqual(item.scoreBreakdown.finalScore, 0.93, accuracy: 0.000_001)

        let planObject: [String: Any] = [
            "title": "旧歌单",
            "scenario": "friends",
            "sections": [[
                "role": "familiar",
                "title": "熟悉金曲",
                "goal": "大家都会唱",
                "items": [itemObject]
            ]]
        ]
        let plan = try JSONDecoder().decode(
            SongPlan.self,
            from: JSONSerialization.data(withJSONObject: planObject, options: [.sortedKeys])
        )
        XCTAssertTrue(plan.sections.flatMap(\.items).isEmpty)
        XCTAssertFalse(plan.sections.contains { $0.role == .externalVerification })
        XCTAssertFalse(plan.sections.contains { $0.role == .familiar }, "丢弃唯一候选后不应保留空分区")

        let text = PlaylistTextExporter().export(plan: plan)
        let json = try PlaylistJSONExporter().export(plan: plan)
        for unsafe in ["这首很适合你", "副歌高音很多", "原调可唱", "本地替代"] {
            XCTAssertFalse(text.contains(unsafe), unsafe)
            XCTAssertFalse(json.contains(unsafe), unsafe)
        }
    }

    func testStartTipsPolicyNeverSelectsProvisionalPlaceholderMetrics() {
        let external = makeTrack(
            id: "external-tip",
            title: "占位高分",
            source: .externalSimilar,
            metadata: ExternalCandidateMetadata(
                relation: .sameArtist,
                relevance: 1,
                reasons: ["同歌手公开曲目"],
                provider: .iTunes
            ),
            difficulty: 1,
            singAlong: 1
        )
        let local = makeTrack(
            id: "local-tip",
            title: "已核对歌曲",
            difficulty: 4,
            singAlong: 0.2
        )
        let plan = SongPlan(
            title: "测试",
            scenario: .friends,
            sections: [SongPlanSection(title: "旧分区", goal: "旧目标", items: [
                unsafePlanItem(track: external),
                unsafePlanItem(track: local)
            ])]
        )

        let selection = StartTipsSelectionPolicy().selection(for: plan)

        XCTAssertEqual(selection.opening?.track.id, local.id)
        XCTAssertNil(selection.chorus)
        XCTAssertNil(selection.easyFallback)
        XCTAssertEqual(selection.closing?.track.id, local.id)
    }

    func testCompleteLocalCatalogSemanticKeysSuppressIrrelevantExternalDuplicate() throws {
        let localDuplicate = makeTrack(
            id: "local-duplicate-hidden",
            title: "同名歌曲",
            artist: "同一歌手",
            genre: "不相关类型",
            singAlong: 0.1
        )
        let externalDuplicate = makeTrack(
            id: "external-duplicate-visible",
            title: "同名歌曲",
            artist: "同一歌手",
            source: .externalSimilar,
            metadata: ExternalCandidateMetadata(
                relation: .sameArtist,
                relevance: 1,
                reasons: ["同歌手公开曲目"],
                provider: .iTunes
            )
        )
        let relevant = (0..<8).map { index in
            makeTrack(id: "relevant-\(index)", title: "相关歌曲 \(index)", genre: "测试类型")
        }
        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 30)
        let voice = VoiceProfile.simulatedMiddle
        let plan = try RecommendationEngine().generatePlan(
            matches: [],
            preferenceProfile: profile(genre: "测试类型"),
            voiceProfile: voice,
            scenario: scenario,
            catalog: [externalDuplicate] + relevant + [localDuplicate],
            generationContext: makeRecommendationGenerationContext(
                matches: [],
                scenario: scenario,
                voiceProfile: voice
            )
        )

        XCTAssertFalse(plan.sections.flatMap(\.items).contains { $0.track.id == externalDuplicate.id })
    }

    func testEqualScoreOrderingUsesStableSemanticKeyInsteadOfCatalogOrder() throws {
        let alpha = makeTrack(id: "alpha", title: "A 歌", artist: "歌手A")
        let beta = makeTrack(id: "beta", title: "B 歌", artist: "歌手B")

        let firstOrder = try planTrackIDs(catalog: [beta, alpha])
        let secondOrder = try planTrackIDs(catalog: [alpha, beta])

        XCTAssertEqual(firstOrder, secondOrder)
        XCTAssertEqual(firstOrder, ["alpha", "beta"])
    }

    func testSemanticDeduplicationAlwaysKeepsLocalReference() throws {
        let metadata = ExternalCandidateMetadata(
            relation: .sameArtist,
            relevance: 1,
            reasons: ["同歌手公开曲目"],
            provider: .iTunes
        )
        let external = makeTrack(
            id: "external:duplicate",
            title: "七里香",
            artist: "周杰伦",
            source: .externalSimilar,
            metadata: metadata
        )
        let local = makeTrack(
            id: "local:duplicate",
            title: "七里香",
            artist: "周杰伦",
            source: .ktvCatalog
        )

        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 30)
        let voice = VoiceProfile.simulatedMiddle
        let plan = try RecommendationEngine().generatePlan(
            matches: [],
            preferenceProfile: profile(genre: local.genre),
            voiceProfile: voice,
            scenario: scenario,
            catalog: [external, local],
            generationContext: makeRecommendationGenerationContext(
                matches: [],
                scenario: scenario,
                voiceProfile: voice
            )
        )
        let ids = Set(plan.sections.flatMap(\.items).map(\.track.id))

        XCTAssertTrue(ids.contains(local.id))
        XCTAssertFalse(ids.contains(external.id))
    }

    func testHighRelevanceExternalCandidateDoesNotEnterPlanAfterFullLocalCap() throws {
        let localTracks = (0..<90).map { index in
            makeTrack(
                id: "local-\(index)",
                title: "本地歌 \(index)",
                genre: "测试类型",
                difficulty: 5,
                energy: 0.2,
                singAlong: 0.1,
                availability: 0.1,
                rapDensity: 0.8,
                highRisk: 0.9
            )
        }
        let external = makeTrack(
            id: "external:priority",
            title: "高相关候选",
            source: .externalSimilar,
            metadata: ExternalCandidateMetadata(
                relation: .similarTrack,
                relevance: 1,
                reasons: ["多个公开结果一致"],
                provider: .lastFM
            )
        )
        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 30)
        let voice = VoiceProfile.simulatedMiddle
        let plan = try RecommendationEngine().generatePlan(
            matches: [],
            preferenceProfile: profile(genre: "测试类型"),
            voiceProfile: voice,
            scenario: scenario,
            catalog: localTracks + [external],
            generationContext: makeRecommendationGenerationContext(
                matches: [],
                scenario: scenario,
                voiceProfile: voice
            )
        )

        XCTAssertFalse(plan.sections.flatMap(\.items).contains { $0.track.id == external.id })
    }

    func testAccumulatorDeduplicatesBySemanticKeyAndLocalCatalogWins() {
        let local = makeTrack(id: "local", title: "七里香", artist: "周杰伦")
        let existingExternal = makeTrack(
            id: "external:legacy-id",
            title: "晴天",
            artist: "周杰伦",
            source: .externalSimilar,
            metadata: nil
        )
        let candidates = [
            ExternalSongCandidate(
                title: "七里香",
                artist: "周杰伦",
                source: .iTunes,
                confidence: 0.99,
                relation: .sameArtist
            ),
            ExternalSongCandidate(
                title: "晴天",
                artist: "周杰伦",
                source: .iTunes,
                confidence: 0.95,
                relation: .sameArtist
            )
        ]

        let merged = ExternalCandidateTrackAccumulator().mergedTracks(
            baseCatalog: [local],
            existingExternalTracks: [existingExternal],
            candidates: candidates
        )

        XCTAssertFalse(merged.contains { SongNormalizer.normalizeTitle($0.title) == SongNormalizer.normalizeTitle(local.title) })
        XCTAssertEqual(merged.filter { SongNormalizer.normalizeTitle($0.title) == "晴天" }.count, 1)
    }

    func testAccumulatorEqualRelevanceOrderingIsIndependentOfInputOrder() {
        let artistB = ExternalSongCandidate(
            title: "同名歌曲",
            artist: "歌手B",
            source: .iTunes,
            confidence: 0.8,
            relation: .sameArtist
        )
        let artistA = ExternalSongCandidate(
            title: "同名歌曲",
            artist: "歌手A",
            source: .iTunes,
            confidence: 0.8,
            relation: .sameArtist
        )
        let accumulator = ExternalCandidateTrackAccumulator()

        let first = accumulator.mergedTracks(
            baseCatalog: [],
            existingExternalTracks: [],
            candidates: [artistB, artistA]
        )
        let second = accumulator.mergedTracks(
            baseCatalog: [],
            existingExternalTracks: [],
            candidates: [artistA, artistB]
        )

        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.map(\.artist), ["歌手A", "歌手B"])
    }

    func testRequestCoordinatorRejectsConcurrentAndStaleCompletions() throws {
        let playlistA = UUID()
        let playlistB = UUID()
        var coordinator = ExternalCandidateRequestCoordinator()

        let requestA = try XCTUnwrap(coordinator.beginIfIdle(playlistID: playlistA, nowNanoseconds: 100, timeoutNanoseconds: 50))
        XCTAssertNil(coordinator.beginIfIdle(playlistID: playlistA, nowNanoseconds: 101, timeoutNanoseconds: 50))

        coordinator.cancel()
        let requestB = try XCTUnwrap(coordinator.beginIfIdle(playlistID: playlistB, nowNanoseconds: 200, timeoutNanoseconds: 50))

        XCTAssertFalse(coordinator.commit(requestA, playlistID: playlistA, nowNanoseconds: 120))
        XCTAssertFalse(coordinator.finish(requestA), "旧请求的清理不能结束新请求")
        XCTAssertFalse(coordinator.commit(requestB, playlistID: playlistA, nowNanoseconds: 210))
        XCTAssertTrue(coordinator.isActive(requestB))
        XCTAssertTrue(coordinator.commit(requestB, playlistID: playlistB, nowNanoseconds: 210))
        XCTAssertFalse(coordinator.isBusy)
    }

    func testRequestCoordinatorExpiresOnlyCurrentRequestAtDeadline() throws {
        let playlistID = UUID()
        var coordinator = ExternalCandidateRequestCoordinator()
        let request = try XCTUnwrap(coordinator.beginIfIdle(
            playlistID: playlistID,
            nowNanoseconds: 1_000,
            timeoutNanoseconds: 500
        ))

        XCTAssertFalse(coordinator.expire(request, nowNanoseconds: 1_499))
        XCTAssertTrue(coordinator.expire(request, nowNanoseconds: 1_500))
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertFalse(coordinator.commit(request, playlistID: playlistID, nowNanoseconds: 1_500))
    }

    func testOverallTimeoutThrowsTypedError() async {
        do {
            _ = try await withExternalCandidateTimeout(nanoseconds: 0) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "too late"
            }
            XCTFail("应当超时")
        } catch let error as ExternalCandidateRequestError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
    }

    func testOverallTimeoutReturnsWithoutWaitingForCancellationIgnoringOperation() async {
        let startedAt = Date()

        do {
            _ = try await withExternalCandidateTimeout(nanoseconds: 0) {
                await Task.detached {
                    do {
                        try await Task.sleep(nanoseconds: 400_000_000)
                    } catch {
                        // Detached task is intentionally independent from the timed operation.
                    }
                    return "too late"
                }.value
            }
            XCTFail("应当超时")
        } catch let error as ExternalCandidateRequestError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }

        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            0.2,
            "总超时不能被不响应取消的底层请求拖住"
        )
    }

    func testOverallTimeoutWrapperPropagatesCallerCancellationPromptly() async {
        let task = Task {
            try await withExternalCandidateTimeout(nanoseconds: 5_000_000_000) {
                await Task.detached {
                    do {
                        try await Task.sleep(nanoseconds: 400_000_000)
                    } catch {
                        // Detached task intentionally ignores the outer cancellation.
                    }
                    return "too late"
                }.value
            }
        }
        let startedAt = Date()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("应当取消")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.2)
    }

    private func planItem(
        for track: KTVTrack,
        scenario: KTVScenario = .carKTV
    ) throws -> SongPlanItem? {
        let matches = [match(track)]
        let config = ScenarioConfig(scenario: scenario, peopleCount: 4, durationMinutes: 30)
        let voice = measuredVoice()
        return try RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: profile(),
            voiceProfile: voice,
            scenario: config,
            catalog: [track],
            generationContext: makeRecommendationGenerationContext(
                matches: matches,
                scenario: config,
                voiceProfile: voice
            ),
            inputSource: .userImport
        ).sections.flatMap(\.items).first
    }

    private func planTrackIDs(catalog: [KTVTrack]) throws -> [String] {
        let matches = catalog.map(match)
        let scenario = ScenarioConfig(scenario: .friends, peopleCount: 4, durationMinutes: 30)
        let voice = measuredVoice()
        return try RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: profile(),
            voiceProfile: voice,
            scenario: scenario,
            catalog: catalog,
            generationContext: makeRecommendationGenerationContext(
                matches: matches,
                scenario: scenario,
                voiceProfile: voice
            ),
            inputSource: .userImport
        ).sections.flatMap(\.items).map(\.track.id)
    }

    private func match(_ track: KTVTrack) -> MatchResult {
        MatchResult(
            importedSong: ImportedSong(
                title: track.title,
                artist: track.artist,
                source: .plainText,
                confidence: 1
            ),
            matchedTrack: track,
            alternatives: [],
            status: .exact,
            score: 1,
            reason: "测试"
        )
    }

    private func profile(genre: String = "测试类型") -> PreferenceProfile {
        PreferenceProfile(
            topArtists: [],
            languageDistribution: [:],
            eraDistribution: [:],
            genreDistribution: [genre: 1],
            moodTags: [:],
            sceneAffinity: [:],
            ktvMatchRate: 0,
            averageDifficulty: 0,
            averageSingAlongScore: 0,
            highNoteRisk: 0,
            summary: "测试"
        )
    }

    private func measuredVoice() -> VoiceProfile {
        VoiceProfile(
            type: .unknown,
            minMidi: 48,
            maxMidi: 72,
            stableLowMidi: 50,
            stableHighMidi: 68,
            averageMidi: 59,
            confidence: 0.8,
            note: "测试",
            source: .measured
        )
    }

    private func makeTrack(
        id: String,
        title: String = "测试候选",
        artist: String = "测试歌手",
        genre: String = "测试类型",
        source: TrackCatalogSource = .ktvCatalog,
        metadata: ExternalCandidateMetadata? = nil,
        difficulty: Int = 3,
        lowMidi: Int = 48,
        highMidi: Int = 70,
        energy: Double = 0.5,
        singAlong: Double = 0.5,
        availability: Double = 0.5,
        duetFriendly: Bool = false,
        rapDensity: Double = 0.1,
        highRisk: Double = 0.4,
        moodTags: [String] = [],
        sceneTags: [String] = []
    ) -> KTVTrack {
        KTVTrack(
            id: id,
            title: title,
            artist: artist,
            language: "Unknown",
            era: "Unknown",
            genre: genre,
            moodTags: moodTags,
            sceneTags: sceneTags,
            difficulty: difficulty,
            vocalRangeLowMidi: lowMidi,
            vocalRangeHighMidi: highMidi,
            energy: energy,
            singAlongScore: singAlong,
            ktvAvailability: availability,
            duetFriendly: duetFriendly,
            rapDensity: rapDensity,
            highNoteRisk: highRisk,
            aliases: [],
            similarSongIds: [],
            catalogSource: source,
            externalCandidateMetadata: metadata
        )
    }

    private func unsafePlanItem(track: KTVTrack) -> SongPlanItem {
        SongPlanItem(
            track: track,
            score: 0.93,
            scoreBreakdown: RecommendationScoreBreakdown(
                preferenceAffinity: 0.9,
                ktvAvailabilityScore: 0.9,
                vocalFitScore: 0.9,
                singAlongScore: 0.9,
                sceneFitScore: 0.9,
                varietyScore: 0.9,
                riskPenalty: 0.1,
                finalScore: 0.93
            ),
            reasons: ["这首很适合你", "音域与你很匹配"],
            riskWarnings: ["副歌高音很多"],
            alternatives: [],
            singingAdvice: SingingAdjustmentAdvice(
                level: .originalKey,
                title: "原调可唱",
                detail: "完全适合",
                semitoneShift: 0
            )
        )
    }

    private func legacyUnsafeExternalItemObject() throws -> [String: Any] {
        let external = makeTrack(
            id: "legacy-external-item",
            title: "旧外部候选",
            artist: "旧歌手",
            source: .externalSimilar,
            metadata: ExternalCandidateMetadata(
                relation: .sameArtist,
                relevance: 0.8,
                reasons: ["同歌手公开曲目"],
                provider: .iTunes
            ),
            difficulty: 1,
            singAlong: 1,
            availability: 1,
            highRisk: 0.9
        )
        let alternative = makeTrack(id: "legacy-local-alt", title: "本地替代")
        let trackObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(external)) as? [String: Any]
        )
        let alternativeObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(alternative)) as? [String: Any]
        )
        return [
            "track": trackObject,
            "score": 0.93,
            "scoreBreakdown": [
                "preferenceAffinity": 0.9,
                "ktvAvailabilityScore": 0.9,
                "vocalFitScore": 0.9,
                "singAlongScore": 0.9,
                "sceneFitScore": 0.9,
                "varietyScore": 0.9,
                "riskPenalty": 0.1,
                "finalScore": 0.93
            ],
            "reasons": ["这首很适合你", "音域与你很匹配"],
            "riskWarnings": ["副歌高音很多"],
            "alternatives": [alternativeObject],
            "isLocked": false,
            "singingAdvice": [
                "level": "originalKey",
                "title": "原调可唱",
                "detail": "完全适合",
                "semitoneShift": 0
            ],
            "feedbackTags": []
        ]
    }
}
