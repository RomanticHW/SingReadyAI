import Foundation

public struct WorkflowRevisionLedger: Codable, Equatable, Sendable {
    public var review: UInt64
    public var match: UInt64
    public var feedback: UInt64
    public var trackControls: UInt64

    public init(
        review: UInt64 = 0,
        match: UInt64 = 0,
        feedback: UInt64 = 0,
        trackControls: UInt64 = 0
    ) {
        self.review = review
        self.match = match
        self.feedback = feedback
        self.trackControls = trackControls
    }
}

public struct MatchBasis: Codable, Equatable, Sendable {
    public let playlistID: UUID
    public let reviewRevision: UInt64
    public let catalogRevision: String

    public init(
        playlistID: UUID,
        reviewRevision: UInt64,
        catalogRevision: String
    ) {
        self.playlistID = playlistID
        self.reviewRevision = reviewRevision
        self.catalogRevision = catalogRevision
    }
}

public struct PlanBasis: Codable, Equatable, Sendable {
    public let matchBasis: MatchBasis
    public let matchRevision: UInt64
    public let scenarioFingerprint: String
    public let voiceSource: VoiceProfileSource
    public let voiceFingerprint: String
    public let feedbackRevision: UInt64
    public let trackControlsRevision: UInt64
    public let catalogRevision: String

    public var isWellFormed: Bool {
        catalogRevision == matchBasis.catalogRevision
    }

    public init(
        matchBasis: MatchBasis,
        matchRevision: UInt64,
        scenarioFingerprint: String,
        voiceSource: VoiceProfileSource,
        voiceFingerprint: String,
        feedbackRevision: UInt64,
        trackControlsRevision: UInt64,
        catalogRevision: String
    ) {
        self.matchBasis = matchBasis
        self.matchRevision = matchRevision
        self.scenarioFingerprint = scenarioFingerprint
        self.voiceSource = voiceSource
        self.voiceFingerprint = voiceFingerprint
        self.feedbackRevision = feedbackRevision
        self.trackControlsRevision = trackControlsRevision
        self.catalogRevision = catalogRevision == matchBasis.catalogRevision
            ? catalogRevision
            : matchBasis.catalogRevision
    }

    private enum CodingKeys: String, CodingKey {
        case matchBasis
        case matchRevision
        case scenarioFingerprint
        case voiceSource
        case voiceFingerprint
        case feedbackRevision
        case trackControlsRevision
        case catalogRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let matchBasis = try container.decode(MatchBasis.self, forKey: .matchBasis)
        let catalogRevision = try container.decode(String.self, forKey: .catalogRevision)
        guard catalogRevision == matchBasis.catalogRevision else {
            throw DecodingError.dataCorruptedError(
                forKey: .catalogRevision,
                in: container,
                debugDescription: "PlanBasis 的曲库修订与 MatchBasis 不一致"
            )
        }
        self.init(
            matchBasis: matchBasis,
            matchRevision: try container.decode(UInt64.self, forKey: .matchRevision),
            scenarioFingerprint: try container.decode(String.self, forKey: .scenarioFingerprint),
            voiceSource: try container.decode(VoiceProfileSource.self, forKey: .voiceSource),
            voiceFingerprint: try container.decode(String.self, forKey: .voiceFingerprint),
            feedbackRevision: try container.decode(UInt64.self, forKey: .feedbackRevision),
            trackControlsRevision: try container.decode(UInt64.self, forKey: .trackControlsRevision),
            catalogRevision: catalogRevision
        )
    }
}

