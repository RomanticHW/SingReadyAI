import XCTest
@testable import SingReadyAISharedKit

final class VoiceProfileStoreTests: XCTestCase {
    func testRestorePolicyPrefersNewerStandaloneMeasurementOverSnapshot() {
        let snapshot = makeMeasuredProfile(createdAt: Date(timeIntervalSince1970: 100))
        var standalone = makeMeasuredProfile(createdAt: Date(timeIntervalSince1970: 200))
        standalone.stableLowMidi = 55
        standalone.stableHighMidi = 72

        XCTAssertEqual(
            VoiceProfileRestorePolicy.preferred(
                current: snapshot,
                standalone: standalone
            ),
            standalone
        )
    }

    func testRestorePolicyKeepsNewerSnapshotMeasurement() {
        let snapshot = makeMeasuredProfile(createdAt: Date(timeIntervalSince1970: 200))
        var standalone = makeMeasuredProfile(createdAt: Date(timeIntervalSince1970: 100))
        standalone.stableLowMidi = 55
        standalone.stableHighMidi = 72

        XCTAssertEqual(
            VoiceProfileRestorePolicy.preferred(
                current: snapshot,
                standalone: standalone
            ),
            snapshot
        )
    }

    func testRestorePolicyUsesStandaloneMeasurementInsteadOfCommonReference() {
        XCTAssertEqual(
            VoiceProfileRestorePolicy.preferred(
                current: .simulatedMiddle,
                standalone: makeMeasuredProfile()
            ),
            makeMeasuredProfile()
        )
    }

    func testRestorePolicyMigratesValidSnapshotWhenStandaloneFileIsMissing() {
        let snapshot = makeMeasuredProfile()

        XCTAssertEqual(
            VoiceProfileRestorePolicy.standaloneMigrationCandidate(current: snapshot),
            snapshot
        )
        XCTAssertNil(
            VoiceProfileRestorePolicy.standaloneMigrationCandidate(current: .simulatedMiddle),
            "常见范围不能被迁移成用户个人实测"
        )
        XCTAssertNil(
            VoiceProfileRestorePolicy.standaloneMigrationCandidate(current: nil)
        )
    }

    func testValidMeasuredProfileRoundTrips() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceProfileStore(url: directory.appendingPathComponent("voice_profile.json"))
        let profile = makeMeasuredProfile()

        let didSave = try await store.saveIfEligible(profile)
        XCTAssertTrue(didSave)

        guard case let .loaded(restored) = try await store.loadWithStatus() else {
            return XCTFail("有效实测音域应能恢复")
        }
        XCTAssertEqual(restored, profile)
    }

    func testCommonReferenceIsNotPersistedAsPersonalMeasurement() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("voice_profile.json")
        let store = VoiceProfileStore(url: url)

        let didSave = try await store.saveIfEligible(.simulatedMiddle)
        XCTAssertFalse(didSave)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        guard case .missing = try await store.loadWithStatus() else {
            return XCTFail("常见参考不应产生个人实测记录")
        }
    }

    func testInvalidMeasuredProfileIsNotPersisted() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("voice_profile.json")
        let store = VoiceProfileStore(url: url)
        var profile = makeMeasuredProfile()
        profile.confidence = 0.2

        let didSave = try await store.saveIfEligible(profile)
        XCTAssertFalse(didSave)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCorruptAndFutureArchivesAreQuarantinedSeparately() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("voice_profile.json")
        let store = VoiceProfileStore(url: url)

        try Data("not-json".utf8).write(to: url)
        guard case .quarantined(.corrupt) = try await store.loadWithStatus() else {
            return XCTFail("损坏记录应被隔离")
        }

        try Data(#"{"schemaVersion":999,"profile":{}}"#.utf8).write(to: url)
        guard case .quarantined(.incompatibleVersion) = try await store.loadWithStatus() else {
            return XCTFail("未来版本应被隔离")
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("voice_profile.corrupt-") })
        XCTAssertTrue(names.contains { $0.hasPrefix("voice_profile.incompatible-") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOversizedArchiveIsQuarantinedBeforeDecoding() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("voice_profile.json")
        let store = VoiceProfileStore(url: url)
        try Data(repeating: 0, count: 256 * 1_024 + 1).write(to: url)

        guard case .quarantined(.oversized) = try await store.loadWithStatus() else {
            return XCTFail("超过 256 KB 的音域归档应在解码前被隔离")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix("voice_profile.oversized-") }
        )
    }

    func testClearRemovesCurrentAndQuarantinedVoiceProfileFiles() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("voice_profile.json")
        let store = VoiceProfileStore(url: url)

        _ = try await store.saveIfEligible(makeMeasuredProfile())
        try Data("bad".utf8).write(
            to: directory.appendingPathComponent("voice_profile.corrupt-fixture.json")
        )
        try Data("future".utf8).write(
            to: directory.appendingPathComponent("voice_profile.incompatible-fixture.json")
        )
        try Data("oversized".utf8).write(
            to: directory.appendingPathComponent("voice_profile.oversized-fixture.json")
        )

        try await store.clear()

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testClearInvalidationPreventsDelayedMeasurementRollbackFromRecreatingFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceProfileStore(url: directory.appendingPathComponent("voice_profile.json"))
        let checkpoint = AsyncCheckpoint()
        var requestGate = VoiceProfilePersistenceRequestGate()
        let request = requestGate.begin()
        let previousProfile = makeMeasuredProfile()
        var newProfile = previousProfile
        newProfile.stableLowMidi = 54
        newProfile.stableHighMidi = 71

        let delayedCompletion = Task {
            _ = try await store.saveIfEligible(newProfile)
            await checkpoint.pause()
        }
        await checkpoint.waitUntilPaused()

        requestGate.invalidate()
        try await store.clear()
        await checkpoint.resume()
        try await delayedCompletion.value
        if requestGate.accepts(request) {
            _ = try await store.saveIfEligible(previousProfile)
        }

        guard case .missing = try await store.loadWithStatus() else {
            return XCTFail("清除完成后，失效测量不能回写旧音域")
        }
    }

    private func makeMeasuredProfile(
        createdAt: Date = Date(timeIntervalSince1970: 1_720_000_000)
    ) -> VoiceProfile {
        VoiceProfile(
            type: .unknown,
            minMidi: 48,
            maxMidi: 72,
            stableLowMidi: 52,
            stableHighMidi: 69,
            averageMidi: 60.5,
            confidence: 0.72,
            note: "这是本次唱到的音区，仅作排歌参考，不代表完整音域。",
            source: .measured,
            suitableSongTypes: ["旋律线平稳"],
            avoidSongTypes: ["连续高强度"],
            singingStrategy: ["先用中音区热身"],
            createdAt: createdAt
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor AsyncCheckpoint {
    private var isPaused = false
    private var isReleased = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        isPaused = true
        pauseWaiters.forEach { $0.resume() }
        pauseWaiters.removeAll()
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func resume() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
