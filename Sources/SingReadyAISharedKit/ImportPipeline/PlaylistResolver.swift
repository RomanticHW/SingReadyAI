import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum PlaylistResolveError: Error, LocalizedError, Equatable {
    case unsupportedSource
    case emptyInput
    case invalidURL
    case webPageUnavailable
    case webPageHasNoSongs
    case webPageTooLarge
    case privatePlaylist
    case qqMusicRequiresShareText
    case qqMusicNeedsMoreSongText
    case unsupportedPublicWebHost
    case fixtureMissing(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSource: return "这个来源暂时还放不进来"
        case .emptyInput: return "没找到能整理的歌单内容"
        case .invalidURL: return "这个链接打不开，请检查后再试"
        case .webPageUnavailable: return "这个链接暂时读不出来，可以粘贴歌单文字或发截图"
        case .webPageHasNoSongs: return "这个链接里没找到歌名，可以粘贴歌单文字或发截图"
        case .webPageTooLarge: return "这个页面内容太多，可以改用粘贴文字或截图"
        case .privatePlaylist: return "这个歌单是私人歌单，公开链接无法读取；请复制歌曲文字或发截图"
        case .qqMusicRequiresShareText: return "QQ 音乐公开链接不能直接读取；请分享/粘贴歌名文字或发截图"
        case .qqMusicNeedsMoreSongText: return "QQ 音乐分享内容里只识别到一首歌；请再粘贴至少一首歌名，或发截图"
        case .unsupportedPublicWebHost: return "目前只直接读取 Apple Music 和网易云公开歌单；其他网页请粘贴歌名文字或发截图"
        case .fixtureMissing: return "这份内置歌单暂时打不开"
        case let .parseFailed(reason): return "这份歌单暂时没整理出来：\(reason)"
        }
    }
}

public protocol PlaylistResolving: Sendable {
    var source: ImportSource { get }
    func canResolve(payload: PendingImportPayload) -> Bool
    func resolve(payload: PendingImportPayload) async throws -> ImportedPlaylist
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
        let playlist = parser.parse(rawText: rawText, source: source, title: payload.displayTitle ?? "导入歌单")
        guard !playlist.songs.isEmpty else {
            throw PlaylistResolveError.emptyInput
        }
        return playlist
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

    public func parseValidated(
        recognizedText: String,
        title: String = "截图识别歌单"
    ) throws -> ImportedPlaylist {
        let playlist = parse(recognizedText: recognizedText, title: title)
        guard !playlist.songs.isEmpty else {
            throw OCRServiceError.noTextRecognized
        }
        return playlist
    }
}

public protocol PlaylistPageFetching: Sendable {
    func pageText(for url: URL) async throws -> String
}

public struct PublicWebURLPolicy: Sendable {
    public init() {}

    public func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https",
              url.user == nil,
              url.password == nil,
              let rawHost = url.host?.nilIfBlank else {
            return false
        }

        let lowercasedHost = rawHost.lowercased()
        guard !lowercasedHost.hasPrefix(".") else { return false }
        var host = lowercasedHost
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty,
              !host.hasPrefix("."),
              !host.contains("%"),
              host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal") else {
            return false
        }

        if let address = IPv4Address(host) {
            return address.isPublic
        }
        if let address = IPv6Address(host) {
            return address.isPublic
        }
        return host.contains(".")
    }

}

private struct IPv4Address {
    let bytes: [UInt8]

    init?(_ host: String) {
        #if canImport(Darwin)
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return nil }
        self.bytes = withUnsafeBytes(of: address) { Array($0) }
        #else
        return nil
        #endif
    }

    init(bytes: ArraySlice<UInt8>) {
        self.bytes = Array(bytes)
    }

    var isPublic: Bool {
        guard bytes.count == 4 else { return false }
        let first = bytes[0]
        let second = bytes[1]
        let third = bytes[2]

        if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
        if first == 100, (64...127).contains(second) { return false }
        if first == 169, second == 254 { return false }
        if first == 172, (16...31).contains(second) { return false }
        if first == 192, second == 168 { return false }
        if first == 192, second == 0, (third == 0 || third == 2) { return false }
        if first == 192, second == 88, third == 99 { return false }
        if first == 198, (second == 18 || second == 19) { return false }
        if first == 198, second == 51, third == 100 { return false }
        if first == 203, second == 0, third == 113 { return false }
        return true
    }

}

