import Foundation

public struct SongMatcher: Sendable {
    public init() {}

    public func match(playlist: ImportedPlaylist, catalog: [KTVTrack]) -> [MatchResult] {
        playlist.songs.map { match(song: $0, catalog: catalog) }
    }

    public func match(song: ImportedSong, catalog: [KTVTrack]) -> MatchResult {
        if let exactTrack = quickExactMatch(song: song, catalog: catalog) {
            return MatchResult(
                importedSong: song,
                matchedTrack: exactTrack,
                alternatives: smartAlternatives(for: exactTrack, in: catalog),
                status: .exact,
                score: 1,
                reason: reason(song: song, track: exactTrack)
            )
        }

        let ranked = catalog
            .map { track in
                (track: track, score: score(song: song, track: track), reason: reason(song: song, track: track))
            }
            .sorted { $0.score > $1.score }

        guard let best = ranked.first else {
            return MatchResult(importedSong: song, matchedTrack: nil, alternatives: [], status: .unmatched, score: 0, reason: "曲库为空")
        }

        let status: MatchStatus
        let matchedTrack: KTVTrack?
        if best.score >= 0.95 {
            status = .exact
            matchedTrack = best.track
        } else if best.score >= 0.78 {
            status = .fuzzy
            matchedTrack = best.track
        } else if best.score >= 0.60 {
            status = .alternative
            matchedTrack = best.track
        } else {
            status = .unmatched
            matchedTrack = nil
        }

        let alternatives = ranked
            .filter { $0.track.id != matchedTrack?.id }
            .prefix(3)
            .map(\.track)

        return MatchResult(
            importedSong: song,
            matchedTrack: matchedTrack,
            alternatives: alternatives,
            status: status,
            score: best.score,
            reason: status == .unmatched ? "未找到足够接近的 KTV 曲库歌曲" : best.reason
        )
    }

    private func quickExactMatch(song: ImportedSong, catalog: [KTVTrack]) -> KTVTrack? {
        catalog.first { track in
            titleMatchesExactly(song: song, track: track) && artistMatches(song.artist, track: track)
        }
    }

    private func titleMatchesExactly(song: ImportedSong, track: KTVTrack) -> Bool {
        let importedTitle = song.normalizedTitle
        return ([track.title] + track.aliases).contains {
            SongNormalizer.normalizeTitle($0) == importedTitle
        }
    }

    private func artistMatches(_ artist: String?, track: KTVTrack) -> Bool {
        guard let artist = artist?.nilIfBlank else { return true }
        let imported = SongNormalizer.normalizeArtist(artist)
        let aliases = artistAliases(for: track.artist)
        return aliases.contains(imported)
            || aliases.contains { imported.contains($0) || $0.contains(imported) }
    }

    private func smartAlternatives(for track: KTVTrack, in catalog: [KTVTrack]) -> [KTVTrack] {
        let similar = catalog.filter { track.similarSongIds.contains($0.id) }
        if similar.count >= 3 { return Array(similar.prefix(3)) }
        let sceneTags = Set(track.sceneTags)
        let related = catalog
            .filter { candidate in
                let candidateSceneTags = Set(candidate.sceneTags)
                return candidate.id != track.id
                    && (track.similarSongIds.contains(candidate.id)
                        || candidate.artist == track.artist
                        || candidate.genre == track.genre
                        || !candidateSceneTags.isDisjoint(with: sceneTags))
            }
            .sorted { lhs, rhs in
                if lhs.artist == track.artist, rhs.artist != track.artist { return true }
                if lhs.genre == track.genre, rhs.genre != track.genre { return true }
                return lhs.singAlongScore > rhs.singAlongScore
            }
        return Array((similar + related).reduce(into: [KTVTrack]()) { result, candidate in
            if result.contains(where: { $0.id == candidate.id }) == false {
                result.append(candidate)
            }
        }.prefix(3))
    }

    private func score(song: ImportedSong, track: KTVTrack) -> Double {
        let titleScores = ([track.title] + track.aliases).map { SongNormalizer.similarity(song.title, $0) }
        let titleScore = titleScores.max() ?? 0
        let artistScore: Double
        if let artist = song.artist?.nilIfBlank {
            let imported = SongNormalizer.normalizeArtist(artist)
            let catalogArtists = artistAliases(for: track.artist)
            if catalogArtists.contains(imported) {
                artistScore = 1
            } else if catalogArtists.contains(where: { imported.contains($0) || $0.contains(imported) }) {
                artistScore = 0.86
            } else {
                artistScore = catalogArtists.map { SongNormalizer.similarity(imported, $0) }.max() ?? 0
            }
        } else {
            artistScore = titleScore >= 0.95 ? 0.9 : 0.55
        }
        return min(1, titleScore * 0.75 + artistScore * 0.25)
    }

    private func reason(song: ImportedSong, track: KTVTrack) -> String {
        let importedTitle = SongNormalizer.normalizeTitle(song.title)
        let trackTitle = SongNormalizer.normalizeTitle(track.title)
        let importedArtist = song.artist.map(SongNormalizer.normalizeArtist)
        let catalogArtists = artistAliases(for: track.artist)

        if importedTitle == trackTitle, let importedArtist, catalogArtists.contains(importedArtist) {
            return "精确命中：歌名和歌手都与 KTV 曲库一致"
        }
        if importedTitle == trackTitle {
            return "歌名精确命中，歌手信息缺失或接近"
        }
        if track.aliases.contains(where: { SongNormalizer.normalizeTitle($0) == SongNormalizer.normalizeTitle(song.title) }) {
            return "别名命中：分享版本名与曲库歌曲别名一致"
        }
        if let importedArtist, catalogArtists.contains(importedArtist) {
            return "同歌手匹配：歌名近似，适合作为 KTV 可唱版本"
        }
        if track.ktvAvailability >= 0.9, track.singAlongScore >= 0.8 {
            return "同风格替代：曲库可唱度和合唱分较高"
        }
        return "歌名和歌手相似度达到可推荐阈值，可作为备选"
    }

    private func artistAliases(for artist: String) -> Set<String> {
        let normalized = SongNormalizer.normalizeArtist(artist)
        var aliases: Set<String> = [normalized]
        let map: [String: [String]] = [
            "周杰伦": ["jaychou", "jay"],
            "陈奕迅": ["eason", "easonchan"],
            "邓紫棋": ["gem", "gem邓紫棋"],
            "五月天": ["mayday"],
            "张学友": ["jackycheung"],
            "刘德华": ["andylautak-wah", "andy lau"],
            "王菲": ["fayewong"],
            "田馥甄": ["hebe"],
            "林俊杰": ["jjlin"],
            "孙燕姿": ["stefaniesun"],
            "蔡依林": ["jolin", "jolintsai"],
            "梁静茹": ["fishleong"],
            "张惠妹": ["amei", "amei张惠妹"],
            "张韶涵": ["angelachang"],
            "beyond": ["beyond"]
        ]
        for candidate in map[normalized] ?? [] {
            aliases.insert(SongNormalizer.normalizeArtist(candidate))
        }
        return aliases
    }
}
