import Foundation

public enum ImportSource: String, Codable, CaseIterable, Sendable {
    case netEaseMusic
    case qqMusic
    case appleMusic
    case plainText
    case screenshot
    case genericURL
    case curated
    case demo
    case unknown

    public var displayName: String {
        switch self {
        case .netEaseMusic: return "网易云音乐"
        case .qqMusic: return "QQ 音乐"
        case .appleMusic: return "Apple Music"
        case .plainText: return "粘贴文本"
        case .screenshot: return "截图识别"
        case .genericURL: return "网页链接"
        case .curated: return "热门歌单"
        case .demo: return "热门歌单"
        case .unknown: return "未知来源"
        }
    }

}

public struct PendingImportPayload: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var sourceHint: ImportSource
    public var rawText: String?
    public var urlString: String?
    public var imageFileName: String?
    public var hostAppName: String?
    public var displayTitle: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceHint: ImportSource,
        rawText: String? = nil,
        urlString: String? = nil,
        imageFileName: String? = nil,
        hostAppName: String? = nil,
        displayTitle: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceHint = sourceHint
        self.rawText = rawText
        self.urlString = urlString
        self.imageFileName = imageFileName
        self.hostAppName = hostAppName
        self.displayTitle = displayTitle
    }
}

public struct ImportedSong: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var artist: String?
    public var source: ImportSource
    public var rawText: String?
    public var confidence: Double
    public var normalizedTitle: String
    public var normalizedArtist: String?
    public var versionTags: [String]

    public init(
        id: UUID = UUID(),
        title: String,
        artist: String? = nil,
        source: ImportSource,
        rawText: String? = nil,
        confidence: Double,
        normalizedTitle: String? = nil,
        normalizedArtist: String? = nil,
        versionTags: [String] = []
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = artist?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.source = source
        self.rawText = rawText
        self.confidence = min(max(confidence, 0), 1)
        self.normalizedTitle = normalizedTitle ?? SongNormalizer.normalizeTitle(title)
        self.normalizedArtist = normalizedArtist ?? self.artist.map(SongNormalizer.normalizeArtist)
        self.versionTags = versionTags
    }
}

public struct ImportedPlaylist: Codable, Identifiable, Sendable {
    public var id: UUID
    public var source: ImportSource
    public var title: String
    public var externalURL: URL?
    public var songs: [ImportedSong]
    public var createdAt: Date
    public var parseConfidence: Double

    public init(
        id: UUID = UUID(),
        source: ImportSource,
        title: String,
        externalURL: URL? = nil,
        songs: [ImportedSong],
        createdAt: Date = Date(),
        parseConfidence: Double
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.externalURL = externalURL
        self.songs = songs
        self.createdAt = createdAt
        self.parseConfidence = min(max(parseConfidence, 0), 1)
    }
}

public struct KTVTrack: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let language: String
    public let era: String
    public let genre: String
    public let moodTags: [String]
    public let sceneTags: [String]
    public let difficulty: Int
    public let vocalRangeLowMidi: Int
    public let vocalRangeHighMidi: Int
    public let energy: Double
    public let singAlongScore: Double
    public let ktvAvailability: Double
    public let duetFriendly: Bool
    public let rapDensity: Double
    public let highNoteRisk: Double
    public let aliases: [String]
    public let versionTags: [String]
    public let similarSongIds: [String]
    public let externalURL: URL?
    public let catalogSource: TrackCatalogSource
    public let confidenceNote: String?
    public let externalCandidateMetadata: ExternalCandidateMetadata?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case artist
        case language
        case era
        case genre
        case moodTags
        case sceneTags
        case difficulty
        case vocalRangeLowMidi
        case vocalRangeHighMidi
        case energy
        case singAlongScore
        case ktvAvailability
        case duetFriendly
        case rapDensity
        case highNoteRisk
        case aliases
        case versionTags
        case similarSongIds
        case externalURL
        case catalogSource
        case confidenceNote
        case externalCandidateMetadata
    }

    public init(
        id: String,
        title: String,
        artist: String,
        language: String,
        era: String,
        genre: String,
        moodTags: [String],
        sceneTags: [String],
        difficulty: Int,
        vocalRangeLowMidi: Int,
        vocalRangeHighMidi: Int,
        energy: Double,
        singAlongScore: Double,
        ktvAvailability: Double,
        duetFriendly: Bool,
        rapDensity: Double,
        highNoteRisk: Double,
        aliases: [String],
        versionTags: [String] = [],
        similarSongIds: [String],
        externalURL: URL? = nil,
        catalogSource: TrackCatalogSource = .ktvCatalog,
        confidenceNote: String? = nil,
        externalCandidateMetadata: ExternalCandidateMetadata? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.language = language
        self.era = era
        self.genre = genre
        self.moodTags = moodTags
        self.sceneTags = sceneTags
        self.difficulty = difficulty
        self.vocalRangeLowMidi = vocalRangeLowMidi
        self.vocalRangeHighMidi = vocalRangeHighMidi
        self.energy = energy
        self.singAlongScore = singAlongScore
        self.ktvAvailability = ktvAvailability
        self.duetFriendly = duetFriendly
        self.rapDensity = rapDensity
        self.highNoteRisk = highNoteRisk
        self.aliases = aliases
        self.versionTags = versionTags
        self.similarSongIds = similarSongIds
        self.externalURL = externalURL
        self.catalogSource = catalogSource
        self.confidenceNote = confidenceNote
        self.externalCandidateMetadata = externalCandidateMetadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        language = try container.decode(String.self, forKey: .language)
        era = try container.decode(String.self, forKey: .era)
        genre = try container.decode(String.self, forKey: .genre)
        moodTags = try container.decode([String].self, forKey: .moodTags)
        sceneTags = try container.decode([String].self, forKey: .sceneTags)
        difficulty = try container.decode(Int.self, forKey: .difficulty)
        vocalRangeLowMidi = try container.decode(Int.self, forKey: .vocalRangeLowMidi)
        vocalRangeHighMidi = try container.decode(Int.self, forKey: .vocalRangeHighMidi)
        energy = try container.decode(Double.self, forKey: .energy)
        singAlongScore = try container.decode(Double.self, forKey: .singAlongScore)
        ktvAvailability = try container.decode(Double.self, forKey: .ktvAvailability)
        duetFriendly = try container.decode(Bool.self, forKey: .duetFriendly)
        rapDensity = try container.decode(Double.self, forKey: .rapDensity)
        highNoteRisk = try container.decode(Double.self, forKey: .highNoteRisk)
        aliases = try container.decode([String].self, forKey: .aliases)
        versionTags = try container.decodeIfPresent([String].self, forKey: .versionTags) ?? []
        similarSongIds = try container.decode([String].self, forKey: .similarSongIds)
        externalURL = try container.decodeIfPresent(URL.self, forKey: .externalURL)
        catalogSource = try container.decodeIfPresent(TrackCatalogSource.self, forKey: .catalogSource) ?? .ktvCatalog
        confidenceNote = try container.decodeIfPresent(String.self, forKey: .confidenceNote)
        externalCandidateMetadata = try container.decodeIfPresent(
            ExternalCandidateMetadata.self,
            forKey: .externalCandidateMetadata
        )
    }

    /// 外部公开搜索只能提供候选关系，不能证明 KTV 曲库、音域或难度数据。
    /// 旧版本没有写入 metadata，因此以 catalogSource 作为不可降级的兼容边界。
    public var isProvisionalExternalCandidate: Bool {
        catalogSource == .externalSimilar
    }

    /// 外部候选只能陈述公开来源关系，不得沿用音域、难度、合唱或场景结论。
    public var provisionalDisclosureReasons: [String] {
        guard isProvisionalExternalCandidate else { return [] }
        switch externalCandidateMetadata?.relation {
        case .sameArtist:
            return ["同歌手公开候选，KTV 收录与现场数据待核对"]
        case .similarTrack:
            return ["公开相似曲目候选，KTV 收录与现场数据待核对"]
        case nil:
            return ["公开搜索候选，KTV 收录与现场数据待核对"]
        }
    }
}

public enum ExternalCandidateRelation: String, Codable, CaseIterable, Hashable, Sendable {
    case sameArtist
    case similarTrack

    public var displayName: String {
        switch self {
        case .sameArtist:
            return "同歌手备选"
        case .similarTrack:
            return "相似曲目备选"
        }
    }
}

public struct ExternalCandidateMetadata: Codable, Equatable, Hashable, Sendable {
    public let relation: ExternalCandidateRelation
    public let relevance: Double
    public let reasons: [String]
    public let provider: ExternalMusicSource

