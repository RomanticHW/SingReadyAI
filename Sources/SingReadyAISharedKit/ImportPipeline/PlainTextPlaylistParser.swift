import Foundation

public struct PlainTextPlaylistParser: Sendable {
    public init() {}

    public func parse(rawText: String, source: ImportSource = .plainText, title: String = "粘贴导入歌单") -> ImportedPlaylist {
        let songs = parseSongs(rawText, source: source)
        let confidence = songs.isEmpty ? 0.1 : songs.map(\.confidence).reduce(0, +) / Double(songs.count)
        return ImportedPlaylist(
            source: source,
            title: title,
            songs: songs,
            parseConfidence: confidence
        )
    }

    public func parseSongs(_ rawText: String, source: ImportSource = .plainText) -> [ImportedSong] {
        var seen = Set<String>()
        return rawText
            .components(separatedBy: .newlines)
            .compactMap { parseLine($0, source: source) }
            .filter { song in
                let key = "\(song.normalizedTitle)#\(song.normalizedArtist ?? "")"
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
    }

    public func parseLine(_ rawLine: String, source: ImportSource = .plainText) -> ImportedSong? {
        let line = cleanedLine(rawLine)
        guard isPotentialSongLine(line) else { return nil }

        if let labeled = parseLabeled(line, rawLine: rawLine, source: source) {
            return labeled
        }
        if let sharedSingle = parseSharedSingle(line, rawLine: rawLine, source: source) {
            return sharedSingle
        }
        if let bracketed = parseBracketed(line, rawLine: rawLine, source: source) {
            return bracketed
        }
        if let delimited = parseDelimited(line, rawLine: rawLine, source: source) {
            return delimited
        }
        if let spaced = parseSpacedArtist(line, rawLine: rawLine, source: source) {
            return spaced
        }

        let title = cleanPart(line)
        guard title.count >= 2 else { return nil }
        return ImportedSong(
            title: title,
            artist: nil,
            source: source,
            rawText: rawLine,
            confidence: 0.5,
            versionTags: versionTags(in: rawLine)
        )
    }

    private func parseLabeled(_ line: String, rawLine: String, source: ImportSource) -> ImportedSong? {
        let patterns = [
            #"歌名[:：]\s*(.*?)\s*歌手[:：]\s*(.+)$"#,
            #"歌曲[:：]\s*(.*?)\s*歌手[:：]\s*(.+)$"#,
            #"title[:：]\s*(.*?)\s*artist[:：]\s*(.+)$"#
        ]
        for pattern in patterns {
            guard let match = firstMatch(pattern: pattern, in: line), match.count >= 3 else { continue }
            return ImportedSong(
                title: cleanPart(match[1]),
                artist: cleanPart(match[2]),
                source: source,
                rawText: rawLine,
                confidence: 0.95,
                versionTags: versionTags(in: rawLine)
            )
        }
        return nil
    }

    private func parseSharedSingle(_ line: String, rawLine: String, source: ImportSource) -> ImportedSong? {
        let patterns = [
            #"分享\s*(.+?)\s*的单曲\s*(.+)$"#,
            #"(.+?)\s*分享的歌曲\s*(.+)$"#
        ]
        for pattern in patterns {
            guard let match = firstMatch(pattern: pattern, in: line), match.count >= 3 else { continue }
            return ImportedSong(
                title: cleanPart(match[2]),
                artist: cleanPart(match[1]),
                source: source,
                rawText: rawLine,
                confidence: 0.82,
                versionTags: versionTags(in: rawLine)
            )
        }
        return nil
    }

    private func parseBracketed(_ line: String, rawLine: String, source: ImportSource) -> ImportedSong? {
        let patterns = [
            #"^(.+?)《(.+?)》"#,
            #"^(.+?)<(.+?)>"#
        ]
        for pattern in patterns {
            guard let match = firstMatch(pattern: pattern, in: line), match.count >= 3 else { continue }
            return ImportedSong(
                title: cleanPart(match[2]),
                artist: cleanPart(match[1]),
                source: source,
                rawText: rawLine,
                confidence: 0.9,
                versionTags: versionTags(in: rawLine)
            )
        }
        return nil
    }

    private func parseDelimited(_ line: String, rawLine: String, source: ImportSource) -> ImportedSong? {
        let delimiters = [" - ", "-", " / ", "/", "｜", "|", "—", "–"]
        for delimiter in delimiters where line.contains(delimiter) {
            let parts = line.components(separatedBy: delimiter)
                .map(cleanPart)
                .filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }

            let left = parts[0]
            let right = parts[1]
            let parsed = inferTitleArtist(left: left, right: right, delimiter: delimiter)
            return ImportedSong(
                title: parsed.title,
                artist: parsed.artist,
                source: source,
                rawText: rawLine,
                confidence: parsed.confidence,
                versionTags: versionTags(in: rawLine)
            )
        }
        return nil
    }

