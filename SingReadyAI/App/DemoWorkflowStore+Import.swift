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
        // cancelWorkflowOperation 可能刚启动一笔计划状态写入；清空边界必须立即让它失效。
        planStateTransitionGate.invalidate()
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
        standaloneFeedbackRevision = 0

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
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ImportedWorkflowCommitError {
                switch error {
                case .persistenceFailed:
                    throw ImportedWorkflowCommitError.pendingPersistenceFailed
                case .pendingPersistenceFailed, .superseded:
                    throw error
                }
            } catch {
                throw ImportedWorkflowCommitError.pendingPersistenceFailed
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
        guard acceptsImportGeneration(generation) else {
            if Task.isCancelled { throw CancellationError() }
            throw ImportedWorkflowCommitError.superseded
        }
        setCommittingImportedWorkflow(true)
        defer { setCommittingImportedWorkflow(false) }
        // 必须在 actor 提交前失效旧迁移，防止旧请求被 supersede 后换新 generation 重试。
        planStateTransitionGate.invalidate()

        do {
            let result = try await workflowPersistenceExecutor.commitWorkflowSnapshot(
                candidate,
                generation: generation
            )
            guard case .applied = result else {
                if Task.isCancelled { throw CancellationError() }
                throw ImportedWorkflowCommitError.superseded
            }

            publishImportedWorkflow(candidate)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains(
                "-singreadyDelayImportedWorkflowFinalization"
            ) {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
            #endif
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
            return .applied
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ImportedWorkflowCommitError {
            throw error
        } catch {
            throw ImportedWorkflowCommitError.persistenceFailed
        }
    }

    private func publishImportedWorkflow(_ snapshot: WorkflowSnapshot) {
        planStateTransitionGate.invalidate()
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
        replaceCompletedAnalysis(nil)
        setMatchOperationState(.notStarted)
        voiceProfile = snapshot.voiceProfile
        recommendationInputSource = snapshot.recommendationInputSource
        scenarioConfig = snapshot.scenarioConfig
        setPlanGenerationState(.absent)
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
        guard !isApplyingMatchReviewAction else { return }
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
        let invalidatedPlanState = planGenerationState.invalidated(
            reason: "歌单内容已更新"
        )
        var nextRevisions = revisions
        nextRevisions.review &+= 1
        replaceWorkflowRevisions(nextRevisions)
        cancelCurrentMatching()
        cancelExternalCandidateRequest()
        replaceCompletedAnalysis(nil)
        setMatchOperationState(.notStarted)
        hasAdvancedToScenario = false
        setPlanGenerationState(invalidatedPlanState)
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
        guard !isWorking,
              let basis = currentMatchBasis,
              let request = matchOperationGate.beginIfIdle() else { return .unavailable }
        let reviewedPlaylist = ImportedPlaylist(
            id: importedPlaylist.id,
            source: importedPlaylist.source,
            title: importedPlaylist.title,
            externalURL: importedPlaylist.externalURL,
            songs: songs,
            createdAt: importedPlaylist.createdAt,
            parseConfidence: songs.map(\.confidence).reduce(0, +) / Double(max(songs.count, 1))
        )
        var recentPlaylist = importedPlaylist
        let reviewDraftsByID = Dictionary(
            uniqueKeysWithValues: reviewSongs.map { ($0.id, $0) }
        )
        recentPlaylist.songs = importedPlaylist.songs.map { originalSong in
            guard let draft = reviewDraftsByID[originalSong.id], !draft.isDeleted else {
                return originalSong
            }
            return draft.importedSong()
        }
        recentPlaylist.parseConfidence = recentPlaylist.songs.map(\.confidence).reduce(0, +)
            / Double(max(recentPlaylist.songs.count, 1))
        let startingStage = currentStage
        let generation = workflowSnapshotPersistenceGate.begin()
        errorMessage = nil
        statusMessage = "正在核对歌曲参考"
        setMatchOperationState(.running(processed: 0, total: songs.count))
        await workflowPersistenceExecutor.reserveWorkflowMutation(generation: generation)
        guard matchOperationGate.accepts(request),
              currentStage == startingStage,
              currentMatchBasis == basis else {
            _ = matchOperationGate.finish(request)
            if case .running = matchOperationState {
                setMatchOperationState(.cancelled)
            }
            return .unavailable
        }

        #if DEBUG
        let timeoutNanoseconds: UInt64 = ProcessInfo.processInfo.arguments.contains(
            "-singreadyShortMatchTimeout"
        ) ? 500_000_000 : 20_000_000_000
        #else
        let timeoutNanoseconds: UInt64 = 20_000_000_000
        #endif
        let deadline = MonotonicOperationDeadline(timeoutNanoseconds: timeoutNanoseconds)
        let task: Task<WorkflowOperationOutcome, Never> = Task { @MainActor [weak self] in
            guard let self else { return .discarded }
            do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-singreadySlowPlaylistAnalysis") {
                try await Task.sleep(nanoseconds: 8_000_000_000)
            }
            if ProcessInfo.processInfo.arguments.contains("-singreadySlowPlaylistAnalysisProgress") {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            #endif
            let output = try await playlistAnalysisExecutor.analyze(
                playlist: reviewedPlaylist,
                catalog: catalog,
                progress: { [weak self] processed, total in
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains(
                        "-singreadySlowPlaylistAnalysisProgress"
                    ) {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                    #endif
                    await self?.publishMatchProgress(
                        processed: processed,
                        total: total,
                        request: request,
                        basis: basis
                    )
                }
            )
            try Task.checkCancellation()
            guard self.matchOperationGate.accepts(request),
                  self.currentStage == startingStage,
                  self.currentMatchBasis == basis,
                  self.activeReviewSongs.map({ $0.importedSong() }) == songs,
                  output.matches.count == songs.count,
                  self.workflowSnapshotPersistenceGate.accepts(generation) else {
                return .discarded
            }
            var nextRevisions = self.revisions
            nextRevisions.match &+= 1
            let analysis = CompletedPlaylistAnalysis(
                basis: basis,
                matchRevision: nextRevisions.match,
                matches: output.matches,
                preferenceProfile: output.preferenceProfile
            )
            let invalidatedPlanState = self.planGenerationState.invalidated(
                reason: "歌曲参考已重新核对"
            )
            guard let candidate = self.workflowSnapshotForPersistence(
                completedAnalysis: analysis,
                revisions: nextRevisions,
                planGenerationState: invalidatedPlanState,
                externalCandidateTracks: []
            ) else {
                return .failed("当前歌单暂时无法保存，请重新导入后再试。")
            }

            self.matchOperationTimeoutTask?.cancel()
            let commitResult = try await self.workflowPersistenceExecutor.commitWorkflowSnapshot(
                candidate,
                generation: generation
            )
            guard commitResult == .applied else {
                return .failed("这次核对已被新的操作替代，请重试。")
            }

            self.publishCompletedAnalysis(
                analysis,
                revisions: nextRevisions,
                planGenerationState: invalidatedPlanState,
                request: request,
                navigate: navigate,
                startingStage: startingStage
            )
            _ = await self.recordRecentImport(
                recentPlaylist,
                request: self.recentPlaylistPersistenceGate.begin(),
                failureMessage: "整理结果已保留，但最近导入暂时没更新。"
            )
            return .succeeded
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed("核对结果暂时没保存下来，整理内容和上次结果都还在。请重试。")
            }
        }
        matchOperationTask = task
        let timeoutTask = Task { @MainActor [weak self] in
            let remaining = deadline.remainingNanoseconds()
            if remaining > 0 {
                do { try await Task.sleep(nanoseconds: remaining) } catch { return }
            }
            guard let self,
                  self.matchOperationGate.finish(request) else { return }
            task.cancel()
            let cancellationGeneration = self.workflowSnapshotPersistenceGate.begin()
            await self.workflowPersistenceExecutor.reserveWorkflowMutation(
                generation: cancellationGeneration
            )
            self.matchOperationTask = nil
            self.matchOperationTimeoutTask = nil
            let message = "核对时间有点长，已停止。歌单内容都还在，可以重新核对。"
            self.setMatchOperationState(.failed(message: message, retryable: true))
            self.errorMessage = nil
            self.statusMessage = message
        }
        matchOperationTimeoutTask = timeoutTask
        let outcome = await task.value
        timeoutTask.cancel()
        matchOperationTask = nil
        matchOperationTimeoutTask = nil

        switch outcome {
        case .succeeded:
            _ = matchOperationGate.finish(request)
            return .completed
        case .cancelled:
            guard matchOperationGate.finish(request) else { return .unavailable }
            setMatchOperationState(.cancelled)
            statusMessage = "已取消本次核对，整理内容和上次结果都还在。"
        case let .failed(message):
            guard matchOperationGate.finish(request) else { return .unavailable }
            setMatchOperationState(.failed(message: message, retryable: true))
            errorMessage = nil
            statusMessage = message
        case .discarded:
            guard matchOperationGate.finish(request) else { return .unavailable }
            setMatchOperationState(.cancelled)
            statusMessage = "歌单内容有变化，本次核对已停止。"
        }
        return .unavailable
    }

    private func publishMatchProgress(
        processed: Int,
        total: Int,
        request: UInt64,
        basis: MatchBasis
    ) {
        guard matchOperationGate.accepts(request),
              currentMatchBasis == basis else { return }
        let boundedTotal = max(0, total)
        let boundedProcessed = min(max(0, processed), boundedTotal)
        if case let .running(currentProcessed, currentTotal) = matchOperationState,
           currentTotal == boundedTotal,
           boundedProcessed < currentProcessed {
            return
        }
        setMatchOperationState(.running(processed: boundedProcessed, total: boundedTotal))
    }

    private func publishCompletedAnalysis(
        _ analysis: CompletedPlaylistAnalysis,
        revisions nextRevisions: WorkflowRevisionLedger,
        planGenerationState nextPlanGenerationState: PlanGenerationState,
        request: UInt64,
        navigate: Bool,
        startingStage: WorkflowStage
    ) {
        cancelExternalCandidateRequest()
        let wasApplyingSnapshot = isApplyingRestoredWorkflowSnapshot
        isApplyingRestoredWorkflowSnapshot = true
        replaceCompletedAnalysis(analysis)
        replaceWorkflowRevisions(nextRevisions)
        setPlanGenerationState(nextPlanGenerationState)
        externalCandidateTracks = []
        externalCandidateStatus = "还没找同歌手备选"
        lastRemovedTrackUndo = nil
        isApplyingRestoredWorkflowSnapshot = wasApplyingSnapshot
        lastWorkflowSnapshotAttemptRevision = workflowSnapshotRevision
        setMatchOperationState(.ready(analysis.basis))
        errorMessage = nil
        let statistics = MatchStatistics(matches: analysis.matches)
        statusMessage = "已核对 \(statistics.verified) 首，\(statistics.pending) 首待确认，\(statistics.unmatched) 首暂未找到"

        guard navigate,
              matchOperationGate.accepts(request),
              currentStage == startingStage else { return }
        isCompletingWorkflowNavigation = true
        defer { isCompletingWorkflowNavigation = false }
        setStage(.matchReport)
    }

    private func applyMatchReviewAction(
        _ action: MatchReviewAction
    ) async {
        guard !isApplyingMatchReviewAction,
              !isWorking,
              let currentAnalysis = completedAnalysis,
              currentAnalysis.basis == currentMatchBasis else { return }
        let startingReviewRevision = revisions.review
        let startingMatchRevision = revisions.match
        setApplyingMatchReviewAction(true)
        defer { setApplyingMatchReviewAction(false) }

        do {
            let updatedAnalysis = try currentAnalysis.applying(action, profiler: profiler)
            var nextRevisions = revisions
            nextRevisions.match = updatedAnalysis.matchRevision
            let invalidatedPlanState = planGenerationState.invalidated(
                reason: "歌曲确认已更新"
            )
            // 匹配确认会提交整份工作流；先终止旧的取消/失效迁移，
            // 避免它在被 supersede 后换用更高 generation 覆盖确认结果。
            planStateTransitionGate.invalidate()
            let generation = workflowSnapshotPersistenceGate.begin()
            await workflowPersistenceExecutor.reserveWorkflowMutation(generation: generation)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-singreadyDelayMatchReviewCommit") {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
            #endif
            guard completedAnalysis?.basis == currentAnalysis.basis,
                  completedAnalysis?.matchRevision == currentAnalysis.matchRevision,
                  currentMatchBasis == currentAnalysis.basis,
                  revisions.review == startingReviewRevision,
                  revisions.match == startingMatchRevision,
                  workflowSnapshotPersistenceGate.accepts(generation) else {
                errorMessage = "这首歌的信息已更新，请重新选择。"
                return
            }
            guard let candidate = workflowSnapshotForPersistence(
                completedAnalysis: updatedAnalysis,
                revisions: nextRevisions,
                planGenerationState: invalidatedPlanState,
                externalCandidateTracks: externalCandidateTracks
            ) else { return }
            let result = try await workflowPersistenceExecutor.commitWorkflowSnapshot(
                candidate,
                generation: generation
            )
            guard result == .applied else {
                errorMessage = "这首歌的信息已更新，请重新选择。"
                return
            }

            cancelExternalCandidateRequest()
            let wasApplyingSnapshot = isApplyingRestoredWorkflowSnapshot
            isApplyingRestoredWorkflowSnapshot = true
            replaceCompletedAnalysis(updatedAnalysis)
            replaceWorkflowRevisions(nextRevisions)
            setPlanGenerationState(invalidatedPlanState)
            lastRemovedTrackUndo = nil
            isApplyingRestoredWorkflowSnapshot = wasApplyingSnapshot
            lastWorkflowSnapshotAttemptRevision = workflowSnapshotRevision
            setMatchOperationState(.ready(updatedAnalysis.basis))
            errorMessage = nil
            let resultID: UUID
            let verb: String
            switch action {
            case let .confirmOriginal(id, _):
                resultID = id
                verb = "已确认"
            case let .adoptAlternative(id, _):
                resultID = id
                verb = "已改用"
            }
            if let track = updatedAnalysis.matches
                .first(where: { $0.id == resultID })?
                .acceptedTrack {
                statusMessage = "\(verb)《\(track.title)》— \(track.artist)"
            } else {
                statusMessage = "匹配结果已更新"
            }
        } catch let error as MatchReviewActionError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "这次修改暂时没保存下来，原来的匹配结果还在。请稍后重试。"
        }
    }

    func confirmMatch(resultID: UUID, trackID: String) {
        Task { @MainActor [weak self] in
            await self?.applyMatchReviewAction(
                .confirmOriginal(resultID: resultID, trackID: trackID)
            )
        }
    }

    func adoptAlternative(resultID: UUID, trackID: String) {
        Task { @MainActor [weak self] in
            await self?.applyMatchReviewAction(
                .adoptAlternative(resultID: resultID, trackID: trackID)
            )
        }
    }
}
