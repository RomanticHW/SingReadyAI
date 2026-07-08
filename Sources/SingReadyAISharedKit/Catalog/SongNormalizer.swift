import Foundation

public struct SongNormalizer: Sendable {
    public init() {}

    public static func normalizeTitle(_ value: String) -> String {
        normalize(value, removeVersionWords: true)
    }

    public static func normalizeArtist(_ value: String) -> String {
        normalize(value, removeVersionWords: false)
    }

    public static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = normalizeTitle(lhs)
        let b = normalizeTitle(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        if a.contains(b) || b.contains(a) {
            let short = Double(min(a.count, b.count))
            let long = Double(max(a.count, b.count))
            let ratio = short / long
            return ratio < 0.45 ? ratio : max(0.82, ratio)
        }
        let distance = levenshtein(Array(a), Array(b))
        let maxCount = max(a.count, b.count)
        guard maxCount > 0 else { return 0 }
        return max(0, 1 - Double(distance) / Double(maxCount))
    }

    private static func normalize(_ value: String, removeVersionWords: Bool) -> String {
        var result = value.precomposedStringWithCompatibilityMapping.lowercased()
        result = result.replacingOccurrences(of: "臺", with: "台")
        result = result.replacingOccurrences(of: "妳", with: "你")
        result = result.replacingOccurrences(of: "愛", with: "爱")
        result = result.replacingOccurrences(of: "給", with: "给")
        result = result.replacingOccurrences(of: "聽", with: "听")
        result = result.replacingOccurrences(of: "氣", with: "气")
        if removeVersionWords {
            result = regexReplace(#"\(.*?(live|伴奏|翻唱|cover|现场|版|remix|剪辑).*?\)"#, in: result, with: "")
            result = regexReplace(#"（.*?(live|伴奏|翻唱|cover|现场|版|remix|剪辑).*?）"#, in: result, with: "")
        }
        result = regexReplace(#"[\p{P}\p{S}\s]+"#, in: result, with: "")
        return result
    }

    private static func regexReplace(_ pattern: String, in value: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return value
        }
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
