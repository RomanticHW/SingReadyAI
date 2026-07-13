import Foundation

public enum ExternalMusicSource: String, Codable, Hashable, Sendable {
    case lastFM
    case iTunes
    case musicBrainz

    public var displayName: String {
        switch self {
        case .lastFM:
            return "Last.fm 公开结果"
        case .iTunes:
            return "Apple 公开搜索"
        case .musicBrainz:
            return "MusicBrainz 公开资料"
        }
    }

    fileprivate var defaultRelation: ExternalCandidateRelation {
        self == .iTunes ? .sameArtist : .similarTrack
    }
}

public struct ExternalSongCandidate: Codable, Identifiable, Hashable, Sendable {
    public var id: String { normalizedKey }
    public var title: String
    public var artist: String?
    public var source: ExternalMusicSource
    public var confidence: Double
    public var relation: ExternalCandidateRelation
    public var reasons: [String]
    public var externalURL: URL?
    public var appleTrackID: String?
    public var musicBrainzRecordingID: String?
    public var musicBrainzArtistID: String?
    public var isrc: String?
    public var primaryGenreName: String?
    public var releaseYear: Int?

    public init(
        title: String,
        artist: String? = nil,
        source: ExternalMusicSource,
        confidence: Double,
        relation: ExternalCandidateRelation? = nil,
        reasons: [String] = [],
        externalURL: URL? = nil,
        appleTrackID: String? = nil,
        musicBrainzRecordingID: String? = nil,
        musicBrainzArtistID: String? = nil,
        isrc: String? = nil,
        primaryGenreName: String? = nil,
        releaseYear: Int? = nil
    ) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = artist?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.source = source
        self.confidence = min(max(confidence, 0), 1)
        self.relation = relation ?? source.defaultRelation
        self.reasons = reasons
        self.externalURL = externalURL
        self.appleTrackID = appleTrackID
        self.musicBrainzRecordingID = musicBrainzRecordingID
        self.musicBrainzArtistID = musicBrainzArtistID
        self.isrc = isrc
        self.primaryGenreName = primaryGenreName
        self.releaseYear = releaseYear
    }

    public var normalizedKey: String {
        let titleKey = SongNormalizer.normalizeTitle(title)
        let artistKey = artist.map(SongNormalizer.normalizeArtist) ?? ""
        return "\(titleKey)|\(artistKey)"
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case artist
        case source
        case confidence
        case relation
        case reasons
        case externalURL
        case appleTrackID
        case musicBrainzRecordingID
        case musicBrainzArtistID
        case isrc
        case primaryGenreName
        case releaseYear
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        source = try container.decode(ExternalMusicSource.self, forKey: .source)
        confidence = min(max(try container.decode(Double.self, forKey: .confidence), 0), 1)
        relation = try container.decodeIfPresent(ExternalCandidateRelation.self, forKey: .relation)
            ?? source.defaultRelation
        reasons = try container.decodeIfPresent([String].self, forKey: .reasons) ?? []
        externalURL = try container.decodeIfPresent(URL.self, forKey: .externalURL)
        appleTrackID = try container.decodeIfPresent(String.self, forKey: .appleTrackID)
        musicBrainzRecordingID = try container.decodeIfPresent(String.self, forKey: .musicBrainzRecordingID)
        musicBrainzArtistID = try container.decodeIfPresent(String.self, forKey: .musicBrainzArtistID)
        isrc = try container.decodeIfPresent(String.self, forKey: .isrc)
        primaryGenreName = try container.decodeIfPresent(String.self, forKey: .primaryGenreName)
        releaseYear = try container.decodeIfPresent(Int.self, forKey: .releaseYear)
    }
}

public protocol ExternalMusicDataFetching: Sendable {
    func data(for url: URL) async throws -> Data
}

public struct URLSessionExternalMusicDataFetcher: ExternalMusicDataFetching {
    public static let defaultMaximumResponseBytes = 2 * 1_024 * 1_024

    private let session: URLSession
    private let maxResponseBytes: Int

