import Foundation
import Combine
import SwiftUI
import SingReadyAISharedKit

#if canImport(AVFoundation)
import AVFoundation
#endif

@MainActor
final class DemoWorkflowStore: ObservableObject {
    static let idleStatusMessage = "先选你现在想做的事"

    @Published var navigationPath: [WorkflowStage] = []
    @Published var pendingImports: [PendingImportPayload] = []
    @Published var recentPlaylists: [ImportedPlaylist] = []
    @Published var importedPlaylist: ImportedPlaylist?
    @Published var reviewSongs: [EditableImportedSongDraft] = []
    @Published var matches: [MatchResult] = []
    @Published var preferenceProfile: PreferenceProfile?
    @Published var voiceProfile: VoiceProfile?
    @Published var recommendationInputSource: RecommendationInputSource = .userImport
    @Published var scenarioConfig = ScenarioConfig()
    @Published var songPlan: SongPlan?
    @Published var statusMessage = DemoWorkflowStore.idleStatusMessage
    @Published var errorMessage: String?
    @Published var isWorking = false
    @Published var isUsingFallbackStore = false
    @Published var recordingState: VoiceRecordingState = .idle
    @Published var recordingRemainingSeconds = 10
    @Published var recordingLevel = 0.08
    @Published var lockedTrackIDs: Set<String> = []
    @Published var removedTrackIDs: Set<String> = []
    @Published var externalCandidateTracks: [KTVTrack] = []
    @Published var externalCandidateStatus = "还没找同歌手备选"
    @Published var isExpandingExternalCandidates = false
    @Published var feedbackProfile = SongFeedbackProfile.empty
    @Published var feedbackStatusMessage: String?
    @Published var lastFeedbackUndo: SongFeedbackUndoAction?
    @Published var lastReviewSongUndo: ReviewSongUndoAction?
    @Published var lastRemovedTrackUndo: RemovedTrackUndoAction?
    @Published var microphonePermissionDenied = false
    @Published var isManagingLocalData = false
    @Published var hasAdvancedToScenario = false

    let appGroupStore = AppGroupStore()
    let importCoordinator = ImportCoordinator()
    private let catalogRepository = KTVCatalogRepository()
    let matcher = SongMatcher()
    let profiler = PreferenceProfiler()
    let playlistAnalysisExecutor = PlaylistAnalysisExecutor()
    let voiceAnalyzer = VoiceProfileAnalyzer()
    let recommendationEngine = RecommendationEngine()
    let ocrService: any OCRServicing = VisionOCRService()
    let ocrTemporaryFileStore = OCRTemporaryFileStore()
    let textExporter = PlaylistTextExporter()
    let shareTextExporter = PlaylistShareTextExporter()
    let jsonExporter = PlaylistJSONExporter()
    let workflowPersistenceExecutor: WorkflowPersistenceExecutor
    let voiceProfileStore: VoiceProfileStore

    #if canImport(AVFoundation)
    let voiceRecordingService = VoiceRecordingService()
    #endif
    var voiceRecordingTask: Task<Void, Never>?
    var voiceMeasurementGate = VoiceMeasurementRequestGate()
    var workflowOperationTask: Task<WorkflowOperationOutcome, Never>?
    var workflowOperationTimeoutTask: Task<Void, Never>?
    var workflowOperationGate = VoiceMeasurementRequestGate()
    var planPreparationTask: Task<Void, Never>?
    var planPreparationGeneration: UInt64 = 0
    var isCompletingWorkflowNavigation = false
    var localDataEpoch: UInt64 = 0
    var externalCandidateTask: Task<[ExternalSongCandidate], Error>?
    var externalCandidateRequestCoordinator = ExternalCandidateRequestCoordinator()
    var workflowSnapshotSubscriptions: Set<AnyCancellable> = []
    var workflowSnapshotRevision: UInt64 = 0
    var lastWorkflowSnapshotAttemptRevision: UInt64?
    var pendingImportPersistenceGate = WorkflowPersistenceRequestGate()
    var recentPlaylistPersistenceGate = WorkflowPersistenceRequestGate()
    var workflowSnapshotPersistenceGate = WorkflowPersistenceRequestGate()
    var isApplyingRestoredWorkflowSnapshot = false
    var voiceProfilePersistenceGate = VoiceProfilePersistenceRequestGate()
    var hasStandaloneFeedbackRecord = false

    private(set) var catalog: [KTVTrack] = []

