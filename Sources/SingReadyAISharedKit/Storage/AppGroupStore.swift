import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum AppGroupStoreError: Error, LocalizedError, Equatable, Sendable {
    case sharedImageTooLarge
    case invalidStagedImage
    case invalidSharedImageReference
    case pendingImportQueueFull
    case pendingImportStoreTooLarge
    case pendingImportRemovalPartiallyCompleted
    case operationTimedOut

    public var errorDescription: String? {
        switch self {
        case .sharedImageTooLarge:
            return "这张图太大了，请先裁一下再试。"
        case .invalidStagedImage:
            return "这张截图暂时读不出来，请重新选择后再试。"
        case .invalidSharedImageReference:
            return "这份分享里的截图位置不安全，请删除后重新分享。"
        case .pendingImportQueueFull:
            return "待整理内容已满，请先处理一份后再分享。"
        case .pendingImportStoreTooLarge:
            return "待整理内容占用空间过大，请先清除本机记录后再试。"
        case .pendingImportRemovalPartiallyCompleted:
            return "待整理内容已删除，但对应截图暂时没清掉；可以通过清除本机记录重试。"
        case .operationTimedOut:
            return "本机存储正忙，请稍后重试。"
        }
    }
}

public struct MonotonicOperationDeadline: Equatable, Sendable {
    public let uptimeNanoseconds: UInt64

    public init(timeoutNanoseconds: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = now.addingReportingOverflow(timeoutNanoseconds)
        uptimeNanoseconds = overflow ? UInt64.max : deadline
    }

    public func remainingNanoseconds(
        nowUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> UInt64 {
        uptimeNanoseconds > nowUptimeNanoseconds
            ? uptimeNanoseconds - nowUptimeNanoseconds
            : 0
    }

    public var hasExpired: Bool {
        remainingNanoseconds() == 0
    }
}

public struct PendingImportPersistenceReceipt: Equatable, Sendable {
    public let didSaveRecentPlaylist: Bool
    public let didSaveWorkflowSnapshot: Bool

    public init(
        didSaveRecentPlaylist: Bool,
        didSaveWorkflowSnapshot: Bool
    ) {
        self.didSaveRecentPlaylist = didSaveRecentPlaylist
        self.didSaveWorkflowSnapshot = didSaveWorkflowSnapshot
    }

    public var canConsumePendingImport: Bool {
        didSaveRecentPlaylist || didSaveWorkflowSnapshot
    }
}

public struct StagedSharedImage: Equatable, Sendable {
    public let fileURL: URL
    public let relativePath: String

    public init(fileURL: URL, relativePath: String) {
        self.fileURL = fileURL
        self.relativePath = relativePath
    }
}

public struct AppGroupStore: Sendable {
    public static let defaultAppGroupID = "group.com.huangwei.singreadyai"

    private static let pendingImportProcessLock = NSLock()
    private static let maximumPendingImportCount = 20

    private let appGroupIdentifier: String
    private let fallbackDirectory: URL?
    private let maximumSharedImageBytes: Int
    private let sharedImageInspector: ImageImportInspector
    private let maximumPendingImportStoreBytes: Int
    private let lockTimeoutNanoseconds: UInt64
    private let afterPendingImportWrite: @Sendable () -> Void

    public init(
        appGroupIdentifier: String = AppGroupStore.defaultAppGroupID,
        fallbackDirectory: URL? = nil,
        maximumSharedImageBytes: Int = 25_000_000,
        maximumSharedImagePixels: Int = ImageImportLimits.default.maximumPixelCount,
        maximumPendingImportStoreBytes: Int = 8_000_000,
        lockTimeoutNanoseconds: UInt64 = 100_000_000
    ) {
        self.init(
            appGroupIdentifier: appGroupIdentifier,
            fallbackDirectory: fallbackDirectory,
            maximumSharedImageBytes: maximumSharedImageBytes,
            maximumSharedImagePixels: maximumSharedImagePixels,
            maximumPendingImportStoreBytes: maximumPendingImportStoreBytes,
            lockTimeoutNanoseconds: lockTimeoutNanoseconds,
            afterPendingImportWrite: {}
        )
    }

