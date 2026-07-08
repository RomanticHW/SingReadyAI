import Foundation
import SwiftUI
import SingReadyAISharedKit

#if canImport(AVFoundation)
import AVFoundation
#endif

enum WorkflowStage: String, CaseIterable, Identifiable {
    case importHub
    case review
    case matchReport
    case voice
    case scenario
    case result
    case export
    case interview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .importHub: return "导入"
        case .review: return "确认"
        case .matchReport: return "匹配"
        case .voice: return "声线"
        case .scenario: return "场景"
        case .result: return "歌单"
        case .export: return "导出"
        case .interview: return "面试"
        }
    }

    var systemImage: String {
        switch self {
        case .importHub: return "tray.and.arrow.down"
        case .review: return "checklist"
        case .matchReport: return "chart.bar.xaxis"
        case .voice: return "waveform"
        case .scenario: return "person.3.sequence"
        case .result: return "sparkles"
        case .export: return "square.and.arrow.up"
        case .interview: return "briefcase"
        }
    }
}

enum VoiceRecordingState: Equatable {
    case idle
    case requestingPermission
    case recording
    case analyzing
    case failed(String)
}

struct EditableImportedSongDraft: Identifiable, Hashable {
    var id: UUID
    var title: String
    var artist: String
    var source: ImportSource
    var rawText: String
    var confidence: Double
    var versionTags: [String]
    var isDeleted: Bool

    init(song: ImportedSong) {
        id = song.id
        title = song.title
        artist = song.artist ?? ""
        source = song.source
        rawText = song.rawText ?? ""
        confidence = song.confidence
        versionTags = song.versionTags
        isDeleted = false
    }

    var needsReview: Bool {
        confidence < 0.72 || artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func importedSong() -> ImportedSong {
        ImportedSong(
            id: id,
            title: title,
            artist: artist.nilIfBlank,
            source: source,
            rawText: rawText,
            confidence: confidence,
            versionTags: versionTags
        )
    }
}

struct WorkflowImportRecord: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var source: ImportSource
    var songCount: Int
    var createdAt: Date
}

@MainActor
final class DemoWorkflowStore: ObservableObject {
    @Published var currentStage: WorkflowStage = .importHub
    @Published var pendingImports: [PendingImportPayload] = []
    @Published var recentImports: [WorkflowImportRecord] = []
    @Published var importedPlaylist: ImportedPlaylist?
    @Published var reviewSongs: [EditableImportedSongDraft] = []
    @Published var matches: [MatchResult] = []
    @Published var preferenceProfile: PreferenceProfile?
    @Published var voiceProfile: VoiceProfile?
    @Published var scenarioConfig = ScenarioConfig()
    @Published var songPlan: SongPlan?
    @Published var statusMessage = "选择一种方式导入歌单"
    @Published var errorMessage: String?
    @Published var isWorking = false
    @Published var isUsingFallbackStore = false
    @Published var recordingState: VoiceRecordingState = .idle
    @Published var recordingRemainingSeconds = 10
    @Published var recordingLevel = 0.08
    @Published var lockedTrackIDs: Set<String> = []
    @Published var removedTrackIDs: Set<String> = []

    private let appGroupStore = AppGroupStore()
    private let importCoordinator = ImportCoordinator()
    private let catalogRepository = KTVCatalogRepository()
    private let matcher = SongMatcher()
    private let profiler = PreferenceProfiler()
    private let voiceAnalyzer = VoiceProfileAnalyzer()
    private let recommendationEngine = RecommendationEngine()
    private let ocrService: any OCRServicing = VisionOCRService()
    private let textExporter = PlaylistTextExporter()
    private let jsonExporter = PlaylistJSONExporter()

    #if canImport(AVFoundation)
    private let voiceRecordingService = VoiceRecordingService()
    #endif

    private(set) var catalog: [KTVTrack] = []

    init() {
        catalog = (try? catalogRepository.loadTracks()) ?? []
        loadPendingImports()
    }

    var activeReviewSongs: [EditableImportedSongDraft] {
        reviewSongs.filter { !$0.isDeleted }
    }

