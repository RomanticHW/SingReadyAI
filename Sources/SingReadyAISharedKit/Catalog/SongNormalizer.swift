import Foundation

public struct SongNormalizer: Sendable {
    private static let punctuationAndWhitespaceRegex = try! NSRegularExpression(
        pattern: #"[\p{P}\p{S}\s]+"#
    )

    public init() {}

    public static func normalizeTitle(_ value: String) -> String {
        normalizeBaseTitle(SongVersionIdentity.strippingVersionMarkers(from: value))
    }

    public static func normalizeArtist(_ value: String) -> String {
        normalize(value)
    }

    public static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = normalizeTitle(lhs)
        let b = normalizeTitle(rhs)
        return similarityNormalized(a, b)
    }

    static func similarityNormalized(_ lhs: String, _ rhs: String) -> Double {
        similarityNormalized(
            lhs,
            rhs,
            lhsCharacters: Array(lhs),
            rhsCharacters: Array(rhs)
        )
    }

    static func similarityNormalized(
        _ lhs: String,
        _ rhs: String,
        lhsCharacters: [Character],
        rhsCharacters: [Character]
    ) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }
        if lhs.contains(rhs) || rhs.contains(lhs) {
            let short = Double(min(lhsCharacters.count, rhsCharacters.count))
            let long = Double(max(lhsCharacters.count, rhsCharacters.count))
            let ratio = short / long
            return ratio < 0.45 ? ratio : max(0.82, ratio)
        }
        let distance = levenshtein(lhsCharacters, rhsCharacters)
        let maxCount = max(lhsCharacters.count, rhsCharacters.count)
        guard maxCount > 0 else { return 0 }
        return max(0, 1 - Double(distance) / Double(maxCount))
    }

    static func normalizeBaseTitle(_ value: String) -> String {
        normalize(value)
    }

    private static func normalize(_ value: String) -> String {
        var result = value.precomposedStringWithCompatibilityMapping.lowercased()
        result = result.replacingOccurrences(of: "臺", with: "台")
        result = result.replacingOccurrences(of: "妳", with: "你")
        result = result.replacingOccurrences(of: "愛", with: "爱")
        result = result.replacingOccurrences(of: "給", with: "给")
        result = result.replacingOccurrences(of: "聽", with: "听")
        result = result.replacingOccurrences(of: "氣", with: "气")
        result = regexReplace(punctuationAndWhitespaceRegex, in: result, with: "")
        return result
    }

    private static func regexReplace(
        _ regex: NSRegularExpression,
        in value: String,
        with replacement: String
    ) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: replacement)
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            previous = current
        }
        return previous[b.count]
    }
}

extension KTVTrack {
    func matchesTitleIdentity(_ importedTitle: String) -> Bool {
        let normalizedImportedTitle = SongNormalizer.normalizeTitle(importedTitle)
        guard !normalizedImportedTitle.isEmpty else { return false }
        return ([title] + aliases).contains {
            SongNormalizer.normalizeTitle($0) == normalizedImportedTitle
        }
    }
}
