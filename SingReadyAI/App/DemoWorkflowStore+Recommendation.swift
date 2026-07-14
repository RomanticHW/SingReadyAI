import Foundation
import SingReadyAISharedKit

@MainActor
extension DemoWorkflowStore {
    func generatePlan(
        navigate: Bool = true,
        schedulesPersistence: Bool = true
    ) {
        if preferenceProfile == nil {
            if importedPlaylist == nil {
                prepareDefaultPlanContext()
            } else {
                guard planPreparationTask == nil else { return }
                let startingStage = currentStage
                planPreparationGeneration &+= 1
                let generation = planPreparationGeneration
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer {
                        if self.planPreparationGeneration == generation {
                            self.planPreparationTask = nil
                        }
                    }
                    let outcome = await self.beginMatchingReviewedSongs(navigate: false)
                    guard !Task.isCancelled,
                          self.planPreparationGeneration == generation,
                          self.currentStage == startingStage else { return }
                    guard outcome == .completed else {
                        if outcome == .needsReview, navigate {
                            self.setStage(.review)
                        }
                        return
                    }
                    guard self.preferenceProfile != nil else {
                        if navigate {
                            self.setStage(.review)
                        }
                        return
                    }
                    self.generatePlan(
                        navigate: navigate,
                        schedulesPersistence: schedulesPersistence
                    )
                }
                planPreparationTask = task
                return
            }
        }

        guard let profile = preferenceProfile else {
            errorMessage = "暂时排不了歌单，请先导入一份歌单。"
            return
        }
        guard importedPlaylist != nil else {
            errorMessage = "暂时排不了歌单，请重新导入后再试。"
            return
        }
        guard planGenerationTask == nil, !isGeneratingPlan else { return }

        let voice = voiceProfile ?? voiceAnalyzer.simulatedProfile()
        if voiceProfile == nil {
            voiceProfile = voice
        }
        guard let basis = currentPlanBasis else {
            errorMessage = "歌曲参考已经有变化，请先重新核对后再排歌。"
            return
        }
        guard let generationContext = currentPlanGenerationContext(using: voice) else {
            errorMessage = "歌曲参考已经有变化，请先重新核对后再排歌。"
            return
        }

        let frozenMatches = matches
        let frozenScenario = scenarioConfig
        let frozenCatalog = catalog
        let frozenInputSource = recommendationInputSource
        let frozenLockedTrackIDs = lockedTrackIDs
        let frozenRemovedTrackIDs = removedTrackIDs
        let frozenFeedback = feedbackProfile
        let previousPlan = visibleSongPlan
        let startingStage = currentStage
        let request = planGenerationGate.begin()
        planStateTransitionGate.invalidate()
        let shouldDelayFixture = ProcessInfo.processInfo.arguments.contains(
            "-singreadyDelayPlanGeneration"
        )
        let generatingState = planGenerationState.preparingGeneration(for: basis)
        // 先在内存中关闭上一版的 ready 安全门，但不对外声称已开始重排。
        // 只有 actor 把 generating(previous) 映射的 stale 快照写盘后，
        // 才发布 generating，确保用户看到进度后强退也不会复活旧 ready。
        setPlanGenerationState(
            planGenerationState.invalidated(reason: "正在准备重排")
        )
        guard let initialSnapshotReservation = reservePlanStateSnapshotCommit(
            generatingState
        ) else {
            finishPlanGenerationFailure(
                request: request,
                message: "当前进度暂时没保存下来，请稍后再试。",
                schedulesPersistence: schedulesPersistence
            )
            return
        }
        errorMessage = nil
        statusMessage = "正在保存最新选择"

        planGenerationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.cleanupPlanGenerationIfCurrent(
                    request: request,
                    basis: basis
                )
            }
            guard await commitGeneratingStateBeforeWork(
                generatingState,
                initialReservation: initialSnapshotReservation,
                request: request,
                basis: basis
            ) else {
                if planGenerationGate.accepts(request), currentPlanBasis == basis {
                    finishPlanGenerationFailure(
                        request: request,
                        message: "当前进度暂时没保存下来，上一版还在，可以稍后重试。",
                        schedulesPersistence: schedulesPersistence
                    )
                }
                return
            }
            setPlanGenerationState(generatingState)
            statusMessage = "正在按最新选择排歌"

            do {
                let engine = recommendationEngine
                let generatedPlan = try await Task.detached(priority: .userInitiated) {
                    #if DEBUG
                    if shouldDelayFixture {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                    #endif
                    return try engine.generatePlan(
                        matches: frozenMatches,
                        preferenceProfile: profile,
                        voiceProfile: voice,
                        scenario: frozenScenario,
                        catalog: frozenCatalog,
                        generationContext: generationContext,
                        inputSource: frozenInputSource,
                        lockedTrackIDs: frozenLockedTrackIDs,
                        removedTrackIDs: frozenRemovedTrackIDs,
                        feedbackProfile: frozenFeedback
                    )
                }.value
                let finalItems = generatedPlan.sections.flatMap(\.items)
                let expectedSummary = try SongPlanGenerationSummary(
                    context: generationContext,
                    items: finalItems
                )
                guard generatedPlan.generationSummary == expectedSummary else {
                    throw RecommendationGenerationError.countMismatch
                }
                let stablePlan = preservingIdentity(
                    in: generatedPlan,
                    previousPlan: previousPlan
                )
                guard planMatchesCurrentGenerationContext(stablePlan, basis: basis),
                      acceptsPlanGeneration(
                          request: request,
                          basis: basis
                      ) else {
                    return
                }
                guard let committedReservation = await commitGeneratedPlanSnapshot(
                    stablePlan,
                    basis: basis,
                    request: request
                ) else {
                    if planGenerationGate.accepts(request), currentPlanBasis == basis {
                        finishPlanGenerationFailure(
                            request: request,
                            message: "排歌结果暂时没保存下来，上一版还在，可以重新排一次。",
                            schedulesPersistence: schedulesPersistence
                        )
                    }
                    return
                }
                let shouldNavigate = navigate
                    && planGenerationGate.accepts(request)
                    && currentStage == startingStage
                let canPublishReady = !Task.isCancelled
                    && planGenerationGate.accepts(request)
                    && currentPlanBasis == basis

                // 只有这次请求仍是当前请求时才发布 ready。若用户已取消，
                // 更新的取消提交会在 actor 中排在本次提交之后，这里不短暂复活 ready。
                guard canPublishReady else {
                    planGenerationTask = nil
                    return
                }
                setPlanGenerationState(.ready(plan: stablePlan, basis: basis))
                if workflowSnapshotPersistenceGate.accepts(committedReservation.generation),
                   workflowSnapshotRevision == committedReservation.candidate.revision {
                    lastWorkflowSnapshotAttemptRevision = committedReservation.candidate.revision
                }
                planGenerationTask = nil
                errorMessage = nil
                _ = planGenerationGate.finish(request)
                statusMessage = "已排好\(stablePlan.scenario.displayName)歌单"
                if shouldNavigate {
                    setStage(.result)
                }
            } catch is CancellationError {
                guard planGenerationGate.accepts(request) else { return }
                _ = planGenerationGate.finish(request)
                planGenerationTask = nil
                let invalidatedState = planGenerationState.invalidated(
                    reason: "这次重排已取消"
                )
                setPlanGenerationState(invalidatedState)
                persistPlanStateImmediately(invalidatedState, reportFailure: false)
            } catch let RecommendationGenerationError.lockedTrackUnavailable(trackIDs) {
                finishPlanGenerationFailure(
                    request: request,
                    message: "有 \(trackIDs.count) 首已保留歌曲暂时无法参与排歌，请取消保留或重新确认后再试。",
                    schedulesPersistence: schedulesPersistence
                )
            } catch {
                finishPlanGenerationFailure(
                    request: request,
                    message: "这次没排好，上一版还在，可以稍后重试。",
                    schedulesPersistence: schedulesPersistence
                )
            }
        }
    }

    func regeneratePlan() {
        generatePlan()
    }

    func currentPlanGenerationContext(
        using voice: VoiceProfile? = nil
    ) -> SongPlanGenerationContext? {
        guard let playlist = importedPlaylist,
              completedAnalysis != nil else { return nil }
        let statistics = MatchStatistics(matches: matches)
        let effectiveVoice = voice ?? voiceProfile ?? voiceAnalyzer.simulatedProfile()
        return SongPlanGenerationContext(
            playlistID: playlist.id,
            playlistTitle: playlist.title,
            importedSongCount: playlist.songs.count,
            verifiedSongCount: statistics.verified,
            pendingSongCount: statistics.pending,
            unmatchedSongCount: statistics.unmatched,
            scenario: scenarioConfig.scenario,
            peopleCount: scenarioConfig.peopleCount,
            durationMinutes: scenarioConfig.durationMinutes,
            voiceSource: effectiveVoice.source,
            feedbackCount: feedbackProfile.feedbackByTrackID.values.reduce(0) { count, feedback in
                count + feedback.count
            }
        )
    }

    func planMatchesCurrentGenerationContext(
        _ plan: SongPlan,
        basis expectedBasis: PlanBasis? = nil
    ) -> Bool {
        let items = plan.sections.flatMap(\.items)
        let plannedTrackIDs = Set(items.map(\.track.id))
        let forbiddenRemovedTrackIDs = removedTrackIDs.subtracting(lockedTrackIDs)
        guard !items.isEmpty,
              items.allSatisfy({ $0.track.catalogSource == .ktvCatalog }),
              lockedTrackIDs.isSubset(of: plannedTrackIDs),
              forbiddenRemovedTrackIDs.isDisjoint(with: plannedTrackIDs),
              let currentBasis = currentPlanBasis,
              let planBasis = expectedBasis ?? currentPlanBasis,
              PlaylistWorkflowValidityPolicy.accepts(
                  plan: plan,
                  planBasis: planBasis,
                  currentBasis: currentBasis,
                  scenarioConfig: scenarioConfig,
                  inputSource: recommendationInputSource
              ),
              let context = currentPlanGenerationContext(),
              let expectedSummary = try? SongPlanGenerationSummary(
                  context: context,
                  items: items
              ) else {
            return false
        }
        return plan.generationSummary == expectedSummary
            && plan.voiceProfile == (voiceProfile ?? voiceAnalyzer.simulatedProfile())
    }

    func selectScenario(_ scenario: KTVScenario) {
        var updated = scenarioConfig
        updated.scenario = scenario
        scenarioConfig = updated
    }

    func setScenarioPeopleCount(_ peopleCount: Int) {
        var updated = scenarioConfig
        updated.peopleCount = peopleCount
        scenarioConfig = updated
    }

    func setScenarioDuration(_ durationMinutes: Int) {
        var updated = scenarioConfig
        updated.durationMinutes = durationMinutes
        scenarioConfig = updated
    }

    func setScenarioVibe(_ vibe: PlaylistVibe) {
        var updated = scenarioConfig
        updated.vibe = vibe
        scenarioConfig = updated
    }

    func setScenarioDifficulty(_ difficulty: DifficultyPreference) {
        var updated = scenarioConfig
        updated.difficultyPreference = difficulty
        scenarioConfig = updated
    }

    func setScenarioChorusPreference(_ preference: ChorusPreference) {
        var updated = scenarioConfig
        updated.chorusPreference = preference
        scenarioConfig = updated
    }

    func toggleLock(trackID: String) {
        guard canUseReadyPlan else {
            errorMessage = readyPlanUnavailableMessage
            return
        }
        if lockedTrackIDs.contains(trackID) {
            lockedTrackIDs.remove(trackID)
        } else {
            lockedTrackIDs.insert(trackID)
            removedTrackIDs.remove(trackID)
        }
        incrementTrackControlsRevision()
        invalidatePlan(reason: "保留歌曲已更新")
        generatePlan()
    }

    @discardableResult
    func removeTrack(trackID: String) -> String {
        guard canUseReadyPlan else {
            errorMessage = readyPlanUnavailableMessage
            return readyPlanUnavailableMessage
        }
        let title = visibleSongPlan?.sections
            .flatMap(\.items)
            .first(where: { $0.track.id == trackID })?
            .track.title ?? "这首歌"
        let transition = TrackControlPolicy().remove(
            trackID: trackID,
            title: title,
            from: TrackControlState(
                lockedTrackIDs: lockedTrackIDs,
                removedTrackIDs: removedTrackIDs
            )
        )
        lockedTrackIDs = transition.state.lockedTrackIDs
        removedTrackIDs = transition.state.removedTrackIDs
        statusMessage = transition.message
        guard transition.didRemove else { return transition.message }
        incrementTrackControlsRevision()
        invalidatePlan(reason: "移除歌曲已更新")
        generatePlan()
        lastRemovedTrackUndo = RemovedTrackUndoAction(trackID: trackID, title: title)
        statusMessage = transition.message
        return transition.message
    }

    func undoLastTrackRemoval() {
        guard canUseReadyPlan else {
            errorMessage = readyPlanUnavailableMessage
            return
        }
        guard let action = lastRemovedTrackUndo else { return }
        removedTrackIDs.remove(action.trackID)
        incrementTrackControlsRevision()
        invalidatePlan(reason: "移除歌曲已更新")
        generatePlan()
        statusMessage = "《\(action.title)》已放回歌单"
        lastRemovedTrackUndo = nil
    }

    func restoreRemovedTrack(trackID: String) {
        guard canUseReadyPlan else {
            errorMessage = readyPlanUnavailableMessage
            return
        }
        guard removedTrackIDs.remove(trackID) != nil else { return }
        let title = (catalog + externalCandidateTracks)
            .first(where: { $0.id == trackID })?
            .title ?? "这首歌"
        lastRemovedTrackUndo = nil
        incrementTrackControlsRevision()
        invalidatePlan(reason: "移除歌曲已更新")
        generatePlan()
        statusMessage = "《\(title)》已恢复为可选歌曲"
    }

    func restoreAllRemovedTracks() {
        guard canUseReadyPlan else {
            errorMessage = readyPlanUnavailableMessage
            return
        }
        guard !removedTrackIDs.isEmpty else { return }
        removedTrackIDs = []
        lastRemovedTrackUndo = nil
        incrementTrackControlsRevision()
        invalidatePlan(reason: "移除歌曲已更新")
        generatePlan()
        statusMessage = "已恢复全部移除歌曲"
    }

    func invalidatePlan(reason: String) {
        let hadActiveGeneration = isGeneratingPlan || planGenerationTask != nil
        planGenerationGate.cancel()
        planGenerationTask?.cancel()
        planGenerationTask = nil
        let invalidatedState = planGenerationState.invalidated(reason: reason)
        lastRemovedTrackUndo = nil
        guard hadActiveGeneration else {
            setPlanGenerationState(invalidatedState)
            persistPlanStateImmediately(invalidatedState, reportFailure: false)
            return
        }
        let transition = planStateTransitionGate.begin()
        guard let reservation = reservePlanStateSnapshotCommit(invalidatedState) else {
            errorMessage = "当前状态暂时没保存下来，请稍后重试。"
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.persistPlanStateBeforePublication(
                invalidatedState,
                initialReservation: reservation,
                transition: transition,
                successStatus: nil,
                failureMessage: "当前状态暂时没保存下来，请稍后重试。",
                failureStatus: nil
            )
        }
    }

    func cancelCurrentPlanGeneration() {
        guard isGeneratingPlan else { return }
        planGenerationGate.cancel()
        planGenerationTask?.cancel()
        planGenerationTask = nil
        lastRemovedTrackUndo = nil
        let transition = planStateTransitionGate.begin()
        let cancelledState = planGenerationState.invalidated(
            reason: "这次重排已取消"
        )
        guard let reservation = reservePlanStateSnapshotCommit(cancelledState) else {
            errorMessage = "取消状态暂时没保存下来，请再试一次。"
            return
        }
        statusMessage = "正在取消重排"
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.persistPlanStateBeforePublication(
                cancelledState,
                initialReservation: reservation,
                transition: transition,
                successStatus: "已取消重排，上一版歌单还在。",
                failureMessage: "取消状态暂时没保存下来，请再试一次。",
                failureStatus: "重排已停止，当前状态还在保存"
            )
        }
    }

    private func acceptsPlanGeneration(
        request: UInt64,
        basis: PlanBasis
    ) -> Bool {
        !Task.isCancelled
            && planGenerationGate.accepts(request)
            && currentPlanBasis == basis
    }

    private func commitGeneratingStateBeforeWork(
        _ state: PlanGenerationState,
        initialReservation: WorkflowSnapshotCommitReservation,
        request: UInt64,
        basis: PlanBasis
    ) async -> Bool {
        var reservation = initialReservation
        for _ in 0..<4 {
            guard acceptsPlanGeneration(request: request, basis: basis) else {
                return false
            }
            guard let result = await commitReservedWorkflowSnapshot(
                reservation,
                reportFailure: false
            ) else {
                return false
            }
            if case .applied = result,
               workflowSnapshotPersistenceGate.accepts(reservation.generation) {
                return true
            }
            guard acceptsPlanGeneration(request: request, basis: basis),
                  let nextReservation = reservePlanStateSnapshotCommit(
                      state,
                      advancesRevision: false
                  ) else {
                return false
            }
            reservation = nextReservation
            await Task.yield()
        }
        return false
    }

    private func persistPlanStateBeforePublication(
        _ state: PlanGenerationState,
        initialReservation: WorkflowSnapshotCommitReservation,
        transition: UInt64,
        successStatus: String?,
        failureMessage: String,
        failureStatus: String?
    ) async {
        var reservation = initialReservation
        for _ in 0..<4 {
            guard planStateTransitionGate.accepts(transition) else { return }
            guard let result = await commitReservedWorkflowSnapshot(
                reservation,
                reportFailure: false
            ) else {
                break
            }
            if case .applied = result,
               workflowSnapshotPersistenceGate.accepts(reservation.generation),
               planStateTransitionGate.accepts(transition) {
                setPlanGenerationState(state)
                if let successStatus {
                    statusMessage = successStatus
                }
                return
            }
            guard let nextReservation = reservePlanStateSnapshotCommit(
                state,
                advancesRevision: false
            ) else {
                break
            }
            reservation = nextReservation
            await Task.yield()
        }
        guard planStateTransitionGate.accepts(transition) else { return }
        errorMessage = failureMessage
        if let failureStatus {
            statusMessage = failureStatus
        }
    }

    private func commitGeneratedPlanSnapshot(
        _ plan: SongPlan,
        basis: PlanBasis,
        request: UInt64
    ) async -> WorkflowSnapshotCommitReservation? {
        // 公开候选与首页浏览等非排歌输入也会保存工作流快照，但不应让正式排歌失效。
        // 每次提交都合并最新稳定状态；若恰好被另一笔快照抢先，使用新 generation 重试。
        let readyState = PlanGenerationState.ready(plan: plan, basis: basis)
        var advancesRevision = true
        for _ in 0..<4 {
            guard acceptsPlanGeneration(request: request, basis: basis) else {
                return nil
            }
            guard let reservation = reservePlanStateSnapshotCommit(
                readyState,
                advancesRevision: advancesRevision
            ) else {
                return nil
            }
            advancesRevision = false
            guard let result = await commitReservedWorkflowSnapshot(
                reservation,
                reportFailure: false
            ) else {
                return nil
            }
            if case .applied = result {
                // 提交期间 basis 变化或用户取消时，返回真实已写入的候选。
                // 更新的状态转换已预约在 actor 之后，调用方不再发布过期 ready。
                if currentPlanBasis != basis || !planGenerationGate.accepts(request) {
                    return reservation
                }
                if workflowSnapshotPersistenceGate.accepts(reservation.generation) {
                    return reservation
                }
            }
            guard acceptsPlanGeneration(request: request, basis: basis) else {
                return nil
            }
            await Task.yield()
        }
        return nil
    }

    private func finishPlanGenerationFailure(
        request: UInt64,
        message: String,
        schedulesPersistence: Bool
    ) {
        guard planGenerationGate.finish(request) else { return }
        planGenerationTask = nil
        let failedState = planGenerationState.failing(
            message: message,
            retryable: true
        )
        setPlanGenerationState(failedState)
        errorMessage = message
        statusMessage = message
        guard schedulesPersistence else { return }
        persistPlanStateImmediately(failedState, reportFailure: false)
    }

    private func cleanupPlanGenerationIfCurrent(
        request: UInt64,
        basis: PlanBasis
    ) {
        guard planGenerationGate.accepts(request) else { return }
        _ = planGenerationGate.finish(request)
        planGenerationTask = nil
        if case let .generating(activeBasis, _) = planGenerationState,
           activeBasis == basis {
            let invalidatedState = planGenerationState.invalidated(
                reason: "排歌条件已更新"
            )
            setPlanGenerationState(invalidatedState)
            persistPlanStateImmediately(invalidatedState, reportFailure: false)
        }
    }

    private func incrementTrackControlsRevision() {
        var nextRevisions = revisions
        nextRevisions.trackControls &+= 1
        replaceWorkflowRevisions(nextRevisions)
    }

    private func preservingIdentity(
        in generatedPlan: SongPlan,
        previousPlan: SongPlan?
    ) -> SongPlan {
        guard let existingPlan = previousPlan,
              existingPlan.scenario == generatedPlan.scenario else {
            return generatedPlan
        }

        var plan = generatedPlan
        plan.id = existingPlan.id
        plan.createdAt = existingPlan.createdAt
        let sectionIDs = Dictionary(
            existingPlan.sections.map { ($0.title, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        let itemIDs = Dictionary(
            existingPlan.sections.flatMap(\.items).map { ($0.track.id, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        plan.sections = plan.sections.map { section in
            var stableSection = section
            stableSection.id = sectionIDs[section.title] ?? section.id
            stableSection.items = section.items.map { item in
                var stableItem = item
                stableItem.id = itemIDs[item.track.id] ?? item.id
                return stableItem
            }
            return stableSection
        }
        return plan
    }

    private func prepareDefaultPlanContext() {
        let seedTracks = catalog
            .sorted {
                if $0.singAlongScore == $1.singAlongScore {
                    return $0.ktvAvailability > $1.ktvAvailability
                }
                return $0.singAlongScore > $1.singAlongScore
            }
            .prefix(24)

        guard !seedTracks.isEmpty else { return }

        let songs = seedTracks.map { track in
            ImportedSong(
                title: track.title,
                artist: track.artist,
                source: .curated,
                confidence: 1
            )
        }
        let playlist = ImportedPlaylist(
            source: .curated,
            title: "热门 K 歌",
            songs: songs,
            parseConfidence: 1
        )
        importedPlaylist = playlist
        recommendationInputSource = .popularFallback
        replaceReviewSongs(playlist.songs.map(EditableImportedSongDraft.init))
        replaceWorkflowRevisions(WorkflowRevisionLedger())
        let preparedMatches = zip(playlist.songs, seedTracks).map { song, track in
            MatchResult(
                importedSong: song,
                matchedTrack: track,
                alternatives: [],
                status: .exact,
                score: 1,
                reason: "来自常见 K 歌参考"
            )
        }
        if let basis = currentMatchBasis {
            var nextRevisions = revisions
            nextRevisions.match &+= 1
            replaceWorkflowRevisions(nextRevisions)
            replaceCompletedAnalysis(CompletedPlaylistAnalysis(
                basis: basis,
                matchRevision: nextRevisions.match,
                matches: preparedMatches,
                preferenceProfile: profiler.buildProfile(
                    importedPlaylist: playlist,
                    matches: preparedMatches
                )
            ))
            setMatchOperationState(.ready(basis))
        }
        statusMessage = "先按热门 K 歌排一版，导入自己的歌单会更贴合你。"
    }
}