    var lowConfidenceReviewSongs: [EditableImportedSongDraft] {
        activeReviewSongs.filter(\.needsReview)
    }

    var matchStats: (exact: Int, fuzzy: Int, alternative: Int, unmatched: Int) {
        (
            matches.filter { $0.status == .exact }.count,
            matches.filter { $0.status == .fuzzy }.count,
            matches.filter { $0.status == .alternative }.count,
            matches.filter { $0.status == .unmatched }.count
        )
    }

    var matchRate: Double {
        guard !matches.isEmpty else { return 0 }
        let matchedCount = matches.filter { $0.matchedTrack != nil }.count
        return Double(matchedCount) / Double(matches.count)
    }

    func loadPendingImports() {
        pendingImports = (try? appGroupStore.loadPendingImports()) ?? []
        isUsingFallbackStore = appGroupStore.isUsingFallbackStore()
    }

    func analyzePending(_ payload: PendingImportPayload) async {
        await run("正在读取分享内容") {
            let playlist: ImportedPlaylist
            if payload.sourceHint == .screenshot, let imageFileName = payload.imageFileName {
                let imageURL = try appGroupStore.storeDirectoryURL().appendingPathComponent(imageFileName)
                let recognizedText = try await ocrService.recognizeText(fromImageAt: imageURL)
                playlist = OCRPlaylistParser().parse(recognizedText: recognizedText, title: payload.displayTitle ?? "分享截图")
            } else {
                playlist = try await importCoordinator.resolve(payload: payload)
            }
            prepareForReview(playlist: playlist)
            try? appGroupStore.removePendingImport(id: payload.id)
            loadPendingImports()
        }
    }

    func useDemoPlaylist() async {
        await run("正在载入 Demo 歌单") {
            let playlist = try importCoordinator.resolveDemoPlaylist()
            prepareForReview(playlist: playlist)
        }
    }

    func importText(_ text: String) async {
        await run("正在解析粘贴文本") {
            let payload = PendingImportPayload(sourceHint: .plainText, rawText: text, displayTitle: "粘贴导入歌单")
            let playlist = try await importCoordinator.resolve(payload: payload)
            prepareForReview(playlist: playlist)
        }
    }

    func importScreenshotData(_ data: Data) async {
        await run("正在识别截图文字") {
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("singready-ocr-\(UUID().uuidString).png")
            try data.write(to: temporaryURL, options: [.atomic])
            let recognizedText = try await ocrService.recognizeText(fromImageAt: temporaryURL)
            let playlist = OCRPlaylistParser().parse(recognizedText: recognizedText)
            guard playlist.songs.count >= 2 else {
                throw OCRServiceError.noTextRecognized
            }
            prepareForReview(playlist: playlist)
        }
    }

    func prepareForReview(playlist: ImportedPlaylist) {
        importedPlaylist = playlist
        reviewSongs = playlist.songs.map(EditableImportedSongDraft.init)
        matches = []
        preferenceProfile = nil
        songPlan = nil
        lockedTrackIDs = []
        removedTrackIDs = []
        recentImports.insert(
            WorkflowImportRecord(title: playlist.title, source: playlist.source, songCount: playlist.songs.count, createdAt: Date()),
            at: 0
        )
        recentImports = Array(recentImports.prefix(6))
        statusMessage = "解析到 \(playlist.songs.count) 首歌，请确认低置信度条目"
        currentStage = .review
    }

    func beginMatchingReviewedSongs() {
        guard let importedPlaylist else {
            errorMessage = "请先导入歌单"
            currentStage = .importHub
            return
        }
        let songs = activeReviewSongs.map { $0.importedSong() }
        guard !songs.isEmpty else {
            errorMessage = "没有可匹配的歌曲，请至少保留一首"
            return
        }
        let reviewedPlaylist = ImportedPlaylist(
            id: importedPlaylist.id,
            source: importedPlaylist.source,
            title: importedPlaylist.title,
            externalURL: importedPlaylist.externalURL,
            songs: songs,
            createdAt: importedPlaylist.createdAt,
            parseConfidence: songs.map(\.confidence).reduce(0, +) / Double(max(songs.count, 1))
        )
        self.importedPlaylist = reviewedPlaylist
        matches = matcher.match(playlist: reviewedPlaylist, catalog: catalog)
        preferenceProfile = profiler.buildProfile(importedPlaylist: reviewedPlaylist, matches: matches)
        statusMessage = "KTV 可唱率 \(Int(matchRate * 100))%，已生成偏好画像"
        currentStage = .matchReport
    }

