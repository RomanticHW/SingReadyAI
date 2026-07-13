import Foundation

public enum VersionedStoreQuarantineReason: Equatable, Sendable {
    case corrupt
    case incompatibleVersion
    case oversized
}

public enum VersionedStoreLoadResult<Value: Sendable>: Sendable {
    case missing
    case loaded(Value)
    case quarantined(VersionedStoreQuarantineReason)
}

public struct WorkflowReviewSong: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var artist: String?
    public var source: ImportSource
    public var rawText: String?
    public var confidence: Double
    public var versionTags: [String]
    public var isDeleted: Bool

    public init(
        id: UUID,
        title: String,
        artist: String?,
        source: ImportSource,
        rawText: String?,
        confidence: Double,
        versionTags: [String],
        isDeleted: Bool
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = normalizedArtist?.isEmpty == false ? normalizedArtist : nil
        self.source = source
        self.rawText = rawText
        self.confidence = min(max(confidence, 0), 1)
        self.versionTags = versionTags
        self.isDeleted = isDeleted
    }

    public init(
        song: ImportedSong,
        title: String? = nil,
        artist: String? = nil,
        isDeleted: Bool = false
    ) {
        self.init(
            id: song.id,
            title: title ?? song.title,
            artist: artist ?? song.artist,
            source: song.source,
            rawText: song.rawText,
            confidence: song.confidence,
            versionTags: song.versionTags,
            isDeleted: isDeleted
        )
    }

    public var importedSong: ImportedSong {
        ImportedSong(
            id: id,
            title: title,
            artist: artist,
            source: source,
            rawText: rawText,
            confidence: confidence,
            versionTags: versionTags
        )
    }
}

public struct WorkflowSnapshot: Codable, Sendable {
    public var importedPlaylist: ImportedPlaylist
    public var reviewSongs: [WorkflowReviewSong]
    public var matches: [MatchResult]
    public var preferenceProfile: PreferenceProfile?
    public var voiceProfile: VoiceProfile?
    public var recommendationInputSource: RecommendationInputSource
    public var scenarioConfig: ScenarioConfig
    public var songPlan: SongPlan?
    public var lockedTrackIDs: [String]
    public var removedTrackIDs: [String]
    public var externalCandidateTracks: [KTVTrack]
    public var feedbackProfile: SongFeedbackProfile
    public var hasAdvancedToScenario: Bool?
    public var updatedAt: Date

    public init(
        importedPlaylist: ImportedPlaylist,
        reviewSongs: [WorkflowReviewSong],
        matches: [MatchResult],
        preferenceProfile: PreferenceProfile?,
        voiceProfile: VoiceProfile?,
        recommendationInputSource: RecommendationInputSource,
        scenarioConfig: ScenarioConfig,
        songPlan: SongPlan?,
        lockedTrackIDs: [String],
        removedTrackIDs: [String],
        externalCandidateTracks: [KTVTrack],
        feedbackProfile: SongFeedbackProfile,
        hasAdvancedToScenario: Bool = false,
        updatedAt: Date = Date()
    ) {
        let normalizedLockedIDs = Array(Set(lockedTrackIDs)).sorted()
        let lockedIDSet = Set(normalizedLockedIDs)
        self.importedPlaylist = importedPlaylist
        self.reviewSongs = reviewSongs
        self.matches = matches
        self.preferenceProfile = preferenceProfile
        self.voiceProfile = voiceProfile
        self.recommendationInputSource = recommendationInputSource
        self.scenarioConfig = scenarioConfig
        self.songPlan = songPlan
        self.lockedTrackIDs = normalizedLockedIDs
        self.removedTrackIDs = Array(Set(removedTrackIDs).subtracting(lockedIDSet)).sorted()
        self.externalCandidateTracks = externalCandidateTracks
        self.feedbackProfile = feedbackProfile
        self.hasAdvancedToScenario = hasAdvancedToScenario
        self.updatedAt = updatedAt
    }
}

public struct WorkflowSnapshotStore: Sendable {
    private static let currentSchemaVersion = 1
    private static let maximumArchiveByteCount: UInt64 = 16 * 1_024 * 1_024

    private struct Archive: Codable {
        let schemaVersion: Int
        let snapshot: WorkflowSnapshot
    }

    private struct VersionHeader: Decodable {
        let schemaVersion: Int
    }

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> WorkflowSnapshot? {
        switch try loadWithStatus() {
        case .missing, .quarantined:
            return nil
        case let .loaded(snapshot):
            return snapshot
        }
    }

    public func loadWithStatus() throws -> VersionedStoreLoadResult<WorkflowSnapshot> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        if try fileExceedsMaximumByteCount(at: url, maximumByteCount: Self.maximumArchiveByteCount) {
            try quarantine(reason: "oversized")
            return .quarantined(.oversized)
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()

        guard let header = try? decoder.decode(VersionHeader.self, from: data) else {
            try quarantine(reason: "corrupt")
            return .quarantined(.corrupt)
        }
        guard header.schemaVersion == Self.currentSchemaVersion else {
            try quarantine(reason: "incompatible")
            return .quarantined(.incompatibleVersion)
        }
        do {
            return .loaded(try decoder.decode(Archive.self, from: data).snapshot)
        } catch {
            try quarantine(reason: "corrupt")
            return .quarantined(.corrupt)
        }
    }