private struct IPv6Address {
    let bytes: [UInt8]

    init?(_ host: String) {
        #if canImport(Darwin)
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
        self.bytes = withUnsafeBytes(of: address) { Array($0) }
        #else
        return nil
        #endif
    }

    var isPublic: Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return false }

        let isIPv4Mapped = bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff
        let isIPv4Compatible = bytes.prefix(12).allSatisfy({ $0 == 0 })
        if isIPv4Mapped || isIPv4Compatible {
            return false
        }

        let isWellKnownNAT64 = bytes.prefix(12).elementsEqual([
            0x00, 0x64, 0xff, 0x9b,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00
        ])
        if isWellKnownNAT64 {
            return IPv4Address(bytes: bytes.suffix(4)).isPublic
        }

        guard bytes[0] & 0xe0 == 0x20 else { return false }
        if isIETFProtocolAssignment {
            return isGloballyReachableIETFProtocolAssignment
        }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0d, bytes[3] == 0xb8 { return false }
        if bytes[0] == 0x20, bytes[1] == 0x02 { return false }
        if bytes[0] == 0x3f, bytes[1] & 0xf0 == 0xf0 { return false }
        return true
    }

    private var isIETFProtocolAssignment: Bool {
        bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] & 0xfe == 0
    }

    private var isGloballyReachableIETFProtocolAssignment: Bool {
        let isAnycastHost = bytes[2] == 0 &&
            bytes[3] == 1 &&
            bytes[4..<15].allSatisfy({ $0 == 0 }) &&
            (1...3).contains(bytes[15])
        let isAMT = bytes[2] == 0 && bytes[3] == 3
        let isAS112 = bytes[2] == 0 && bytes[3] == 4 && bytes[4] == 1 && bytes[5] == 0x12
        let isORCHIDv2 = bytes[2] == 0 && bytes[3] & 0xf0 == 0x20
        let isDroneRemoteID = bytes[2] == 0 && bytes[3] & 0xf0 == 0x30
        return isAnycastHost || isAMT || isAS112 || isORCHIDv2 || isDroneRemoteID
    }
}

public struct PlaylistPageDataResponse: @unchecked Sendable {
    public let data: Data
    public let response: URLResponse

    public init(data: Data, response: URLResponse) {
        self.data = data
        self.response = response
    }
}

public protocol PlaylistPageDataLoading: Sendable {
    func data(
        for request: URLRequest,
        maximumBytes: Int,
        urlPolicy: PublicWebURLPolicy
    ) async throws -> PlaylistPageDataResponse
}

public struct URLSessionPlaylistPageDataLoader: PlaylistPageDataLoading, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    public func data(
        for request: URLRequest,
        maximumBytes: Int,
        urlPolicy: PublicWebURLPolicy
    ) async throws -> PlaylistPageDataResponse {
        guard let url = request.url,
              urlPolicy.allows(url),
              MusicShareHostRegistry.isDirectlyFetchable(url) else {
            throw PlaylistResolveError.invalidURL
        }
        let delegate = BoundedPlaylistPageSessionDelegate(
            maximumBytes: maximumBytes,
            urlPolicy: urlPolicy
        )
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await delegate.load(request: request, session: session)
    }
}

private enum PlaylistPageContentKind {
    case html
    case plainText
    case sniff
}

private enum PlaylistPageResponseValidator {
    static func validateHeaders(
        _ response: URLResponse,
        maximumBytes: Int,
        urlPolicy: PublicWebURLPolicy
    ) throws -> PlaylistPageContentKind {
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PlaylistResolveError.webPageUnavailable
        }
        guard let responseURL = httpResponse.url,
              urlPolicy.allows(responseURL),
              MusicShareHostRegistry.isDirectlyFetchable(responseURL) else {
            throw PlaylistResolveError.invalidURL
        }
        if httpResponse.expectedContentLength > Int64(maximumBytes) {
            throw PlaylistResolveError.webPageTooLarge
        }

