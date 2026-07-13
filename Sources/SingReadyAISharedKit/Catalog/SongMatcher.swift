import Foundation

public struct SongMatcher: Sendable {
    public init() {}

    public func match(playlist: ImportedPlaylist, catalog: [KTVTrack]) -> [MatchResult] {
        var session = CatalogMatchSession(catalog: catalog)
        var results: [MatchResult] = []
        results.reserveCapacity(playlist.songs.count)
        for song in playlist.songs {
            results.append(session.match(song: song, cancellationCheck: {}))
        }
        return results
    }

    public func matchCancellable(
        playlist: ImportedPlaylist,
        catalog: [KTVTrack]
    ) throws -> [MatchResult] {
        try Task.checkCancellation()
        var session = CatalogMatchSession(catalog: catalog)
        try Task.checkCancellation()
        var results: [MatchResult] = []
        results.reserveCapacity(playlist.songs.count)
        for song in playlist.songs {
            try Task.checkCancellation()
            results.append(
                try session.match(
                    song: song,
                    cancellationCheck: { try Task.checkCancellation() }
                )
            )
        }
        try Task.checkCancellation()
        return results
    }

    public func match(song: ImportedSong, catalog: [KTVTrack]) -> MatchResult {
        var session = CatalogMatchSession(catalog: catalog)
        return session.match(song: song, cancellationCheck: {})
    }
}

public struct PlaylistAnalysisOutput: Sendable {
    public let matches: [MatchResult]
    public let preferenceProfile: PreferenceProfile

    public init(matches: [MatchResult], preferenceProfile: PreferenceProfile) {
        self.matches = matches
        self.preferenceProfile = preferenceProfile
    }
}

public actor PlaylistAnalysisExecutor {
    private let matcher: SongMatcher
    private let profiler: PreferenceProfiler
    private let beforeAnalysis: @Sendable () -> Void

    public init(
        matcher: SongMatcher = SongMatcher(),
        profiler: PreferenceProfiler = PreferenceProfiler()
    ) {
        self.matcher = matcher
        self.profiler = profiler
        beforeAnalysis = {}
    }

    init(beforeAnalysis: @escaping @Sendable () -> Void) {
        matcher = SongMatcher()
        profiler = PreferenceProfiler()
        self.beforeAnalysis = beforeAnalysis
    }

    public func analyze(
        playlist: ImportedPlaylist,
        catalog: [KTVTrack]
    ) throws -> PlaylistAnalysisOutput {
        try Task.checkCancellation()
        beforeAnalysis()
        try Task.checkCancellation()
        let matches = try matcher.matchCancellable(
            playlist: playlist,
            catalog: catalog
        )
        try Task.checkCancellation()
        let preferenceProfile = profiler.buildProfile(
            importedPlaylist: playlist,
            matches: matches
        )
        try Task.checkCancellation()
        return PlaylistAnalysisOutput(
            matches: matches,
            preferenceProfile: preferenceProfile
        )
    }
}

private struct CatalogMatchSession {
    private let index: CatalogMatchIndex
    private var smartAlternativeCache: [String: [KTVTrack]] = [:]

    init(catalog: [KTVTrack]) {
        index = CatalogMatchIndex(catalog: catalog)
    }