    init(
        appGroupIdentifier: String = AppGroupStore.defaultAppGroupID,
        fallbackDirectory: URL? = nil,
        maximumSharedImageBytes: Int = 25_000_000,
        maximumSharedImagePixels: Int = ImageImportLimits.default.maximumPixelCount,
        maximumPendingImportStoreBytes: Int = 8_000_000,
        lockTimeoutNanoseconds: UInt64 = 100_000_000,
        afterPendingImportWrite: @escaping @Sendable () -> Void
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.fallbackDirectory = fallbackDirectory
        self.maximumSharedImageBytes = max(1, maximumSharedImageBytes)
        self.sharedImageInspector = ImageImportInspector(
            limits: ImageImportLimits(maximumPixelCount: maximumSharedImagePixels)
        )
        self.maximumPendingImportStoreBytes = max(1, maximumPendingImportStoreBytes)
        self.lockTimeoutNanoseconds = max(1, lockTimeoutNanoseconds)
        self.afterPendingImportWrite = afterPendingImportWrite
    }

    public func savePendingImport(_ payload: PendingImportPayload) throws {
        _ = try commitPendingImport(payload)
    }

    public func stageSharedImage(from sourceURL: URL) throws -> StagedSharedImage {
        let sourceValues = try sourceURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true else {
            throw AppGroupStoreError.invalidStagedImage
        }
        if let fileSize = sourceValues.fileSize, fileSize > maximumSharedImageBytes {
            throw AppGroupStoreError.sharedImageTooLarge
        }
        try validateSharedImage(at: sourceURL)

        let directory = try sharedImageStagingDirectoryURL()
        let pathExtension = safeImageExtension(sourceURL.pathExtension)
        let fileName = "\(UUID().uuidString).\(pathExtension)"
        let destination = directory.appendingPathComponent(fileName)
        let relativePath = "shared-images/.staging/\(fileName)"

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            try FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: destination.path
            )
            try validateSharedImage(at: destination)
            let stagedImage = StagedSharedImage(
                fileURL: destination,
                relativePath: relativePath
            )
            _ = try validatedStagedImageURL(stagedImage)
            return stagedImage
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public func discardStagedSharedImage(_ stagedImage: StagedSharedImage) throws {
        let stagedURL = try validatedStagedImageURL(stagedImage)
        if FileManager.default.fileExists(atPath: stagedURL.path) {
            try FileManager.default.removeItem(at: stagedURL)
        }
    }

    @discardableResult
    public func commitPendingImport(
        _ payload: PendingImportPayload,
        stagedImage: StagedSharedImage? = nil
    ) throws -> PendingImportPayload {
        do {
            return try withPendingImportLock {
                try commitPendingImportUnlocked(
                    payload,
                    stagedImage: stagedImage,
                    deadline: nil
                )
            }
        } catch {
            if let stagedImage {
                try? discardStagedSharedImage(stagedImage)
            }
            throw error
        }
    }

    @discardableResult
    public func commitPendingImport(
        _ payload: PendingImportPayload,
        stagedImage: StagedSharedImage? = nil,
        deadline: MonotonicOperationDeadline
    ) async throws -> PendingImportPayload {
        do {
            return try await withPendingImportLock(deadline: deadline) {
                try commitPendingImportUnlocked(
                    payload,
                    stagedImage: stagedImage,
                    deadline: deadline
                )
            }
        } catch {
            if let stagedImage {
                try? discardStagedSharedImage(stagedImage)
            }
            throw error
        }
    }