    func useSimulatedVoice() {
        voiceProfile = voiceAnalyzer.simulatedProfile()
        recordingState = .idle
        statusMessage = "已生成模拟声线画像"
        currentStage = .scenario
    }

    func startVoiceRecording() async {
        recordingState = .requestingPermission
        errorMessage = nil

        #if os(iOS) && canImport(AVFoundation)
        let granted = await requestMicrophonePermission()
        guard granted else {
            recordingState = .failed("没有麦克风权限，可使用模拟声线继续演示。")
            return
        }

        let countdownTask = Task { @MainActor in
            for second in stride(from: 10, through: 1, by: -1) {
                recordingRemainingSeconds = second
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
        }

        do {
            recordingState = .recording
            recordingRemainingSeconds = 10
            recordingLevel = 0.08
            let profile = try await voiceRecordingService.recordPitchProfile(duration: 10) { [weak self] level in
                Task { @MainActor in
                    self?.recordingLevel = level
                }
            }
            countdownTask.cancel()
            recordingState = .analyzing
            voiceProfile = profile
            recordingState = .idle
            statusMessage = "已完成 10 秒声线分析"
            currentStage = .scenario
        } catch {
            countdownTask.cancel()
            recordingState = .failed("录音失败：\(error.localizedDescription)。可使用模拟声线继续。")
        }
        #else
        for second in stride(from: 10, through: 1, by: -1) {
            recordingState = .recording
            recordingRemainingSeconds = second
            recordingLevel = Double(11 - second) / 10
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        useSimulatedVoice()
        #endif
    }

    func generatePlan() {
        guard let profile = preferenceProfile else {
            errorMessage = "请先完成导入和 KTV 曲库匹配"
            currentStage = .importHub
            return
        }
        let voice = voiceProfile ?? voiceAnalyzer.simulatedProfile()
        voiceProfile = voice
        songPlan = recommendationEngine.generatePlan(
            matches: matches,
            preferenceProfile: profile,
            voiceProfile: voice,
            scenario: scenarioConfig,
            catalog: catalog,
            lockedTrackIDs: lockedTrackIDs,
            removedTrackIDs: removedTrackIDs
        )
        statusMessage = "已生成\(scenarioConfig.scenario.displayName)歌单"
        currentStage = .result
    }

    func regeneratePlan() {
        generatePlan()
    }

    func toggleLock(trackID: String) {
        if lockedTrackIDs.contains(trackID) {
            lockedTrackIDs.remove(trackID)
        } else {
            lockedTrackIDs.insert(trackID)
            removedTrackIDs.remove(trackID)
        }
        generatePlan()
    }

    func removeTrack(trackID: String) {
        removedTrackIDs.insert(trackID)
        lockedTrackIDs.remove(trackID)
        generatePlan()
    }

    func resetImport() {
        importedPlaylist = nil
        reviewSongs = []
        matches = []
        preferenceProfile = nil
        songPlan = nil
        errorMessage = nil
        statusMessage = "选择一种方式导入歌单"
        currentStage = .importHub
    }

    func exportedText() -> String {
        guard let songPlan else { return "暂无可导出的歌单" }
        return textExporter.export(plan: songPlan)
    }

    func exportedJSON() -> String {
        guard let songPlan else { return "{}" }
        return (try? jsonExporter.export(plan: songPlan)) ?? "{}"
    }

    private func run(_ loadingMessage: String, operation: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        statusMessage = loadingMessage
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = error.localizedDescription
        }
        isWorking = false
    }

    #if os(iOS) && canImport(AVFoundation)
    private func requestMicrophonePermission() async -> Bool {
        await voiceRecordingService.requestPermission()
    }
    #endif
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