public enum PlaylistWorkflowFingerprint {
    public static func catalogRevision(for tracks: [KTVTrack]) -> String {
        let records = tracks
            .filter { $0.catalogSource == .ktvCatalog }
            .map { track -> String in
                let identity = SongVersionIdentity.parse(
                    title: track.title,
                    versionTags: track.versionTags
                )
                let versionKinds = identity.kinds.map(\.rawValue).sorted()
                let unknownVersion = identity.kinds.contains(.unknown)
                    ? SongVersionIdentity.deduplicationUnknownFingerprint(
                        title: track.title,
                        versionTags: track.versionTags
                    )
                    : ""
                let externalMetadata = track.externalCandidateMetadata.map { metadata in
                    stableRecord([
                        metadata.relation.rawValue,
                        String(metadata.relevance.bitPattern, radix: 16),
                        stableSet(metadata.reasons),
                        metadata.provider.rawValue
                    ])
                } ?? ""
                return stableRecord([
                    canonicalText(track.id),
                    canonicalText(track.title),
                    canonicalText(track.artist),
                    canonicalText(track.language),
                    canonicalText(track.era),
                    canonicalText(track.genre),
                    stableSet(track.moodTags),
                    stableSet(track.sceneTags),
                    String(track.difficulty),
                    String(track.vocalRangeLowMidi),
                    String(track.vocalRangeHighMidi),
                    String(track.energy.bitPattern, radix: 16),
                    String(track.singAlongScore.bitPattern, radix: 16),
                    String(track.ktvAvailability.bitPattern, radix: 16),
                    track.duetFriendly ? "true" : "false",
                    String(track.rapDensity.bitPattern, radix: 16),
                    String(track.highNoteRisk.bitPattern, radix: 16),
                    stableSet(track.aliases),
                    stableSet(track.versionTags),
                    stableSet(track.similarSongIds),
                    track.externalURL.map { canonicalText($0.absoluteString) } ?? "",
                    track.catalogSource.rawValue,
                    track.confidenceNote.map(canonicalText) ?? "",
                    externalMetadata,
                    identity.normalizedBaseTitle,
                    identity.hasExplicitMarker ? "explicit" : "studio",
                    stableRecord(versionKinds),
                    unknownVersion
                ])
            }
            .sorted()
        return digest(prefix: "catalog-v1", components: records)
    }

    public static func scenario(for config: ScenarioConfig) -> String {
        digest(
            prefix: "scenario-v1",
            components: [
                config.scenario.rawValue,
                String(config.peopleCount),
                String(config.durationMinutes),
                config.vibe.rawValue,
                config.chorusPreference.rawValue,
                config.difficultyPreference.rawValue
            ]
        )
    }

    public static func voice(for profile: VoiceProfile) -> String {
        digest(
            prefix: "voice-v1",
            components: [
                profile.type.rawValue,
                String(profile.minMidi),
                String(profile.maxMidi),
                String(profile.stableLowMidi),
                String(profile.stableHighMidi),
                String(profile.averageMidi.bitPattern, radix: 16),
                String(profile.confidence.bitPattern, radix: 16),
                canonicalText(profile.note),
                stableRecord(profile.suitableSongTypes.map(canonicalText)),
                stableRecord(profile.avoidSongTypes.map(canonicalText)),
                stableRecord(profile.singingStrategy.map(canonicalText))
            ]
        )
    }

    private static func digest(prefix: String, components: [String]) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037

        func absorb(_ bytes: some Sequence<UInt8>) {
            for byte in bytes {
                value ^= UInt64(byte)
                value &*= 1_099_511_628_211
            }
        }

        absorb(prefix.utf8)
        for component in components {
            let bytes = component.utf8
            absorb(String(bytes.count).utf8)
            absorb([UInt8(ascii: ":")])
            absorb(bytes)
            absorb([UInt8(ascii: ";")])
        }