    public init(
        relation: ExternalCandidateRelation,
        relevance: Double,
        reasons: [String],
        provider: ExternalMusicSource
    ) {
        self.relation = relation
        self.relevance = min(max(relevance, 0), 1)
        self.reasons = reasons
        self.provider = provider
    }

    enum CodingKeys: String, CodingKey {
        case relation
        case relevance
        case reasons
        case provider
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            relation: try container.decode(ExternalCandidateRelation.self, forKey: .relation),
            relevance: try container.decode(Double.self, forKey: .relevance),
            reasons: try container.decodeIfPresent([String].self, forKey: .reasons) ?? [],
            provider: try container.decode(ExternalMusicSource.self, forKey: .provider)
        )
    }
}

public enum TrackCatalogSource: String, Codable, CaseIterable, Sendable {
    case ktvCatalog
    case externalSimilar

    public var displayName: String {
        switch self {
        case .ktvCatalog: return "本地参考曲库"
        case .externalSimilar: return "外部候选 · 待核对"
        }
    }
}

public enum MatchStatus: String, Codable, CaseIterable, Sendable {
    case exact
    case fuzzy
    case alternative
    case unmatched

    public var displayName: String {
        switch self {
        case .exact: return "参考命中"
        case .fuzzy: return "歌名相近"
        case .alternative: return "可替代"
        case .unmatched: return "暂时没找到"
        }
    }
}

public enum MatchConfirmationState: String, Codable, CaseIterable, Sendable {
    case notRequired
    case required
    case confirmed
}

public enum SongMatchDisposition: Codable, Sendable {
    case acceptedOriginalExact(track: KTVTrack)
    case acceptedOriginalConfirmed(track: KTVTrack)
    case identityConfirmationRequired(candidates: [KTVTrack])
    case alternativeSuggested(candidates: [KTVTrack])
    case adoptedAlternative(track: KTVTrack)
    case unmatched

    private enum Kind: String, Codable {
        case acceptedOriginalExact
        case acceptedOriginalConfirmed
        case identityConfirmationRequired
        case alternativeSuggested
        case adoptedAlternative
        case unmatched
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case track
        case candidates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .acceptedOriginalExact:
            self = .acceptedOriginalExact(track: try container.decode(KTVTrack.self, forKey: .track))
        case .acceptedOriginalConfirmed:
            self = .acceptedOriginalConfirmed(track: try container.decode(KTVTrack.self, forKey: .track))
        case .identityConfirmationRequired:
            self = .identityConfirmationRequired(
                candidates: try container.decode([KTVTrack].self, forKey: .candidates)
            )
        case .alternativeSuggested:
            self = .alternativeSuggested(
                candidates: try container.decode([KTVTrack].self, forKey: .candidates)
            )
        case .adoptedAlternative:
            self = .adoptedAlternative(track: try container.decode(KTVTrack.self, forKey: .track))
        case .unmatched:
            self = .unmatched
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .acceptedOriginalExact(track):
            try container.encode(Kind.acceptedOriginalExact, forKey: .kind)
            try container.encode(track, forKey: .track)
        case let .acceptedOriginalConfirmed(track):
            try container.encode(Kind.acceptedOriginalConfirmed, forKey: .kind)
            try container.encode(track, forKey: .track)
        case let .identityConfirmationRequired(candidates):
            try container.encode(Kind.identityConfirmationRequired, forKey: .kind)
            try container.encode(candidates, forKey: .candidates)
        case let .alternativeSuggested(candidates):
            try container.encode(Kind.alternativeSuggested, forKey: .kind)
            try container.encode(candidates, forKey: .candidates)
        case let .adoptedAlternative(track):
            try container.encode(Kind.adoptedAlternative, forKey: .kind)
            try container.encode(track, forKey: .track)
        case .unmatched:
            try container.encode(Kind.unmatched, forKey: .kind)
        }
    }
}

public struct MatchResultDisplayPolicy: Sendable {
    public static let batchSize = 5

    private init() {}

    public static func initialVisibleCount(totalCount: Int) -> Int {
        min(batchSize, max(0, totalCount))
    }

    public static func nextVisibleCount(currentCount: Int, totalCount: Int) -> Int {
        min(max(0, totalCount), max(0, currentCount) + batchSize)
    }
}

public struct MatchResult: Codable, Identifiable, Sendable {
    public var id: UUID
    public let importedSong: ImportedSong
    public private(set) var disposition: SongMatchDisposition
    public private(set) var suggestedAlternatives: [KTVTrack]
    public var score: Double
    public var reason: String

    public var acceptedTrack: KTVTrack? {
        switch disposition {
        case let .acceptedOriginalExact(track),
             let .acceptedOriginalConfirmed(track),
             let .adoptedAlternative(track):
            return track
        case .identityConfirmationRequired, .alternativeSuggested, .unmatched:
            return nil
        }
    }

    public var candidateTracks: [KTVTrack] {
        switch disposition {
        case let .identityConfirmationRequired(candidates),
             let .alternativeSuggested(candidates):
            return candidates
        case .acceptedOriginalExact,
             .acceptedOriginalConfirmed,
             .adoptedAlternative,
             .unmatched:
            return []
        }
    }

    public var isVerified: Bool {
        acceptedTrack != nil
    }

    public var isPending: Bool {
        switch disposition {
        case .identityConfirmationRequired, .alternativeSuggested:
            return true
        case .acceptedOriginalExact,
             .acceptedOriginalConfirmed,
             .adoptedAlternative,
             .unmatched:
            return false
        }
    }

    public var isUnmatched: Bool {
        if case .unmatched = disposition {
            return true
        }
        return false
    }

    public var hasOriginalReferenceMatch: Bool {
        switch disposition {
        case .acceptedOriginalExact, .acceptedOriginalConfirmed:
            return true
        case .identityConfirmationRequired,
             .alternativeSuggested,
             .adoptedAlternative,
             .unmatched:
            return false
        }
    }

    public var isAdoptedAlternative: Bool {
        if case .adoptedAlternative = disposition {
            return true
        }
        return false
    }

    public var needsAlternativeAdoption: Bool {
        if case .alternativeSuggested = disposition {
            return true
        }
        return false
    }

    // Migration-only 只读适配器；Task 16 在生产调用点迁移完成后删除。
    public var matchedTrack: KTVTrack? {
        acceptedTrack
    }

    // Migration-only 只读适配器；候选或建议均由 disposition 单向派生。
    public var alternatives: [KTVTrack] {
        candidateTracks.isEmpty ? suggestedAlternatives : candidateTracks
    }

    // Migration-only 只读适配器；不得作为新的状态判断真源。
    public var status: MatchStatus {
        switch disposition {
        case .acceptedOriginalExact, .acceptedOriginalConfirmed:
            return .exact
        case .identityConfirmationRequired:
            return .fuzzy
        case .alternativeSuggested, .adoptedAlternative:
            return .alternative
        case .unmatched:
            return .unmatched
        }
    }

