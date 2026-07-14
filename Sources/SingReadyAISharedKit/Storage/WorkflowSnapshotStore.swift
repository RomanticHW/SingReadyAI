import Foundation

public enum PlaylistImportTextPreflight {
    public static let maximumCharacterCount = 50_000
    public static let maximumPhysicalLineCount = 1_000
    public static let limitMessage = "每次最多导入 5 万字、1000 行，请分成几份再试。"

    public static func accepts(_ text: String) -> Bool {
        guard text.count <= maximumCharacterCount else { return false }

        var physicalLineCount = 1
        for character in text where character.isNewline {
            physicalLineCount += 1
            guard physicalLineCount <= maximumPhysicalLineCount else { return false }
        }
        return true
    }
}

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

public enum PersistedPlanRecord: Codable, Sendable {
    case ready(plan: SongPlan, basis: PlanBasis)
    case stale(StalePlanSnapshot)

    private enum Kind: String, Codable {
        case ready
        case stale
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case plan
        case basis
        case reason
    }

    public init?(planGenerationState: PlanGenerationState) {
        switch planGenerationState {
        case .absent:
            return nil
        case let .ready(plan, basis):
            self = .ready(plan: plan, basis: basis)
        case let .stale(snapshot):
            self = .stale(snapshot)
        case let .generating(_, previous), let .failed(_, _, previous):
            guard let previous else { return nil }
            self = .stale(previous)
        }
    }

    public var restoredPlanGenerationState: PlanGenerationState {
        switch self {
        case let .ready(plan, basis):
            return .ready(plan: plan, basis: basis)
        case let .stale(snapshot):
            return .stale(snapshot)
        }
    }