        let hexadecimal = String(value, radix: 16)
        let padded = String(repeating: "0", count: max(0, 16 - hexadecimal.count)) + hexadecimal
        return "\(prefix)-\(padded)"
    }

    private static func stableRecord(_ components: [String]) -> String {
        components.map { component in
            "\(component.utf8.count):\(component)"
        }.joined(separator: ";")
    }

    private static func stableSet(_ values: [String]) -> String {
        stableRecord(values.map(canonicalText).sorted())
    }

    private static func canonicalText(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct CompletedPlaylistAnalysis: Codable, Sendable {
    public let basis: MatchBasis
    public let matchRevision: UInt64
    public let matches: [MatchResult]
    public let preferenceProfile: PreferenceProfile

    public init(
        basis: MatchBasis,
        matchRevision: UInt64,
        matches: [MatchResult],
        preferenceProfile: PreferenceProfile
    ) {
        self.basis = basis
        self.matchRevision = matchRevision
        self.matches = matches
        self.preferenceProfile = preferenceProfile
    }
}

public enum MatchReviewAction: Sendable {
    case confirmOriginal(resultID: UUID, trackID: String)
    case adoptAlternative(resultID: UUID, trackID: String)
}

public enum MatchReviewActionError: Error, Equatable, LocalizedError, Sendable {
    case resultNotFound
    case trackNotSelectable

    public var errorDescription: String? {
        switch self {
        case .resultNotFound:
            return "这条匹配结果已经变化，请刷新后再试。"
        case .trackNotSelectable:
            return "这首歌已不在可选范围，请重新核对。"
        }
    }
}

public extension CompletedPlaylistAnalysis {
    func applying(
        _ action: MatchReviewAction,
        profiler: PreferenceProfiler
    ) throws -> CompletedPlaylistAnalysis {
        let resultID: UUID
        switch action {
        case let .confirmOriginal(id, _), let .adoptAlternative(id, _):
            resultID = id
        }
        guard let resultIndex = matches.firstIndex(where: { $0.id == resultID }) else {
            throw MatchReviewActionError.resultNotFound
        }

        var updatedMatches = matches
        let updatedResult: MatchResult?
        switch action {
        case let .confirmOriginal(_, trackID):
            guard let track = matches[resultIndex].candidateTracks.first(where: {
                $0.id == trackID && $0.catalogSource == .ktvCatalog
            }) else {
                throw MatchReviewActionError.trackNotSelectable
            }
            updatedResult = matches[resultIndex].confirming(track: track)
        case let .adoptAlternative(_, trackID):
            guard let track = (matches[resultIndex].candidateTracks + matches[resultIndex].suggestedAlternatives)
                .first(where: { $0.id == trackID && $0.catalogSource == .ktvCatalog }) else {
                throw MatchReviewActionError.trackNotSelectable
            }
            updatedResult = matches[resultIndex].adoptingAlternative(track: track)
        }
        guard let updatedResult else {
            throw MatchReviewActionError.trackNotSelectable
        }
        updatedMatches[resultIndex] = updatedResult

        let playlist = ImportedPlaylist(
            id: basis.playlistID,
            source: updatedMatches.first?.importedSong.source ?? .plainText,
            title: "已整理歌单",
            songs: updatedMatches.map(\.importedSong),
            parseConfidence: updatedMatches.map(\.importedSong.confidence).reduce(0, +)
                / Double(max(updatedMatches.count, 1))
        )
        return CompletedPlaylistAnalysis(
            basis: basis,
            matchRevision: matchRevision &+ 1,
            matches: updatedMatches,
            preferenceProfile: profiler.buildProfile(
                importedPlaylist: playlist,
                matches: updatedMatches
            )
        )
    }
}

private struct ValidatedPlaylistAnalysis {
    let importedCount: Int
    let validReviewedCount: Int
    let verifiedCount: Int
    let pendingCount: Int
    let unmatchedCount: Int
}

private enum PlaylistAnalysisSnapshotValidator {
    static func validate(
        playlist: ImportedPlaylist,
        reviewSongs: [WorkflowReviewSong],
        analysis: CompletedPlaylistAnalysis,
        currentBasis: MatchBasis
    ) -> ValidatedPlaylistAnalysis? {
        guard currentBasis.playlistID == playlist.id,
              analysis.basis == currentBasis else {
            return nil
        }

        let playlistIDs = Set(playlist.songs.map(\.id))
        guard playlistIDs.count == playlist.songs.count else { return nil }

        var allReviewIDs = Set<UUID>()
        var activeReviewSongsByID: [UUID: ImportedSong] = [:]
        for reviewSong in reviewSongs {
            guard playlistIDs.contains(reviewSong.id),
                  allReviewIDs.insert(reviewSong.id).inserted else {
                return nil
            }
            guard !reviewSong.isDeleted else { continue }
            guard !reviewSong.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            activeReviewSongsByID[reviewSong.id] = reviewSong.importedSong
        }
        guard allReviewIDs == playlistIDs,
              analysis.matches.count == activeReviewSongsByID.count else {
            return nil
        }

        var verifiedCount = 0
        var pendingCount = 0
        var unmatchedCount = 0
        var analyzedSongIDs = Set<UUID>()

        for match in analysis.matches {
            let songID = match.importedSong.id
            guard analyzedSongIDs.insert(songID).inserted,
                  let reviewedSong = activeReviewSongsByID[songID],
                  reviewedSong == match.importedSong else {
                return nil
            }

            switch match.disposition {
            case .acceptedOriginalExact, .acceptedOriginalConfirmed, .adoptedAlternative:
                verifiedCount += 1
            case .identityConfirmationRequired, .alternativeSuggested:
                pendingCount += 1
            case .unmatched:
                unmatchedCount += 1
            }
        }

        guard analyzedSongIDs == Set(activeReviewSongsByID.keys) else { return nil }
        return ValidatedPlaylistAnalysis(
            importedCount: playlist.songs.count,
            validReviewedCount: activeReviewSongsByID.count,
            verifiedCount: verifiedCount,
            pendingCount: pendingCount,
            unmatchedCount: unmatchedCount
        )
    }
}

public struct PlaylistPreparationSummary: Equatable, Sendable {
    public let importedCount: Int
    public let validReviewedCount: Int
    public let verifiedCount: Int
    public let pendingCount: Int
    public let unmatchedCount: Int
    public let canContinue: Bool

    public init?(
        playlist: ImportedPlaylist,
        reviewSongs: [WorkflowReviewSong],
        analysis: CompletedPlaylistAnalysis?,
        currentBasis: MatchBasis
    ) {
        guard let analysis,
              let validated = PlaylistAnalysisSnapshotValidator.validate(
                playlist: playlist,
                reviewSongs: reviewSongs,
                analysis: analysis,
                currentBasis: currentBasis
              ) else {
            return nil
        }

        importedCount = validated.importedCount
        validReviewedCount = validated.validReviewedCount
        verifiedCount = validated.verifiedCount
        pendingCount = validated.pendingCount
        unmatchedCount = validated.unmatchedCount
        canContinue = validated.validReviewedCount > 0
    }
}

public enum ImportOperationState: Equatable, Sendable {
    case idle
    case resolving
    case failed(message: String, retryable: Bool)
    case cancelled
}

public enum MatchOperationState: Equatable, Sendable {
    case notStarted
    case running(processed: Int, total: Int)
    case ready(MatchBasis)
    case failed(message: String, retryable: Bool)
    case cancelled
}

public struct StalePlanSnapshot: Codable, Sendable {
    public let plan: SongPlan
    public let previousBasis: PlanBasis?
    public let reason: String

    public init(
        plan: SongPlan,
        previousBasis: PlanBasis?,
        reason: String
    ) {
        self.plan = plan
        self.previousBasis = previousBasis
        self.reason = reason
    }
}

public enum PlanGenerationState: Sendable {
    case absent
    case generating(basis: PlanBasis, previous: StalePlanSnapshot?)
    case ready(plan: SongPlan, basis: PlanBasis)
    case stale(StalePlanSnapshot)
    case failed(message: String, retryable: Bool, previous: StalePlanSnapshot?)
}

public enum PlaylistWorkflowValidityPolicy {
    public static func accepts(matchBasis: MatchBasis, current: MatchBasis) -> Bool {
        matchBasis == current
    }

    public static func accepts(planBasis: PlanBasis, current: PlanBasis) -> Bool {
        planBasis.isWellFormed && current.isWellFormed && planBasis == current
    }

    public static func restoredMatchState(
        persistedAnalysis: CompletedPlaylistAnalysis?,
        currentBasis: MatchBasis,
        currentMatchRevision: UInt64,
        playlist: ImportedPlaylist,
        reviewSongs: [WorkflowReviewSong]
    ) -> MatchOperationState {
        guard let persistedAnalysis,
              persistedAnalysis.matchRevision == currentMatchRevision,
              PlaylistAnalysisSnapshotValidator.validate(
                playlist: playlist,
                reviewSongs: reviewSongs,
                analysis: persistedAnalysis,
                currentBasis: currentBasis
              ) != nil else {
            return .notStarted
        }
        return .ready(persistedAnalysis.basis)
    }
}