    init() {
        workflowPersistenceExecutor = WorkflowPersistenceExecutor(
            recentPlaylistStore: RecentPlaylistStore(url: Self.recentPlaylistsURL()),
            workflowSnapshotStore: WorkflowSnapshotStore(url: Self.workflowSnapshotURL())
        )
        voiceProfileStore = VoiceProfileStore(url: Self.voiceProfileURL())
        catalog = (try? catalogRepository.loadTracks()) ?? []
        switch SongFeedbackLocalStore().loadWithStatus() {
        case .missing:
            feedbackProfile = .empty
        case let .loaded(profile):
            feedbackProfile = profile
            hasStandaloneFeedbackRecord = true
        }
        do {
            try ocrTemporaryFileStore.removeOrphans()
        } catch {
            errorMessage = "上次留下的截图临时文件暂时没清掉，可以通过清除本机记录重试。"
        }
        Task { @MainActor [weak self] in
            await self?.loadPendingImports()
        }
        let recentPlaylistRestoreRequest = recentPlaylistPersistenceGate.begin()
        Task { @MainActor [weak self] in
            await self?.loadRecentPlaylists(request: recentPlaylistRestoreRequest)
        }
        let workflowSnapshotRestoreRequest = workflowSnapshotPersistenceGate.begin()
        let voiceProfileRestoreRequest = voiceProfilePersistenceGate.begin()
        let voiceProfileRestoreEpoch = localDataEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.restoreWorkflowSnapshot(request: workflowSnapshotRestoreRequest)
            await self.restoreStandaloneVoiceProfileIfNeeded(
                request: voiceProfileRestoreRequest,
                epoch: voiceProfileRestoreEpoch
            )
        }
        observeWorkflowSnapshotChanges()
        Task { [appGroupStore] in
            _ = try? await appGroupStore.removeExpiredStagedSharedImages(
                deadline: MonotonicOperationDeadline(timeoutNanoseconds: 1_000_000_000)
            )
        }
    }

    var activeReviewSongs: [EditableImportedSongDraft] {
        reviewSongs.filter { !$0.isDeleted }
    }

    var untitledReviewSongs: [EditableImportedSongDraft] {
        activeReviewSongs.filter { !$0.hasValidTitle }
    }

    var removedTracksForManagement: [KTVTrack] {
        let tracksByID = Dictionary(
            (catalog + externalCandidateTracks).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let sortedTracks = removedTrackIDs
            .compactMap { tracksByID[$0] }
            .sorted {
                if $0.title == $1.title { return $0.artist < $1.artist }
                return $0.title < $1.title
            }
        return Array(sortedTracks.prefix(8))
    }

    var currentStage: WorkflowStage {
        navigationPath.last ?? .home
    }

    var hasUncommittedReviewChanges: Bool {
        reviewSongsDifferFromImportedPlaylist(reviewSongs)
    }

    var resumeStage: WorkflowStage {
        guard importedPlaylist != nil else { return .importHub }
        if songPlan != nil { return .result }
        if matches.isEmpty { return .review }
        if hasAdvancedToScenario, preferenceProfile != nil { return .scenario }
        if hasUncommittedReviewChanges { return .review }
        if matches.contains(where: {
            $0.confirmationState == .required
                || $0.status == .unmatched
                || $0.needsAlternativeAdoption
        }) {
            return .matchReport
        }
        return preferenceProfile == nil ? .matchReport : .scenario
    }

    var lowConfidenceReviewSongs: [EditableImportedSongDraft] {
        activeReviewSongs.filter(\.needsReview)
    }

    var matchStats: MatchStatistics {
        MatchStatistics(matches: matches)
    }

    var matchRate: Double {
        guard !matches.isEmpty else { return 0 }
        let matchedCount = matches.filter(\.hasOriginalReferenceMatch).count
        return Double(matchedCount) / Double(matches.count)
    }

    var shouldShowImportStatus: Bool {
        isWorking || errorMessage != nil || statusMessage != Self.idleStatusMessage
    }

    func setStage(_ stage: WorkflowStage, animated: Bool = true) {
        guard currentStage != stage else { return }
        if stage == .scenario, importedPlaylist != nil {
            hasAdvancedToScenario = true
        }

        let updatePath = {
            if stage == .home {
                self.navigationPath = []
            } else if let existingIndex = self.navigationPath.lastIndex(of: stage) {
                self.navigationPath = Array(self.navigationPath.prefix(through: existingIndex))
            } else {
                self.navigationPath.append(stage)
            }
        }
        if animated {
            withAnimation(MotionTokens.page, updatePath)
        } else {
            updatePath()
        }
    }

    func jumpToStage(_ stage: WorkflowStage, animated: Bool = true) async {
        if stage == .scenario, importedPlaylist != nil {
            hasAdvancedToScenario = true
        }
        replaceNavigation(with: stage, animated: animated)
    }

    func replaceNavigation(with stage: WorkflowStage, animated: Bool = false) {
        let updatePath = {
            self.navigationPath = stage == .home ? [] : [stage]
        }
        if animated {
            withAnimation(MotionTokens.page, updatePath)
        } else {
            updatePath()
        }
    }

}
