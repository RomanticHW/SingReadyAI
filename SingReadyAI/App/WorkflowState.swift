import Foundation
import SingReadyAISharedKit

enum WorkflowStage: String, CaseIterable, Identifiable, Hashable {
    case home
    case importHub
    case review
    case matchReport
    case voice
    case scenario
    case result
    case export
    case startTips

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .importHub: return "导入歌单"
        case .review: return "整理歌单"
        case .matchReport: return "核对参考匹配"
        case .voice: return "测一下音域"
        case .scenario: return "排今晚歌单"
        case .result: return "今晚歌单"
        case .export: return "发给朋友"
        case .startTips: return "开唱小抄"
        }
    }

    func title(for scenario: KTVScenario) -> String {
        guard scenario == .soloPractice else { return title }
        switch self {
        case .scenario:
            return "排练唱单"
        case .result:
            return "练唱歌单"
        case .export:
            return "保存练唱单"
        case .startTips:
            return "练唱小抄"
        default:
            return title
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .importHub: return "tray.and.arrow.down"
        case .review: return "checklist"
        case .matchReport: return "chart.bar.xaxis"
        case .voice: return "waveform"
        case .scenario: return "person.3.sequence"
        case .result: return "sparkles"
        case .export: return "square.and.arrow.up"
        case .startTips: return "quote.bubble"
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

enum ReviewedSongMatchingOutcome: Equatable {
    case completed
    case needsReview
    case unavailable
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

    var hasValidTitle: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名歌曲" : trimmed
    }

    var needsAttention: Bool {
        !hasValidTitle
            || confidence < 0.72
            || artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !versionTags.isEmpty
    }

    func importedSong() -> ImportedSong {
        ImportedSong(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: artist.nilIfBlank,
            source: source,
            rawText: rawText.isEmpty ? nil : rawText,
            confidence: confidence,
            versionTags: versionTags
        )
    }
}

struct ImportReviewSummary: Equatable {
    let totalCount: Int
    let attentionCount: Int
    let missingTitleCount: Int

    init(songs: [EditableImportedSongDraft]) {
        let activeSongs = songs.filter { !$0.isDeleted }
        totalCount = activeSongs.count
        attentionCount = activeSongs.filter(\.needsAttention).count
        missingTitleCount = activeSongs.filter { !$0.hasValidTitle }.count
    }

    var canStartMatching: Bool {
        totalCount > 0 && missingTitleCount == 0
    }
}

enum ReviewMutation: Equatable {
    case updateTitle(id: UUID, value: String)
    case updateArtist(id: UUID, value: String)
    case delete(id: UUID)
    case restore(id: UUID)
}

enum ImportedWorkflowCommitError: LocalizedError {
    case persistenceFailed
    case pendingPersistenceFailed
    case superseded

    var errorDescription: String? {
        switch self {
        case .persistenceFailed:
            return "这份歌单暂时没保存下来，之前的歌单和结果都还在。请稍后重试。"
        case .pendingPersistenceFailed:
            return "歌单暂时没保存下来，待整理内容已保留，请稍后重试。"
        case .superseded:
            return "本次导入已停止，之前的歌单和结果都还在。请重新试一次。"
        }
    }
}

struct SongFeedbackUndoAction: Equatable {
    var trackID: String
    var trackTitle: String
    var kind: SongFeedbackKind
    var previousTags: [SongFeedbackKind]
    var appliedFeedbackRevision: UInt64
}

struct ReviewSongUndoAction: Equatable {
    var songID: UUID
    var title: String
}

struct RemovedTrackUndoAction: Equatable {
    var trackID: String
    var title: String
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