    mutating func match(
        song: ImportedSong,
        cancellationCheck: () throws -> Void
    ) rethrows -> MatchResult {
        let query = SongMatchQuery(song: song)

        if query.normalizedArtist == nil,
           let candidateIndices = index.titleCandidateIndices[query.normalizedTitle.value],
           !candidateIndices.isEmpty {
            let titleCandidates = candidateIndices.map { index.entries[$0].track }
            return MatchResult(
                importedSong: song,
                matchedTrack: nil,
                alternatives: titleCandidates,
                status: .fuzzy,
                confirmationState: .required,
                score: 1,
                reason: titleCandidates.count == 1
                    ? "歌名相同但缺少歌手，请确认这个候选"
                    : "找到多首同名歌曲，请确认歌手"
            )
        }

        if let exactEntry = quickExactMatch(query: query) {
            return MatchResult(
                importedSong: song,
                matchedTrack: exactEntry.track,
                alternatives: try smartAlternatives(
                    for: exactEntry,
                    cancellationCheck: cancellationCheck
                ),
                status: .exact,
                score: 1,
                reason: reason(query: query, entry: exactEntry)
            )
        }

        var topCandidates: [RankedCandidate] = []
        topCandidates.reserveCapacity(4)
        for entry in index.entries {
            if entry.catalogOrder.isMultiple(of: 32) {
                try cancellationCheck()
            }
            insertTopCandidate(
                RankedCandidate(
                    entryIndex: entry.catalogOrder,
                    score: score(query: query, entry: entry)
                ),
                into: &topCandidates,
                limit: 4
            )
        }

        guard let bestCandidate = topCandidates.first else {
            return MatchResult(
                importedSong: song,
                matchedTrack: nil,
                alternatives: [],
                status: .unmatched,
                score: 0,
                reason: "本地参考曲库为空"
            )
        }

        let bestEntry = index.entries[bestCandidate.entryIndex]
        let status: MatchStatus
        let matchedTrack: KTVTrack?
        if bestCandidate.score >= 0.95 {
            status = .exact
            matchedTrack = bestEntry.track
        } else if bestCandidate.score >= 0.78 {
            status = .fuzzy
            matchedTrack = bestEntry.track
        } else if bestCandidate.score >= 0.60 {
            status = .alternative
            matchedTrack = nil
        } else {
            status = .unmatched
            matchedTrack = nil
        }

        var alternatives: [KTVTrack] = []
        alternatives.reserveCapacity(3)
        for candidate in topCandidates {
            let track = index.entries[candidate.entryIndex].track
            guard track.id != matchedTrack?.id else { continue }
            alternatives.append(track)
            if alternatives.count == 3 { break }
        }

        return MatchResult(
            importedSong: song,
            matchedTrack: matchedTrack,
            alternatives: alternatives,
            status: status,
            score: bestCandidate.score,
            reason: status == .unmatched
                ? "本地参考曲库中未找到足够接近的歌曲"
                : reason(query: query, entry: bestEntry)
        )
    }

    private func quickExactMatch(query: SongMatchQuery) -> CatalogMatchEntry? {
        guard let candidateIndices = index.titleCandidateIndices[query.normalizedTitle.value] else {
            return nil
        }
        return candidateIndices.lazy
            .map { index.entries[$0] }
            .first { artistMatches(query.normalizedArtist, entry: $0) }
    }

    private func artistMatches(
        _ artist: NormalizedMatchText?,
        entry: CatalogMatchEntry
    ) -> Bool {
        guard let artist else { return true }
        if entry.artistAliasValues.contains(artist.value) { return true }
        return entry.normalizedArtistAliases.contains {
            artist.value.contains($0.value) || $0.value.contains(artist.value)
        }
    }

    private mutating func smartAlternatives(
        for source: CatalogMatchEntry,
        cancellationCheck: () throws -> Void
    ) rethrows -> [KTVTrack] {
        if let cached = smartAlternativeCache[source.track.id] {
            return cached
        }

        let similarEntries = index.entries.filter {
            source.similarSongIDs.contains($0.track.id)
        }
        if similarEntries.count >= 3 {
            let result = Array(similarEntries.prefix(3).map(\.track))
            smartAlternativeCache[source.track.id] = result
            return result
        }

        let similarIDs = Set(similarEntries.map { $0.track.id })
        let remainingCount = 3 - similarEntries.count
        var relatedCandidates: [RelatedCandidate] = []
        relatedCandidates.reserveCapacity(remainingCount)
        for entry in index.entries {
            if entry.catalogOrder.isMultiple(of: 32) {
                try cancellationCheck()
            }
            guard entry.track.id != source.track.id,
                  !similarIDs.contains(entry.track.id),
                  entry.track.artist == source.track.artist
                    || entry.track.genre == source.track.genre
                    || !entry.sceneTags.isDisjoint(with: source.sceneTags) else {
                continue
            }
            insertRelatedCandidate(
                RelatedCandidate(
                    entryIndex: entry.catalogOrder,
                    hasSameArtist: entry.track.artist == source.track.artist,
                    hasSameGenre: entry.track.genre == source.track.genre,
                    singAlongScore: entry.track.singAlongScore
                ),
                into: &relatedCandidates,
                limit: remainingCount
            )
        }

        let result = Array(similarEntries.map(\.track))
            + relatedCandidates.map { index.entries[$0.entryIndex].track }
        smartAlternativeCache[source.track.id] = result
        return result
    }

