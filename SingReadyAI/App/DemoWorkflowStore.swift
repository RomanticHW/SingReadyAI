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
    @Published private(set) var reviewSongs: [EditableImportedSongDraft] = []
    @Published private(set) var revisions = WorkflowRevisionLedger()
    @Published private(set) var completedAnalysis: CompletedPlaylistAnalysis?
    @Published private(set) var matchOperationState: MatchOperationState = .notStarted
    @Published private(set) var isApplyingMatchReviewAction = false
    @Published var voiceProfile: VoiceProfile?
    @Published var recommendationInputSource: RecommendationInputSource = .userImport
    @Published var scenarioConfig = ScenarioConfig()
    @Published private(set) var planGenerationState: PlanGenerationState = .absent
    @Published var statusMessage = DemoWorkflowStore.idleStatusMessage
    @Published var errorMessage: String?
    @Published private(set) var importOperationState: ImportOperationState = .idle
    @Published private(set) var isCommittingImportedWorkflow = false
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
    var matchOperationTask: Task<WorkflowOperationOutcome, Never>?
    var matchOperationTimeoutTask: Task<Void, Never>?
    var matchOperationGate = VoiceMeasurementRequestGate()
    var importOperationTask: Task<WorkflowOperationOutcome, Never>?
    var importOperationTimeoutTask: Task<Void, Never>?
    var importOperationGate = VoiceMeasurementRequestGate()
    var planPreparationTask: Task<Void, Never>?
    var planPreparationGeneration: UInt64 = 0
    var planGenerationTask: Task<Void, Never>?
    var planGenerationGate = VoiceMeasurementRequestGate()
    var planStateTransitionGate = WorkflowStateTransitionGate()
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
    var standaloneFeedbackRevision: UInt64 = 0

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
        case let .loaded(record):
            feedbackProfile = record.profile
            revisions.feedback = record.revision
            standaloneFeedbackRevision = record.revision
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
            await self.restoreWorkflowSnapshot(
                request: workflowSnapshotRestoreRequest,
                voiceProfileRequest: voiceProfileRestoreRequest,
                voiceProfileEpoch: voiceProfileRestoreEpoch
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

    var matches: [MatchResult] {
        completedAnalysis?.matches ?? []
    }

    var preferenceProfile: PreferenceProfile? {
        completedAnalysis?.preferenceProfile
    }

    var isWorking: Bool {
        if case .running = matchOperationState { return true }
        if case .generating = planGenerationState { return true }
        if planGenerationTask != nil { return true }
        return false
    }

    var visibleSongPlan: SongPlan? {
        planGenerationState.visiblePlan
    }

    var readySongPlan: SongPlan? {
        guard let basis = currentPlanBasis,
              let plan = planGenerationState.readyPlan(validFor: basis),
              planMatchesCurrentGenerationContext(plan, basis: basis) else {
            return nil
        }
        return plan
    }

    var canUseReadyPlan: Bool {
        readySongPlan != nil
    }

    var isGeneratingPlan: Bool {
        if case .generating = planGenerationState { return true }
        return false
    }

    var matchingProgressText: String {
        if case let .running(processed, total) = matchOperationState {
            return "已处理 \(processed)/\(total) 首"
        }
        return "正在核对歌曲参考"
    }

    var currentMatchBasis: MatchBasis? {
        guard let importedPlaylist else { return nil }
        return MatchBasis(
            playlistID: importedPlaylist.id,
            reviewRevision: revisions.review,
            catalogRevision: PlaylistWorkflowFingerprint.catalogRevision(for: catalog)
        )
    }

    var currentPlanBasis: PlanBasis? {
        guard let matchBasis = currentMatchBasis,
              let analysis = completedAnalysis,
              analysis.basis == matchBasis,
              analysis.matchRevision == revisions.match else {
            return nil
        }
        let voice = voiceProfile ?? voiceAnalyzer.simulatedProfile()
        return PlanBasis(
            matchBasis: matchBasis,
            matchRevision: revisions.match,
            scenarioFingerprint: PlaylistWorkflowFingerprint.scenario(for: scenarioConfig),
            voiceSource: voice.source,
            voiceFingerprint: PlaylistWorkflowFingerprint.voice(for: voice),
            feedbackRevision: revisions.feedback,
            trackControlsRevision: revisions.trackControls,
            inputSource: recommendationInputSource,
            catalogRevision: matchBasis.catalogRevision
        )
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
        if visibleSongPlan != nil { return .result }
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
        activeReviewSongs.filter(\.needsAttention)
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
        importOperationState != .idle
            || errorMessage != nil
            || statusMessage != Self.idleStatusMessage
    }

    var isImportResolving: Bool {
        if case .resolving = importOperationState { return true }
        return false
    }

    var isImportInteractionDisabled: Bool {
        isImportResolving
            || isCommittingImportedWorkflow
            || isWorking
            || isApplyingMatchReviewAction
            || isManagingLocalData
    }

    var isImportPersistenceLocked: Bool {
        isImportResolving
            || isCommittingImportedWorkflow
            || isWorking
            || isApplyingMatchReviewAction
    }

    var isWorkflowMutationNavigationLocked: Bool {
        isCommittingImportedWorkflow || isApplyingMatchReviewAction
    }

    func replaceReviewSongs(_ songs: [EditableImportedSongDraft]) {
        reviewSongs = songs
    }

    func replaceWorkflowRevisions(_ ledger: WorkflowRevisionLedger) {
        revisions = ledger
    }

    func replaceCompletedAnalysis(_ analysis: CompletedPlaylistAnalysis?) {
        completedAnalysis = analysis
    }

    func setMatchOperationState(_ state: MatchOperationState) {
        matchOperationState = state
    }

    func setPlanGenerationState(_ state: PlanGenerationState) {
        planGenerationState = state
    }

    func setApplyingMatchReviewAction(_ isApplying: Bool) {
        isApplyingMatchReviewAction = isApplying
    }

    func setImportOperationState(_ state: ImportOperationState) {
        importOperationState = state
    }

    func setCommittingImportedWorkflow(_ isCommitting: Bool) {
        isCommittingImportedWorkflow = isCommitting
    }

    func setStage(_ stage: WorkflowStage, animated: Bool = true) {
        guard currentStage != stage else { return }
        guard canNavigateToWorkflowStage(stage) else {
            errorMessage = readyPlanUnavailableMessage
            return
        }
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
        guard !isWorkflowMutationNavigationLocked else { return }
        guard canNavigateToWorkflowStage(stage) else {
            errorMessage = readyPlanUnavailableMessage
            return
        }
        if stage == .scenario, importedPlaylist != nil {
            hasAdvancedToScenario = true
        }
        replaceNavigation(with: stage, animated: animated)
    }

    func replaceNavigation(with stage: WorkflowStage, animated: Bool = false) {
        guard canNavigateToWorkflowStage(stage) else {
            errorMessage = readyPlanUnavailableMessage
            return
        }
        let updatePath = {
            self.navigationPath = stage == .home ? [] : [stage]
        }
        if animated {
            withAnimation(MotionTokens.page, updatePath)
        } else {
            updatePath()
        }
    }

    private func canNavigateToWorkflowStage(_ stage: WorkflowStage) -> Bool {
        !((stage == .export || stage == .startTips) && !canUseReadyPlan)
    }

}