    private func parseSpacedArtist(_ line: String, rawLine: String, source: ImportSource) -> ImportedSong? {
        let parts = line
            .split(separator: " ")
            .map { cleanPart(String($0)) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }

        if let last = parts.last, commonArtists.contains(SongNormalizer.normalizeArtist(last)) {
            let title = parts.dropLast().joined(separator: " ")
            return ImportedSong(
                title: title,
                artist: last,
                source: source,
                rawText: rawLine,
                confidence: 0.78,
                versionTags: versionTags(in: rawLine)
            )
        }

        if let first = parts.first, commonArtists.contains(SongNormalizer.normalizeArtist(first)) {
            let title = parts.dropFirst().joined(separator: " ")
            return ImportedSong(
                title: title,
                artist: first,
                source: source,
                rawText: rawLine,
                confidence: 0.78,
                versionTags: versionTags(in: rawLine)
            )
        }
        return nil
    }

    private func inferTitleArtist(left: String, right: String, delimiter: String) -> (title: String, artist: String?, confidence: Double) {
        let knownLeftArtist = commonArtists.contains(SongNormalizer.normalizeArtist(left))
        let knownRightArtist = commonArtists.contains(SongNormalizer.normalizeArtist(right))
        if knownLeftArtist && !knownRightArtist {
            return (right, left, 0.88)
        }
        if knownRightArtist && !knownLeftArtist {
            return (left, right, 0.88)
        }
        if delimiter.contains("/") || delimiter.contains("｜") || delimiter == "|" {
            return (right, left, 0.78)
        }
        return (left, right, 0.74)
    }

    private func cleanedLine(_ rawLine: String) -> String {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        line = replace(pattern: #"^\s*[\d０-９]+[\.\)、\)]\s*"#, in: line, with: "")
        line = replace(pattern: #"^\s*[\d０-９]{1,3}\s+"#, in: line, with: "")
        line = replace(pattern: #"^[#\-\*\u{2022}\s]+"#, in: line, with: "")
        line = replace(pattern: #"\s+"#, in: line, with: " ")
        line = stripEmoji(line)
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanPart(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        result = replace(pattern: #"\((live|Live|LIVE|伴奏|翻唱|cover|Cover|现场|版|remix|Remix|剪辑).*?\)"#, in: result, with: "")
        result = replace(pattern: #"（(Live|live|LIVE|伴奏|翻唱|cover|Cover|现场|版|remix|Remix|剪辑).*?）"#, in: result, with: "")
        result = replace(pattern: #"\s+"#, in: result, with: " ")
        return result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private func isPotentialSongLine(_ line: String) -> Bool {
        guard line.count >= 2, line.count <= 80 else { return false }
        let lower = line.lowercased()
        let noiseKeywords = [
            "http://", "https://", "打开app", "打开 app", "分享自", "复制链接",
            "查看完整歌单", "播放全部", "评论", "收藏", "download", "登录",
            "下载", "vip", "会员", "来自网易云音乐的歌单", "网易云音乐的歌单",
            "qq音乐歌单", "qq 音乐歌单", "歌单：", "歌单:"
        ]
        if noiseKeywords.contains(where: { lower.contains($0) }) {
            return false
        }
        return line.rangeOfCharacter(from: .letters) != nil || line.rangeOfCharacter(from: CharacterSet(charactersIn: "\u{4e00}"..."\u{9fff}")) != nil
    }

    private func versionTags(in value: String) -> [String] {
        let lower = value.lowercased()
        let candidates = [
            ("live", "Live"),
            ("现场", "现场"),
            ("伴奏", "伴奏"),
            ("翻唱", "翻唱"),
            ("cover", "Cover"),
            ("dj", "DJ"),
            ("remix", "Remix"),
            ("剪辑", "剪辑")
        ]
        return candidates.compactMap { needle, tag in
            lower.contains(needle) ? tag : nil
        }
    }

    private func firstMatch(pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range) else {
            return nil
        }
        return (0..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
    }

    private func replace(pattern: String, in value: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: replacement)
    }

    private func stripEmoji(_ value: String) -> String {
        String(value.unicodeScalars.filter { scalar in
            !scalar.properties.isEmojiPresentation && scalar.value != 0xFE0F
        })
    }

    private var commonArtists: Set<String> {
        [
            "周杰伦", "陈奕迅", "孙燕姿", "五月天", "林俊杰", "邓紫棋", "王菲", "张学友",
            "刘德华", "李荣浩", "毛不易", "蔡依林", "张惠妹", "梁静茹", "张韶涵", "许嵩",
            "薛之谦", "陶喆", "王力宏", "田馥甄", "Beyond", "光良", "莫文蔚", "汪苏泷",
            "刘若英", "李克勤", "张碧晨", "胡夏", "朴树", "赵雷", "王心凌", "袁娅维",
            "买辣椒也用券", "张国荣", "任贤齐", "周华健", "苏打绿", "凤凰传奇"
        ].map(SongNormalizer.normalizeArtist).reduce(into: Set<String>()) { $0.insert($1) }
    }
}
