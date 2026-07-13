import Foundation
import XCTest
@testable import SingReadyAISharedKit

final class AppGroupStoreTests: XCTestCase {
    func testPendingImportPersistenceRequiresAtLeastOneRecoverableWrite() {
        XCTAssertFalse(
            PendingImportPersistenceReceipt(
                didSaveRecentPlaylist: false,
                didSaveWorkflowSnapshot: false
            ).canConsumePendingImport
        )
        XCTAssertTrue(
            PendingImportPersistenceReceipt(
                didSaveRecentPlaylist: true,
                didSaveWorkflowSnapshot: false
            ).canConsumePendingImport
        )
        XCTAssertTrue(
            PendingImportPersistenceReceipt(
                didSaveRecentPlaylist: false,
                didSaveWorkflowSnapshot: true
            ).canConsumePendingImport
        )
    }

    func testSharedImageURLRejectsReferencesOutsideCommittedImageBoundary() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        )
        let invalidPaths = [
            "../outside.png",
            "shared-images/../../outside.png",
            "/tmp/outside.png",
            "shared-images/.staging/queued.png",
            "shared-images"
        ]

        for path in invalidPaths {
            let payload = PendingImportPayload(
                sourceHint: .screenshot,
                imageFileName: path
            )
            XCTAssertThrowsError(try store.sharedImageURL(for: payload), path) { error in
                XCTAssertEqual(error as? AppGroupStoreError, .invalidSharedImageReference, path)
            }
        }
    }

    func testSharedImageURLResolvesCommittedDirectChild() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageDirectory = directory.appendingPathComponent("shared-images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let imageURL = imageDirectory.appendingPathComponent("playlist.png")
        try writeTinyPNG(to: imageURL)
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        )
        let payload = PendingImportPayload(
            sourceHint: .screenshot,
            imageFileName: "shared-images/playlist.png"
        )

        XCTAssertEqual(
            try store.sharedImageURL(for: payload).standardizedFileURL,
            imageURL.standardizedFileURL
        )
    }

    func testSharedImageURLRejectsSymlinkedImageDirectoryEscape() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outsideDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("shared-images", isDirectory: true),
            withDestinationURL: outsideDirectory
        )
        let outsideImage = outsideDirectory.appendingPathComponent("playlist.png")
        try writeTinyPNG(to: outsideImage)
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        )
        let payload = PendingImportPayload(
            sourceHint: .screenshot,
            imageFileName: "shared-images/playlist.png"
        )

        XCTAssertThrowsError(try store.sharedImageURL(for: payload)) { error in
            XCTAssertEqual(error as? AppGroupStoreError, .invalidSharedImageReference)
        }
    }

    func testSharedImageURLRejectsSymlinkedFinalImageInsideStore() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageDirectory = directory.appendingPathComponent("shared-images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let targetURL = imageDirectory.appendingPathComponent("target.png")
        try writeTinyPNG(to: targetURL)
        let linkedURL = imageDirectory.appendingPathComponent("playlist.png")
        try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: targetURL)
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        )
        let payload = PendingImportPayload(
            sourceHint: .screenshot,
            imageFileName: "shared-images/playlist.png"
        )

        XCTAssertThrowsError(try store.sharedImageURL(for: payload)) { error in
            XCTAssertEqual(error as? AppGroupStoreError, .invalidSharedImageReference)
        }
    }

    func testConcurrentPendingImportSavesDoNotLoseReadModifyWriteUpdates() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payloads = (0..<20).map { index in
            PendingImportPayload(
                sourceHint: .plainText,
                rawText: "歌曲 \(index) - 歌手"
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for payload in payloads {
                group.addTask {
                    let store = AppGroupStore(
                        appGroupIdentifier: "missing.group",
                        fallbackDirectory: directory
                    )
                    try store.savePendingImport(payload)
                }
            }
            try await group.waitForAll()
        }

        let restored = try AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        ).loadPendingImports()
        XCTAssertEqual(restored.count, payloads.count)
        XCTAssertEqual(Set(restored.map(\.id)), Set(payloads.map(\.id)))
    }

    func testExpiredDeadlineRejectsAsyncCommitWithoutWriting() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        )
        let payload = PendingImportPayload(sourceHint: .plainText, rawText: "晴天 - 周杰伦")
        let expiredDeadline = MonotonicOperationDeadline(timeoutNanoseconds: 0)

        do {
            _ = try await store.commitPendingImport(payload, deadline: expiredDeadline)
            XCTFail("已过期的绝对 deadline 不应写入")
        } catch let error as AppGroupStoreError {
            XCTAssertEqual(error, .operationTimedOut)
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }

        XCTAssertEqual(try store.loadPendingImports(), [])
    }

    func testDeadlineExpiringAfterQueueWriteRollsBackPayloadAndFinalImage() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("playlist.png")
        try writeTinyPNG(to: sourceURL)
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory,
            afterPendingImportWrite: {
                Thread.sleep(forTimeInterval: 0.08)
            }
        )
        let stagedImage = try store.stageSharedImage(from: sourceURL)
        let payload = PendingImportPayload(
            sourceHint: .screenshot,
            imageFileName: stagedImage.relativePath
        )

        do {
            _ = try await store.commitPendingImport(
                payload,
                stagedImage: stagedImage,
                deadline: MonotonicOperationDeadline(timeoutNanoseconds: 20_000_000)
            )
            XCTFail("写入后 deadline 到期时不应留下迟到队列项")
        } catch let error as AppGroupStoreError {
            XCTAssertEqual(error, .operationTimedOut)
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }

        XCTAssertEqual(try store.loadPendingImports(), [])
        XCTAssertEqual(try sharedImageFiles(in: directory), [])
    }

    func testCancellationAfterQueueWriteRollsBackBeforeReleasingLock() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let afterWriteStarted = DispatchSemaphore(value: 0)
        let allowWriteCheck = DispatchSemaphore(value: 0)
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory,
            afterPendingImportWrite: {
                afterWriteStarted.signal()
                _ = allowWriteCheck.wait(timeout: .now() + 1)
            }
        )
        let payload = PendingImportPayload(sourceHint: .plainText, rawText: "晴天 - 周杰伦")
        let task = Task {
            try await store.commitPendingImport(
                payload,
                deadline: MonotonicOperationDeadline(timeoutNanoseconds: 5_000_000_000)
            )
        }
        XCTAssertEqual(afterWriteStarted.wait(timeout: .now() + 1), .success)

        task.cancel()
        allowWriteCheck.signal()

        do {
            _ = try await task.value
            XCTFail("最终写入后收到取消时不应发布队列项")
        } catch is CancellationError {
            // 写入后的取消必须在释放跨进程锁前完成回滚。
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }
        XCTAssertEqual(try store.loadPendingImports(), [])
    }

    #if os(macOS)
    func testAsyncCommitTimesOutWithoutLateWriteWhileAnotherProcessHoldsLock() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("pending_imports.lock")
        let lockHolder = try startExternalLockHolder(at: lockURL)
        defer {
            if lockHolder.isRunning {
                lockHolder.terminate()
                lockHolder.waitUntilExit()
            }
        }
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        )
        let payload = PendingImportPayload(sourceHint: .plainText, rawText: "晴天 - 周杰伦")
        let startedAt = Date()

        do {
            _ = try await store.commitPendingImport(
                payload,
                deadline: MonotonicOperationDeadline(timeoutNanoseconds: 50_000_000)
            )
            XCTFail("跨进程锁被占用时应在绝对 deadline 结束")
        } catch let error as AppGroupStoreError {
            XCTAssertEqual(error, .operationTimedOut)
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        lockHolder.terminate()
        lockHolder.waitUntilExit()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(try store.loadPendingImports(), [])
    }

    func testSynchronousAccessUsesBoundedNonblockingLockRetry() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockHolder = try startExternalLockHolder(
            at: directory.appendingPathComponent("pending_imports.lock")
        )
        defer {
            if lockHolder.isRunning {
                lockHolder.terminate()
                lockHolder.waitUntilExit()
            }
        }
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        )
        let startedAt = Date()

        XCTAssertThrowsError(try store.loadPendingImports()) { error in
            XCTAssertEqual(error as? AppGroupStoreError, .operationTimedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
    }

    func testCancellingAsyncCommitStopsLockRetryWithoutLateWrite() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockHolder = try startExternalLockHolder(
            at: directory.appendingPathComponent("pending_imports.lock")
        )
        defer {
            if lockHolder.isRunning {
                lockHolder.terminate()
                lockHolder.waitUntilExit()
            }
        }
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        )
        let payload = PendingImportPayload(sourceHint: .plainText, rawText: "晴天 - 周杰伦")
        let task = Task {
            try await store.commitPendingImport(
                payload,
                deadline: MonotonicOperationDeadline(timeoutNanoseconds: 5_000_000_000)
            )
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        let cancelledAt = Date()

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("取消后不应继续等待跨进程锁")
        } catch is CancellationError {
            // 取消必须终止非阻塞重试。
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 0.3)
        lockHolder.terminate()
        lockHolder.waitUntilExit()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(try store.loadPendingImports(), [])
    }

    @MainActor
    func testAsyncRemovalKeepsMainActorResponsiveWhileAnotherProcessHoldsLock() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        )
        let payload = PendingImportPayload(sourceHint: .plainText, rawText: "晴天 - 周杰伦")
        try store.savePendingImport(payload)
        let lockHolder = try startExternalLockHolder(
            at: directory.appendingPathComponent("pending_imports.lock")
        )
        defer {
            if lockHolder.isRunning {
                lockHolder.terminate()
                lockHolder.waitUntilExit()
            }
        }
        let mainActorHeartbeat = expectation(description: "main actor stays responsive")
        let removalTask = Task { @MainActor in
            try await store.removePendingImport(
                id: payload.id,
                deadline: MonotonicOperationDeadline(timeoutNanoseconds: 250_000_000)
            )
        }
        Task { @MainActor in
            mainActorHeartbeat.fulfill()
        }

        await fulfillment(of: [mainActorHeartbeat], timeout: 0.1)
        do {
            try await removalTask.value
            XCTFail("锁被占用时删除应以 typed timeout 结束")
        } catch let error as AppGroupStoreError {
            XCTAssertEqual(error, .operationTimedOut)
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }
        lockHolder.terminate()
        lockHolder.waitUntilExit()
        XCTAssertEqual(try store.loadPendingImports().map(\.id), [payload.id])
    }

    @MainActor
    func testAsyncLoadKeepsMainActorResponsiveWhileAnotherProcessHoldsLock() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        )
        let payload = PendingImportPayload(sourceHint: .plainText, rawText: "晴天 - 周杰伦")
        try store.savePendingImport(payload)
        let lockHolder = try startExternalLockHolder(
            at: directory.appendingPathComponent("pending_imports.lock")
        )
        defer {
            if lockHolder.isRunning {
                lockHolder.terminate()
                lockHolder.waitUntilExit()
            }
        }
        let mainActorHeartbeat = expectation(description: "main actor stays responsive during pending load")
        let loadTask = Task { @MainActor in
            try await store.loadPendingImports(
                deadline: MonotonicOperationDeadline(timeoutNanoseconds: 250_000_000)
            )
        }
        Task { @MainActor in
            mainActorHeartbeat.fulfill()
        }

        await fulfillment(of: [mainActorHeartbeat], timeout: 0.1)
        do {
            _ = try await loadTask.value
            XCTFail("锁被占用时异步读取应以 typed timeout 结束")
        } catch let error as AppGroupStoreError {
            XCTAssertEqual(error, .operationTimedOut)
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }
        lockHolder.terminate()
        lockHolder.waitUntilExit()
        XCTAssertEqual(try store.loadPendingImports().map(\.id), [payload.id])
    }

    @MainActor
    func testAsyncClearKeepsMainActorResponsiveAndDoesNotDeleteAfterLockTimeout() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        )
        let payload = PendingImportPayload(sourceHint: .plainText, rawText: "晴天 - 周杰伦")
        try store.savePendingImport(payload)
        let lockHolder = try startExternalLockHolder(
            at: directory.appendingPathComponent("pending_imports.lock")
        )
        defer {
            if lockHolder.isRunning {
                lockHolder.terminate()
                lockHolder.waitUntilExit()
            }
        }
        let mainActorHeartbeat = expectation(description: "main actor stays responsive during pending clear")
        let clearTask = Task { @MainActor in
            try await store.clearPendingImports(
                deadline: MonotonicOperationDeadline(timeoutNanoseconds: 250_000_000)
            )
        }
        Task { @MainActor in
            mainActorHeartbeat.fulfill()
        }

        await fulfillment(of: [mainActorHeartbeat], timeout: 0.1)
        do {
            try await clearTask.value
            XCTFail("锁被占用时异步清理应以 typed timeout 结束")
        } catch let error as AppGroupStoreError {
            XCTAssertEqual(error, .operationTimedOut)
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }
        lockHolder.terminate()
        lockHolder.waitUntilExit()
        XCTAssertEqual(try store.loadPendingImports().map(\.id), [payload.id])
    }

    #endif

    func testSharedImageStagingRejectsOversizedSourceWithoutLeavingPartialFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("oversized.png")
        try Data(repeating: 1, count: 5).write(to: sourceURL)
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory,
            maximumSharedImageBytes: 4
        )

        XCTAssertThrowsError(try store.stageSharedImage(from: sourceURL)) { error in
            XCTAssertEqual(error as? AppGroupStoreError, .sharedImageTooLarge)
        }

        XCTAssertEqual(try sharedImageFiles(in: directory), [])
    }

    func testSharedImageStagingCleansDestinationWhenCopyFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("unreadable.png")
        try writeTinyPNG(to: sourceURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sourceURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceURL.path)
        }
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        )

        XCTAssertThrowsError(try store.stageSharedImage(from: sourceURL))
        XCTAssertEqual(try sharedImageFiles(in: directory), [])
    }

    func testSharedImageStagingRejectsSymlinkedSharedImageDirectoryWithoutWritingOutsideStore() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outsideDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        let sourceURL = directory.appendingPathComponent("playlist.png")
        try writeTinyPNG(to: sourceURL)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("shared-images", isDirectory: true),
            withDestinationURL: outsideDirectory
        )
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        )

        XCTAssertThrowsError(try store.stageSharedImage(from: sourceURL)) { error in
            XCTAssertEqual(error as? AppGroupStoreError, .invalidStagedImage)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outsideDirectory.path), [])
    }

    func testSharedImageStagingRejectsSymlinkedStagingDirectoryWithoutWritingOutsideStore() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outsideDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        let sourceURL = directory.appendingPathComponent("playlist.png")
        try writeTinyPNG(to: sourceURL)
        let imageDirectory = directory.appendingPathComponent("shared-images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: imageDirectory.appendingPathComponent(".staging", isDirectory: true),
            withDestinationURL: outsideDirectory
        )
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        )

        XCTAssertThrowsError(try store.stageSharedImage(from: sourceURL)) { error in
            XCTAssertEqual(error as? AppGroupStoreError, .invalidStagedImage)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outsideDirectory.path), [])
    }

    func testSharedImageStagingRejectsSymlinkedSourceFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let targetURL = directory.appendingPathComponent("target.png")
        try writeTinyPNG(to: targetURL)
        let linkedSourceURL = directory.appendingPathComponent("playlist.png")
        try FileManager.default.createSymbolicLink(at: linkedSourceURL, withDestinationURL: targetURL)
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        )

        XCTAssertThrowsError(try store.stageSharedImage(from: linkedSourceURL)) { error in
            XCTAssertEqual(error as? AppGroupStoreError, .invalidStagedImage)
        }
        XCTAssertEqual(try sharedImageFiles(in: directory), [])
    }

    func testPendingImportCommitRejectsStagedFileReplacedBySymlink() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("playlist.png")
        try writeTinyPNG(to: sourceURL)
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        )
        let stagedImage = try store.stageSharedImage(from: sourceURL)
        try FileManager.default.removeItem(at: stagedImage.fileURL)
        try FileManager.default.createSymbolicLink(
            at: stagedImage.fileURL,
            withDestinationURL: sourceURL
        )
        let payload = PendingImportPayload(
            sourceHint: .screenshot,
            imageFileName: stagedImage.relativePath
        )

        XCTAssertThrowsError(
            try store.commitPendingImport(payload, stagedImage: stagedImage)
        ) { error in
            XCTAssertEqual(error as? AppGroupStoreError, .invalidStagedImage)
        }
        XCTAssertEqual(try store.loadPendingImports(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testSharedImageStagingAllowsFallbackRootThatResolvesThroughSymlink() throws {
        let actualStoreRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: actualStoreRoot) }
        let linkParent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: linkParent) }
        let linkedStoreRoot = linkParent.appendingPathComponent("linked-store", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedStoreRoot,
            withDestinationURL: actualStoreRoot
        )
        let sourceURL = actualStoreRoot.appendingPathComponent("playlist.png")
        try writeTinyPNG(to: sourceURL)
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: linkedStoreRoot
        )

        let stagedImage = try store.stageSharedImage(from: sourceURL)
        let committed = try store.commitPendingImport(
            PendingImportPayload(sourceHint: .screenshot),
            stagedImage: stagedImage
        )
        let imageURL = try store.sharedImageURL(for: committed)

        XCTAssertTrue(imageURL.path.hasPrefix(actualStoreRoot.path + "/shared-images/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testStagedImageAndQueueCommitPublishOneFinalReference() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("playlist.png")
        try writeTinyPNG(to: sourceURL)
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        )
        let stagedImage = try store.stageSharedImage(from: sourceURL)
        let payload = PendingImportPayload(
            sourceHint: .screenshot,
            imageFileName: stagedImage.relativePath
        )

        let committed = try store.commitPendingImport(payload, stagedImage: stagedImage)

        let finalRelativePath = try XCTUnwrap(committed.imageFileName)
        XCTAssertTrue(finalRelativePath.hasPrefix("shared-images/"))
        XCTAssertFalse(finalRelativePath.contains("/.staging/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedImage.fileURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(finalRelativePath).path
            )
        )
        XCTAssertEqual(try store.loadPendingImports().first?.imageFileName, finalRelativePath)
    }

    func testQueueWriteFailureRollsBackFinalAndStagedImages() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("playlist.png")
        try writeTinyPNG(to: sourceURL)
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory
        )
        let existing = PendingImportPayload(sourceHint: .plainText, rawText: "晴天 - 周杰伦")
        try store.savePendingImport(existing)
        let stagedImage = try store.stageSharedImage(from: sourceURL)
        let screenshot = PendingImportPayload(
            sourceHint: .screenshot,
            imageFileName: stagedImage.relativePath
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        XCTAssertThrowsError(try store.commitPendingImport(screenshot, stagedImage: stagedImage))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(try store.loadPendingImports().map(\.id), [existing.id])
        XCTAssertEqual(try sharedImageFiles(in: directory), [])
    }

    func testRemovingScreenshotPendingImportAlsoDeletesImageFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageDirectory = directory.appendingPathComponent("shared-images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let imageURL = imageDirectory.appendingPathComponent("playlist.png")
        try Data("image".utf8).write(to: imageURL)

        let store = AppGroupStore(appGroupIdentifier: "missing.group", fallbackDirectory: directory)
        let payload = PendingImportPayload(sourceHint: .screenshot, imageFileName: "shared-images/playlist.png")
        try store.savePendingImport(payload)

        try store.removePendingImport(id: payload.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testPendingImportRemovalRestoresQueueWhenImageCleanupFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageDirectory = directory.appendingPathComponent("shared-images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let imageURL = imageDirectory.appendingPathComponent("playlist.png")
        try Data("image".utf8).write(to: imageURL)
        let store = AppGroupStore(appGroupIdentifier: "missing.group", fallbackDirectory: directory)
        let payload = PendingImportPayload(
            sourceHint: .screenshot,
            imageFileName: "shared-images/playlist.png"
        )
        try store.savePendingImport(payload)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: imageDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: imageDirectory.path)
        }

        XCTAssertThrowsError(try store.removePendingImport(id: payload.id))

        XCTAssertEqual(try store.loadPendingImports().map(\.id), [payload.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: imageDirectory.path)
        try store.removePendingImport(id: payload.id)
        XCTAssertEqual(try store.loadPendingImports(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testPendingImportRemovalOnlyDeletesFilesInsideSharedImageDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unrelatedURL = directory.appendingPathComponent("keep-me.json")
        try Data("unrelated".utf8).write(to: unrelatedURL)
        let store = AppGroupStore(appGroupIdentifier: "missing.group", fallbackDirectory: directory)
        let unrelatedPayload = PendingImportPayload(
            sourceHint: .screenshot,
            imageFileName: "keep-me.json"
        )
        let lockPayload = PendingImportPayload(
            sourceHint: .screenshot,
            imageFileName: "pending_imports.lock"
        )
        try store.savePendingImport(unrelatedPayload)
        try store.savePendingImport(lockPayload)

        try store.removePendingImport(id: unrelatedPayload.id)
        try store.removePendingImport(id: lockPayload.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("pending_imports.lock").path
            )
        )
    }

    func testRemovingOnePendingImportKeepsImageReferencedByAnotherImport() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageDirectory = directory.appendingPathComponent("shared-images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let imageURL = imageDirectory.appendingPathComponent("shared.png")
        try Data("image".utf8).write(to: imageURL)
        let store = AppGroupStore(appGroupIdentifier: "missing.group", fallbackDirectory: directory)
        let first = PendingImportPayload(
            sourceHint: .screenshot,
            imageFileName: "shared-images/shared.png"
        )
        let second = PendingImportPayload(
            sourceHint: .screenshot,
            imageFileName: "shared-images/shared.png"
        )
        try store.savePendingImport(first)
        try store.savePendingImport(second)

        try store.removePendingImport(id: first.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        try store.removePendingImport(id: second.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testPendingImportQueueRejectsTwentyFirstItemWithoutEvictingOldestScreenshot() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageDirectory = directory.appendingPathComponent("shared-images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let store = AppGroupStore(appGroupIdentifier: "missing.group", fallbackDirectory: directory)
        var payloads: [PendingImportPayload] = []

        for index in 0..<20 {
            let fileName = "shared-images/\(index).png"
            try Data("image".utf8).write(to: directory.appendingPathComponent(fileName))
            let payload = PendingImportPayload(sourceHint: .screenshot, imageFileName: fileName)
            try store.savePendingImport(payload)
            payloads.append(payload)
        }

        XCTAssertThrowsError(
            try store.savePendingImport(
                PendingImportPayload(sourceHint: .plainText, rawText: "第 21 份歌单")
            )
        ) { error in
            XCTAssertEqual(error as? AppGroupStoreError, .pendingImportQueueFull)
        }

        let restored = try store.loadPendingImports()
        XCTAssertEqual(restored.count, 20)
        XCTAssertEqual(Set(restored.map(\.id)), Set(payloads.map(\.id)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageDirectory.appendingPathComponent("0.png").path))
    }

    func testPendingImportQueueFullDiscardsRejectedStagedScreenshot() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.png")
        try writeTinyPNG(to: sourceURL)
        let store = AppGroupStore(appGroupIdentifier: "missing.group", fallbackDirectory: directory)
        for index in 0..<20 {
            try store.savePendingImport(
                PendingImportPayload(sourceHint: .plainText, rawText: "歌曲 \(index) - 歌手")
            )
        }
        let stagedImage = try store.stageSharedImage(from: sourceURL)

        XCTAssertThrowsError(
            try store.commitPendingImport(
                PendingImportPayload(sourceHint: .screenshot),
                stagedImage: stagedImage
            )
        ) { error in
            XCTAssertEqual(error as? AppGroupStoreError, .pendingImportQueueFull)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedImage.fileURL.path))
        XCTAssertEqual(try store.loadPendingImports().count, 20)
    }

    func testExpiredStagingCleanupPreservesQueueReferencesAndFreshWrites() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stagingDirectory = directory
            .appendingPathComponent("shared-images", isDirectory: true)
            .appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        let now = Date()
        let oldDate = now.addingTimeInterval(-7_200)
        let oldOrphanURL = stagingDirectory.appendingPathComponent("old-orphan.png")
        let referencedURL = stagingDirectory.appendingPathComponent("referenced.png")
        let activeWriteURL = stagingDirectory.appendingPathComponent("active-write.png")
        try Data("orphan".utf8).write(to: oldOrphanURL)
        try Data("referenced".utf8).write(to: referencedURL)
        try Data("still-writing".utf8).write(to: activeWriteURL)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: oldOrphanURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: referencedURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: activeWriteURL.path
        )

        let referencedPayload = PendingImportPayload(
            sourceHint: .screenshot,
            imageFileName: "shared-images/.staging/referenced.png"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([referencedPayload]).write(
            to: directory.appendingPathComponent("pending_imports.json"),
            options: .atomic
        )

        let ancientSourceURL = directory.appendingPathComponent("ancient-source.png")
        try writeTinyPNG(to: ancientSourceURL)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: ancientSourceURL.path
        )
        let store = AppGroupStore(appGroupIdentifier: "missing.group", fallbackDirectory: directory)
        let newlyStagedImage = try store.stageSharedImage(from: ancientSourceURL)

        let removedCount = try await store.removeExpiredStagedSharedImages(
            olderThan: 3_600,
            now: now,
            deadline: MonotonicOperationDeadline(timeoutNanoseconds: 1_000_000_000)
        )

        XCTAssertEqual(removedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldOrphanURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: referencedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeWriteURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newlyStagedImage.fileURL.path))
    }

    func testPendingImportQueueKeepsImageReferencedByMultiplePayloads() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageDirectory = directory.appendingPathComponent("shared-images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let imageURL = imageDirectory.appendingPathComponent("shared.png")
        try Data("image".utf8).write(to: imageURL)
        let store = AppGroupStore(appGroupIdentifier: "missing.group", fallbackDirectory: directory)
        try store.savePendingImport(
            PendingImportPayload(sourceHint: .screenshot, imageFileName: "shared-images/shared.png")
        )
        try store.savePendingImport(
            PendingImportPayload(sourceHint: .screenshot, imageFileName: "shared-images/shared.png")
        )
        for index in 0..<18 {
            try store.savePendingImport(
                PendingImportPayload(sourceHint: .plainText, rawText: "歌曲 \(index) - 歌手")
            )
        }

        XCTAssertEqual(try store.loadPendingImports().count, 20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testCorruptPendingImportStoreIsQuarantinedAndCanRecover() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("pending_imports.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: storeURL)
        let store = AppGroupStore(appGroupIdentifier: "missing.group", fallbackDirectory: directory)

        XCTAssertThrowsError(try store.loadPendingImports())
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("pending_imports.corrupt-") })

        let payload = PendingImportPayload(sourceHint: .plainText, rawText: "晴天 - 周杰伦")
        try store.savePendingImport(payload)
        XCTAssertEqual(try store.loadPendingImports().map(\.id), [payload.id])
    }

    func testOversizedPendingImportStoreIsRejectedBeforeDecodingAndQuarantined() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("pending_imports.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: 65).write(to: storeURL)
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory,
            maximumPendingImportStoreBytes: 64
        )

        XCTAssertThrowsError(try store.loadPendingImports()) { error in
            XCTAssertEqual(error as? AppGroupStoreError, .pendingImportStoreTooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix("pending_imports.oversized-") }
        )
    }

    func testPendingImportCommitRejectsEncodedQueueAboveStoreByteLimit() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppGroupStore(
            appGroupIdentifier: "missing.group",
            fallbackDirectory: directory,
            maximumPendingImportStoreBytes: 128
        )

        XCTAssertThrowsError(
            try store.savePendingImport(
                PendingImportPayload(
                    sourceHint: .plainText,
                    rawText: String(repeating: "歌", count: 200)
                )
            )
        ) { error in
            XCTAssertEqual(error as? AppGroupStoreError, .pendingImportStoreTooLarge)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("pending_imports.json").path
            )
        )
    }

    func testClearingPendingImportsRemovesStoreQuarantinesAndOrphanImages() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageDirectory = directory.appendingPathComponent("shared-images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let referencedImageURL = imageDirectory.appendingPathComponent("referenced.png")
        let orphanImageURL = imageDirectory.appendingPathComponent("orphan.png")
        try Data("image".utf8).write(to: referencedImageURL)
        try Data("orphan".utf8).write(to: orphanImageURL)
        let quarantineURL = directory.appendingPathComponent("pending_imports.corrupt-old.json")
        let unrelatedURL = directory.appendingPathComponent("keep-me.json")
        let lockURL = directory.appendingPathComponent("pending_imports.lock")
        try Data("corrupt".utf8).write(to: quarantineURL)
        try Data("unrelated".utf8).write(to: unrelatedURL)
        let store = AppGroupStore(appGroupIdentifier: "missing.group", fallbackDirectory: directory)
        try store.savePendingImport(
            PendingImportPayload(
                sourceHint: .screenshot,
                imageFileName: "shared-images/referenced.png"
            )
        )

        try store.clearPendingImports()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("pending_imports.json").path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantineURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: referencedImageURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanImageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
        XCTAssertEqual(try store.loadPendingImports(), [])
    }

    func testRecentPlaylistStoreUpsertsEditedSnapshotByPlaylistID() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recent_playlists.json")
        let store = RecentPlaylistStore(url: url, limit: 3)
        let playlistID = UUID()
        let original = ImportedPlaylist(
            id: playlistID,
            source: .plainText,
            title: "原始歌单",
            songs: [ImportedSong(title: "晴天", artist: "周杰伦", source: .plainText, confidence: 1)],
            parseConfidence: 0.8
        )
        let other = ImportedPlaylist(
            source: .plainText,
            title: "其他歌单",
            songs: [ImportedSong(title: "后来", artist: "刘若英", source: .plainText, confidence: 1)],
            parseConfidence: 1
        )
        let edited = ImportedPlaylist(
            id: playlistID,
            source: .plainText,
            title: "已编辑歌单",
            songs: [ImportedSong(title: "搁浅", artist: "周杰伦", source: .plainText, confidence: 1)],
            parseConfidence: 1
        )

        try store.record(original)
        try store.record(other)
        try store.record(edited)

        let loaded = try store.load()
        XCTAssertEqual(loaded.map(\.id), [playlistID, other.id])
        XCTAssertEqual(loaded.first?.title, "已编辑歌单")
        XCTAssertEqual(loaded.first?.songs.map(\.title), ["搁浅"])
    }

    func testRecentPlaylistStoreReplacesLegacyDemoRecordsWithTheCanonicalSnapshot() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecentPlaylistStore(
            url: directory.appendingPathComponent("recent_playlists.json"),
            limit: 6
        )
        let legacy = ImportedPlaylist(
            source: .demo,
            title: "周末朋友局常听",
            songs: [ImportedSong(title: "晴天", artist: "周杰伦", source: .demo, confidence: 1)],
            parseConfidence: 1
        )
        let canonical = ImportedPlaylist(
            source: .demo,
            title: "周末朋友局常听",
            songs: [ImportedSong(title: "晴天现场版", artist: "周杰伦", source: .demo, confidence: 1)],
            parseConfidence: 1
        )

        try store.record(legacy)
        try store.record(canonical)

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, canonical.id)
        XCTAssertEqual(loaded.first?.songs.map(\.title), ["晴天现场版"])
    }

    func testRecentPlaylistStoreKeepsIdenticalContentWithDifferentPlaylistIDs() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recent_playlists.json")
        let store = RecentPlaylistStore(url: url, limit: 3)
        let first = ImportedPlaylist(
            source: .plainText,
            title: "同名歌单",
            songs: [ImportedSong(title: "晴天", artist: "周杰伦", source: .plainText, confidence: 1)],
            parseConfidence: 1
        )
        let second = ImportedPlaylist(
            source: .plainText,
            title: "同名歌单",
            songs: [ImportedSong(title: "晴天", artist: "周杰伦", source: .plainText, confidence: 1)],
            parseConfidence: 1
        )

        try store.record(first)
        try store.record(second)

        XCTAssertEqual(try store.load().map(\.id), [second.id, first.id])
    }

    func testRecentPlaylistStorePersistsOrderAndLimitsHistory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recent_playlists.json")
        let store = RecentPlaylistStore(url: url, limit: 3)

        for index in 0..<4 {
            let playlist = ImportedPlaylist(
                source: .plainText,
                title: "歌单 \(index)",
                songs: [ImportedSong(title: "歌曲 \(index)", artist: "歌手", source: .plainText, confidence: 1)],
                parseConfidence: 1
            )
            try store.record(playlist)
        }

        let loaded = try RecentPlaylistStore(url: url, limit: 3).load()
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded.map(\.title), ["歌单 3", "歌单 2", "歌单 1"])
    }

    func testRecentPlaylistStoreRemovesOnePlaylistByID() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecentPlaylistStore(url: directory.appendingPathComponent("recent_playlists.json"))
        let first = makePlaylist(title: "歌单一")
        let second = makePlaylist(title: "歌单二")
        try store.record(first)
        try store.record(second)

        try store.remove(id: first.id)

        XCTAssertEqual(try store.load().map(\.id), [second.id])
    }

    func testRecentPlaylistStoreClearRemovesAllPlaylistsAndAllowsNewRecords() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recent_playlists.json")
        let quarantineURL = directory.appendingPathComponent("recent_playlists.corrupt-old.json")
        let oversizedURL = directory.appendingPathComponent("recent_playlists.oversized-old.json")
        let unrelatedURL = directory.appendingPathComponent("keep-me.json")
        let store = RecentPlaylistStore(url: url)
        try store.record(makePlaylist(title: "旧歌单"))
        try Data("corrupt".utf8).write(to: quarantineURL)
        try Data("oversized".utf8).write(to: oversizedURL)
        try Data("unrelated".utf8).write(to: unrelatedURL)

        try store.clear()

        XCTAssertEqual(try store.load().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantineURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oversizedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        let replacement = makePlaylist(title: "新歌单")
        try store.record(replacement)
        XCTAssertEqual(try store.load().map(\.id), [replacement.id])
    }

    func testRecentPlaylistStoreQuarantinesCorruptDataAndCanRecover() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recent_playlists.json")
        try Data("not-json".utf8).write(to: url)
        let store = RecentPlaylistStore(url: url)

        XCTAssertEqual(try store.load().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix("recent_playlists.corrupt-") }
        )

        let replacement = makePlaylist(title: "恢复后的歌单")
        try store.record(replacement)
        XCTAssertEqual(try store.load().map(\.id), [replacement.id])
    }

    func testRecentPlaylistStoreReadsLegacyArrayAndMigratesOnNextWrite() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recent_playlists.json")
        let legacy = makePlaylist(title: "旧格式歌单")
        try JSONEncoder().encode([legacy]).write(to: url)
        let store = RecentPlaylistStore(url: url)

        XCTAssertEqual(try store.load().map(\.id), [legacy.id])

        let latest = makePlaylist(title: "新歌单")
        try store.record(latest)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual((object["playlists"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(try store.load().map(\.id), [latest.id, legacy.id])
    }

    func testRecentPlaylistStoreQuarantinesFutureVersionAndCanRecover() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recent_playlists.json")
        try Data(#"{"schemaVersion":999,"playlists":[]}"#.utf8).write(to: url)
        let store = RecentPlaylistStore(url: url)

        XCTAssertEqual(try store.load().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix("recent_playlists.incompatible-") }
        )

        let replacement = makePlaylist(title: "兼容版本歌单")
        try store.record(replacement)
        XCTAssertEqual(try store.load().map(\.id), [replacement.id])
    }

    func testRecentPlaylistStorePreservesCodablePlaylistFields() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recent_playlists.json")
        let songID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let playlist = ImportedPlaylist(
            source: .appleMusic,
            title: "完整字段歌单",
            externalURL: URL(string: "https://music.example.com/playlist/42"),
            songs: [
                ImportedSong(
                    id: songID,
                    title: "晴天",
                    artist: "周杰伦",
                    source: .appleMusic,
                    rawText: "晴天 - 周杰伦",
                    confidence: 0.92,
                    versionTags: ["Live"]
                )
            ],
            createdAt: createdAt,
            parseConfidence: 0.88
        )

        try RecentPlaylistStore(url: url).record(playlist)
        let restored = try XCTUnwrap(RecentPlaylistStore(url: url).load().first)

        XCTAssertEqual(restored.id, playlist.id)
        XCTAssertEqual(restored.source, .appleMusic)
        XCTAssertEqual(restored.title, "完整字段歌单")
        XCTAssertEqual(restored.externalURL, playlist.externalURL)
        XCTAssertEqual(restored.createdAt, createdAt)
        XCTAssertEqual(restored.parseConfidence, 0.88, accuracy: 0.000_001)
        XCTAssertEqual(restored.songs.first?.id, songID)
        XCTAssertEqual(restored.songs.first?.rawText, "晴天 - 周杰伦")
        XCTAssertEqual(restored.songs.first?.versionTags, ["Live"])
    }

    func testWorkflowSnapshotStoreRoundTripsCurrentWorkflowState() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workflow_snapshot.json")
        let playlist = makePlaylist(title: "今晚歌单")
        let song = try XCTUnwrap(playlist.songs.first)
        let snapshot = WorkflowSnapshot(
            importedPlaylist: playlist,
            reviewSongs: [
                WorkflowReviewSong(
                    song: song,
                    title: "晴天（现场版）",
                    artist: "周杰伦",
                    isDeleted: true
                )
            ],
            matches: [],
            preferenceProfile: nil,
            voiceProfile: nil,
            recommendationInputSource: .userImport,
            scenarioConfig: ScenarioConfig(
                scenario: .friends,
                peopleCount: 6,
                durationMinutes: 90,
                vibe: .energetic,
                chorusPreference: .moreChorus,
                difficultyPreference: .easy
            ),
            songPlan: nil,
            lockedTrackIDs: ["locked-b", "locked-a", "locked-a"],
            removedTrackIDs: ["removed-a"],
            externalCandidateTracks: [],
            feedbackProfile: SongFeedbackProfile(
                feedbackByTrackID: ["locked-a": [.liked, .tooHigh]]
            ),
            hasAdvancedToScenario: true,
            updatedAt: Date(timeIntervalSince1970: 1_720_000_000)
        )

        let store = WorkflowSnapshotStore(url: url)
        try store.save(snapshot)
        let restored = try XCTUnwrap(store.load())

        XCTAssertEqual(restored.importedPlaylist.id, playlist.id)
        XCTAssertEqual(restored.reviewSongs.first?.title, "晴天（现场版）")
        XCTAssertEqual(restored.reviewSongs.first?.isDeleted, true)
        XCTAssertEqual(restored.recommendationInputSource, .userImport)
        XCTAssertEqual(restored.scenarioConfig.peopleCount, 6)
        XCTAssertEqual(restored.scenarioConfig.durationMinutes, 90)
        XCTAssertEqual(restored.lockedTrackIDs, ["locked-a", "locked-b"])
        XCTAssertEqual(restored.removedTrackIDs, ["removed-a"])
        XCTAssertEqual(restored.hasAdvancedToScenario, true)
        XCTAssertEqual(
            Set(restored.feedbackProfile.feedback(for: "locked-a")),
            Set([.liked, .tooHigh])
        )
        XCTAssertEqual(restored.updatedAt, snapshot.updatedAt)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
    }

    func testWorkflowSnapshotStoreLoadsArchiveBeforeScenarioAdvanceWasPersisted() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workflow_snapshot.json")
        let playlist = makePlaylist(title: "旧版进度")
        let snapshot = WorkflowSnapshot(
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
        let store = WorkflowSnapshotStore(url: url)
        try store.save(snapshot)

        var archive = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var storedSnapshot = try XCTUnwrap(archive["snapshot"] as? [String: Any])
        storedSnapshot.removeValue(forKey: "hasAdvancedToScenario")
        archive["snapshot"] = storedSnapshot
        try JSONSerialization.data(withJSONObject: archive).write(to: url, options: .atomic)

        let restored = try XCTUnwrap(store.load())
        XCTAssertNil(restored.hasAdvancedToScenario)
    }

    func testWorkflowSnapshotStoreQuarantinesCorruptAndFutureVersions() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workflow_snapshot.json")
        let store = WorkflowSnapshotStore(url: url)

        try Data("not-json".utf8).write(to: url)
        XCTAssertNil(try store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix("workflow_snapshot.corrupt-") }
        )

        try Data(#"{"schemaVersion":999,"snapshot":{}}"#.utf8).write(to: url)
        XCTAssertNil(try store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix("workflow_snapshot.incompatible-") }
        )
    }

    func testWorkflowSnapshotStoreClearRemovesCurrentAndQuarantinedFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workflow_snapshot.json")
        let corruptURL = directory.appendingPathComponent("workflow_snapshot.corrupt-old.json")
        let incompatibleURL = directory.appendingPathComponent("workflow_snapshot.incompatible-old.json")
        let oversizedURL = directory.appendingPathComponent("workflow_snapshot.oversized-old.json")
        let unrelatedURL = directory.appendingPathComponent("keep-me.json")
        try Data("current".utf8).write(to: url)
        try Data("corrupt".utf8).write(to: corruptURL)
        try Data("future".utf8).write(to: incompatibleURL)
        try Data("oversized".utf8).write(to: oversizedURL)
        try Data("unrelated".utf8).write(to: unrelatedURL)

        try WorkflowSnapshotStore(url: url).clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: incompatibleURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oversizedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    private func makePlaylist(id: UUID = UUID(), title: String) -> ImportedPlaylist {
        ImportedPlaylist(
            id: id,
            source: .plainText,
            title: title,
            songs: [ImportedSong(title: "晴天", artist: "周杰伦", source: .plainText, confidence: 1)],
            parseConfidence: 1
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    #if os(macOS)
    private func startExternalLockHolder(at lockURL: URL) throws -> Process {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-MFcntl=:flock",
            "-e",
            #"$|=1; open(my $fh, ">>", $ARGV[0]) or die $!; flock($fh, LOCK_EX) or die $!; print "locked\n"; sleep 30;"#,
            lockURL.path
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let readiness = output.fileHandleForReading.availableData
        let message = String(data: readiness, encoding: .utf8) ?? ""
        guard message.contains("locked") else {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            throw NSError(
                domain: "AppGroupStoreTests.ExternalLockHolder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "外部锁进程未就绪：\(message)"]
            )
        }
        return process
    }
    #endif

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

    private func writeTinyPNG(to url: URL) throws {
        let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        try data.write(to: url)
    }
}
