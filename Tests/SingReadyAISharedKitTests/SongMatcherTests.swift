import XCTest
@testable import SingReadyAISharedKit

final class SongMatcherTests: XCTestCase {
    func testSongMatchDispositionHasExactlySixStableCodableShapes() throws {
        let original = makeTrack(id: "original", title: "原曲", artist: "原歌手")
        let candidate = makeTrack(id: "candidate", title: "候选", artist: "候选歌手")
        let cases: [(disposition: SongMatchDisposition, kind: String, payloadKey: String?)] = [
            (.acceptedOriginalExact(track: original), "acceptedOriginalExact", "track"),
            (.acceptedOriginalConfirmed(track: original), "acceptedOriginalConfirmed", "track"),
            (.identityConfirmationRequired(candidates: [candidate]), "identityConfirmationRequired", "candidates"),
            (.alternativeSuggested(candidates: [candidate]), "alternativeSuggested", "candidates"),
            (.adoptedAlternative(track: candidate), "adoptedAlternative", "track"),
            (.unmatched, "unmatched", nil)
        ]

        XCTAssertEqual(cases.count, 6)
        for testCase in cases {
            let data = try JSONEncoder().encode(testCase.disposition)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let expectedKeys = Set(["kind", testCase.payloadKey].compactMap(\.self))

            XCTAssertEqual(object["kind"] as? String, testCase.kind)
            XCTAssertEqual(Set(object.keys), expectedKeys)

            let decoded = try JSONDecoder().decode(SongMatchDisposition.self, from: data)
            XCTAssertEqual(dispositionKind(decoded), testCase.kind)
            XCTAssertEqual(dispositionTrackIDs(decoded), dispositionTrackIDs(testCase.disposition))
        }
    }

