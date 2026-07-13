import Foundation

public struct PlaylistTextExporter: Sendable {
    public init() {}

    public func export(plan: SongPlan) -> String {
        let plan = sanitizedPlanForExport(plan)
        var lines: [String] = []
        let duration = plan.scenarioConfig?.durationMinutes ?? 120
        let hours = duration % 60 == 0 ? "\(duration / 60) 小时" : "\(duration) 分钟"
        lines.append("今晚唱什么｜\(plan.scenario.displayName) \(hours)")
        if plan.inputSource.allowsPlaylistPersonalization,
           let preferenceSummary = plan.preferenceSummary {
            lines.append("今晚建议：\(preferenceSummary)")
        } else {
            lines.append("今晚建议：\(plan.scenario.planSummary)")
        }
        if let voiceProfile = plan.voiceProfile {
            lines.append("\(voiceProfile.source.displayName)：\(midiDisplayRange(voiceProfile))")
        }
        lines.append("")
        for section in plan.sections {
            guard !section.items.isEmpty else { continue }
            lines.append(section.title)
            lines.append(section.goal)
            for (index, item) in section.items.enumerated() {
                lines.append("\(index + 1). \(item.track.title) - \(item.track.artist)")
                lines.append("   \(item.track.catalogSource.displayName)")
                if let confidenceNote = item.track.confidenceNote {
                    lines.append("   参考说明：\(confidenceNote)")
                }
                let reasons = exportableReasons(item.reasons, plan: plan)
                if !reasons.isEmpty {
                    lines.append("   为什么放这首：\(reasons.joined(separator: "；"))")
                }
                if plan.voiceProfile?.source == .measured,
                   let advice = item.singingAdvice {
                    lines.append("   唱的时候：\(advice.title)：\(advice.detail)")
                }
                if !item.riskWarnings.isEmpty {
                    lines.append("   注意：\(item.riskWarnings.joined(separator: "；"))")
                }
                if let actionURL = item.actionURL {
                    lines.append("   搜歌：\(actionURL.absoluteString)")
                }
                if let alternative = item.alternatives.first {
                    lines.append("   备选：\(alternative.title) - \(alternative.artist)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

public struct PlaylistShareTextExporter: Sendable {
    public init() {}

    public func export(plan: SongPlan) -> String {
        let plan = sanitizedPlanForExport(plan)
        let duration = plan.scenarioConfig?.durationMinutes ?? 120
        var lines = [
            "今晚唱什么｜\(plan.scenario.displayName) \(duration) 分钟",
            plan.scenario.planSummary,
            ""
        ]

        for section in plan.sections where !section.items.isEmpty {
            lines.append(section.title)
            for (index, item) in section.items.enumerated() {
                lines.append("\(index + 1). \(item.track.title) - \(item.track.artist)")
            }
            lines.append("")
        }

        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

}

public struct PlaylistTextFilePayload: Equatable, Sendable {
    public let fileName: String
    public let contents: String

    public init(fileName: String, contents: String) {
        self.fileName = fileName
        self.contents = contents
    }

    public var data: Data {
        Data(contents.utf8)
    }
}

public struct PlaylistTextFileExporter: Sendable {
    public init() {}

    public func export(plan: SongPlan) -> PlaylistTextFilePayload {
        PlaylistTextFilePayload(
            fileName: "\(safeFileStem(plan.title))-详细歌单.txt",
            contents: PlaylistTextExporter().export(plan: plan)
        )
    }

    private func safeFileStem(_ value: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(
            CharacterSet(charactersIn: "/\\:?%*|\"<>")
        )
        let cleaned = value.unicodeScalars.map { scalar in
            forbidden.contains(scalar) ? "-" : String(scalar)
        }.joined()
        let collapsed = cleaned
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .joined(separator: "-")
        let stem = collapsed.isEmpty ? "今晚歌单" : collapsed
        return String(stem.prefix(60))
    }
}

public enum TemporaryExportFileStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidFileName

    public var errorDescription: String? {
        "详细文本文件名不安全，请重新生成后再试。"
    }
}

public struct TemporaryExportFileStore: Sendable {
    private let directory: URL

    public init(
        directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingReadyAIExports", isDirectory: true)
    ) {
        self.directory = directory
    }

    public func materialize(_ payload: PlaylistTextFilePayload) throws -> URL {
        let fileName = payload.fileName
        let trimmedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fileName == trimmedFileName,
              !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.hasPrefix("."),
              !fileName.contains("/"),
              !fileName.contains("\\"),
              !fileName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (fileName as NSString).pathExtension.lowercased() == "txt" else {
            throw TemporaryExportFileStoreError.invalidFileName
        }
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for existingURL in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) where existingURL.pathExtension.lowercased() == "txt" {
            try? FileManager.default.removeItem(at: existingURL)
        }
        let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        try payload.data.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}

public struct LocalArtifactCleanupResult: Equatable, Sendable {
    public let failureCount: Int

    public init(failureCount: Int) {
        self.failureCount = max(0, failureCount)
    }

    public var succeeded: Bool {
        failureCount == 0
    }
}

public struct LocalArtifactCleaner: Sendable {
    private let operations: [@Sendable () throws -> Void]

    public init(
        ocrTemporaryFileStore: OCRTemporaryFileStore,
        temporaryExportFileStore: TemporaryExportFileStore = TemporaryExportFileStore()
    ) {
        operations = [
            { try ocrTemporaryFileStore.removeOrphans() },
            { try temporaryExportFileStore.clear() }
        ]
    }

    public init(
        recentPlaylistStore: RecentPlaylistStore,
        workflowSnapshotStore: WorkflowSnapshotStore,
        ocrTemporaryFileStore: OCRTemporaryFileStore,
        temporaryExportFileStore: TemporaryExportFileStore = TemporaryExportFileStore()
    ) {
        operations = [
            { try recentPlaylistStore.clear() },
            { try workflowSnapshotStore.clear() },
            { try ocrTemporaryFileStore.removeOrphans() },
            { try temporaryExportFileStore.clear() }
        ]
    }

    init(operations: [@Sendable () throws -> Void]) {
        self.operations = operations
    }

    public func clear() async -> LocalArtifactCleanupResult {
        let operations = self.operations
        return await Task.detached(priority: .utility) {
            var failureCount = 0
            for operation in operations {
                do {
                    try operation()
                } catch {
                    failureCount += 1
                }
            }
            return LocalArtifactCleanupResult(failureCount: failureCount)
        }.value
    }
}

private func midiDisplayRange(_ profile: VoiceProfile) -> String {
    "\(midiNoteName(profile.stableLowMidi)) 到 \(midiNoteName(profile.stableHighMidi))"
}

private func exportableReasons(_ reasons: [String], plan: SongPlan) -> [String] {
    reasons.filter {
        plan.inputSource.allowsRecommendationReason(
            $0,
            voiceSource: plan.voiceProfile?.source
        )
    }
}

private func sanitizedPlanForExport(_ original: SongPlan) -> SongPlan {
    var plan = original.sanitizedForTrustBoundaries()
    if !plan.inputSource.allowsPlaylistPersonalization {
        plan.preferenceSummary = plan.scenario.planSummary
    }
    if var voiceProfile = plan.voiceProfile,
       voiceProfile.source == .commonReference {
        voiceProfile.type = .unknown
        voiceProfile.confidence = 0
        voiceProfile.note = "这是尚未实测时使用的常见音域参考。"
        plan.voiceProfile = voiceProfile
    }
    if let voiceProfile = plan.voiceProfile,
       voiceProfile.source == .measured,
       !voiceProfile.hasValidMeasuredRange {
        plan.voiceProfile = nil
    }
    plan.sections = plan.sections.map { section in
        var section = section
        section.items = section.items.map { item in
            var item = item
            item.reasons = exportableReasons(item.reasons, plan: plan)
            if plan.voiceProfile?.hasValidMeasuredRange != true {
                item.singingAdvice = nil
            }
            return item
        }
        return section
    }
    return plan
}

private func midiNoteName(_ midi: Int) -> String {
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    let note = names[(midi % 12 + 12) % 12]
    let octave = midi / 12 - 1
    return "\(note)\(octave)"
}

public struct PlaylistJSONExporter: Sendable {
    public init() {}

    public func export(plan: SongPlan) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(sanitizedPlanForExport(plan)), as: UTF8.self)
    }
}

public struct PosterHighlight: Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let isPendingVerification: Bool

    public init(id: String, text: String, isPendingVerification: Bool) {
        self.id = id
        self.text = text
        self.isPendingVerification = isPendingVerification
    }

    public var displayText: String {
        isPendingVerification ? "\(text) · 待核对" : text
    }
}

public struct PosterSectionSummary: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let disclosure: String?
    public let highlights: [PosterHighlight]

    public init(
        id: String,
        title: String,
        disclosure: String?,
        highlights: [PosterHighlight]
    ) {
        self.id = id
        self.title = title
        self.disclosure = disclosure
        self.highlights = highlights
    }
}

public struct PosterSummary: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public let sections: [PosterSectionSummary]

    public init(title: String, subtitle: String, sections: [PosterSectionSummary]) {
        self.title = title
        self.subtitle = subtitle
        self.sections = sections
    }

    public var highlights: [String] {
        sections.flatMap(\.highlights).map(\.displayText)
    }
}

public struct PosterRenderer: Sendable {
    public init() {}

