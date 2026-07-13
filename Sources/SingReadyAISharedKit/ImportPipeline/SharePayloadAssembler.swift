import Foundation

public struct SharePayloadPart: Equatable, Sendable {
    public var urlString: String?
    public var rawText: String?
    public var imageFileName: String?

    public init(
        urlString: String? = nil,
        rawText: String? = nil,
        imageFileName: String? = nil
    ) {
        self.urlString = urlString
        self.rawText = rawText
        self.imageFileName = imageFileName
    }
}

public struct ShareProviderRepresentationDecoder: Sendable {
    public init() {}

    public func plainText(from item: NSSecureCoding?) -> String? {
        if let string = item as? NSString {
            return String(string)
        }
        if let data = item as? NSData {
            let value = data as Data
            if let text = String(data: value, encoding: .utf8) {
                return text
            }
            if let archivedText = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSString.self,
                from: value
            ) {
                return String(archivedText)
            }
        }
        if let url = item as? NSURL {
            return url.absoluteString
        }
        return nil
    }

    public func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? NSURL {
            return url as URL
        }
        if let string = item as? NSString {
            return URL(string: String(string))
        }
        if let data = item as? NSData,
           let string = plainText(from: data) {
            return URL(string: string)
        }
        return nil
    }
}

public struct BoundedShareTextFileReader: Sendable {
    public static let defaultMaximumBytes = 512_000

    private let maximumBytes: Int
    private let decoder: ShareProviderRepresentationDecoder

    public init(
        maximumBytes: Int = BoundedShareTextFileReader.defaultMaximumBytes,
        decoder: ShareProviderRepresentationDecoder = ShareProviderRepresentationDecoder()
    ) {
        self.maximumBytes = max(1, maximumBytes)
        self.decoder = decoder
    }

    public func plainText(from url: URL) throws -> String? {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw SharePayloadAssemblyError.emptyInput
        }
        if let fileSize = values.fileSize, fileSize > maximumBytes {
            throw SharePayloadAssemblyError.contentTooLarge
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let readLimit = maximumBytes == Int.max ? Int.max : maximumBytes + 1
        let data = try handle.read(upToCount: readLimit) ?? Data()
        guard data.count <= maximumBytes else {
            throw SharePayloadAssemblyError.contentTooLarge
        }
        return decoder.plainText(from: data as NSData)
    }
}

public enum SharePayloadAssemblyError: Error, LocalizedError, Equatable, Sendable {
    case emptyInput
    case contentTooLarge

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "没找到能保存的歌单内容。"
        case .contentTooLarge:
            return "这段内容太长了，请分成几份再分享。"
        }
    }
}

public struct ShareExtractionRequestGate: Equatable, Sendable {
    private var nextToken: UInt64 = 0
    private var activeToken: UInt64?

    public init() {}

    public mutating func beginIfIdle() -> UInt64? {
        guard activeToken == nil else { return nil }
        nextToken &+= 1
        if nextToken == 0 {
            nextToken = 1
        }
        activeToken = nextToken
        return nextToken
    }

    public func canCommit(_ token: UInt64) -> Bool {
        activeToken == token
    }

    @discardableResult
    public mutating func finish(_ token: UInt64) -> Bool {
        guard activeToken == token else { return false }
        activeToken = nil
        return true
    }

    public mutating func cancel() {
        activeToken = nil
    }
}

public struct ShareItemLoadBridge: Sendable {
    public init() {}

