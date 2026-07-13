import XCTest
@testable import SingReadyAISharedKit

final class SharePayloadAssemblerTests: XCTestCase {
    func testItemLoadBridgeCancelsProgressWithoutWaitingForProviderCallback() async {
        let started = expectation(description: "provider load started")
        let progress = Progress(totalUnitCount: 1)
        let completionBox = ShareLoadCompletionBox<String>()
        let task = Task<String, Error> {
            try await ShareItemLoadBridge().load { completion in
                completionBox.store(completion)
                started.fulfill()
                return progress
            }
        }
        await fulfillment(of: [started], timeout: 1)

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("取消后不应继续等待 provider 回调")
        } catch is CancellationError {
            // 取消必须直接结束等待。
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }
        XCTAssertTrue(progress.isCancelled)
        XCTAssertEqual(completionBox.resolve(.success("迟到结果")), false)
    }

    func testItemLoadBridgeAcceptsOneSuccessfulCompletion() async throws {
        let progress = Progress(totalUnitCount: 1)
        var secondCompletionAccepted: Bool?

        let value: String = try await ShareItemLoadBridge().load { completion in
            XCTAssertTrue(completion(.success("已读取")))
            secondCompletionAccepted = completion(.success("重复结果"))
            return progress
        }

        XCTAssertEqual(value, "已读取")
        XCTAssertEqual(secondCompletionAccepted, false)
        XCTAssertFalse(progress.isCancelled)
    }

    func testExtractionDeadlineTimesOutAndCancelsHungProviderProgress() async {
        let progress = Progress(totalUnitCount: 1)
        let completionBox = ShareLoadCompletionBox<String>()
        let startedAt = Date()

        do {
            let _: String = try await ShareExtractionDeadline(
                timeoutNanoseconds: 20_000_000
            ).perform {
                try await ShareItemLoadBridge().load { completion in
                    completionBox.store(completion)
                    return progress
                }
            }
            XCTFail("永不回调的 provider 应在总超时后退出")
        } catch let error as ShareExtractionDeadlineError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }

        XCTAssertTrue(progress.isCancelled)
        XCTAssertEqual(completionBox.resolve(.success("迟到结果")), false)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.3)
    }

    @MainActor
    func testExtractionDeadlineReusesOneAbsoluteBudgetAcrossSequentialStages() async {
        let policy = ShareExtractionDeadline(timeoutNanoseconds: 80_000_000)
        let deadline = policy.makeDeadline()
        let progress = Progress(totalUnitCount: 1)
        let completionBox = ShareLoadCompletionBox<String>()
        let startedAt = Date()
        try? await Task.sleep(nanoseconds: 50_000_000)

        do {
            let _: String = try await policy.perform(until: deadline) {
                try await ShareItemLoadBridge().load { completion in
                    completionBox.store(completion)
                    return progress
                }
            }
            XCTFail("后续阶段只能使用同一绝对 deadline 的剩余预算")
        } catch let error as ShareExtractionDeadlineError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.2)
        XCTAssertTrue(progress.isCancelled)
        XCTAssertEqual(completionBox.resolve(.success("迟到结果")), false)
    }

    @MainActor
    func testRepresentationCoordinatorKeepsTextCopyableWhenSiblingURLHangsUntilDeadline() async throws {
        let hungURLProgress = Progress(totalUnitCount: 1)
        let hungURLCompletion = ShareLoadCompletionBox<URL?>()
        var loadedParts: [SharePayloadPart] = []

        do {
            let _: [SharePayloadPart] = try await ShareExtractionDeadline(
                timeoutNanoseconds: 50_000_000
            ).perform {
                try await ShareRepresentationLoadCoordinator().load(
                    [
                        ShareRepresentationLoad {
                            let url: URL? = try await ShareItemLoadBridge().load { completion in
                                hungURLCompletion.store(completion)
                                return hungURLProgress
                            }
                            return url.map { SharePayloadPart(urlString: $0.absoluteString) }
                        },
                        ShareRepresentationLoad {
                            SharePayloadPart(rawText: "晴天 - 周杰伦")
                        }
                    ],
                    onUpdate: { loadedParts = $0 }
                )
            }
            XCTFail("URL 表示挂起时，总体时限应结束协调器")
        } catch let error as ShareExtractionDeadlineError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }

        XCTAssertEqual(loadedParts, [SharePayloadPart(rawText: "晴天 - 周杰伦")])
        XCTAssertTrue(hungURLProgress.isCancelled)
        XCTAssertEqual(
            hungURLCompletion.resolve(.success(URL(string: "https://music.163.com/playlist?id=42"))),
            false
        )

        let partialPayload = try SharePayloadAssembler().assemble(parts: loadedParts)
        let presentation = SharePayloadFallbackPolicy().extractionTimeoutPresentation(
            for: partialPayload,
            includedScreenshot: false
        )
        XCTAssertEqual(presentation.fallbackCopyText, "晴天 - 周杰伦")
    }

    @MainActor
    func testRepresentationCoordinatorManualCancellationCancelsEveryPendingProgress() async {
        let firstStarted = expectation(description: "first representation started")
        let secondStarted = expectation(description: "second representation started")
        let firstProgress = Progress(totalUnitCount: 1)
        let secondProgress = Progress(totalUnitCount: 1)
        let firstCompletion = ShareLoadCompletionBox<String>()
        let secondCompletion = ShareLoadCompletionBox<String>()
        let task = Task { @MainActor in
            try await ShareRepresentationLoadCoordinator().load([
                ShareRepresentationLoad {
                    let value: String = try await ShareItemLoadBridge().load { completion in
                        firstCompletion.store(completion)
                        firstStarted.fulfill()
                        return firstProgress
                    }
                    return SharePayloadPart(rawText: value)
                },
                ShareRepresentationLoad {
                    let value: String = try await ShareItemLoadBridge().load { completion in
                        secondCompletion.store(completion)
                        secondStarted.fulfill()
                        return secondProgress
                    }
                    return SharePayloadPart(rawText: value)
                }
            ])
        }
        await fulfillment(of: [firstStarted, secondStarted], timeout: 1)

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("手动取消后不应继续等待任何表示")
        } catch is CancellationError {
            // 所有并行表示都必须直接结束等待。
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }
        XCTAssertTrue(firstProgress.isCancelled)
        XCTAssertTrue(secondProgress.isCancelled)
        XCTAssertEqual(firstCompletion.resolve(.success("迟到结果一")), false)
        XCTAssertEqual(secondCompletion.resolve(.success("迟到结果二")), false)
    }

    func testExtractionTimeoutFallbackKeepsLoadedTextAndURLCopyable() {
        let payload = PendingImportPayload(
            sourceHint: .netEaseMusic,
            rawText: "晴天 - 周杰伦",
            urlString: "https://music.163.com/playlist?id=42",
            displayTitle: "分享歌单"
        )

        let presentation = SharePayloadFallbackPolicy().extractionTimeoutPresentation(
            for: payload,
            includedScreenshot: false
        )

        XCTAssertEqual(presentation.title, "读取超时，请手动带回 App")
        XCTAssertEqual(
            presentation.fallbackCopyText,
            "https://music.163.com/playlist?id=42\n晴天 - 周杰伦"
        )
        XCTAssertTrue(presentation.message.contains("已停止"))
    }

    func testExtractionTimeoutFallbackTellsScreenshotUserToReselectInApp() {
        let presentation = SharePayloadFallbackPolicy().extractionTimeoutPresentation(
            for: nil,
            includedScreenshot: true
        )

        XCTAssertEqual(presentation.title, "请在 App 里重新选择截图")
        XCTAssertEqual(presentation.source, "截图没有导入")
        XCTAssertNil(presentation.fallbackCopyText)
        XCTAssertTrue(presentation.message.contains("读取时间太久"))
        XCTAssertTrue(presentation.message.contains("重新选择"))
    }

    func testProviderRepresentationDecoderReadsBridgedTextAndURLValues() throws {
        let decoder = ShareProviderRepresentationDecoder()
        let archivedText = try NSKeyedArchiver.archivedData(
            withRootObject: "告白气球 - 周杰伦" as NSString,
            requiringSecureCoding: true
        )

        XCTAssertEqual(decoder.plainText(from: "晴天 - 周杰伦" as NSString), "晴天 - 周杰伦")
        XCTAssertEqual(
            decoder.plainText(from: Data("稻香 - 周杰伦".utf8) as NSData),
            "稻香 - 周杰伦"
        )
        XCTAssertEqual(
            decoder.plainText(from: archivedText as NSData),
            "告白气球 - 周杰伦"
        )
        XCTAssertEqual(
            decoder.url(from: "https://music.apple.com/cn/playlist/test" as NSString)?.absoluteString,
            "https://music.apple.com/cn/playlist/test"
        )
    }

    func testBoundedTextFileReaderRejectsOversizedProviderFileBeforeDecoding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-text-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("123456789".utf8).write(to: url)

        XCTAssertThrowsError(
            try BoundedShareTextFileReader(maximumBytes: 8).plainText(from: url)
        ) { error in
            XCTAssertEqual(error as? SharePayloadAssemblyError, .contentTooLarge)
        }
    }

    func testBoundedTextFileReaderDecodesArchivedProviderStringWithinLimit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-text-\(UUID().uuidString).data")
        defer { try? FileManager.default.removeItem(at: url) }
        let archivedText = try NSKeyedArchiver.archivedData(
            withRootObject: "告白气球 - 周杰伦" as NSString,
            requiringSecureCoding: true
        )
        try archivedText.write(to: url)

        XCTAssertEqual(
            try BoundedShareTextFileReader(maximumBytes: archivedText.count).plainText(from: url),
            "告白气球 - 周杰伦"
        )
    }

    func testExtractionGateRejectsConcurrentAndCancelledOrStaleCommits() throws {
        var gate = ShareExtractionRequestGate()
        let first = try XCTUnwrap(gate.beginIfIdle())

        XCTAssertNil(gate.beginIfIdle())
        XCTAssertTrue(gate.canCommit(first))

        gate.cancel()
        XCTAssertFalse(gate.canCommit(first))

        let second = try XCTUnwrap(gate.beginIfIdle())
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(gate.finish(first))
        XCTAssertTrue(gate.canCommit(second))
        XCTAssertTrue(gate.finish(second))
        XCTAssertFalse(gate.canCommit(second))
    }

    func testFallbackPolicyMakesURLAndTextCopyableAfterStoreFailure() {
        let payload = PendingImportPayload(
            sourceHint: .netEaseMusic,
            rawText: "晴天 - 周杰伦",
            urlString: "https://music.163.com/playlist?id=42",
            displayTitle: "分享歌单"
        )

        let presentation = SharePayloadFallbackPolicy().storageFailurePresentation(for: payload)

        XCTAssertEqual(presentation.title, "需要手动带回 App")
        XCTAssertEqual(presentation.source, "没有直接导入")
        XCTAssertEqual(
            presentation.fallbackCopyText,
            "https://music.163.com/playlist?id=42\n晴天 - 周杰伦"
        )
        XCTAssertTrue(presentation.message.contains("没有直接进入"))
    }

    func testFallbackPolicyExplainsScreenshotMustBeReselectedAfterStoreFailure() {
        let payload = PendingImportPayload(
            sourceHint: .screenshot,
            imageFileName: "shared-images/.staging/image.png",
            displayTitle: "截图歌单"
        )

        let presentation = SharePayloadFallbackPolicy().storageFailurePresentation(for: payload)

        XCTAssertEqual(presentation.title, "请在 App 里重新选择截图")
        XCTAssertEqual(presentation.source, "截图没有导入")
        XCTAssertNil(presentation.fallbackCopyText)
        XCTAssertTrue(presentation.message.contains("没有保存进"))
        XCTAssertTrue(presentation.message.contains("重新选择"))
        XCTAssertTrue(presentation.preview.contains("没有留下"))
    }

    func testAssemblerRetainsURLAndPlainTextFromSameShare() throws {
        let payload = try SharePayloadAssembler().assemble(parts: [
            SharePayloadPart(urlString: "https://music.163.com/playlist?id=42"),
            SharePayloadPart(rawText: "晴天 - 周杰伦\n稻香 - 周杰伦")
        ])

        XCTAssertEqual(payload.urlString, "https://music.163.com/playlist?id=42")
        XCTAssertEqual(payload.rawText, "晴天 - 周杰伦\n稻香 - 周杰伦")
        XCTAssertEqual(payload.sourceHint, .netEaseMusic)
    }

    func testAssemblerPrefersKnownMusicURLOverEarlierGenericURL() throws {
        let payload = try SharePayloadAssembler().assemble(parts: [
            SharePayloadPart(urlString: "https://example.com/article"),
            SharePayloadPart(urlString: "https://music.apple.com/cn/playlist/test")
        ])

        XCTAssertEqual(payload.urlString, "https://music.apple.com/cn/playlist/test")
        XCTAssertEqual(payload.sourceHint, .appleMusic)
    }

    func testAssemblerKeepsProviderOrderAmongKnownMusicURLs() throws {
        let payload = try SharePayloadAssembler().assemble(parts: [
            SharePayloadPart(urlString: "https://y.qq.com/n/ryqq/playlist/42"),
            SharePayloadPart(urlString: "https://music.163.com/playlist?id=42")
        ])

        XCTAssertEqual(payload.urlString, "https://y.qq.com/n/ryqq/playlist/42")
        XCTAssertEqual(payload.sourceHint, .qqMusic)
    }

    func testAssemblerUsesPublicWebPolicyForSharedURLs() throws {
        let payload = try SharePayloadAssembler().assemble(parts: [
            SharePayloadPart(urlString: "https://user:password@example.com/playlist"),
            SharePayloadPart(urlString: "https://127.0.0.1/private"),
            SharePayloadPart(rawText: "小幸运")
        ])

        XCTAssertNil(payload.urlString)
        XCTAssertEqual(payload.rawText, "小幸运")
        XCTAssertEqual(payload.sourceHint, .plainText)
    }

    func testInvalidURLPartDoesNotDiscardValidPlainText() throws {
        let payload = try SharePayloadAssembler().assemble(parts: [
            SharePayloadPart(urlString: "not a web URL"),
            SharePayloadPart(rawText: "小幸运")
        ])

        XCTAssertNil(payload.urlString)
        XCTAssertEqual(payload.rawText, "小幸运")
        XCTAssertEqual(payload.sourceHint, .plainText)
    }

    func testAssemblerRejectsCompletelyBlankOrInvalidParts() {
        XCTAssertThrowsError(try SharePayloadAssembler().assemble(parts: [
            SharePayloadPart(urlString: "  ", rawText: "\n\t"),
            SharePayloadPart(urlString: "ftp://example.com/list")
        ])) { error in
            XCTAssertEqual(error as? SharePayloadAssemblyError, .emptyInput)
        }
    }

    func testAssemblerRejectsOversizedTextWhenNothingElseIsUsable() {
        XCTAssertThrowsError(try SharePayloadAssembler(maximumTextLength: 8).assemble(parts: [
            SharePayloadPart(rawText: "123456789")
        ])) { error in
            XCTAssertEqual(error as? SharePayloadAssemblyError, .contentTooLarge)
        }
    }

    func testAssemblerKeepsUsableURLWhenAnotherRepresentationIsOversized() throws {
        let payload = try SharePayloadAssembler(maximumTextLength: 8).assemble(parts: [
            SharePayloadPart(urlString: "https://music.apple.com/cn/playlist/test"),
            SharePayloadPart(rawText: "123456789")
        ])

        XCTAssertEqual(payload.urlString, "https://music.apple.com/cn/playlist/test")
        XCTAssertNil(payload.rawText)
        XCTAssertEqual(payload.sourceHint, .appleMusic)
    }

    func testAssemblerMergesTrimmedUniqueTextFragmentsInProviderOrder() throws {
        let payload = try SharePayloadAssembler().assemble(parts: [
            SharePayloadPart(rawText: "  晴天 - 周杰伦  "),
            SharePayloadPart(rawText: "稻香 - 周杰伦"),
            SharePayloadPart(rawText: "晴天 - 周杰伦")
        ])

        XCTAssertEqual(payload.rawText, "晴天 - 周杰伦\n稻香 - 周杰伦")
    }

    func testTextualShareKeepsOptionalImageReferenceWithoutBeingMisclassifiedAsScreenshot() throws {
        let payload = try SharePayloadAssembler().assemble(parts: [
            SharePayloadPart(
                urlString: "https://y.qq.com/n/ryqq/playlist/42",
                rawText: "后来 - 刘若英",
                imageFileName: "shared-images/cover.png"
            )
        ])

        XCTAssertEqual(payload.sourceHint, .qqMusic)
        XCTAssertEqual(payload.imageFileName, "shared-images/cover.png")
    }
}

private final class ShareLoadCompletionBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Result<Value, Error>) -> Bool)?

    func store(_ completion: @escaping (Result<Value, Error>) -> Bool) {
        lock.lock()
        self.completion = completion
        lock.unlock()
    }

    func resolve(_ result: Result<Value, Error>) -> Bool? {
        lock.lock()
        let completion = completion
        lock.unlock()
        return completion?(result)
    }
}