    public func summary(for plan: SongPlan) -> PosterSummary {
        let plan = sanitizedPlanForExport(plan)
        var remainingHighlightCount = 10
        var posterSections: [PosterSectionSummary] = []
        for section in plan.sections where remainingHighlightCount > 0 {
            let items = Array(section.items.prefix(remainingHighlightCount))
            guard !items.isEmpty else { continue }
            let hasProvisionalCandidate = items.contains { $0.track.isProvisionalExternalCandidate }
            posterSections.append(PosterSectionSummary(
                id: section.id.uuidString,
                title: section.title,
                disclosure: hasProvisionalCandidate
                    ? "公开搜索候选，KTV 收录与现场数据待核对"
                    : nil,
                highlights: items.map { item in
                    PosterHighlight(
                        id: item.id.uuidString,
                        text: "\(item.track.title) - \(item.track.artist)",
                        isPendingVerification: item.track.isProvisionalExternalCandidate
                    )
                }
            ))
            remainingHighlightCount -= items.count
        }
        let duration = plan.scenarioConfig.map { "\($0.durationMinutes) 分钟" } ?? "\(plan.sections.count) 段"
        let voiceSummary = plan.voiceProfile.map { profile in
            switch profile.source {
            case .measured:
                return "\(profile.source.displayName) \(midiDisplayRange(profile))"
            case .commonReference:
                return profile.source.displayName
            case .legacyUnknown:
                return profile.source.displayName
            }
        }
        let subtitleParts = [
            plan.scenario.displayName,
            duration,
            voiceSummary
        ].compactMap { $0 }
        return PosterSummary(
            title: "今晚唱什么",
            subtitle: subtitleParts.joined(separator: "，"),
            sections: posterSections
        )
    }
}
