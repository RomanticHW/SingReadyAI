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
        let playlistRevision = ExternalCandidatePlaylistRevision.fingerprint(for: requestPlaylist)
        guard let request = externalCandidateRequestCoordinator.beginIfIdle(
            playlistID: requestPlaylist.id,
            playlistRevision: playlistRevision,
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
                      playlistRevision: ExternalCandidatePlaylistRevision.fingerprint(for: currentPlaylist),
                      nowNanoseconds: completedAt
                  ) else {
                guard externalCandidateRequestCoordinator.isActive(request) else { return }
                let contextIsCurrent = isCurrentExternalCandidateContext(request)
                _ = externalCandidateRequestCoordinator.finish(request)
                externalCandidateTask = nil
                isExpandingExternalCandidates = false
                if contextIsCurrent {
                    applyLocalCandidateFallback(
                        for: requestPlaylist,
                        failureText: "Apple 公开搜索等待超时"
                    )
                } else {
                    clearExternalCandidateResultsForContextChange()
                }
                return
            }

            externalCandidateTask = nil
            isExpandingExternalCandidates = false
            let candidates = fetchedCandidates.filter { !importedKeys.contains($0.normalizedKey) }
            let previousCount = externalCandidateTracks.filter(\.isProvisionalExternalCandidate).count
            externalCandidateTracks = ExternalCandidateTrackAccumulator().mergedTracks(
                baseCatalog: catalog,
                existingExternalTracks: externalCandidateTracks,
                candidates: candidates,
                limit: 12
            )
            let newCount = max(0, externalCandidateTracks.count - previousCount)
            if externalCandidateTracks.isEmpty {
                applyLocalCandidateFallback(
                    for: requestPlaylist,
                    failureText: "Apple 公开搜索没有找到新的同歌手曲目"
                )
            } else if newCount > 0 {
                externalCandidateStatus = "新增 \(newCount) 首同歌手公开候选，KTV 收录与适唱情况待核对"
                statusMessage = externalCandidateStatus
            } else {
                externalCandidateStatus = "没有新增同歌手候选，已保留现有 \(externalCandidateTracks.count) 首"
                statusMessage = externalCandidateStatus
            }
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
                applyLocalCandidateFallback(
                    for: requestPlaylist,
                    failureText: "Apple 公开搜索等待超时"
                )
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
                applyLocalCandidateFallback(
                    for: requestPlaylist,
                    failureText: "Apple 公开搜索暂时不可用"
                )
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
              playlist.id == request.playlistID else { return false }
        return ExternalCandidatePlaylistRevision.fingerprint(for: playlist) == request.playlistRevision
    }

    private func clearExternalCandidateResultsForContextChange() {
        externalCandidateTracks = []
        externalCandidateStatus = "歌单内容已变更，请重新找同歌手备选"
        statusMessage = externalCandidateStatus
    }

    private func applyLocalCandidateFallback(
        for playlist: ImportedPlaylist,
        failureText: String
    ) {
        if !externalCandidateTracks.isEmpty {
            externalCandidateStatus = "\(failureText)，已保留现有 \(externalCandidateTracks.count) 首备选"
            statusMessage = externalCandidateStatus
            return
        }
        let fallbackTracks = localFallbackTracks(for: playlist, limit: 8)
        externalCandidateTracks = fallbackTracks
        externalCandidateStatus = fallbackTracks.isEmpty
            ? "\(failureText)，本地参考中也没有新的备选"
            : "\(failureText)，先列出 \(fallbackTracks.count) 首本地参考备选"
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
        invalidatePlan(reason: "歌曲反馈已更新")
        generatePlan()
        lastFeedbackUndo = SongFeedbackUndoAction(
            trackID: trackID,
            trackTitle: trackTitle,
            kind: kind,
            previousTags: previousTags
        )
        let isSelected = nextProfile.contains(trackID: trackID, kind: kind)
        feedbackStatusMessage = isSelected
            ? "已记录\(trackTitle)：\(kind.displayName)"
            : "已取消\(trackTitle)的\(kind.displayName)"
        statusMessage = feedbackStatusMessage ?? statusMessage
    }

    func undoLastFeedback() {
        guard canUseReadyPlan else {
            errorMessage = readyPlanUnavailableMessage
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
        invalidatePlan(reason: "歌曲反馈已更新")
        generatePlan()
        feedbackStatusMessage = "已撤销\(action.trackTitle)：\(action.kind.displayName)"
        statusMessage = feedbackStatusMessage ?? statusMessage
        lastFeedbackUndo = nil
    }

    private func localFallbackTracks(for playlist: ImportedPlaylist, limit: Int) -> [KTVTrack] {
        let importedTitles = Set(playlist.songs.map { SongNormalizer.normalizeTitle($0.title) })
        let preferredArtists = Set(playlist.songs.compactMap(\.artist).map(SongNormalizer.normalizeArtist))
        let preferredGenres = Set(matches.compactMap(\.acceptedTrack).map(\.genre))

        return catalog
            .filter { !importedTitles.contains(SongNormalizer.normalizeTitle($0.title)) }
            .sorted { lhs, rhs in
                let lhsScore = fallbackScore(lhs, artists: preferredArtists, genres: preferredGenres)
                let rhsScore = fallbackScore(rhs, artists: preferredArtists, genres: preferredGenres)
                if lhsScore == rhsScore { return lhs.singAlongScore > rhs.singAlongScore }
                return lhsScore > rhsScore
            }
            .prefix(limit)
            .map { $0 }
    }

    private func fallbackScore(_ track: KTVTrack, artists: Set<String>, genres: Set<String>) -> Double {
        var score = track.singAlongScore * 0.45 + track.ktvAvailability * 0.35
        if artists.contains(SongNormalizer.normalizeArtist(track.artist)) { score += 0.45 }
        if genres.contains(track.genre) { score += 0.20 }
        return score
    }

    private func trackDisplayTitle(for trackID: String) -> String {
        let planTracks = visibleSongPlan?.sections.flatMap(\.items).map(\.track) ?? []
        let matchTracks = matches.flatMap { match in
            [match.acceptedTrack].compactMap(\.self) + match.alternatives
        }
        let allTracks = planTracks + externalCandidateTracks + matchTracks + catalog
        guard let track = allTracks.first(where: { $0.id == trackID }) else {
            return "这首歌"
        }
        return "《\(track.title)》"
    }
}