    private func commitPendingImportUnlocked(
        _ payload: PendingImportPayload,
        stagedImage: StagedSharedImage?,
        deadline: MonotonicOperationDeadline?
    ) throws -> PendingImportPayload {
        try checkOperation(deadline)
        var payloads = try loadPendingImportsUnlocked()
        guard payloads.count < Self.maximumPendingImportCount else {
            throw AppGroupStoreError.pendingImportQueueFull
        }
        let originalPayloads = payloads
        var committedPayload = payload
        var finalImageURL: URL?

        do {
            if let stagedImage {
                let stagedURL = try validatedStagedImageURL(stagedImage)
                try validateSharedImage(at: stagedURL)
                try checkOperation(deadline)
                let imageDirectory = try sharedImageDirectoryURL()
                let finalFileName = "\(UUID().uuidString).\(safeImageExtension(stagedURL.pathExtension))"
                let finalURL = imageDirectory.appendingPathComponent(finalFileName)
                try FileManager.default.moveItem(at: stagedURL, to: finalURL)
                finalImageURL = finalURL
                _ = try validatedRealFile(
                    at: finalURL,
                    inside: imageDirectory,
                    invalidError: .invalidStagedImage
                )
                try validateSharedImage(at: finalURL)
                committedPayload.imageFileName = "shared-images/\(finalFileName)"
            } else if committedPayload.imageFileName?.contains("/.staging/") == true {
                throw AppGroupStoreError.invalidStagedImage
            }

            try checkOperation(deadline)
            payloads.insert(committedPayload, at: 0)
            try writeUnlocked(payloads)
            afterPendingImportWrite()
            do {
                try checkOperation(deadline)
            } catch {
                do {
                    try writeUnlocked(originalPayloads)
                } catch {
                    // 新队列已经原子发布且无法回滚时，以已提交结果收口，避免留下失去图片的引用。
                    return committedPayload
                }
                if let finalImageURL,
                   FileManager.default.fileExists(atPath: finalImageURL.path) {
                    try? FileManager.default.removeItem(at: finalImageURL)
                }
                finalImageURL = nil
                throw error
            }
            return committedPayload
        } catch {
            if let finalImageURL,
               FileManager.default.fileExists(atPath: finalImageURL.path) {
                try? FileManager.default.removeItem(at: finalImageURL)
            }
            throw error
        }
    }

    public func loadPendingImports() throws -> [PendingImportPayload] {
        try withPendingImportLock {
            try loadPendingImportsUnlocked()
        }
    }

    public func loadPendingImports(
        deadline: MonotonicOperationDeadline
    ) async throws -> [PendingImportPayload] {
        try await withPendingImportLock(deadline: deadline) {
            let payloads = try loadPendingImportsUnlocked()
            try checkOperation(deadline)
            return payloads
        }
    }

    private func loadPendingImportsUnlocked() throws -> [PendingImportPayload] {
        let url = try storeFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw AppGroupStoreError.pendingImportStoreTooLarge
        }
        if let fileSize = values.fileSize,
           fileSize > maximumPendingImportStoreBytes {
            try quarantinePendingImportStore(at: url, reason: "oversized")
            throw AppGroupStoreError.pendingImportStoreTooLarge
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([PendingImportPayload].self, from: data)
        } catch {
            try quarantinePendingImportStore(at: url, reason: "corrupt")
            throw error
        }
    }

    private func quarantinePendingImportStore(at url: URL, reason: String) throws {
        let quarantineURL = url.deletingLastPathComponent()
            .appendingPathComponent("pending_imports.\(reason)-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: url, to: quarantineURL)
    }

    public func clearPendingImports() throws {
        try withPendingImportLock {
            try clearPendingImportsUnlocked()
        }
    }

    public func clearPendingImports(
        deadline: MonotonicOperationDeadline
    ) async throws {
        try await withPendingImportLock(deadline: deadline) {
            try clearPendingImportsUnlocked()
        }
    }

    private func clearPendingImportsUnlocked() throws {
        let directory = try storeDirectoryURL()
        let imageDirectory = directory.appendingPathComponent("shared-images", isDirectory: true)
        if FileManager.default.fileExists(atPath: imageDirectory.path) {
            try FileManager.default.removeItem(at: imageDirectory)
        }
        try removeStoreFamily(
            url: directory.appendingPathComponent("pending_imports.json"),
            quarantineReasons: ["corrupt", "incompatible", "oversized"]
        )
    }

    public func removePendingImport(id: UUID) throws {
        try withPendingImportLock {
            try removePendingImportUnlocked(id: id, deadline: nil)
        }
    }

    public func removePendingImport(
        id: UUID,
        deadline: MonotonicOperationDeadline
    ) async throws {
        try await withPendingImportLock(deadline: deadline) {
            try removePendingImportUnlocked(id: id, deadline: deadline)
        }
    }

    @discardableResult
    public func removeExpiredStagedSharedImages(
        olderThan maximumAge: TimeInterval = 24 * 60 * 60,
        now: Date = Date(),
        deadline: MonotonicOperationDeadline
    ) async throws -> Int {
        try await withPendingImportLock(deadline: deadline) {
            try removeExpiredStagedSharedImagesUnlocked(
                olderThan: maximumAge,
                now: now,
                deadline: deadline
            )
        }
    }

    private func removeExpiredStagedSharedImagesUnlocked(
        olderThan maximumAge: TimeInterval,
        now: Date,
        deadline: MonotonicOperationDeadline
    ) throws -> Int {
        try checkOperation(deadline)
        let storeRoot = try storeDirectoryURL()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let expectedStagingDirectory = storeRoot
            .appendingPathComponent("shared-images", isDirectory: true)
            .appendingPathComponent(".staging", isDirectory: true)
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: expectedStagingDirectory.path) else {
            return 0
        }
        let stagingDirectory = expectedStagingDirectory.resolvingSymlinksInPath()
        guard stagingDirectory == expectedStagingDirectory else {
            throw AppGroupStoreError.invalidStagedImage
        }

        let referencedPaths = Set(
            try loadPendingImportsUnlocked().compactMap { payload in
                payload.imageFileName?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )
        let cutoff = now.addingTimeInterval(-max(0, maximumAge))
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]
        let candidates = try FileManager.default.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        )
        var removedCount = 0

