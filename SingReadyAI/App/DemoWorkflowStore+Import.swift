import Foundation
import SingReadyAISharedKit

@MainActor
extension DemoWorkflowStore {
    func loadPendingImports() async {
        guard !isManagingLocalData else { return }
        let request = pendingImportPersistenceGate.begin()
        let epoch = localDataEpoch
        do {
            let loadedPendingImports = try await appGroupStore.loadPendingImports(
                deadline: pendingStoreDeadline()
            )
            guard pendingImportPersistenceGate.accepts(request),
                  !isManagingLocalData,
                  acceptsLocalDataEpoch(epoch) else { return }
            pendingImports = loadedPendingImports
        } catch is CancellationError {
            return
        } catch {
            guard pendingImportPersistenceGate.accepts(request),
                  !isManagingLocalData,
                  acceptsLocalDataEpoch(epoch) else { return }
            pendingImports = []
            errorMessage = "之前分享的一份歌单打不开了，已经先收好，不影响继续导入。"
        }
        guard pendingImportPersistenceGate.accepts(request),
              !isManagingLocalData else { return }
        isUsingFallbackStore = appGroupStore.isUsingFallbackStore()
    }

    func loadRecentPlaylists(request: UInt64? = nil) async {
        let request = request ?? recentPlaylistPersistenceGate.begin()
        do {
            let requestResult = try await workflowPersistenceExecutor.loadRecentPlaylists(
                request: request
            )
            guard recentPlaylistPersistenceGate.accepts(request),
                  case let .applied(loadResult) = requestResult else { return }
            switch loadResult {
            case .missing:
                recentPlaylists = []
            case let .loaded(playlists):
                recentPlaylists = playlists
            case .quarantined(.corrupt):
                recentPlaylists = []
                errorMessage = "一份最近导入记录已损坏，已单独收好；不影响继续导入。"
            case .quarantined(.incompatibleVersion):
                recentPlaylists = []
                errorMessage = "最近导入记录来自其他版本，已单独收好；不影响继续导入。"
            case .quarantined(.oversized):
                recentPlaylists = []
                errorMessage = "一份最近导入记录异常过大，已单独收好；不影响继续导入。"
            }
        } catch {
            guard recentPlaylistPersistenceGate.accepts(request) else { return }
            recentPlaylists = []
            errorMessage = "最近导入记录暂时读不到，请稍后再试。"
        }
    }

    func removePendingImport(id: UUID) async {
        guard !isManagingLocalData else { return }
        isManagingLocalData = true
        defer { isManagingLocalData = false }
        do {
            try await appGroupStore.removePendingImport(
                id: id,
                deadline: pendingStoreDeadline()
            )
            pendingImportPersistenceGate.invalidate()
            pendingImports.removeAll { $0.id == id }
            statusMessage = "已删除这份待整理内容"
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "这份待整理内容暂时删不掉，请稍后再试。"
        }
    }

    func removeRecentPlaylist(id: UUID) async {
        let request = recentPlaylistPersistenceGate.begin()
        do {
            let requestResult = try await workflowPersistenceExecutor.removeRecentPlaylist(
                id: id,
                request: request
            )
            guard recentPlaylistPersistenceGate.accepts(request),
                  case let .applied(playlists) = requestResult else { return }
            recentPlaylists = playlists
            statusMessage = "已删除这条最近导入"
        } catch {
            guard recentPlaylistPersistenceGate.accepts(request) else { return }
            errorMessage = "这条最近导入暂时删不掉，请稍后再试。"
        }
    }