    public func save(_ snapshot: WorkflowSnapshot) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let archive = Archive(schemaVersion: Self.currentSchemaVersion, snapshot: snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(archive).write(to: url, options: [.atomic])
    }

    public func clear() throws {
        let directory = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let baseName = url.deletingPathExtension().lastPathComponent
        let fileExtension = url.pathExtension
        let currentName = url.lastPathComponent
        let quarantinePrefixes = [
            "\(baseName).corrupt-",
            "\(baseName).incompatible-",
            "\(baseName).oversized-"
        ]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let isCurrent = name == currentName
            let isQuarantine = quarantinePrefixes.contains { prefix in
                name.hasPrefix(prefix) && (fileExtension.isEmpty || name.hasSuffix(".\(fileExtension)"))
            }
            if isCurrent || isQuarantine {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
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

public enum WorkflowPersistenceRequestResult<Value: Sendable>: Sendable {
    case applied(Value)
    case rejectedStaleRequest
}

enum WorkflowPersistenceOperation: Equatable, Sendable {
    case loadRecentPlaylists
    case recordRecentPlaylist
    case removeRecentPlaylist
    case clearRecentPlaylists
    case loadWorkflowSnapshot
    case saveWorkflowSnapshot
    case clearWorkflowSnapshot
}

/// 串行承载最近导入和工作流快照的文件读写，并用 generation 阻止旧请求在清除后复活数据。
public actor WorkflowPersistenceExecutor {
    private let recentPlaylistStore: RecentPlaylistStore
    private let workflowSnapshotStore: WorkflowSnapshotStore
    private let beforeOperation: @Sendable (WorkflowPersistenceOperation) -> Void
    private var recentGeneration: UInt64 = 0
    private var workflowSnapshotGeneration: UInt64 = 0

    public init(
        recentPlaylistStore: RecentPlaylistStore,
        workflowSnapshotStore: WorkflowSnapshotStore
    ) {
        self.init(
            recentPlaylistStore: recentPlaylistStore,
            workflowSnapshotStore: workflowSnapshotStore,
            beforeOperation: { _ in }
        )
    }

    init(
        recentPlaylistStore: RecentPlaylistStore,
        workflowSnapshotStore: WorkflowSnapshotStore,
        beforeOperation: @escaping @Sendable (WorkflowPersistenceOperation) -> Void
    ) {
        self.recentPlaylistStore = recentPlaylistStore
        self.workflowSnapshotStore = workflowSnapshotStore
        self.beforeOperation = beforeOperation
    }

    public func loadRecentPlaylists(
        request: UInt64
    ) throws -> WorkflowPersistenceRequestResult<VersionedStoreLoadResult<[ImportedPlaylist]>> {
        guard acceptRecentRequest(request) else { return .rejectedStaleRequest }
        beforeOperation(.loadRecentPlaylists)
        return .applied(try recentPlaylistStore.loadWithStatus())
    }

    public func recordRecentPlaylist(
        _ playlist: ImportedPlaylist,
        request: UInt64
    ) throws -> WorkflowPersistenceRequestResult<[ImportedPlaylist]> {
        guard acceptRecentRequest(request) else { return .rejectedStaleRequest }
        beforeOperation(.recordRecentPlaylist)
        try recentPlaylistStore.record(playlist)
        return .applied(try recentPlaylistStore.load())
    }

    public func removeRecentPlaylist(
        id: UUID,
        request: UInt64
    ) throws -> WorkflowPersistenceRequestResult<[ImportedPlaylist]> {
        guard acceptRecentRequest(request) else { return .rejectedStaleRequest }
        beforeOperation(.removeRecentPlaylist)
        try recentPlaylistStore.remove(id: id)
        return .applied(try recentPlaylistStore.load())
    }

    public func clearRecentPlaylists(
        request: UInt64
    ) throws -> WorkflowPersistenceRequestResult<Void> {
        guard acceptRecentRequest(request) else { return .rejectedStaleRequest }
        beforeOperation(.clearRecentPlaylists)
        try recentPlaylistStore.clear()
        return .applied(())
    }

    public func loadWorkflowSnapshot(
        request: UInt64
    ) throws -> WorkflowPersistenceRequestResult<VersionedStoreLoadResult<WorkflowSnapshot>> {
        guard acceptWorkflowSnapshotRequest(request) else { return .rejectedStaleRequest }
        beforeOperation(.loadWorkflowSnapshot)
        return .applied(try workflowSnapshotStore.loadWithStatus())
    }

    public func saveWorkflowSnapshot(
        _ snapshot: WorkflowSnapshot,
        request: UInt64
    ) throws -> WorkflowPersistenceRequestResult<Void> {
        guard acceptWorkflowSnapshotRequest(request) else { return .rejectedStaleRequest }
        beforeOperation(.saveWorkflowSnapshot)
        try workflowSnapshotStore.save(snapshot)
        return .applied(())
    }

    public func clearWorkflowSnapshot(
        request: UInt64
    ) throws -> WorkflowPersistenceRequestResult<Void> {
        guard acceptWorkflowSnapshotRequest(request) else { return .rejectedStaleRequest }
        beforeOperation(.clearWorkflowSnapshot)
        try workflowSnapshotStore.clear()
        return .applied(())
    }

    private func acceptRecentRequest(_ request: UInt64) -> Bool {
        guard request >= recentGeneration else { return false }
        recentGeneration = request
        return true
    }

    private func acceptWorkflowSnapshotRequest(_ request: UInt64) -> Bool {
        guard request >= workflowSnapshotGeneration else { return false }
        workflowSnapshotGeneration = request
        return true
    }
}

public struct WorkflowPersistenceRequestGate: Equatable, Sendable {
    public private(set) var generation: UInt64

    public init(generation: UInt64 = 0) {
        self.generation = generation
    }

    @discardableResult
    public mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    public mutating func invalidate() {
        generation &+= 1
    }

    public func accepts(_ request: UInt64) -> Bool {
        request == generation
    }
}

/// 独立保存用户最近一次有效实测音域。
///
/// actor 隔离保证调用方即使位于 MainActor，实际文件读写也会切换到此存储的执行器。
/// 常见范围参考和无效测量不会写入或覆盖已有实测记录。
public enum VoiceProfileRestorePolicy {
    /// 工作流快照用于恢复当时的上下文，独立记录保存最近一次成功实测。
    /// 两处都有效时按测量时间取较新值，避免快照写入失败后把新测量回滚。
    public static func preferred(
        current: VoiceProfile?,
        standalone: VoiceProfile?
    ) -> VoiceProfile? {
        guard let standalone,
              standalone.hasValidMeasuredRange else {
            return current
        }
        guard let current,
              current.hasValidMeasuredRange else {
            return standalone
        }
        return standalone.createdAt >= current.createdAt ? standalone : current
    }

    /// 旧版本可能只把实测音区写进工作流快照。独立记录缺失时将有效实测
    /// 迁移过去，避免后续清理工作流快照时一并丢失最近一次测量。
    public static func standaloneMigrationCandidate(
        current: VoiceProfile?
    ) -> VoiceProfile? {
        guard let current, current.hasValidMeasuredRange else { return nil }
        return current
    }
}

public actor VoiceProfileStore {
    private static let currentSchemaVersion = 1
    private static let maximumArchiveByteCount: UInt64 = 256 * 1_024

    private struct Archive: Codable {
        let schemaVersion: Int
        let profile: VoiceProfile
    }

    private struct VersionHeader: Decodable {
        let schemaVersion: Int
    }

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func loadWithStatus() throws -> VersionedStoreLoadResult<VoiceProfile> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        if try fileExceedsMaximumByteCount(at: url, maximumByteCount: Self.maximumArchiveByteCount) {
            try quarantine(reason: "oversized")
            return .quarantined(.oversized)
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()

        guard let header = try? decoder.decode(VersionHeader.self, from: data) else {
            try quarantine(reason: "corrupt")
            return .quarantined(.corrupt)
        }
        guard header.schemaVersion == Self.currentSchemaVersion else {
            try quarantine(reason: "incompatible")
            return .quarantined(.incompatibleVersion)
        }
        do {
            let profile = try decoder.decode(Archive.self, from: data).profile
            guard profile.hasValidMeasuredRange else {
                try quarantine(reason: "corrupt")
                return .quarantined(.corrupt)
            }
            return .loaded(profile)
        } catch {
            try quarantine(reason: "corrupt")
            return .quarantined(.corrupt)
        }
    }

    @discardableResult
    public func saveIfEligible(_ profile: VoiceProfile) throws -> Bool {
        guard profile.hasValidMeasuredRange else { return false }
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let archive = Archive(schemaVersion: Self.currentSchemaVersion, profile: profile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(archive).write(to: url, options: [.atomic])
        return true
    }

    public func clear() throws {
        let directory = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let baseName = url.deletingPathExtension().lastPathComponent
        let fileExtension = url.pathExtension
        let prefixes = [
            "\(baseName).corrupt-",
            "\(baseName).incompatible-",
            "\(baseName).oversized-"
        ]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let isCurrent = name == url.lastPathComponent
            let isQuarantine = prefixes.contains { prefix in
                name.hasPrefix(prefix) && (fileExtension.isEmpty || name.hasSuffix(".\(fileExtension)"))
            }
            if isCurrent || isQuarantine {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
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

private func fileExceedsMaximumByteCount(at url: URL, maximumByteCount: UInt64) throws -> Bool {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let fileSize = attributes[.size] as? NSNumber else { return false }
    return fileSize.uint64Value > maximumByteCount
}

public struct VoiceProfilePersistenceRequestGate: Equatable, Sendable {
    public private(set) var generation: UInt64

    public init(generation: UInt64 = 0) {
        self.generation = generation
    }

    @discardableResult
    public mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    public mutating func invalidate() {
        generation &+= 1
    }

    public func accepts(_ request: UInt64) -> Bool {
        request == generation
    }
}