    /// 把返回 `Progress` 的回调式加载桥接为可取消的异步操作。
    /// 完成回调返回 `false` 时，表示取消已先完成，调用方需要回收刚创建的临时资源。
    public func load<Value: Sendable>(
        _ start: @escaping (@escaping (Result<Value, Error>) -> Bool) -> Progress
    ) async throws -> Value {
        let state = ShareItemLoadState<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.begin(continuation) else { return }
                let progress = start { result in
                    state.resolve(result)
                }
                state.attach(progress)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

/// 闭包始终回到主执行器启动系统表示加载；包装值仅用于跨任务组传递该主执行器入口。
public struct ShareRepresentationLoad: @unchecked Sendable {
    private let operation: @MainActor () async throws -> SharePayloadPart?

    public init(_ operation: @escaping @MainActor () async throws -> SharePayloadPart?) {
        self.operation = operation
    }

    @MainActor
    fileprivate func callAsFunction() async throws -> SharePayloadPart? {
        try await operation()
    }
}

public struct ShareRepresentationLoadCoordinator: Sendable {
    public init() {}

    @MainActor
    public func load(
        _ representations: [ShareRepresentationLoad],
        onUpdate: @escaping @MainActor ([SharePayloadPart]) -> Void = { _ in }
    ) async throws -> [SharePayloadPart] {
        try await withThrowingTaskGroup(of: IndexedSharePayloadPart?.self) { group in
            for (index, representation) in representations.enumerated() {
                group.addTask {
                    do {
                        guard let part = try await representation() else { return nil }
                        return IndexedSharePayloadPart(index: index, part: part)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return nil
                    }
                }
            }

            var loadedByIndex: [Int: SharePayloadPart] = [:]
            do {
                while let loaded = try await group.next() {
                    guard let loaded else { continue }
                    loadedByIndex[loaded.index] = loaded.part
                    onUpdate(orderedParts(from: loadedByIndex))
                }
                return orderedParts(from: loadedByIndex)
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func orderedParts(from loadedByIndex: [Int: SharePayloadPart]) -> [SharePayloadPart] {
        loadedByIndex.keys.sorted().compactMap { loadedByIndex[$0] }
    }
}

private struct IndexedSharePayloadPart: Sendable {
    let index: Int
    let part: SharePayloadPart
}

private final class ShareItemLoadState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var progress: Progress?
    private var isCancelled = false
    private var isFinished = false

    func begin(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if isCancelled {
            isFinished = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func attach(_ progress: Progress) {
        lock.lock()
        let shouldCancel = isCancelled
        if !isFinished {
            self.progress = progress
        }
        lock.unlock()

        if shouldCancel {
            progress.cancel()
        }
    }

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return false
        }
        isFinished = true
        self.continuation = nil
        progress = nil
        lock.unlock()

        continuation.resume(with: result)
        return true
    }

    func cancel() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isCancelled = true
        let progress = progress
        let continuation = continuation
        if continuation != nil {
            isFinished = true
            self.continuation = nil
            self.progress = nil
        }
        lock.unlock()

        progress?.cancel()
        continuation?.resume(throwing: CancellationError())
    }
}

public enum ShareExtractionDeadlineError: Error, Equatable, LocalizedError, Sendable {
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            return "读取分享内容超时，已停止。"
        }
    }
}

public struct ShareExtractionDeadline: Sendable {
    public static let defaultTimeoutNanoseconds: UInt64 = 18_000_000_000

    private let timeoutNanoseconds: UInt64

    public init(timeoutNanoseconds: UInt64 = ShareExtractionDeadline.defaultTimeoutNanoseconds) {
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    public func makeDeadline() -> MonotonicOperationDeadline {
        MonotonicOperationDeadline(timeoutNanoseconds: timeoutNanoseconds)
    }

    @MainActor
    public func perform<Value: Sendable>(
        _ operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        try await perform(until: makeDeadline(), operation)
    }

    @MainActor
    public func perform<Value: Sendable>(
        until deadline: MonotonicOperationDeadline,
        _ operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        let state = ShareExtractionDeadlineState<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.install(continuation) else { return }

                let operationTask = Task<Void, Never> { @MainActor in
                    let result: Result<Value, Error>
                    do {
                        result = .success(try await operation())
                    } catch {
                        result = .failure(error)
                    }
                    state.resolve(result)
                }
                let timeoutTask = Task.detached {
                    do {
                        let remainingNanoseconds = deadline.remainingNanoseconds()
                        if remainingNanoseconds > 0 {
                            try await Task.sleep(nanoseconds: remainingNanoseconds)
                        }
                        try Task.checkCancellation()
                        state.resolve(.failure(ShareExtractionDeadlineError.timedOut))
                    } catch {
                        return
                    }
                }
                state.installTasks(operation: operationTask, timeout: timeoutTask)
            }
        } onCancel: {
            state.resolve(.failure(CancellationError()))
        }
    }
}