        guard let mimeType = httpResponse.mimeType?.lowercased().nilIfBlank else {
            return .sniff
        }
        switch mimeType {
        case "text/html", "application/xhtml+xml":
            return .html
        case "text/plain":
            return .plainText
        default:
            throw PlaylistResolveError.webPageUnavailable
        }
    }

    static func validateBody(
        _ data: Data,
        maximumBytes: Int,
        contentKind: PlaylistPageContentKind
    ) throws -> PlaylistPageContentKind {
        guard data.count <= maximumBytes else {
            throw PlaylistResolveError.webPageTooLarge
        }
        guard !data.isEmpty else {
            throw PlaylistResolveError.webPageUnavailable
        }
        guard contentKind == .sniff else { return contentKind }
        guard isPlausibleUTF8Text(data) else {
            throw PlaylistResolveError.webPageUnavailable
        }
        let prefix = String(decoding: data.prefix(512), as: UTF8.self)
        return prefix.localizedCaseInsensitiveContains("<html") || prefix.localizedCaseInsensitiveContains("<!doctype html")
            ? .html
            : .plainText
    }

    private static func isPlausibleUTF8Text(_ data: Data) -> Bool {
        guard String(data: data, encoding: .utf8) != nil else { return false }
        let sample = data.prefix(1_024)
        guard !sample.contains(0) else { return false }
        let invalidControlCount = sample.reduce(into: 0) { count, byte in
            if byte < 0x20, byte != 0x09, byte != 0x0a, byte != 0x0d {
                count += 1
            }
        }
        return invalidControlCount * 100 <= max(sample.count, 1)
    }
}

