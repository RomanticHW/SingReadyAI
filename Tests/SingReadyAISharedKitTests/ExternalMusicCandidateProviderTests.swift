import XCTest
@testable import SingReadyAISharedKit

final class ExternalMusicCandidateProviderTests: XCTestCase {
    override func tearDown() {
        ExternalMusicURLProtocol.responseData = Data()
        ExternalMusicURLProtocol.responseStatus = 200
        ExternalMusicURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func testURLSessionFetcherRejectsOversizedUncachedResponses() async throws {
        ExternalMusicURLProtocol.responseData = Data(repeating: 0x41, count: 96)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExternalMusicURLProtocol.self]
        let fetcher = URLSessionExternalMusicDataFetcher(
            sessionConfiguration: configuration,
            maxResponseBytes: 32
        )

        do {
            _ = try await fetcher.data(for: URL(string: "https://itunes.apple.com/search")!)
            XCTFail("异常响应超过上限时必须停止读取")
        } catch let error as ExternalMusicError {
            XCTAssertEqual(error, .responseTooLarge(maxBytes: 32))
        }
        XCTAssertEqual(
            ExternalMusicURLProtocol.lastRequest?.cachePolicy,
            .reloadIgnoringLocalCacheData
        )
    }

    func testURLSessionFetcherReturnsBoundedSuccessfulResponse() async throws {
        ExternalMusicURLProtocol.responseData = Data("bounded".utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExternalMusicURLProtocol.self]
        let fetcher = URLSessionExternalMusicDataFetcher(
            sessionConfiguration: configuration,
            maxResponseBytes: 32
        )

        let data = try await fetcher.data(for: URL(string: "https://itunes.apple.com/search")!)

        XCTAssertEqual(String(data: data, encoding: .utf8), "bounded")
    }

    func testProviderDeduplicatesAndEnrichesSimilarCandidates() async throws {
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "验证歌单",
            songs: [
                ImportedSong(title: "晴天", artist: "周杰伦", source: .plainText, confidence: 0.95),
                ImportedSong(title: "稻香", artist: "周杰伦", source: .plainText, confidence: 0.95)
            ],
            parseConfidence: 0.95
        )
        let similarProvider = StubSimilarSongProvider(results: [
            "晴天": [
                ExternalSongCandidate(title: "七里香", artist: "周杰伦", source: .lastFM, confidence: 0.92),
                ExternalSongCandidate(title: "十年", artist: "陈奕迅", source: .lastFM, confidence: 0.72)
            ],
            "稻香": [
                ExternalSongCandidate(title: "七里香", artist: "周杰伦", source: .lastFM, confidence: 0.85)
            ]
        ])
        let resolver = StubMetadataResolver { candidate in
            var enriched = candidate
            enriched.externalURL = URL(string: "https://example.com/\(candidate.normalizedKey)")
            enriched.releaseYear = candidate.title == "七里香" ? 2004 : nil
            return enriched
        }
        let provider = ExternalMusicCandidateProvider(
            similarProvider: similarProvider,
            metadataResolvers: [resolver]
        )

        let candidates = try await provider.candidates(for: playlist, perSeedLimit: 5)