    private func score(query: SongMatchQuery, entry: CatalogMatchEntry) -> Double {
        let titleScore = entry.normalizedTitleIdentities.map {
            similarity(query.normalizedTitle, $0)
        }.max() ?? 0

        let artistScore: Double
        if let importedArtist = query.normalizedArtist {
            if entry.artistAliasValues.contains(importedArtist.value) {
                artistScore = 1
            } else if entry.normalizedArtistAliases.contains(where: {
                importedArtist.value.contains($0.value) || $0.value.contains(importedArtist.value)
            }) {
                artistScore = 0.86
            } else {
                artistScore = entry.normalizedArtistAliases.map {
                    similarity(importedArtist, $0)
                }.max() ?? 0
            }
        } else {
            artistScore = titleScore >= 0.95 ? 0.9 : 0.55
        }
        return min(1, titleScore * 0.75 + artistScore * 0.25)
    }

    private func reason(query: SongMatchQuery, entry: CatalogMatchEntry) -> String {
        if query.normalizedTitle.value == entry.normalizedPrimaryTitle.value,
           let importedArtist = query.normalizedArtist,
           entry.artistAliasValues.contains(importedArtist.value) {
            return "歌名和歌手在本地参考曲库中命中"
        }
        if query.normalizedTitle.value == entry.normalizedPrimaryTitle.value {
            return "歌名对上了，歌手可能少写了"
        }
        if entry.normalizedAliases.contains(where: {
            $0.value == query.normalizedTitle.value
        }) {
            return "常见别名也能找到这首"
        }
        if let importedArtist = query.normalizedArtist,
           entry.artistAliasValues.contains(importedArtist.value) {
            return "同歌手的相近版本，可作为本地参考候选"
        }
        if entry.track.ktvAvailability >= 0.9,
           entry.track.singAlongScore >= 0.8 {
            return "在常见 K 歌参考中较常见，也适合大家一起接"
        }
        return "歌名和歌手相似，可以先放进备选"
    }

    private func similarity(
        _ lhs: NormalizedMatchText,
        _ rhs: NormalizedMatchText
    ) -> Double {
        SongNormalizer.similarityNormalized(
            lhs.value,
            rhs.value,
            lhsCharacters: lhs.characters,
            rhsCharacters: rhs.characters
        )
    }
}

private struct CatalogMatchIndex {
    let entries: [CatalogMatchEntry]
    let titleCandidateIndices: [String: [Int]]

    init(catalog: [KTVTrack]) {
        entries = catalog.enumerated().map { offset, track in
            CatalogMatchEntry(track: track, catalogOrder: offset)
        }
        var titleCandidateIndices: [String: [Int]] = [:]
        for entry in entries {
            for identity in entry.titleIdentityValues where !identity.isEmpty {
                titleCandidateIndices[identity, default: []].append(entry.catalogOrder)
            }
        }
        self.titleCandidateIndices = titleCandidateIndices
    }
}

private struct CatalogMatchEntry {
    let track: KTVTrack
    let catalogOrder: Int
    let normalizedPrimaryTitle: NormalizedMatchText
    let normalizedAliases: [NormalizedMatchText]
    let normalizedTitleIdentities: [NormalizedMatchText]
    let titleIdentityValues: Set<String>
    let normalizedArtistAliases: [NormalizedMatchText]
    let artistAliasValues: Set<String>
    let sceneTags: Set<String>
    let similarSongIDs: Set<String>

    init(track: KTVTrack, catalogOrder: Int) {
        self.track = track
        self.catalogOrder = catalogOrder
        normalizedPrimaryTitle = .title(track.title)
        normalizedAliases = track.aliases.map(NormalizedMatchText.title)
        var titleIdentities: [NormalizedMatchText] = []
        var seenTitleIdentities = Set<String>()
        for value in [normalizedPrimaryTitle] + normalizedAliases
        where seenTitleIdentities.insert(value.value).inserted {
            titleIdentities.append(value)
        }
        normalizedTitleIdentities = titleIdentities
        titleIdentityValues = seenTitleIdentities
        normalizedArtistAliases = normalizedArtistAliasesForTrack(track.artist)
            .map(NormalizedMatchText.normalized)
        artistAliasValues = Set(normalizedArtistAliases.map(\.value))
        sceneTags = Set(track.sceneTags)
        similarSongIDs = Set(track.similarSongIds)
    }
}

