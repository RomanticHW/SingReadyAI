import Foundation

public enum SongVersionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case live
    case cover
    case remix
    case accompaniment
    case edit
    case unknown
}

public enum SongVersionCompatibility: Equatable, Sendable {
    case compatible
    case requiresConfirmation
}

public struct SongVersionIdentity: Equatable, Sendable {
    public let normalizedBaseTitle: String
    public let kinds: Set<SongVersionKind>
    public let hasExplicitMarker: Bool

    public static func parse(title: String, versionTags: [String]) -> Self {
        let titleExtraction = SongVersionMarkerParser.extractTitle(from: title)
        var kinds = titleExtraction.kinds
        var hasExplicitMarker = titleExtraction.hasExplicitMarker

        for rawTag in versionTags {
            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            hasExplicitMarker = true
            kinds.formUnion(SongVersionMarkerParser.kinds(inExplicitSegment: tag))
        }

        return SongVersionIdentity(
            normalizedBaseTitle: SongNormalizer.normalizeBaseTitle(titleExtraction.baseTitle),
            kinds: kinds,
            hasExplicitMarker: hasExplicitMarker
        )
    }

    public func compatibility(with other: Self) -> SongVersionCompatibility {
        guard !kinds.contains(.unknown), !other.kinds.contains(.unknown) else {
            return .requiresConfirmation
        }
        guard hasExplicitMarker == other.hasExplicitMarker else {
            return .requiresConfirmation
        }
        return kinds == other.kinds ? .compatible : .requiresConfirmation
    }

    static func strippingVersionMarkers(from value: String) -> String {
        SongVersionMarkerParser.extractTitle(from: value).baseTitle
    }

    static func extractTitleAndVersionTags(
        from value: String
    ) -> (baseTitle: String, versionTags: [String]) {
        let extraction = SongVersionMarkerParser.extractTitle(from: value)
        return (
            baseTitle: extraction.baseTitle,
            versionTags: SongVersionMarkerParser.extractedTags(from: extraction)
        )
    }
}

public enum SongIdentityEvidence: Equatable, Sendable {
    case canonicalTitle(identity: SongVersionIdentity)
    case alias(rawValue: String, identity: SongVersionIdentity)

    public var allowsAutomaticAcceptance: Bool {
        switch self {
        case let .canonicalTitle(identity):
            return !identity.kinds.contains(.unknown)
        case .alias:
            return false
        }
    }
}

private struct SongVersionTitleExtraction {
    let baseTitle: String
    let kinds: Set<SongVersionKind>
    let markerSegments: [String]

    var hasExplicitMarker: Bool {
        !markerSegments.isEmpty
    }
}

private enum SongVersionMarkerParser {
    private struct MarkerDefinition {
        let kind: SongVersionKind
        let tag: String
        let regex: NSRegularExpression
    }

    private struct MarkerHit {
        let location: Int
        let kind: SongVersionKind
        let tag: String
    }

