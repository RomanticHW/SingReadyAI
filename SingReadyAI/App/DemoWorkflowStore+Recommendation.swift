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
        guard let playlist = importedPlaylist else {
            errorMessage = "暂时排不了歌单，请重新导入后再试。"
            return
        }
        let voice = voiceProfile ?? voiceAnalyzer.simulatedProfile()
        let statistics = MatchStatistics(matches: matches)
        let generationContext = SongPlanGenerationContext(
            playlistID: playlist.id,
            playlistTitle: playlist.title,
            importedSongCount: playlist.songs.count,
            verifiedSongCount: statistics.verified,
            pendingSongCount: statistics.pending,
            unmatchedSongCount: statistics.unmatched,
            scenario: scenarioConfig.scenario,
            peopleCount: scenarioConfig.peopleCount,
            durationMinutes: scenarioConfig.durationMinutes,
            voiceSource: voice.source,
            feedbackCount: feedbackProfile.feedbackByTrackID.values.reduce(0) { count, feedback in
                count + feedback.count
            }
        )
        do {
            let generatedPlan = try recommendationEngine.generatePlan(
                matches: matches,
                preferenceProfile: profile,
                voiceProfile: voice,
                scenario: scenarioConfig,
                catalog: catalog + externalCandidateTracks,
                generationContext: generationContext,
                inputSource: recommendationInputSource,
                lockedTrackIDs: lockedTrackIDs,
                removedTrackIDs: removedTrackIDs,
                feedbackProfile: feedbackProfile
            )
            voiceProfile = voice
            songPlan = preservingIdentity(in: generatedPlan)
            errorMessage = nil
            statusMessage = "已排好\(scenarioConfig.scenario.displayName)歌单"
            if schedulesPersistence {
                Task { @MainActor [weak self] in
                    _ = await self?.persistWorkflowSnapshot()
                }
            }
            if navigate {
                setStage(.result)
            }
        } catch let RecommendationGenerationError.lockedTrackUnavailable(trackIDs) {
            errorMessage = "有 \(trackIDs.count) 首已保留歌曲无法按当前条件核对来源，请取消保留或重新确认后再试。"
        } catch {
            errorMessage = "暂时无法生成歌单，请检查当前选择后重试。"
        }
    }

    func regeneratePlan() {
        generatePlan()
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
        if lockedTrackIDs.contains(trackID) {
            lockedTrackIDs.remove(trackID)
        } else {
            lockedTrackIDs.insert(trackID)
            removedTrackIDs.remove(trackID)
        }
        generatePlan()
    }

    @discardableResult
    func removeTrack(trackID: String) -> String {
        let title = songPlan?.sections
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
        generatePlan()
        lastRemovedTrackUndo = RemovedTrackUndoAction(trackID: trackID, title: title)
        statusMessage = transition.message
        return transition.message
    }

    func undoLastTrackRemoval() {
        guard let action = lastRemovedTrackUndo else { return }
        removedTrackIDs.remove(action.trackID)
        generatePlan()
        statusMessage = "《\(action.title)》已放回歌单"
        lastRemovedTrackUndo = nil
    }

    func restoreRemovedTrack(trackID: String) {
        guard removedTrackIDs.remove(trackID) != nil else { return }
        let title = (catalog + externalCandidateTracks)
            .first(where: { $0.id == trackID })?
            .title ?? "这首歌"
        lastRemovedTrackUndo = nil
        generatePlan()
        statusMessage = "《\(title)》已恢复为可选歌曲"
    }

    func restoreAllRemovedTracks() {
        guard !removedTrackIDs.isEmpty else { return }
        removedTrackIDs = []
        lastRemovedTrackUndo = nil
        generatePlan()
        statusMessage = "已恢复全部移除歌曲"
    }

    private func preservingIdentity(in generatedPlan: SongPlan) -> SongPlan {
        guard let existingPlan = songPlan,
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
