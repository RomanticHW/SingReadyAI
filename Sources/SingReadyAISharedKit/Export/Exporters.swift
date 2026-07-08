import Foundation

public struct PlaylistTextExporter: Sendable {
    public init() {}

    public func export(plan: SongPlan) -> String {
        var lines: [String] = []
        let duration = plan.scenarioConfig?.durationMinutes ?? 120
        let hours = duration % 60 == 0 ? "\(duration / 60) 小时" : "\(duration) 分钟"
        lines.append("今晚唱什么｜\(plan.scenario.displayName) \(hours)歌单")
        if let preferenceSummary = plan.preferenceSummary {
            lines.append("画像摘要：\(preferenceSummary)")
        }
        if let voiceProfile = plan.voiceProfile {
            lines.append("声线：\(voiceProfile.type.displayName) · 稳定音域 \(voiceProfile.stableLowMidi)-\(voiceProfile.stableHighMidi) MIDI")
        }
        lines.append("")
        for section in plan.sections {
            guard !section.items.isEmpty else { continue }
            lines.append(section.title)
            lines.append(section.goal)
            for (index, item) in section.items.enumerated() {
                lines.append("\(index + 1). \(item.track.title) - \(item.track.artist)")
                if !item.reasons.isEmpty {
                    lines.append("   推荐理由：\(item.reasons.joined(separator: "；"))")
                }
                if !item.riskWarnings.isEmpty {
                    lines.append("   风险提示：\(item.riskWarnings.joined(separator: "；"))")
                }
                if let alternative = item.alternatives.first {
                    lines.append("   替代建议：\(alternative.title) - \(alternative.artist)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

public struct PlaylistJSONExporter: Sendable {
    public init() {}

    public func export(plan: SongPlan) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(plan), as: UTF8.self)
    }
}

public struct PosterSummary: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public let highlights: [String]

    public init(title: String, subtitle: String, highlights: [String]) {
        self.title = title
        self.subtitle = subtitle
        self.highlights = highlights
    }
}

public struct PosterRenderer: Sendable {
    public init() {}

    public func summary(for plan: SongPlan) -> PosterSummary {
        let highlights = plan.sections
            .flatMap(\.items)
            .prefix(10)
            .map { "\($0.track.title) - \($0.track.artist)" }
        let duration = plan.scenarioConfig.map { "\($0.durationMinutes) 分钟" } ?? "\(plan.sections.count) 个段落"
        let subtitleParts = [
            plan.scenario.displayName,
            duration,
            plan.voiceProfile?.type.displayName
        ].compactMap { $0 }
        return PosterSummary(
            title: "今晚唱什么",
            subtitle: subtitleParts.joined(separator: " · "),
            highlights: Array(highlights)
        )
    }
}