    func testMatchResultEncodingWritesOnlyNewDispositionFormatAndPrefersItWhenDecoding() throws {
        let original = makeTrack(id: "original", title: "原曲", artist: "原歌手")
        let alternative = makeTrack(id: "alternative", title: "替代", artist: "替代歌手")
        let result = MatchResult(
            importedSong: ImportedSong(title: original.title, artist: original.artist, source: .plainText, confidence: 1),
            disposition: .acceptedOriginalExact(track: original),
            suggestedAlternatives: [alternative, original, alternative],
            score: 1,
            reason: "精确命中"
        )

        let encoded = try JSONEncoder().encode(result)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertNotNil(object["disposition"])
        XCTAssertEqual((object["suggestedAlternatives"] as? [[String: Any]])?.count, 1)
        XCTAssertNil(object["matchedTrack"])
        XCTAssertNil(object["alternatives"])
        XCTAssertNil(object["status"])
        XCTAssertNil(object["confirmationState"])

        object["disposition"] = ["kind": "unmatched"]
        object["matchedTrack"] = try jsonObject(original)
        object["alternatives"] = []
        object["status"] = MatchStatus.exact.rawValue
        object["confirmationState"] = MatchConfirmationState.notRequired.rawValue

        let decoded = try JSONDecoder().decode(
            MatchResult.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertTrue(decoded.isUnmatched)
        XCTAssertNil(decoded.acceptedTrack)
    }

    func testCurrentDispositionInitializerAndDecoderNormalizeAcceptedOriginalIdentity() throws {
        let compatible = makeTrack(id: "compatible", title: "原曲", artist: "原歌手")
        let artistConflict = makeTrack(id: "artist-conflict", title: "原曲", artist: "另一歌手")
        let unrelated = makeTrack(id: "unrelated", title: "无关歌曲", artist: "无关歌手")
        let completeSong = ImportedSong(
            title: "原曲",
            artist: "原歌手",
            source: .plainText,
            confidence: 1
        )
        let missingArtistSong = ImportedSong(
            title: "原曲",
            source: .plainText,
            confidence: 1
        )
        let cases: [CurrentDispositionCase] = [
            (
                "exact-compatible",
                completeSong,
                .acceptedOriginalExact(track: compatible),
                "acceptedOriginalExact",
                [compatible.id],
                compatible.id
            ),
            (
                "exact-unrelated",
                completeSong,
                .acceptedOriginalExact(track: unrelated),
                "unmatched",
                [],
                nil
            ),
            (
                "exact-missing-artist",
                missingArtistSong,
                .acceptedOriginalExact(track: compatible),
                "identityConfirmationRequired",
                [compatible.id],
                nil
            ),
            (
                "exact-artist-conflict",
                completeSong,
                .acceptedOriginalExact(track: artistConflict),
                "identityConfirmationRequired",
                [artistConflict.id],
                nil
            ),
            (
                "confirmed-same-title",
                completeSong,
                .acceptedOriginalConfirmed(track: artistConflict),
                "acceptedOriginalConfirmed",
                [artistConflict.id],
                artistConflict.id
            ),
            (
                "confirmed-unrelated",
                completeSong,
                .acceptedOriginalConfirmed(track: unrelated),
                "unmatched",
                [],
                nil
            ),
            (
                "adopted-unrelated",
                completeSong,
                .adoptedAlternative(track: unrelated),
                "adoptedAlternative",
                [unrelated.id],
                unrelated.id
            )
        ]

        for testCase in cases {
            let direct = MatchResult(
                importedSong: testCase.importedSong,
                disposition: testCase.disposition,
                score: 0.8,
                reason: "当前格式"
            )
            let decoded = try JSONDecoder().decode(
                MatchResult.self,
                from: JSONEncoder().encode(
                    CurrentMatchResultFixture(
                        id: UUID(),
                        importedSong: testCase.importedSong,
                        disposition: testCase.disposition,
                        suggestedAlternatives: [],
                        score: 0.8,
                        reason: "当前格式"
                    )
                )
            )

            for (source, result) in [("initializer", direct), ("decoder", decoded)] {
                XCTAssertEqual(
                    dispositionKind(result.disposition),
                    testCase.expectedKind,
                    "\(testCase.name) / \(source)"
                )
                XCTAssertEqual(
                    dispositionTrackIDs(result.disposition),
                    testCase.expectedTrackIDs,
                    "\(testCase.name) / \(source)"
                )
                XCTAssertEqual(
                    result.acceptedTrack?.id,
                    testCase.expectedAcceptedTrackID,
                    "\(testCase.name) / \(source)"
                )
            }
        }
    }

    func testLegacyMatchResultJSONMigratesEveryValidStateAndNormalizesUnsafeCombinations() throws {
        let original = makeTrack(id: "original", title: "原曲", artist: "原歌手")
        let candidate = makeTrack(id: "candidate", title: "原曲", artist: "另一歌手")
        let replacement = makeTrack(id: "replacement", title: "替代", artist: "替代歌手")
        let importedSong = ImportedSong(
            title: original.title,
            artist: original.artist,
            source: .plainText,
            confidence: 1
        )
        let cases: [(fixture: LegacyMatchResultFixture, expectedKind: String, expectedTrackIDs: [String])] = [
            (
                legacyFixture(importedSong: importedSong, matchedTrack: original, status: .exact),
                "acceptedOriginalExact",
                [original.id]
            ),
            (
                legacyFixture(
                    importedSong: importedSong,
                    matchedTrack: original,
                    status: .exact,
                    confirmationState: .confirmed
                ),
                "acceptedOriginalConfirmed",
                [original.id]
            ),
            (
                legacyFixture(
                    importedSong: importedSong,
                    alternatives: [candidate],
                    status: .fuzzy,
                    confirmationState: .required
                ),
                "identityConfirmationRequired",
                [candidate.id]
            ),
            (
                legacyFixture(importedSong: importedSong, alternatives: [replacement], status: .alternative),
                "alternativeSuggested",
                [replacement.id]
            ),
            (
                legacyFixture(importedSong: importedSong, matchedTrack: replacement, status: .alternative),
                "adoptedAlternative",
                [replacement.id]
            ),
            (
                legacyFixture(importedSong: importedSong, status: .unmatched),
                "unmatched",
                []
            ),
            (
                legacyFixture(importedSong: importedSong, matchedTrack: candidate, status: .fuzzy),
                "identityConfirmationRequired",
                [candidate.id]
            ),
            (
                legacyFixture(importedSong: importedSong, status: .exact),
                "unmatched",
                []
            ),
            (
                legacyFixture(importedSong: importedSong, matchedTrack: candidate, status: .unmatched),
                "identityConfirmationRequired",
                [candidate.id]
            )
        ]

        for testCase in cases {
            let decoded = try JSONDecoder().decode(
                MatchResult.self,
                from: JSONEncoder().encode(testCase.fixture)
            )

            XCTAssertEqual(dispositionKind(decoded.disposition), testCase.expectedKind)
            XCTAssertEqual(dispositionTrackIDs(decoded.disposition), testCase.expectedTrackIDs)
            if ["identityConfirmationRequired", "alternativeSuggested", "unmatched"].contains(testCase.expectedKind) {
                XCTAssertNil(decoded.acceptedTrack, testCase.expectedKind)
            }
        }
    }

    func testLegacyMigrationUsesSameConservativeIdentityRulesForInitializerAndDecoder() throws {
        let compatible = makeTrack(id: "compatible", title: "原曲", artist: "原歌手")
        let artistConflict = makeTrack(id: "artist-conflict", title: "原曲", artist: "另一歌手")
        let titleConflict = makeTrack(id: "title-conflict", title: "另一首", artist: "原歌手")
        let unrelated = makeTrack(id: "unrelated", title: "无关歌曲", artist: "无关歌手")
        let completeSong = ImportedSong(
            title: "原曲",
            artist: "原歌手",
            source: .plainText,
            confidence: 1
        )
        let missingArtistSong = ImportedSong(
            title: "原曲",
            source: .plainText,
            confidence: 1
        )
        let cases = [
            LegacyMigrationCase(
                name: "exact-compatible",
                importedSong: completeSong,
                matchedTrack: compatible,
                alternatives: [],
                status: .exact,
                confirmationState: .notRequired,
                expectedKind: "acceptedOriginalExact",
                expectedTrackIDs: [compatible.id]
            ),
            LegacyMigrationCase(
                name: "exact-artist-conflict",
                importedSong: completeSong,
                matchedTrack: artistConflict,
                alternatives: [],
                status: .exact,
                confirmationState: .notRequired,
                expectedKind: "identityConfirmationRequired",
                expectedTrackIDs: [artistConflict.id]
            ),
            LegacyMigrationCase(
                name: "exact-title-conflict-with-identity-alternative",
                importedSong: completeSong,
                matchedTrack: titleConflict,
                alternatives: [artistConflict],
                status: .exact,
                confirmationState: .notRequired,
                expectedKind: "identityConfirmationRequired",
                expectedTrackIDs: [artistConflict.id]
            ),
            LegacyMigrationCase(
                name: "exact-unrelated",
                importedSong: completeSong,
                matchedTrack: unrelated,
                alternatives: [],
                status: .exact,
                confirmationState: .notRequired,
                expectedKind: "unmatched",
                expectedTrackIDs: []
            ),
            LegacyMigrationCase(
                name: "exact-without-track",
                importedSong: completeSong,
                matchedTrack: nil,
                alternatives: [],
                status: .exact,
                confirmationState: .notRequired,
                expectedKind: "unmatched",
                expectedTrackIDs: []
            ),
            LegacyMigrationCase(
                name: "exact-with-explicit-not-required-but-missing-artist",
                importedSong: missingArtistSong,
                matchedTrack: compatible,
                alternatives: [],
                status: .exact,
                confirmationState: .notRequired,
                expectedKind: "identityConfirmationRequired",
                expectedTrackIDs: [compatible.id]
            ),
            LegacyMigrationCase(
                name: "required-with-track",
                importedSong: completeSong,
                matchedTrack: compatible,
                alternatives: [],
                status: .exact,
                confirmationState: .required,
                expectedKind: "identityConfirmationRequired",
                expectedTrackIDs: [compatible.id]
            ),
            LegacyMigrationCase(
                name: "required-without-track",
                importedSong: completeSong,
                matchedTrack: nil,
                alternatives: [],
                status: .exact,
                confirmationState: .required,
                expectedKind: "unmatched",
                expectedTrackIDs: []
            ),
            LegacyMigrationCase(
                name: "confirmed-same-title-artist-conflict",
                importedSong: completeSong,
                matchedTrack: artistConflict,
                alternatives: [],
                status: .exact,
                confirmationState: .confirmed,
                expectedKind: "acceptedOriginalConfirmed",
                expectedTrackIDs: [artistConflict.id]
            ),
            LegacyMigrationCase(
                name: "confirmed-unrelated-with-identity-alternative",
                importedSong: completeSong,
                matchedTrack: unrelated,
                alternatives: [artistConflict],
                status: .exact,
                confirmationState: .confirmed,
                expectedKind: "identityConfirmationRequired",
                expectedTrackIDs: [artistConflict.id]
            ),
            LegacyMigrationCase(
                name: "confirmed-unrelated-without-identity-candidate",
                importedSong: completeSong,
                matchedTrack: unrelated,
                alternatives: [],
                status: .fuzzy,
                confirmationState: .confirmed,
                expectedKind: "unmatched",
                expectedTrackIDs: []
            ),
            LegacyMigrationCase(
                name: "confirmed-fuzzy-compatible",
                importedSong: completeSong,
                matchedTrack: compatible,
                alternatives: [],
                status: .fuzzy,
                confirmationState: .confirmed,
                expectedKind: "acceptedOriginalConfirmed",
                expectedTrackIDs: [compatible.id]
            ),
            LegacyMigrationCase(
                name: "confirmed-fuzzy-without-track",
                importedSong: completeSong,
                matchedTrack: nil,
                alternatives: [],
                status: .fuzzy,
                confirmationState: .confirmed,
                expectedKind: "unmatched",
                expectedTrackIDs: []
            ),
            LegacyMigrationCase(
                name: "unconfirmed-fuzzy-same-title",
                importedSong: completeSong,
                matchedTrack: artistConflict,
                alternatives: [],
                status: .fuzzy,
                confirmationState: .notRequired,
                expectedKind: "identityConfirmationRequired",
                expectedTrackIDs: [artistConflict.id]
            ),
            LegacyMigrationCase(
                name: "adopted-alternative",
                importedSong: completeSong,
                matchedTrack: unrelated,
                alternatives: [],
                status: .alternative,
                confirmationState: .notRequired,
                expectedKind: "adoptedAlternative",
                expectedTrackIDs: [unrelated.id]
            ),
            LegacyMigrationCase(
                name: "unmatched-with-same-title-track",
                importedSong: completeSong,
                matchedTrack: artistConflict,
                alternatives: [],
                status: .unmatched,
                confirmationState: .notRequired,
                expectedKind: "identityConfirmationRequired",
                expectedTrackIDs: [artistConflict.id]
            )
        ]

        for testCase in cases {
            let initialized = MatchResult(
                importedSong: testCase.importedSong,
                matchedTrack: testCase.matchedTrack,
                alternatives: testCase.alternatives,
                status: testCase.status,
                confirmationState: testCase.confirmationState,
                score: 0.8,
                reason: "旧构造入口"
            )
            let decoded = try JSONDecoder().decode(
                MatchResult.self,
                from: JSONEncoder().encode(
                    legacyFixture(
                        importedSong: testCase.importedSong,
                        matchedTrack: testCase.matchedTrack,
                        alternatives: testCase.alternatives,
                        status: testCase.status,
                        confirmationState: testCase.confirmationState
                    )
                )
            )

            for (source, result) in [("initializer", initialized), ("decoder", decoded)] {
                XCTAssertEqual(
                    dispositionKind(result.disposition),
                    testCase.expectedKind,
                    "\(testCase.name) / \(source)"
                )
                XCTAssertEqual(
                    dispositionTrackIDs(result.disposition),
                    testCase.expectedTrackIDs,
                    "\(testCase.name) / \(source)"
                )
                if ["identityConfirmationRequired", "alternativeSuggested", "unmatched"]
                    .contains(testCase.expectedKind) {
                    XCTAssertNil(result.acceptedTrack, "\(testCase.name) / \(source)")
                }
            }
        }
    }

    @MainActor
    func testPlaylistAnalysisExecutorKeepsMainActorResponsive() async throws {
        let operationStarted = expectation(description: "playlist analysis started")
        let mainActorHeartbeat = expectation(description: "main actor stays responsive")
        let allowAnalysisToFinish = DispatchSemaphore(value: 0)
        let catalog = try KTVCatalogRepository().loadTracks()
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "后台匹配测试",
            songs: [
                ImportedSong(
                    title: "晴天",
                    artist: "周杰伦",
                    source: .plainText,
                    confidence: 1
                )
            ],
            parseConfidence: 1
        )
        let executor = PlaylistAnalysisExecutor(beforeAnalysis: {
            operationStarted.fulfill()
            _ = allowAnalysisToFinish.wait(timeout: .now() + 1)
        })

        let analysisTask = Task { @MainActor in
            try await executor.analyze(playlist: playlist, catalog: catalog)
        }
        await fulfillment(of: [operationStarted], timeout: 1)

        Task { @MainActor in
            mainActorHeartbeat.fulfill()
        }
        await fulfillment(of: [mainActorHeartbeat], timeout: 0.1)
        allowAnalysisToFinish.signal()

        let output = try await analysisTask.value
        XCTAssertEqual(output.matches.count, 1)
        XCTAssertEqual(output.matches.first?.matchedTrack?.title, "晴天")
        XCTAssertNotNil(output.preferenceProfile)
    }

