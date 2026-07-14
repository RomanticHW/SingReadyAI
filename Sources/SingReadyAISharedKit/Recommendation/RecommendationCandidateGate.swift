import Foundation

public struct RecommendationCandidate: Sendable {
    public let track: KTVTrack
    public let origin: SongRecommendationOrigin

    public init(track: KTVTrack, origin: SongRecommendationOrigin) {
        self.track = track
        self.origin = origin
    }
}

public struct RecommendationCandidateGate: Sendable {
    private static let localSupplementLimit = 90

    public init() {}

    public func candidates(
        matches: [MatchResult],
        preferenceProfile: PreferenceProfile,
        scenario: ScenarioConfig,
        catalog: [KTVTrack],
        lockedTrackIDs: Set<String>
    ) throws -> [RecommendationCandidate] {
        var accumulator = CandidateAccumulator(lockedTrackIDs: lockedTrackIDs)
        var legalMatchTrackIDs = Set<String>()

        for match in matches {
            switch match.disposition {
            case let .acceptedOriginalExact(track),
                 let .acceptedOriginalConfirmed(track):
                if track.catalogSource == .ktvCatalog {
                    legalMatchTrackIDs.insert(track.id)
                }
                addLocal(track, origin: .importedMatch, to: &accumulator)
            case let .adoptedAlternative(track):
                if track.catalogSource == .ktvCatalog {
                    legalMatchTrackIDs.insert(track.id)
                }
                addLocal(track, origin: .adoptedAlternative, to: &accumulator)
            case .identityConfirmationRequired,
                 .alternativeSuggested,
                 .unmatched:
                break
            }
        }
        let unadoptedTrackIDs = Set(
            matches.flatMap { $0.candidateTracks + $0.suggestedAlternatives }.map(\.id)
        )

        let preferredArtists = Set(preferenceProfile.topArtists.map(\.name))
        let preferredGenres = Set(
            preferenceProfile.genreDistribution
                .filter { $0.value >= 0.15 }
                .map(\.key)
        )
        let preferredMoods = Set(
            preferenceProfile.moodTags
                .filter { $0.value >= 0.12 }
                .map(\.key)
        )
        let classifiedSupplements = catalog.compactMap { track -> RecommendationCandidate? in
            guard track.catalogSource == .ktvCatalog,
                  !unadoptedTrackIDs.contains(track.id) || legalMatchTrackIDs.contains(track.id),
                  let origin = supplementOrigin(
                    for: track,
                    preferredArtists: preferredArtists,
                    preferredGenres: preferredGenres,
                    preferredMoods: preferredMoods,
                    scenario: scenario
                  ) else {
                return nil
            }
            return RecommendationCandidate(track: track, origin: origin)
        }
        let regularSupplementIDs = Set(
            classifiedSupplements.prefix(Self.localSupplementLimit).map(\.track.id)
        )

        for candidate in classifiedSupplements
        where regularSupplementIDs.contains(candidate.track.id)
            || lockedTrackIDs.contains(candidate.track.id) {
            accumulator.add(candidate)
        }

        let candidates = accumulator.candidates
        let availableTrackIDs = Set(candidates.map(\.track.id))
        let unavailableTrackIDs = lockedTrackIDs
            .subtracting(availableTrackIDs)
            .sorted()
        guard unavailableTrackIDs.isEmpty else {
            throw RecommendationGenerationError.lockedTrackUnavailable(
                trackIDs: unavailableTrackIDs
            )
        }
        return candidates
    }

    static func semanticKey(for track: KTVTrack) -> String {
        let identity = SongVersionIdentity.parse(
            title: track.title,
            versionTags: track.versionTags
        )
        let artist = SongNormalizer.normalizeArtist(track.artist)
        guard !identity.normalizedBaseTitle.isEmpty, !artist.isEmpty else {
            return "id:\(track.id)"
        }
        let kinds = identity.kinds
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        let unknownFingerprint = SongVersionIdentity.deduplicationUnknownFingerprint(
            title: track.title,
            versionTags: track.versionTags
        )
        return [
            identity.normalizedBaseTitle,
            artist,
            identity.hasExplicitMarker ? "explicit" : "studio",
            kinds,
            unknownFingerprint
        ].joined(separator: "|")
    }

    private func addLocal(
        _ track: KTVTrack,
        origin: SongRecommendationOrigin,
        to accumulator: inout CandidateAccumulator
    ) {
        guard track.catalogSource == .ktvCatalog else { return }
        accumulator.add(RecommendationCandidate(track: track, origin: origin))
    }

    private func supplementOrigin(
        for track: KTVTrack,
        preferredArtists: Set<String>,
        preferredGenres: Set<String>,
        preferredMoods: Set<String>,
        scenario: ScenarioConfig
    ) -> SongRecommendationOrigin? {
        if preferredArtists.contains(track.artist) {
            return .sameArtistSupplement
        }
        if preferredGenres.contains(track.genre)
            || !preferredMoods.isDisjoint(with: track.moodTags) {
            return .styleSupplement
        }
        if track.sceneTags.contains(scenario.scenario.rawValue) {
            return .sceneSupplement
        }
        if track.singAlongScore >= 0.86 {
            return .popularSupplement
        }
        return nil
    }
}

private struct CandidateAccumulator {
    let lockedTrackIDs: Set<String>
    private var candidatesBySemanticKey: [String: RecommendationCandidate] = [:]

    init(lockedTrackIDs: Set<String>) {
        self.lockedTrackIDs = lockedTrackIDs
    }

    var candidates: [RecommendationCandidate] {
        candidatesBySemanticKey.values.sorted { lhs, rhs in
            let leftKey = RecommendationCandidateGate.semanticKey(for: lhs.track)
            let rightKey = RecommendationCandidateGate.semanticKey(for: rhs.track)
            if leftKey != rightKey {
                return leftKey < rightKey
            }
            return lhs.track.id < rhs.track.id
        }
    }

    mutating func add(_ candidate: RecommendationCandidate) {
        let key = RecommendationCandidateGate.semanticKey(for: candidate.track)
        guard let existing = candidatesBySemanticKey[key] else {
            candidatesBySemanticKey[key] = candidate
            return
        }
        let candidateIsLocked = lockedTrackIDs.contains(candidate.track.id)
        let existingIsLocked = lockedTrackIDs.contains(existing.track.id)
        if candidateIsLocked != existingIsLocked {
            if candidateIsLocked {
                candidatesBySemanticKey[key] = candidate
            }
            return
        }
        if candidate.origin.recommendationPriority > existing.origin.recommendationPriority
            || (candidate.origin.recommendationPriority == existing.origin.recommendationPriority
                && candidate.track.id < existing.track.id) {
            candidatesBySemanticKey[key] = candidate
        }
    }
}

private extension SongRecommendationOrigin {
    var recommendationPriority: Int {
        switch self {
        case .adoptedAlternative: return 6
        case .importedMatch: return 5
        case .sameArtistSupplement: return 4
        case .styleSupplement: return 3
        case .sceneSupplement: return 2
        case .popularSupplement: return 1
        case .legacyUnknown: return 0
        }
    }
}
