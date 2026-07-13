import Foundation
import SingReadyAISharedKit

enum WorkflowOperationOutcome: Sendable {
    case succeeded
    case cancelled
    case failed(String)
    case discarded
}

@MainActor
extension DemoWorkflowStore {
    func resetImport(
        navigateToImport: Bool = true,
        clearPersistedSnapshot: Bool = true
    ) {
        cancelExternalCandidateRequest()
        importedPlaylist = nil
        reviewSongs = []
        matches = []
        preferenceProfile = nil
        recommendationInputSource = .userImport
        songPlan = nil
        hasAdvancedToScenario = false
        externalCandidateTracks = []
        externalCandidateStatus = "还没找同歌手备选"
        feedbackStatusMessage = nil
        lastFeedbackUndo = nil
        lastReviewSongUndo = nil
        lastRemovedTrackUndo = nil
        errorMessage = nil
        statusMessage = Self.idleStatusMessage
        if clearPersistedSnapshot {
            let request = workflowSnapshotPersistenceGate.begin()
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = try? await self.workflowPersistenceExecutor.clearWorkflowSnapshot(
                    request: request
                )
            }
        }
        if navigateToImport {
            setStage(.importHub)
        }
    }

    func exportedText() -> String {
        guard let songPlan else { return "还没有可复制的歌单" }
        return textExporter.export(plan: songPlan)
    }

    func exportedShareText() -> String {
        guard let songPlan else { return "还没有可分享的歌单" }
        return shareTextExporter.export(plan: songPlan)
    }

    func exportedJSON() -> String {
        guard let songPlan else { return "{}" }
        return (try? jsonExporter.export(plan: songPlan)) ?? "{}"
    }

    func reopenRecentPlaylist(_ playlist: ImportedPlaylist) {
        cancelWorkflowOperation()
        prepareForReview(
            playlist: playlist,
            recommendationInputSource: recommendationInputSource(for: playlist.source)
        )
    }

    func pendingStoreDeadline() -> MonotonicOperationDeadline {
        MonotonicOperationDeadline(timeoutNanoseconds: 1_000_000_000)
    }

    func run(
        _ loadingMessage: String,
        operation: @escaping (UInt64, MonotonicOperationDeadline) async throws -> Void
    ) async {
        guard !isWorking,
              let request = workflowOperationGate.beginIfIdle() else { return }
        isWorking = true
        errorMessage = nil
        statusMessage = loadingMessage
        #if DEBUG
        let timeoutNanoseconds: UInt64 = ProcessInfo.processInfo.arguments.contains("-singreadyShortImportTimeout")
            ? 500_000_000
            : 20_000_000_000
        #else
        let timeoutNanoseconds: UInt64 = 20_000_000_000
        #endif
        let operationDeadline = MonotonicOperationDeadline(timeoutNanoseconds: timeoutNanoseconds)
        let task: Task<WorkflowOperationOutcome, Never> = Task { @MainActor [weak self] in
            guard let self else { return .discarded }
            let outcome: WorkflowOperationOutcome
            do {
                try await operation(request, operationDeadline)
                outcome = .succeeded
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            guard self.workflowOperationGate.finish(request) else {
                return .discarded
            }
            return outcome
        }
        workflowOperationTask = task
        let timeoutTask = Task { @MainActor [weak self] in
            do {
                let remainingNanoseconds = operationDeadline.remainingNanoseconds()
                if remainingNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: remainingNanoseconds)
                }
            } catch {
                return
            }
            guard let self,
                  self.workflowOperationGate.finish(request) else { return }
            task.cancel()
            self.workflowOperationTask = nil
            self.workflowOperationTimeoutTask = nil
            self.isWorking = false
            self.errorMessage = "处理时间太久，已取消。可以重试，或改用粘贴文本。"
            self.statusMessage = self.errorMessage ?? Self.idleStatusMessage
        }
        workflowOperationTimeoutTask = timeoutTask
        defer { timeoutTask.cancel() }
        let outcome = await task.value
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-singreadyDelayWorkflowCompletion") {
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        #endif
        switch outcome {
        case .succeeded:
            break
        case .cancelled:
            statusMessage = Self.idleStatusMessage
        case let .failed(message):
            errorMessage = message
            statusMessage = message
        case .discarded:
            return
        }
        workflowOperationTask = nil
        workflowOperationTimeoutTask = nil
        isWorking = false
    }

    func acceptsWorkflowOperation(_ request: UInt64) -> Bool {
        !Task.isCancelled && workflowOperationGate.accepts(request)
    }

    func cancelWorkflowOperation() {
        planPreparationGeneration &+= 1
        planPreparationTask?.cancel()
        planPreparationTask = nil
        workflowOperationGate.cancel()
        workflowOperationTask?.cancel()
        workflowOperationTimeoutTask?.cancel()
        workflowOperationTask = nil
        workflowOperationTimeoutTask = nil
        isWorking = false
    }

    func cancelCurrentImport() {
        guard isWorking else { return }
        cancelWorkflowOperation()
        statusMessage = "已取消本次导入"
    }

    func cancelCurrentMatching() {
        guard isWorking else { return }
        cancelWorkflowOperation()
        statusMessage = "已取消本次核对"
    }

    func acceptsLocalDataEpoch(_ epoch: UInt64) -> Bool {
        epoch == localDataEpoch
    }

    func invalidateLocalDataEpoch() {
        localDataEpoch &+= 1
    }
}