    func clearAllLocalData() async {
        guard !isManagingLocalData else { return }
        isManagingLocalData = true
        defer { isManagingLocalData = false }
        invalidateLocalDataEpoch()
        pendingImportPersistenceGate.invalidate()
        recentPlaylistPersistenceGate.invalidate()
        workflowSnapshotPersistenceGate.invalidate()
        voiceProfilePersistenceGate.invalidate()
        let inFlightVoiceRecording = voiceRecordingTask
        await cancelCurrentImportAndWait()
        cancelWorkflowOperation()
        cancelVoiceRecording()
        await inFlightVoiceRecording?.value
        cancelExternalCandidateRequest()
        isApplyingRestoredWorkflowSnapshot = true
        pendingImports = []
        recentPlaylists = []
        feedbackProfile = .empty
        voiceProfile = nil
        scenarioConfig = ScenarioConfig()
        isApplyingRestoredWorkflowSnapshot = false
        let recentClearRequest = recentPlaylistPersistenceGate.begin()
        let snapshotClearRequest = workflowSnapshotPersistenceGate.begin()
        await workflowPersistenceExecutor.reserveWorkflowMutation(
            generation: snapshotClearRequest
        )
        var didFail = false
        var didClearWorkflowSnapshot = false
        do {
            try await appGroupStore.clearPendingImports(
                deadline: pendingStoreDeadline()
            )
        } catch {
            didFail = true
        }
        do {
            let result = try await workflowPersistenceExecutor.clearRecentPlaylists(
                request: recentClearRequest
            )
            if case .rejectedStaleRequest = result { didFail = true }
        } catch {
            didFail = true
        }
        do {
            let result = try await workflowPersistenceExecutor.clearWorkflowSnapshot(
                request: snapshotClearRequest
            )
            if case .rejectedStaleRequest = result {
                didFail = true
            } else {
                didClearWorkflowSnapshot = true
            }
        } catch {
            didFail = true
        }
        if didClearWorkflowSnapshot {
            isApplyingRestoredWorkflowSnapshot = true
            resetImport(
                navigateToImport: false,
                clearPersistedSnapshot: false
            )
            isApplyingRestoredWorkflowSnapshot = false
        }
        let artifactCleanupResult = await LocalArtifactCleaner(
            ocrTemporaryFileStore: ocrTemporaryFileStore
        ).clear()
        if !artifactCleanupResult.succeeded {
            didFail = true
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-singreadyDelayVoiceProfileRestoreRace") {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        #endif
        do {
            try await voiceProfileStore.clear()
        } catch {
            didFail = true
        }
        voiceProfilePersistenceGate.invalidate()
        voiceProfile = nil
        SongFeedbackLocalStore().clear()
        hasStandaloneFeedbackRecord = true

        statusMessage = didFail ? "部分本机记录暂时没清掉，请稍后再试。" : "本机记录已清除"
        errorMessage = didFail ? statusMessage : nil
    }

    func analyzePending(_ payload: PendingImportPayload) async {
        await runImport("正在读取分享内容") { [self] request, generation, operationDeadline in
            let playlist: ImportedPlaylist
            if payload.sourceHint == .screenshot, payload.imageFileName != nil {
                let imageURL = try appGroupStore.sharedImageURL(for: payload)
                let recognizedText = try await ocrService.recognizeText(fromImageAt: imageURL)
                playlist = try OCRPlaylistParser().parseValidated(
                    recognizedText: recognizedText,
                    title: payload.displayTitle ?? "分享截图"
                )
            } else {
                playlist = try await importCoordinator.resolve(payload: payload)
            }
            guard acceptsImportOperation(request), currentStage == .importHub else { return }
            let candidate = makeInitialWorkflowCandidate(
                playlist: playlist,
                inputSource: recommendationInputSource(for: playlist.source)
            )
            let commitResult: WorkflowCommitResult
            do {
                commitResult = try await commitImportedWorkflow(
                    candidate,
                    generation: generation,
                    navigate: false,
                    recordsRecentPlaylist: false
                )
            } catch {
                let message = "歌单暂时没保存下来，待整理内容已保留，请稍后重试。"
                errorMessage = message
                statusMessage = message
                return
            }
            guard case .applied = commitResult else { return }
            setCommittingImportedWorkflow(true)
            defer { setCommittingImportedWorkflow(false) }
            _ = await recordRecentImport(
                candidate.importedPlaylist,
                request: recentPlaylistPersistenceGate.begin(),
                failureMessage: "歌单已经打开，但“最近导入”暂时没保存下来。"
            )
            do {
                try await appGroupStore.removePendingImport(
                    id: payload.id,
                    deadline: operationDeadline
                )
                pendingImportPersistenceGate.invalidate()
                pendingImports.removeAll { $0.id == payload.id }
            } catch {
                errorMessage = "歌单已整理，但这条待处理记录暂时没删掉，可以稍后重试。"
            }
            setStage(.review)
        }
    }

    func useDemoPlaylist() async {
        await runImport("正在准备示例歌单") { [self] request, generation, _ in
            let playlist = try importCoordinator.resolveDemoPlaylist()
            guard acceptsImportOperation(request), currentStage == .importHub else { return }
            let candidate = makeInitialWorkflowCandidate(playlist: playlist, inputSource: .example)
            _ = try await commitImportedWorkflow(
                candidate,
                generation: generation,
                navigate: true
            )
        }
    }

    func importText(_ text: String) async {
        guard PlaylistImportTextPreflight.accepts(text) else {
            errorMessage = PlaylistImportTextPreflight.limitMessage
            statusMessage = errorMessage ?? statusMessage
            setImportOperationState(.failed(
                message: PlaylistImportTextPreflight.limitMessage,
                retryable: true
            ))
            return
        }
        await runImport("正在整理这段歌单") { [self] request, generation, _ in
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-singreadySlowImport") {
                try await Task.sleep(nanoseconds: 12_000_000_000)
            }
            #endif
            let payload = PendingImportPayload(sourceHint: .plainText, rawText: text, displayTitle: "粘贴导入歌单")
            let playlist = try await importCoordinator.resolve(payload: payload)
            guard acceptsImportOperation(request), currentStage == .importHub else { return }
            let candidate = makeInitialWorkflowCandidate(playlist: playlist, inputSource: .userImport)
            _ = try await commitImportedWorkflow(
                candidate,
                generation: generation,
                navigate: true
            )
        }
    }