    public init(maxResponseBytes: Int = Self.defaultMaximumResponseBytes) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        self.init(
            sessionConfiguration: configuration,
            maxResponseBytes: maxResponseBytes
        )
    }

    init(
        sessionConfiguration: URLSessionConfiguration,
        maxResponseBytes: Int
    ) {
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: sessionConfiguration)
        self.maxResponseBytes = max(1, maxResponseBytes)
    }

    public func data(for url: URL) async throws -> Data {
        let request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        let (bytes, response) = try await session.bytes(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw ExternalMusicError.httpStatus(httpResponse.statusCode)
        }
        if response.expectedContentLength > Int64(maxResponseBytes) {
            throw ExternalMusicError.responseTooLarge(maxBytes: maxResponseBytes)
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(
                min(maxResponseBytes, Int(response.expectedContentLength))
            )
        }
        for try await byte in bytes {
            guard data.count < maxResponseBytes else {
                throw ExternalMusicError.responseTooLarge(maxBytes: maxResponseBytes)
            }
            data.append(byte)
        }
        return data
    }
}

public enum ExternalMusicError: Error, Equatable {
    case missingArtist
    case invalidURL
    case httpStatus(Int)
    case responseTooLarge(maxBytes: Int)
}

public protocol SimilarSongProviding: Sendable {
    func similarSongs(for song: ImportedSong, limit: Int) async throws -> [ExternalSongCandidate]
}

public protocol SongMetadataResolving: Sendable {
    func enrich(_ candidate: ExternalSongCandidate) async throws -> ExternalSongCandidate
}

public struct ExternalMusicCandidateProvider: Sendable {
    private let similarProvider: any SimilarSongProviding
    private let metadataResolvers: [any SongMetadataResolving]

    public init(
        similarProvider: any SimilarSongProviding,
        metadataResolvers: [any SongMetadataResolving] = []
    ) {
        self.similarProvider = similarProvider
        self.metadataResolvers = metadataResolvers
    }

    public func candidates(
        for playlist: ImportedPlaylist,
        perSeedLimit: Int = 10
    ) async throws -> [ExternalSongCandidate] {
        var candidatesByKey: [String: ExternalSongCandidate] = [:]
        var firstLookupFailure: Error?
        var didCompleteLookup = false

        for song in playlist.songs {
            try Task.checkCancellation()
            let similarSongs: [ExternalSongCandidate]
            do {
                similarSongs = try await similarProvider.similarSongs(for: song, limit: perSeedLimit)
                didCompleteLookup = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstLookupFailure == nil {
                    firstLookupFailure = error
                }
                continue
            }
            for similarSong in similarSongs {
                try Task.checkCancellation()
                var candidate = similarSong
                switch candidate.relation {
                case .sameArtist:
                    candidate.reasons.append("与《\(song.title)》来自同一歌手的公开曲目")
                case .similarTrack:
                    candidate.reasons.append("公开结果显示与《\(song.title)》相似")
                }
                for resolver in metadataResolvers {
                    do {
                        candidate = try await resolver.enrich(candidate)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        continue
                    }
                }
                merge(candidate, into: &candidatesByKey)
            }
        }

        if candidatesByKey.isEmpty, !didCompleteLookup, let firstLookupFailure {
            throw firstLookupFailure
        }

        return candidatesByKey.values.sorted {
            if $0.confidence == $1.confidence {
                return $0.normalizedKey < $1.normalizedKey
            }
            return $0.confidence > $1.confidence
        }
    }

    private func merge(
        _ candidate: ExternalSongCandidate,
        into candidatesByKey: inout [String: ExternalSongCandidate]
    ) {
        guard var existing = candidatesByKey[candidate.normalizedKey] else {
            candidatesByKey[candidate.normalizedKey] = candidate
            return
        }
        let mergedReasons = Array(NSOrderedSet(array: existing.reasons + candidate.reasons).compactMap { $0 as? String })
        if candidate.confidence > existing.confidence {
            var replacement = candidate
            replacement.reasons = mergedReasons
            candidatesByKey[candidate.normalizedKey] = replacement
        } else {
            existing.reasons = mergedReasons
            candidatesByKey[candidate.normalizedKey] = existing
        }
    }
}

public struct ExternalCandidateSeedSelector: Sendable {
    public init() {}

    public func seeds(
        from songs: [ImportedSong],
        matches: [MatchResult],
        limit: Int = 4
    ) -> [ImportedSong] {
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return [] }
        let prioritySongIDs = Set(matches.filter(needsBackup).map(\.importedSong.id))
        var selected: [ImportedSong] = []
        var seenSemanticKeys = Set<String>()