    // Migration-only 只读适配器；不得与 disposition 分开保存。
    public var confirmationState: MatchConfirmationState {
        switch disposition {
        case .acceptedOriginalConfirmed:
            return .confirmed
        case .identityConfirmationRequired:
            return .required
        case .acceptedOriginalExact,
             .alternativeSuggested,
             .adoptedAlternative,
             .unmatched:
            return .notRequired
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case importedSong
        case disposition
        case suggestedAlternatives
        case score
        case reason

        // 仅用于旧快照单向迁移。
        case matchedTrack
        case alternatives
        case status
        case confirmationState
    }

    public init(
        id: UUID = UUID(),
        importedSong: ImportedSong,
        disposition: SongMatchDisposition,
        suggestedAlternatives: [KTVTrack] = [],
        score: Double,
        reason: String
    ) {
        let normalized = Self.normalized(
            importedSong: importedSong,
            disposition: disposition,
            suggestedAlternatives: suggestedAlternatives
        )
        self.id = id
        self.importedSong = importedSong
        self.disposition = normalized.disposition
        self.suggestedAlternatives = normalized.suggestedAlternatives
        self.score = min(max(score, 0), 1)
        self.reason = reason
    }

    // Migration-only 初始化器；旧字段只在此处做一次保守映射。
    public init(
        id: UUID = UUID(),
        importedSong: ImportedSong,
        matchedTrack: KTVTrack?,
        alternatives: [KTVTrack],
        status: MatchStatus,
        confirmationState: MatchConfirmationState = .notRequired,
        score: Double,
        reason: String
    ) {
        let migration = Self.migrateLegacyState(
            importedSong: importedSong,
            matchedTrack: matchedTrack,
            alternatives: alternatives,
            status: status,
            confirmationState: confirmationState
        )
        self.init(
            id: id,
            importedSong: importedSong,
            disposition: migration.disposition,
            suggestedAlternatives: migration.suggestedAlternatives,
            score: score,
            reason: reason
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(UUID.self, forKey: .id)
        let decodedImportedSong = try container.decode(ImportedSong.self, forKey: .importedSong)

        if container.contains(.disposition) {
            self.init(
                id: decodedID,
                importedSong: decodedImportedSong,
                disposition: try container.decode(SongMatchDisposition.self, forKey: .disposition),
                suggestedAlternatives: try container.decodeIfPresent(
                    [KTVTrack].self,
                    forKey: .suggestedAlternatives
                ) ?? [],
                score: try container.decode(Double.self, forKey: .score),
                reason: try container.decode(String.self, forKey: .reason)
            )
            return
        }

        let decodedMatchedTrack = try container.decodeIfPresent(KTVTrack.self, forKey: .matchedTrack)
        let decodedAlternatives = try container.decodeIfPresent([KTVTrack].self, forKey: .alternatives) ?? []
        let decodedStatus = try container.decodeIfPresent(MatchStatus.self, forKey: .status) ?? .unmatched
        let decodedConfirmationState = try container.decodeIfPresent(
            MatchConfirmationState.self,
            forKey: .confirmationState
        )
        let migration = Self.migrateLegacyState(
            importedSong: decodedImportedSong,
            matchedTrack: decodedMatchedTrack,
            alternatives: decodedAlternatives,
            status: decodedStatus,
            confirmationState: decodedConfirmationState ?? .notRequired
        )
        self.init(
            id: decodedID,
            importedSong: decodedImportedSong,
            disposition: migration.disposition,
            suggestedAlternatives: migration.suggestedAlternatives,
            score: try container.decode(Double.self, forKey: .score),
            reason: try container.decode(String.self, forKey: .reason)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(importedSong, forKey: .importedSong)
        try container.encode(disposition, forKey: .disposition)
        try container.encode(suggestedAlternatives, forKey: .suggestedAlternatives)
        try container.encode(score, forKey: .score)
        try container.encode(reason, forKey: .reason)
    }

    public func confirming(track: KTVTrack) -> MatchResult? {
        guard case let .identityConfirmationRequired(candidates) = disposition,
              let confirmedTrack = candidates.first(where: { $0.id == track.id }) else {
            return nil
        }

        return MatchResult(
            id: id,
            importedSong: importedSong,
            disposition: .acceptedOriginalConfirmed(track: confirmedTrack),
            score: 1,
            reason: "已确认歌名和歌手"
        )
    }

    public func adoptingAlternative(track: KTVTrack) -> MatchResult? {
        let selectableTracks = candidateTracks + suggestedAlternatives
        guard let adoptedTrack = selectableTracks.first(where: { $0.id == track.id }),
              adoptedTrack.id != acceptedTrack?.id else {
            return nil
        }

        var remainingTracks = selectableTracks.filter { $0.id != adoptedTrack.id }
        let previousTrack = acceptedTrack
        if let previousTrack,
           previousTrack.id != adoptedTrack.id,
           !remainingTracks.contains(where: { $0.id == previousTrack.id }) {
            remainingTracks.insert(previousTrack, at: 0)
        }

        return MatchResult(
            id: id,
            importedSong: importedSong,
            disposition: .adoptedAlternative(track: adoptedTrack),
            suggestedAlternatives: remainingTracks,
            score: score,
            reason: "已采用替代歌：\(adoptedTrack.title) - \(adoptedTrack.artist)"
        )
    }

    private static func normalized(
        importedSong: ImportedSong,
        disposition: SongMatchDisposition,
        suggestedAlternatives: [KTVTrack]
    ) -> (disposition: SongMatchDisposition, suggestedAlternatives: [KTVTrack]) {
        switch disposition {
        case let .acceptedOriginalExact(track):
            let suggestions = uniqueTracks(suggestedAlternatives)
                .filter { $0.id != track.id }
            guard track.matchesTitleIdentity(importedSong.title),
                  let importedArtist = importedSong.artist?.nilIfBlank,
                  track.matchesArtistIdentity(importedArtist) else {
                return pendingIdentityMigration(
                    importedSong: importedSong,
                    tracks: [track] + suggestions
                )
            }
            return (.acceptedOriginalExact(track: track), suggestions)
        case let .acceptedOriginalConfirmed(track):
            let suggestions = uniqueTracks(suggestedAlternatives)
                .filter { $0.id != track.id }
            guard track.matchesTitleIdentity(importedSong.title) else {
                return pendingIdentityMigration(
                    importedSong: importedSong,
                    tracks: [track] + suggestions
                )
            }
            return (.acceptedOriginalConfirmed(track: track), suggestions)
        case let .identityConfirmationRequired(candidates):
            let candidates = uniqueTracks(candidates)
            return candidates.isEmpty
                ? (.unmatched, [])
                : (.identityConfirmationRequired(candidates: candidates), [])
        case let .alternativeSuggested(candidates):
            let candidates = uniqueTracks(candidates)
            return candidates.isEmpty
                ? (.unmatched, [])
                : (.alternativeSuggested(candidates: candidates), [])
        case let .adoptedAlternative(track):
            let suggestions = uniqueTracks(suggestedAlternatives)
                .filter { $0.id != track.id }
            return (.adoptedAlternative(track: track), suggestions)
        case .unmatched:
            return (.unmatched, [])
        }
    }

    private static func migrateLegacyState(
        importedSong: ImportedSong,
        matchedTrack: KTVTrack?,
        alternatives: [KTVTrack],
        status: MatchStatus,
        confirmationState: MatchConfirmationState
    ) -> (disposition: SongMatchDisposition, suggestedAlternatives: [KTVTrack]) {
        let allTracks = uniqueTracks(([matchedTrack].compactMap(\.self) + alternatives))

        if confirmationState == .required {
            return pendingIdentityMigration(importedSong: importedSong, tracks: allTracks)
        }

        if confirmationState == .confirmed {
            guard let matchedTrack,
                  status == .exact || status == .fuzzy else {
                return pendingIdentityMigration(importedSong: importedSong, tracks: allTracks)
            }
            return (
                .acceptedOriginalConfirmed(track: matchedTrack),
                uniqueTracks(alternatives).filter { $0.id != matchedTrack.id }
            )
        }

        switch status {
        case .exact:
            guard let matchedTrack else {
                return pendingIdentityMigration(importedSong: importedSong, tracks: allTracks)
            }
            return (
                .acceptedOriginalExact(track: matchedTrack),
                uniqueTracks(alternatives).filter { $0.id != matchedTrack.id }
            )
        case .fuzzy:
            return pendingIdentityMigration(importedSong: importedSong, tracks: allTracks)
        case .alternative:
            if let matchedTrack {
                return (
                    .adoptedAlternative(track: matchedTrack),
                    uniqueTracks(alternatives).filter { $0.id != matchedTrack.id }
                )
            }
            let candidates = uniqueTracks(alternatives)
            return candidates.isEmpty
                ? (.unmatched, [])
                : (.alternativeSuggested(candidates: candidates), [])
        case .unmatched:
            if matchedTrack != nil {
                return pendingIdentityMigration(importedSong: importedSong, tracks: allTracks)
            }
            return (.unmatched, [])
        }
    }

    private static func pendingIdentityMigration(
        importedSong: ImportedSong,
        tracks: [KTVTrack]
    ) -> (disposition: SongMatchDisposition, suggestedAlternatives: [KTVTrack]) {
        let candidates = uniqueTracks(tracks)
            .filter { $0.matchesTitleIdentity(importedSong.title) }
        return candidates.isEmpty
            ? (.unmatched, [])
            : (.identityConfirmationRequired(candidates: candidates), [])
    }

    private static func uniqueTracks(_ tracks: [KTVTrack]) -> [KTVTrack] {
        var seenTrackIDs = Set<String>()
        return tracks.filter { seenTrackIDs.insert($0.id).inserted }
    }
}

public struct MatchStatistics: Equatable, Sendable {
    public var verified: Int
    public var pending: Int
    public var unmatched: Int
    public var originalAccepted: Int
    public var adoptedAlternative: Int

    // Migration-only 统计适配器；Task 15 完成界面迁移后删除。
    public var exact: Int
    public var fuzzy: Int
    public var pendingAlternative: Int

    public var total: Int {
        verified + pending + unmatched
    }

    public init(matches: [MatchResult]) {
        verified = 0
        pending = 0
        unmatched = 0
        originalAccepted = 0
        adoptedAlternative = 0
        exact = 0
        fuzzy = 0
        pendingAlternative = 0

        for match in matches {
            switch match.disposition {
            case .acceptedOriginalExact:
                verified += 1
                originalAccepted += 1
                exact += 1
            case .acceptedOriginalConfirmed:
                verified += 1
                originalAccepted += 1
                fuzzy += 1
            case .identityConfirmationRequired:
                pending += 1
            case .alternativeSuggested:
                pending += 1
                pendingAlternative += 1
            case .adoptedAlternative:
                verified += 1
                adoptedAlternative += 1
            case .unmatched:
                unmatched += 1
            }
        }
    }
}

public struct MatchConfirmationWorkflowState: Sendable {
    public var lockedTrackIDs: Set<String>
    public var removedTrackIDs: Set<String>
    public var externalCandidateTracks: [KTVTrack]
    public var songPlan: SongPlan?

    public init(
        lockedTrackIDs: Set<String>,
        removedTrackIDs: Set<String>,
        externalCandidateTracks: [KTVTrack],
        songPlan: SongPlan?
    ) {
        self.lockedTrackIDs = lockedTrackIDs
        self.removedTrackIDs = removedTrackIDs
        self.externalCandidateTracks = externalCandidateTracks
        self.songPlan = songPlan
    }
}

public enum MatchConfirmationStatePolicy {
    public static func afterConfirmingMatch(
        _ currentState: MatchConfirmationWorkflowState
    ) -> MatchConfirmationWorkflowState {
        var nextState = currentState
        nextState.songPlan = nil
        return nextState
    }
}

public enum VoiceType: String, Codable, CaseIterable, Sendable {
    case lowMale
    case midMale
    case highMale
    case lowFemale
    case midFemale
    case highFemale
    case unknown

    public var displayName: String {
        switch self {
        case .lowMale: return "低音男声"
        case .midMale: return "中音男声"
        case .highMale: return "高音男声"
        case .lowFemale: return "低音女声"
        case .midFemale: return "中音女声"
        case .highFemale: return "高音女声"
        case .unknown: return "未知"
        }
    }
}

public enum VoiceProfileSource: String, Codable, CaseIterable, Sendable {
    case measured
    case commonReference
    case legacyUnknown

    public var displayName: String {
        switch self {
        case .measured: return "本次唱到的音区"
        case .commonReference: return "常见音域参考"
        case .legacyUnknown: return "来源未记录"
        }
    }

    public var allowsMeasuredRangeClaims: Bool {
        self == .measured
    }
}

public struct VoiceProfile: Codable, Equatable, Sendable {
    public var type: VoiceType
    public var source: VoiceProfileSource
    public var minMidi: Int
    public var maxMidi: Int
    public var stableLowMidi: Int
    public var stableHighMidi: Int
    public var averageMidi: Double
    public var confidence: Double
    public var note: String
    public var suitableSongTypes: [String]
    public var avoidSongTypes: [String]
    public var singingStrategy: [String]
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case type
        case source
        case minMidi
        case maxMidi
        case stableLowMidi
        case stableHighMidi
        case averageMidi
        case confidence
        case note
        case suitableSongTypes
        case avoidSongTypes
        case singingStrategy
        case createdAt
    }

    public init(
        type: VoiceType,
        minMidi: Int,
        maxMidi: Int,
        stableLowMidi: Int,
        stableHighMidi: Int,
        averageMidi: Double,
        confidence: Double,
        note: String,
        source: VoiceProfileSource = .measured,
        suitableSongTypes: [String] = [],
        avoidSongTypes: [String] = [],
        singingStrategy: [String] = [],
        createdAt: Date = Date()
    ) {
        self.type = type
        self.source = source
        self.minMidi = minMidi
        self.maxMidi = maxMidi
        self.stableLowMidi = stableLowMidi
        self.stableHighMidi = stableHighMidi
        self.averageMidi = averageMidi
        self.confidence = min(max(confidence, 0), 1)
        self.note = note
        self.suitableSongTypes = suitableSongTypes
        self.avoidSongTypes = avoidSongTypes
        self.singingStrategy = singingStrategy
        self.createdAt = createdAt
    }

    public var userFacingSuitableSongTypes: [String] {
        genderNeutralVoiceTags(suitableSongTypes)
    }

    public var userFacingAvoidSongTypes: [String] {
        genderNeutralVoiceTags(avoidSongTypes)
    }

    public var hasValidMeasuredRange: Bool {
        source == .measured
            && confidence >= 0.5
            && stableLowMidi > 0
            && stableHighMidi > stableLowMidi
            && stableHighMidi - stableLowMidi >= 5
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(VoiceType.self, forKey: .type)
        let minMidi = try container.decode(Int.self, forKey: .minMidi)
        let maxMidi = try container.decode(Int.self, forKey: .maxMidi)
        let stableLowMidi = try container.decode(Int.self, forKey: .stableLowMidi)
        let stableHighMidi = try container.decode(Int.self, forKey: .stableHighMidi)
        let averageMidi = try container.decode(Double.self, forKey: .averageMidi)
        let confidence = try container.decode(Double.self, forKey: .confidence)
        let note = try container.decode(String.self, forKey: .note)
        let decodedSource = try container.decodeIfPresent(VoiceProfileSource.self, forKey: .source)
        let isLegacyCommonReference = decodedSource == nil && Self.matchesLegacyCommonReference(
            type: type,
            minMidi: minMidi,
            maxMidi: maxMidi,
            stableLowMidi: stableLowMidi,
            stableHighMidi: stableHighMidi,
            averageMidi: averageMidi,
            confidence: confidence,
            note: note
        )
        self.init(
            type: isLegacyCommonReference ? .unknown : type,
            minMidi: minMidi,
            maxMidi: maxMidi,
            stableLowMidi: stableLowMidi,
            stableHighMidi: stableHighMidi,
            averageMidi: averageMidi,
            confidence: isLegacyCommonReference ? 0 : confidence,
            note: isLegacyCommonReference ? "这是尚未实测时使用的常见音域参考。" : note,
            source: decodedSource ?? (isLegacyCommonReference ? .commonReference : .legacyUnknown),
            suitableSongTypes: try container.decodeIfPresent([String].self, forKey: .suitableSongTypes) ?? [],
            avoidSongTypes: try container.decodeIfPresent([String].self, forKey: .avoidSongTypes) ?? [],
            singingStrategy: try container.decodeIfPresent([String].self, forKey: .singingStrategy) ?? [],
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        )
    }

    private static func matchesLegacyCommonReference(
        type: VoiceType,
        minMidi: Int,
        maxMidi: Int,
        stableLowMidi: Int,
        stableHighMidi: Int,
        averageMidi: Double,
        confidence: Double,
        note: String
    ) -> Bool {
        let legacyNotes = [
            "模拟声线：适合大多数华语流行歌，连续高音歌曲建议减少。",
            "适合大多数华语流行歌，连续高音歌少排几首更稳。"
        ]
        return type == .midMale
            && minMidi == 48
            && maxMidi == 72
            && stableLowMidi == 53
            && stableHighMidi == 67
            && abs(averageMidi - 60.5) < 0.000_001
            && abs(confidence - 0.86) < 0.000_001
            && legacyNotes.contains(note)
    }

    public static var simulatedMiddle: VoiceProfile {
        VoiceProfile(
            type: .unknown,
            minMidi: 48,
            maxMidi: 72,
            stableLowMidi: 53,
            stableHighMidi: 67,
            averageMidi: 60.5,
            confidence: 0,
            note: "这是尚未实测时使用的常见音域参考，完成录音后可以获得更贴合的建议。",
            source: .commonReference,
            suitableSongTypes: ["华语流行", "民谣流行", "中低音情歌", "合唱金曲"],
            avoidSongTypes: ["长时间高音", "密集 Rap", "连续高强度摇滚"],
            singingStrategy: ["先用中低音歌曲开嗓", "高音歌放在中段状态最好时", "多人局优先安排好接合唱的歌"]
        )
    }
}

private func genderNeutralVoiceTags(_ tags: [String]) -> [String] {
    var seen = Set<String>()
    return tags.compactMap { tag in
        let value = tag
            .replacingOccurrences(of: "男声", with: "")
            .replacingOccurrences(of: "女声", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, seen.insert(value).inserted else { return nil }
        return value
    }
}

public enum SongPlanSectionRole: String, Codable, CaseIterable, Sendable {
    case warmup
    case groupSingAlong
    case spotlight
    case nostalgia
    case closing
    case birthday
    case participation
    case energy
    case familiar
    case relaxed
    case emotional
    case memorable
    case duet
    case stablePractice
    case challengePractice
    case externalVerification
    case general
}

public struct SongPlanSectionTemplate: Sendable {
    public let role: SongPlanSectionRole
    public let title: String
    public let goal: String

    public init(role: SongPlanSectionRole, title: String, goal: String) {
        self.role = role
        self.title = title
        self.goal = goal
    }
}

public enum KTVScenario: String, Codable, CaseIterable, Sendable {
    case friends
    case birthday
    case teamBuilding
    case carKTV
    case couples
    case soloPractice

    public var displayName: String {
        switch self {
        case .friends: return "朋友局"
        case .birthday: return "生日局"
        case .teamBuilding: return "团建局"
        case .carKTV: return "车载 K 歌"
        case .couples: return "情侣局"
        case .soloPractice: return "独自练歌"
        }
    }

    public var fixedPeopleCount: Int? {
        switch self {
        case .soloPractice:
            return 1
        case .couples:
            return 2
        case .friends, .birthday, .teamBuilding, .carKTV:
            return nil
        }
    }

    public var minimumPeopleCount: Int {
        isGroupScenario ? 2 : 1
    }

    public var planSummary: String {
        switch self {
        case .friends: return "朋友局先唱大家熟的，后面再留几首自己想唱的。"
        case .birthday: return "生日局先留祝福和合唱，中段放寿星想唱的。"
        case .teamBuilding: return "团建局先唱大家都会一点的，别让一个人连着唱。"
        case .carKTV: return "车里适合轻松一点，难唱的别连着排。"
        case .couples: return "情侣局多放甜歌和对唱，情绪歌放中段更顺。"
        case .soloPractice: return "练歌先从稳的开始，再留几首挑战。"
        }
    }

    public var sectionTemplates: [SongPlanSectionTemplate] {
        switch self {
        case .friends:
            return [
                SongPlanSectionTemplate(role: .warmup, title: "开场热身", goal: "先唱大家熟的，开口更容易。"),
                SongPlanSectionTemplate(role: .groupSingAlong, title: "全员合唱", goal: "不常唱的人也能一起接。"),
                SongPlanSectionTemplate(role: .spotlight, title: "自己想唱", goal: "留几首自己想唱的，高音歌别挨着。"),
                SongPlanSectionTemplate(role: .nostalgia, title: "怀旧情绪", goal: "节奏放慢一点，唱几首有回忆的。"),
                SongPlanSectionTemplate(role: .closing, title: "收尾大合唱", goal: "最后用一首大家都会的收尾。")
            ]
        case .birthday:
            return [
                SongPlanSectionTemplate(role: .warmup, title: "开场热身", goal: "先唱熟歌，别让寿星等太久。"),
                SongPlanSectionTemplate(role: .birthday, title: "生日氛围", goal: "多放温暖、带祝福感的歌。"),
                SongPlanSectionTemplate(role: .groupSingAlong, title: "祝福/合唱", goal: "朋友一起唱，寿星也不会有压力。"),
                SongPlanSectionTemplate(role: .spotlight, title: "寿星想唱", goal: "安排一两首寿星或主唱想唱的歌。"),
                SongPlanSectionTemplate(role: .closing, title: "收尾", goal: "最后用一首大家熟的歌。")
            ]
        case .teamBuilding:
            return [
                SongPlanSectionTemplate(role: .warmup, title: "好唱热场", goal: "优先大家熟、开口不累的歌。"),
                SongPlanSectionTemplate(role: .participation, title: "全员参与", goal: "别让一个人连唱，大家轮着来。"),
                SongPlanSectionTemplate(role: .energy, title: "气氛推进", goal: "穿插几首节奏更强的歌。"),
                SongPlanSectionTemplate(role: .familiar, title: "熟悉金曲", goal: "不同年龄都听过的歌多放几首。"),
                SongPlanSectionTemplate(role: .closing, title: "收尾", goal: "最后选一首大家都接得上的。")
            ]
        case .carKTV:
            return [
                SongPlanSectionTemplate(role: .relaxed, title: "轻松开唱", goal: "别排得太累，情绪也别太满。"),
                SongPlanSectionTemplate(role: .familiar, title: "熟悉旋律", goal: "优先容易跟唱的歌。"),
                SongPlanSectionTemplate(role: .emotional, title: "情绪陪伴", goal: "别太吵，也别影响开车注意力。"),
                SongPlanSectionTemplate(role: .memorable, title: "记忆点", goal: "穿插一两首特别想唱的。"),
                SongPlanSectionTemplate(role: .closing, title: "合唱收尾", goal: "最后用一首副歌大家都会的。")
            ]
        case .couples:
            return [
                SongPlanSectionTemplate(role: .warmup, title: "轻松开场", goal: "从轻松熟悉的旋律开始，避免一上来太用力。"),
                SongPlanSectionTemplate(role: .duet, title: "甜歌/对唱", goal: "多放甜歌和适合两个人唱的。"),
                SongPlanSectionTemplate(role: .emotional, title: "情绪段落", goal: "中间留几首更走心的。"),
                SongPlanSectionTemplate(role: .spotlight, title: "自己想唱", goal: "安排一首更想唱的歌曲。"),
                SongPlanSectionTemplate(role: .closing, title: "收尾", goal: "最后唱一首温暖又熟悉的。")
            ]
        case .soloPractice:
            return [
                SongPlanSectionTemplate(role: .warmup, title: "开嗓", goal: "先唱不费嗓的，慢慢找状态。"),
                SongPlanSectionTemplate(role: .stablePractice, title: "舒服范围", goal: "先把唱得最稳的几首过一遍。"),
                SongPlanSectionTemplate(role: .challengePractice, title: "挑战一下", goal: "再挑一两首难一点的。"),
                SongPlanSectionTemplate(role: .closing, title: "收尾再唱", goal: "最后用熟歌看看今天哪里更顺。")
            ]
        }
    }

    public var isGroupScenario: Bool {
        switch self {
        case .soloPractice: return false
        default: return true
        }
    }
}

public enum PlaylistVibe: String, Codable, CaseIterable, Sendable {
    case balanced
    case energetic
    case nostalgic
    case relaxed
    case chorus
    case emotional
    case spotlight

    public var displayName: String {
        switch self {
        case .balanced: return "正常"
        case .energetic: return "热场"
        case .nostalgic: return "怀旧"
        case .chorus: return "合唱"
        case .relaxed: return "轻松"
        case .emotional: return "情绪"
        case .spotlight: return "想唱"
        }
    }
}

public enum ChorusPreference: String, Codable, CaseIterable, Sendable {
    case balanced
    case moreChorus
    case moreSolo

    public var displayName: String {
        switch self {
        case .balanced: return "均衡"
        case .moreChorus: return "多合唱"
        case .moreSolo: return "多独唱"
        }
    }
}

public enum DifficultyPreference: String, Codable, CaseIterable, Sendable {
    case easy
    case balanced
    case showcase

    public var displayName: String {
        switch self {
        case .easy: return "稳妥"
        case .balanced: return "正常"
        case .showcase: return "有挑战"
        }
    }
}

public struct ScenarioConfig: Codable, Equatable, Sendable {
    public var scenario: KTVScenario {
        didSet {
            peopleCount = Self.normalizedPeopleCount(peopleCount, for: scenario)
            vibe = Self.normalizedVibe(vibe, for: scenario)
            if oldValue == .soloPractice,
               scenario != .soloPractice,
               chorusPreference == .moreSolo {
                chorusPreference = .balanced
            } else {
                chorusPreference = Self.normalizedChorusPreference(chorusPreference, for: scenario)
            }
        }
    }
    public var peopleCount: Int {
        didSet {
            let normalized = Self.normalizedPeopleCount(peopleCount, for: scenario)
            if peopleCount != normalized {
                peopleCount = normalized
            }
        }
    }
    public var durationMinutes: Int
    public var vibe: PlaylistVibe {
        didSet {
            let normalized = Self.normalizedVibe(vibe, for: scenario)
            if vibe != normalized {
                vibe = normalized
            }
        }
    }
    public var chorusPreference: ChorusPreference {
        didSet {
            let normalized = Self.normalizedChorusPreference(chorusPreference, for: scenario)
            if chorusPreference != normalized {
                chorusPreference = normalized
            }
        }
    }
    public var difficultyPreference: DifficultyPreference

    enum CodingKeys: String, CodingKey {
        case scenario
        case peopleCount
        case durationMinutes
        case vibe
        case chorusPreference
        case difficultyPreference
    }

    public init(
        scenario: KTVScenario = .friends,
        peopleCount: Int = 4,
        durationMinutes: Int = 60,
        vibe: PlaylistVibe = .balanced,
        chorusPreference: ChorusPreference = .balanced,
        difficultyPreference: DifficultyPreference = .balanced
    ) {
        self.scenario = scenario
        self.peopleCount = Self.normalizedPeopleCount(peopleCount, for: scenario)
        self.durationMinutes = max(15, durationMinutes)
        self.vibe = Self.normalizedVibe(vibe, for: scenario)
        self.chorusPreference = Self.normalizedChorusPreference(chorusPreference, for: scenario)
        self.difficultyPreference = difficultyPreference
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            scenario: try container.decodeIfPresent(KTVScenario.self, forKey: .scenario) ?? .friends,
            peopleCount: try container.decodeIfPresent(Int.self, forKey: .peopleCount) ?? 4,
            durationMinutes: try container.decodeIfPresent(Int.self, forKey: .durationMinutes) ?? 60,
            vibe: try container.decodeIfPresent(PlaylistVibe.self, forKey: .vibe) ?? .balanced,
            chorusPreference: try container.decodeIfPresent(ChorusPreference.self, forKey: .chorusPreference) ?? .balanced,
            difficultyPreference: try container.decodeIfPresent(DifficultyPreference.self, forKey: .difficultyPreference) ?? .balanced
        )
    }

    private static func normalizedPeopleCount(_ value: Int, for scenario: KTVScenario) -> Int {
        scenario.fixedPeopleCount ?? min(16, max(scenario.minimumPeopleCount, value))
    }

    private static func normalizedVibe(_ value: PlaylistVibe, for scenario: KTVScenario) -> PlaylistVibe {
        scenario == .soloPractice && value == .chorus ? .balanced : value
    }

    private static func normalizedChorusPreference(
        _ value: ChorusPreference,
        for scenario: KTVScenario
    ) -> ChorusPreference {
        scenario == .soloPractice ? .moreSolo : value
    }
}

public struct PreferenceProfile: Codable, Sendable {
    public var topArtists: [(name: String, count: Int)]
    public var languageDistribution: [String: Double]
    public var eraDistribution: [String: Double]
    public var genreDistribution: [String: Double]
    public var moodTags: [String: Double]
    public var sceneAffinity: [String: Double]
    public var ktvMatchRate: Double
    public var averageDifficulty: Double
    public var averageSingAlongScore: Double
    public var highNoteRisk: Double
    public var chorusFriendliness: Double
    public var scenarioFitScores: [String: Double]
    public var profileTags: [String]
    public var summary: String

    public var hasReferenceInsights: Bool {
        !languageDistribution.isEmpty
            || !eraDistribution.isEmpty
            || !genreDistribution.isEmpty
            || !moodTags.isEmpty
            || !sceneAffinity.isEmpty
            || !scenarioFitScores.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case topArtists
        case languageDistribution
        case eraDistribution
        case genreDistribution
        case moodTags
        case sceneAffinity
        case ktvMatchRate
        case averageDifficulty
        case averageSingAlongScore
        case highNoteRisk
        case chorusFriendliness
        case scenarioFitScores
        case profileTags
        case summary
    }

    public init(
        topArtists: [(name: String, count: Int)],
        languageDistribution: [String: Double],
        eraDistribution: [String: Double],
        genreDistribution: [String: Double],
        moodTags: [String: Double],
        sceneAffinity: [String: Double],
        ktvMatchRate: Double,
        averageDifficulty: Double,
        averageSingAlongScore: Double,
        highNoteRisk: Double,
        chorusFriendliness: Double = 0,
        scenarioFitScores: [String: Double] = [:],
        profileTags: [String] = [],
        summary: String
    ) {
        self.topArtists = topArtists
        self.languageDistribution = languageDistribution
        self.eraDistribution = eraDistribution
        self.genreDistribution = genreDistribution
        self.moodTags = moodTags
        self.sceneAffinity = sceneAffinity
        self.ktvMatchRate = ktvMatchRate
        self.averageDifficulty = averageDifficulty
        self.averageSingAlongScore = averageSingAlongScore
        self.highNoteRisk = highNoteRisk
        self.chorusFriendliness = chorusFriendliness
        self.scenarioFitScores = scenarioFitScores
        self.profileTags = profileTags
        self.summary = summary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        topArtists = try container.decode([ArtistCount].self, forKey: .topArtists).map { ($0.name, $0.count) }
        languageDistribution = try container.decode([String: Double].self, forKey: .languageDistribution)
        eraDistribution = try container.decode([String: Double].self, forKey: .eraDistribution)
        genreDistribution = try container.decode([String: Double].self, forKey: .genreDistribution)
        moodTags = try container.decode([String: Double].self, forKey: .moodTags)
        sceneAffinity = try container.decode([String: Double].self, forKey: .sceneAffinity)
        ktvMatchRate = try container.decode(Double.self, forKey: .ktvMatchRate)
        averageDifficulty = try container.decode(Double.self, forKey: .averageDifficulty)
        averageSingAlongScore = try container.decode(Double.self, forKey: .averageSingAlongScore)
        highNoteRisk = try container.decode(Double.self, forKey: .highNoteRisk)
        chorusFriendliness = try container.decodeIfPresent(Double.self, forKey: .chorusFriendliness) ?? averageSingAlongScore
        scenarioFitScores = try container.decodeIfPresent([String: Double].self, forKey: .scenarioFitScores) ?? sceneAffinity
        profileTags = try container.decodeIfPresent([String].self, forKey: .profileTags) ?? []
        summary = try container.decode(String.self, forKey: .summary)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(topArtists.map { ArtistCount(name: $0.name, count: $0.count) }, forKey: .topArtists)
        try container.encode(languageDistribution, forKey: .languageDistribution)
        try container.encode(eraDistribution, forKey: .eraDistribution)
        try container.encode(genreDistribution, forKey: .genreDistribution)
        try container.encode(moodTags, forKey: .moodTags)
        try container.encode(sceneAffinity, forKey: .sceneAffinity)
        try container.encode(ktvMatchRate, forKey: .ktvMatchRate)
        try container.encode(averageDifficulty, forKey: .averageDifficulty)
        try container.encode(averageSingAlongScore, forKey: .averageSingAlongScore)
        try container.encode(highNoteRisk, forKey: .highNoteRisk)
        try container.encode(chorusFriendliness, forKey: .chorusFriendliness)
        try container.encode(scenarioFitScores, forKey: .scenarioFitScores)
        try container.encode(profileTags, forKey: .profileTags)
        try container.encode(summary, forKey: .summary)
    }

    private struct ArtistCount: Codable {
        let name: String
        let count: Int
    }
}

public enum RecommendationInputSource: String, Codable, CaseIterable, Sendable {
    case userImport
    case example
    case popularFallback
    case legacyUnknown

    public var displayName: String {
        switch self {
        case .userImport: return "用户导入"
        case .example: return "示例歌单"
        case .popularFallback: return "热门歌单"
        case .legacyUnknown: return "来源未记录"
        }
    }

    public var allowsPlaylistPersonalization: Bool {
        self == .userImport
    }

    public var preferenceInsightTitle: String {
        switch self {
        case .userImport: return "你常听的风格"
        case .example: return "示例歌单的风格"
        case .popularFallback: return "热门歌单的风格"
        case .legacyUnknown: return "这份歌单的风格"
        }
    }

    public func matchReportSummary(for profile: PreferenceProfile) -> String {
        if profile.ktvMatchRate >= 0.95 {
            return "熟歌不少，先用大家会唱的热场，后面再放个人发挥。"
        }
        guard allowsPlaylistPersonalization else {
            return "有些歌暂时没找到，先挑有本地参考的，再核对或准备替换。"
        }
        return profile.summary
    }

    public func allowsRecommendationReason(
        _ reason: String,
        voiceSource: VoiceProfileSource?
    ) -> Bool {
        if !allowsPlaylistPersonalization,
           reason.contains("你歌单")
            || reason.contains("你平时听")
            || reason.contains("你导入的歌单") {
            return false
        }
        if reason.contains("你的声线") || reason.contains("你的音域") {
            return false
        }
        if voiceSource?.allowsMeasuredRangeClaims != true,
           reason.contains("本次唱到的音区") {
            return false
        }
        return true
    }
}

public struct SongPlan: Codable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var scenario: KTVScenario
    public var inputSource: RecommendationInputSource
    public var scenarioConfig: ScenarioConfig?
    public var voiceProfile: VoiceProfile?
    public var preferenceSummary: String?
    public var generationSummary: SongPlanGenerationSummary?
    public var sections: [SongPlanSection]
    public var notices: [String]
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case scenario
        case inputSource
        case scenarioConfig
        case voiceProfile
        case preferenceSummary
        case generationSummary
        case sections
        case notices
        case createdAt
    }

