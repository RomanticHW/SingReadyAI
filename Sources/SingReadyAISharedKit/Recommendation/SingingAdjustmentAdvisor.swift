import Foundation

public struct SingingAdjustmentAdvisor: Sendable {
    public init() {}

    public func advice(for track: KTVTrack, voiceProfile: VoiceProfile) -> SingingAdjustmentAdvice? {
        guard track.catalogSource == .ktvCatalog,
              voiceProfile.hasValidMeasuredRange else {
            return nil
        }

        let minimumShift = voiceProfile.stableLowMidi - track.vocalRangeLowMidi
        let maximumShift = voiceProfile.stableHighMidi - track.vocalRangeHighMidi
        guard minimumShift <= maximumShift else {
            return substituteAdvice(detail: "这首歌的音域跨度超出本次唱到的音区，单纯移调无法同时顾到低音和高音。")
        }

        if minimumShift <= 0, maximumShift >= 0 {
            return SingingAdjustmentAdvice(
                level: .originalKey,
                title: "可先试原调",
                detail: "原调的低音和高音都落在本次唱到的音区内。",
                semitoneShift: 0
            )
        }

        let shift = minimumShift > 0 ? minimumShift : maximumShift
        guard abs(shift) <= 8 else {
            return substituteAdvice(detail: "需要移调超过 8 个半音才能顾到两端，优先换一首更合适的歌。")
        }

        if shift < 0 {
            return SingingAdjustmentAdvice(
                level: .lowerKey,
                title: "可先试降 \(abs(shift)) 个半音",
                detail: "降 \(abs(shift)) 个半音后，歌曲的低音和高音都可落入本次唱到的音区。",
                semitoneShift: shift
            )
        }

        return SingingAdjustmentAdvice(
            level: .raiseKey,
            title: "可先试升 \(shift) 个半音",
            detail: "升 \(shift) 个半音后，歌曲的低音和高音都可落入本次唱到的音区。",
            semitoneShift: shift
        )
    }

    private func substituteAdvice(detail: String) -> SingingAdjustmentAdvice {
        SingingAdjustmentAdvice(
            level: .substitute,
            title: "建议换一首音区更合适的歌",
            detail: detail,
            semitoneShift: 0
        )
    }
}

public struct SongActionURLPolicy: Sendable {
    private let allowedHostSuffixes: Set<String>

    public init(
        allowedHostSuffixes: Set<String> = [
            "music.apple.com",
            "itunes.apple.com",
            "last.fm"
        ]
    ) {
        self.allowedHostSuffixes = Set(allowedHostSuffixes.map { $0.lowercased() })
    }

    public func validated(_ url: URL?) -> URL? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(),
              allowedHostSuffixes.contains(where: {
                  host == $0 || host.hasSuffix(".\($0)")
              }) else {
            return nil
        }
        return url
    }
}

public struct SongActionLinkBuilder: Sendable {
    private let urlPolicy: SongActionURLPolicy

    public init(urlPolicy: SongActionURLPolicy = SongActionURLPolicy()) {
        self.urlPolicy = urlPolicy
    }

    public func url(for track: KTVTrack) -> URL? {
        if let externalURL = urlPolicy.validated(track.externalURL),
           !(externalURL.host?.lowercased() == "itunes.apple.com" && externalURL.path == "/search") {
            return externalURL
        }
        var components = URLComponents(string: "https://music.apple.com/cn/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(track.title) \(track.artist)")
        ]
        return urlPolicy.validated(components?.url)
    }
}