        func append(_ song: ImportedSong) {
            guard selected.count < boundedLimit,
                  song.artist?.nilIfBlank != nil else { return }
            let key = semanticKey(for: song)
            guard seenSemanticKeys.insert(key).inserted else { return }
            selected.append(song)
        }

        for song in songs where prioritySongIDs.contains(song.id) {
            append(song)
        }
        for song in songs where selected.count < boundedLimit {
            append(song)
        }
        return selected
    }

    private func needsBackup(_ match: MatchResult) -> Bool {
        if match.confirmationState == .required {
            return true
        }
        switch match.status {
        case .unmatched, .fuzzy:
            return true
        case .alternative:
            return match.needsAlternativeAdoption
        case .exact:
            return false
        }
    }

    private func semanticKey(for song: ImportedSong) -> String {
        let title = SongNormalizer.normalizeTitle(song.title)
        let artist = song.artist.map(SongNormalizer.normalizeArtist) ?? ""
        return title.isEmpty ? "id:\(song.id.uuidString.lowercased())" : "\(title)|\(artist)"
    }
}

public struct ExternalCandidateTrackAccumulator: Sendable {
    private let mapper: ExternalCandidateTrackMapper

    public init(mapper: ExternalCandidateTrackMapper = ExternalCandidateTrackMapper()) {
        self.mapper = mapper
    }

    public func mergedTracks(
        baseCatalog: [KTVTrack],
        existingExternalTracks: [KTVTrack],
        candidates: [ExternalSongCandidate],
        limit: Int = 12
    ) -> [KTVTrack] {
        let baseSemanticKeys = Set(baseCatalog.map(Self.semanticKey))
        var tracksBySemanticKey = existingExternalTracks.reduce(into: [String: KTVTrack]()) { result, track in
            let key = Self.semanticKey(track)
            guard !baseSemanticKeys.contains(key) else { return }
            if let existing = result[key], Self.relevance(of: existing) >= Self.relevance(of: track) {
                return
            }
            result[key] = track
        }

        for candidate in candidates.sorted(by: { $0.confidence > $1.confidence }) {
            let track = mapper.map(candidate)
            let key = Self.semanticKey(track)
            guard !baseSemanticKeys.contains(key) else { continue }
            if let existing = tracksBySemanticKey[key], Self.relevance(of: existing) >= candidate.confidence {
                continue
            }
            tracksBySemanticKey[key] = track
        }

        return Array(tracksBySemanticKey.values.sorted {
            let lhsRelevance = Self.relevance(of: $0)
            let rhsRelevance = Self.relevance(of: $1)
            if lhsRelevance != rhsRelevance {
                return lhsRelevance > rhsRelevance
            }
            return Self.semanticKey($0) < Self.semanticKey($1)
        }.prefix(max(0, limit)))
    }

    private static func semanticKey(_ track: KTVTrack) -> String {
        "\(SongNormalizer.normalizeTitle(track.title))|\(SongNormalizer.normalizeArtist(track.artist))"
    }

    private static func relevance(of track: KTVTrack) -> Double {
        track.externalCandidateMetadata?.relevance ?? 0
    }
}

public struct LastFMSimilarSongProvider: SimilarSongProviding {
    private let apiKey: String
    private let fetcher: any ExternalMusicDataFetching

    public init(
        apiKey: String,
        fetcher: any ExternalMusicDataFetching = URLSessionExternalMusicDataFetcher()
    ) {
        self.apiKey = apiKey
        self.fetcher = fetcher
    }

    public func similarSongs(for song: ImportedSong, limit: Int) async throws -> [ExternalSongCandidate] {
        guard let artist = song.artist?.nilIfBlank else {
            throw ExternalMusicError.missingArtist
        }
        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")
        components?.queryItems = [
            URLQueryItem(name: "method", value: "track.getsimilar"),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "track", value: song.title),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components?.url else {
            throw ExternalMusicError.invalidURL
        }
        let data = try await fetcher.data(for: url)
        let response = try JSONDecoder().decode(LastFMSimilarTracksResponse.self, from: data)
        return response.similartracks.track.map { track in
            ExternalSongCandidate(
                title: track.name,
                artist: track.artist.name,
                source: .lastFM,
                confidence: track.match.value,
                relation: .similarTrack,
                reasons: ["Last.fm 公开相似曲目结果"],
                externalURL: track.url.flatMap(URL.init(string:)),
                musicBrainzArtistID: track.artist.mbid?.nilIfBlank
            )
        }
    }
}