    public init(
        id: UUID = UUID(),
        title: String,
        scenario: KTVScenario,
        inputSource: RecommendationInputSource = .legacyUnknown,
        scenarioConfig: ScenarioConfig? = nil,
        voiceProfile: VoiceProfile? = nil,
        preferenceSummary: String? = nil,
        generationSummary: SongPlanGenerationSummary? = nil,
        sections: [SongPlanSection],
        notices: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.scenario = scenario
        self.inputSource = inputSource
        self.scenarioConfig = scenarioConfig
        self.voiceProfile = voiceProfile
        self.preferenceSummary = preferenceSummary
        self.generationSummary = generationSummary
        self.sections = normalizeSongPlanSectionsForTrustBoundary(sections)
        self.notices = notices
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedGenerationSummary = try container.decodeIfPresent(
            SongPlanGenerationSummary.self,
            forKey: .generationSummary
        )
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            title: try container.decode(String.self, forKey: .title),
            scenario: try container.decode(KTVScenario.self, forKey: .scenario),
            inputSource: try container.decodeIfPresent(RecommendationInputSource.self, forKey: .inputSource) ?? .legacyUnknown,
            scenarioConfig: try container.decodeIfPresent(ScenarioConfig.self, forKey: .scenarioConfig),
            voiceProfile: try container.decodeIfPresent(VoiceProfile.self, forKey: .voiceProfile),
            preferenceSummary: try container.decodeIfPresent(String.self, forKey: .preferenceSummary),
            generationSummary: decodedGenerationSummary,
            sections: try container.decodeIfPresent([SongPlanSection].self, forKey: .sections) ?? [],
            notices: try container.decodeIfPresent([String].self, forKey: .notices) ?? [],
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        )
        if let decodedGenerationSummary,
           !decodedGenerationSummary.matchesFinalItems(sections.lazy.flatMap(\.items)) {
            throw RecommendationGenerationError.countMismatch
        }
    }
}

