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
            lhsUnits: matchUnits(lhs),
            rhsUnits: matchUnits(rhs)
        )
    }

    static func similarityNormalized(
        _ lhs: String,
        _ rhs: String,
        lhsUnits: [UInt32],
        rhsUnits: [UInt32]
    ) -> Double {
        var workspace = SongSimilarityWorkspace()
        return similarityNormalized(
            lhs,
            rhs,
            lhsUnits: lhsUnits,
            rhsUnits: rhsUnits,
            workspace: &workspace
        )
    }

    static func similarityNormalized(
        _ lhs: String,
        _ rhs: String,
        lhsUnits: [UInt32],
        rhsUnits: [UInt32],
        workspace: inout SongSimilarityWorkspace
    ) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }
        if lhs.contains(rhs) || rhs.contains(lhs) {
            let short = Double(min(lhsUnits.count, rhsUnits.count))
            let long = Double(max(lhsUnits.count, rhsUnits.count))
            let ratio = short / long
            return ratio < 0.45 ? ratio : max(0.82, ratio)
        }
        let distance = workspace.levenshtein(lhsUnits, rhsUnits)
        let maxCount = max(lhsUnits.count, rhsUnits.count)
        guard maxCount > 0 else { return 0 }
        return max(0, 1 - Double(distance) / Double(maxCount))
    }

    static func matchUnits(_ normalizedValue: String) -> [UInt32] {
        normalizedValue.unicodeScalars.map(\.value)
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

}

struct SongSimilarityWorkspace: Sendable {
    private var previous: [Int] = []
    private var current: [Int] = []

    mutating func levenshtein(_ a: [UInt32], _ b: [UInt32]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var startIndex = 0
        let sharedLimit = min(a.count, b.count)
        while startIndex < sharedLimit, a[startIndex] == b[startIndex] {
            startIndex += 1
        }

        var aEndIndex = a.count
        var bEndIndex = b.count
        while aEndIndex > startIndex,
              bEndIndex > startIndex,
              a[aEndIndex - 1] == b[bEndIndex - 1] {
            aEndIndex -= 1
            bEndIndex -= 1
        }

        let aCount = aEndIndex - startIndex
        let bCount = bEndIndex - startIndex
        if aCount == 0 { return bCount }
        if bCount == 0 { return aCount }

        let requiredCount = bCount + 1
        if previous.count < requiredCount {
            previous = Array(repeating: 0, count: requiredCount)
            current = Array(repeating: 0, count: requiredCount)
        }
        var index = 0
        while index <= bCount {
            previous[index] = index
            index += 1
        }
        var i = 1
        while i <= aCount {
            current[0] = i
            var j = 1
            while j <= bCount {
                let cost = a[startIndex + i - 1] == b[startIndex + j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
                j += 1
            }
            swap(&previous, &current)
            i += 1
        }
        return previous[bCount]
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