private final class ShareExtractionDeadlineState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var terminalResult: Result<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    @discardableResult
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let terminalResult {
            lock.unlock()
            continuation.resume(with: terminalResult)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func installTasks(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            operation.cancel()
            timeout.cancel()
            return
        }
        operationTask = operation
        timeoutTask = timeout
        lock.unlock()
    }

    func resolve(_ result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>?
        let operationTask: Task<Void, Never>?
        let timeoutTask: Task<Void, Never>?

        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        terminalResult = result
        continuation = self.continuation
        self.continuation = nil
        operationTask = self.operationTask
        timeoutTask = self.timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}

public struct SharePayloadFallbackPresentation: Equatable, Sendable {
    public let title: String
    public let message: String
    public let source: String
    public let preview: String
    public let fallbackCopyText: String?

    public init(
        title: String,
        message: String,
        source: String,
        preview: String,
        fallbackCopyText: String?
    ) {
        self.title = title
        self.message = message
        self.source = source
        self.preview = preview
        self.fallbackCopyText = fallbackCopyText
    }
}

public struct SharePayloadFallbackPolicy: Sendable {
    public init() {}

    public func extractionTimeoutPresentation(
        for payload: PendingImportPayload?,
        includedScreenshot: Bool
    ) -> SharePayloadFallbackPresentation {
        if let payload, let copyText = manualTransferText(for: payload) {
            return SharePayloadFallbackPresentation(
                title: "读取超时，请手动带回 App",
                message: "这次分享读取时间太久，已停止。请复制已读到的内容，回到 App 粘贴。",
                source: "没有直接导入",
                preview: previewText(for: payload),
                fallbackCopyText: copyText
            )
        }
        if includedScreenshot || payload?.imageFileName?.nilIfBlank != nil {
            return SharePayloadFallbackPresentation(
                title: "请在 App 里重新选择截图",
                message: "这张截图读取时间太久，已停止且没有导入。请回到 App 点“识别截图”重新选择。",
                source: "截图没有导入",
                preview: "这次没有留下可供 App 继续读取的图片副本。",
                fallbackCopyText: nil
            )
        }
        return SharePayloadFallbackPresentation(
            title: "读取超时",
            message: "这次分享读取时间太久，已停止。请回到原应用复制链接或文字，再到 App 粘贴。",
            source: "没有导入",
            preview: "也可以稍后重新分享一次。",
            fallbackCopyText: nil
        )
    }

    public func storageFailurePresentation(for payload: PendingImportPayload) -> SharePayloadFallbackPresentation {
        if let copyText = manualTransferText(for: payload) {
            return SharePayloadFallbackPresentation(
                title: "需要手动带回 App",
                message: "共享存储暂时不可用，这次内容没有直接进入今晚唱什么。请复制后回到 App 粘贴。",
                source: "没有直接导入",
                preview: previewText(for: payload),
                fallbackCopyText: copyText
            )
        }
        if payload.imageFileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return SharePayloadFallbackPresentation(
                title: "请在 App 里重新选择截图",
                message: "这张截图没有保存进今晚唱什么。请回到 App 点“识别截图”，再从相册或刚才的应用重新选择。",
                source: "截图没有导入",
                preview: "这次没有留下可供 App 继续读取的图片副本。",
                fallbackCopyText: nil
            )
        }
        return SharePayloadFallbackPresentation(
            title: "这次没存好",
            message: "这次内容没有保存，请回到刚才的页面再分享一次。",
            source: "没保存",
            preview: "也可以打开今晚唱什么，改用粘贴文本或识别截图。",
            fallbackCopyText: nil
        )
    }

    private func manualTransferText(for payload: PendingImportPayload) -> String? {
        let values = [payload.urlString, payload.rawText]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
        return values.isEmpty ? nil : values.joined(separator: "\n")
    }

    private func previewText(for payload: PendingImportPayload) -> String {
        if let displayTitle = payload.displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayTitle.isEmpty {
            if let urlString = payload.urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
               !urlString.isEmpty {
                return "\(displayTitle)\n\(urlString)"
            }
            if let rawText = payload.rawText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawText.isEmpty {
                return "\(displayTitle)\n\(rawText)"
            }
        }
        return payload.urlString?.nilIfBlank ?? payload.rawText?.nilIfBlank ?? "请复制内容后回到 App 继续"
    }
}