        for candidate in candidates {
            try checkOperation(deadline)
            let standardizedCandidate = candidate.standardizedFileURL
            guard standardizedCandidate.deletingLastPathComponent() == stagingDirectory else {
                continue
            }
            let relativePath = "shared-images/.staging/\(standardizedCandidate.lastPathComponent)"
            guard !referencedPaths.contains(relativePath) else { continue }

            let initialValues = try standardizedCandidate.resourceValues(forKeys: resourceKeys)
            guard initialValues.isRegularFile == true,
                  initialValues.isSymbolicLink != true,
                  let initialModificationDate = initialValues.contentModificationDate,
                  initialModificationDate <= cutoff else {
                continue
            }

            // 删除前重读一次元数据。仍在写入的文件会改变时间或大小，因此不会被本轮清理误删。
            let latestValues = try standardizedCandidate.resourceValues(forKeys: resourceKeys)
            guard latestValues.isRegularFile == true,
                  latestValues.isSymbolicLink != true,
                  latestValues.contentModificationDate == initialModificationDate,
                  latestValues.fileSize == initialValues.fileSize,
                  let latestModificationDate = latestValues.contentModificationDate,
                  latestModificationDate <= cutoff else {
                continue
            }

            try checkOperation(deadline)
            try FileManager.default.removeItem(at: standardizedCandidate)
            removedCount += 1
        }
        return removedCount
    }

    private func removePendingImportUnlocked(
        id: UUID,
        deadline: MonotonicOperationDeadline?
    ) throws {
        try checkOperation(deadline)
        let payloads = try loadPendingImportsUnlocked()
        let removed = payloads.filter { $0.id == id }
        let remaining = payloads.filter { $0.id != id }
        try checkOperation(deadline)
        try writeUnlocked(remaining)
        do {
            for removedPayload in removed {
                try removeImageIfPresent(
                    removedPayload,
                    retainedPayloads: remaining
                )
            }
        } catch let cleanupError {
            do {
                try writeUnlocked(payloads)
            } catch {
                throw AppGroupStoreError.pendingImportRemovalPartiallyCompleted
            }
            throw cleanupError
        }
    }

    public func storeDirectoryURL() throws -> URL {
        if let fallbackDirectory {
            return fallbackDirectory
        }
        if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return appGroupURL
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("SingReadyAI", isDirectory: true)
    }

    public func isUsingFallbackStore() -> Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) == nil
    }

    public func sharedImageURL(for payload: PendingImportPayload) throws -> URL {
        guard let relativePath = payload.imageFileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relativePath.isEmpty else {
            throw AppGroupStoreError.invalidSharedImageReference
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == "shared-images" else {
            throw AppGroupStoreError.invalidSharedImageReference
        }
        let fileName = String(components[1])
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.hasPrefix(".") else {
            throw AppGroupStoreError.invalidSharedImageReference
        }

        let storeRoot = try resolvedStoreRootURL(
            createIfMissing: false,
            invalidError: .invalidSharedImageReference
        )
        let imageRoot = try validatedRealDirectory(
            at: storeRoot.appendingPathComponent("shared-images", isDirectory: true),
            inside: storeRoot,
            createIfMissing: false,
            invalidError: .invalidSharedImageReference
        )
        return try validatedRealFile(
            at: imageRoot.appendingPathComponent(fileName, isDirectory: false),
            inside: imageRoot,
            invalidError: .invalidSharedImageReference
        )
    }

    private func storeFileURL() throws -> URL {
        let directory = try storeDirectoryURL()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("pending_imports.json")
    }

    private func sharedImageDirectoryURL() throws -> URL {
        let storeRoot = try resolvedStoreRootURL(
            createIfMissing: true,
            invalidError: .invalidStagedImage
        )
        return try validatedRealDirectory(
            at: storeRoot.appendingPathComponent("shared-images", isDirectory: true),
            inside: storeRoot,
            createIfMissing: true,
            invalidError: .invalidStagedImage
        )
    }

    private func sharedImageStagingDirectoryURL() throws -> URL {
        let imageRoot = try sharedImageDirectoryURL()
        return try validatedRealDirectory(
            at: imageRoot.appendingPathComponent(".staging", isDirectory: true),
            inside: imageRoot,
            createIfMissing: true,
            invalidError: .invalidStagedImage
        )
    }

    private func validatedStagedImageURL(_ stagedImage: StagedSharedImage) throws -> URL {
        let stagingRoot = try sharedImageStagingDirectoryURL().standardizedFileURL
        let components = stagedImage.relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count == 3,
              components[0] == "shared-images",
              components[1] == ".staging" else {
            throw AppGroupStoreError.invalidStagedImage
        }
        let fileName = String(components[2])
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.hasPrefix(".") else {
            throw AppGroupStoreError.invalidStagedImage
        }
        let expectedURL = stagingRoot.appendingPathComponent(fileName).standardizedFileURL
        let suppliedURL = stagedImage.fileURL.standardizedFileURL
        guard suppliedURL == expectedURL else {
            throw AppGroupStoreError.invalidStagedImage
        }
        return try validatedRealFile(
            at: suppliedURL,
            inside: stagingRoot,
            invalidError: .invalidStagedImage
        )
    }

    private func validateSharedImage(at url: URL) throws {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0 else {
            throw AppGroupStoreError.invalidStagedImage
        }
        guard fileSize <= maximumSharedImageBytes else {
            throw AppGroupStoreError.sharedImageTooLarge
        }
        do {
            _ = try sharedImageInspector.inspectImage(at: url)
        } catch ImageImportSafetyError.pixelLimitExceeded {
            throw AppGroupStoreError.sharedImageTooLarge
        } catch {
            throw AppGroupStoreError.invalidStagedImage
        }
    }

    private func resolvedStoreRootURL(
        createIfMissing: Bool,
        invalidError: AppGroupStoreError
    ) throws -> URL {
        let configuredRoot = try storeDirectoryURL().standardizedFileURL
        if !FileManager.default.fileExists(atPath: configuredRoot.path) {
            guard createIfMissing else { throw invalidError }
            try FileManager.default.createDirectory(
                at: configuredRoot,
                withIntermediateDirectories: true
            )
        }
        let resolvedRoot = configuredRoot.resolvingSymlinksInPath().standardizedFileURL
        let values = try resolvedRoot.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw invalidError
        }
        return resolvedRoot
    }

    private func validatedRealDirectory(
        at directory: URL,
        inside parent: URL,
        createIfMissing: Bool,
        invalidError: AppGroupStoreError
    ) throws -> URL {
        let standardizedParent = parent.standardizedFileURL
        let standardizedDirectory = directory.standardizedFileURL
        guard standardizedDirectory.deletingLastPathComponent() == standardizedParent else {
            throw invalidError
        }

        if !FileManager.default.fileExists(atPath: standardizedDirectory.path) {
            if let values = try? standardizedDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]),
               values.isSymbolicLink == true {
                throw invalidError
            }
            guard createIfMissing else { throw invalidError }
            try FileManager.default.createDirectory(
                at: standardizedDirectory,
                withIntermediateDirectories: false
            )
        }

        let values = try standardizedDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        let resolvedDirectory = standardizedDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              resolvedDirectory == standardizedDirectory,
              resolvedDirectory.deletingLastPathComponent() == standardizedParent else {
            throw invalidError
        }
        return resolvedDirectory
    }

    private func validatedRealFile(
        at file: URL,
        inside directory: URL,
        invalidError: AppGroupStoreError
    ) throws -> URL {
        let standardizedDirectory = directory.standardizedFileURL
        let standardizedFile = file.standardizedFileURL
        let values = try standardizedFile.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        let resolvedFile = standardizedFile
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard standardizedFile.deletingLastPathComponent() == standardizedDirectory,
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              resolvedFile == standardizedFile else {
            throw invalidError
        }
        return standardizedFile
    }

    private func safeImageExtension(_ value: String) -> String {
        let normalized = value.lowercased()
        guard !normalized.isEmpty,
              normalized.count <= 10,
              normalized.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else {
            return "png"
        }
        return normalized
    }

    private func writeUnlocked(_ payloads: [PendingImportPayload]) throws {
        let url = try storeFileURL()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payloads)
        guard data.count <= maximumPendingImportStoreBytes else {
            throw AppGroupStoreError.pendingImportStoreTooLarge
        }
        try data.write(to: url, options: [.atomic])
    }

    private func withPendingImportLock<T>(_ body: () throws -> T) throws -> T {
        try withNonblockingPendingImportLock(
            deadline: MonotonicOperationDeadline(timeoutNanoseconds: lockTimeoutNanoseconds),
            cancellationCheck: {},
            body
        )
    }

    private func withPendingImportLock<T: Sendable>(
        deadline: MonotonicOperationDeadline,
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let worker = Task.detached { [self] in
            try withNonblockingPendingImportLock(
                deadline: deadline,
                cancellationCheck: { try Task.checkCancellation() },
                body
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func withNonblockingPendingImportLock<T>(
        deadline: MonotonicOperationDeadline,
        cancellationCheck: () throws -> Void,
        _ body: () throws -> T
    ) throws -> T {
        while !Self.pendingImportProcessLock.try() {
            try waitForPendingImportLock(deadline: deadline, cancellationCheck: cancellationCheck)
        }
        defer { Self.pendingImportProcessLock.unlock() }

        try cancellationCheck()
        guard !deadline.hasExpired else { throw AppGroupStoreError.operationTimedOut }
        let directory = try storeDirectoryURL()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let lockURL = directory.appendingPathComponent("pending_imports.lock")

        #if canImport(Darwin)
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }

        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR {
                try waitForPendingImportLock(deadline: deadline, cancellationCheck: cancellationCheck)
                continue
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        #endif

        try cancellationCheck()
        guard !deadline.hasExpired else { throw AppGroupStoreError.operationTimedOut }
        return try body()
    }

    private func waitForPendingImportLock(
        deadline: MonotonicOperationDeadline,
        cancellationCheck: () throws -> Void
    ) throws {
        try cancellationCheck()
        let remaining = deadline.remainingNanoseconds()
        guard remaining > 0 else { throw AppGroupStoreError.operationTimedOut }
        let retryNanoseconds = min(remaining, 5_000_000)
        Thread.sleep(forTimeInterval: Double(retryNanoseconds) / 1_000_000_000)
    }

    private func checkOperation(_ deadline: MonotonicOperationDeadline?) throws {
        guard let deadline else { return }
        try Task.checkCancellation()
        guard !deadline.hasExpired else { throw AppGroupStoreError.operationTimedOut }
    }

    private func removeImageIfPresent(
        _ payload: PendingImportPayload,
        retainedPayloads: [PendingImportPayload] = []
    ) throws {
        guard let imageURL = cleanupSharedImageURL(for: payload) else { return }
        let isStillReferenced = retainedPayloads.contains { retainedPayload in
            cleanupSharedImageURL(for: retainedPayload) == imageURL
        }
        guard !isStillReferenced else { return }
        if FileManager.default.fileExists(atPath: imageURL.path) {
            try FileManager.default.removeItem(at: imageURL)
        }
    }

    private func cleanupSharedImageURL(for payload: PendingImportPayload) -> URL? {
        try? sharedImageURL(for: payload)
    }
}

public struct RecentPlaylistStore: Sendable {
    private static let currentSchemaVersion = 1
    private static let maximumArchiveByteCount: UInt64 = 8 * 1_024 * 1_024

    private struct Archive: Codable {
        let schemaVersion: Int
        let playlists: [ImportedPlaylist]
    }

    private struct VersionHeader: Decodable {
        let schemaVersion: Int
    }

    private let url: URL
    private let limit: Int

    public init(url: URL, limit: Int = 6) {
        self.url = url
        self.limit = max(1, limit)
    }

    public func load() throws -> [ImportedPlaylist] {
        switch try loadWithStatus() {
        case .missing, .quarantined:
            return []
        case let .loaded(playlists):
            return playlists
        }
    }

    public func loadWithStatus() throws -> VersionedStoreLoadResult<[ImportedPlaylist]> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        if try recentPlaylistFileExceedsMaximumByteCount(
            at: url,
            maximumByteCount: Self.maximumArchiveByteCount
        ) {
            try quarantine(reason: "oversized")
            return .quarantined(.oversized)
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()

        if let header = try? decoder.decode(VersionHeader.self, from: data) {
            guard header.schemaVersion == Self.currentSchemaVersion else {
                try quarantine(reason: "incompatible")
                return .quarantined(.incompatibleVersion)
            }
            do {
                let archive = try decoder.decode(Archive.self, from: data)
                return .loaded(Array(archive.playlists.prefix(limit)))
            } catch {
                try quarantine(reason: "corrupt")
                return .quarantined(.corrupt)
            }
        }

        do {
            let legacyPlaylists = try decoder.decode([ImportedPlaylist].self, from: data)
            return .loaded(Array(legacyPlaylists.prefix(limit)))
        } catch {
            try quarantine(reason: "corrupt")
            return .quarantined(.corrupt)
        }
    }

    public func record(_ playlist: ImportedPlaylist) throws {
        var playlists = try load()
        let canonicalTitle = playlist.title.trimmingCharacters(in: .whitespacesAndNewlines)
        playlists.removeAll { existing in
            existing.id == playlist.id
                || (
                    playlist.source == .demo
                        && existing.source == .demo
                        && existing.title.trimmingCharacters(in: .whitespacesAndNewlines) == canonicalTitle
                )
        }
        playlists.insert(playlist, at: 0)
        try save(Array(playlists.prefix(limit)))
    }

    public func remove(id: UUID) throws {
        let playlists = try load().filter { $0.id != id }
        try save(playlists)
    }

    public func clear() throws {
        try removeStoreFamily(
            url: url,
            quarantineReasons: ["corrupt", "incompatible", "oversized"]
        )
    }

    private func save(_ playlists: [ImportedPlaylist]) throws {
        let archive = Archive(
            schemaVersion: Self.currentSchemaVersion,
            playlists: Array(playlists.prefix(limit))
        )
        try LocalJSONStore<Archive>(url: url).save(archive)
    }

    private func quarantine(reason: String) throws {
        let fileExtension = url.pathExtension
        let baseName = url.deletingPathExtension().lastPathComponent
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        let quarantineURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(baseName).\(reason)-\(UUID().uuidString)\(suffix)")
        try FileManager.default.moveItem(at: url, to: quarantineURL)
    }
}

private func recentPlaylistFileExceedsMaximumByteCount(
    at url: URL,
    maximumByteCount: UInt64
) throws -> Bool {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let fileSize = attributes[.size] as? NSNumber else { return false }
    return fileSize.uint64Value > maximumByteCount
}

private func removeStoreFamily(url: URL, quarantineReasons: [String]) throws {
    let directory = url.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    let baseName = url.deletingPathExtension().lastPathComponent
    let fileExtension = url.pathExtension
    let quarantinePrefixes = quarantineReasons.map { "\(baseName).\($0)-" }

    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
        let isCurrent = name == url.lastPathComponent
        let isQuarantine = quarantinePrefixes.contains { prefix in
            name.hasPrefix(prefix) && (fileExtension.isEmpty || name.hasSuffix(".\(fileExtension)"))
        }
        if isCurrent || isQuarantine {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

public struct LocalJSONStore<Value: Codable>: Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load(default defaultValue: Value) throws -> Value {
        guard FileManager.default.fileExists(atPath: url.path) else { return defaultValue }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }

    public func save(_ value: Value) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
    }
}
