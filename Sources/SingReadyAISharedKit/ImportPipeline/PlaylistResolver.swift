import Foundation

public enum PlaylistResolveError: Error, LocalizedError, Equatable {
    case unsupportedSource
    case emptyInput
    case fixtureMissing(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSource: return "暂不支持该来源"
        case .emptyInput: return "没有可解析的导入内容"
        case let .fixtureMissing(name): return "缺少 fixture：\(name)"
        case let .parseFailed(reason): return "歌单解析失败：\(reason)"
        }
    }
}

public protocol PlaylistResolving: Sendable {
    var source: ImportSource { get }
    func canResolve(payload: PendingImportPayload) -> Bool
    func resolve(payload: PendingImportPayload) async throws -> ImportedPlaylist
}

public struct MockNetEasePlaylistResolver: PlaylistResolving {
    public let source: ImportSource = .netEaseMusic

    public init() {}

    public func canResolve(payload: PendingImportPayload) -> Bool {
        payload.sourceHint == .netEaseMusic || payload.urlString?.contains("music.163") == true
    }

    public func resolve(payload: PendingImportPayload) async throws -> ImportedPlaylist {
        try FixturePlaylistLoader.loadPlaylist(named: "fixtures_netease_playlist", fallbackSource: .netEaseMusic)
    }
}

public struct MockQQMusicPlaylistResolver: PlaylistResolving {
    public let source: ImportSource = .qqMusic

    public init() {}

    public func canResolve(payload: PendingImportPayload) -> Bool {
        payload.sourceHint == .qqMusic || payload.urlString?.contains("qq.com") == true
    }

    public func resolve(payload: PendingImportPayload) async throws -> ImportedPlaylist {
        try FixturePlaylistLoader.loadPlaylist(named: "fixtures_qqmusic_playlist", fallbackSource: .qqMusic)
    }
}

public struct PlainTextPlaylistResolver: PlaylistResolving {
    public let source: ImportSource = .plainText
    private let parser: PlainTextPlaylistParser

    public init(parser: PlainTextPlaylistParser = PlainTextPlaylistParser()) {
        self.parser = parser
    }

    public func canResolve(payload: PendingImportPayload) -> Bool {
        payload.rawText?.nilIfBlank != nil
    }

    public func resolve(payload: PendingImportPayload) async throws -> ImportedPlaylist {
        guard let rawText = payload.rawText?.nilIfBlank else {
            throw PlaylistResolveError.emptyInput
        }
        let source = payload.sourceHint == .screenshot ? ImportSource.screenshot : .plainText
        return parser.parse(rawText: rawText, source: source, title: payload.displayTitle ?? "导入歌单")
    }
}

public struct OCRPlaylistParser: Sendable {
    private let parser: PlainTextPlaylistParser

    public init(parser: PlainTextPlaylistParser = PlainTextPlaylistParser()) {
        self.parser = parser
    }

    public func parse(recognizedText: String, title: String = "截图识别歌单") -> ImportedPlaylist {
        parser.parse(rawText: recognizedText, source: .screenshot, title: title)
    }
}

public struct GenericURLMetadataResolver: PlaylistResolving {
    public let source: ImportSource = .genericURL
    private let parser: PlainTextPlaylistParser

    public init(parser: PlainTextPlaylistParser = PlainTextPlaylistParser()) {
        self.parser = parser
    }

    public func canResolve(payload: PendingImportPayload) -> Bool {
        payload.urlString?.nilIfBlank != nil || payload.rawText?.nilIfBlank != nil
    }

    public func resolve(payload: PendingImportPayload) async throws -> ImportedPlaylist {
        let title = payload.displayTitle ?? "链接导入歌单"
        if let rawText = payload.rawText?.nilIfBlank {
            return parser.parse(rawText: rawText, source: .genericURL, title: title)
        }
        return ImportedPlaylist(source: .genericURL, title: title, externalURL: payload.urlString.flatMap(URL.init(string:)), songs: [], parseConfidence: 0.35)
    }
}

public struct ImportCoordinator: Sendable {
    private let detector: ShareProviderDetector
    private let resolvers: [any PlaylistResolving]

    public init(
        detector: ShareProviderDetector = ShareProviderDetector(),
        resolvers: [any PlaylistResolving] = [
            MockNetEasePlaylistResolver(),
            MockQQMusicPlaylistResolver(),
            PlainTextPlaylistResolver(),
            GenericURLMetadataResolver()
        ]
    ) {
        self.detector = detector
        self.resolvers = resolvers
    }

    public func resolve(payload: PendingImportPayload) async throws -> ImportedPlaylist {
        let detected = detector.detect(payload: payload)
        var enriched = payload
        enriched.sourceHint = detected.source
        if detected.source == .netEaseMusic, let resolver = resolvers.first(where: { $0.source == .netEaseMusic }) {
            return try await resolver.resolve(payload: enriched)
        }
        if detected.source == .qqMusic, let resolver = resolvers.first(where: { $0.source == .qqMusic }) {
            return try await resolver.resolve(payload: enriched)
        }
        if let resolver = resolvers.first(where: { $0.canResolve(payload: enriched) }) {
            return try await resolver.resolve(payload: enriched)
        }
        throw PlaylistResolveError.unsupportedSource
    }

    public func resolveDemoPlaylist() throws -> ImportedPlaylist {
        try FixturePlaylistLoader.loadPlaylist(named: "fixtures_netease_playlist", fallbackSource: .demo)
    }
}

enum FixturePlaylistLoader {
    struct PlaylistFixture: Decodable {
        let title: String
        let source: ImportSource?
        let songs: [SongFixture]
    }

    struct SongFixture: Decodable {
        let title: String
        let artist: String?
    }

    static func loadPlaylist(named name: String, fallbackSource: ImportSource) throws -> ImportedPlaylist {
        let data = try FixtureLoader.loadData(named: name, extension: "json")
        let fixture = try JSONDecoder().decode(PlaylistFixture.self, from: data)
        let source = fixture.source ?? fallbackSource
        let songs = fixture.songs.map {
            ImportedSong(title: $0.title, artist: $0.artist, source: source, rawText: "\($0.title) - \($0.artist ?? "")", confidence: 0.98)
        }
        return ImportedPlaylist(source: source, title: fixture.title, songs: songs, parseConfidence: 0.98)
    }
}

public enum FixtureLoader {
    public static func loadData(named name: String, `extension`: String) throws -> Data {
        let bundle = Bundle.module
        let candidates = [
            bundle.url(forResource: name, withExtension: `extension`),
            bundle.url(forResource: name, withExtension: `extension`, subdirectory: "Fixtures"),
            bundle.url(forResource: name, withExtension: `extension`, subdirectory: "Resources/Fixtures")
        ]
        guard let url = candidates.compactMap({ $0 }).first else {
            throw PlaylistResolveError.fixtureMissing("\(name).\(`extension`)")
        }
        return try Data(contentsOf: url)
    }
}