final class BoundedPlaylistPageSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let urlPolicy: PublicWebURLPolicy
    private let lock = NSLock()

    private var continuation: CheckedContinuation<PlaylistPageDataResponse, Error>?
    private var activeTask: URLSessionDataTask?
    private var receivedData = Data()
    private var receivedResponse: URLResponse?
    private var finished = false

    private struct CompletionClaim {
        let continuation: CheckedContinuation<PlaylistPageDataResponse, Error>?
        let activeTask: URLSessionDataTask?
    }

    init(
        maximumBytes: Int,
        urlPolicy: PublicWebURLPolicy
    ) {
        self.maximumBytes = max(1, maximumBytes)
        self.urlPolicy = urlPolicy
    }

    var bufferedByteCount: Int {
        lock.withLock { receivedData.count }
    }

    func load(request: URLRequest, session: URLSession) async throws -> PlaylistPageDataResponse {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let shouldStart = lock.withLock { () -> Bool in
                    guard !finished else { return false }
                    self.continuation = continuation
                    activeTask = task
                    return true
                }
                guard shouldStart else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if Task.isCancelled {
                    cancelForTaskCancellation()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.cancelForTaskCancellation()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let normalizedRequest = PlaylistRedirectNormalizer().normalize(
            proposedRequest: request,
            currentRequest: task.currentRequest
        )
        guard let redirectedURL = normalizedRequest.url else {
            rejectRedirect(task: task, completionHandler: completionHandler, error: PlaylistResolveError.invalidURL)
            return
        }
        guard urlPolicy.allows(redirectedURL),
              MusicShareHostRegistry.isDirectlyFetchable(redirectedURL) else {
            rejectRedirect(task: task, completionHandler: completionHandler, error: PlaylistResolveError.invalidURL)
            return
        }
        completionHandler(normalizedRequest)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            _ = try PlaylistPageResponseValidator.validateHeaders(
                response,
                maximumBytes: maximumBytes,
                urlPolicy: urlPolicy
            )
            lock.withLock {
                receivedResponse = response
            }
            completionHandler(.allow)
        } catch {
            let claim = claimCompletion()
            completionHandler(.cancel)
            dataTask.cancel()
            claim?.continuation?.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceededLimit = lock.withLock { () -> Bool in
            guard !finished else { return false }
            guard data.count <= maximumBytes,
                  receivedData.count <= maximumBytes - data.count else {
                return true
            }
            receivedData.append(data)
            return false
        }
        guard exceededLimit else { return }
        let claim = claimCompletion()
        dataTask.cancel()
        claim?.continuation?.resume(throwing: PlaylistResolveError.webPageTooLarge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        let result = lock.withLock { () -> PlaylistPageDataResponse? in
            guard let receivedResponse else { return nil }
            return PlaylistPageDataResponse(data: receivedData, response: receivedResponse)
        }
        guard let result else {
            finish(.failure(PlaylistResolveError.webPageUnavailable))
            return
        }
        finish(.success(result))
    }

    private func cancelForTaskCancellation() {
        guard let claim = claimCompletion() else { return }
        claim.activeTask?.cancel()
        claim.continuation?.resume(throwing: CancellationError())
    }

    private func rejectRedirect(
        task: URLSessionTask,
        completionHandler: @escaping (URLRequest?) -> Void,
        error: Error
    ) {
        let claim = claimCompletion()
        completionHandler(nil)
        task.cancel()
        claim?.continuation?.resume(throwing: error)
    }

    private func finish(_ result: Result<PlaylistPageDataResponse, Error>) {
        claimCompletion()?.continuation?.resume(with: result)
    }

    private func claimCompletion() -> CompletionClaim? {
        lock.withLock {
            guard !finished else { return nil }
            finished = true
            let claim = CompletionClaim(
                continuation: continuation,
                activeTask: activeTask
            )
            self.continuation = nil
            activeTask = nil
            return claim
        }
    }
}

public struct URLSessionPlaylistPageFetcher: PlaylistPageFetching {
    private let maximumBytes: Int
    private let loader: any PlaylistPageDataLoading
    private let urlPolicy: PublicWebURLPolicy

    public init(
        maximumBytes: Int = 2_000_000,
        loader: any PlaylistPageDataLoading = URLSessionPlaylistPageDataLoader(),
        urlPolicy: PublicWebURLPolicy = PublicWebURLPolicy()
    ) {
        self.maximumBytes = max(1, maximumBytes)
        self.loader = loader
        self.urlPolicy = urlPolicy
    }

    public func pageText(for url: URL) async throws -> String {
        guard urlPolicy.allows(url) else {
            throw PlaylistResolveError.invalidURL
        }
        guard MusicShareHostRegistry.isDirectlyFetchable(url) else {
            throw PlaylistResolveError.unsupportedPublicWebHost
        }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml;q=0.9,text/plain;q=0.8", forHTTPHeaderField: "Accept")

        let result = try await loader.data(
            for: request,
            maximumBytes: maximumBytes,
            urlPolicy: urlPolicy
        )
        let data = result.data
        let response = result.response
        try Task.checkCancellation()
        let headerKind = try PlaylistPageResponseValidator.validateHeaders(
            response,
            maximumBytes: maximumBytes,
            urlPolicy: urlPolicy
        )
        let contentKind = try PlaylistPageResponseValidator.validateBody(
            data,
            maximumBytes: maximumBytes,
            contentKind: headerKind
        )
        if contentKind == .html {
            return try htmlText(from: data)
        }
        guard let text = String(data: data, encoding: .utf8)?.nilIfBlank else {
            throw PlaylistResolveError.webPageUnavailable
        }
        return text
    }

    private func htmlText(from data: Data) throws -> String {
        try PlaylistPageTextExtractor().text(fromHTMLData: data)
    }
}

public struct PlaylistPageTextExtractor: Sendable {
    public init() {}

    public func text(fromHTMLData data: Data) throws -> String {
        if let structured = try netEasePlaylistText(from: data) {
            return structured
        }
        if let structured = try AppleMusicPlaylistPageParser().playlistText(from: data) {
            return structured
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw PlaylistResolveError.webPageUnavailable
        }
        guard let text = LocalHTMLTextExtractor().text(from: html).nilIfBlank else {
            throw PlaylistResolveError.webPageHasNoSongs
        }
        return text
    }

    private func netEasePlaylistText(from data: Data) throws -> String? {
        guard let html = String(data: data, encoding: .utf8),
              let marker = html.range(of: "window.REDUX_STATE = ") else {
            return nil
        }
        let suffix = html[marker.upperBound...]
        let endCandidates = [";</script>", ";\n", ";\r"]
            .compactMap { suffix.range(of: $0)?.lowerBound }
        guard let end = endCandidates.min(), end > suffix.startIndex else {
            return nil
        }
        let jsonData = Data(suffix[..<end].utf8)
        guard let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let playlist = root["Playlist"] as? [String: Any] else {
            return nil
        }
        let responseCode = (playlist["code"] as? NSNumber)?.intValue
            ?? Int(playlist["code"] as? String ?? "")
        if responseCode == 401 {
            throw PlaylistResolveError.privatePlaylist
        }
        guard let rawSongs = playlist["data"] as? [[String: Any]] else { return nil }
        let lines = rawSongs.compactMap { song -> String? in
            guard let title = (song["songName"] as? String)?.nilIfBlank,
                  let artist = (song["singerName"] as? String)?.nilIfBlank else {
                return nil
            }
            return "\(title) - \(artist)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

private struct LocalHTMLTextExtractor {
    private static let blockSeparator: Character = "\u{E000}"
    private static let hiddenElements: Set<String> = [
        "head", "noscript", "script", "style", "template"
    ]
    private static let blockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "br", "dd", "div", "dl", "dt",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4",
        "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section",
        "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul"
    ]
    private static let namedEntities: [String: Character] = [
        "amp": "&",
        "apos": "'",
        "bull": "•",
        "gt": ">",
        "hellip": "…",
        "laquo": "«",
        "ldquo": "“",
        "lsquo": "‘",
        "lt": "<",
        "mdash": "—",
        "middot": "·",
        "nbsp": " ",
        "ndash": "–",
        "quot": "\"",
        "raquo": "»",
        "rdquo": "”",
        "rsquo": "’"
    ]

    func text(from html: String) -> String {
        var output = String()
        output.reserveCapacity(html.count)
        var cursor = html.startIndex
        var hiddenElement: String?

        while cursor < html.endIndex {
            if let activeHiddenElement = hiddenElement {
                guard let closingRange = html.range(
                    of: "</\(activeHiddenElement)",
                    options: [.caseInsensitive],
                    range: cursor..<html.endIndex
                ) else {
                    break
                }
                cursor = closingRange.lowerBound
            }

            guard html[cursor] == "<" else {
                output.append(html[cursor])
                cursor = html.index(after: cursor)
                continue
            }

            if html[cursor...].hasPrefix("<!--") {
                guard let commentEnd = html.range(
                    of: "-->",
                    range: html.index(cursor, offsetBy: 4)..<html.endIndex
                ) else {
                    break
                }
                cursor = commentEnd.upperBound
                continue
            }

            guard let tag = tag(at: cursor, in: html) else {
                if hiddenElement == nil {
                    output.append("<")
                }
                cursor = html.index(after: cursor)
                continue
            }
            cursor = tag.endIndex

            if let activeHiddenElement = hiddenElement {
                if tag.isClosing, tag.name == activeHiddenElement {
                    self.appendBlockSeparator(to: &output)
                    hiddenElement = nil
                }
                continue
            }

            if !tag.isClosing,
               !tag.isSelfClosing,
               Self.hiddenElements.contains(tag.name) {
                hiddenElement = tag.name
                continue
            }
            if Self.blockElements.contains(tag.name) {
                appendBlockSeparator(to: &output)
            }
        }

        return normalize(decodeEntities(in: output))
    }

    private func tag(at startIndex: String.Index, in html: String) -> HTMLTag? {
        var cursor = html.index(after: startIndex)
        var quote: Character?
        var endIndex: String.Index?
        while cursor < html.endIndex {
            let character = html[cursor]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                endIndex = html.index(after: cursor)
                break
            }
            cursor = html.index(after: cursor)
        }
        guard let endIndex else { return nil }

        var contentCursor = html.index(after: startIndex)
        let contentEnd = html.index(before: endIndex)
        skipWhitespace(in: html, cursor: &contentCursor, before: contentEnd)
        let isClosing = contentCursor < contentEnd && html[contentCursor] == "/"
        if isClosing {
            contentCursor = html.index(after: contentCursor)
            skipWhitespace(in: html, cursor: &contentCursor, before: contentEnd)
        }

        let nameStart = contentCursor
        while contentCursor < contentEnd, isTagNameCharacter(html[contentCursor]) {
            contentCursor = html.index(after: contentCursor)
        }
        let name = String(html[nameStart..<contentCursor]).lowercased()

        var trailingCursor = contentEnd
        while trailingCursor > startIndex {
            let previous = html.index(before: trailingCursor)
            guard html[previous].isWhitespace else { break }
            trailingCursor = previous
        }
        let isSelfClosing = trailingCursor > startIndex
            && html[html.index(before: trailingCursor)] == "/"

        return HTMLTag(
            name: name,
            isClosing: isClosing,
            isSelfClosing: isSelfClosing,
            endIndex: endIndex
        )
    }

    private func skipWhitespace(
        in html: String,
        cursor: inout String.Index,
        before endIndex: String.Index
    ) {
        while cursor < endIndex, html[cursor].isWhitespace {
            cursor = html.index(after: cursor)
        }
    }

    private func isTagNameCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == ":"
        }
    }

    private func appendBlockSeparator(to output: inout String) {
        guard output.last != Self.blockSeparator else { return }
        output.append(Self.blockSeparator)
    }

    private func decodeEntities(in value: String) -> String {
        var output = String()
        output.reserveCapacity(value.count)
        var cursor = value.startIndex

        while cursor < value.endIndex {
            guard value[cursor] == "&" else {
                output.append(value[cursor])
                cursor = value.index(after: cursor)
                continue
            }

            let entityStart = value.index(after: cursor)
            var entityEnd = entityStart
            var semicolon: String.Index?
            for _ in 0..<32 where entityEnd < value.endIndex {
                if value[entityEnd] == ";" {
                    semicolon = entityEnd
                    break
                }
                entityEnd = value.index(after: entityEnd)
            }
            guard let semicolon,
                  let decoded = decodedEntity(String(value[entityStart..<semicolon])) else {
                output.append("&")
                cursor = entityStart
                continue
            }
            output.append(decoded)
            cursor = value.index(after: semicolon)
        }
        return output
    }

    private func decodedEntity(_ entity: String) -> Character? {
        if let named = Self.namedEntities[entity.lowercased()] {
            return named
        }
        let scalarValue: UInt32?
        if entity.lowercased().hasPrefix("#x") {
            scalarValue = UInt32(entity.dropFirst(2), radix: 16)
        } else if entity.hasPrefix("#") {
            scalarValue = UInt32(entity.dropFirst(), radix: 10)
        } else {
            scalarValue = nil
        }
        guard let scalarValue,
              scalarValue != 0,
              let scalar = UnicodeScalar(scalarValue) else {
            return nil
        }
        return Character(scalar)
    }

    private func normalize(_ value: String) -> String {
        value
            .split(separator: Self.blockSeparator, omittingEmptySubsequences: true)
            .map { segment in
                segment
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

private struct HTMLTag {
    let name: String
    let isClosing: Bool
    let isSelfClosing: Bool
    let endIndex: String.Index
}

public struct PublicWebPlaylistResolver: PlaylistResolving {
    public let source: ImportSource = .genericURL
    private let parser: PlainTextPlaylistParser
    private let fetcher: any PlaylistPageFetching

    public init(
        parser: PlainTextPlaylistParser = PlainTextPlaylistParser(),
        fetcher: any PlaylistPageFetching = URLSessionPlaylistPageFetcher()
    ) {
        self.parser = parser
        self.fetcher = fetcher
    }

    public func canResolve(payload: PendingImportPayload) -> Bool {
        payload.urlString?.nilIfBlank != nil
    }

    public func resolve(payload: PendingImportPayload) async throws -> ImportedPlaylist {
        guard let urlString = payload.urlString?.nilIfBlank,
              let url = URL(string: urlString),
              PublicWebURLPolicy().allows(url) else {
            throw PlaylistResolveError.invalidURL
        }
        let sourceFromHost = MusicShareHostRegistry.source(for: url)
        if sourceFromHost == .qqMusic {
            if let rawText = payload.rawText?.nilIfBlank,
               let playlist = parsedPlaylist(
                   rawText: rawText,
                   source: .qqMusic,
                   title: payload.displayTitle ?? ImportSource.qqMusic.displayName,
                   externalURL: url,
                   keepsTitleOnlySongs: true
               ) {
                if playlist.songs.count >= 2 {
                    return playlist
                }
                throw PlaylistResolveError.qqMusicNeedsMoreSongText
            }
            throw PlaylistResolveError.qqMusicRequiresShareText
        }
        guard let detectedSource = sourceFromHost,
              detectedSource == .appleMusic || detectedSource == .netEaseMusic else {
            throw PlaylistResolveError.unsupportedPublicWebHost
        }
        do {
            let pageText = try await fetcher.pageText(for: url)
            guard let playlist = parsedPlaylist(
                rawText: pageText,
                source: detectedSource,
                title: payload.displayTitle ?? detectedSource.displayName,
                externalURL: url
            ) else {
                throw PlaylistResolveError.webPageHasNoSongs
            }
            return playlist
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PlaylistResolveError where error == .invalidURL {
            throw error
        } catch {
            if payload.sourceHint != .qqMusic,
               let rawText = payload.rawText?.nilIfBlank,
               let fallback = parsedPlaylist(
                   rawText: rawText,
                   source: detectedSource,
                   title: payload.displayTitle ?? detectedSource.displayName,
                   externalURL: url,
                   keepsTitleOnlySongs: true
               ) {
                return fallback
            }
            if let resolveError = error as? PlaylistResolveError {
                throw resolveError
            }
            throw PlaylistResolveError.webPageUnavailable
        }
    }

    private func parsedPlaylist(
        rawText: String,
        source: ImportSource,
        title: String,
        externalURL: URL,
        keepsTitleOnlySongs: Bool = false
    ) -> ImportedPlaylist? {
        let playlist = parser.parse(
            rawText: rawText,
            source: source,
            title: title
        )
        let songs = playlist.songs.filter {
            keepsTitleOnlySongs || $0.artist != nil || $0.confidence >= 0.72
        }
        guard !songs.isEmpty else { return nil }
        return ImportedPlaylist(
            id: playlist.id,
            source: playlist.source,
            title: playlist.title,
            externalURL: externalURL,
            songs: songs,
            createdAt: playlist.createdAt,
            parseConfidence: songs.map(\.confidence).reduce(0, +) / Double(songs.count)
        )
    }
}

public struct ImportCoordinator: Sendable {
    private let detector: ShareProviderDetector
    private let resolvers: [any PlaylistResolving]

    public init(
        detector: ShareProviderDetector = ShareProviderDetector(),
        resolvers: [any PlaylistResolving] = [
            PublicWebPlaylistResolver(),
            PlainTextPlaylistResolver()
        ]
    ) {
        self.detector = detector
        self.resolvers = resolvers
    }

    public func resolve(payload: PendingImportPayload) async throws -> ImportedPlaylist {
        var enriched = promotedLinkPayload(from: payload)
        let detected = detector.detect(payload: enriched)
        enriched.sourceHint = detected.source
        if let resolver = resolvers.first(where: { $0.canResolve(payload: enriched) }) {
            return try await resolver.resolve(payload: enriched)
        }
        throw PlaylistResolveError.unsupportedSource
    }

    private func promotedLinkPayload(from payload: PendingImportPayload) -> PendingImportPayload {
        guard payload.urlString?.nilIfBlank == nil,
              let text = payload.rawText?.nilIfBlank,
              text.count <= 2_048,
              text.components(separatedBy: .newlines).filter({ $0.nilIfBlank != nil }).count <= 3,
              let urlString = firstWebURL(in: text) else {
            return payload
        }
        var promoted = payload
        promoted.urlString = urlString
        return promoted
    }

    private func firstWebURL(in text: String) -> String? {
        let trimSet = CharacterSet(charactersIn: "，。,:：；;()（）[]【】\"'")
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: trimSet) }
            .first { value in
                guard let url = URL(string: value) else { return false }
                return PublicWebURLPolicy().allows(url)
            }
    }

    public func resolveDemoPlaylist() throws -> ImportedPlaylist {
        var playlist = try FixturePlaylistLoader.loadPlaylist(
            named: "fixtures_netease_playlist",
            fallbackSource: .demo
        )
        playlist.id = UUID(uuidString: "53494E47-5245-4144-8000-000000000001")!
        return playlist
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