public struct ITunesArtistSongProvider: SimilarSongProviding {
    private let fetcher: any ExternalMusicDataFetching
    private let countryCode: String

    public init(
        fetcher: any ExternalMusicDataFetching = URLSessionExternalMusicDataFetcher(),
        countryCode: String = "CN"
    ) {
        self.fetcher = fetcher
        self.countryCode = countryCode
    }

    public func similarSongs(for song: ImportedSong, limit: Int) async throws -> [ExternalSongCandidate] {
        guard let artist = song.artist?.nilIfBlank else {
            throw ExternalMusicError.missingArtist
        }
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: artist),
            URLQueryItem(name: "country", value: countryCode),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "attribute", value: "artistTerm"),
            URLQueryItem(name: "limit", value: String(max(limit + 4, 8)))
        ]
        guard let url = components?.url else {
            throw ExternalMusicError.invalidURL
        }
        let data = try await fetcher.data(for: url)
        let response = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        let seedTitle = SongNormalizer.normalizeTitle(song.title)
        let seedArtist = SongNormalizer.normalizeArtist(artist)
        return response.results.compactMap { result in
            guard let title = result.trackName?.nilIfBlank,
                  let resultArtist = result.artistName?.nilIfBlank,
                  SongNormalizer.normalizeArtist(resultArtist) == seedArtist,
                  SongNormalizer.normalizeTitle(title) != seedTitle else {
                return nil
            }
            return ExternalSongCandidate(
                title: title,
                artist: resultArtist,
                source: .iTunes,
                confidence: 0.76,
                relation: .sameArtist,
                reasons: ["Apple 公开搜索的同歌手曲目"],
                externalURL: result.trackViewUrl.flatMap(URL.init(string:)),
                appleTrackID: String(result.trackId),
                primaryGenreName: result.primaryGenreName,
                releaseYear: result.releaseYear
            )
        }
        .prefix(limit)
        .map { $0 }
    }
}

public struct ITunesSearchMetadataResolver: SongMetadataResolving {
    private let fetcher: any ExternalMusicDataFetching
    private let countryCode: String

    public init(
        fetcher: any ExternalMusicDataFetching = URLSessionExternalMusicDataFetcher(),
        countryCode: String = "US"
    ) {
        self.fetcher = fetcher
        self.countryCode = countryCode
    }

    public func enrich(_ candidate: ExternalSongCandidate) async throws -> ExternalSongCandidate {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        let term = [candidate.title, candidate.artist].compactMap(\.self).joined(separator: " ")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: countryCode),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components?.url else {
            throw ExternalMusicError.invalidURL
        }
        let data = try await fetcher.data(for: url)
        let response = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        guard let result = response.results.first else {
            return candidate
        }

        var enriched = candidate
        enriched.appleTrackID = String(result.trackId)
        enriched.externalURL = result.trackViewUrl.flatMap(URL.init(string:)) ?? enriched.externalURL
        enriched.primaryGenreName = result.primaryGenreName ?? enriched.primaryGenreName
        enriched.releaseYear = result.releaseYear ?? enriched.releaseYear
        return enriched
    }
}

public struct MusicBrainzMetadataResolver: SongMetadataResolving {
    private let fetcher: any ExternalMusicDataFetching

    public init(fetcher: any ExternalMusicDataFetching = URLSessionExternalMusicDataFetcher()) {
        self.fetcher = fetcher
    }

    public func enrich(_ candidate: ExternalSongCandidate) async throws -> ExternalSongCandidate {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording")
        var query = #"recording:"\#(candidate.title)""#
        if let artist = candidate.artist?.nilIfBlank {
            query += #" AND artist:"\#(artist)""#
        }
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "inc", value: "artist-credits+isrcs")
        ]
        guard let url = components?.url else {
            throw ExternalMusicError.invalidURL
        }
        let data = try await fetcher.data(for: url)
        let response = try JSONDecoder().decode(MusicBrainzRecordingSearchResponse.self, from: data)
        guard let recording = response.recordings.first else {
            return candidate
        }

        var enriched = candidate
        enriched.musicBrainzRecordingID = recording.id
        enriched.musicBrainzArtistID = recording.artistCredit.first?.artist.id ?? enriched.musicBrainzArtistID
        enriched.isrc = recording.isrcs?.first ?? enriched.isrc
        return enriched
    }
}

