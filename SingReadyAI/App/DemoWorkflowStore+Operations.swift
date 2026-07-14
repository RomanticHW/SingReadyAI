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
        replaceReviewSongs([])
        replaceWorkflowRevisions(WorkflowRevisionLedger())
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
            let generation = workflowSnapshotPersistenceGate.begin()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.workflowPersistenceExecutor.reserveWorkflowMutation(
                    generation: generation
                )
                _ = try? await self.workflowPersistenceExecutor.clearWorkflowSnapshot(
                    request: generation
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
        guard !isImportInteractionDisabled else { return }
        Task { @MainActor [weak self] in
            await self?.importResolvedPlaylist(
                playlist: playlist,
                recommendationInputSource: self?.recommendationInputSource(
                    for: playlist.source
                ) ?? .userImport
            )
        }
    }

    func pendingStoreDeadline() -> MonotonicOperationDeadline {
        MonotonicOperationDeadline(timeoutNanoseconds: 1_000_000_000)
    }

    func runImport(
        _ loadingMessage: String,
        operation: @escaping (
            UInt64,
            UInt64,
            MonotonicOperationDeadline
        ) async throws -> Void
    ) async {
        guard !isImportInteractionDisabled,
              let request = importOperationGate.beginIfIdle() else { return }
        let generation = workflowSnapshotPersistenceGate.begin()
        await workflowPersistenceExecutor.reserveWorkflowMutation(generation: generation)
        guard importOperationGate.accepts(request) else { return }

        setImportOperationState(.resolving)
        errorMessage = nil
        statusMessage = loadingMessage
        #if DEBUG
        let timeoutNanoseconds: UInt64 = ProcessInfo.processInfo.arguments.contains(
            "-singreadyShortImportTimeout"
        ) ? 500_000_000 : 20_000_000_000
        #else
        let timeoutNanoseconds: UInt64 = 20_000_000_000
        #endif
        let deadline = MonotonicOperationDeadline(timeoutNanoseconds: timeoutNanoseconds)
        let task: Task<WorkflowOperationOutcome, Never> = Task { @MainActor [weak self] in
            guard let self else { return .discarded }
            do {
                try await operation(request, generation, deadline)
                guard self.importOperationGate.finish(request) else { return .discarded }
                return .succeeded
            } catch is CancellationError {
                guard self.importOperationGate.finish(request) else { return .discarded }
                return .cancelled
            } catch {
                guard self.importOperationGate.finish(request) else { return .discarded }
                return .failed(error.localizedDescription)
            }
        }
        importOperationTask = task
        let timeoutTask = Task { @MainActor [weak self] in
            let remaining = deadline.remainingNanoseconds()
            if remaining > 0 {
                do { try await Task.sleep(nanoseconds: remaining) } catch { return }
            }
            guard let self, self.importOperationGate.accepts(request) else { return }
            await self.cancelCurrentImportAndWait(
                state: .failed(
                    message: "处理时间太久，已取消。可以重试，或改用粘贴文本。",
                    retryable: true
                ),
                status: "处理时间太久，已取消。可以重试，或改用粘贴文本。"
            )
        }
        importOperationTimeoutTask = timeoutTask
        let outcome = await task.value
        timeoutTask.cancel()
        guard case .discarded = outcome else {
            importOperationTask = nil
            importOperationTimeoutTask = nil
            switch outcome {
            case .succeeded:
                setImportOperationState(.idle)
            case .cancelled:
                setImportOperationState(.cancelled)
            case let .failed(message):
                setImportOperationState(.failed(message: message, retryable: true))
                errorMessage = message
                statusMessage = message
            case .discarded:
                break
            }
            return
        }
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

    func acceptsImportOperation(_ request: UInt64) -> Bool {
        !Task.isCancelled && importOperationGate.accepts(request)
    }

    func acceptsImportGeneration(_ generation: UInt64) -> Bool {
        !Task.isCancelled && workflowSnapshotPersistenceGate.accepts(generation)
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
        guard let generation = beginImportCancellation(
            state: .cancelled,
            status: "已取消本次导入"
        ) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.workflowPersistenceExecutor.reserveWorkflowMutation(
                generation: generation
            )
        }
    }

    func cancelCurrentImportAndWait(
        state: ImportOperationState = .cancelled,
        status: String = "已取消本次导入"
    ) async {
        guard let generation = beginImportCancellation(state: state, status: status) else {
            return
        }
        await workflowPersistenceExecutor.reserveWorkflowMutation(generation: generation)
    }

    private func beginImportCancellation(
        state: ImportOperationState,
        status: String
    ) -> UInt64? {
        guard isImportResolving, !isCommittingImportedWorkflow else { return nil }
        importOperationGate.cancel()
        importOperationTask?.cancel()
        importOperationTimeoutTask?.cancel()
        importOperationTask = nil
        importOperationTimeoutTask = nil
        let generation = workflowSnapshotPersistenceGate.begin()
        setImportOperationState(state)
        statusMessage = status
        if case .failed = state { errorMessage = status }
        return generation
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