public struct SongPlanSection: Codable, Identifiable, Sendable {
    public var id: UUID
    public var role: SongPlanSectionRole
    public var title: String
    public var goal: String
    public var items: [SongPlanItem]

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case title
        case goal
        case items
    }

    public init(
        id: UUID = UUID(),
        role: SongPlanSectionRole = .general,
        title: String,
        goal: String,
        items: [SongPlanItem]
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.goal = goal
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            role: try container.decodeIfPresent(SongPlanSectionRole.self, forKey: .role) ?? .general,
            title: try container.decode(String.self, forKey: .title),
            goal: try container.decode(String.self, forKey: .goal),
            items: try container.decodeIfPresent([SongPlanItem].self, forKey: .items) ?? []
        )
    }
}

public struct TrackControlState: Equatable, Sendable {
    public var lockedTrackIDs: Set<String>
    public var removedTrackIDs: Set<String>

    public init(lockedTrackIDs: Set<String>, removedTrackIDs: Set<String>) {
        self.lockedTrackIDs = lockedTrackIDs
        self.removedTrackIDs = removedTrackIDs
    }
}

public struct TrackControlTransition: Equatable, Sendable {
    public var state: TrackControlState
    public var didRemove: Bool
    public var message: String

    public init(state: TrackControlState, didRemove: Bool, message: String) {
        self.state = state
        self.didRemove = didRemove
        self.message = message
    }
}

