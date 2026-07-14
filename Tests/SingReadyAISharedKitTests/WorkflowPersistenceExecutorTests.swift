import XCTest
@testable import SingReadyAISharedKit

final class WorkflowPersistenceExecutorTests: XCTestCase {
    func testImportTextPreflightAcceptsExactCharacterAndPhysicalLineLimits() {
        XCTAssertTrue(PlaylistImportTextPreflight.accepts(String(repeating: "歌", count: 50_000)))
        let oneThousandPhysicalLines = Array(repeating: "歌", count: 1_000).joined(separator: "\n")
        XCTAssertTrue(PlaylistImportTextPreflight.accepts(oneThousandPhysicalLines))
    }

    func testImportTextPreflightRejectsCharacterOverflowAndCountsBlankPhysicalLines() {
        XCTAssertFalse(PlaylistImportTextPreflight.accepts(String(repeating: "歌", count: 50_001)))
        let oneThousandAndOnePhysicalLines = Array(repeating: "", count: 1_001).joined(separator: "\n")
        XCTAssertFalse(PlaylistImportTextPreflight.accepts(oneThousandAndOnePhysicalLines))
        let unicodeSeparatedLines = Array(repeating: "歌", count: 1_001).joined(separator: "\u{2028}")
        XCTAssertFalse(PlaylistImportTextPreflight.accepts(unicodeSeparatedLines))
        let windowsSeparatedLines = Array(repeating: "歌", count: 1_000).joined(separator: "\r\n")
        XCTAssertTrue(PlaylistImportTextPreflight.accepts(windowsSeparatedLines))
        XCTAssertEqual(
            PlaylistImportTextPreflight.limitMessage,
            "每次最多导入 5 万字、1000 行，请分成几份再试。"
        )
    }

    func testAtomicWorkflowCommitRejectsSnapshotSupersededBeforeLinearization() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotURL = directory.appendingPathComponent("workflow_snapshot.json")
        let snapshotStore = WorkflowSnapshotStore(url: snapshotURL)
        let stableSnapshot = makeSnapshot(title: "当前歌单 A")
        try snapshotStore.save(stableSnapshot)
        let executor = WorkflowPersistenceExecutor(
            recentPlaylistStore: RecentPlaylistStore(
                url: directory.appendingPathComponent("recent_playlists.json")
            ),
            workflowSnapshotStore: snapshotStore
        )

        await executor.reserveWorkflowMutation(generation: 1)
        await executor.reserveWorkflowMutation(generation: 2)
        let result = try await executor.commitWorkflowSnapshot(
            makeSnapshot(title: "迟到歌单 B"),
            generation: 1
        )

