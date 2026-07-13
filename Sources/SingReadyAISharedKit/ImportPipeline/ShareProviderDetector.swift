import Foundation

public struct ShareProviderDetection: Equatable, Sendable {
    public let source: ImportSource
    public let confidence: Double
    public let reason: String

    public init(source: ImportSource, confidence: Double, reason: String) {
        self.source = source
        self.confidence = confidence
        self.reason = reason
    }
}

enum MusicShareHostRegistry {
    static let netEaseHosts: Set<String> = ["music.163.com", "y.music.163.com", "163cn.tv", "music.163cn.tv"]
    static let qqMusicHosts: Set<String> = ["y.qq.com", "i.y.qq.com", "c.y.qq.com", "qqmusic.qq.com"]
    static let appleMusicHosts: Set<String> = ["music.apple.com", "itunes.apple.com"]

    static func canonicalHost(for url: URL) -> String? {
        guard let host = url.host else { return nil }
        return canonicalHost(host)
    }

    static func canonicalHost(_ rawHost: String) -> String? {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, !host.hasPrefix(".") else { return nil }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty, !host.hasPrefix(".") else { return nil }
        return host
    }

    static func source(for url: URL) -> ImportSource? {
        source(
            for: url,
            netEaseHosts: netEaseHosts,
            qqMusicHosts: qqMusicHosts,
            appleMusicHosts: appleMusicHosts
        )
    }

    static func source(
        for url: URL,
        netEaseHosts: Set<String>,
        qqMusicHosts: Set<String>,
        appleMusicHosts: Set<String>
    ) -> ImportSource? {
        guard let host = canonicalHost(for: url) else { return nil }
        if matches(host, trustedHosts: netEaseHosts) {
            return .netEaseMusic
        }
        if matches(host, trustedHosts: qqMusicHosts) {
            return .qqMusic
        }
        if matches(host, trustedHosts: appleMusicHosts) {
            return .appleMusic
        }
        return nil
    }

    static func isDirectlyFetchable(_ url: URL) -> Bool {
        guard let source = source(for: url) else { return false }
        return source == .appleMusic || source == .netEaseMusic
    }

    private static func matches(_ host: String, trustedHosts: Set<String>) -> Bool {
        trustedHosts.compactMap(canonicalHost).contains { trustedHost in
            host == trustedHost || host.hasSuffix("." + trustedHost)
        }
    }
}

public struct ShareProviderDetector: Sendable {
    public static let defaultNetEaseHosts = MusicShareHostRegistry.netEaseHosts
    public static let defaultQQMusicHosts = MusicShareHostRegistry.qqMusicHosts
    public static let defaultAppleMusicHosts = MusicShareHostRegistry.appleMusicHosts

    public var netEaseHosts: Set<String>
    public var qqMusicHosts: Set<String>
    public var appleMusicHosts: Set<String>

    public init(
        netEaseHosts: Set<String> = ShareProviderDetector.defaultNetEaseHosts,
        qqMusicHosts: Set<String> = ShareProviderDetector.defaultQQMusicHosts,
        appleMusicHosts: Set<String> = ShareProviderDetector.defaultAppleMusicHosts
    ) {
        self.netEaseHosts = netEaseHosts
        self.qqMusicHosts = qqMusicHosts
        self.appleMusicHosts = appleMusicHosts
    }

    public func detect(payload: PendingImportPayload) -> ShareProviderDetection {
        if payload.imageFileName != nil {
            return ShareProviderDetection(source: .screenshot, confidence: 0.92, reason: "分享里有图片，先从截图里找歌名")
        }
        if let sourceFromURL = payload.urlString.flatMap(detectURL) {
            return sourceFromURL
        }
        if let text = payload.rawText, let sourceFromText = detectText(text) {
            return sourceFromText
        }
        if payload.urlString != nil {
            return ShareProviderDetection(source: .genericURL, confidence: 0.62, reason: "没认出音乐平台，先按普通链接试试")
        }
        if payload.rawText?.nilIfBlank != nil {
            return ShareProviderDetection(source: .plainText, confidence: 0.68, reason: "没看到平台链接，先按粘贴文本整理")
        }
        return ShareProviderDetection(source: .unknown, confidence: 0.2, reason: "没有看到文本、链接或图片")
    }

    public func detect(urlString: String) -> ShareProviderDetection {
        detectURL(urlString) ?? ShareProviderDetection(source: .genericURL, confidence: 0.62, reason: "没认出音乐平台，先按普通链接试试")
    }

    private func detectURL(_ urlString: String) -> ShareProviderDetection? {
        guard let url = URL(string: urlString),
              let source = MusicShareHostRegistry.source(
                  for: url,
                  netEaseHosts: netEaseHosts,
                  qqMusicHosts: qqMusicHosts,
                  appleMusicHosts: appleMusicHosts
              ) else {
            return nil
        }
        if source == .netEaseMusic {
            return ShareProviderDetection(source: .netEaseMusic, confidence: 0.96, reason: "这是网易云音乐链接")
        }
        if source == .qqMusic {
            return ShareProviderDetection(source: .qqMusic, confidence: 0.96, reason: "这是 QQ 音乐链接")
        }
        if source == .appleMusic {
            return ShareProviderDetection(source: .appleMusic, confidence: 0.94, reason: "这是 Apple Music 链接")
        }
        return nil
    }

    private func detectText(_ rawText: String) -> ShareProviderDetection? {
        let text = rawText.lowercased()
        if text.contains("music.163.com") || rawText.contains("网易云音乐") || text.contains("netease") {
            return ShareProviderDetection(source: .netEaseMusic, confidence: 0.9, reason: "文本里有网易云音乐内容")
        }
        if text.contains("y.qq.com") || rawText.contains("QQ音乐") || rawText.contains("QQ 音乐") {
            return ShareProviderDetection(source: .qqMusic, confidence: 0.9, reason: "文本里有 QQ 音乐内容")
        }
        if text.contains("music.apple.com") || rawText.contains("Apple Music") {
            return ShareProviderDetection(source: .appleMusic, confidence: 0.88, reason: "文本里有 Apple Music 内容")
        }
        let meaningfulLines = rawText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if meaningfulLines.count >= 2 {
            return ShareProviderDetection(source: .plainText, confidence: 0.72, reason: "文本里有几行歌名，可以先整理")
        }
        return nil
    }
}