public struct TrackControlPolicy: Sendable {
    public init() {}

    public func remove(
        trackID: String,
        title: String,
        from state: TrackControlState
    ) -> TrackControlTransition {
        var nextState = state
        if nextState.lockedTrackIDs.contains(trackID) {
            nextState.removedTrackIDs.remove(trackID)
            return TrackControlTransition(
                state: nextState,
                didRemove: false,
                message: "《\(title)》已锁定，请先取消锁定再移除。"
            )
        }
        nextState.removedTrackIDs.insert(trackID)
        return TrackControlTransition(
            state: nextState,
            didRemove: true,
            message: "已移除《\(title)》"
        )
    }
}

public struct RecommendationScoreBreakdown: Codable, Equatable, Sendable {
    public var preferenceAffinity: Double
    public var ktvAvailabilityScore: Double
    public var vocalFitScore: Double
    public var singAlongScore: Double
    public var sceneFitScore: Double
    public var varietyScore: Double
    public var riskPenalty: Double
    public var finalScore: Double

    public init(
        preferenceAffinity: Double,
        ktvAvailabilityScore: Double,
        vocalFitScore: Double,
        singAlongScore: Double,
        sceneFitScore: Double,
        varietyScore: Double,
        riskPenalty: Double,
        finalScore: Double
    ) {
        self.preferenceAffinity = min(max(preferenceAffinity, 0), 1)
        self.ktvAvailabilityScore = min(max(ktvAvailabilityScore, 0), 1)
        self.vocalFitScore = min(max(vocalFitScore, 0), 1)
        self.singAlongScore = min(max(singAlongScore, 0), 1)
        self.sceneFitScore = min(max(sceneFitScore, 0), 1)
        self.varietyScore = min(max(varietyScore, 0), 1)
        self.riskPenalty = min(max(riskPenalty, 0), 1)
        self.finalScore = min(max(finalScore, 0), 1)
    }