    private static let markerDefinitions: [MarkerDefinition] = [
        MarkerDefinition(kind: .live, tag: "Live", regex: regex(#"(?i)(?<![a-z0-9])live(?![a-z0-9])"#)),
        MarkerDefinition(kind: .live, tag: "现场", regex: regex(#"现场"#)),
        MarkerDefinition(kind: .cover, tag: "Cover", regex: regex(#"(?i)(?<![a-z0-9])cover(?![a-z0-9])"#)),
        MarkerDefinition(kind: .cover, tag: "翻唱", regex: regex(#"翻唱"#)),
        MarkerDefinition(kind: .remix, tag: "Remix", regex: regex(#"(?i)(?<![a-z0-9])remix(?![a-z0-9])"#)),
        MarkerDefinition(kind: .remix, tag: "DJ", regex: regex(#"(?i)(?<![a-z0-9])dj(?![a-z0-9])"#)),
        MarkerDefinition(kind: .accompaniment, tag: "伴奏", regex: regex(#"伴奏"#)),
        MarkerDefinition(kind: .edit, tag: "Edit", regex: regex(#"(?i)(?<![a-z0-9])edit(?![a-z0-9])"#)),
        MarkerDefinition(kind: .edit, tag: "剪辑", regex: regex(#"剪辑"#))
    ]

    private static let parenthesizedMarkerRegex = regex(
        #"\s*[\(（\[【][^\)）\]】]{0,48}(?i:live|cover|remix|dj|edit|现场|翻唱|伴奏|剪辑|版|version|edition)[^\)）\]】]{0,48}[\)）\]】]"#
    )
    private static let knownTrailingMarkerRegex = regex(
        #"(?i)\s+(?:(?:live|cover|remix|dj|edit)(?:\s*(?:version|edition|版))?|(?:现场|翻唱|伴奏|剪辑)(?:版)?)(?:\s+(?:(?:live|cover|remix|dj|edit)(?:\s*(?:version|edition|版))?|(?:现场|翻唱|伴奏|剪辑)(?:版)?))*\s*$"#
    )
    private static let compactEnglishMarkerRegex = regex(
        #"(?i)(?<![a-z0-9])(?:live|cover|remix|dj|edit)版\s*$"#
    )
    private static let compactChineseMarkerRegex = regex(
        #"(?:现场|翻唱|伴奏|剪辑)版\s*$"#
    )
    private static let unknownChineseVersionRegex = regex(
        #"\s+[^\s\(\)（）\[\]【】]{1,16}版\s*$"#
    )
    private static let unknownEnglishVersionRegex = regex(
        #"(?i)\s+[a-z][a-z0-9'-]*(?:\s+[a-z0-9][a-z0-9'-]*){0,3}\s+(?:version|edition)\s*$"#
    )
    private static let framingMarkerRegex = regex(
        #"(?i)(?<![a-z0-9])(?:version|edition)(?![a-z0-9])|版"#
    )
    private static let nonSemanticSeparatorRegex = regex(#"[\s\p{P}\p{S}]+"#)

    static func extractTitle(from value: String) -> SongVersionTitleExtraction {
        var baseTitle = value
        var markerSegments: [String] = []

        let parenthesizedSegments = removeAllMatches(
            of: parenthesizedMarkerRegex,
            from: &baseTitle
        )
        markerSegments.append(contentsOf: parenthesizedSegments)

        if let segment = removeFirstMatch(of: knownTrailingMarkerRegex, from: &baseTitle) {
            markerSegments.append(segment)
        } else if let segment = removeFirstMatch(of: compactEnglishMarkerRegex, from: &baseTitle) {
            markerSegments.append(segment)
        } else if let segment = removeFirstMatch(of: compactChineseMarkerRegex, from: &baseTitle) {
            markerSegments.append(segment)
        } else if let segment = removeFirstMatch(of: unknownChineseVersionRegex, from: &baseTitle) {
            markerSegments.append(segment)
        } else if let segment = removeFirstMatch(of: unknownEnglishVersionRegex, from: &baseTitle) {
            markerSegments.append(segment)
        }

        let extractedKinds = markerSegments.reduce(into: Set<SongVersionKind>()) { result, segment in
            result.formUnion(kinds(inExplicitSegment: segment))
        }

        return SongVersionTitleExtraction(
            baseTitle: baseTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            kinds: extractedKinds,
            markerSegments: markerSegments
        )
    }

    static func knownKinds(in value: String) -> Set<SongVersionKind> {
        Set(markerHits(in: value).map(\.kind))
    }

    static func kinds(inExplicitSegment segment: String) -> Set<SongVersionKind> {
        let hits = markerHits(in: segment)
        var kinds = Set(hits.map(\.kind))
        if hits.isEmpty || semanticResidual(in: segment) != nil {
            kinds.insert(.unknown)
        }
        return kinds
    }

    static func extractedTags(from extraction: SongVersionTitleExtraction) -> [String] {
        var tags: [String] = []
        for segment in extraction.markerSegments {
            let hits = markerHits(in: segment)
            tags.append(contentsOf: hits.map(\.tag))

            if hits.isEmpty {
                let unknownTag = segment.trimmingCharacters(
                    in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
                )
                if !unknownTag.isEmpty {
                    tags.append(unknownTag)
                }
            } else if let residual = semanticResidual(in: segment) {
                tags.append(residual)
            }
        }

        var seen = Set<String>()
        return tags.filter { tag in
            seen.insert(tag.lowercased()).inserted
        }
    }

    private static func semanticResidual(in segment: String) -> String? {
        var residual = segment
        for definition in markerDefinitions {
            residual = replacingMatches(of: definition.regex, in: residual, with: " ")
        }
        residual = replacingMatches(of: framingMarkerRegex, in: residual, with: " ")
        residual = replacingMatches(of: nonSemanticSeparatorRegex, in: residual, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return residual.rangeOfCharacter(from: .alphanumerics) == nil ? nil : residual
    }

    private static func markerHits(in value: String) -> [MarkerHit] {
        let searchRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return markerDefinitions
            .flatMap { definition in
                definition.regex.matches(in: value, range: searchRange).map { match in
                    MarkerHit(
                        location: match.range.location,
                        kind: definition.kind,
                        tag: definition.tag
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.location == rhs.location {
                    return lhs.tag < rhs.tag
                }
                return lhs.location < rhs.location
            }
    }

    private static func removeAllMatches(
        of regex: NSRegularExpression,
        from value: inout String
    ) -> [String] {
        let searchRange = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.matches(in: value, range: searchRange)
        var segments: [String] = []
        for match in matches.reversed() {
            guard let range = Range(match.range, in: value) else { continue }
            segments.insert(String(value[range]), at: 0)
            value.removeSubrange(range)
        }
        return segments
    }

    private static func removeFirstMatch(
        of regex: NSRegularExpression,
        from value: inout String
    ) -> String? {
        let searchRange = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: searchRange),
              let range = Range(match.range, in: value) else {
            return nil
        }
        let segment = String(value[range])
        value.removeSubrange(range)
        return segment
    }

    private static func replacingMatches(
        of regex: NSRegularExpression,
        in value: String,
        with replacement: String
    ) -> String {
        let searchRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(
            in: value,
            range: searchRange,
            withTemplate: replacement
        )
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}
