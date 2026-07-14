import Combine
import Foundation
import SingReadyAISharedKit

struct WorkflowSnapshotCommitReservation {
    let generation: UInt64
    let candidate: WorkflowSnapshotCommitCandidate
}

@MainActor
extension DemoWorkflowStore {
    static func recentPlaylistsURL() -> URL {
        persistenceStoreURL(fileName: "recent_playlists.json")
    }

    static func workflowSnapshotURL() -> URL {
        persistenceStoreURL(fileName: "workflow_snapshot.json")
    }

    static func voiceProfileURL() -> URL {
        persistenceStoreURL(fileName: "voice_profile.json")
    }

    private static func persistenceStoreURL(fileName: String) -> URL {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-singreadyFailRecoverableImportPersistence") {
            let fixtureDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "SingReadyPersistenceFailure-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(
                at: fixtureDirectory,
                withIntermediateDirectories: true
            )
            let blockedParent = fixtureDirectory.appendingPathComponent("blocked-parent")
            if !FileManager.default.fileExists(atPath: blockedParent.path) {
                _ = FileManager.default.createFile(atPath: blockedParent.path, contents: Data())
            }
            return blockedParent.appendingPathComponent(fileName)
        }
        #endif
        return localStorageDirectoryURL().appendingPathComponent(fileName)
    }

    private static func localStorageDirectoryURL() -> URL {
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingReadyAI", isDirectory: true)
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fallback
        return base.appendingPathComponent("SingReadyAI", isDirectory: true)
    }

    @discardableResult
    func persistWorkflowSnapshot(reportFailure: Bool = true) async -> Bool {
        guard !isImportPersistenceLocked else { return false }
        let revision = workflowSnapshotRevision
        let request = workflowSnapshotPersistenceGate.begin()
        lastWorkflowSnapshotAttemptRevision = revision
        return await persistWorkflowSnapshot(
            workflowSnapshotForPersistence(),
            revision: revision,
            request: request,
            reportFailure: reportFailure
        )
    }

    func workflowSnapshotForPersistence() -> WorkflowSnapshot? {
        workflowSnapshotForPersistence(
            completedAnalysis: completedAnalysis,
            revisions: revisions,
            planGenerationState: planGenerationState,
            externalCandidateCollection: externalCandidateCollection
        )
    }

    func workflowSnapshotForPersistence(
        completedAnalysis: CompletedPlaylistAnalysis?,
        revisions: WorkflowRevisionLedger,
        planGenerationState: PlanGenerationState,
        externalCandidateCollection: ExternalCandidateCollection?
    ) -> WorkflowSnapshot? {
        guard let importedPlaylist else { return nil }
        return WorkflowSnapshot(
            importedPlaylist: importedPlaylist,
            reviewSongs: reviewSongs.map { draft in
                WorkflowReviewSong(
                    id: draft.id,
                    title: draft.title,
                    artist: draft.artist,
                    source: draft.source,
                    rawText: draft.rawText,
                    confidence: draft.confidence,
                    versionTags: draft.versionTags,
                    isDeleted: draft.isDeleted
                )
            },
            revisions: revisions,
            completedAnalysis: completedAnalysis,
            persistedPlanRecord: PersistedPlanRecord(
                planGenerationState: planGenerationState
            ),
            externalCandidateCollection: externalCandidateCollection,
            voiceProfile: voiceProfile,
            recommendationInputSource: recommendationInputSource,
            scenarioConfig: scenarioConfig,
            lockedTrackIDs: Array(lockedTrackIDs),
            removedTrackIDs: Array(removedTrackIDs),
            feedbackProfile: feedbackProfile,
            hasAdvancedToScenario: hasAdvancedToScenario,
            legacySongPlan: nil,
            legacyExternalCandidateTracks: []
        )
    }

    func reservePlanStateSnapshotCommit(
        _ state: PlanGenerationState,
        advancesRevision: Bool = true
    ) -> WorkflowSnapshotCommitReservation? {
        if advancesRevision {
            workflowSnapshotRevision &+= 1
        }
        let revision = workflowSnapshotRevision
        let generation = workflowSnapshotPersistenceGate.begin()
        guard let snapshot = workflowSnapshotForPersistence(
            completedAnalysis: completedAnalysis,
            revisions: revisions,
            planGenerationState: state,
            externalCandidateCollection: externalCandidateCollection
        ) else {
            return nil
        }
        return WorkflowSnapshotCommitReservation(
            generation: generation,
            candidate: WorkflowSnapshotCommitCandidate(
                snapshot: snapshot,
                revision: revision
            )
        )
    }

    @discardableResult
    func commitReservedWorkflowSnapshot(
        _ reservation: WorkflowSnapshotCommitReservation,
        reportFailure: Bool
    ) async -> WorkflowSnapshotCommitResult? {
        await workflowPersistenceExecutor.reserveWorkflowMutation(
            generation: reservation.generation
        )
        do {
            let result = try await workflowPersistenceExecutor.commitWorkflowSnapshot(
                reservation.candidate,
                generation: reservation.generation
            )
            if case let .applied(revision) = result,
               workflowSnapshotPersistenceGate.accepts(reservation.generation),
               workflowSnapshotRevision == revision {
                lastWorkflowSnapshotAttemptRevision = revision
            }
            return result
        } catch {
            guard workflowSnapshotPersistenceGate.accepts(reservation.generation) else {
                return nil
            }
            if reportFailure {
                errorMessage = "当前进度暂时没保存下来，请稍后再试。"
            }
            return nil
        }
    }

    func persistPlanStateImmediately(
        _ state: PlanGenerationState,
        reportFailure: Bool
    ) {
        guard let reservation = reservePlanStateSnapshotCommit(state) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.commitReservedWorkflowSnapshot(
                reservation,
                reportFailure: reportFailure
            )
        }
    }

    private func persistWorkflowSnapshot(
        _ snapshot: WorkflowSnapshot?,
        revision: UInt64,
        request: UInt64,
        reportFailure: Bool
    ) async -> Bool {
        do {
            let result: WorkflowPersistenceRequestResult<Void>
            if let snapshot {
                result = try await workflowPersistenceExecutor.saveWorkflowSnapshot(
                    snapshot,
                    request: request
                )
            } else {
                result = try await workflowPersistenceExecutor.clearWorkflowSnapshot(
                    request: request
                )
            }
            guard workflowSnapshotPersistenceGate.accepts(request) else { return false }
            guard case .applied = result else { return false }
            lastWorkflowSnapshotAttemptRevision = revision
            return true
        } catch {
            guard workflowSnapshotPersistenceGate.accepts(request) else { return false }
            lastWorkflowSnapshotAttemptRevision = revision
            if reportFailure {
                errorMessage = "当前进度暂时没保存下来，请稍后再试。"
            }
            return false
        }
    }

    func restoreWorkflowSnapshot(
        request: UInt64,
        voiceProfileRequest: UInt64,
        voiceProfileEpoch: UInt64
    ) async {
        do {
            let requestResult = try await workflowPersistenceExecutor.loadWorkflowSnapshot(
                request: request
            )
            guard workflowSnapshotPersistenceGate.accepts(request),
                  case let .applied(loadResult) = requestResult else { return }
            let snapshot: WorkflowSnapshot
            switch loadResult {
            case .missing:
                await restoreStandaloneVoiceProfileIfNeeded(
                    request: voiceProfileRequest,
                    epoch: voiceProfileEpoch
                )
                return
            case let .loaded(loadedSnapshot):
                snapshot = loadedSnapshot
            case .quarantined(.corrupt):
                errorMessage = "上次整理进度已损坏，已单独收好；可以重新导入歌单。"
                await restoreStandaloneVoiceProfileIfNeeded(
                    request: voiceProfileRequest,
                    epoch: voiceProfileEpoch
                )
                return
            case .quarantined(.incompatibleVersion):
                errorMessage = "上次整理进度来自其他版本，已单独收好；可以重新开始。"
                await restoreStandaloneVoiceProfileIfNeeded(
                    request: voiceProfileRequest,
                    epoch: voiceProfileEpoch
                )
                return
            case .quarantined(.oversized):
                errorMessage = "上次整理进度异常过大，已单独收好；可以重新导入歌单。"
                await restoreStandaloneVoiceProfileIfNeeded(
                    request: voiceProfileRequest,
                    epoch: voiceProfileEpoch
                )
                return
            }
            let restoredVoiceProfile = await resolvedStandaloneVoiceProfile(
                current: snapshot.voiceProfile,
                request: voiceProfileRequest,
                epoch: voiceProfileEpoch
            )
            guard workflowSnapshotPersistenceGate.accepts(request) else { return }
            isApplyingRestoredWorkflowSnapshot = true
            defer { isApplyingRestoredWorkflowSnapshot = false }
            importedPlaylist = snapshot.importedPlaylist
            replaceReviewSongs(snapshot.reviewSongs.map { savedSong in
                var draft = EditableImportedSongDraft(song: savedSong.importedSong)
                draft.isDeleted = savedSong.isDeleted
                return draft
            })
            replaceWorkflowRevisions(snapshot.revisions)
            let restoredAnalysis: CompletedPlaylistAnalysis?
            if let basis = currentMatchBasis,
               PlaylistWorkflowValidityPolicy.restoredMatchState(
                   persistedAnalysis: snapshot.completedAnalysis,
                   currentBasis: basis,
                   currentMatchRevision: snapshot.revisions.match,
                   playlist: snapshot.importedPlaylist,
                   reviewSongs: snapshot.reviewSongs
               ) == .ready(basis) {
                restoredAnalysis = snapshot.completedAnalysis
                setMatchOperationState(.ready(basis))
            } else {
                restoredAnalysis = nil
                setMatchOperationState(.notStarted)
            }
            replaceCompletedAnalysis(restoredAnalysis)
            voiceProfile = restoredVoiceProfile
            recommendationInputSource = snapshot.recommendationInputSource
            scenarioConfig = snapshot.scenarioConfig
            lockedTrackIDs = Set(snapshot.lockedTrackIDs)
            removedTrackIDs = Set(snapshot.removedTrackIDs).subtracting(lockedTrackIDs)
            if let restoredCandidates = snapshot.externalCandidateCollection,
               restoredCandidates.basis.playlistID == snapshot.importedPlaylist.id,
               restoredCandidates.basis.reviewRevision == snapshot.revisions.review {
                externalCandidateCollection = restoredCandidates
            } else {
                externalCandidateCollection = nil
            }
            // 歌曲反馈以同步写入的独立本机记录为真源。快照字段仅用于旧版本迁移，
            // 不能覆盖用户在快照落盘前刚刚保存的新反馈。
            let standaloneFeedback = hasStandaloneFeedbackRecord ? feedbackProfile : nil
            let restoredFeedback = SongFeedbackRestorePolicy.preferred(
                standalone: standaloneFeedback,
                snapshot: snapshot.feedbackProfile
            )
            let shouldRefreshPlanForFeedback = SongFeedbackRestorePolicy.shouldRefreshPlan(
                standalone: standaloneFeedback,
                snapshot: snapshot.feedbackProfile,
                hasRestoredPlan: snapshot.songPlan != nil
            )
            if restoredFeedback != feedbackProfile {
                feedbackProfile = restoredFeedback
            }
            if hasStandaloneFeedbackRecord,
               revisions.feedback != standaloneFeedbackRevision {
                var restoredRevisions = revisions
                restoredRevisions.feedback = standaloneFeedbackRevision
                replaceWorkflowRevisions(restoredRevisions)
            }
            if !hasStandaloneFeedbackRecord {
                try? SongFeedbackLocalStore().save(
                    SongFeedbackRecord(
                        revision: snapshot.revisions.feedback,
                        profile: feedbackProfile
                    )
                )
                hasStandaloneFeedbackRecord = true
                standaloneFeedbackRevision = snapshot.revisions.feedback
            }
            let restoredPlanState: PlanGenerationState
            if let record = snapshot.persistedPlanRecord {
                switch record.restoredPlanGenerationState {
                case let .ready(plan, basis):
                    if currentPlanBasis == basis,
                       planMatchesCurrentGenerationContext(plan, basis: basis) {
                        restoredPlanState = .ready(plan: plan, basis: basis)
                    } else {
                        restoredPlanState = .stale(
                            StalePlanSnapshot(
                                plan: plan,
                                previousBasis: basis,
                                reason: "排歌条件已经更新，请重新排一版"
                            )
                        )
                    }
                case let .stale(snapshot):
                    restoredPlanState = .stale(snapshot)
                case .absent, .generating, .failed:
                    restoredPlanState = .absent
                }
            } else if let legacyPlan = snapshot.songPlan {
                restoredPlanState = .legacyStale(plan: legacyPlan)
            } else {
                restoredPlanState = .absent
            }
            setPlanGenerationState(restoredPlanState)
            hasAdvancedToScenario = snapshot.hasAdvancedToScenario ?? false
            if shouldRefreshPlanForFeedback {
                invalidatePlan(reason: "歌曲反馈已更新")
            }
            externalCandidateStatus = externalCandidates.isEmpty
                ? "还没找同歌手备选"
                : "已恢复 \(externalCandidates.count) 首公开候选"
            statusMessage = visibleSongPlan == nil
                ? "已恢复上次整理进度"
                : (canUseReadyPlan ? "已恢复上次排好的歌单" : "已恢复上一版歌单，请按最新选择重排")
        } catch {
            guard workflowSnapshotPersistenceGate.accepts(request) else { return }
            errorMessage = "上次整理进度暂时读不到，请稍后再试。"
            await restoreStandaloneVoiceProfileIfNeeded(
                request: voiceProfileRequest,
                epoch: voiceProfileEpoch
            )
        }
    }

    func restoreStandaloneVoiceProfileIfNeeded(request: UInt64, epoch: UInt64) async {
        let restored = await resolvedStandaloneVoiceProfile(
            current: voiceProfile,
            request: request,
            epoch: epoch
        )
        guard voiceProfilePersistenceGate.accepts(request),
              acceptsLocalDataEpoch(epoch),
              !isManagingLocalData else { return }
        if restored != voiceProfile {
            voiceProfile = restored
        }
    }

    private func resolvedStandaloneVoiceProfile(
        current: VoiceProfile?,
        request: UInt64,
        epoch: UInt64
    ) async -> VoiceProfile? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-singreadyDelayVoiceProfileRestoreRace") {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
        #endif
        guard voiceProfilePersistenceGate.accepts(request),
              acceptsLocalDataEpoch(epoch),
              !isManagingLocalData else { return current }
        do {
            let result = try await voiceProfileStore.loadWithStatus()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-singreadyDelayVoiceProfileRestoreRace") {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            #endif
            guard voiceProfilePersistenceGate.accepts(request),
                  acceptsLocalDataEpoch(epoch),
                  !isManagingLocalData else { return current }
            switch result {
            case .missing:
                if let migrationCandidate = VoiceProfileRestorePolicy
                    .standaloneMigrationCandidate(current: current) {
                    _ = try await voiceProfileStore.saveIfEligible(migrationCandidate)
                }
                return current
            case let .loaded(profile):
                return VoiceProfileRestorePolicy.preferred(
                    current: current,
                    standalone: profile
                )
            case .quarantined(.corrupt):
                errorMessage = "上次保存的实测音区已损坏，已单独收好；可以重新测一次。"
            case .quarantined(.incompatibleVersion):
                errorMessage = "上次实测音区来自其他版本，已单独收好；可以重新测一次。"
            case .quarantined(.oversized):
                errorMessage = "上次实测音区记录异常过大，已单独收好；可以重新测一次。"
            }
            return current
        } catch {
            guard voiceProfilePersistenceGate.accepts(request),
                  acceptsLocalDataEpoch(epoch),
                  !isManagingLocalData else { return current }
            if current?.hasValidMeasuredRange != true {
                errorMessage = "上次测到的音区暂时读不到，可以重新测一次。"
            }
            return current
        }
    }

    func observeWorkflowSnapshotChanges() {
        $navigationPath
            .dropFirst()
            .sink { [weak self] path in
                guard let self else { return }
                if self.isImportResolving, !self.isCommittingImportedWorkflow {
                    self.cancelCurrentImport()
                    return
                }
                guard self.isWorking,
                      !self.isCompletingWorkflowNavigation else { return }
                self.cancelWorkflowOperation()
                self.statusMessage = Self.idleStatusMessage
            }
            .store(in: &workflowSnapshotSubscriptions)

        $scenarioConfig
            .dropFirst()
            .sink { [weak self] scenarioConfig in
                guard let self,
                      !self.isApplyingRestoredWorkflowSnapshot else { return }
                self.invalidatePlanIfScenarioChanged(scenarioConfig)
            }
            .store(in: &workflowSnapshotSubscriptions)

        $voiceProfile
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] voiceProfile in
                guard let self,
                      !self.isApplyingRestoredWorkflowSnapshot else { return }
                self.invalidatePlanIfVoiceChanged(voiceProfile)
            }
            .store(in: &workflowSnapshotSubscriptions)

        $recommendationInputSource
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self,
                      !self.isApplyingRestoredWorkflowSnapshot,
                      self.visibleSongPlan != nil || self.isGeneratingPlan else { return }
                self.invalidatePlan(reason: "歌单来源已更新")
            }
            .store(in: &workflowSnapshotSubscriptions)

        let changes: [AnyPublisher<Void, Never>] = [
            $importedPlaylist.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $reviewSongs.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $revisions.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $completedAnalysis.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $voiceProfile.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $recommendationInputSource.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $scenarioConfig.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $lockedTrackIDs.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $removedTrackIDs.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $externalCandidateCollection.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $feedbackProfile.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $hasAdvancedToScenario.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(changes)
            .filter { [weak self] in
                self?.isApplyingRestoredWorkflowSnapshot == false
            }
            .handleEvents(receiveOutput: { [weak self] in
                guard let self else { return }
                self.workflowSnapshotRevision &+= 1
                self.workflowSnapshotPersistenceGate.invalidate()
            })
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self,
                      !self.isImportPersistenceLocked,
                      self.lastWorkflowSnapshotAttemptRevision != self.workflowSnapshotRevision else {
                    return
                }
                let revision = self.workflowSnapshotRevision
                let request = self.workflowSnapshotPersistenceGate.begin()
                let snapshot = self.workflowSnapshotForPersistence()
                self.lastWorkflowSnapshotAttemptRevision = revision
                Task { @MainActor [weak self, snapshot] in
                    guard let self else { return }
                    _ = await self.persistWorkflowSnapshot(
                        snapshot,
                        revision: revision,
                        request: request,
                        reportFailure: true
                    )
                }
            }
            .store(in: &workflowSnapshotSubscriptions)
    }

    private func invalidateDownstreamIfReviewChanged(_ reviewSongs: [EditableImportedSongDraft]) {
        guard reviewSongsDifferFromImportedPlaylist(reviewSongs) else { return }
        invalidateDownstreamForReviewChange()
    }

    private func invalidateDownstreamForReviewChange() {
        guard !matches.isEmpty
                || preferenceProfile != nil
                || visibleSongPlan != nil
                || isGeneratingPlan
                || !lockedTrackIDs.isEmpty
                || !removedTrackIDs.isEmpty
                || externalCandidateCollection != nil else {
            return
        }
        let invalidatedPlanState = planGenerationState.invalidated(
            reason: "歌单内容已更新"
        )
        planGenerationGate.cancel()
        planGenerationTask?.cancel()
        planGenerationTask = nil
        invalidateExternalCandidateContext()
        replaceCompletedAnalysis(nil)
        setMatchOperationState(.notStarted)
        hasAdvancedToScenario = false
        setPlanGenerationState(invalidatedPlanState)
        lockedTrackIDs = []
        removedTrackIDs = []
        lastRemovedTrackUndo = nil
        statusMessage = "歌名有变化，请重新核对参考匹配"
    }

    private func invalidatePlanIfScenarioChanged(_ scenarioConfig: ScenarioConfig) {
        guard visibleSongPlan != nil || isGeneratingPlan else { return }
        invalidatePlan(reason: "场景已调整")
        statusMessage = "场景已调整，请重新排今晚歌单"
    }

    private func invalidatePlanIfVoiceChanged(_ voiceProfile: VoiceProfile?) {
        guard visibleSongPlan != nil || isGeneratingPlan else { return }
        invalidatePlan(reason: "音区参考已更新")
        statusMessage = "音区参考已更新，请重新排今晚歌单"
    }

    func reviewSongsDifferFromImportedPlaylist(
        _ reviewSongs: [EditableImportedSongDraft]
    ) -> Bool {
        guard let importedPlaylist else { return false }
        return reviewSongs
            .filter { !$0.isDeleted }
            .map { $0.importedSong() } != importedPlaylist.songs
    }
}
