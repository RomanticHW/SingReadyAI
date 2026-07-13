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
        try Data(repeating: 0, count: 16 * 1_024 * 1_024 + 1).write(to: url)

        guard case .quarantined(.oversized) = try store.loadWithStatus() else {
            return XCTFail("超过 16 MB 的工作流快照应在解码前被隔离")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix("workflow_snapshot.oversized-") }
        )
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

    func testWorkflowSnapshotRoundTripsNonEmptyRecommendationState() throws {
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

        XCTAssertEqual(try canonicalJSON(restored), try canonicalJSON(snapshot))
        XCTAssertEqual(restored.importedPlaylist.externalURL, playlist.externalURL)
        XCTAssertEqual(restored.reviewSongs.first?.versionTags, ["Live"])
        XCTAssertEqual(restored.matches.first?.matchedTrack?.id, localTrack.id)
        XCTAssertEqual(restored.matches.first?.alternatives.first?.id, alternative.id)
        XCTAssertEqual(restored.matches.first?.confirmationState, .confirmed)
        XCTAssertEqual(restored.preferenceProfile?.topArtists.first?.name, "周杰伦")
        XCTAssertEqual(restored.preferenceProfile?.scenarioFitScores["friends"], 0.95)
        XCTAssertEqual(restored.voiceProfile, voice)
        XCTAssertEqual(restored.songPlan?.id, plan.id)
        XCTAssertEqual(restored.songPlan?.scenarioConfig, scenario)
        XCTAssertEqual(restored.songPlan?.voiceProfile, voice)
        XCTAssertEqual(restored.songPlan?.sections.first?.role, .warmup)
        XCTAssertEqual(restored.songPlan?.sections.first?.items.first?.track.id, localTrack.id)
        XCTAssertEqual(restored.songPlan?.sections.first?.items.first?.scoreBreakdown, breakdown)
        XCTAssertEqual(restored.songPlan?.sections.first?.items.first?.singingAdvice?.semitoneShift, -2)
        XCTAssertEqual(restored.songPlan?.sections.first?.items.first?.feedbackTags, [.liked, .sung])
        XCTAssertEqual(restored.externalCandidateTracks.first?.catalogSource, .externalSimilar)
        XCTAssertEqual(restored.externalCandidateTracks.first?.externalCandidateMetadata, externalTrack.externalCandidateMetadata)
        XCTAssertEqual(restored.lockedTrackIDs, [localTrack.id])
        XCTAssertEqual(restored.removedTrackIDs, [alternative.id])
        XCTAssertEqual(Set(restored.feedbackProfile.feedback(for: localTrack.id)), Set([.liked, .sung]))
        XCTAssertEqual(restored.updatedAt, snapshot.updatedAt)
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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func canonicalJSON<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
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