public struct ExternalCandidateTrackMapper: Sendable {
    public init() {}

    public func map(_ candidate: ExternalSongCandidate) -> KTVTrack {
        KTVTrack(
            id: "external:\(candidate.source.rawValue):\(candidate.normalizedKey)",
            title: candidate.title,
            artist: candidate.artist ?? "未知歌手",
            language: language(for: candidate),
            era: era(for: candidate.releaseYear),
            genre: candidate.primaryGenreName ?? "流行",
            moodTags: [],
            sceneTags: [],
            difficulty: 3,
            vocalRangeLowMidi: 48,
            vocalRangeHighMidi: 70,
            energy: 0.58,
            singAlongScore: 0.72,
            ktvAvailability: 0.45,
            duetFriendly: false,
            rapDensity: 0.12,
            highNoteRisk: 0.50,
            aliases: [],
            similarSongIds: [],
            externalURL: candidate.externalURL,
            catalogSource: .externalSimilar,
            confidenceNote: "\(candidate.relation.displayName)，KTV 收录与适唱情况待核对",
            externalCandidateMetadata: ExternalCandidateMetadata(
                relation: candidate.relation,
                relevance: candidate.confidence,
                reasons: candidate.reasons,
                provider: candidate.source
            )
        )
    }

    private func language(for candidate: ExternalSongCandidate) -> String {
        let genre = (candidate.primaryGenreName ?? "").lowercased()
        if genre.contains("mandopop") || genre.contains("c-pop") || genre.contains("chinese") {
            return "Mandarin"
        }
        return "Unknown"
    }

    private func era(for releaseYear: Int?) -> String {
        guard let releaseYear else { return "Unknown" }
        let decade = (releaseYear / 10) * 10
        return "\(decade)s"
    }
}

public enum ExternalCandidatePlaylistRevision {
    public static func fingerprint(for playlist: ImportedPlaylist) -> String {
        var parts = [
            playlist.id.uuidString.lowercased(),
            playlist.source.rawValue,
            playlist.title.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        parts.append(contentsOf: playlist.songs.enumerated().map { index, song in
            [
                String(index),
                song.id.uuidString.lowercased(),
                song.title.trimmingCharacters(in: .whitespacesAndNewlines),
                song.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                song.versionTags.joined(separator: ",")
            ].joined(separator: "\u{1F}")
        })

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in parts.joined(separator: "\u{1E}").utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

public struct ExternalCandidateRequest: Equatable, Hashable, Sendable {
    public let id: UInt64
    public let playlistID: UUID
    public let playlistRevision: String

    fileprivate init(id: UInt64, playlistID: UUID, playlistRevision: String) {
        self.id = id
        self.playlistID = playlistID
        self.playlistRevision = playlistRevision
    }
}

public struct ExternalCandidateRequestCoordinator: Sendable {
    private struct ActiveRequest: Sendable {
        let request: ExternalCandidateRequest
        let deadlineNanoseconds: UInt64
    }

    private var nextID: UInt64 = 0
    private var active: ActiveRequest?

    public init() {}

    public var isBusy: Bool {
        active != nil
    }

    public mutating func beginIfIdle(
        playlistID: UUID,
        playlistRevision: String = "",
        nowNanoseconds: UInt64,
        timeoutNanoseconds: UInt64
    ) -> ExternalCandidateRequest? {
        guard active == nil else { return nil }
        nextID &+= 1
        let request = ExternalCandidateRequest(
            id: nextID,
            playlistID: playlistID,
            playlistRevision: playlistRevision
        )
        let (deadline, overflow) = nowNanoseconds.addingReportingOverflow(timeoutNanoseconds)
        active = ActiveRequest(
            request: request,
            deadlineNanoseconds: overflow ? UInt64.max : deadline
        )
        return request
    }

    public func isActive(_ request: ExternalCandidateRequest) -> Bool {
        active?.request == request
    }

    public mutating func commit(
        _ request: ExternalCandidateRequest,
        playlistID: UUID,
        playlistRevision: String = "",
        nowNanoseconds: UInt64
    ) -> Bool {
        guard let active,
              active.request == request,
              request.playlistID == playlistID,
              request.playlistRevision == playlistRevision,
              nowNanoseconds < active.deadlineNanoseconds else {
            return false
        }
        self.active = nil
        return true
    }

    public mutating func finish(_ request: ExternalCandidateRequest) -> Bool {
        guard active?.request == request else { return false }
        active = nil
        return true
    }

    public mutating func expire(
        _ request: ExternalCandidateRequest,
        nowNanoseconds: UInt64
    ) -> Bool {
        guard let active,
              active.request == request,
              nowNanoseconds >= active.deadlineNanoseconds else {
            return false
        }
        self.active = nil
        return true
    }

    public mutating func cancel() {
        active = nil
    }
}

public enum ExternalCandidateRequestError: Error, Equatable, LocalizedError, Sendable {
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            return "公开搜索等待超时"
        }
    }
}

public func withExternalCandidateTimeout<Value: Sendable>(
    nanoseconds: UInt64,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let state = ExternalCandidateTimeoutState<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard state.install(continuation) else { return }

            let operationTask = Task<Void, Never> {
                let result: Result<Value, Error>
                do {
                    result = .success(try await operation())
                } catch {
                    result = .failure(error)
                }
                state.resolve(result)
            }
            let timeoutTask = Task<Void, Never> {
                do {
                    if nanoseconds > 0 {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    }
                    try Task.checkCancellation()
                    state.resolve(.failure(ExternalCandidateRequestError.timedOut))
                } catch {
                    return
                }
            }
            state.installTasks(operation: operationTask, timeout: timeoutTask)
        }
    } onCancel: {
        state.resolve(.failure(CancellationError()))
    }
}

