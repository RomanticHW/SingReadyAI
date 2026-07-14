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
        self.catalogRevision = catalogRevision
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
                return stableRecord([
                    canonicalText(track.id),
                    canonicalText(track.title),
                    canonicalText(track.artist),
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
        analysis: CompletedPlaylistAnalysis?
    ) {
        guard let analysis,
              analysis.basis.playlistID == playlist.id else {
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

        importedCount = playlist.songs.count
        validReviewedCount = activeReviewSongsByID.count
        self.verifiedCount = verifiedCount
        self.pendingCount = pendingCount
        self.unmatchedCount = unmatchedCount
        canContinue = !activeReviewSongsByID.isEmpty
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
        planBasis == current
    }

    public static func restoredMatchState(
        persistedAnalysis: CompletedPlaylistAnalysis?,
        currentBasis: MatchBasis
    ) -> MatchOperationState {
        guard let persistedAnalysis,
              persistedAnalysis.basis == currentBasis else {
            return .notStarted
        }
        return .ready(persistedAnalysis.basis)
    }
}