private struct SongMatchQuery {
    let song: ImportedSong
    let normalizedTitle: NormalizedMatchText
    let normalizedArtist: NormalizedMatchText?

    init(song: ImportedSong) {
        self.song = song
        normalizedTitle = .title(song.title)
        if let artist = song.artist?.nilIfBlank {
            normalizedArtist = .artist(artist)
        } else {
            normalizedArtist = nil
        }
    }
}

private struct NormalizedMatchText: Sendable {
    let value: String
    let characters: [Character]

    static func title(_ rawValue: String) -> NormalizedMatchText {
        normalized(SongNormalizer.normalizeTitle(rawValue))
    }

    static func artist(_ rawValue: String) -> NormalizedMatchText {
        normalized(SongNormalizer.normalizeArtist(rawValue))
    }

    static func normalized(_ value: String) -> NormalizedMatchText {
        NormalizedMatchText(value: value, characters: Array(value))
    }
}

private struct RankedCandidate {
    let entryIndex: Int
    let score: Double
}

private func insertTopCandidate(
    _ candidate: RankedCandidate,
    into candidates: inout [RankedCandidate],
    limit: Int
) {
    guard limit > 0 else { return }
    let insertionIndex = candidates.firstIndex {
        candidate.score > $0.score
    } ?? candidates.endIndex
    guard insertionIndex < limit || candidates.count < limit else { return }
    candidates.insert(candidate, at: insertionIndex)
    if candidates.count > limit {
        candidates.removeLast()
    }
}

private struct RelatedCandidate {
    let entryIndex: Int
    let hasSameArtist: Bool
    let hasSameGenre: Bool
    let singAlongScore: Double
}

private func insertRelatedCandidate(
    _ candidate: RelatedCandidate,
    into candidates: inout [RelatedCandidate],
    limit: Int
) {
    guard limit > 0 else { return }
    let insertionIndex = candidates.firstIndex {
        relatedCandidate(candidate, ranksBefore: $0)
    } ?? candidates.endIndex
    guard insertionIndex < limit || candidates.count < limit else { return }
    candidates.insert(candidate, at: insertionIndex)
    if candidates.count > limit {
        candidates.removeLast()
    }
}

private func relatedCandidate(
    _ lhs: RelatedCandidate,
    ranksBefore rhs: RelatedCandidate
) -> Bool {
    if lhs.hasSameArtist != rhs.hasSameArtist {
        return lhs.hasSameArtist
    }
    if lhs.hasSameGenre != rhs.hasSameGenre {
        return lhs.hasSameGenre
    }
    if lhs.singAlongScore != rhs.singAlongScore {
        return lhs.singAlongScore > rhs.singAlongScore
    }
    return lhs.entryIndex < rhs.entryIndex
}

private let artistAliasCandidates: [String: [String]] = [
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

private func normalizedArtistAliasesForTrack(_ artist: String) -> [String] {
    let normalizedArtist = SongNormalizer.normalizeArtist(artist)
    var aliases = Set([normalizedArtist])
    for candidate in artistAliasCandidates[normalizedArtist] ?? [] {
        aliases.insert(SongNormalizer.normalizeArtist(candidate))
    }
    return aliases.sorted()
}

extension KTVTrack {
    func matchesArtistIdentity(_ importedArtist: String) -> Bool {
        let normalizedImportedArtist = SongNormalizer.normalizeArtist(importedArtist)
        guard !normalizedImportedArtist.isEmpty else { return false }
        let normalizedAliases = normalizedArtistAliasesForTrack(artist)
        return normalizedAliases.contains(normalizedImportedArtist)
            || normalizedAliases.contains {
                normalizedImportedArtist.contains($0) || $0.contains(normalizedImportedArtist)
            }
    }
}
