import Foundation

public enum SongRecommendationOrigin: String, Codable, CaseIterable, Sendable {
    case importedMatch
    case adoptedAlternative
    case sameArtistSupplement
    case styleSupplement
    case sceneSupplement
    case popularSupplement
    case legacyUnknown

    public var displayName: String {
        switch self {
        case .importedMatch: return "来自导入歌单"
        case .adoptedAlternative: return "你采用的替代"
        case .sameArtistSupplement: return "同歌手补充"
        case .styleSupplement: return "风格补充"
        case .sceneSupplement: return "场景补充"
        case .popularSupplement: return "热门补充"
        case .legacyUnknown: return "历史排歌"
        }
    }
}

public enum RecommendationGenerationError: Error, Equatable, Sendable {
    case countMismatch
    case lockedTrackUnavailable(trackIDs: [String])
}

public struct SongPlanGenerationContext: Codable, Equatable, Sendable {
    public let playlistID: UUID
    public let playlistTitle: String
    public let importedSongCount: Int
    public let verifiedSongCount: Int
    public let pendingSongCount: Int
    public let unmatchedSongCount: Int
    public let scenario: KTVScenario
    public let peopleCount: Int
    public let durationMinutes: Int
    public let voiceSource: VoiceProfileSource
    public let feedbackCount: Int

    public init(
        playlistID: UUID,
        playlistTitle: String,
        importedSongCount: Int,
        verifiedSongCount: Int,
        pendingSongCount: Int,
        unmatchedSongCount: Int,
        scenario: KTVScenario,
        peopleCount: Int,
        durationMinutes: Int,
        voiceSource: VoiceProfileSource,
        feedbackCount: Int
    ) {
        self.playlistID = playlistID
        self.playlistTitle = playlistTitle
        self.importedSongCount = importedSongCount
        self.verifiedSongCount = verifiedSongCount
        self.pendingSongCount = pendingSongCount
        self.unmatchedSongCount = unmatchedSongCount
        self.scenario = scenario
        self.peopleCount = peopleCount
        self.durationMinutes = durationMinutes
        self.voiceSource = voiceSource
        self.feedbackCount = feedbackCount
    }

    fileprivate var hasNonnegativeValues: Bool {
        importedSongCount >= 0
            && verifiedSongCount >= 0
            && pendingSongCount >= 0
            && unmatchedSongCount >= 0
            && peopleCount >= 0
            && durationMinutes >= 0
            && feedbackCount >= 0
    }
}

public struct SongPlanGenerationSummary: Codable, Equatable, Sendable {
    public let playlistID: UUID
    public let playlistTitle: String
    public let importedSongCount: Int
    public let verifiedSongCount: Int
    public let pendingSongCount: Int
    public let unmatchedSongCount: Int
    public let formalPlanCount: Int
    public let importedMatchCount: Int
    public let adoptedAlternativeCount: Int
    public let supplementCount: Int
    public let scenario: KTVScenario
    public let peopleCount: Int
    public let durationMinutes: Int
    public let voiceSource: VoiceProfileSource
    public let feedbackCount: Int

    enum CodingKeys: String, CodingKey {
        case playlistID
        case playlistTitle
        case importedSongCount
        case verifiedSongCount
        case pendingSongCount
        case unmatchedSongCount
        case formalPlanCount
        case importedMatchCount
        case adoptedAlternativeCount
        case supplementCount
        case scenario
        case peopleCount
        case durationMinutes
        case voiceSource
        case feedbackCount
    }

