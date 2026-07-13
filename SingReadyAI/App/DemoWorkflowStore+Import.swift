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
        lockedTrackIDs = []
        removedTrackIDs = []
        resetImport(
            navigateToImport: false,
            clearPersistedSnapshot: false
        )
        isApplyingRestoredWorkflowSnapshot = false
        let recentClearRequest = recentPlaylistPersistenceGate.begin()
        let snapshotClearRequest = workflowSnapshotPersistenceGate.begin()
        var didFail = false
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
            if case .rejectedStaleRequest = result { didFail = true }
        } catch {
            didFail = true
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
        await run("正在读取分享内容") { [self] request, operationDeadline in
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
            guard acceptsWorkflowOperation(request), currentStage == .importHub else { return }
            let persistedPlaylist = prepareForReview(
                playlist: playlist,
                recordsRecentPlaylist: false
            )
            let didSaveRecentPlaylist = await recordRecentImport(
                persistedPlaylist,
                request: recentPlaylistPersistenceGate.begin(),
                failureMessage: nil
            )
            let persistenceReceipt = PendingImportPersistenceReceipt(
                didSaveRecentPlaylist: didSaveRecentPlaylist,
                didSaveWorkflowSnapshot: await persistWorkflowSnapshot(reportFailure: false)
            )
            guard acceptsWorkflowOperation(request),
                  persistenceReceipt.canConsumePendingImport else {
                let message = "歌单已整理，但本机暂时保存不了。待整理内容已保留，请稍后重试。"
                errorMessage = message
                statusMessage = message
                return
            }
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
        }
    }

    func useDemoPlaylist() async {
        await run("正在准备示例歌单") { [self] request, _ in
            let playlist = try importCoordinator.resolveDemoPlaylist()
            guard acceptsWorkflowOperation(request), currentStage == .importHub else { return }
            prepareForReview(playlist: playlist, recommendationInputSource: .example)
        }
    }

    func importText(_ text: String) async {
        guard text.count <= 50_000,
              text.split(whereSeparator: \.isNewline).count <= 1_000 else {
            errorMessage = "这段内容太长了，请分成几份再导入。"
            statusMessage = errorMessage ?? statusMessage
            return
        }
        await run("正在整理这段歌单") { [self] request, _ in
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-singreadySlowImport") {
                try await Task.sleep(nanoseconds: 12_000_000_000)
            }
            #endif
            let payload = PendingImportPayload(sourceHint: .plainText, rawText: text, displayTitle: "粘贴导入歌单")
            let playlist = try await importCoordinator.resolve(payload: payload)
            guard acceptsWorkflowOperation(request), currentStage == .importHub else { return }
            prepareForReview(playlist: playlist)
        }
    }

    func importScreenshotFile(at temporaryURL: URL) async {
        await run("正在看截图里的歌名") { [self] request, _ in
            let recognizedText = try await ocrService.recognizeText(fromImageAt: temporaryURL)
            let playlist = try OCRPlaylistParser().parseValidated(recognizedText: recognizedText)
            guard acceptsWorkflowOperation(request), currentStage == .importHub else { return }
            prepareForReview(playlist: playlist)
        }
        try? await ocrTemporaryFileStore.removePreparedImage(at: temporaryURL)
    }

    @discardableResult
    func prepareForReview(
        playlist: ImportedPlaylist,
        navigate: Bool = true,
        recommendationInputSource: RecommendationInputSource = .userImport,
        recordsRecentPlaylist: Bool = true
    ) -> ImportedPlaylist {
        cancelExternalCandidateRequest()
        let playlist = playlistForPersistence(playlist, inputSource: recommendationInputSource)
        importedPlaylist = playlist
        self.recommendationInputSource = recommendationInputSource
        reviewSongs = playlist.songs.map(EditableImportedSongDraft.init)
        matches = []
        preferenceProfile = nil
        songPlan = nil
        hasAdvancedToScenario = false
        lockedTrackIDs = []
        removedTrackIDs = []
        externalCandidateTracks = []
        externalCandidateStatus = "还没找同歌手备选"
        feedbackStatusMessage = nil
        lastFeedbackUndo = nil
        lastReviewSongUndo = nil
        lastRemovedTrackUndo = nil
        if recordsRecentPlaylist {
            let persistenceRequest = recentPlaylistPersistenceGate.begin()
            Task { @MainActor [weak self, playlist] in
                _ = await self?.recordRecentImport(
                    playlist,
                    request: persistenceRequest,
                    failureMessage: "歌单已打开，但最近导入暂时没保存下来。"
                )
            }
        }
        statusMessage = "找到了 \(playlist.songs.count) 首歌，先把不确定的地方看一眼"
        if navigate {
            isCompletingWorkflowNavigation = isWorking
            defer { isCompletingWorkflowNavigation = false }
            setStage(.review)
        }
        return playlist
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

    func deleteReviewSong(id: UUID) {
        guard let index = reviewSongs.firstIndex(where: { $0.id == id }),
              !reviewSongs[index].isDeleted else { return }
        invalidateExternalCandidateContext()
        let title = reviewSongs[index].displayTitle
        reviewSongs[index].isDeleted = true
        lastReviewSongUndo = ReviewSongUndoAction(songID: id, title: title)
        statusMessage = "已删《\(title)》"
    }

    func undoReviewSongDeletion() {
        guard let action = lastReviewSongUndo,
              let index = reviewSongs.firstIndex(where: { $0.id == action.songID }) else { return }
        invalidateExternalCandidateContext()
        reviewSongs[index].isDeleted = false
        statusMessage = "《\(action.title)》已放回歌单"
        lastReviewSongUndo = nil
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