    func testPlaylistAnalysisExecutorHonorsCancellationBeforePublishingResults() async throws {
        let catalog = try KTVCatalogRepository().loadTracks()
        let songs = (0..<1_000).map { index in
            ImportedSong(
                title: "完全不存在且很长的歌曲标题编号\(index)",
                artist: "不存在的歌手",
                source: .plainText,
                confidence: 0.4
            )
        }
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "取消测试",
            songs: songs,
            parseConfidence: 0.4
        )
        let executor = PlaylistAnalysisExecutor()
        let analysisTask = Task {
            try await executor.analyze(playlist: playlist, catalog: catalog)
        }

        analysisTask.cancel()

        do {
            _ = try await analysisTask.value
            XCTFail("取消后的匹配不得发布结果")
        } catch is CancellationError {
            // 预期路径。
        }
    }

    func testIndexedMatcherKeepsThousandExactMatchesWithinWorkerBudget() throws {
        let catalog = try KTVCatalogRepository().loadTracks()
        let track = try XCTUnwrap(catalog.first(where: { $0.title == "晴天" }))
        let songs = (0..<1_000).map { _ in
            ImportedSong(
                title: track.title,
                artist: track.artist,
                source: .plainText,
                confidence: 1
            )
        }
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "千首精确命中",
            songs: songs,
            parseConfidence: 1
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds

        let results = SongMatcher().match(playlist: playlist, catalog: catalog)

        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
        XCTAssertEqual(results.count, 1_000)
        XCTAssertTrue(results.allSatisfy { $0.status == .exact })
        XCTAssertLessThan(elapsedSeconds, 5, "千首精确匹配不应退化为逐首重复规范化全曲库")
    }

    func testIndexedMatcherKeepsWorstCaseFuzzyWorkWithinWorkerBudget() throws {
        let catalog = try KTVCatalogRepository().loadTracks()
        let songs = (0..<100).map { index in
            ImportedSong(
                title: "完全不存在且很长的歌曲标题编号\(index)额外文本",
                artist: "不存在的歌手",
                source: .plainText,
                confidence: 0.4
            )
        }
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "百首模糊匹配",
            songs: songs,
            parseConfidence: 0.4
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds

        let results = SongMatcher().match(playlist: playlist, catalog: catalog)

        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
        XCTAssertEqual(results.count, 100)
        XCTAssertLessThan(elapsedSeconds, 5, "模糊匹配不应为每首歌重复编译正则并全量排序")
    }

    func testMatchResultDisplayPolicyRevealsResultsInBoundedBatches() {
        XCTAssertEqual(MatchResultDisplayPolicy.initialVisibleCount(totalCount: 3), 3)
        XCTAssertEqual(MatchResultDisplayPolicy.initialVisibleCount(totalCount: 12), 5)
        XCTAssertEqual(MatchResultDisplayPolicy.nextVisibleCount(currentCount: 5, totalCount: 12), 10)
        XCTAssertEqual(MatchResultDisplayPolicy.nextVisibleCount(currentCount: 10, totalCount: 12), 12)
    }

    func testMissingArtistSingleTitleCandidateRequiresConfirmation() throws {
        let catalog = try KTVCatalogRepository().loadTracks()
        let track = try XCTUnwrap(catalog.first(where: { $0.title == "晴天" }))

        let result = SongMatcher().match(
            song: ImportedSong(title: track.title, source: .plainText, confidence: 0.9),
            catalog: [track]
        )

        XCTAssertNil(result.matchedTrack)
        XCTAssertEqual(result.alternatives.map(\.id), [track.id])
        XCTAssertEqual(result.confirmationState, .required)
        XCTAssertTrue(result.isPending)
    }

    func testMissingArtistMultipleTitleCandidatesRequireConfirmation() throws {
        let catalog = try KTVCatalogRepository().loadTracks()
            .filter { $0.title == "喜欢你" }
        XCTAssertEqual(catalog.count, 2)

        let result = SongMatcher().match(
            song: ImportedSong(title: "喜欢你", source: .plainText, confidence: 0.9),
            catalog: catalog
        )

        XCTAssertNil(result.matchedTrack)
        XCTAssertEqual(Set(result.alternatives.map(\.id)), Set(catalog.map(\.id)))
        XCTAssertEqual(result.confirmationState, .required)
        XCTAssertTrue(result.isPending)
    }

    func testLegacyMatchResultJSONDefaultsConfirmationToNotRequired() throws {
        let track = try XCTUnwrap(try KTVCatalogRepository().loadTracks().first)
        let legacy = legacyFixture(
            importedSong: ImportedSong(title: track.title, artist: track.artist, source: .plainText, confidence: 1),
            matchedTrack: track,
            status: .exact,
            confirmationState: nil
        )

        let decoded = try JSONDecoder().decode(MatchResult.self, from: JSONEncoder().encode(legacy))

        XCTAssertEqual(decoded.confirmationState, .notRequired)
        XCTAssertEqual(decoded.matchedTrack?.id, track.id)
    }

    func testLegacyMatchWithoutArtistMigratesMatchedTrackToRequiredCandidate() throws {
        let catalog = try KTVCatalogRepository().loadTracks()
        let matchedTrack = try XCTUnwrap(catalog.first)
        let otherCandidate = try XCTUnwrap(catalog.first(where: { $0.id != matchedTrack.id }))
        let legacyArtists: [String?] = [nil, "   "]

        for legacyArtist in legacyArtists {
            let legacy = legacyFixture(
                importedSong: ImportedSong(
                    title: matchedTrack.title,
                    artist: matchedTrack.artist,
                    source: .plainText,
                    confidence: 1
                ),
                matchedTrack: matchedTrack,
                alternatives: [otherCandidate, matchedTrack, otherCandidate],
                status: .exact,
                confirmationState: nil
            )
            var legacyObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
            )
            var importedSong = try XCTUnwrap(legacyObject["importedSong"] as? [String: Any])
            if let legacyArtist {
                importedSong["artist"] = legacyArtist
            } else {
                importedSong.removeValue(forKey: "artist")
            }
            legacyObject["importedSong"] = importedSong
            let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)

            let decoded = try JSONDecoder().decode(MatchResult.self, from: legacyData)

            XCTAssertEqual(decoded.confirmationState, .required)
            XCTAssertNil(decoded.matchedTrack)
            XCTAssertEqual(decoded.alternatives.map(\.id), [matchedTrack.id])
            XCTAssertNil(decoded.confirming(track: otherCandidate))
        }
    }

    func testLegacyMatchMigrationKeepsMultipleSameTitleIdentityCandidates() throws {
        let catalog = try KTVCatalogRepository().loadTracks()
        let identityCandidates = catalog.filter { $0.title == "喜欢你" }
        XCTAssertEqual(identityCandidates.count, 2)
        let unrelated = try XCTUnwrap(catalog.first(where: { $0.title != "喜欢你" }))
        let legacy = legacyFixture(
            importedSong: ImportedSong(
                title: "喜欢你",
                artist: identityCandidates[0].artist,
                source: .plainText,
                confidence: 1
            ),
            matchedTrack: identityCandidates[0],
            alternatives: [unrelated, identityCandidates[1]],
            status: .exact,
            confirmationState: nil
        )
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        var importedSong = try XCTUnwrap(legacyObject["importedSong"] as? [String: Any])
        importedSong.removeValue(forKey: "artist")
        legacyObject["importedSong"] = importedSong

        let decoded = try JSONDecoder().decode(
            MatchResult.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )

        XCTAssertEqual(decoded.confirmationState, .required)
        XCTAssertEqual(decoded.alternatives.map(\.id), identityCandidates.map(\.id))
    }

    func testLegacyMatchMigrationKeepsCandidateWhoseAliasMatchesImportedTitle() throws {
        let catalog = try KTVCatalogRepository().loadTracks()
        let matchedTrack = try XCTUnwrap(catalog.first(where: { $0.title == "晴天" }))
        let aliasCandidate = try XCTUnwrap(catalog.first(where: { $0.id != matchedTrack.id }))
        let unrelated = try XCTUnwrap(catalog.first(where: {
            $0.id != matchedTrack.id && $0.id != aliasCandidate.id
        }))
        let legacy = legacyFixture(
            importedSong: ImportedSong(
                title: matchedTrack.title,
                artist: matchedTrack.artist,
                source: .plainText,
                confidence: 1
            ),
            matchedTrack: matchedTrack,
            alternatives: [aliasCandidate, unrelated],
            status: .exact,
            confirmationState: nil
        )
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        var importedSong = try XCTUnwrap(legacyObject["importedSong"] as? [String: Any])
        importedSong.removeValue(forKey: "artist")
        legacyObject["importedSong"] = importedSong
        var alternatives = try XCTUnwrap(legacyObject["alternatives"] as? [[String: Any]])
        alternatives[0]["aliases"] = [matchedTrack.title]
        legacyObject["alternatives"] = alternatives

        let decoded = try JSONDecoder().decode(
            MatchResult.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )

        XCTAssertEqual(decoded.confirmationState, .required)
        XCTAssertEqual(decoded.alternatives.map(\.id), [matchedTrack.id, aliasCandidate.id])
    }

    func testExactAliasAndArtistAliasMatchesAgainstCatalog() throws {
        let catalog = try KTVCatalogRepository().loadTracks()
        let matcher = SongMatcher()
        let cases: [(title: String, artist: String?, expected: String)] = [
            ("晴天", "周杰伦", "晴天"),
            ("晴天 Live", "Jay Chou", "晴天"),
            ("K 歌之王", "陈奕迅", "K歌之王"),
            ("十年", "Eason", "十年"),
            ("告白气球 伴奏", "周杰伦", "告白气球"),
            ("恋爱 ING", "五月天", "恋爱ing"),
            ("海阔天空", "Beyond", "海阔天空"),
            ("月半小夜曲", "李克勤", "月半小夜曲"),
            ("爱的就是你", "王力宏", "爱的就是你"),
            ("大鱼", "周深", "大鱼"),
            ("说谎", "林宥嘉", "说谎"),
            ("王妃", "萧敬腾", "王妃"),
            ("飞得更高", "汪峰", "飞得更高"),
            ("蓝莲花", "许巍", "蓝莲花"),
            ("追", "张国荣", "追"),
            ("朋友", "周华健", "朋友"),
            ("夜空中最亮的星", "逃跑计划", "夜空中最亮的星"),
            ("云烟成雨", "房东的猫", "云烟成雨"),
            ("画心", "张靓颖", "画心"),
            ("给我一个理由忘记", "A-Lin", "给我一个理由忘记"),
            ("好久不见", "陈奕迅", "好久不见"),
            ("童话", "光良", "童话"),
            ("小情歌", "苏打绿", "小情歌"),
            ("双截棍", "周杰伦", "双截棍"),
            ("快乐崇拜", "潘玮柏", "快乐崇拜")
        ]

        for testCase in cases {
            let result = matcher.match(
                song: ImportedSong(title: testCase.title, artist: testCase.artist, source: .plainText, confidence: 0.9),
                catalog: catalog
            )
            XCTAssertTrue([MatchStatus.exact, .fuzzy].contains(result.status), testCase.title)
            XCTAssertEqual(result.matchedTrack?.title, testCase.expected, testCase.title)
            XCTAssertFalse(result.reason.isEmpty)
        }
    }

    func testUnmatchedSongDoesNotExposeUnverifiedAlternatives() throws {
        let catalog = try KTVCatalogRepository().loadTracks()
        let result = SongMatcher().match(
            song: ImportedSong(title: "不存在的测试歌名", artist: "某歌手", source: .plainText, confidence: 0.4),
            catalog: catalog
        )

        XCTAssertEqual(result.status, .unmatched)
        XCTAssertNil(result.matchedTrack)
        XCTAssertTrue(result.candidateTracks.isEmpty)
        XCTAssertTrue(result.alternatives.isEmpty)
    }

    func testAlternativeMatchExplainsRecommendation() throws {
        let catalog = [
            KTVTrack(
                id: "spring",
                title: "春天里",
                artist: "汪峰",
                language: "Mandarin",
                era: "2010s",
                genre: "摇滚/乐队",
                moodTags: ["热烈"],
                sceneTags: ["friends"],
                difficulty: 3,
                vocalRangeLowMidi: 48,
                vocalRangeHighMidi: 69,
                energy: 0.8,
                singAlongScore: 0.78,
                ktvAvailability: 0.8,
                duetFriendly: false,
                rapDensity: 0,
                highNoteRisk: 0.45,
                aliases: [],
                similarSongIds: []
            )
        ]
        let result = SongMatcher().match(
            song: ImportedSong(title: "冬天里", artist: "汪峰", source: .plainText, confidence: 0.7),
            catalog: catalog
        )

        XCTAssertEqual(result.status, .alternative)
        XCTAssertNil(result.matchedTrack)
        XCTAssertEqual(result.alternatives.map(\.id), ["spring"])
        XCTAssertNotNil(result.adoptingAlternative(track: catalog[0]))
    }

    func testRequiredStateNormalizesMatchedTrackIntoIdentityCandidates() {
        let track = KTVTrack(
            id: "identity",
            title: "同名歌曲",
            artist: "候选歌手",
            language: "Mandarin",
            era: "2010s",
            genre: "华语流行",
            moodTags: [],
            sceneTags: [],
            difficulty: 2,
            vocalRangeLowMidi: 48,
            vocalRangeHighMidi: 67,
            energy: 0.6,
            singAlongScore: 0.7,
            ktvAvailability: 0.7,
            duetFriendly: false,
            rapDensity: 0,
            highNoteRisk: 0.3,
            aliases: [],
            similarSongIds: []
        )

        let result = MatchResult(
            importedSong: ImportedSong(title: track.title, source: .plainText, confidence: 1),
            matchedTrack: track,
            alternatives: [],
            status: .fuzzy,
            confirmationState: .required,
            score: 0.9,
            reason: "待确认"
        )

        XCTAssertNil(result.matchedTrack)
        XCTAssertNil(result.acceptedTrack)
        XCTAssertEqual(result.alternatives.map(\.id), [track.id])
    }

    private func dispositionKind(_ disposition: SongMatchDisposition) -> String {
        switch disposition {
        case .acceptedOriginalExact:
            return "acceptedOriginalExact"
        case .acceptedOriginalConfirmed:
            return "acceptedOriginalConfirmed"
        case .identityConfirmationRequired:
            return "identityConfirmationRequired"
        case .alternativeSuggested:
            return "alternativeSuggested"
        case .adoptedAlternative:
            return "adoptedAlternative"
        case .unmatched:
            return "unmatched"
        }
    }

    private func dispositionTrackIDs(_ disposition: SongMatchDisposition) -> [String] {
        switch disposition {
        case let .acceptedOriginalExact(track),
             let .acceptedOriginalConfirmed(track),
             let .adoptedAlternative(track):
            return [track.id]
        case let .identityConfirmationRequired(candidates),
             let .alternativeSuggested(candidates):
            return candidates.map(\.id)
        case .unmatched:
            return []
        }
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func legacyFixture(
        importedSong: ImportedSong,
        matchedTrack: KTVTrack? = nil,
        alternatives: [KTVTrack] = [],
        status: MatchStatus,
        confirmationState: MatchConfirmationState? = .notRequired
    ) -> LegacyMatchResultFixture {
        LegacyMatchResultFixture(
            id: UUID(),
            importedSong: importedSong,
            matchedTrack: matchedTrack,
            alternatives: alternatives,
            status: status,
            confirmationState: confirmationState,
            score: 0.8,
            reason: "旧快照"
        )
    }

    private func makeTrack(id: String, title: String, artist: String) -> KTVTrack {
        KTVTrack(
            id: id,
            title: title,
            artist: artist,
            language: "Mandarin",
            era: "2010s",
            genre: "华语流行",
            moodTags: [],
            sceneTags: [],
            difficulty: 2,
            vocalRangeLowMidi: 48,
            vocalRangeHighMidi: 67,
            energy: 0.6,
            singAlongScore: 0.7,
            ktvAvailability: 0.7,
            duetFriendly: false,
            rapDensity: 0,
            highNoteRisk: 0.3,
            aliases: [],
            similarSongIds: []
        )
    }
}

private struct LegacyMatchResultFixture: Encodable {
    let id: UUID
    let importedSong: ImportedSong
    let matchedTrack: KTVTrack?
    let alternatives: [KTVTrack]
    let status: MatchStatus
    let confirmationState: MatchConfirmationState?
    let score: Double
    let reason: String
}

private struct CurrentMatchResultFixture: Encodable {
    let id: UUID
    let importedSong: ImportedSong
    let disposition: SongMatchDisposition
    let suggestedAlternatives: [KTVTrack]
    let score: Double
    let reason: String
}

private typealias CurrentDispositionCase = (
    name: String,
    importedSong: ImportedSong,
    disposition: SongMatchDisposition,
    expectedKind: String,
    expectedTrackIDs: [String],
    expectedAcceptedTrackID: String?
)

private struct LegacyMigrationCase {
    let name: String
    let importedSong: ImportedSong
    let matchedTrack: KTVTrack?
    let alternatives: [KTVTrack]
    let status: MatchStatus
    let confirmationState: MatchConfirmationState
    let expectedKind: String
    let expectedTrackIDs: [String]
}