        guard case .superseded = result else {
            return XCTFail("被更新预约取代的候选不能写盘")
        }
        XCTAssertEqual(try snapshotStore.load()?.importedPlaylist.title, "当前歌单 A")
    }

    func testAtomicWorkflowCommitPublishesOnlyLatestReservedCandidate() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotURL = directory.appendingPathComponent("workflow_snapshot.json")
        let snapshotStore = WorkflowSnapshotStore(url: snapshotURL)
        try snapshotStore.save(makeSnapshot(title: "当前歌单 A"))
        let executor = WorkflowPersistenceExecutor(
            recentPlaylistStore: RecentPlaylistStore(
                url: directory.appendingPathComponent("recent_playlists.json")
            ),
            workflowSnapshotStore: snapshotStore
        )

        await executor.reserveWorkflowMutation(generation: 10)
        await executor.reserveWorkflowMutation(generation: 11)
        let staleResult = try await executor.commitWorkflowSnapshot(
            makeSnapshot(title: "旧候选 B"),
            generation: 10
        )
        let currentResult = try await executor.commitWorkflowSnapshot(
            makeSnapshot(title: "新候选 C"),
            generation: 11
        )

        guard case .superseded = staleResult else {
            return XCTFail("B 应被 C 的预约取代")
        }
        guard case .applied = currentResult else {
            return XCTFail("当前预约的 C 应完成提交")
        }
        XCTAssertEqual(try snapshotStore.load()?.importedPlaylist.title, "新候选 C")
    }

    func testMatchCancellationReservationSupersedesAnalysisBeforeCommitStarts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotURL = directory.appendingPathComponent("workflow_snapshot.json")
        let snapshotStore = WorkflowSnapshotStore(url: snapshotURL)
        try snapshotStore.save(makeSnapshot(title: "稳定分析 A"))
        let executor = WorkflowPersistenceExecutor(
            recentPlaylistStore: RecentPlaylistStore(
                url: directory.appendingPathComponent("recent_playlists.json")
            ),
            workflowSnapshotStore: snapshotStore
        )

        await executor.reserveWorkflowMutation(generation: 20)
        await executor.reserveWorkflowMutation(generation: 21)
        let result = try await executor.commitWorkflowSnapshot(
            makeSnapshot(title: "已取消的分析 B"),
            generation: 20
        )

        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(try snapshotStore.load()?.importedPlaylist.title, "稳定分析 A")
    }

    func testAppliedAnalysisRemainsAuthoritativeWhenCancellationArrivesAfterLinearization() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotURL = directory.appendingPathComponent("workflow_snapshot.json")
        let commitStarted = expectation(description: "analysis commit entered actor")
        let allowCommitToFinish = DispatchSemaphore(value: 0)
        let executor = WorkflowPersistenceExecutor(
            recentPlaylistStore: RecentPlaylistStore(
                url: directory.appendingPathComponent("recent_playlists.json")
            ),
            workflowSnapshotStore: WorkflowSnapshotStore(url: snapshotURL),
            beforeOperation: { operation in
                guard operation == .saveWorkflowSnapshot else { return }
                commitStarted.fulfill()
                _ = allowCommitToFinish.wait(timeout: .now() + 1)
            }
        )

        await executor.reserveWorkflowMutation(generation: 30)
        let commitTask = Task {
            try await executor.commitWorkflowSnapshot(
                makeSnapshot(title: "已线性提交的分析 B"),
                generation: 30
            )
        }
        await fulfillment(of: [commitStarted], timeout: 1)
        let cancellationTask = Task {
            await executor.reserveWorkflowMutation(generation: 31)
        }
        allowCommitToFinish.signal()

        let commitResult = try await commitTask.value
        XCTAssertEqual(commitResult, .applied)
        await cancellationTask.value
        XCTAssertEqual(
            try WorkflowSnapshotStore(url: snapshotURL).load()?.importedPlaylist.title,
            "已线性提交的分析 B"
        )
    }

    func testAtomicWorkflowCommitFailureKeepsPreviousStableSnapshot() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotURL = directory.appendingPathComponent("workflow_snapshot.json")
        let snapshotStore = WorkflowSnapshotStore(url: snapshotURL)
        try snapshotStore.save(makeSnapshot(title: "当前歌单 A"))
        let executor = WorkflowPersistenceExecutor(
            recentPlaylistStore: RecentPlaylistStore(
                url: directory.appendingPathComponent("recent_playlists.json")
            ),
            workflowSnapshotStore: snapshotStore
        )
        let invalidSnapshot = makeSnapshot(
            title: "无法编码的 B",
            voiceProfile: VoiceProfile(
                type: .unknown,
                minMidi: 48,
                maxMidi: 72,
                stableLowMidi: 52,
                stableHighMidi: 68,
                averageMidi: .nan,
                confidence: 0.8,
                note: "非法浮点用于验证原子保存"
            )
        )

        await executor.reserveWorkflowMutation(generation: 1)
        do {
            _ = try await executor.commitWorkflowSnapshot(invalidSnapshot, generation: 1)
            XCTFail("非法快照应保存失败")
        } catch {}

        XCTAssertEqual(try snapshotStore.load()?.importedPlaylist.title, "当前歌单 A")
    }

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

    func testPersistedPlanRecordMapsOnlyCompletedPlanOrPreviousSnapshot() throws {
        let playlistID = UUID()
        let plan = makePlan(title: "已完成歌单")
        let basis = makePlanBasis(playlistID: playlistID)
        let previous = StalePlanSnapshot(
            plan: plan,
            previousBasis: basis,
            reason: "场景已更新"
        )

        XCTAssertNil(PersistedPlanRecord(planGenerationState: .absent))
        XCTAssertNil(
            PersistedPlanRecord(
                planGenerationState: .generating(basis: basis, previous: nil)
            )
        )
        XCTAssertNil(
            PersistedPlanRecord(
                planGenerationState: .failed(message: "生成失败", retryable: true, previous: nil)
            )
        )

        guard case let .ready(readyPlan, readyBasis) = PersistedPlanRecord(
            planGenerationState: .ready(plan: plan, basis: basis)
        ) else {
            return XCTFail("ready 状态应保存为 ready 记录")
        }
        XCTAssertEqual(readyPlan.id, plan.id)
        XCTAssertEqual(readyBasis, basis)

        for transientState in [
            PlanGenerationState.generating(basis: basis, previous: previous),
            PlanGenerationState.failed(message: "生成失败", retryable: true, previous: previous)
        ] {
            guard case let .stale(stale) = PersistedPlanRecord(
                planGenerationState: transientState
            ) else {
                return XCTFail("携带上一版计划的临时状态只能保存 stale 记录")
            }
            XCTAssertEqual(stale.plan.id, plan.id)
            XCTAssertEqual(stale.previousBasis, basis)
            XCTAssertEqual(stale.reason, "场景已更新")
        }

        let staleRecord = try XCTUnwrap(
            PersistedPlanRecord(planGenerationState: .stale(previous))
        )
        guard case let .stale(restored) = staleRecord.restoredPlanGenerationState else {
            return XCTFail("持久化计划只能恢复为 absent、ready 或 stale")
        }
        XCTAssertEqual(restored.plan.id, plan.id)
        XCTAssertEqual(restored.previousBasis, basis)
        XCTAssertEqual(restored.reason, previous.reason)
    }

    func testPersistedPlanRecordUsesStableExplicitCodingShape() throws {
        let plan = makePlan(title: "稳定编码歌单")
        let basis = makePlanBasis(playlistID: UUID())
        let records: [PersistedPlanRecord] = [
            .ready(plan: plan, basis: basis),
            .stale(
                StalePlanSnapshot(
                    plan: plan,
                    previousBasis: basis,
                    reason: "音区已更新"
                )
            )
        ]

        for (record, expectedKind) in zip(records, ["ready", "stale"]) {
            let data = try JSONEncoder().encode(record)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(Set(object.keys), Set(["kind", "plan", "basis", "reason"]))
            XCTAssertEqual(object["kind"] as? String, expectedKind)

            let decoded = try JSONDecoder().decode(PersistedPlanRecord.self, from: data)
            switch (record, decoded) {
            case let (.ready(expectedPlan, expectedBasis), .ready(actualPlan, actualBasis)):
                XCTAssertEqual(actualPlan.id, expectedPlan.id)
                XCTAssertEqual(actualBasis, expectedBasis)
            case let (.stale(expected), .stale(actual)):
                XCTAssertEqual(actual.plan.id, expected.plan.id)
                XCTAssertEqual(actual.previousBasis, expected.previousBasis)
                XCTAssertEqual(actual.reason, expected.reason)
            default:
                XCTFail("计划记录 kind 不应在回环后改变")
            }
        }
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

    private func makeSnapshot(
        title: String,
        voiceProfile: VoiceProfile? = nil
    ) -> WorkflowSnapshot {
        let playlist = makePlaylist(title: title)
        return WorkflowSnapshot(
            importedPlaylist: playlist,
            reviewSongs: playlist.songs.map { WorkflowReviewSong(song: $0) },
            matches: [],
            preferenceProfile: nil,
            voiceProfile: voiceProfile,
            recommendationInputSource: .userImport,
            scenarioConfig: ScenarioConfig(),
            songPlan: nil,
            lockedTrackIDs: [],
            removedTrackIDs: [],
            externalCandidateTracks: [],
            feedbackProfile: .empty
        )
    }

    private func makePlan(title: String) -> SongPlan {
        SongPlan(
            title: title,
            scenario: .friends,
            inputSource: .userImport,
            sections: []
        )
    }

    private func makePlanBasis(playlistID: UUID) -> PlanBasis {
        let matchBasis = MatchBasis(
            playlistID: playlistID,
            reviewRevision: 1,
            catalogRevision: "catalog-v2"
        )
        return PlanBasis(
            matchBasis: matchBasis,
            matchRevision: 2,
            scenarioFingerprint: "scenario-v2",
            voiceSource: .commonReference,
            voiceFingerprint: "voice-v2",
            feedbackRevision: 3,
            trackControlsRevision: 4,
            catalogRevision: "catalog-v2"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
