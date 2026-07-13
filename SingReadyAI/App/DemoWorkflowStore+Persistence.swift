import Combine
import Foundation
import SingReadyAISharedKit

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
            matches: matches,
            preferenceProfile: preferenceProfile,
            voiceProfile: voiceProfile,
            recommendationInputSource: recommendationInputSource,
            scenarioConfig: scenarioConfig,
            songPlan: songPlan,
            lockedTrackIDs: Array(lockedTrackIDs),
            removedTrackIDs: Array(removedTrackIDs),
            externalCandidateTracks: externalCandidateTracks,
            feedbackProfile: feedbackProfile,
            hasAdvancedToScenario: hasAdvancedToScenario
        )
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

    func restoreWorkflowSnapshot(request: UInt64? = nil) async {
        let request = request ?? workflowSnapshotPersistenceGate.begin()
        do {
            let requestResult = try await workflowPersistenceExecutor.loadWorkflowSnapshot(
                request: request
            )
            guard workflowSnapshotPersistenceGate.accepts(request),
                  case let .applied(loadResult) = requestResult else { return }
            let snapshot: WorkflowSnapshot
            switch loadResult {
            case .missing:
                return
            case let .loaded(loadedSnapshot):
                snapshot = loadedSnapshot
            case .quarantined(.corrupt):
                errorMessage = "上次整理进度已损坏，已单独收好；可以重新导入歌单。"
                return
            case .quarantined(.incompatibleVersion):
                errorMessage = "上次整理进度来自其他版本，已单独收好；可以重新开始。"
                return
            case .quarantined(.oversized):
                errorMessage = "上次整理进度异常过大，已单独收好；可以重新导入歌单。"
                return
            }
            isApplyingRestoredWorkflowSnapshot = true
            defer { isApplyingRestoredWorkflowSnapshot = false }
            importedPlaylist = snapshot.importedPlaylist
            reviewSongs = snapshot.reviewSongs.map { savedSong in
                var draft = EditableImportedSongDraft(song: savedSong.importedSong)
                draft.isDeleted = savedSong.isDeleted
                return draft
            }
            matches = snapshot.matches
            preferenceProfile = snapshot.preferenceProfile
            voiceProfile = snapshot.voiceProfile
            recommendationInputSource = snapshot.recommendationInputSource
            scenarioConfig = snapshot.scenarioConfig
            songPlan = snapshot.songPlan
            lockedTrackIDs = Set(snapshot.lockedTrackIDs)
            removedTrackIDs = Set(snapshot.removedTrackIDs).subtracting(lockedTrackIDs)
            externalCandidateTracks = snapshot.externalCandidateTracks
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
            if !hasStandaloneFeedbackRecord {
                SongFeedbackLocalStore().save(feedbackProfile)
                hasStandaloneFeedbackRecord = true
            }
            hasAdvancedToScenario = snapshot.hasAdvancedToScenario ?? false
            reconcileRestoredWorkflowConsistency(
                shouldRefreshPlanForFeedback: shouldRefreshPlanForFeedback
            )
            externalCandidateStatus = externalCandidateTracks.isEmpty
                ? "还没找同歌手备选"
                : "已恢复 \(externalCandidateTracks.count) 首备选"
            statusMessage = songPlan == nil ? "已恢复上次整理进度" : "已恢复上次排好的歌单"
        } catch {
            guard workflowSnapshotPersistenceGate.accepts(request) else { return }
            errorMessage = "上次整理进度暂时读不到，请稍后再试。"
        }
    }

    func restoreStandaloneVoiceProfileIfNeeded(request: UInt64, epoch: UInt64) async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-singreadyDelayVoiceProfileRestoreRace") {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
        #endif
        guard voiceProfilePersistenceGate.accepts(request),
              acceptsLocalDataEpoch(epoch),
              !isManagingLocalData else { return }
        do {
            let result = try await voiceProfileStore.loadWithStatus()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-singreadyDelayVoiceProfileRestoreRace") {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            #endif
            guard voiceProfilePersistenceGate.accepts(request),
                  acceptsLocalDataEpoch(epoch),
                  !isManagingLocalData else { return }
            switch result {
            case .missing:
                if let migrationCandidate = VoiceProfileRestorePolicy
                    .standaloneMigrationCandidate(current: voiceProfile) {
                    _ = try await voiceProfileStore.saveIfEligible(migrationCandidate)
                }
                return
            case let .loaded(profile):
                let preferred = VoiceProfileRestorePolicy.preferred(
                    current: voiceProfile,
                    standalone: profile
                )
                if preferred != voiceProfile {
                    voiceProfile = preferred
                }
            case .quarantined(.corrupt):
                errorMessage = "上次保存的实测音区已损坏，已单独收好；可以重新测一次。"
            case .quarantined(.incompatibleVersion):
                errorMessage = "上次实测音区来自其他版本，已单独收好；可以重新测一次。"
            case .quarantined(.oversized):
                errorMessage = "上次实测音区记录异常过大，已单独收好；可以重新测一次。"
            }
        } catch {
            guard voiceProfilePersistenceGate.accepts(request),
                  acceptsLocalDataEpoch(epoch),
                  !isManagingLocalData else { return }
            if voiceProfile?.hasValidMeasuredRange != true {
                errorMessage = "上次测到的音区暂时读不到，可以重新测一次。"
            }
        }
    }

    func observeWorkflowSnapshotChanges() {
        $navigationPath
            .dropFirst()
            .sink { [weak self] path in
                guard let self,
                      self.isWorking,
                      !self.isCompletingWorkflowNavigation else { return }
                self.cancelWorkflowOperation()
                self.statusMessage = Self.idleStatusMessage
            }
            .store(in: &workflowSnapshotSubscriptions)

        $reviewSongs
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] reviewSongs in
                guard let self,
                      !self.isApplyingRestoredWorkflowSnapshot else { return }
                if self.isWorking, self.currentStage == .review {
                    self.cancelWorkflowOperation()
                    self.statusMessage = "歌名有变化，本次核对已取消"
                }
                self.invalidateDownstreamIfReviewChanged(reviewSongs)
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

        $externalCandidateTracks
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self,
                      !self.isApplyingRestoredWorkflowSnapshot else { return }
                self.invalidatePlanForExternalCandidateChange()
            }
            .store(in: &workflowSnapshotSubscriptions)

        let changes: [AnyPublisher<Void, Never>] = [
            $importedPlaylist.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $reviewSongs.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $matches.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $preferenceProfile.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $voiceProfile.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $recommendationInputSource.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $scenarioConfig.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $songPlan.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $lockedTrackIDs.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $removedTrackIDs.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $externalCandidateTracks.dropFirst().map { _ in () }.eraseToAnyPublisher(),
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

    private func reconcileRestoredWorkflowConsistency(
        shouldRefreshPlanForFeedback: Bool
    ) {
        if reviewSongsDifferFromImportedPlaylist(reviewSongs) {
            invalidateDownstreamForReviewChange()
            return
        }
        if let restoredConfig = songPlan?.scenarioConfig,
           restoredConfig != scenarioConfig {
            songPlan = nil
            statusMessage = "已恢复场景调整，请重新排今晚歌单"
            return
        }
        if let restoredPlan = songPlan,
           restoredPlan.voiceProfile != voiceProfile {
            songPlan = nil
            statusMessage = "已恢复音区调整，请重新排今晚歌单"
            return
        }
        if shouldRefreshPlanForFeedback {
            guard preferenceProfile != nil else {
                songPlan = nil
                statusMessage = "已恢复歌曲反馈，请重新排今晚歌单"
                return
            }
            generatePlan(navigate: false, schedulesPersistence: false)
        }
    }

    private func invalidateDownstreamIfReviewChanged(_ reviewSongs: [EditableImportedSongDraft]) {
        guard reviewSongsDifferFromImportedPlaylist(reviewSongs) else { return }
        invalidateDownstreamForReviewChange()
    }

    private func invalidateDownstreamForReviewChange() {
        guard !matches.isEmpty
                || preferenceProfile != nil
                || songPlan != nil
                || !lockedTrackIDs.isEmpty
                || !removedTrackIDs.isEmpty
                || !externalCandidateTracks.isEmpty else {
            return
        }
        invalidateExternalCandidateContext()
        matches = []
        preferenceProfile = nil
        hasAdvancedToScenario = false
        songPlan = nil
        lockedTrackIDs = []
        removedTrackIDs = []
        lastRemovedTrackUndo = nil
        statusMessage = "歌名有变化，请重新核对参考匹配"
    }

    private func invalidatePlanIfScenarioChanged(_ scenarioConfig: ScenarioConfig) {
        guard let songPlan,
              songPlan.scenarioConfig != scenarioConfig else { return }
        self.songPlan = nil
        lastRemovedTrackUndo = nil
        statusMessage = "场景已调整，请重新排今晚歌单"
    }

    private func invalidatePlanIfVoiceChanged(_ voiceProfile: VoiceProfile?) {
        guard let songPlan,
              songPlan.voiceProfile != voiceProfile else { return }
        self.songPlan = nil
        lastRemovedTrackUndo = nil
        statusMessage = "音区参考已更新，请重新排今晚歌单"
    }

    func invalidatePlanForExternalCandidateChange() {
        guard songPlan != nil else { return }
        songPlan = nil
        lastRemovedTrackUndo = nil
        statusMessage = "备选歌曲已更新，请重新排今晚歌单"
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