    public init(
        context: SongPlanGenerationContext,
        items: [SongPlanItem]
    ) throws {
        var formalPlanCount = 0
        var importedMatchCount = 0
        var adoptedAlternativeCount = 0
        var supplementCount = 0

        for item in items {
            formalPlanCount += 1
            switch item.origin {
            case .importedMatch:
                importedMatchCount += 1
            case .adoptedAlternative:
                adoptedAlternativeCount += 1
            case .sameArtistSupplement, .styleSupplement, .sceneSupplement, .popularSupplement:
                supplementCount += 1
            case .legacyUnknown:
                break
            }
        }

        try self.init(
            validatedContext: context,
            formalPlanCount: formalPlanCount,
            importedMatchCount: importedMatchCount,
            adoptedAlternativeCount: adoptedAlternativeCount,
            supplementCount: supplementCount
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let context = SongPlanGenerationContext(
            playlistID: try container.decode(UUID.self, forKey: .playlistID),
            playlistTitle: try container.decode(String.self, forKey: .playlistTitle),
            importedSongCount: try container.decode(Int.self, forKey: .importedSongCount),
            verifiedSongCount: try container.decode(Int.self, forKey: .verifiedSongCount),
            pendingSongCount: try container.decode(Int.self, forKey: .pendingSongCount),
            unmatchedSongCount: try container.decode(Int.self, forKey: .unmatchedSongCount),
            scenario: try container.decode(KTVScenario.self, forKey: .scenario),
            peopleCount: try container.decode(Int.self, forKey: .peopleCount),
            durationMinutes: try container.decode(Int.self, forKey: .durationMinutes),
            voiceSource: try container.decode(VoiceProfileSource.self, forKey: .voiceSource),
            feedbackCount: try container.decode(Int.self, forKey: .feedbackCount)
        )
        try self.init(
            validatedContext: context,
            formalPlanCount: try container.decode(Int.self, forKey: .formalPlanCount),
            importedMatchCount: try container.decode(Int.self, forKey: .importedMatchCount),
            adoptedAlternativeCount: try container.decode(Int.self, forKey: .adoptedAlternativeCount),
            supplementCount: try container.decode(Int.self, forKey: .supplementCount)
        )
    }

    private init(
        validatedContext context: SongPlanGenerationContext,
        formalPlanCount: Int,
        importedMatchCount: Int,
        adoptedAlternativeCount: Int,
        supplementCount: Int
    ) throws {
        let (importedAndAdoptedCount, firstAdditionOverflowed) = importedMatchCount
            .addingReportingOverflow(adoptedAlternativeCount)
        let (classifiedCount, secondAdditionOverflowed) = importedAndAdoptedCount
            .addingReportingOverflow(supplementCount)
        guard context.hasNonnegativeValues,
              formalPlanCount >= 0,
              importedMatchCount >= 0,
              adoptedAlternativeCount >= 0,
              supplementCount >= 0,
              !firstAdditionOverflowed,
              !secondAdditionOverflowed,
              formalPlanCount == classifiedCount else {
            throw RecommendationGenerationError.countMismatch
        }

        playlistID = context.playlistID
        playlistTitle = context.playlistTitle
        importedSongCount = context.importedSongCount
        verifiedSongCount = context.verifiedSongCount
        pendingSongCount = context.pendingSongCount
        unmatchedSongCount = context.unmatchedSongCount
        self.formalPlanCount = formalPlanCount
        self.importedMatchCount = importedMatchCount
        self.adoptedAlternativeCount = adoptedAlternativeCount
        self.supplementCount = supplementCount
        scenario = context.scenario
        peopleCount = context.peopleCount
        durationMinutes = context.durationMinutes
        voiceSource = context.voiceSource
        feedbackCount = context.feedbackCount
    }

    func matchesFinalItems<Items: Sequence>(_ items: Items) -> Bool where Items.Element == SongPlanItem {
        var actualFormalPlanCount = 0
        var actualImportedMatchCount = 0
        var actualAdoptedAlternativeCount = 0
        var actualSupplementCount = 0

        for item in items {
            actualFormalPlanCount += 1
            switch item.origin {
            case .importedMatch:
                actualImportedMatchCount += 1
            case .adoptedAlternative:
                actualAdoptedAlternativeCount += 1
            case .sameArtistSupplement, .styleSupplement, .sceneSupplement, .popularSupplement:
                actualSupplementCount += 1
            case .legacyUnknown:
                break
            }
        }

        return actualFormalPlanCount == formalPlanCount
            && actualImportedMatchCount == importedMatchCount
            && actualAdoptedAlternativeCount == adoptedAlternativeCount
            && actualSupplementCount == supplementCount
    }
}
