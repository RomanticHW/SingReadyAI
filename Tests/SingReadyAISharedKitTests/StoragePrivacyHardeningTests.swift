import XCTest
@testable import SingReadyAISharedKit

#if canImport(CoreGraphics) && canImport(ImageIO) && canImport(UniformTypeIdentifiers)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

final class StoragePrivacyHardeningTests: XCTestCase {
    @MainActor
    func testLocalArtifactCleanerKeepsMainActorResponsiveDuringBlockingFileCleanup() async {
        let cleanupStarted = expectation(description: "cleanup started off main actor")
        let mainActorHeartbeat = expectation(description: "main actor stays responsive")
        let allowCleanupToFinish = DispatchSemaphore(value: 0)
        let cleaner = LocalArtifactCleaner(operations: [
            {
                cleanupStarted.fulfill()
                _ = allowCleanupToFinish.wait(timeout: .now() + 1)
            }
        ])
        let cleanupTask = Task { @MainActor in
            await cleaner.clear()
        }
        await fulfillment(of: [cleanupStarted], timeout: 1)

        Task { @MainActor in
            mainActorHeartbeat.fulfill()
        }
        await fulfillment(of: [mainActorHeartbeat], timeout: 0.1)
        allowCleanupToFinish.signal()

        let result = await cleanupTask.value
        XCTAssertEqual(result.failureCount, 0)
    }

    func testOCRTemporaryFileStoreRemovesOnlyOwnedOrphanFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ownedPNG = directory.appendingPathComponent("singready-ocr-old.png")
        let ownedJPG = directory.appendingPathComponent("singready-ocr-old.jpg")
        let unrelated = directory.appendingPathComponent("keep-me.png")
        let similarlyNamed = directory.appendingPathComponent("prefix-singready-ocr-old.png")
        for url in [ownedPNG, ownedJPG, unrelated, similarlyNamed] {
            try Data("test".utf8).write(to: url)
        }