        XCTAssertEqual(candidates.map(\.title), ["七里香", "十年"])
        XCTAssertEqual(candidates.first?.confidence, 0.92)
        XCTAssertEqual(candidates.first?.releaseYear, 2004)
        XCTAssertEqual(candidates.first?.source, .lastFM)
        XCTAssertTrue(candidates.first?.reasons.contains("公开结果显示与《晴天》相似") == true)
        XCTAssertEqual(candidates.first?.relation, .similarTrack)
    }

    func testProviderKeepsSuccessfulSeedsWhenOneSeedFails() async throws {
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "部分失败歌单",
            songs: [
                ImportedSong(title: "可用歌", artist: "歌手A", source: .plainText, confidence: 0.9),
                ImportedSong(title: "失败歌", artist: "歌手B", source: .plainText, confidence: 0.9)
            ],
            parseConfidence: 0.9
        )
        let provider = ExternalMusicCandidateProvider(
            similarProvider: PartiallyFailingSimilarSongProvider()
        )

        let candidates = try await provider.candidates(for: playlist, perSeedLimit: 5)

        XCTAssertEqual(candidates.map(\.title), ["可用相似歌"])
    }

    func testProviderThrowsWhenEverySeedLookupFails() async {
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "全部失败歌单",
            songs: [
                ImportedSong(title: "失败歌一", artist: "歌手A", source: .plainText, confidence: 0.9),
                ImportedSong(title: "失败歌二", artist: "歌手B", source: .plainText, confidence: 0.9)
            ],
            parseConfidence: 0.9
        )
        let provider = ExternalMusicCandidateProvider(
            similarProvider: AlwaysFailingSimilarSongProvider()
        )

        do {
            _ = try await provider.candidates(for: playlist, perSeedLimit: 5)
            XCTFail("所有公开搜索都失败时不应伪装成空结果")
        } catch let error as ExternalMusicError {
            XCTAssertEqual(error, .httpStatus(503))
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
    }

    func testProviderReturnsEmptyWhenAtLeastOneSeedLookupSuccessfullyReturnsNoCandidates() async throws {
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "空结果歌单",
            songs: [
                ImportedSong(title: "缺歌手", source: .plainText, confidence: 0.7),
                ImportedSong(title: "正常空结果", artist: "歌手B", source: .plainText, confidence: 0.9)
            ],
            parseConfidence: 0.8
        )
        let provider = ExternalMusicCandidateProvider(
            similarProvider: MissingArtistThenEmptySimilarSongProvider()
        )

        let candidates = try await provider.candidates(for: playlist, perSeedLimit: 5)

        XCTAssertTrue(candidates.isEmpty)
    }

    func testSameArtistSeedSelectionSkipsFourArtistlessBackupSongsAndUsesLaterSearchableSong() async throws {
        let artistlessSongs = (1...4).map { index in
            ImportedSong(
                title: "缺歌手歌曲\(index)",
                source: .plainText,
                confidence: 0.6
            )
        }
        let searchableSong = ImportedSong(
            title: "晴天",
            artist: "周杰伦",
            source: .plainText,
            confidence: 1
        )
        let songs = artistlessSongs + [searchableSong]
        let matches = artistlessSongs.map { song in
            MatchResult(
                importedSong: song,
                matchedTrack: nil,
                alternatives: [],
                status: .unmatched,
                score: 0,
                reason: "缺少歌手，未命中"
            )
        } + [
            MatchResult(
                importedSong: searchableSong,
                matchedTrack: nil,
                alternatives: [],
                status: .unmatched,
                score: 0,
                reason: "已有歌手，可用于同歌手搜索"
            )
        ]
        let seeds = ExternalCandidateSeedSelector().seeds(
            from: songs,
            matches: matches,
            limit: 4
        )
        let recordingProvider = RecordingSameArtistSongProvider()
        let provider = ExternalMusicCandidateProvider(similarProvider: recordingProvider)
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "同歌手搜索",
            songs: seeds,
            parseConfidence: 0.7
        )

        let candidates = try await provider.candidates(for: playlist, perSeedLimit: 4)
        let requestedSongs = await recordingProvider.requestedSongs

        XCTAssertTrue(candidates.isEmpty)
        XCTAssertEqual(requestedSongs.map(\.id), [searchableSong.id])
        XCTAssertTrue(requestedSongs.allSatisfy { $0.artist?.isEmpty == false })
    }

    func testSameArtistSeedSelectionWithNoUsableArtistsReturnsEmptyWithoutLookupFailure() async throws {
        let songs = (1...4).map { index in
            ImportedSong(
                title: "无歌手歌曲\(index)",
                source: .plainText,
                confidence: 0.6
            )
        }
        let matches = songs.map { song in
            MatchResult(
                importedSong: song,
                matchedTrack: nil,
                alternatives: [],
                status: .unmatched,
                score: 0,
                reason: "缺少歌手，未命中"
            )
        }
        let seeds = ExternalCandidateSeedSelector().seeds(
            from: songs,
            matches: matches,
            limit: 4
        )
        let recordingProvider = RecordingSameArtistSongProvider()
        let provider = ExternalMusicCandidateProvider(similarProvider: recordingProvider)
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "无可用歌手",
            songs: seeds,
            parseConfidence: 0.6
        )

        let candidates = try await provider.candidates(for: playlist, perSeedLimit: 4)
        let requestedSongs = await recordingProvider.requestedSongs

        XCTAssertTrue(seeds.isEmpty)
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertTrue(requestedSongs.isEmpty)
    }

    func testProviderKeepsCandidateWhenMetadataResolverFails() async throws {
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "元数据失败歌单",
            songs: [ImportedSong(title: "晴天", artist: "周杰伦", source: .plainText, confidence: 1)],
            parseConfidence: 1
        )
        let provider = ExternalMusicCandidateProvider(
            similarProvider: StubSimilarSongProvider(results: [
                "晴天": [ExternalSongCandidate(title: "七里香", artist: "周杰伦", source: .iTunes, confidence: 0.9)]
            ]),
            metadataResolvers: [AlwaysFailingMetadataResolver()]
        )

        let candidates = try await provider.candidates(for: playlist, perSeedLimit: 5)

        XCTAssertEqual(candidates.map(\.title), ["七里香"])
    }

    func testITunesArtistProviderReturnsOtherUserFacingTracks() async throws {
        let fetcher = StubDataFetcher(data: """
        {
          "resultCount": 3,
          "results": [
            {
              "trackId": 1,
              "trackName": "晴天",
              "artistName": "周杰伦",
              "trackViewUrl": "https://music.apple.com/cn/song/1",
              "primaryGenreName": "Mandopop",
              "releaseDate": "2003-07-31T00:00:00Z"
            },
            {
              "trackId": 2,
              "trackName": "七里香",
              "artistName": "周 杰伦",
              "trackViewUrl": "https://music.apple.com/cn/song/2",
              "primaryGenreName": "Mandopop",
              "releaseDate": "2004-08-03T00:00:00Z"
            },
            {
              "trackId": 3,
              "trackName": "稻香",
              "artistName": "周杰伦",
              "trackViewUrl": "https://music.apple.com/cn/song/3",
              "primaryGenreName": "Mandopop",
              "releaseDate": "2008-10-15T00:00:00Z"
            }
          ]
        }
        """.data(using: .utf8)!)
        let provider = ITunesArtistSongProvider(fetcher: fetcher, countryCode: "CN")
        let song = ImportedSong(title: "晴天", artist: "周杰伦", source: .plainText, confidence: 1)

        let candidates = try await provider.similarSongs(for: song, limit: 2)

        XCTAssertEqual(candidates.map(\.title), ["七里香", "稻香"])
        XCTAssertEqual(candidates.map(\.relation), [.sameArtist, .sameArtist])
        XCTAssertTrue(candidates.allSatisfy { $0.reasons.contains("Apple 公开搜索的同歌手曲目") })
        XCTAssertEqual(candidates.first?.externalURL?.host, "music.apple.com")
        XCTAssertTrue(fetcher.requestedURLs.first?.absoluteString.contains("country=CN") == true)
    }

    func testITunesArtistProviderRejectsResultsFromDifferentNormalizedArtist() async throws {
        let fetcher = StubDataFetcher(data: """
        {
          "resultCount": 3,
          "results": [
            {
              "trackId": 1,
              "trackName": "七里香",
              "artistName": "周杰伦",
              "trackViewUrl": "https://music.apple.com/cn/song/1"
            },
            {
              "trackId": 2,
              "trackName": "错误合作曲",
              "artistName": "周杰伦与其他歌手",
              "trackViewUrl": "https://music.apple.com/cn/song/2"
            },
            {
              "trackId": 3,
              "trackName": "同名其他人",
              "artistName": "周杰伦乐队",
              "trackViewUrl": "https://music.apple.com/cn/song/3"
            }
          ]
        }
        """.data(using: .utf8)!)
        let provider = ITunesArtistSongProvider(fetcher: fetcher, countryCode: "CN")
        let song = ImportedSong(title: "晴天", artist: "周杰伦", source: .plainText, confidence: 1)

        let candidates = try await provider.similarSongs(for: song, limit: 10)

        XCTAssertEqual(candidates.map(\.title), ["七里香"])
        XCTAssertEqual(candidates.first?.relation, .sameArtist)
    }

    func testLastFMClientBuildsRequestAndParsesSimilarTracks() async throws {
        let fetcher = StubDataFetcher(data: """
        {
          "similartracks": {
            "track": [
              {
                "name": "七里香",
                "match": "0.93",
                "url": "https://www.last.fm/music/artist/_/song",
                "artist": { "name": "周杰伦", "mbid": "artist-mbid" }
              }
            ]
          }
        }
        """.data(using: .utf8)!)
        let client = LastFMSimilarSongProvider(apiKey: "test-key", fetcher: fetcher)
        let song = ImportedSong(title: "晴天", artist: "周杰伦", source: .plainText, confidence: 1)

        let candidates = try await client.similarSongs(for: song, limit: 10)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].title, "七里香")
        XCTAssertEqual(candidates[0].artist, "周杰伦")
        XCTAssertEqual(candidates[0].confidence, 0.93, accuracy: 0.001)
        XCTAssertEqual(candidates[0].source, .lastFM)
        XCTAssertEqual(candidates[0].relation, .similarTrack)
        XCTAssertTrue(candidates[0].reasons.contains("Last.fm 公开相似曲目结果"))
        XCTAssertEqual(candidates[0].musicBrainzArtistID, "artist-mbid")
        XCTAssertTrue(fetcher.requestedURLs.first?.absoluteString.contains("method=track.getsimilar") == true)
        XCTAssertTrue(fetcher.requestedURLs.first?.absoluteString.contains("api_key=test-key") == true)
    }

    func testITunesResolverEnrichesCandidateFromSearchResult() async throws {
        let fetcher = StubDataFetcher(data: """
        {
          "resultCount": 1,
          "results": [
            {
              "trackId": 3001,
              "trackName": "七里香",
              "artistName": "周杰伦",
              "trackViewUrl": "https://music.apple.com/song/3001",
              "primaryGenreName": "Mandopop",
              "releaseDate": "2004-08-03T07:00:00Z"
            }
          ]
        }
        """.data(using: .utf8)!)
        let resolver = ITunesSearchMetadataResolver(fetcher: fetcher, countryCode: "US")
        let candidate = ExternalSongCandidate(title: "七里香", artist: "周杰伦", source: .lastFM, confidence: 0.8)

        let enriched = try await resolver.enrich(candidate)

        XCTAssertEqual(enriched.appleTrackID, "3001")
        XCTAssertEqual(enriched.externalURL?.absoluteString, "https://music.apple.com/song/3001")
        XCTAssertEqual(enriched.primaryGenreName, "Mandopop")
        XCTAssertEqual(enriched.releaseYear, 2004)
        XCTAssertTrue(fetcher.requestedURLs.first?.absoluteString.contains("itunes.apple.com/search") == true)
    }

    func testMusicBrainzResolverEnrichesCandidateFromRecordingSearch() async throws {
        let fetcher = StubDataFetcher(data: """
        {
          "recordings": [
            {
              "id": "recording-mbid",
              "title": "七里香",
              "score": 98,
              "isrcs": ["TWK970401001"],
              "artist-credit": [
                {
                  "artist": {
                    "id": "artist-mbid",
                    "name": "周杰伦"
                  }
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!)
        let resolver = MusicBrainzMetadataResolver(fetcher: fetcher)
        let candidate = ExternalSongCandidate(title: "七里香", artist: "周杰伦", source: .lastFM, confidence: 0.8)

        let enriched = try await resolver.enrich(candidate)

        XCTAssertEqual(enriched.musicBrainzRecordingID, "recording-mbid")
        XCTAssertEqual(enriched.musicBrainzArtistID, "artist-mbid")
        XCTAssertEqual(enriched.isrc, "TWK970401001")
        XCTAssertTrue(fetcher.requestedURLs.first?.absoluteString.contains("musicbrainz.org/ws/2/recording") == true)
    }

    func testExternalCandidateCollectionRoundTripsOnlyPublicSourceMetadata() throws {
        let basis = ExternalCandidateBasis(
            playlistID: UUID(uuidString: "1D5387CB-A857-4E48-B6B9-1301731BEE29")!,
            reviewRevision: 7,
            requestRevision: 11
        )
        let candidate = ExternalSongCandidate(
            title: "七里香",
            artist: "周杰伦",
            source: .iTunes,
            confidence: 0.91,
            relation: .sameArtist,
            reasons: ["公开同歌手曲目"],
            externalURL: URL(string: "https://music.apple.com/cn/song/3001"),
            appleTrackID: "3001",
            musicBrainzRecordingID: "recording-3001",
            musicBrainzArtistID: "artist-3001",
            isrc: "TWK970401001",
            primaryGenreName: "Mandopop",
            releaseYear: 2004
        )
        let collection = ExternalCandidateCollection(
            basis: basis,
            candidates: [candidate]
        )

        let data = try JSONEncoder().encode(collection)
        let restored = try JSONDecoder().decode(ExternalCandidateCollection.self, from: data)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(restored, collection)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.candidates.first, candidate)
        for forbiddenKey in ["difficulty", "vocalRange", "sceneTags", "ktvAvailability"] {
            XCTAssertFalse(json.contains(forbiddenKey), forbiddenKey)
        }
    }

    func testExternalCandidateMapperCreatesProvisionalKTVTrack() {
        let candidate = ExternalSongCandidate(
            title: "七里香",
            artist: "周杰伦",
            source: .lastFM,
            confidence: 0.9,
            appleTrackID: "3001",
            primaryGenreName: "Mandopop",
            releaseYear: 2004
        )

        let track = ExternalCandidateTrackMapper().map(candidate)

        XCTAssertEqual(track.id, "external:lastFM:七里香|周杰伦")
        XCTAssertEqual(track.title, "七里香")
        XCTAssertEqual(track.artist, "周杰伦")
        XCTAssertEqual(track.language, "Mandarin")
        XCTAssertEqual(track.era, "2000s")
        XCTAssertEqual(track.genre, "Mandopop")
        XCTAssertTrue(track.moodTags.isEmpty)
        XCTAssertEqual(track.ktvAvailability, 0.45)
        XCTAssertEqual(track.vocalRangeLowMidi, 48)
        XCTAssertEqual(track.vocalRangeHighMidi, 70)
        XCTAssertTrue(track.isProvisionalExternalCandidate)
        XCTAssertEqual(track.externalCandidateMetadata?.relation, .similarTrack)
        XCTAssertEqual(track.externalCandidateMetadata?.relevance, 0.9)
        XCTAssertEqual(track.externalCandidateMetadata?.provider, .lastFM)
        XCTAssertTrue(track.confidenceNote?.contains("待核对") == true)
    }

    func testRecommendationEngineRejectsMappedExternalCandidates() throws {
        let externalCandidates = [
            ExternalSongCandidate(title: "七里香", artist: "周杰伦", source: .lastFM, confidence: 0.9, primaryGenreName: "Mandopop", releaseYear: 2004),
            ExternalSongCandidate(title: "十年", artist: "陈奕迅", source: .lastFM, confidence: 0.8, primaryGenreName: "Mandopop", releaseYear: 2003),
            ExternalSongCandidate(title: "小幸运", artist: "田馥甄", source: .lastFM, confidence: 0.75, primaryGenreName: "Mandopop", releaseYear: 2015)
        ]
        let catalog = externalCandidates.map { ExternalCandidateTrackMapper().map($0) }
        let matches = catalog.map { track in
            MatchResult(
                importedSong: ImportedSong(title: track.title, artist: track.artist, source: .plainText, confidence: 0.8),
                matchedTrack: track,
                alternatives: [],
                status: .alternative,
                score: 0.7,
                reason: "外部相似歌曲候选"
            )
        }
        let profile = PreferenceProfile(
            topArtists: [("周杰伦", 2)],
            languageDistribution: ["Mandarin": 1],
            eraDistribution: ["2000s": 1],
            genreDistribution: ["Mandopop": 1],
            moodTags: ["相似推荐": 1],
            sceneAffinity: [:],
            ktvMatchRate: 0.5,
            averageDifficulty: 3,
            averageSingAlongScore: 0.72,
            highNoteRisk: 0.5,
            summary: "外部相似歌曲候选"
        )
        let scenario = ScenarioConfig(scenario: .friends, durationMinutes: 45)
        let voice = VoiceProfile.simulatedMiddle

        let plan = try RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: profile,
            voiceProfile: voice,
            scenario: scenario,
            catalog: catalog,
            generationContext: makeRecommendationGenerationContext(
                matches: matches,
                scenario: scenario,
                voiceProfile: voice
            )
        )

        let formalItems = plan.sections.flatMap(\.items)
        let externalTitles = Set(externalCandidates.map(\.title))

        XCTAssertFalse(formalItems.contains { $0.track.id.hasPrefix("external:lastFM:") })
        XCTAssertTrue(Set(formalItems.map(\.track.title)).isDisjoint(with: externalTitles))
        XCTAssertEqual(plan.generationSummary?.formalPlanCount, formalItems.count)
    }
}

private final class StubDataFetcher: ExternalMusicDataFetching, @unchecked Sendable {
    private let data: Data
    private(set) var requestedURLs: [URL] = []

    init(data: Data) {
        self.data = data
    }

    func data(for url: URL) async throws -> Data {
        requestedURLs.append(url)
        return data
    }
}

private final class ExternalMusicURLProtocol: URLProtocol, @unchecked Sendable {
    static var responseData = Data()
    static var responseStatus = 200
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.responseStatus,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct StubSimilarSongProvider: SimilarSongProviding {
    let results: [String: [ExternalSongCandidate]]

    func similarSongs(for song: ImportedSong, limit: Int) async throws -> [ExternalSongCandidate] {
        Array((results[song.title] ?? []).prefix(limit))
    }
}

private struct PartiallyFailingSimilarSongProvider: SimilarSongProviding {
    func similarSongs(for song: ImportedSong, limit: Int) async throws -> [ExternalSongCandidate] {
        if song.title == "失败歌" {
            throw ExternalMusicError.missingArtist
        }
        return [
            ExternalSongCandidate(title: "可用相似歌", artist: "歌手A", source: .lastFM, confidence: 0.82)
        ]
    }
}

private struct AlwaysFailingSimilarSongProvider: SimilarSongProviding {
    func similarSongs(for song: ImportedSong, limit: Int) async throws -> [ExternalSongCandidate] {
        throw ExternalMusicError.httpStatus(503)
    }
}

private struct MissingArtistThenEmptySimilarSongProvider: SimilarSongProviding {
    func similarSongs(for song: ImportedSong, limit: Int) async throws -> [ExternalSongCandidate] {
        if song.artist == nil {
            throw ExternalMusicError.missingArtist
        }
        return []
    }
}

private actor RecordingSameArtistSongProvider: SimilarSongProviding {
    private(set) var requestedSongs: [ImportedSong] = []

    func similarSongs(for song: ImportedSong, limit: Int) async throws -> [ExternalSongCandidate] {
        requestedSongs.append(song)
        guard song.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ExternalMusicError.missingArtist
        }
        return []
    }
}

private struct StubMetadataResolver: SongMetadataResolving {
    let transform: @Sendable (ExternalSongCandidate) -> ExternalSongCandidate

    func enrich(_ candidate: ExternalSongCandidate) async throws -> ExternalSongCandidate {
        transform(candidate)
    }
}

private struct AlwaysFailingMetadataResolver: SongMetadataResolving {
    func enrich(_ candidate: ExternalSongCandidate) async throws -> ExternalSongCandidate {
        throw ExternalMusicError.httpStatus(503)
    }
}