    func importScreenshotFile(at temporaryURL: URL) async {
        await runImport("正在看截图里的歌名") { [self] request, generation, _ in
            let recognizedText = try await ocrService.recognizeText(fromImageAt: temporaryURL)
            let playlist = try OCRPlaylistParser().parseValidated(recognizedText: recognizedText)
            guard acceptsImportOperation(request), currentStage == .importHub else { return }
            let candidate = makeInitialWorkflowCandidate(playlist: playlist, inputSource: .userImport)
            _ = try await commitImportedWorkflow(
                candidate,
                generation: generation,
                navigate: true
            )
        }
        try? await ocrTemporaryFileStore.removePreparedImage(at: temporaryURL)
    }

    func importResolvedPlaylist(
        playlist: ImportedPlaylist,
        navigate: Bool = true,
        recommendationInputSource: RecommendationInputSource = .userImport
    ) async {
        await runImport("正在打开这份歌单") { [self] request, generation, _ in
            guard acceptsImportOperation(request) else { return }
            let candidate = makeInitialWorkflowCandidate(
                playlist: playlist,
                inputSource: recommendationInputSource
            )
            _ = try await commitImportedWorkflow(
                candidate,
                generation: generation,
                navigate: navigate
            )
        }
    }

    func makeInitialWorkflowCandidate(
        playlist: ImportedPlaylist,
        inputSource: RecommendationInputSource
    ) -> WorkflowSnapshot {
        let playlist = playlistForPersistence(playlist, inputSource: inputSource)
        let preservedVoiceProfile = voiceProfile?.hasValidMeasuredRange == true
            ? voiceProfile
            : nil
        return WorkflowSnapshot(
            importedPlaylist: playlist,
            reviewSongs: playlist.songs.map { WorkflowReviewSong(song: $0) },
            revisions: WorkflowRevisionLedger(),
            completedAnalysis: nil,
            persistedPlanRecord: nil,
            externalCandidateCollection: nil,
            voiceProfile: preservedVoiceProfile,
            recommendationInputSource: inputSource,
            scenarioConfig: scenarioConfig,
            lockedTrackIDs: [],
            removedTrackIDs: [],
            feedbackProfile: feedbackProfile,
            hasAdvancedToScenario: false
        )
    }

