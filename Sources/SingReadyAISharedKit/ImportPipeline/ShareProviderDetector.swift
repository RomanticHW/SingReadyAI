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

public struct ShareProviderDetector: Sendable {
    public var netEaseHosts: Set<String>
    public var qqMusicHosts: Set<String>
    public var appleMusicHosts: Set<String>

    public init(
        netEaseHosts: Set<String> = ["music.163.com", "y.music.163.com", "163cn.tv", "music.163cn.tv"],
        qqMusicHosts: Set<String> = ["y.qq.com", "i.y.qq.com", "c.y.qq.com", "qqmusic.qq.com"],
        appleMusicHosts: Set<String> = ["music.apple.com", "itunes.apple.com"]
    ) {
        self.netEaseHosts = netEaseHosts
        self.qqMusicHosts = qqMusicHosts
        self.appleMusicHosts = appleMusicHosts
    }

    public func detect(payload: PendingImportPayload) -> ShareProviderDetection {
        if payload.imageFileName != nil {
            return ShareProviderDetection(source: .screenshot, confidence: 0.92, reason: "分享内容包含图片，按截图识别处理")
        }
        if let sourceFromURL = payload.urlString.flatMap(detectURL) {
            return sourceFromURL
        }
        if let text = payload.rawText, let sourceFromText = detectText(text) {
            return sourceFromText
        }
        if payload.urlString != nil {
            return ShareProviderDetection(source: .genericURL, confidence: 0.62, reason: "未识别为已知音乐平台，按普通链接处理")
        }
        if payload.rawText?.nilIfBlank != nil {
            return ShareProviderDetection(source: .plainText, confidence: 0.68, reason: "未识别到平台链接，按粘贴歌单文本处理")
        }
        return ShareProviderDetection(source: .unknown, confidence: 0.2, reason: "没有可解析的文本、链接或图片")
    }

    public func detect(urlString: String) -> ShareProviderDetection {
        detectURL(urlString) ?? ShareProviderDetection(source: .genericURL, confidence: 0.62, reason: "未识别为已知音乐平台，按普通链接处理")
    }

    private func detectURL(_ urlString: String) -> ShareProviderDetection? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else {
            return nil
        }
        if hostMatches(host, in: netEaseHosts) {
            return ShareProviderDetection(source: .netEaseMusic, confidence: 0.96, reason: "链接 host 命中网易云音乐")
        }
        if hostMatches(host, in: qqMusicHosts) {
            return ShareProviderDetection(source: .qqMusic, confidence: 0.96, reason: "链接 host 命中 QQ 音乐")
        }
        if hostMatches(host, in: appleMusicHosts) {
            return ShareProviderDetection(source: .appleMusic, confidence: 0.94, reason: "链接 host 命中 Apple Music")
        }
        return nil
    }

    private func detectText(_ rawText: String) -> ShareProviderDetection? {
        let text = rawText.lowercased()
        if text.contains("music.163.com") || rawText.contains("网易云音乐") || text.contains("netease") {
            return ShareProviderDetection(source: .netEaseMusic, confidence: 0.9, reason: "分享文本包含网易云音乐特征")
        }
        if text.contains("y.qq.com") || rawText.contains("QQ音乐") || rawText.contains("QQ 音乐") {
            return ShareProviderDetection(source: .qqMusic, confidence: 0.9, reason: "分享文本包含 QQ 音乐特征")
        }
        if text.contains("music.apple.com") || rawText.contains("Apple Music") {
            return ShareProviderDetection(source: .appleMusic, confidence: 0.88, reason: "分享文本包含 Apple Music 特征")
        }
        let meaningfulLines = rawText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if meaningfulLines.count >= 2 {
            return ShareProviderDetection(source: .plainText, confidence: 0.72, reason: "文本包含多行内容，适合按歌单文本解析")
        }
        return nil
    }

    private func hostMatches(_ host: String, in hosts: Set<String>) -> Bool {
        hosts.contains(host) || hosts.contains { host.hasSuffix("." + $0) }
    }
}
