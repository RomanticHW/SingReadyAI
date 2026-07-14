import Foundation
import SingReadyAISharedKit

enum WorkflowOperationOutcome: Sendable {
    case succeeded
    case cancelled
    case failed(String)
    case discarded
}

private struct ImportCancellationReservation {
    let generation: UInt64
    let snapshot: WorkflowSnapshot?
    let snapshotRevision: UInt64
}

@MainActor
extension DemoWorkflowStore {
    func resetImport(
        navigateToImport: Bool = true,
        clearPersistedSnapshot: Bool = true
    ) {
        planStateTransitionGate.invalidate()
        cancelExternalCandidateRequest()
        importedPlaylist = nil
        replaceReviewSongs([])
        replaceWorkflowRevisions(WorkflowRevisionLedger())
        replaceCompletedAnalysis(nil)
        setMatchOperationState(.notStarted)
        recommendationInputSource = .userImport
        setPlanGenerationState(.absent)
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
        guard let readySongPlan else { return readyPlanUnavailableMessage }
        return textExporter.export(plan: readySongPlan)
    }

    func exportedShareText() -> String {
        guard let readySongPlan else { return readyPlanUnavailableMessage }
        return shareTextExporter.export(plan: readySongPlan)
    }

    func exportedJSON() -> String {
        guard let readySongPlan else { return "{}" }
        return (try? jsonExporter.export(plan: readySongPlan)) ?? "{}"
    }

    var readyPlanUnavailableMessage: String {
        "歌单还没按最新选择更新，请先重新排一版。"
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
        setImportOperationState(.resolving)
        errorMessage = nil
        statusMessage = loadingMessage
        let generation = workflowSnapshotPersistenceGate.begin()
        await workflowPersistenceExecutor.reserveWorkflowMutation(generation: generation)
        guard importOperationGate.accepts(request) else { return }
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

    func acceptsImportOperation(_ request: UInt64) -> Bool {
        !Task.isCancelled && importOperationGate.accepts(request)
    }

    func acceptsImportGeneration(_ generation: UInt64) -> Bool {
        !Task.isCancelled && workflowSnapshotPersistenceGate.accepts(generation)
    }

    func cancelWorkflowOperation() {
        let hadActiveMatch: Bool
        if case .running = matchOperationState {
            hadActiveMatch = true
        } else {
            hadActiveMatch = matchOperationTask != nil
        }
        let hadActivePlan = isGeneratingPlan || planGenerationTask != nil
        planPreparationGeneration &+= 1
        planPreparationTask?.cancel()
        planPreparationTask = nil
        matchOperationGate.cancel()
        matchOperationTask?.cancel()
        matchOperationTimeoutTask?.cancel()
        matchOperationTask = nil
        matchOperationTimeoutTask = nil
        if hadActivePlan {
            invalidatePlan(reason: "这次重排已取消")
        }
        if hadActiveMatch {
            setMatchOperationState(.cancelled)
            reserveCancellationOfCurrentMatchCommit()
        }
    }

    func cancelCurrentImport() {
        guard let reservation = beginImportCancellation(
            state: .cancelled,
            status: "已取消本次导入，之前的歌单和结果都还在。"
        ) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishImportCancellation(reservation)
        }
    }

    func cancelCurrentImportAndWait(
        state: ImportOperationState = .cancelled,
        status: String = "已取消本次导入，之前的歌单和结果都还在。"
    ) async {
        guard let reservation = beginImportCancellation(state: state, status: status) else {
            return
        }
        await finishImportCancellation(reservation)
    }

    private func beginImportCancellation(
        state: ImportOperationState,
        status: String
    ) -> ImportCancellationReservation? {
        guard isImportResolving, !isCommittingImportedWorkflow else { return nil }
        importOperationGate.cancel()
        importOperationTask?.cancel()
        importOperationTimeoutTask?.cancel()
        importOperationTask = nil
        importOperationTimeoutTask = nil
        let generation = workflowSnapshotPersistenceGate.begin()
        let reservation = ImportCancellationReservation(
            generation: generation,
            snapshot: workflowSnapshotForPersistence(),
            snapshotRevision: workflowSnapshotRevision
        )
        setImportOperationState(state)
        statusMessage = status
        if case .failed = state { errorMessage = status }
        return reservation
    }

    private func finishImportCancellation(
        _ reservation: ImportCancellationReservation
    ) async {
        await workflowPersistenceExecutor.reserveWorkflowMutation(
            generation: reservation.generation
        )
        do {
            let didApply: Bool
            if let snapshot = reservation.snapshot {
                didApply = try await workflowPersistenceExecutor.commitWorkflowSnapshot(
                    snapshot,
                    generation: reservation.generation
                ) == .applied
            } else {
                let result = try await workflowPersistenceExecutor.clearWorkflowSnapshot(
                    request: reservation.generation
                )
                if case .applied = result {
                    didApply = true
                } else {
                    didApply = false
                }
            }
            if didApply,
               workflowSnapshotPersistenceGate.accepts(reservation.generation),
               workflowSnapshotRevision == reservation.snapshotRevision {
                lastWorkflowSnapshotAttemptRevision = reservation.snapshotRevision
            }
        } catch {
            guard workflowSnapshotPersistenceGate.accepts(reservation.generation) else { return }
            errorMessage = "之前的进度暂时没保存下来，请稍后再试。"
        }
    }

    func cancelCurrentMatching() {
        guard case .running = matchOperationState else { return }
        cancelWorkflowOperation()
        setMatchOperationState(.cancelled)
        statusMessage = "已取消本次核对"
    }

    private func reserveCancellationOfCurrentMatchCommit() {
        let cancellationGeneration = workflowSnapshotPersistenceGate.begin()
        Task { [workflowPersistenceExecutor] in
            await workflowPersistenceExecutor.reserveWorkflowMutation(
                generation: cancellationGeneration
            )
        }
    }

    func acceptsLocalDataEpoch(_ epoch: UInt64) -> Bool {
        epoch == localDataEpoch
    }

    func invalidateLocalDataEpoch() {
        localDataEpoch &+= 1
    }
}