    @discardableResult
    func commitImportedWorkflow(
        _ candidate: WorkflowSnapshot,
        generation: UInt64,
        navigate: Bool,
        recordsRecentPlaylist: Bool = true
    ) async throws -> WorkflowCommitResult {
        guard acceptsImportGeneration(generation) else { return .superseded }
        setCommittingImportedWorkflow(true)
        let result: WorkflowCommitResult
        do {
            result = try await workflowPersistenceExecutor.commitWorkflowSnapshot(
                candidate,
                generation: generation
            )
        } catch {
            setCommittingImportedWorkflow(false)
            throw error
        }
        guard case .applied = result else {
            setCommittingImportedWorkflow(false)
            return result
        }

        defer { setCommittingImportedWorkflow(false) }
        publishImportedWorkflow(candidate)
        if recordsRecentPlaylist {
            _ = await recordRecentImport(
                candidate.importedPlaylist,
                request: recentPlaylistPersistenceGate.begin(),
                failureMessage: "歌单已经打开，但“最近导入”暂时没保存下来。"
            )
        }
        statusMessage = "找到了 \(candidate.importedPlaylist.songs.count) 首歌，先把不确定的地方看一眼"
        if navigate {
            setStage(.review)
        }
        return result
    }

    private func publishImportedWorkflow(_ snapshot: WorkflowSnapshot) {
        cancelExternalCandidateRequest()
        let wasApplyingSnapshot = isApplyingRestoredWorkflowSnapshot
        isApplyingRestoredWorkflowSnapshot = true
        importedPlaylist = snapshot.importedPlaylist
        replaceReviewSongs(snapshot.reviewSongs.map { savedSong in
            var draft = EditableImportedSongDraft(song: savedSong.importedSong)
            draft.isDeleted = savedSong.isDeleted
            return draft
        })
        replaceWorkflowRevisions(snapshot.revisions)
        matches = []
        preferenceProfile = nil
        voiceProfile = snapshot.voiceProfile
        recommendationInputSource = snapshot.recommendationInputSource
        scenarioConfig = snapshot.scenarioConfig
        songPlan = nil
        hasAdvancedToScenario = false
        lockedTrackIDs = []
        removedTrackIDs = []
        externalCandidateTracks = []
        externalCandidateStatus = "还没找同歌手备选"
        feedbackProfile = snapshot.feedbackProfile
        feedbackStatusMessage = nil
        lastFeedbackUndo = nil
        lastReviewSongUndo = nil
        lastRemovedTrackUndo = nil
        isApplyingRestoredWorkflowSnapshot = wasApplyingSnapshot
    }

    @discardableResult
    private func recordRecentImport(
        _ playlist: ImportedPlaylist,
        request: UInt64,
        failureMessage: String?
    ) async -> Bool {
        do {
            let requestResult = try await workflowPersistenceExecutor.recordRecentPlaylist(
                playlist,
                request: request
            )
            guard recentPlaylistPersistenceGate.accepts(request),
                  case let .applied(playlists) = requestResult else { return false }
            recentPlaylists = playlists
            return true
        } catch {
            guard recentPlaylistPersistenceGate.accepts(request) else { return false }
            if let failureMessage {
                errorMessage = failureMessage
            }
            return false
        }
    }