private final class ExternalCandidateTimeoutState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var terminalResult: Result<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    @discardableResult
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let terminalResult {
            lock.unlock()
            continuation.resume(with: terminalResult)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func installTasks(
        operation: Task<Void, Never>,
        timeout: Task<Void, Never>
    ) {
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            operation.cancel()
            timeout.cancel()
            return
        }
        operationTask = operation
        timeoutTask = timeout
        lock.unlock()
    }

    func resolve(_ result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>?
        let operationTask: Task<Void, Never>?
        let timeoutTask: Task<Void, Never>?

        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        terminalResult = result
        continuation = self.continuation
        self.continuation = nil
        operationTask = self.operationTask
        timeoutTask = self.timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}

private struct LastFMSimilarTracksResponse: Decodable {
    let similartracks: SimilarTracks

    struct SimilarTracks: Decodable {
        let track: [Track]
    }

    struct Track: Decodable {
        let name: String
        let match: FlexibleDouble
        let url: String?
        let artist: Artist
    }

    struct Artist: Decodable {
        let name: String
        let mbid: String?
    }
}

private struct ITunesSearchResponse: Decodable {
    let results: [Result]

    struct Result: Decodable {
        let trackId: Int
        let trackName: String?
        let artistName: String?
        let trackViewUrl: String?
        let primaryGenreName: String?
        let releaseDate: String?

        var releaseYear: Int? {
            guard let prefix = releaseDate?.prefix(4) else { return nil }
            return Int(prefix)
        }
    }
}

private struct MusicBrainzRecordingSearchResponse: Decodable {
    let recordings: [Recording]

    struct Recording: Decodable {
        let id: String
        let title: String?
        let score: Int?
        let isrcs: [String]?
        let artistCredit: [ArtistCredit]

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case score
            case isrcs
            case artistCredit = "artist-credit"
        }
    }

    struct ArtistCredit: Decodable {
        let artist: Artist
    }

    struct Artist: Decodable {
        let id: String
        let name: String
    }
}

private struct FlexibleDouble: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let doubleValue = try? container.decode(Double.self) {
            value = min(max(doubleValue, 0), 1)
            return
        }
        let stringValue = try container.decode(String.self)
        value = min(max(Double(stringValue) ?? 0, 0), 1)
    }
}