    public static let empty = RecommendationScoreBreakdown(
        preferenceAffinity: 0,
        ktvAvailabilityScore: 0,
        vocalFitScore: 0,
        singAlongScore: 0,
        sceneFitScore: 0,
        varietyScore: 0,
        riskPenalty: 0,
        finalScore: 0
    )
}

public enum SongFeedbackKind: String, Codable, CaseIterable, Hashable, Sendable {
    case sung
    case liked
    case tooHigh
    case unfamiliar
    case chorusFriendly

    public var displayName: String {
        switch self {
        case .sung: return "唱过"
        case .liked: return "喜欢"
        case .tooHigh: return "太高"
        case .unfamiliar: return "不熟"
        case .chorusFriendly: return "适合合唱"
        }
    }
}

public struct SongFeedbackProfile: Codable, Equatable, Sendable {
    public var feedbackByTrackID: [String: [SongFeedbackKind]]

    public init(feedbackByTrackID: [String: [SongFeedbackKind]] = [:]) {
        self.feedbackByTrackID = feedbackByTrackID.mapValues { Array(Set($0)).sorted { $0.rawValue < $1.rawValue } }
    }

    public static let empty = SongFeedbackProfile()

    public func feedback(for trackID: String) -> [SongFeedbackKind] {
        feedbackByTrackID[trackID] ?? []
    }

    public func contains(trackID: String, kind: SongFeedbackKind) -> Bool {
        feedback(for: trackID).contains(kind)
    }

    public mutating func record(trackID: String, kind: SongFeedbackKind) {
        var values = Set(feedbackByTrackID[trackID] ?? [])
        values.insert(kind)
        setFeedback(trackID: trackID, kinds: Array(values))
    }

    public mutating func toggle(trackID: String, kind: SongFeedbackKind) {
        var values = Set(feedbackByTrackID[trackID] ?? [])
        if values.contains(kind) {
            values.remove(kind)
        } else {
            values.insert(kind)
        }
        setFeedback(trackID: trackID, kinds: Array(values))
    }

    public mutating func setFeedback(trackID: String, kinds: [SongFeedbackKind]) {
        let values = Array(Set(kinds)).sorted { $0.rawValue < $1.rawValue }
        if values.isEmpty {
            feedbackByTrackID.removeValue(forKey: trackID)
        } else {
            feedbackByTrackID[trackID] = values
        }
    }
}

/// 歌曲反馈的独立本机记录是运行时真源；工作流快照只在旧安装尚未建立
/// 独立记录时参与一次迁移。`.some(.empty)` 代表用户已经取消或清除反馈。
public enum SongFeedbackRestorePolicy {
    public static func preferred(
        standalone: SongFeedbackProfile?,
        snapshot: SongFeedbackProfile
    ) -> SongFeedbackProfile {
        standalone ?? snapshot
    }

    /// 独立记录与快照反馈不一致时，快照中的既有歌单也已过期：反馈既会改变
    /// 歌曲分数和排序，也会写入每个 `SongPlanItem` 的可见标签。
    public static func shouldRefreshPlan(
        standalone: SongFeedbackProfile?,
        snapshot: SongFeedbackProfile,
        hasRestoredPlan: Bool
    ) -> Bool {
        guard hasRestoredPlan, let standalone else { return false }
        return standalone != snapshot
    }
}