    func recommendationInputSource(for importSource: ImportSource) -> RecommendationInputSource {
        switch importSource {
        case .demo:
            return .example
        case .curated:
            return .popularFallback
        default:
            return .userImport
        }
    }

    private func playlistForPersistence(
        _ playlist: ImportedPlaylist,
        inputSource: RecommendationInputSource
    ) -> ImportedPlaylist {
        guard inputSource == .example else { return playlist }
        var examplePlaylist = playlist
        examplePlaylist.source = .demo
        examplePlaylist.songs = playlist.songs.map { song in
            var exampleSong = song
            exampleSong.source = .demo
            return exampleSong
        }
        return examplePlaylist
    }

    func commitReviewMutation(_ mutation: ReviewMutation) {
        var updatedSongs = reviewSongs
        switch mutation {
        case let .updateTitle(id, value):
            guard let index = updatedSongs.firstIndex(where: { $0.id == id }),
                  updatedSongs[index].title != value else { return }
            updatedSongs[index].title = value
            statusMessage = "歌名已更新"
        case let .updateArtist(id, value):
            guard let index = updatedSongs.firstIndex(where: { $0.id == id }),
                  updatedSongs[index].artist != value else { return }
            updatedSongs[index].artist = value
            statusMessage = "歌手已更新"
        case let .delete(id):
            guard let index = updatedSongs.firstIndex(where: { $0.id == id }),
                  !updatedSongs[index].isDeleted else { return }
            let title = updatedSongs[index].displayTitle
            updatedSongs[index].isDeleted = true
            lastReviewSongUndo = ReviewSongUndoAction(songID: id, title: title)
            statusMessage = "已删《\(title)》"
        case let .restore(id):
            guard let index = updatedSongs.firstIndex(where: { $0.id == id }),
                  updatedSongs[index].isDeleted else { return }
            updatedSongs[index].isDeleted = false
            statusMessage = "《\(updatedSongs[index].displayTitle)》已放回歌单"
            lastReviewSongUndo = nil
        }

        replaceReviewSongs(updatedSongs)
        var nextRevisions = revisions
        nextRevisions.review &+= 1
        replaceWorkflowRevisions(nextRevisions)
        cancelCurrentMatching()
        cancelExternalCandidateRequest()
        matches = []
        preferenceProfile = nil
        hasAdvancedToScenario = false
        songPlan = nil
        externalCandidateTracks = []
        externalCandidateStatus = "歌单内容已变更，请重新找同歌手备选"
        lockedTrackIDs = []
        removedTrackIDs = []
        lastRemovedTrackUndo = nil
    }

    func undoReviewSongDeletion() {
        guard let action = lastReviewSongUndo else { return }
        commitReviewMutation(.restore(id: action.songID))
    }

