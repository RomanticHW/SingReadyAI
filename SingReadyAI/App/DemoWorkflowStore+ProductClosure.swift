import Foundation
import SingReadyAISharedKit

@MainActor
extension DemoWorkflowStore {
    func expandSimilarCandidates() async {
        guard currentStage == .matchReport else { return }
        guard let requestPlaylist = externalCandidatePlaylistForCurrentReview(),
              !requestPlaylist.songs.isEmpty else {
            errorMessage = "请先导入歌单"
            setStage(.importHub)
            return
        }
        let timeoutNanoseconds: UInt64 = 12_000_000_000
        let now = DispatchTime.now().uptimeNanoseconds
        guard let request = externalCandidateRequestCoordinator.beginIfIdle(
            playlistID: requestPlaylist.id,
            reviewRevision: revisions.review,
            nowNanoseconds: now,
            timeoutNanoseconds: timeoutNanoseconds
        ) else {
            statusMessage = "同歌手候选正在搜索，请稍等"
            return
        }
        isExpandingExternalCandidates = true
        errorMessage = nil
        externalCandidateStatus = "正在通过 Apple 公开搜索找同歌手备选"
        statusMessage = externalCandidateStatus

        let seeds = ExternalCandidateSeedSelector().seeds(
            from: requestPlaylist.songs,
            matches: matches,
            limit: 4
        )
        let seedPlaylist = ImportedPlaylist(
            source: requestPlaylist.source,
            title: requestPlaylist.title,
            externalURL: requestPlaylist.externalURL,
            songs: seeds,
            parseConfidence: requestPlaylist.parseConfidence
        )
        let provider = ExternalMusicCandidateProvider(
            similarProvider: ITunesArtistSongProvider(countryCode: "CN")
        )
        let importedKeys = Set(requestPlaylist.songs.map {
            "\(SongNormalizer.normalizeTitle($0.title))|\($0.artist.map(SongNormalizer.normalizeArtist) ?? "")"
        })
        #if DEBUG
        let testDelayNanoseconds: UInt64 = ProcessInfo.processInfo.arguments.contains("-singreadySlowExternalCandidateSearch")
            ? 8_000_000_000
            : 0
        #else
        let testDelayNanoseconds: UInt64 = 0
        #endif
        let task = Task<[ExternalSongCandidate], Error> {
            try await withExternalCandidateTimeout(nanoseconds: timeoutNanoseconds) {
                if testDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: testDelayNanoseconds)
                }
                return try await provider.candidates(for: seedPlaylist, perSeedLimit: 4)
            }
        }
        externalCandidateTask = task

        do {
            let fetchedCandidates = try await task.value
            guard currentStage == .matchReport else {
                finishExternalCandidateRequestWithoutResults(request)
                return
            }
            let completedAt = DispatchTime.now().uptimeNanoseconds
            guard let currentPlaylist = externalCandidatePlaylistForCurrentReview(),
                  externalCandidateRequestCoordinator.commit(
                      request,
                      playlistID: currentPlaylist.id,
                      reviewRevision: revisions.review,
                      requestRevision: request.basis.requestRevision,
                      nowNanoseconds: completedAt
                  ) else {
                guard externalCandidateRequestCoordinator.isActive(request) else { return }
                let contextIsCurrent = isCurrentExternalCandidateContext(request)
                _ = externalCandidateRequestCoordinator.finish(request)
                externalCandidateTask = nil
                isExpandingExternalCandidates = false
                if contextIsCurrent {
                    reportExternalCandidateSearchUnavailable()
                } else {
                    clearExternalCandidateResultsForContextChange()
                }
                return
            }

            externalCandidateTask = nil
            isExpandingExternalCandidates = false
            let candidates = fetchedCandidates.filter { !importedKeys.contains($0.normalizedKey) }
            guard !candidates.isEmpty else {
                reportExternalCandidateSearchUnavailable()
                return
            }
            externalCandidateCollection = ExternalCandidateCollectionAccumulator().mergedCollection(
                basis: request.basis,
                existing: externalCandidateCollection,
                incoming: candidates,
                limit: 12
            )
            externalCandidateStatus = "找到 \(externalCandidates.count) 首同歌手公开候选，可打开来源核对，不会自动加入排歌结果"
            statusMessage = externalCandidateStatus
        } catch is CancellationError {
            guard currentStage == .matchReport else {
                finishExternalCandidateRequestWithoutResults(request)
                return
            }
            guard externalCandidateRequestCoordinator.finish(request) else { return }
            externalCandidateTask = nil
            isExpandingExternalCandidates = false
            externalCandidateStatus = "已取消同歌手候选搜索"
            statusMessage = externalCandidateStatus
        } catch let error as ExternalCandidateRequestError where error == .timedOut {
            guard currentStage == .matchReport else {
                finishExternalCandidateRequestWithoutResults(request)
                return
            }
            let contextIsCurrent = isCurrentExternalCandidateContext(request)
            guard externalCandidateRequestCoordinator.finish(request) else { return }
            externalCandidateTask = nil
            isExpandingExternalCandidates = false
            if contextIsCurrent {
                reportExternalCandidateSearchUnavailable()
            } else {
                clearExternalCandidateResultsForContextChange()
            }
        } catch {
            guard currentStage == .matchReport else {
                finishExternalCandidateRequestWithoutResults(request)
                return
            }
            let contextIsCurrent = isCurrentExternalCandidateContext(request)
            guard externalCandidateRequestCoordinator.finish(request) else { return }
            externalCandidateTask = nil
            isExpandingExternalCandidates = false
            if contextIsCurrent {
                reportExternalCandidateSearchUnavailable()
            } else {
                clearExternalCandidateResultsForContextChange()
            }
        }
    }

    func cancelExternalCandidateRequest(reportStatus: Bool = false) {
        let wasActive = isExpandingExternalCandidates
        externalCandidateRequestCoordinator.cancel()
        externalCandidateTask?.cancel()
        externalCandidateTask = nil
        isExpandingExternalCandidates = false
        if reportStatus, wasActive {
            externalCandidateStatus = "已取消同歌手候选搜索"
            statusMessage = externalCandidateStatus
        }
    }

    private func finishExternalCandidateRequestWithoutResults(_ request: ExternalCandidateRequest) {
        guard externalCandidateRequestCoordinator.finish(request) else { return }
        externalCandidateTask = nil
        isExpandingExternalCandidates = false
    }

    func invalidateExternalCandidateContext() {
        cancelExternalCandidateRequest()
        clearExternalCandidateResultsForContextChange()
    }

    private func externalCandidatePlaylistForCurrentReview() -> ImportedPlaylist? {
        guard let importedPlaylist else { return nil }
        let songs = reviewSongs.isEmpty
            ? importedPlaylist.songs
            : activeReviewSongs.map { $0.importedSong() }
        return ImportedPlaylist(
            id: importedPlaylist.id,
            source: importedPlaylist.source,
            title: importedPlaylist.title,
            externalURL: importedPlaylist.externalURL,
            songs: songs,
            createdAt: importedPlaylist.createdAt,
            parseConfidence: songs.map(\.confidence).reduce(0, +) / Double(max(songs.count, 1))
        )
    }

    private func isCurrentExternalCandidateContext(_ request: ExternalCandidateRequest) -> Bool {
        guard let playlist = externalCandidatePlaylistForCurrentReview(),
              playlist.id == request.basis.playlistID else { return false }
        return revisions.review == request.basis.reviewRevision
    }

    private func clearExternalCandidateResultsForContextChange() {
        externalCandidateCollection = nil
        externalCandidateStatus = "歌单内容已变更，请重新找同歌手备选"
        statusMessage = externalCandidateStatus
    }

    private func reportExternalCandidateSearchUnavailable() {
        externalCandidateStatus = "暂时没找到更多公开候选，可以继续按已确认歌曲排歌"
        statusMessage = externalCandidateStatus
    }

    func applyFeedback(trackID: String, kind: SongFeedbackKind) {
        guard canUseReadyPlan else {
            errorMessage = readyPlanUnavailableMessage
            return
        }
        let previousTags = feedbackProfile.feedback(for: trackID)
        let trackTitle = trackDisplayTitle(for: trackID)
        var nextProfile = feedbackProfile
        nextProfile.toggle(trackID: trackID, kind: kind)
        var nextRevisions = revisions
        nextRevisions.feedback &+= 1
        do {
            try SongFeedbackLocalStore().save(
                SongFeedbackRecord(
                    revision: nextRevisions.feedback,
                    profile: nextProfile
                )
            )
        } catch {
            errorMessage = "这次选择暂时没保存下来，请稍后再试。"
            return
        }
        feedbackProfile = nextProfile
        replaceWorkflowRevisions(nextRevisions)
        standaloneFeedbackRevision = nextRevisions.feedback
        hasStandaloneFeedbackRecord = true
        lastFeedbackUndo = SongFeedbackUndoAction(
            trackID: trackID,
            trackTitle: trackTitle,
            kind: kind,
            previousTags: previousTags,
            appliedFeedbackRevision: nextRevisions.feedback
        )
        feedbackStatusMessage = Self.feedbackReplanInProgressMessage
        statusMessage = Self.feedbackReplanInProgressMessage
        invalidatePlan(reason: "歌曲反馈已更新")
        generatePlan()
    }

    func undoLastFeedback() {
        guard canUndoLastFeedback else {
            if lastFeedbackUndo != nil {
                errorMessage = "请等当前操作结束后再撤销。"
            }
            return
        }
        guard let action = lastFeedbackUndo else { return }
        var nextProfile = feedbackProfile
        nextProfile.setFeedback(trackID: action.trackID, kinds: action.previousTags)
        var nextRevisions = revisions
        nextRevisions.feedback &+= 1
        do {
            try SongFeedbackLocalStore().save(
                SongFeedbackRecord(
                    revision: nextRevisions.feedback,
                    profile: nextProfile
                )
            )
        } catch {
            errorMessage = "这次撤销暂时没保存下来，请稍后再试。"
            return
        }
        feedbackProfile = nextProfile
        replaceWorkflowRevisions(nextRevisions)
        standaloneFeedbackRevision = nextRevisions.feedback
        hasStandaloneFeedbackRecord = true
        lastFeedbackUndo = nil
        feedbackStatusMessage = Self.feedbackUndoReplanInProgressMessage
        statusMessage = Self.feedbackUndoReplanInProgressMessage
        invalidatePlan(reason: "歌曲反馈已更新")
        generatePlan()
    }

    private func trackDisplayTitle(for trackID: String) -> String {
        let planTracks = visibleSongPlan?.sections.flatMap(\.items).map(\.track) ?? []
        let matchTracks = matches.flatMap { match in
            [match.acceptedTrack].compactMap(\.self) + match.alternatives
        }
        let allTracks = planTracks + matchTracks + catalog
        guard let track = allTracks.first(where: { $0.id == trackID }) else {
            return "这首歌"
        }
        return "《\(track.title)》"
    }
}