        try OCRTemporaryFileStore(directory: directory).removeOrphans()

        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedPNG.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedJPG.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: similarlyNamed.path))
    }

    func testImageImportLimitsRejectPixelCountOverflowWithoutMultiplication() {
        let limits = ImageImportLimits(
            maximumPixelCount: 40_000_000,
            maximumDimension: Int.max,
            thumbnailMaximumDimension: 4_096
        )

        XCTAssertThrowsError(
            try limits.validate(width: Int.max, height: Int.max)
        ) { error in
            XCTAssertEqual(error as? ImageImportSafetyError, .pixelLimitExceeded)
        }
    }

    #if canImport(CoreGraphics) && canImport(ImageIO) && canImport(UniformTypeIdentifiers)
    func testImageInspectorRejectsValidImageAbovePixelLimitFromMetadata() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("four-pixels.png")
        try writePNG(width: 2, height: 2, to: imageURL)
        let inspector = ImageImportInspector(
            limits: ImageImportLimits(
                maximumPixelCount: 3,
                maximumDimension: 10,
                thumbnailMaximumDimension: 2
            )
        )

        XCTAssertThrowsError(try inspector.inspectImage(at: imageURL)) { error in
            XCTAssertEqual(error as? ImageImportSafetyError, .pixelLimitExceeded)
        }
    }

    func testSharedImageStagingRejectsImageAbovePixelLimitBeforeCopying() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("four-pixels.png")
        try writePNG(width: 2, height: 2, to: imageURL)
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory,
            maximumSharedImageBytes: 1_000_000,
            maximumSharedImagePixels: 3
        )

        XCTAssertThrowsError(try store.stageSharedImage(from: imageURL)) { error in
            XCTAssertEqual(error as? AppGroupStoreError, .sharedImageTooLarge)
        }
        XCTAssertEqual(try sharedImageFiles(in: directory), [])
    }

    func testOCRImageLoaderUsesBoundedThumbnailInsteadOfFullResolutionImage() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("wide.png")
        try writePNG(width: 8, height: 4, to: imageURL)
        let loader = OCRImageLoader(
            limits: ImageImportLimits(
                maximumPixelCount: 100,
                maximumDimension: 20,
                thumbnailMaximumDimension: 2
            )
        )

        let image = try loader.loadThumbnail(at: imageURL)

        XCTAssertLessThanOrEqual(max(image.width, image.height), 2)
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 1)
    }

    @MainActor
    func testScreenshotFilePreparationKeepsMainActorResponsiveDuringInspectionAndCopy() async throws {
        let sourceDirectory = try makeTemporaryDirectory()
        let destinationDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: destinationDirectory)
        }
        let sourceURL = sourceDirectory.appendingPathComponent("source.png")
        try writePNG(width: 2, height: 2, to: sourceURL)
        let preparationStarted = expectation(description: "preparation started off main actor")
        let mainActorHeartbeat = expectation(description: "main actor stays responsive")
        let allowPreparationToFinish = DispatchSemaphore(value: 0)
        let store = OCRTemporaryFileStore(
            directory: destinationDirectory,
            beforeImagePreparation: {
                preparationStarted.fulfill()
                _ = allowPreparationToFinish.wait(timeout: .now() + 1)
            }
        )

        let preparationTask = Task { @MainActor in
            try await store.prepareImageFile(from: sourceURL)
        }
        await fulfillment(of: [preparationStarted], timeout: 1)

        Task { @MainActor in
            mainActorHeartbeat.fulfill()
        }
        await fulfillment(of: [mainActorHeartbeat], timeout: 0.1)
        allowPreparationToFinish.signal()

        let preparedURL = try await preparationTask.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: preparedURL.path))
        try await store.removePreparedImage(at: preparedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedURL.path))
    }

    func testScreenshotFilePreparationRejectsOversizeBeforeCreatingOwnedFile() async throws {
        let sourceDirectory = try makeTemporaryDirectory()
        let destinationDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: destinationDirectory)
        }
        let sourceURL = sourceDirectory.appendingPathComponent("oversize.png")
        try Data(repeating: 0, count: 2).write(to: sourceURL)
        let store = OCRTemporaryFileStore(
            directory: destinationDirectory,
            maximumImageBytes: 1
        )

        do {
            _ = try await store.prepareImageFile(from: sourceURL)
            XCTFail("超过字节上限的截图必须在复制前拒绝")
        } catch {
            XCTAssertEqual(error as? ImageImportSafetyError, .fileTooLarge)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path),
            []
        )
    }
    #endif

    func testRecentPlaylistLoadResultDistinguishesCorruptAndFutureQuarantines() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recent_playlists.json")
        let store = RecentPlaylistStore(url: url)

        try Data("not-json".utf8).write(to: url)
        guard case .quarantined(.corrupt) = try store.loadWithStatus() else {
            return XCTFail("损坏数据应返回 corrupt 隔离状态")
        }

        try Data(#"{"schemaVersion":999,"playlists":[]}"#.utf8).write(to: url)
        guard case .quarantined(.incompatibleVersion) = try store.loadWithStatus() else {
            return XCTFail("未来版本应返回 incompatibleVersion 隔离状态")
        }
    }

    func testRecentPlaylistLoadQuarantinesOversizedArchiveBeforeDecoding() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recent_playlists.json")
        let store = RecentPlaylistStore(url: url)
        try Data(repeating: 0, count: 8 * 1_024 * 1_024 + 1).write(to: url)

        guard case .quarantined(.oversized) = try store.loadWithStatus() else {
            return XCTFail("超过 8 MB 的最近歌单归档应在解码前被隔离")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix("recent_playlists.oversized-") }
        )
    }

    func testWorkflowSnapshotLoadResultDistinguishesMissingCorruptAndFutureData() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workflow_snapshot.json")
        let store = WorkflowSnapshotStore(url: url)

        guard case .missing = try store.loadWithStatus() else {
            return XCTFail("没有快照时应返回 missing")
        }

        try Data("not-json".utf8).write(to: url)
        guard case .quarantined(.corrupt) = try store.loadWithStatus() else {
            return XCTFail("损坏快照应返回 corrupt 隔离状态")
        }

        try Data(#"{"schemaVersion":999,"snapshot":{}}"#.utf8).write(to: url)
        guard case .quarantined(.incompatibleVersion) = try store.loadWithStatus() else {
            return XCTFail("未来版本快照应返回 incompatibleVersion 隔离状态")
        }
    }

    func testWorkflowSnapshotLoadQuarantinesOversizedArchiveBeforeDecoding() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workflow_snapshot.json")
        let store = WorkflowSnapshotStore(url: url)
        try Data(repeating: 0, count: 16 * 1_024 * 1_024).write(to: url)

        guard case .quarantined(.oversized) = try store.loadWithStatus() else {
            return XCTFail("达到 16 MiB 的工作流快照应在解码前被隔离")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix("workflow_snapshot.oversized-") }
        )
    }

    func testWorkflowSnapshotSaveRejectsOversizedArchiveWithoutReplacingStableSnapshot() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workflow_snapshot.json")
        let stableSong = ImportedSong(
            title: "晴天",
            artist: "周杰伦",
            source: .plainText,
            confidence: 1
        )
        let stablePlaylist = ImportedPlaylist(
            source: .plainText,
            title: "稳定快照",
            songs: [stableSong],
            parseConfidence: 1
        )
        let stableSnapshot = WorkflowSnapshot(
            importedPlaylist: stablePlaylist,
            reviewSongs: [WorkflowReviewSong(song: stableSong)],
            revisions: WorkflowRevisionLedger(),
            completedAnalysis: nil,
            persistedPlanRecord: nil,
            externalCandidateCollection: nil,
            voiceProfile: nil,
            recommendationInputSource: .userImport,
            scenarioConfig: ScenarioConfig(),
            lockedTrackIDs: [],
            removedTrackIDs: [],
            feedbackProfile: .empty
        )
        let store = WorkflowSnapshotStore(url: url)
        try store.save(stableSnapshot)
        let stableData = try Data(contentsOf: url)

        let oversizedRawText = String(repeating: "x", count: 9 * 1_024 * 1_024)
        let oversizedSong = ImportedSong(
            title: "超限歌曲",
            source: .plainText,
            rawText: oversizedRawText,
            confidence: 1
        )
        let oversizedPlaylist = ImportedPlaylist(
            source: .plainText,
            title: "超限快照",
            songs: [oversizedSong],
            parseConfidence: 1
        )
        let oversizedSnapshot = WorkflowSnapshot(
            importedPlaylist: oversizedPlaylist,
            reviewSongs: [WorkflowReviewSong(song: oversizedSong)],
            revisions: WorkflowRevisionLedger(),
            completedAnalysis: nil,
            persistedPlanRecord: nil,
            externalCandidateCollection: nil,
            voiceProfile: nil,
            recommendationInputSource: .userImport,
            scenarioConfig: ScenarioConfig(),
            lockedTrackIDs: [],
            removedTrackIDs: [],
            feedbackProfile: .empty
        )

        XCTAssertThrowsError(try store.save(oversizedSnapshot)) { error in
            XCTAssertEqual(error as? WorkflowSnapshotStoreError, .archiveTooLarge)
        }
        XCTAssertEqual(try Data(contentsOf: url), stableData)
        XCTAssertEqual(try store.load()?.importedPlaylist.title, "稳定快照")
    }

    func testWorkflowSnapshotSaveRejectsArchiveAtExactLimitWithoutTouchingStableFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let maximumArchiveByteCount = 16 * 1_024 * 1_024
        let songID = try XCTUnwrap(UUID(uuidString: "10000000-0000-0000-0000-000000000001"))
        let playlistID = try XCTUnwrap(UUID(uuidString: "20000000-0000-0000-0000-000000000002"))
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        func snapshot(rawTextCount: Int) -> WorkflowSnapshot {
            let song = ImportedSong(
                id: songID,
                title: "精确边界歌曲",
                source: .plainText,
                rawText: String(repeating: "x", count: rawTextCount),
                confidence: 1
            )
            let playlist = ImportedPlaylist(
                id: playlistID,
                source: .plainText,
                title: "精确边界快照",
                songs: [song],
                createdAt: fixedDate,
                parseConfidence: 1
            )
            return WorkflowSnapshot(
                importedPlaylist: playlist,
                reviewSongs: [
                    WorkflowReviewSong(
                        id: songID,
                        title: song.title,
                        artist: nil,
                        source: .plainText,
                        rawText: nil,
                        confidence: 1,
                        versionTags: [],
                        isDeleted: false
                    )
                ],
                revisions: WorkflowRevisionLedger(),
                completedAnalysis: nil,
                persistedPlanRecord: nil,
                externalCandidateCollection: nil,
                voiceProfile: nil,
                recommendationInputSource: .userImport,
                scenarioConfig: ScenarioConfig(),
                lockedTrackIDs: [],
                removedTrackIDs: [],
                feedbackProfile: .empty,
                updatedAt: fixedDate
            )
        }

        let calibrationURL = directory.appendingPathComponent("workflow_snapshot_calibration.json")
        let calibrationStore = WorkflowSnapshotStore(url: calibrationURL)
        let initialRawTextCount = maximumArchiveByteCount - 128 * 1_024
        try calibrationStore.save(snapshot(rawTextCount: initialRawTextCount))
        let initialArchiveByteCount = try Data(contentsOf: calibrationURL).count
        XCTAssertLessThan(initialArchiveByteCount, maximumArchiveByteCount)

        let exactRawTextCount = initialRawTextCount
            + maximumArchiveByteCount
            - initialArchiveByteCount
        try calibrationStore.save(snapshot(rawTextCount: exactRawTextCount - 1))
        XCTAssertEqual(
            try Data(contentsOf: calibrationURL).count,
            maximumArchiveByteCount - 1
        )

        let stableURL = directory.appendingPathComponent("workflow_snapshot.json")
        let stableStore = WorkflowSnapshotStore(url: stableURL)
        try stableStore.save(snapshot(rawTextCount: 0))
        let stableData = try Data(contentsOf: stableURL)

        XCTAssertThrowsError(try stableStore.save(snapshot(rawTextCount: exactRawTextCount))) { error in
            XCTAssertEqual(error as? WorkflowSnapshotStoreError, .archiveTooLarge)
        }
        XCTAssertEqual(try Data(contentsOf: stableURL), stableData)
        XCTAssertEqual(try stableStore.load()?.importedPlaylist.title, "精确边界快照")
    }

    func testVersionedStoresPropagateIOReadFailuresInsteadOfReportingQuarantine() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recentDirectoryURL = directory.appendingPathComponent("recent_playlists.json", isDirectory: true)
        let snapshotDirectoryURL = directory.appendingPathComponent("workflow_snapshot.json", isDirectory: true)
        try FileManager.default.createDirectory(at: recentDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshotDirectoryURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try RecentPlaylistStore(url: recentDirectoryURL).loadWithStatus())
        XCTAssertThrowsError(try WorkflowSnapshotStore(url: snapshotDirectoryURL).loadWithStatus())
    }

    func testWorkflowSnapshotMigratesEarlySchemaTwoLegacyDerivationsConservatively() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workflow_snapshot.json")
        let localTrack = makeTrack(id: "local-main", title: "晴天", artist: "周杰伦")
        let alternative = makeTrack(id: "local-alt", title: "晴天", artist: "孙燕姿")
        let externalTrack = makeTrack(
            id: "external-1",
            title: "稻香",
            artist: "周杰伦",
            catalogSource: .externalSimilar,
            metadata: ExternalCandidateMetadata(
                relation: .sameArtist,
                relevance: 0.91,
                reasons: ["同歌手公开候选"],
                provider: .iTunes
            )
        )
        let song = ImportedSong(
            title: "晴天",
            artist: "周杰伦",
            source: .plainText,
            rawText: "晴天 - 周杰伦",
            confidence: 0.93,
            versionTags: ["Live"]
        )
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "完整快照",
            externalURL: URL(string: "https://music.apple.com/cn/playlist/example"),
            songs: [song],
            createdAt: Date(timeIntervalSince1970: 1_710_000_000),
            parseConfidence: 0.93
        )
        let match = MatchResult(
            importedSong: song,
            matchedTrack: localTrack,
            alternatives: [alternative],
            status: .exact,
            confirmationState: .confirmed,
            score: 0.96,
            reason: "歌名和歌手一致"
        )
        let preference = PreferenceProfile(
            topArtists: [("周杰伦", 3)],
            languageDistribution: ["国语": 1],
            eraDistribution: ["2000s": 1],
            genreDistribution: ["流行": 1],
            moodTags: ["合唱": 0.8],
            sceneAffinity: ["friends": 0.9],
            ktvMatchRate: 1,
            averageDifficulty: 3,
            averageSingAlongScore: 0.88,
            highNoteRisk: 0.22,
            chorusFriendliness: 0.9,
            scenarioFitScores: ["friends": 0.95],
            profileTags: ["流行", "适合合唱"],
            summary: "偏爱华语流行"
        )
        let voice = VoiceProfile(
            type: .midMale,
            minMidi: 48,
            maxMidi: 72,
            stableLowMidi: 52,
            stableHighMidi: 67,
            averageMidi: 60.2,
            confidence: 0.87,
            note: "本次测量稳定",
            source: .measured,
            suitableSongTypes: ["华语流行"],
            avoidSongTypes: ["连续高音"],
            singingStrategy: ["先热嗓"],
            createdAt: Date(timeIntervalSince1970: 1_710_000_100)
        )
        let scenario = ScenarioConfig(
            scenario: .friends,
            peopleCount: 5,
            durationMinutes: 75,
            vibe: .energetic,
            chorusPreference: .moreChorus,
            difficultyPreference: .balanced
        )
        let breakdown = RecommendationScoreBreakdown(
            preferenceAffinity: 0.9,
            ktvAvailabilityScore: 0.95,
            vocalFitScore: 0.8,
            singAlongScore: 0.88,
            sceneFitScore: 0.92,
            varietyScore: 0.7,
            riskPenalty: 0.1,
            finalScore: 0.89
        )
        let item = SongPlanItem(
            track: localTrack,
            score: 0.89,
            scoreBreakdown: breakdown,
            reasons: ["歌单原曲", "朋友局适合合唱"],
            riskWarnings: ["高音段留意"],
            alternatives: [alternative],
            isLocked: true,
            singingAdvice: SingingAdjustmentAdvice(
                level: .lowerKey,
                title: "建议降调",
                detail: "可先降 2 个半音试唱",
                semitoneShift: -2
            ),
            actionURL: URL(string: "https://music.apple.com/cn/search?term=晴天"),
            feedbackTags: [.liked, .sung]
        )
        let plan = SongPlan(
            title: "朋友局歌单",
            scenario: .friends,
            inputSource: .userImport,
            scenarioConfig: scenario,
            voiceProfile: voice,
            preferenceSummary: "偏爱华语流行",
            sections: [
                SongPlanSection(
                    role: .warmup,
                    title: "先热场",
                    goal: "从熟歌开始",
                    items: [item]
                )
            ],
            notices: ["候选不足时保留原曲"],
            createdAt: Date(timeIntervalSince1970: 1_710_000_200)
        )
        let snapshot = WorkflowSnapshot(
            importedPlaylist: playlist,
            reviewSongs: [WorkflowReviewSong(song: song)],
            matches: [match],
            preferenceProfile: preference,
            voiceProfile: voice,
            recommendationInputSource: .userImport,
            scenarioConfig: scenario,
            songPlan: plan,
            lockedTrackIDs: [localTrack.id],
            removedTrackIDs: [alternative.id],
            externalCandidateTracks: [externalTrack],
            feedbackProfile: SongFeedbackProfile(feedbackByTrackID: [localTrack.id: [.liked, .sung]]),
            updatedAt: Date(timeIntervalSince1970: 1_710_000_300)
        )

        let store = WorkflowSnapshotStore(url: url)
        try store.save(snapshot)
        let restored = try XCTUnwrap(store.load())

        XCTAssertEqual(restored.importedPlaylist.externalURL, playlist.externalURL)
        XCTAssertEqual(restored.reviewSongs.first?.versionTags, ["Live"])
        XCTAssertNil(restored.completedAnalysis)
        XCTAssertTrue(restored.matches.isEmpty)
        XCTAssertNil(restored.preferenceProfile)
        XCTAssertEqual(restored.voiceProfile, voice)
        guard case let .stale(stalePlan)? = restored.persistedPlanRecord else {
            return XCTFail("缺少 basis 的早期 v2 计划只能恢复为 stale")
        }
        XCTAssertEqual(stalePlan.plan.id, plan.id)
        XCTAssertNil(stalePlan.previousBasis)
        XCTAssertEqual(stalePlan.reason, "这份旧歌单需要按当前选择重新排一版")
        XCTAssertNil(restored.externalCandidateCollection)
        XCTAssertTrue(restored.externalCandidateTracks.isEmpty)
        XCTAssertEqual(restored.lockedTrackIDs, [localTrack.id])
        XCTAssertEqual(restored.removedTrackIDs, [alternative.id])
        XCTAssertEqual(Set(restored.feedbackProfile.feedback(for: localTrack.id)), Set([.liked, .sung]))
        XCTAssertEqual(restored.updatedAt, snapshot.updatedAt)
    }

    func testWorkflowSnapshotV2RoundTripsCommittedStateWithoutSynthesizingKTVFields() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workflow_snapshot.json")
        let song = ImportedSong(
            title: "晴天",
            artist: "周杰伦",
            source: .plainText,
            confidence: 0.96
        )
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "v2 完整快照",
            songs: [song],
            parseConfidence: 0.96
        )
        let track = makeTrack(id: "local-main", title: "晴天", artist: "周杰伦")
        let matchBasis = MatchBasis(
            playlistID: playlist.id,
            reviewRevision: 3,
            catalogRevision: "catalog-v2"
        )
        let preference = makePreferenceProfile()
        let analysis = CompletedPlaylistAnalysis(
            basis: matchBasis,
            matchRevision: 4,
            matches: [
                MatchResult(
                    importedSong: song,
                    matchedTrack: track,
                    alternatives: [],
                    status: .exact,
                    confirmationState: .confirmed,
                    score: 0.97,
                    reason: "歌名和歌手一致"
                )
            ],
            preferenceProfile: preference
        )
        let scenario = ScenarioConfig(scenario: .friends, peopleCount: 4, durationMinutes: 60)
        let plan = SongPlan(
            title: "朋友局歌单",
            scenario: .friends,
            inputSource: .userImport,
            scenarioConfig: scenario,
            preferenceSummary: preference.summary,
            sections: []
        )
        let planBasis = PlanBasis(
            matchBasis: matchBasis,
            matchRevision: 4,
            scenarioFingerprint: "scenario-v2",
            voiceSource: .commonReference,
            voiceFingerprint: "voice-v2",
            feedbackRevision: 5,
            trackControlsRevision: 6,
            catalogRevision: "catalog-v2"
        )
        let externalCollection = ExternalCandidateCollection(
            basis: ExternalCandidateBasis(
                playlistID: playlist.id,
                reviewRevision: 3,
                requestRevision: 8
            ),
            candidates: [
                ExternalSongCandidate(
                    title: "稻香",
                    artist: "周杰伦",
                    source: .iTunes,
                    confidence: 0.91,
                    relation: .sameArtist,
                    reasons: ["同歌手公开候选"],
                    externalURL: URL(string: "https://music.apple.com/cn/song/1"),
                    appleTrackID: "1"
                )
            ]
        )
        let revisions = WorkflowRevisionLedger(
            review: 3,
            match: 4,
            feedback: 5,
            trackControls: 6
        )
        let snapshot = WorkflowSnapshot(
            importedPlaylist: playlist,
            reviewSongs: [WorkflowReviewSong(song: song)],
            revisions: revisions,
            completedAnalysis: analysis,
            persistedPlanRecord: .ready(plan: plan, basis: planBasis),
            externalCandidateCollection: externalCollection,
            voiceProfile: nil,
            recommendationInputSource: .userImport,
            scenarioConfig: scenario,
            lockedTrackIDs: [track.id],
            removedTrackIDs: [],
            feedbackProfile: .empty,
            hasAdvancedToScenario: true,
            updatedAt: Date(timeIntervalSince1970: 1_730_000_000)
        )

        let store = WorkflowSnapshotStore(url: url)
        try store.save(snapshot)
        let restored = try XCTUnwrap(store.load())

        XCTAssertEqual(restored.revisions, revisions)
        XCTAssertEqual(restored.completedAnalysis?.basis, matchBasis)
        XCTAssertEqual(restored.completedAnalysis?.matches.first?.matchedTrack?.id, track.id)
        XCTAssertEqual(restored.completedAnalysis?.preferenceProfile.summary, preference.summary)
        guard case let .ready(restoredPlan, restoredBasis) = restored.persistedPlanRecord else {
            return XCTFail("v2 ready 计划记录应完整恢复")
        }
        XCTAssertEqual(restoredPlan.id, plan.id)
        XCTAssertEqual(restoredBasis, planBasis)
        XCTAssertEqual(restored.externalCandidateCollection, externalCollection)
        XCTAssertEqual(restored.matches.first?.matchedTrack?.id, track.id)
        XCTAssertEqual(restored.preferenceProfile?.summary, preference.summary)
        XCTAssertEqual(restored.songPlan?.id, plan.id)
        XCTAssertTrue(restored.externalCandidateTracks.isEmpty)

        let archive = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(archive["schemaVersion"] as? Int, 2)
        let storedSnapshot = try XCTUnwrap(archive["snapshot"] as? [String: Any])
        XCTAssertNil(storedSnapshot["externalCandidateTracks"])
        let storedCollection = try XCTUnwrap(
            storedSnapshot["externalCandidateCollection"] as? [String: Any]
        )
        let collectionText = String(
            decoding: try JSONSerialization.data(withJSONObject: storedCollection),
            as: UTF8.self
        )
        XCTAssertFalse(collectionText.contains("ktvAvailability"))
        XCTAssertFalse(collectionText.contains("catalogSource"))
    }

    func testWorkflowSnapshotRoundTripsOneThousandSongCommittedSnapshotWithinArchiveLimit() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workflow_snapshot.json")
        let songs = (0..<1_000).map { index in
            ImportedSong(
                title: "歌曲 \(index)",
                artist: index.isMultiple(of: 3) ? "歌手甲" : "歌手乙",
                source: .plainText,
                rawText: "歌曲 \(index) - 歌手",
                confidence: index.isMultiple(of: 5) ? 0.72 : 0.96,
                versionTags: index.isMultiple(of: 7) ? ["Live"] : []
            )
        }
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "千首完整快照",
            songs: songs,
            parseConfidence: 0.91
        )
        let reviewSongs = songs.enumerated().map { index, song in
            WorkflowReviewSong(
                song: song,
                title: index.isMultiple(of: 11) ? "\(song.title)（已核对）" : nil,
                isDeleted: index.isMultiple(of: 37)
            )
        }
        let matchBasis = MatchBasis(
            playlistID: playlist.id,
            reviewRevision: 12,
            catalogRevision: "catalog-1000"
        )
        let matches = songs.map { song in
            MatchResult(
                importedSong: song,
                matchedTrack: makeTrack(
                    id: "track-\(song.id.uuidString)",
                    title: song.title,
                    artist: song.artist ?? "未知歌手"
                ),
                alternatives: [],
                status: .exact,
                confirmationState: .confirmed,
                score: 0.96,
                reason: "歌名和歌手一致"
            )
        }
        let analysis = CompletedPlaylistAnalysis(
            basis: matchBasis,
            matchRevision: 13,
            matches: matches,
            preferenceProfile: makePreferenceProfile()
        )
        let scenario = ScenarioConfig(scenario: .friends, peopleCount: 8, durationMinutes: 180)
        let plan = SongPlan(
            title: "千首歌单排歌",
            scenario: .friends,
            inputSource: .userImport,
            scenarioConfig: scenario,
            sections: []
        )
        let planBasis = PlanBasis(
            matchBasis: matchBasis,
            matchRevision: 13,
            scenarioFingerprint: "scenario-1000",
            voiceSource: .commonReference,
            voiceFingerprint: "voice-1000",
            feedbackRevision: 14,
            trackControlsRevision: 15,
            inputSource: .userImport,
            catalogRevision: "catalog-1000"
        )
        let externalCollection = ExternalCandidateCollection(
            basis: ExternalCandidateBasis(
                playlistID: playlist.id,
                reviewRevision: 12,
                requestRevision: 16
            ),
            candidates: (0..<16).map { index in
                ExternalSongCandidate(
                    title: "公开候选 \(index)",
                    artist: "候选歌手 \(index)",
                    source: index.isMultiple(of: 2) ? .iTunes : .lastFM,
                    confidence: 0.8
                )
            }
        )
        let revisions = WorkflowRevisionLedger(
            review: 12,
            match: 13,
            feedback: 14,
            trackControls: 15
        )
        let snapshot = WorkflowSnapshot(
            importedPlaylist: playlist,
            reviewSongs: reviewSongs,
            revisions: revisions,
            completedAnalysis: analysis,
            persistedPlanRecord: .ready(plan: plan, basis: planBasis),
            externalCandidateCollection: externalCollection,
            voiceProfile: nil,
            recommendationInputSource: .userImport,
            scenarioConfig: scenario,
            lockedTrackIDs: [matches[0].acceptedTrack!.id],
            removedTrackIDs: [matches[1].acceptedTrack!.id],
            feedbackProfile: SongFeedbackProfile(
                feedbackByTrackID: [matches[2].acceptedTrack!.id: [.liked]]
            )
        )

        let store = WorkflowSnapshotStore(url: url)
        try store.save(snapshot)
        let archiveData = try Data(contentsOf: url)
        let restored = try XCTUnwrap(store.load())

        XCTAssertLessThan(archiveData.count, 16 * 1_024 * 1_024)
        XCTAssertEqual(restored.importedPlaylist.songs.count, 1_000)
        XCTAssertEqual(restored.reviewSongs.count, 1_000)
        XCTAssertEqual(restored.completedAnalysis?.matches.count, 1_000)
        XCTAssertEqual(restored.revisions, revisions)
        guard case let .ready(restoredPlan, restoredBasis) = restored.persistedPlanRecord else {
            return XCTFail("千首快照的 ready 计划应完整恢复")
        }
        XCTAssertEqual(restoredPlan.id, plan.id)
        XCTAssertEqual(restoredBasis, planBasis)
        XCTAssertEqual(restored.externalCandidateCollection, externalCollection)
    }

    func testWorkflowSnapshotMigratesSchemaOneWithoutClaimingLegacyDerivationsAreReady() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workflow_snapshot.json")
        let song = ImportedSong(
            title: "晴天",
            artist: "周杰伦",
            source: .plainText,
            confidence: 0.92
        )
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "旧版快照",
            songs: [song],
            parseConfidence: 0.92
        )
        let track = makeTrack(id: "legacy-main", title: "晴天", artist: "周杰伦")
        let match = MatchResult(
            importedSong: song,
            matchedTrack: track,
            alternatives: [],
            status: .exact,
            confirmationState: .confirmed,
            score: 0.94,
            reason: "旧版匹配"
        )
        let preference = makePreferenceProfile()
        let plan = SongPlan(
            title: "旧版排歌",
            scenario: .friends,
            inputSource: .userImport,
            sections: []
        )
        let externalTrack = makeTrack(
            id: "legacy-external",
            title: "稻香",
            artist: "周杰伦",
            catalogSource: .externalSimilar
        )
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_123)
        let archive = LegacyWorkflowArchiveFixture(
            schemaVersion: 1,
            snapshot: LegacyWorkflowSnapshotFixture(
                importedPlaylist: playlist,
                reviewSongs: [WorkflowReviewSong(song: song)],
                matches: [match],
                preferenceProfile: preference,
                voiceProfile: nil,
                recommendationInputSource: .userImport,
                scenarioConfig: ScenarioConfig(scenario: .friends),
                songPlan: plan,
                lockedTrackIDs: [track.id],
                removedTrackIDs: [],
                externalCandidateTracks: [externalTrack],
                feedbackProfile: .empty,
                hasAdvancedToScenario: true,
                updatedAt: updatedAt
            )
        )
        try JSONEncoder().encode(archive).write(to: url)

        guard case let .loaded(restored) = try WorkflowSnapshotStore(url: url).loadWithStatus() else {
            return XCTFail("schema 1 应迁入 v2 壳，而不是隔离")
        }

        XCTAssertEqual(restored.revisions, WorkflowRevisionLedger())
        XCTAssertNil(restored.completedAnalysis)
        XCTAssertNil(restored.externalCandidateCollection)
        XCTAssertTrue(restored.matches.isEmpty)
        XCTAssertNil(restored.preferenceProfile)
        guard case let .stale(stalePlan)? = restored.persistedPlanRecord else {
            return XCTFail("schema 1 的旧计划缺少 basis，只能恢复为 stale")
        }
        XCTAssertEqual(stalePlan.plan.id, plan.id)
        XCTAssertNil(stalePlan.previousBasis)
        XCTAssertEqual(stalePlan.reason, "这份旧歌单需要按当前选择重新排一版")
        XCTAssertTrue(restored.externalCandidateTracks.isEmpty)
        XCTAssertEqual(restored.updatedAt, updatedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.contains(".corrupt-") || $0.contains(".incompatible-") }
        )
    }

    func testWorkflowSnapshotSchemaOneDefaultsMissingSongVersionTagsToEmpty() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workflow_snapshot.json")
        let song = ImportedSong(
            title: "旧版歌曲",
            artist: "旧版歌手",
            source: .plainText,
            confidence: 0.9,
            versionTags: ["Live"]
        )
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "旧版无版本标签",
            songs: [song],
            parseConfidence: 0.9
        )
        let archive = LegacyWorkflowArchiveFixture(
            schemaVersion: 1,
            snapshot: LegacyWorkflowSnapshotFixture(
                importedPlaylist: playlist,
                reviewSongs: [WorkflowReviewSong(song: song)],
                matches: [],
                preferenceProfile: nil,
                voiceProfile: nil,
                recommendationInputSource: .userImport,
                scenarioConfig: ScenarioConfig(),
                songPlan: nil,
                lockedTrackIDs: [],
                removedTrackIDs: [],
                externalCandidateTracks: [],
                feedbackProfile: .empty,
                hasAdvancedToScenario: false,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any]
        )
        var snapshot = try XCTUnwrap(root["snapshot"] as? [String: Any])
        var importedPlaylist = try XCTUnwrap(snapshot["importedPlaylist"] as? [String: Any])
        var importedSongs = try XCTUnwrap(importedPlaylist["songs"] as? [[String: Any]])
        importedSongs[0].removeValue(forKey: "versionTags")
        importedPlaylist["songs"] = importedSongs
        snapshot["importedPlaylist"] = importedPlaylist
        var reviewSongs = try XCTUnwrap(snapshot["reviewSongs"] as? [[String: Any]])
        reviewSongs[0].removeValue(forKey: "versionTags")
        snapshot["reviewSongs"] = reviewSongs
        root["snapshot"] = snapshot
        try JSONSerialization.data(withJSONObject: root).write(to: url, options: .atomic)

        guard case let .loaded(restored) = try WorkflowSnapshotStore(url: url).loadWithStatus() else {
            return XCTFail("缺少 versionTags 的 schema 1 快照应兼容恢复")
        }
        XCTAssertEqual(restored.importedPlaylist.songs.first?.versionTags, [])
        XCTAssertEqual(restored.reviewSongs.first?.versionTags, [])
    }

    func testWorkflowSnapshotV2DecodeDropsLegacyAnalysisWhenCommittedAnalysisExists() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workflow_snapshot.json")
        let song = ImportedSong(
            title: "晴天",
            artist: "周杰伦",
            source: .plainText,
            confidence: 0.95
        )
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "双状态防护",
            songs: [song],
            parseConfidence: 0.95
        )
        let legacyTrack = makeTrack(id: "legacy-track", title: "晴天", artist: "孙燕姿")
        let committedTrack = makeTrack(id: "committed-track", title: "晴天", artist: "周杰伦")
        let preference = makePreferenceProfile()
        let snapshot = WorkflowSnapshot(
            importedPlaylist: playlist,
            reviewSongs: [WorkflowReviewSong(song: song)],
            matches: [
                MatchResult(
                    importedSong: song,
                    matchedTrack: legacyTrack,
                    alternatives: [],
                    status: .fuzzy,
                    score: 0.7,
                    reason: "旧 bridge"
                )
            ],
            preferenceProfile: preference,
            voiceProfile: nil,
            recommendationInputSource: .userImport,
            scenarioConfig: ScenarioConfig(),
            songPlan: nil,
            lockedTrackIDs: [],
            removedTrackIDs: [],
            externalCandidateTracks: [],
            feedbackProfile: .empty
        )
        let store = WorkflowSnapshotStore(url: url)
        try store.save(snapshot)
        let basis = MatchBasis(
            playlistID: playlist.id,
            reviewRevision: 0,
            catalogRevision: "catalog-v2"
        )
        let analysis = CompletedPlaylistAnalysis(
            basis: basis,
            matchRevision: 1,
            matches: [
                MatchResult(
                    importedSong: song,
                    matchedTrack: committedTrack,
                    alternatives: [],
                    status: .exact,
                    confirmationState: .confirmed,
                    score: 0.98,
                    reason: "已提交分析"
                )
            ],
            preferenceProfile: preference
        )

        var archive = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var storedSnapshot = try XCTUnwrap(archive["snapshot"] as? [String: Any])
        storedSnapshot["completedAnalysis"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(analysis)
        )
        archive["snapshot"] = storedSnapshot
        try JSONSerialization.data(withJSONObject: archive).write(to: url, options: .atomic)

        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.matches.first?.matchedTrack?.id, committedTrack.id)
        try store.save(restored)

        let normalizedArchive = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let normalizedSnapshot = try XCTUnwrap(
            normalizedArchive["snapshot"] as? [String: Any]
        )
        XCTAssertNil(normalizedSnapshot["legacyDerivationBridge"])
    }

    private func makeTrack(
        id: String,
        title: String,
        artist: String,
        catalogSource: TrackCatalogSource = .ktvCatalog,
        metadata: ExternalCandidateMetadata? = nil
    ) -> KTVTrack {
        KTVTrack(
            id: id,
            title: title,
            artist: artist,
            language: "国语",
            era: "2000s",
            genre: "流行",
            moodTags: ["合唱"],
            sceneTags: ["friends"],
            difficulty: 3,
            vocalRangeLowMidi: 52,
            vocalRangeHighMidi: 68,
            energy: 0.72,
            singAlongScore: 0.88,
            ktvAvailability: 0.96,
            duetFriendly: false,
            rapDensity: 0.05,
            highNoteRisk: 0.22,
            aliases: [],
            similarSongIds: [],
            externalURL: URL(string: "https://music.apple.com/cn/song/example"),
            catalogSource: catalogSource,
            confidenceNote: catalogSource == .externalSimilar ? "KTV 收录待核对" : nil,
            externalCandidateMetadata: metadata
        )
    }

    private func makePreferenceProfile() -> PreferenceProfile {
        PreferenceProfile(
            topArtists: [("周杰伦", 1)],
            languageDistribution: ["国语": 1],
            eraDistribution: ["2000s": 1],
            genreDistribution: ["流行": 1],
            moodTags: ["合唱": 0.8],
            sceneAffinity: ["friends": 0.9],
            ktvMatchRate: 1,
            averageDifficulty: 3,
            averageSingAlongScore: 0.88,
            highNoteRisk: 0.2,
            chorusFriendliness: 0.9,
            scenarioFitScores: ["friends": 0.95],
            profileTags: ["华语流行"],
            summary: "偏爱华语流行"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sharedImageFiles(in directory: URL) throws -> [String] {
        let imageDirectory = directory.appendingPathComponent("shared-images", isDirectory: true)
        guard FileManager.default.fileExists(atPath: imageDirectory.path) else { return [] }
        let enumerator = FileManager.default.enumerator(
            at: imageDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        return try (enumerator?.allObjects as? [URL] ?? [])
            .filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
            .map { $0.path.replacingOccurrences(of: imageDirectory.path + "/", with: "") }
            .sorted()
    }

    #if canImport(CoreGraphics) && canImport(ImageIO) && canImport(UniformTypeIdentifiers)
    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "StoragePrivacyHardeningTests", code: 1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "StoragePrivacyHardeningTests", code: 2)
        }
    }
    #endif
}

private struct LegacyWorkflowArchiveFixture: Encodable {
    let schemaVersion: Int
    let snapshot: LegacyWorkflowSnapshotFixture
}

private struct LegacyWorkflowSnapshotFixture: Encodable {
    let importedPlaylist: ImportedPlaylist
    let reviewSongs: [WorkflowReviewSong]
    let matches: [MatchResult]
    let preferenceProfile: PreferenceProfile?
    let voiceProfile: VoiceProfile?
    let recommendationInputSource: RecommendationInputSource
    let scenarioConfig: ScenarioConfig
    let songPlan: SongPlan?
    let lockedTrackIDs: [String]
    let removedTrackIDs: [String]
    let externalCandidateTracks: [KTVTrack]
    let feedbackProfile: SongFeedbackProfile
    let hasAdvancedToScenario: Bool?
    let updatedAt: Date
}