    public static func restoredPlanGenerationState(
        from record: PersistedPlanRecord?
    ) -> PlanGenerationState {
        record?.restoredPlanGenerationState ?? .absent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let plan = try container.decode(SongPlan.self, forKey: .plan)

        switch kind {
        case .ready:
            self = .ready(
                plan: plan,
                basis: try container.decode(PlanBasis.self, forKey: .basis)
            )
        case .stale:
            self = .stale(
                StalePlanSnapshot(
                    plan: plan,
                    previousBasis: try container.decodeIfPresent(PlanBasis.self, forKey: .basis),
                    reason: try container.decode(String.self, forKey: .reason)
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .ready(plan, basis):
            try container.encode(Kind.ready, forKey: .kind)
            try container.encode(plan, forKey: .plan)
            try container.encode(basis, forKey: .basis)
            try container.encodeNil(forKey: .reason)
        case let .stale(snapshot):
            try container.encode(Kind.stale, forKey: .kind)
            try container.encode(snapshot.plan, forKey: .plan)
            if let previousBasis = snapshot.previousBasis {
                try container.encode(previousBasis, forKey: .basis)
            } else {
                try container.encodeNil(forKey: .basis)
            }
            try container.encode(snapshot.reason, forKey: .reason)
        }
    }
}

fileprivate struct LegacyWorkflowDerivationBridge: Codable, Sendable {
    var matches: [MatchResult]
    var preferenceProfile: PreferenceProfile?
    var songPlan: SongPlan?
    var externalCandidateTracks: [KTVTrack]

    static let empty = LegacyWorkflowDerivationBridge(
        matches: [],
        preferenceProfile: nil,
        songPlan: nil,
        externalCandidateTracks: []
    )

    var isEmpty: Bool {
        matches.isEmpty
            && preferenceProfile == nil
            && songPlan == nil
            && externalCandidateTracks.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case matches
        case preferenceProfile
        case songPlan
        case externalCandidateTracks
    }

    init(
        matches: [MatchResult],
        preferenceProfile: PreferenceProfile?,
        songPlan: SongPlan?,
        externalCandidateTracks: [KTVTrack]
    ) {
        self.matches = matches
        self.preferenceProfile = preferenceProfile
        self.songPlan = songPlan
        self.externalCandidateTracks = externalCandidateTracks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        matches = try container.decodeIfPresent([MatchResult].self, forKey: .matches) ?? []
        preferenceProfile = try container.decodeIfPresent(
            PreferenceProfile.self,
            forKey: .preferenceProfile
        )
        songPlan = try container.decodeIfPresent(SongPlan.self, forKey: .songPlan)
        externalCandidateTracks = try container.decodeIfPresent(
            [KTVTrack].self,
            forKey: .externalCandidateTracks
        ) ?? []
    }
}

public struct WorkflowSnapshot: Codable, Sendable {
    public let importedPlaylist: ImportedPlaylist
    public let reviewSongs: [WorkflowReviewSong]
    public let revisions: WorkflowRevisionLedger
    public let completedAnalysis: CompletedPlaylistAnalysis?
    public let persistedPlanRecord: PersistedPlanRecord?
    public let externalCandidateCollection: ExternalCandidateCollection?
    public let voiceProfile: VoiceProfile?
    public let recommendationInputSource: RecommendationInputSource
    public let scenarioConfig: ScenarioConfig
    public let lockedTrackIDs: [String]
    public let removedTrackIDs: [String]
    public let feedbackProfile: SongFeedbackProfile
    public let hasAdvancedToScenario: Bool?
    public let updatedAt: Date

    private let legacyDerivationBridge: LegacyWorkflowDerivationBridge

    public var matches: [MatchResult] {
        completedAnalysis?.matches ?? legacyDerivationBridge.matches
    }

    public var preferenceProfile: PreferenceProfile? {
        completedAnalysis?.preferenceProfile ?? legacyDerivationBridge.preferenceProfile
    }

    public var songPlan: SongPlan? {
        if let persistedPlanRecord {
            switch persistedPlanRecord {
            case let .ready(plan, _):
                return plan
            case let .stale(snapshot):
                return snapshot.plan
            }
        }
        return legacyDerivationBridge.songPlan
    }

    public var externalCandidateTracks: [KTVTrack] {
        externalCandidateCollection == nil
            ? legacyDerivationBridge.externalCandidateTracks
            : []
    }

    public init(
        importedPlaylist: ImportedPlaylist,
        reviewSongs: [WorkflowReviewSong],
        revisions: WorkflowRevisionLedger,
        completedAnalysis: CompletedPlaylistAnalysis?,
        persistedPlanRecord: PersistedPlanRecord?,
        externalCandidateCollection: ExternalCandidateCollection?,
        voiceProfile: VoiceProfile?,
        recommendationInputSource: RecommendationInputSource,
        scenarioConfig: ScenarioConfig,
        lockedTrackIDs: [String],
        removedTrackIDs: [String],
        feedbackProfile: SongFeedbackProfile,
        hasAdvancedToScenario: Bool = false,
        legacySongPlan: SongPlan? = nil,
        legacyExternalCandidateTracks: [KTVTrack] = [],
        updatedAt: Date = Date()
    ) {
        self.init(
            importedPlaylist: importedPlaylist,
            reviewSongs: reviewSongs,
            revisions: revisions,
            completedAnalysis: completedAnalysis,
            persistedPlanRecord: persistedPlanRecord,
            externalCandidateCollection: externalCandidateCollection,
            voiceProfile: voiceProfile,
            recommendationInputSource: recommendationInputSource,
            scenarioConfig: scenarioConfig,
            lockedTrackIDs: lockedTrackIDs,
            removedTrackIDs: removedTrackIDs,
            feedbackProfile: feedbackProfile,
            hasAdvancedToScenario: hasAdvancedToScenario,
            updatedAt: updatedAt,
            legacyDerivationBridge: LegacyWorkflowDerivationBridge(
                matches: [],
                preferenceProfile: nil,
                songPlan: legacySongPlan,
                externalCandidateTracks: legacyExternalCandidateTracks
            )
        )
    }

    /// 迁移期间供旧 App 调用点和 schema 1 壳使用；新流程只写入上面的 v2 状态。
    public init(
        importedPlaylist: ImportedPlaylist,
        reviewSongs: [WorkflowReviewSong],
        revisions: WorkflowRevisionLedger = WorkflowRevisionLedger(),
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
        self.init(
            importedPlaylist: importedPlaylist,
            reviewSongs: reviewSongs,
            revisions: revisions,
            completedAnalysis: nil,
            persistedPlanRecord: nil,
            externalCandidateCollection: nil,
            voiceProfile: voiceProfile,
            recommendationInputSource: recommendationInputSource,
            scenarioConfig: scenarioConfig,
            lockedTrackIDs: lockedTrackIDs,
            removedTrackIDs: removedTrackIDs,
            feedbackProfile: feedbackProfile,
            hasAdvancedToScenario: hasAdvancedToScenario,
            updatedAt: updatedAt,
            legacyDerivationBridge: LegacyWorkflowDerivationBridge(
                matches: matches,
                preferenceProfile: preferenceProfile,
                songPlan: songPlan,
                externalCandidateTracks: externalCandidateTracks
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case importedPlaylist
        case reviewSongs
        case revisions
        case completedAnalysis
        case persistedPlanRecord
        case externalCandidateCollection
        case voiceProfile
        case recommendationInputSource
        case scenarioConfig
        case lockedTrackIDs
        case removedTrackIDs
        case feedbackProfile
        case hasAdvancedToScenario
        case updatedAt
        case legacyDerivationBridge
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            importedPlaylist: try container.decode(ImportedPlaylist.self, forKey: .importedPlaylist),
            reviewSongs: try container.decode([WorkflowReviewSong].self, forKey: .reviewSongs),
            revisions: try container.decode(WorkflowRevisionLedger.self, forKey: .revisions),
            completedAnalysis: try container.decodeIfPresent(
                CompletedPlaylistAnalysis.self,
                forKey: .completedAnalysis
            ),
            persistedPlanRecord: try container.decodeIfPresent(
                PersistedPlanRecord.self,
                forKey: .persistedPlanRecord
            ),
            externalCandidateCollection: try container.decodeIfPresent(
                ExternalCandidateCollection.self,
                forKey: .externalCandidateCollection
            ),
            voiceProfile: try container.decodeIfPresent(VoiceProfile.self, forKey: .voiceProfile),
            recommendationInputSource: try container.decode(
                RecommendationInputSource.self,
                forKey: .recommendationInputSource
            ),
            scenarioConfig: try container.decode(ScenarioConfig.self, forKey: .scenarioConfig),
            lockedTrackIDs: try container.decode([String].self, forKey: .lockedTrackIDs),
            removedTrackIDs: try container.decode([String].self, forKey: .removedTrackIDs),
            feedbackProfile: try container.decode(SongFeedbackProfile.self, forKey: .feedbackProfile),
            hasAdvancedToScenario: try container.decodeIfPresent(
                Bool.self,
                forKey: .hasAdvancedToScenario
            ),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            legacyDerivationBridge: try container.decodeIfPresent(
                LegacyWorkflowDerivationBridge.self,
                forKey: .legacyDerivationBridge
            ) ?? .empty
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(importedPlaylist, forKey: .importedPlaylist)
        try container.encode(reviewSongs, forKey: .reviewSongs)
        try container.encode(revisions, forKey: .revisions)
        try container.encodeIfPresent(completedAnalysis, forKey: .completedAnalysis)
        try container.encodeIfPresent(persistedPlanRecord, forKey: .persistedPlanRecord)
        try container.encodeIfPresent(externalCandidateCollection, forKey: .externalCandidateCollection)
        try container.encodeIfPresent(voiceProfile, forKey: .voiceProfile)
        try container.encode(recommendationInputSource, forKey: .recommendationInputSource)
        try container.encode(scenarioConfig, forKey: .scenarioConfig)
        try container.encode(lockedTrackIDs, forKey: .lockedTrackIDs)
        try container.encode(removedTrackIDs, forKey: .removedTrackIDs)
        try container.encode(feedbackProfile, forKey: .feedbackProfile)
        try container.encodeIfPresent(hasAdvancedToScenario, forKey: .hasAdvancedToScenario)
        try container.encode(updatedAt, forKey: .updatedAt)
        if !legacyDerivationBridge.isEmpty {
            try container.encode(legacyDerivationBridge, forKey: .legacyDerivationBridge)
        }
    }

    fileprivate init(
        importedPlaylist: ImportedPlaylist,
        reviewSongs: [WorkflowReviewSong],
        revisions: WorkflowRevisionLedger,
        completedAnalysis: CompletedPlaylistAnalysis?,
        persistedPlanRecord: PersistedPlanRecord?,
        externalCandidateCollection: ExternalCandidateCollection?,
        voiceProfile: VoiceProfile?,
        recommendationInputSource: RecommendationInputSource,
        scenarioConfig: ScenarioConfig,
        lockedTrackIDs: [String],
        removedTrackIDs: [String],
        feedbackProfile: SongFeedbackProfile,
        hasAdvancedToScenario: Bool?,
        updatedAt: Date,
        legacyDerivationBridge: LegacyWorkflowDerivationBridge
    ) {
        let normalizedLockedIDs = Array(Set(lockedTrackIDs)).sorted()
        let lockedIDSet = Set(normalizedLockedIDs)
        var normalizedLegacyBridge = legacyDerivationBridge

        if completedAnalysis != nil {
            normalizedLegacyBridge.matches = []
            normalizedLegacyBridge.preferenceProfile = nil
        }
        if persistedPlanRecord != nil {
            normalizedLegacyBridge.songPlan = nil
        }
        if externalCandidateCollection != nil {
            normalizedLegacyBridge.externalCandidateTracks = []
        }

        self.importedPlaylist = importedPlaylist
        self.reviewSongs = reviewSongs
        self.revisions = revisions
        self.completedAnalysis = completedAnalysis
        self.persistedPlanRecord = persistedPlanRecord
        self.externalCandidateCollection = externalCandidateCollection
        self.voiceProfile = voiceProfile
        self.recommendationInputSource = recommendationInputSource
        self.scenarioConfig = scenarioConfig
        self.lockedTrackIDs = normalizedLockedIDs
        self.removedTrackIDs = Array(Set(removedTrackIDs).subtracting(lockedIDSet)).sorted()
        self.feedbackProfile = feedbackProfile
        self.hasAdvancedToScenario = hasAdvancedToScenario
        self.updatedAt = updatedAt
        self.legacyDerivationBridge = normalizedLegacyBridge
    }
}

public struct WorkflowSnapshotStore: Sendable {
    private static let currentSchemaVersion = 2
    private static let maximumArchiveByteCount: UInt64 = 16 * 1_024 * 1_024

    private struct ArchiveV2: Codable {
        let schemaVersion: Int
        let snapshot: WorkflowSnapshot
    }

    private struct ArchiveV1: Decodable {
        let schemaVersion: Int
        let snapshot: Snapshot

        struct Snapshot: Decodable {
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
        switch header.schemaVersion {
        case 1:
            do {
                return .loaded(migrateShell(try decoder.decode(ArchiveV1.self, from: data)))
            } catch {
                try quarantine(reason: "corrupt")
                return .quarantined(.corrupt)
            }
        case Self.currentSchemaVersion:
            do {
                return .loaded(try decoder.decode(ArchiveV2.self, from: data).snapshot)
            } catch {
                try quarantine(reason: "corrupt")
                return .quarantined(.corrupt)
            }
        default:
            try quarantine(reason: "incompatible")
            return .quarantined(.incompatibleVersion)
        }
    }

    public func save(_ snapshot: WorkflowSnapshot) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let archive = ArchiveV2(schemaVersion: Self.currentSchemaVersion, snapshot: snapshot)
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

    private func migrateShell(_ archive: ArchiveV1) -> WorkflowSnapshot {
        let snapshot = archive.snapshot
        return WorkflowSnapshot(
            importedPlaylist: snapshot.importedPlaylist,
            reviewSongs: snapshot.reviewSongs,
            revisions: WorkflowRevisionLedger(),
            completedAnalysis: nil,
            persistedPlanRecord: nil,
            externalCandidateCollection: nil,
            voiceProfile: snapshot.voiceProfile,
            recommendationInputSource: snapshot.recommendationInputSource,
            scenarioConfig: snapshot.scenarioConfig,
            lockedTrackIDs: snapshot.lockedTrackIDs,
            removedTrackIDs: snapshot.removedTrackIDs,
            feedbackProfile: snapshot.feedbackProfile,
            hasAdvancedToScenario: snapshot.hasAdvancedToScenario,
            updatedAt: snapshot.updatedAt,
            legacyDerivationBridge: LegacyWorkflowDerivationBridge(
                matches: snapshot.matches,
                preferenceProfile: snapshot.preferenceProfile,
                songPlan: snapshot.songPlan,
                externalCandidateTracks: snapshot.externalCandidateTracks
            )
        )
    }
}

public enum WorkflowPersistenceRequestResult<Value: Sendable>: Sendable {
    case applied(Value)
    case rejectedStaleRequest
}

public enum WorkflowCommitResult: Equatable, Sendable {
    case applied
    case superseded
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

    /// 预约下一次工作流整体替换。预约和提交都在同一个 actor 内串行，
    /// 因此检查 generation、同步原子写盘和返回结果共同构成唯一线性化点。
    public func reserveWorkflowMutation(generation: UInt64) {
        guard generation > workflowSnapshotGeneration else { return }
        workflowSnapshotGeneration = generation
    }

    public func commitWorkflowSnapshot(
        _ snapshot: WorkflowSnapshot,
        generation: UInt64
    ) async throws -> WorkflowCommitResult {
        guard generation == workflowSnapshotGeneration else { return .superseded }
        beforeOperation(.saveWorkflowSnapshot)
        try workflowSnapshotStore.save(snapshot)
        return .applied
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