public struct SharePayloadAssembler: Sendable {
    private let detector: ShareProviderDetector
    private let maximumTextLength: Int
    private let maximumURLLength: Int

    public init(
        detector: ShareProviderDetector = ShareProviderDetector(),
        maximumTextLength: Int = 50_000,
        maximumURLLength: Int = 4_096
    ) {
        self.detector = detector
        self.maximumTextLength = max(1, maximumTextLength)
        self.maximumURLLength = max(256, maximumURLLength)
    }

    public func assemble(
        parts: [SharePayloadPart],
        hostAppName: String? = nil,
        displayTitle: String? = nil
    ) throws -> PendingImportPayload {
        let urlString = firstUsableURL(in: parts)
        let textResult = mergedText(in: parts)
        let imageFileName = parts.lazy
            .compactMap(\.imageFileName)
            .compactMap(trimmedNonEmpty)
            .first

        if urlString == nil, textResult.value == nil, imageFileName == nil {
            throw textResult.sawOversized
                ? SharePayloadAssemblyError.contentTooLarge
                : SharePayloadAssemblyError.emptyInput
        }

        let detectionDraft = PendingImportPayload(
            sourceHint: .unknown,
            rawText: textResult.value,
            urlString: urlString,
            imageFileName: urlString == nil && textResult.value == nil ? imageFileName : nil,
            hostAppName: trimmedNonEmpty(hostAppName),
            displayTitle: trimmedNonEmpty(displayTitle)
        )
        let detected = detector.detect(payload: detectionDraft)
        return PendingImportPayload(
            sourceHint: detected.source,
            rawText: textResult.value,
            urlString: urlString,
            imageFileName: imageFileName,
            hostAppName: trimmedNonEmpty(hostAppName),
            displayTitle: trimmedNonEmpty(displayTitle) ?? defaultTitle(
                source: detected.source,
                hasText: textResult.value != nil,
                hasImage: imageFileName != nil
            )
        )
    }

    private func firstUsableURL(in parts: [SharePayloadPart]) -> String? {
        parts
            .compactMap(\.urlString)
            .compactMap(trimmedNonEmpty)
            .filter(isUsableWebURL)
            .enumerated()
            .min { lhs, rhs in
                let lhsPriority = urlPriority(lhs.element)
                let rhsPriority = urlPriority(rhs.element)
                return lhsPriority == rhsPriority
                    ? lhs.offset < rhs.offset
                    : lhsPriority < rhsPriority
            }?
            .element
    }

    private func isUsableWebURL(_ value: String) -> Bool {
        guard value.count <= maximumURLLength,
              let url = URL(string: value),
              PublicWebURLPolicy().allows(url) else {
            return false
        }
        return true
    }

    private func urlPriority(_ value: String) -> Int {
        switch detector.detect(urlString: value).source {
        case .netEaseMusic, .qqMusic, .appleMusic:
            return 0
        default:
            return 1
        }
    }

    private func mergedText(in parts: [SharePayloadPart]) -> (value: String?, sawOversized: Bool) {
        var fragments: [String] = []
        var seen = Set<String>()
        var sawOversized = false

        for part in parts {
            guard let value = trimmedNonEmpty(part.rawText) else { continue }
            guard value.count <= maximumTextLength else {
                sawOversized = true
                continue
            }
            guard seen.insert(value).inserted else { continue }
            let candidate = (fragments + [value]).joined(separator: "\n")
            guard candidate.count <= maximumTextLength else {
                sawOversized = true
                continue
            }
            fragments.append(value)
        }
        let merged = fragments.joined(separator: "\n")
        return (merged.isEmpty ? nil : merged, sawOversized)
    }

    private func defaultTitle(source: ImportSource, hasText: Bool, hasImage: Bool) -> String {
        if source == .screenshot || (!hasText && hasImage) {
            return "截图歌单"
        }
        if source == .plainText {
            return "分享文本"
        }
        return source.displayName
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
