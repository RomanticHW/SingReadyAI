import XCTest
@testable import SingReadyAISharedKit

final class WorkflowPersistenceExecutorTests: XCTestCase {
    @MainActor
    func testSlowRecentPlaylistLoadKeepsMainActorResponsive() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let operationStarted = expectation(description: "recent playlist load started")
        let mainActorHeartbeat = expectation(description: "main actor stays responsive")
        let allowOperationToFinish = DispatchSemaphore(value: 0)
        let executor = WorkflowPersistenceExecutor(
            recentPlaylistStore: RecentPlaylistStore(
                url: directory.appendingPathComponent("recent_playlists.json")
            ),
            workflowSnapshotStore: WorkflowSnapshotStore(
                url: directory.appendingPathComponent("workflow_snapshot.json")
            ),
            beforeOperation: { operation in
                guard operation == .loadRecentPlaylists else { return }
                operationStarted.fulfill()
                _ = allowOperationToFinish.wait(timeout: .now() + 1)
            }
        )

        let loadTask = Task { @MainActor in
            try await executor.loadRecentPlaylists(request: 1)
        }
        await fulfillment(of: [operationStarted], timeout: 1)

        Task { @MainActor in
            mainActorHeartbeat.fulfill()
        }
        await fulfillment(of: [mainActorHeartbeat], timeout: 0.1)
        allowOperationToFinish.signal()

        guard case let .applied(loadResult) = try await loadTask.value,
              case .missing = loadResult else {
            return XCTFail("空存储应返回已执行的 missing 状态")
        }
    }

    func testRecentPlaylistClearRunsAfterInFlightRecordAndLeavesStoreEmpty() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recentURL = directory.appendingPathComponent("recent_playlists.json")
        let recordStarted = expectation(description: "recent playlist record started")
        let allowRecordToFinish = DispatchSemaphore(value: 0)
        let executor = WorkflowPersistenceExecutor(
            recentPlaylistStore: RecentPlaylistStore(url: recentURL),
            workflowSnapshotStore: WorkflowSnapshotStore(
                url: directory.appendingPathComponent("workflow_snapshot.json")
            ),
            beforeOperation: { operation in
                guard operation == .recordRecentPlaylist else { return }
                recordStarted.fulfill()
                _ = allowRecordToFinish.wait(timeout: .now() + 1)
            }
        )

        let recordTask = Task {
            try await executor.recordRecentPlaylist(makePlaylist(title: "旧歌单"), request: 1)
        }
        await fulfillment(of: [recordStarted], timeout: 1)
        let clearTask = Task {
            try await executor.clearRecentPlaylists(request: 2)
        }
        allowRecordToFinish.signal()

        _ = try await recordTask.value
        _ = try await clearTask.value
        XCTAssertEqual(try RecentPlaylistStore(url: recentURL).load().count, 0)
    }

    func testWorkflowSnapshotSaveOlderThanClearGenerationIsRejected() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotURL = directory.appendingPathComponent("workflow_snapshot.json")
        let executor = WorkflowPersistenceExecutor(
            recentPlaylistStore: RecentPlaylistStore(
                url: directory.appendingPathComponent("recent_playlists.json")
            ),
            workflowSnapshotStore: WorkflowSnapshotStore(url: snapshotURL)
        )

        _ = try await executor.clearWorkflowSnapshot(request: 2)
        let staleSave = try await executor.saveWorkflowSnapshot(
            makeSnapshot(title: "不应复活"),
            request: 1
        )

        guard case .rejectedStaleRequest = staleSave else {
            return XCTFail("clear 之后到达的旧保存必须被拒绝")
        }
        XCTAssertNil(try WorkflowSnapshotStore(url: snapshotURL).load())
    }

    func testPersistenceRequestGateRejectsResultAfterInvalidation() {
        var gate = WorkflowPersistenceRequestGate()
        let startupRestore = gate.begin()

        gate.invalidate()

        XCTAssertFalse(gate.accepts(startupRestore))
        let currentRequest = gate.begin()
        XCTAssertTrue(gate.accepts(currentRequest))
    }

    func testArtifactCleanerCanClearTemporaryArtifactsWithoutBypassingPersistenceExecutor() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recentURL = directory.appendingPathComponent("recent_playlists.json")
        let snapshotURL = directory.appendingPathComponent("workflow_snapshot.json")
        let ocrDirectory = directory.appendingPathComponent("ocr", isDirectory: true)
        let exportDirectory = directory.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: ocrDirectory, withIntermediateDirectories: true)
        let ocrFile = ocrDirectory.appendingPathComponent("singready-ocr-old.png")
        try Data("temporary".utf8).write(to: ocrFile)
        let playlist = makePlaylist(title: "保留的最近导入")
        try RecentPlaylistStore(url: recentURL).record(playlist)
        try WorkflowSnapshotStore(url: snapshotURL).save(makeSnapshot(title: "保留的进度"))
        let exportStore = TemporaryExportFileStore(directory: exportDirectory)
        _ = try exportStore.materialize(
            PlaylistTextFilePayload(fileName: "今晚歌单.txt", contents: "测试")
        )

        let result = await LocalArtifactCleaner(
            ocrTemporaryFileStore: OCRTemporaryFileStore(directory: ocrDirectory),
            temporaryExportFileStore: exportStore
        ).clear()

        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ocrFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportDirectory.path))
        XCTAssertEqual(try RecentPlaylistStore(url: recentURL).load().map(\.id), [playlist.id])
        XCTAssertNotNil(try WorkflowSnapshotStore(url: snapshotURL).load())
    }

    private func makePlaylist(title: String) -> ImportedPlaylist {
        ImportedPlaylist(
            source: .plainText,
            title: title,
            songs: [
                ImportedSong(
                    title: "晴天",
                    artist: "周杰伦",
                    source: .plainText,
                    confidence: 0.95
                )
            ],
            parseConfidence: 0.95
        )
    }

    private func makeSnapshot(title: String) -> WorkflowSnapshot {
        let playlist = makePlaylist(title: title)
        return WorkflowSnapshot(
            importedPlaylist: playlist,
            reviewSongs: playlist.songs.map { WorkflowReviewSong(song: $0) },
            matches: [],
            preferenceProfile: nil,
            voiceProfile: nil,
            recommendationInputSource: .userImport,
            scenarioConfig: ScenarioConfig(),
            songPlan: nil,
            lockedTrackIDs: [],
            removedTrackIDs: [],
            externalCandidateTracks: [],
            feedbackProfile: .empty
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
