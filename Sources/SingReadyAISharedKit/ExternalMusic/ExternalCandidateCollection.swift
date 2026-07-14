import Foundation

public struct ExternalCandidateBasis: Codable, Equatable, Sendable {
    public let playlistID: UUID
    public let reviewRevision: UInt64
    public let requestRevision: UInt64

    public init(
        playlistID: UUID,
        reviewRevision: UInt64,
        requestRevision: UInt64
    ) {
        self.playlistID = playlistID
        self.reviewRevision = reviewRevision
        self.requestRevision = requestRevision
    }
}

public struct ExternalCandidateCollection: Codable, Equatable, Sendable {
    private struct SemanticKey: Hashable, Comparable {
        let normalizedBaseTitle: String
        let normalizedArtist: String
        let version: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.normalizedBaseTitle != rhs.normalizedBaseTitle {
                return lhs.normalizedBaseTitle < rhs.normalizedBaseTitle
            }
            if lhs.normalizedArtist != rhs.normalizedArtist {
                return lhs.normalizedArtist < rhs.normalizedArtist
            }
            return lhs.version < rhs.version
        }
    }

    public let basis: ExternalCandidateBasis
    public let candidates: [ExternalSongCandidate]

    public var count: Int { candidates.count }

    public init(
        basis: ExternalCandidateBasis,
        candidates: [ExternalSongCandidate]
    ) {
        self.basis = basis
        self.candidates = Self.normalizedCandidates(candidates)
    }

    private enum CodingKeys: String, CodingKey {
        case basis
        case candidates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            basis: try container.decode(ExternalCandidateBasis.self, forKey: .basis),
            candidates: try container.decode([ExternalSongCandidate].self, forKey: .candidates)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(basis, forKey: .basis)
        try container.encode(candidates, forKey: .candidates)
    }

    private static func normalizedCandidates(
        _ candidates: [ExternalSongCandidate]
    ) -> [ExternalSongCandidate] {
        var candidatesBySemanticKey: [SemanticKey: ExternalSongCandidate] = [:]

        for rawCandidate in candidates {
            let candidate = normalizedCandidate(rawCandidate)
            let key = semanticKey(for: candidate)
            guard let existing = candidatesBySemanticKey[key] else {
                candidatesBySemanticKey[key] = candidate
                continue
            }
            if isPreferred(candidate, over: existing) {
                candidatesBySemanticKey[key] = candidate
            }
        }

        return candidatesBySemanticKey.values.sorted(by: stableOrder)
    }

    private static func normalizedCandidate(
        _ candidate: ExternalSongCandidate
    ) -> ExternalSongCandidate {
        let confidence = candidate.confidence.isFinite
            ? min(max(candidate.confidence, 0), 1)
            : 0
        let reasons = Array(Set(candidate.reasons.compactMap { reason -> String? in
            let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        })).sorted()

        return ExternalSongCandidate(
            title: candidate.title,
            artist: candidate.artist,
            source: candidate.source,
            confidence: confidence,
            relation: candidate.relation,
            reasons: reasons,
            externalURL: candidate.externalURL,
            appleTrackID: candidate.appleTrackID,
            musicBrainzRecordingID: candidate.musicBrainzRecordingID,
            musicBrainzArtistID: candidate.musicBrainzArtistID,
            isrc: candidate.isrc,
            primaryGenreName: candidate.primaryGenreName,
            releaseYear: candidate.releaseYear
        )
    }

    private static func semanticKey(for candidate: ExternalSongCandidate) -> SemanticKey {
        let identity = SongVersionIdentity.parse(
            title: candidate.title,
            versionTags: []
        )
        let artist = candidate.artist.map(SongNormalizer.normalizeArtist) ?? ""
        let version: String

        if identity.hasExplicitMarker {
            let kinds = identity.kinds.map(\.rawValue).sorted().joined(separator: ",")
            let unknownFingerprint = identity.kinds.contains(.unknown)
                ? SongVersionIdentity.deduplicationUnknownFingerprint(
                    title: candidate.title,
                    versionTags: []
                )
                : ""
            version = "version:\(kinds):\(unknownFingerprint)"
        } else {
            version = "studio"
        }

        return SemanticKey(
            normalizedBaseTitle: identity.normalizedBaseTitle,
            normalizedArtist: artist,
            version: version
        )
    }

    private static func stableOrder(
        _ lhs: ExternalSongCandidate,
        _ rhs: ExternalSongCandidate
    ) -> Bool {
        if lhs.confidence != rhs.confidence {
            return lhs.confidence > rhs.confidence
        }
        let lhsSemanticKey = semanticKey(for: lhs)
        let rhsSemanticKey = semanticKey(for: rhs)
        if lhsSemanticKey != rhsSemanticKey {
            return lhsSemanticKey < rhsSemanticKey
        }
        return tieBreakComponents(for: lhs).lexicographicallyPrecedes(
            tieBreakComponents(for: rhs)
        )
    }

    private static func isPreferred(
        _ lhs: ExternalSongCandidate,
        over rhs: ExternalSongCandidate
    ) -> Bool {
        if lhs.confidence != rhs.confidence {
            return lhs.confidence > rhs.confidence
        }
        return tieBreakComponents(for: lhs).lexicographicallyPrecedes(
            tieBreakComponents(for: rhs)
        )
    }

    private static func tieBreakComponents(
        for candidate: ExternalSongCandidate
    ) -> [String] {
        var components = [
            candidate.source.rawValue,
            candidate.relation.rawValue,
            optionalComponent(candidate.externalURL?.absoluteString),
            optionalComponent(candidate.appleTrackID),
            optionalComponent(candidate.musicBrainzRecordingID),
            optionalComponent(candidate.musicBrainzArtistID),
            optionalComponent(candidate.isrc),
            optionalComponent(candidate.primaryGenreName),
            optionalComponent(candidate.releaseYear.map(String.init)),
            candidate.title,
            optionalComponent(candidate.artist),
            "reasons:\(candidate.reasons.count)"
        ]
        components.append(contentsOf: candidate.reasons.map { "reason:\($0)" })
        components.append(String(candidate.confidence.bitPattern, radix: 16))
        return components
    }

    private static func optionalComponent(_ value: String?) -> String {
        value.map { "1:\($0)" } ?? "0:"
    }
}

public struct ExternalCandidateCollectionAccumulator: Sendable {
    public init() {}

    public func mergedCollection(
        basis: ExternalCandidateBasis,
        existing: ExternalCandidateCollection? = nil,
        incoming: [ExternalSongCandidate],
        limit: Int = 12
    ) -> ExternalCandidateCollection {
        let inheritedCandidates = existing?.basis == basis
            ? existing?.candidates ?? []
            : []
        let merged = ExternalCandidateCollection(
            basis: basis,
            candidates: inheritedCandidates + incoming
        )
        return ExternalCandidateCollection(
            basis: basis,
            candidates: Array(merged.candidates.prefix(max(0, limit)))
        )
    }
}
