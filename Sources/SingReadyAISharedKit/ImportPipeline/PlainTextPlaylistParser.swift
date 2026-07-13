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
                let key = deduplicationKey(for: song)
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
    }

    public func parseLine(_ rawLine: String, source: ImportSource = .plainText) -> ImportedSong? {
        let line = cleanedLine(rawLine)
        guard isPotentialSongLine(line) else { return nil }

        if let labeled = parseLabeled(line, rawLine: rawLine, source: source) {
            return validatedSong(labeled)
        }
        if let sharedSingle = parseSharedSingle(line, rawLine: rawLine, source: source) {
            return validatedSong(sharedSingle)
        }
        if let bracketed = parseBracketed(line, rawLine: rawLine, source: source) {
            return validatedSong(bracketed)
        }
        if let delimited = parseDelimited(line, rawLine: rawLine, source: source) {
            return validatedSong(delimited)
        }
        if let spaced = parseSpacedArtist(line, rawLine: rawLine, source: source) {
            return validatedSong(spaced)
        }

        let song = importedSong(
            rawTitle: line,
            rawArtist: nil,
            source: source,
            rawLine: rawLine,
            confidence: 0.5
        )
        return song.title.count >= 2 ? song : nil
    }

    private func validatedSong(_ song: ImportedSong) -> ImportedSong? {
        song.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : song
    }

    private func deduplicationKey(for song: ImportedSong) -> String {
        let identity = SongVersionIdentity.parse(
            title: song.title,
            versionTags: song.versionTags
        )
        let kinds = identity.kinds.map(\.rawValue).sorted().joined(separator: ",")
        let unknownFingerprint = SongVersionIdentity.deduplicationUnknownFingerprint(
            title: song.title,
            versionTags: song.versionTags
        )
        return [
            identity.normalizedBaseTitle,
            song.normalizedArtist ?? "",
            identity.hasExplicitMarker ? "versioned" : "original",
            kinds,
            unknownFingerprint
        ].joined(separator: "#")
    }

    private func parseLabeled(_ line: String, rawLine: String, source: ImportSource) -> ImportedSong? {
        let patterns = [
            #"歌名[:：]\s*(.*?)\s*歌手[:：]\s*(.+)$"#,
            #"歌曲[:：]\s*(.*?)\s*歌手[:：]\s*(.+)$"#,
            #"title[:：]\s*(.*?)\s*artist[:：]\s*(.+)$"#
        ]
        for pattern in patterns {
            guard let match = firstMatch(pattern: pattern, in: line), match.count >= 3 else { continue }
            return importedSong(
                rawTitle: match[1],
                rawArtist: match[2],
                source: source,
                rawLine: rawLine,
                confidence: 0.95
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
            return importedSong(
                rawTitle: match[2],
                rawArtist: match[1],
                source: source,
                rawLine: rawLine,
                confidence: 0.82
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
            return importedSong(
                rawTitle: match[2],
                rawArtist: match[1],
                source: source,
                rawLine: rawLine,
                confidence: 0.9
            )
        }
        return nil
    }

    private func parseDelimited(_ line: String, rawLine: String, source: ImportSource) -> ImportedSong? {
        let delimiters = [" - ", " / ", "｜", "|", "—", "–", "/", "-"]
        for delimiter in delimiters where line.contains(delimiter) {
            let parts = line.components(separatedBy: delimiter)
                .map(normalizedPart)
                .filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }

            let left = parts[0]
            let right = parts[1]
            let parsed = inferTitleArtist(left: left, right: right, delimiter: delimiter)
            return importedSong(
                rawTitle: parsed.title,
                rawArtist: parsed.artist,
                source: source,
                rawLine: rawLine,
                confidence: parsed.confidence
            )
        }
        return nil
    }

    private func parseSpacedArtist(_ line: String, rawLine: String, source: ImportSource) -> ImportedSong? {
        let parts = line
            .split(separator: " ")
            .map { normalizedPart(String($0)) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }

        if let last = parts.last,
           commonArtists.contains(SongNormalizer.normalizeArtist(cleanPart(last))) {
            let title = parts.dropLast().joined(separator: " ")
            return importedSong(
                rawTitle: title,
                rawArtist: last,
                source: source,
                rawLine: rawLine,
                confidence: 0.78
            )
        }

        if let first = parts.first,
           commonArtists.contains(SongNormalizer.normalizeArtist(cleanPart(first))) {
            let title = parts.dropFirst().joined(separator: " ")
            return importedSong(
                rawTitle: title,
                rawArtist: first,
                source: source,
                rawLine: rawLine,
                confidence: 0.78
            )
        }
        return nil
    }

    private func inferTitleArtist(left: String, right: String, delimiter: String) -> (title: String, artist: String?, confidence: Double) {
        let knownLeftArtist = commonArtists.contains(SongNormalizer.normalizeArtist(cleanPart(left)))
        let knownRightArtist = commonArtists.contains(SongNormalizer.normalizeArtist(cleanPart(right)))
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
        normalizedPart(value).trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        )
    }

    private func normalizedPart(_ value: String) -> String {
        let result = replace(pattern: #"\s+"#, in: value, with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func importedSong(
        rawTitle: String,
        rawArtist: String?,
        source: ImportSource,
        rawLine: String,
        confidence: Double
    ) -> ImportedSong {
        let extraction = SongVersionIdentity.extractTitleAndVersionTags(from: rawTitle)
        return ImportedSong(
            title: cleanPart(extraction.baseTitle),
            artist: rawArtist.map(cleanPart),
            source: source,
            rawText: rawLine,
            confidence: confidence,
            versionTags: extraction.versionTags
        )
    }

    private func isPotentialSongLine(_ line: String) -> Bool {
        guard line.count >= 2, line.count <= 200 else { return false }
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
            "买辣椒也用券", "张国荣", "任贤齐", "周华健", "苏打绿", "凤凰传奇",
            "A-Lin", "S.H.E"
        ].map(SongNormalizer.normalizeArtist).reduce(into: Set<String>()) { $0.insert($1) }
    }
}