public enum SingingAdjustmentLevel: String, Codable, Equatable, Sendable {
    case originalKey
    case lowerKey
    case raiseKey
    case substitute

    public var displayName: String {
        switch self {
        case .originalKey: return "原调可唱"
        case .lowerKey: return "建议降调"
        case .raiseKey: return "建议升调"
        case .substitute: return "建议替换"
        }
    }
}

public struct VoiceMeasurementRequestGate: Equatable, Sendable {
    public private(set) var generation: UInt64
    public private(set) var isActive: Bool

    public init(generation: UInt64 = 0, isActive: Bool = false) {
        self.generation = generation
        self.isActive = isActive
    }

    @discardableResult
    public mutating func begin() -> UInt64 {
        generation &+= 1
        isActive = true
        return generation
    }

    public mutating func beginIfIdle() -> UInt64? {
        guard !isActive else { return nil }
        return begin()
    }

    public mutating func cancel() {
        generation &+= 1
        isActive = false
    }

    public func accepts(_ request: UInt64) -> Bool {
        isActive && request == generation
    }

    @discardableResult
    public mutating func finish(_ request: UInt64) -> Bool {
        guard accepts(request) else { return false }
        isActive = false
        return true
    }
}

public struct SingingAdjustmentAdvice: Codable, Equatable, Sendable {
    public var level: SingingAdjustmentLevel
    public var title: String
    public var detail: String
    public var semitoneShift: Int

    public init(level: SingingAdjustmentLevel, title: String, detail: String, semitoneShift: Int) {
        self.level = level
        self.title = title
        self.detail = detail
        self.semitoneShift = semitoneShift
    }
}

public struct SongPlanItem: Codable, Identifiable, Sendable {
    public var id: UUID
    public var track: KTVTrack
    public var origin: SongRecommendationOrigin
    public var score: Double
    public var scoreBreakdown: RecommendationScoreBreakdown
    public var reasons: [String]
    public var riskWarnings: [String]
    public var alternatives: [KTVTrack]
    public var isLocked: Bool
    public var singingAdvice: SingingAdjustmentAdvice?
    public var actionURL: URL?
    public var feedbackTags: [SongFeedbackKind]

    enum CodingKeys: String, CodingKey {
        case id
        case track
        case origin
        case score
        case scoreBreakdown
        case reasons
        case riskWarnings
        case alternatives
        case isLocked
        case singingAdvice
        case actionURL
        case feedbackTags
    }

    public init(
        id: UUID = UUID(),
        track: KTVTrack,
        origin: SongRecommendationOrigin = .legacyUnknown,
        score: Double,
        scoreBreakdown: RecommendationScoreBreakdown = .empty,
        reasons: [String],
        riskWarnings: [String],
        alternatives: [KTVTrack],
        isLocked: Bool = false,
        singingAdvice: SingingAdjustmentAdvice? = nil,
        actionURL: URL? = nil,
        feedbackTags: [SongFeedbackKind] = []
    ) {
        let boundedScore = min(max(score, 0), 1)
        self.id = id
        self.track = track
        self.origin = origin
        self.score = boundedScore
        if track.isProvisionalExternalCandidate {
            self.scoreBreakdown = RecommendationScoreBreakdown(
                preferenceAffinity: 0,
                ktvAvailabilityScore: 0,
                vocalFitScore: 0,
                singAlongScore: 0,
                sceneFitScore: 0,
                varietyScore: 0,
                riskPenalty: 0,
                finalScore: boundedScore
            )
            self.reasons = track.provisionalDisclosureReasons
            self.riskWarnings = []
            self.alternatives = []
        } else {
            self.scoreBreakdown = scoreBreakdown.finalScore == 0 && score > 0
                ? RecommendationScoreBreakdown(
                    preferenceAffinity: score,
                    ktvAvailabilityScore: score,
                    vocalFitScore: score,
                    singAlongScore: score,
                    sceneFitScore: score,
                    varietyScore: score,
                    riskPenalty: 0,
                    finalScore: score
                )
                : scoreBreakdown
            self.reasons = reasons
            self.riskWarnings = riskWarnings
            self.alternatives = alternatives.filter { $0.catalogSource == .ktvCatalog }
        }
        self.isLocked = isLocked
        self.singingAdvice = track.isProvisionalExternalCandidate ? nil : singingAdvice
        self.actionURL = SongActionURLPolicy().validated(actionURL)
        self.feedbackTags = feedbackTags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedScore = try container.decode(Double.self, forKey: .score)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            track: try container.decode(KTVTrack.self, forKey: .track),
            origin: try container.decodeIfPresent(SongRecommendationOrigin.self, forKey: .origin) ?? .legacyUnknown,
            score: decodedScore,
            scoreBreakdown: try container.decodeIfPresent(RecommendationScoreBreakdown.self, forKey: .scoreBreakdown) ?? .empty,
            reasons: try container.decodeIfPresent([String].self, forKey: .reasons) ?? [],
            riskWarnings: try container.decodeIfPresent([String].self, forKey: .riskWarnings) ?? [],
            alternatives: try container.decodeIfPresent([KTVTrack].self, forKey: .alternatives) ?? [],
            isLocked: try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false,
            singingAdvice: try container.decodeIfPresent(SingingAdjustmentAdvice.self, forKey: .singingAdvice),
            actionURL: try container.decodeIfPresent(URL.self, forKey: .actionURL),
            feedbackTags: try container.decodeIfPresent([SongFeedbackKind].self, forKey: .feedbackTags) ?? []
        )
    }

    public func sanitizedForTrustBoundaries() -> SongPlanItem {
        SongPlanItem(
            id: id,
            track: track,
            origin: origin,
            score: score,
            scoreBreakdown: scoreBreakdown,
            reasons: reasons,
            riskWarnings: riskWarnings,
            alternatives: alternatives,
            isLocked: isLocked,
            singingAdvice: singingAdvice,
            actionURL: actionURL,
            feedbackTags: feedbackTags
        )
    }
}

private func normalizeSongPlanSectionsForTrustBoundary(
    _ sections: [SongPlanSection]
) -> [SongPlanSection] {
    var normalized: [SongPlanSection] = []

    for original in sections {
        var section = original
        let sanitizedItems = section.items.map { $0.sanitizedForTrustBoundaries() }
        let extractedProvisionalItems = sanitizedItems.filter { $0.track.isProvisionalExternalCandidate }
        let verifiedItems = sanitizedItems.filter { !$0.track.isProvisionalExternalCandidate }

        if section.role == .externalVerification {
            if !verifiedItems.isEmpty {
                section.role = .general
                section.items = verifiedItems
                normalized.append(section)
            }
        } else {
            section.items = verifiedItems
            if !verifiedItems.isEmpty || extractedProvisionalItems.isEmpty {
                normalized.append(section)
            }
        }
    }
    return normalized
}

public extension SongPlan {
    func sanitizedForTrustBoundaries() -> SongPlan {
        SongPlan(
            id: id,
            title: title,
            scenario: scenario,
            inputSource: inputSource,
            scenarioConfig: scenarioConfig,
            voiceProfile: voiceProfile,
            preferenceSummary: preferenceSummary,
            generationSummary: generationSummary,
            sections: sections,
            notices: notices,
            createdAt: createdAt
        )
    }
}

public struct StartTipsSelection: Sendable {
    public let opening: SongPlanItem?
    public let chorus: SongPlanItem?
    public let closing: SongPlanItem?
    public let easyFallback: SongPlanItem?

    public init(
        opening: SongPlanItem?,
        chorus: SongPlanItem?,
        closing: SongPlanItem?,
        easyFallback: SongPlanItem?
    ) {
        self.opening = opening
        self.chorus = chorus
        self.closing = closing
        self.easyFallback = easyFallback
    }
}

public struct StartTipsSelectionPolicy: Sendable {
    public init() {}

    public func selection(for plan: SongPlan) -> StartTipsSelection {
        let verifiedItems = plan.sections
            .flatMap(\.items)
            .filter { !$0.track.isProvisionalExternalCandidate }
        let opening = verifiedItems.first
        return StartTipsSelection(
            opening: opening,
            chorus: verifiedItems.first {
                $0.track.singAlongScore >= 0.78 && $0.track.id != opening?.track.id
            },
            closing: verifiedItems.last,
            easyFallback: verifiedItems.first { $0.track.difficulty <= 2 }
        )
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
