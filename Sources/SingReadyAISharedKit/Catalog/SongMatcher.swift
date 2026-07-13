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
        catalog: [KTVTrack],
        batchProgress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async throws -> [MatchResult] {
        try Task.checkCancellation()
        var session = CatalogMatchSession(catalog: catalog)
        try Task.checkCancellation()
        var results: [MatchResult] = []
        results.reserveCapacity(playlist.songs.count)
        for (offset, song) in playlist.songs.enumerated() {
            try Task.checkCancellation()
            results.append(
                try session.match(
                    song: song,
                    cancellationCheck: { try Task.checkCancellation() }
                )
            )
            let completedCount = offset + 1
            if completedCount.isMultiple(of: PlaylistAnalysisExecutor.progressBatchSize),
               completedCount < playlist.songs.count,
               let batchProgress {
                await batchProgress(completedCount, playlist.songs.count)
                try Task.checkCancellation()
            }
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
    static let progressBatchSize = 20

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
        catalog: [KTVTrack],
        progress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async throws -> PlaylistAnalysisOutput {
        try Task.checkCancellation()
        if let progress {
            await progress(0, playlist.songs.count)
            try Task.checkCancellation()
        }
        beforeAnalysis()
        try Task.checkCancellation()
        let matches = try await matcher.matchCancellable(
            playlist: playlist,
            catalog: catalog,
            batchProgress: progress
        )
        try Task.checkCancellation()
        let preferenceProfile = profiler.buildProfile(
            importedPlaylist: playlist,
            matches: matches
        )
        try Task.checkCancellation()
        if let progress, !playlist.songs.isEmpty {
            await progress(playlist.songs.count, playlist.songs.count)
            try Task.checkCancellation()
        }
        return PlaylistAnalysisOutput(
            matches: matches,
            preferenceProfile: preferenceProfile
        )
    }
}

enum MatchDispositionDecision: Equatable, Sendable {
    case acceptedOriginalExact
    case identityConfirmationRequired
    case alternativeSuggested
    case unmatched

    static func resolve(
        allowsAutomaticAcceptance: Bool,
        hasIdentityConflict: Bool,
        score: Double
    ) -> Self {
        if allowsAutomaticAcceptance {
            return .acceptedOriginalExact
        }
        if hasIdentityConflict || score >= 0.78 {
            return .identityConfirmationRequired
        }
        if score >= 0.60 {
            return .alternativeSuggested
        }
        return .unmatched
    }
}

struct AutomaticAcceptanceDecision {
    static func allows(
        importedSong: ImportedSong,
        candidate: KTVTrack,
        evidence: SongIdentityEvidence,
        compatibleCandidateCount: Int
    ) -> Bool {
        guard compatibleCandidateCount == 1,
              evidence.allowsAutomaticAcceptance,
              let importedArtist = importedSong.artist?.nilIfBlank,
              candidate.matchesArtistIdentity(importedArtist) else {
            return false
        }

        let importedIdentity = SongVersionIdentity.parse(
            title: importedSong.title,
            versionTags: importedSong.versionTags
        )
        let candidateIdentity: SongVersionIdentity
        switch evidence {
        case let .canonicalTitle(identity):
            candidateIdentity = identity
        case let .alias(_, identity):
            candidateIdentity = identity
        }

        return importedIdentity.normalizedBaseTitle == candidateIdentity.normalizedBaseTitle
            && importedIdentity.compatibility(with: candidateIdentity) == .compatible
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
        var similarityWorkspace = SongSimilarityWorkspace()

        let identityCandidates = try rankedIdentityCandidates(
            query: query,
            similarityWorkspace: &similarityWorkspace,
            cancellationCheck: cancellationCheck
        )
        if let bestIdentityCandidate = identityCandidates.first {
            let bestEntry = index.entries[bestIdentityCandidate.entryIndex]
            let evidence = bestEntry.identityEvidence(
                matching: query.normalizedTitle.value
            )!
            let allowsAutomaticAcceptance = AutomaticAcceptanceDecision.allows(
                importedSong: song,
                candidate: bestEntry.track,
                evidence: evidence,
                compatibleCandidateCount: identityCandidates.count
            )
            let decision = MatchDispositionDecision.resolve(
                allowsAutomaticAcceptance: allowsAutomaticAcceptance,
                hasIdentityConflict: true,
                score: bestIdentityCandidate.score
            )

            switch decision {
            case .acceptedOriginalExact:
                return MatchResult(
                    importedSong: song,
                    disposition: .acceptedOriginalExact(track: bestEntry.track),
                    suggestedAlternatives: try smartAlternatives(
                        for: bestEntry,
                        cancellationCheck: cancellationCheck
                    ),
                    score: bestIdentityCandidate.score,
                    reason: reason(query: query, entry: bestEntry)
                )
            case .identityConfirmationRequired:
                let candidates = identityCandidates.map {
                    index.entries[$0.entryIndex].track
                }
                return MatchResult(
                    importedSong: song,
                    disposition: .identityConfirmationRequired(candidates: candidates),
                    score: bestIdentityCandidate.score,
                    reason: identityConfirmationReason(
                        query: query,
                        candidates: candidates,
                        evidence: evidence
                    )
                )
            case .alternativeSuggested, .unmatched:
                preconditionFailure("同歌名身份候选必须接受或进入身份确认")
            }
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
                    score: score(
                        query: query,
                        entry: entry,
                        similarityWorkspace: &similarityWorkspace
                    )
                ),
                into: &topCandidates,
                limit: 4
            )
        }

        guard let bestCandidate = topCandidates.first else {
            return MatchResult(
                importedSong: song,
                disposition: .unmatched,
                score: 0,
                reason: "本地参考曲库为空"
            )
        }

        let bestEntry = index.entries[bestCandidate.entryIndex]
        let candidates = topCandidates.prefix(3).map {
            index.entries[$0.entryIndex].track
        }
        let decision = MatchDispositionDecision.resolve(
            allowsAutomaticAcceptance: false,
            hasIdentityConflict: false,
            score: bestCandidate.score
        )
        let disposition: SongMatchDisposition
        let matchReason: String
        switch decision {
        case .acceptedOriginalExact:
            preconditionFailure("模糊召回不得自动接受")
        case .identityConfirmationRequired:
            disposition = .identityConfirmationRequired(candidates: candidates)
            matchReason = reason(query: query, entry: bestEntry)
        case .alternativeSuggested:
            disposition = .alternativeSuggested(candidates: candidates)
            matchReason = reason(query: query, entry: bestEntry)
        case .unmatched:
            disposition = .unmatched
            matchReason = "本地参考曲库中未找到足够接近的歌曲"
        }

        return MatchResult(
            importedSong: song,
            disposition: disposition,
            score: bestCandidate.score,
            reason: matchReason
        )
    }

    private func rankedIdentityCandidates(
        query: SongMatchQuery,
        similarityWorkspace: inout SongSimilarityWorkspace,
        cancellationCheck: () throws -> Void
    ) rethrows -> [RankedCandidate] {
        guard let candidateIndices = index.titleCandidateIndices[query.normalizedTitle.value] else {
            return []
        }

        var candidates: [RankedCandidate] = []
        candidates.reserveCapacity(candidateIndices.count)
        for (offset, entryIndex) in candidateIndices.enumerated() {
            if offset.isMultiple(of: 32) {
                try cancellationCheck()
            }
            let entry = index.entries[entryIndex]
            guard entry.identityEvidence(matching: query.normalizedTitle.value) != nil else {
                continue
            }
            candidates.append(
                RankedCandidate(
                    entryIndex: entryIndex,
                    score: score(
                        query: query,
                        entry: entry,
                        similarityWorkspace: &similarityWorkspace
                    )
                )
            )
        }
        candidates.sort {
            $0.score == $1.score
                ? $0.entryIndex < $1.entryIndex
                : $0.score > $1.score
        }
        return candidates
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

    private func score(
        query: SongMatchQuery,
        entry: CatalogMatchEntry,
        similarityWorkspace: inout SongSimilarityWorkspace
    ) -> Double {
        var titleScore = 0.0
        for identity in entry.normalizedTitleIdentities {
            titleScore = max(
                titleScore,
                similarity(
                    query.normalizedTitle,
                    identity,
                    similarityWorkspace: &similarityWorkspace
                )
            )
        }

        let artistScore: Double
        if let importedArtist = query.normalizedArtist {
            if entry.artistAliasValues.contains(importedArtist.value) {
                artistScore = 1
            } else if entry.normalizedArtistAliases.contains(where: {
                importedArtist.value.contains($0.value) || $0.value.contains(importedArtist.value)
            }) {
                artistScore = 0.86
            } else {
                var bestArtistScore = 0.0
                for artistIdentity in entry.normalizedArtistAliases {
                    bestArtistScore = max(
                        bestArtistScore,
                        similarity(
                            importedArtist,
                            artistIdentity,
                            similarityWorkspace: &similarityWorkspace
                        )
                    )
                }
                artistScore = bestArtistScore
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

    private func identityConfirmationReason(
        query: SongMatchQuery,
        candidates: [KTVTrack],
        evidence: SongIdentityEvidence
    ) -> String {
        if candidates.count > 1 {
            return "找到多首同名歌曲，请确认歌手和版本"
        }
        if query.normalizedArtist == nil {
            return "歌名相同但缺少歌手，请确认这个候选"
        }
        if case .alias = evidence {
            return "别名可以召回候选，但仍需确认歌曲身份和版本"
        }
        return "歌名相同，但歌手或版本信息仍需确认"
    }

    private func similarity(
        _ lhs: NormalizedMatchText,
        _ rhs: NormalizedMatchText,
        similarityWorkspace: inout SongSimilarityWorkspace
    ) -> Double {
        SongNormalizer.similarityNormalized(
            lhs.value,
            rhs.value,
            lhsUnits: lhs.units,
            rhsUnits: rhs.units,
            workspace: &similarityWorkspace
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
    let primaryVersionIdentity: SongVersionIdentity
    let aliasVersionIdentities: [SongVersionIdentity]

    init(track: KTVTrack, catalogOrder: Int) {
        self.track = track
        self.catalogOrder = catalogOrder
        primaryVersionIdentity = SongVersionIdentity.parse(
            title: track.title,
            versionTags: track.versionTags
        )
        aliasVersionIdentities = track.aliases.map {
            SongVersionIdentity.parse(title: $0, versionTags: track.versionTags)
        }
        normalizedPrimaryTitle = .normalized(primaryVersionIdentity.normalizedBaseTitle)
        normalizedAliases = aliasVersionIdentities.map {
            .normalized($0.normalizedBaseTitle)
        }
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

    func identityEvidence(matching normalizedTitle: String) -> SongIdentityEvidence? {
        if normalizedPrimaryTitle.value == normalizedTitle {
            return .canonicalTitle(identity: primaryVersionIdentity)
        }
        guard let aliasIndex = normalizedAliases.firstIndex(where: {
            $0.value == normalizedTitle
        }) else {
            return nil
        }
        return .alias(
            rawValue: track.aliases[aliasIndex],
            identity: aliasVersionIdentities[aliasIndex]
        )
    }
}

private struct SongMatchQuery {
    let normalizedTitle: NormalizedMatchText
    let normalizedArtist: NormalizedMatchText?

    init(song: ImportedSong) {
        let versionIdentity = SongVersionIdentity.parse(
            title: song.title,
            versionTags: song.versionTags
        )
        normalizedTitle = .normalized(versionIdentity.normalizedBaseTitle)
        if let artist = song.artist?.nilIfBlank {
            normalizedArtist = .artist(artist)
        } else {
            normalizedArtist = nil
        }
    }
}

private struct NormalizedMatchText: Sendable {
    let value: String
    let units: [UInt32]

    static func title(_ rawValue: String) -> NormalizedMatchText {
        normalized(SongNormalizer.normalizeTitle(rawValue))
    }

    static func artist(_ rawValue: String) -> NormalizedMatchText {
        normalized(SongNormalizer.normalizeArtist(rawValue))
    }

    static func normalized(_ value: String) -> NormalizedMatchText {
        NormalizedMatchText(value: value, units: SongNormalizer.matchUnits(value))
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
    }
}
