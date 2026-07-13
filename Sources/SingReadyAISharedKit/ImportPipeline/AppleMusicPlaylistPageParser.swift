import Foundation

struct AppleMusicPlaylistPageParser: Sendable {
    func playlistText(from data: Data) throws -> String? {
        guard let html = String(data: data, encoding: .utf8),
              let identifierRange = html.range(of: #"id="serialized-server-data""#),
              let openingTagEnd = html[identifierRange.upperBound...].firstIndex(of: ">") else {
            return nil
        }
        let jsonStart = html.index(after: openingTagEnd)
        guard let closingTag = html.range(of: "</script>", range: jsonStart..<html.endIndex) else {
            return nil
        }

        let jsonData = Data(html[jsonStart..<closingTag.lowerBound].utf8)
        let root = try JSONSerialization.jsonObject(with: jsonData)
        var lines = [String]()
        var seenTrackIDs = Set<String>()
        collectTrackLines(from: root, lines: &lines, seenTrackIDs: &seenTrackIDs)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func collectTrackLines(
        from value: Any,
        lines: inout [String],
        seenTrackIDs: inout Set<String>
    ) {
        if let values = value as? [Any] {
            for value in values {
                collectTrackLines(from: value, lines: &lines, seenTrackIDs: &seenTrackIDs)
            }
            return
        }
        guard let dictionary = value as? [String: Any] else { return }

        if let id = dictionary["id"] as? String,
           id.hasPrefix("track-lockup - "),
           seenTrackIDs.insert(id).inserted,
           let title = (dictionary["title"] as? String)?.nilIfBlank,
           let artist = artistName(in: dictionary) {
            lines.append("\(title) - \(artist)")
            return
        }

        for nestedValue in dictionary.values {
            collectTrackLines(from: nestedValue, lines: &lines, seenTrackIDs: &seenTrackIDs)
        }
    }

    private func artistName(in dictionary: [String: Any]) -> String? {
        if let artist = (dictionary["artistName"] as? String)?.nilIfBlank {
            return artist
        }
        guard let subtitleLinks = dictionary["subtitleLinks"] as? [[String: Any]] else {
            return nil
        }
        return subtitleLinks.lazy.compactMap { ($0["title"] as? String)?.nilIfBlank }.first
    }
}
