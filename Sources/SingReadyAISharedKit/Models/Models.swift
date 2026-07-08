import Foundation

public enum ImportSource: String, Codable, CaseIterable, Sendable {
    case netEaseMusic
    case qqMusic
    case appleMusic
    case plainText
    case screenshot
    case genericURL
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
        case .demo: return "Demo 歌单"
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
    public let similarSongIds: [String]

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
        similarSongIds: [String]
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
        self.similarSongIds = similarSongIds
    }
}

public enum MatchStatus: String, Codable, CaseIterable, Sendable {
    case exact
    case fuzzy
    case alternative
    case unmatched

    public var displayName: String {
        switch self {
        case .exact: return "精确匹配"
        case .fuzzy: return "模糊匹配"
        case .alternative: return "可替代"
        case .unmatched: return "未匹配"
        }
    }
}

public struct MatchResult: Codable, Identifiable, Sendable {
    public var id: UUID
    public var importedSong: ImportedSong
    public var matchedTrack: KTVTrack?
    public var alternatives: [KTVTrack]
    public var status: MatchStatus
    public var score: Double
    public var reason: String

    public init(
        id: UUID = UUID(),
        importedSong: ImportedSong,
        matchedTrack: KTVTrack?,
        alternatives: [KTVTrack],
        status: MatchStatus,
        score: Double,
        reason: String
    ) {
        self.id = id
        self.importedSong = importedSong
        self.matchedTrack = matchedTrack
        self.alternatives = alternatives
        self.status = status
        self.score = min(max(score, 0), 1)
        self.reason = reason
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

public struct VoiceProfile: Codable, Equatable, Sendable {
    public var type: VoiceType
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

    public init(
        type: VoiceType,
        minMidi: Int,
        maxMidi: Int,
        stableLowMidi: Int,
        stableHighMidi: Int,
        averageMidi: Double,
        confidence: Double,
        note: String,
        suitableSongTypes: [String] = [],
        avoidSongTypes: [String] = [],
        singingStrategy: [String] = [],
        createdAt: Date = Date()
    ) {
        self.type = type
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

    public static var simulatedMiddle: VoiceProfile {
        VoiceProfile(
            type: .midMale,
            minMidi: 48,
            maxMidi: 72,
            stableLowMidi: 53,
            stableHighMidi: 67,
            averageMidi: 60.5,
            confidence: 0.86,
            note: "模拟声线：适合大多数华语流行歌，连续高音歌曲建议减少。",
            suitableSongTypes: ["华语流行", "民谣流行", "中低音情歌", "合唱金曲"],
            avoidSongTypes: ["长时间高音", "密集 Rap", "连续高强度摇滚"],
            singingStrategy: ["先用中低音歌曲开嗓", "高音歌放在中段状态最好时", "多人局优先安排合唱友好歌曲"]
        )
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

    public var sectionTemplates: [(title: String, goal: String)] {
        switch self {
        case .friends:
            return [
                ("开场热身", "先把气氛拉起来，选择旋律熟、能量高的歌。"),
                ("全员合唱", "让不常唱歌的人也能加入。"),
                ("个人高光", "留给主唱展示，但控制高音风险。"),
                ("怀旧情绪", "降低节奏，制造记忆点。"),
                ("收尾大合唱", "用高参与度歌曲结束。")
            ]
        case .birthday:
            return [
                ("开场热身", "快速进入状态，不让寿星等太久。"),
                ("生日氛围", "选择温暖、祝福感更强的歌曲。"),
                ("祝福/合唱", "让朋友一起参与，降低个人演唱压力。"),
                ("个人高光", "安排一两首更能展示声线的歌。"),
                ("收尾", "用熟悉旋律收束。")
            ]
        case .teamBuilding:
            return [
                ("低门槛热场", "优先低难度、高熟悉度歌曲。"),
                ("全员参与", "降低个人压力，提升参与感。"),
                ("气氛推进", "加入节奏更强的歌曲。"),
                ("熟悉金曲", "用跨年龄层熟悉的歌曲稳住参与度。"),
                ("收尾", "用稳妥歌曲结束。")
            ]
        case .carKTV:
            return [
                ("轻松开唱", "控制难度和情绪强度。"),
                ("熟悉旋律", "优先容易跟唱的歌。"),
                ("情绪陪伴", "选择不抢驾驶注意力的中低强度歌曲。"),
                ("短时高光", "安排少量记忆点强的歌曲。"),
                ("合唱收尾", "用副歌参与度高的歌结束。")
            ]
        case .couples:
            return [
                ("轻松开场", "从轻松熟悉的旋律开始，避免一上来太用力。"),
                ("甜歌/对唱", "优先安排甜歌和对唱友好的曲目。"),
                ("情绪段落", "保留一段更走心的表达。"),
                ("个人高光", "安排一首更能展示声线的歌曲。"),
                ("收尾", "用温暖、熟悉的歌曲结束。")
            ]
        case .soloPractice:
            return [
                ("开嗓", "先用低风险歌曲建立状态。"),
                ("稳定区练习", "集中练稳定音域内的歌曲。"),
                ("技巧挑战", "少量安排有挑战的歌曲。"),
                ("复盘", "用熟悉歌曲复盘音准和气息。")
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
        case .spotlight: return "高光"
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
    public var scenario: KTVScenario
    public var peopleCount: Int
    public var durationMinutes: Int
    public var vibe: PlaylistVibe
    public var chorusPreference: ChorusPreference
    public var difficultyPreference: DifficultyPreference

    public init(
        scenario: KTVScenario = .friends,
        peopleCount: Int = 4,
        durationMinutes: Int = 60,
        vibe: PlaylistVibe = .balanced,
        chorusPreference: ChorusPreference = .balanced,
        difficultyPreference: DifficultyPreference = .balanced
    ) {
        self.scenario = scenario
        self.peopleCount = max(1, peopleCount)
        self.durationMinutes = max(15, durationMinutes)
        self.vibe = vibe
        self.chorusPreference = chorusPreference
        self.difficultyPreference = difficultyPreference
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

public struct SongPlan: Codable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var scenario: KTVScenario
    public var scenarioConfig: ScenarioConfig?
    public var voiceProfile: VoiceProfile?
    public var preferenceSummary: String?
    public var sections: [SongPlanSection]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        scenario: KTVScenario,
        scenarioConfig: ScenarioConfig? = nil,
        voiceProfile: VoiceProfile? = nil,
        preferenceSummary: String? = nil,
        sections: [SongPlanSection],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.scenario = scenario
        self.scenarioConfig = scenarioConfig
        self.voiceProfile = voiceProfile
        self.preferenceSummary = preferenceSummary
        self.sections = sections
        self.createdAt = createdAt
    }
}

public struct SongPlanSection: Codable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var goal: String
    public var items: [SongPlanItem]

    public init(id: UUID = UUID(), title: String, goal: String, items: [SongPlanItem]) {
        self.id = id
        self.title = title
        self.goal = goal
        self.items = items
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

public struct SongPlanItem: Codable, Identifiable, Sendable {
    public var id: UUID
    public var track: KTVTrack
    public var score: Double
    public var scoreBreakdown: RecommendationScoreBreakdown
    public var reasons: [String]
    public var riskWarnings: [String]
    public var alternatives: [KTVTrack]
    public var isLocked: Bool

    public init(
        id: UUID = UUID(),
        track: KTVTrack,
        score: Double,
        scoreBreakdown: RecommendationScoreBreakdown = .empty,
        reasons: [String],
        riskWarnings: [String],
        alternatives: [KTVTrack],
        isLocked: Bool = false
    ) {
        self.id = id
        self.track = track
        self.score = min(max(score, 0), 1)
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
        self.alternatives = alternatives
        self.isLocked = isLocked
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