    @discardableResult
    func beginMatchingReviewedSongs(navigate: Bool = true) async -> ReviewedSongMatchingOutcome {
        guard let importedPlaylist else {
            errorMessage = "请先导入歌单"
            setStage(.importHub)
            return .unavailable
        }
        guard untitledReviewSongs.isEmpty else {
            errorMessage = "还有歌曲缺少歌名，补上后才能核对参考命中。"
            statusMessage = errorMessage ?? statusMessage
            return .needsReview
        }
        let songs = activeReviewSongs.map { $0.importedSong() }
        guard !songs.isEmpty else {
            errorMessage = "歌单空了，请至少留一首歌"
            return .needsReview
        }
        guard !isWorking else { return .unavailable }
        let reviewedPlaylist = ImportedPlaylist(
            id: importedPlaylist.id,
            source: importedPlaylist.source,
            title: importedPlaylist.title,
            externalURL: importedPlaylist.externalURL,
            songs: songs,
            createdAt: importedPlaylist.createdAt,
            parseConfidence: songs.map(\.confidence).reduce(0, +) / Double(max(songs.count, 1))
        )
        let startingStage = currentStage
        var didCompleteMatching = false
        await run("正在核对本地参考命中") { [self] request, _ in
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-singreadySlowPlaylistAnalysis") {
                try await Task.sleep(nanoseconds: 8_000_000_000)
            }
            #endif
            let output = try await playlistAnalysisExecutor.analyze(
                playlist: reviewedPlaylist,
                catalog: catalog
            )
            guard acceptsWorkflowOperation(request) else { return }
            guard currentStage == startingStage,
                  activeReviewSongs.map({ $0.importedSong() }) == songs else {
                statusMessage = "歌名有变化，本次核对已取消"
                return
            }

            invalidateExternalCandidateContext()
            self.importedPlaylist = reviewedPlaylist
            matches = output.matches
            preferenceProfile = output.preferenceProfile
            statusMessage = matchRate >= 0.75
                ? "这份歌单的本地参考命中较多"
                : "还有几首需要核对备选"

            _ = await recordRecentImport(
                reviewedPlaylist,
                request: recentPlaylistPersistenceGate.begin(),
                failureMessage: "整理结果已保留，但最近导入暂时没更新。"
            )
            _ = await persistWorkflowSnapshot()
            guard acceptsWorkflowOperation(request),
                  currentStage == startingStage else { return }
            didCompleteMatching = true
            if navigate {
                isCompletingWorkflowNavigation = true
                defer { isCompletingWorkflowNavigation = false }
                setStage(.matchReport)
            }
        }
        return didCompleteMatching ? .completed : .unavailable
    }

    func confirmMatch(resultID: UUID, trackID: String) {
        guard let resultIndex = matches.firstIndex(where: { $0.id == resultID }),
              let track = matches[resultIndex].alternatives.first(where: { $0.id == trackID }),
              let confirmed = matches[resultIndex].confirming(track: track),
              let importedPlaylist else {
            return
        }
        cancelExternalCandidateRequest()
        let nextWorkflowState = MatchConfirmationStatePolicy.afterConfirmingMatch(
            MatchConfirmationWorkflowState(
                lockedTrackIDs: lockedTrackIDs,
                removedTrackIDs: removedTrackIDs,
                externalCandidateTracks: externalCandidateTracks,
                songPlan: songPlan
            )
        )

        matches[resultIndex] = confirmed
        preferenceProfile = profiler.buildProfile(importedPlaylist: importedPlaylist, matches: matches)
        lockedTrackIDs = nextWorkflowState.lockedTrackIDs
        removedTrackIDs = nextWorkflowState.removedTrackIDs
        externalCandidateTracks = nextWorkflowState.externalCandidateTracks
        songPlan = nextWorkflowState.songPlan
        statusMessage = "已采用《\(track.title)》- \(track.artist)作为参考匹配"
    }

    func adoptAlternative(resultID: UUID, trackID: String) {
        guard let resultIndex = matches.firstIndex(where: { $0.id == resultID }),
              let track = matches[resultIndex].alternatives.first(where: { $0.id == trackID }),
              let adopted = matches[resultIndex].adoptingAlternative(track: track),
              let importedPlaylist else {
            return
        }
        cancelExternalCandidateRequest()
        let nextWorkflowState = MatchConfirmationStatePolicy.afterConfirmingMatch(
            MatchConfirmationWorkflowState(
                lockedTrackIDs: lockedTrackIDs,
                removedTrackIDs: removedTrackIDs,
                externalCandidateTracks: externalCandidateTracks,
                songPlan: songPlan
            )
        )

        matches[resultIndex] = adopted
        preferenceProfile = profiler.buildProfile(importedPlaylist: importedPlaylist, matches: matches)
        lockedTrackIDs = nextWorkflowState.lockedTrackIDs
        removedTrackIDs = nextWorkflowState.removedTrackIDs
        externalCandidateTracks = nextWorkflowState.externalCandidateTracks
        songPlan = nextWorkflowState.songPlan
        statusMessage = "已采用替代歌：\(track.title) - \(track.artist)"
    }
}
