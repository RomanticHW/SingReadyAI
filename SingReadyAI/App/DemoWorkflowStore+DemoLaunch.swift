#if DEBUG
import Foundation
import SingReadyAISharedKit

extension DemoWorkflowStore {
    func prepareDemoState(for launchStage: DemoLaunchStage) async {
        pendingImportPersistenceGate.invalidate()
        recentPlaylistPersistenceGate.invalidate()
        workflowSnapshotPersistenceGate.invalidate()
        voiceProfilePersistenceGate.invalidate()
        let wasApplyingRestoredWorkflowSnapshot = isApplyingRestoredWorkflowSnapshot
        isApplyingRestoredWorkflowSnapshot = true
        let seedsStaleFeedbackSnapshot = ProcessInfo.processInfo.arguments.contains(
            "-singreadySeedStaleFeedbackSnapshot"
        )
        defer {
            isApplyingRestoredWorkflowSnapshot = wasApplyingRestoredWorkflowSnapshot
        }
        errorMessage = nil
        cancelWorkflowOperation()
        setMatchOperationState(.notStarted)
        feedbackProfile = .empty
        hasStandaloneFeedbackRecord = false
        feedbackStatusMessage = nil
        lastFeedbackUndo = nil
        voiceProfile = nil
        do {
            try await voiceProfileStore.clear()
        } catch {
            errorMessage = "测试场景的音域记录暂时没清理干净。"
        }
        scenarioConfig = ScenarioConfig()

        if launchStage == .home {
            resetImport(navigateToImport: false)
            replaceNavigation(with: .home)
            return
        }

        if launchStage == .importHub {
            resetImport(navigateToImport: false)
            if ProcessInfo.processInfo.arguments.contains("-singreadySeedPendingImport") {
                let payload = PendingImportPayload(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!,
                    sourceHint: .plainText,
                    rawText: "晴天 - 周杰伦",
                    displayTitle: "测试分享"
                )
                let deadline = MonotonicOperationDeadline(timeoutNanoseconds: 1_000_000_000)
                try? await appGroupStore.removePendingImport(id: payload.id, deadline: deadline)
                _ = try? await appGroupStore.commitPendingImport(
                    payload,
                    deadline: MonotonicOperationDeadline(timeoutNanoseconds: 1_000_000_000)
                )
                await loadPendingImports()
            }
            await loadRecentPlaylists()
            replaceNavigation(with: .importHub)
            return
        }

        if launchStage == .review,
           ProcessInfo.processInfo.arguments.contains("-singreadyLargeMixedReview") {
            await prepareLargeMixedReviewState()
            replaceNavigation(with: .review)
            return
        }

        if launchStage == .matchReport,
           ProcessInfo.processInfo.arguments.contains("-singreadyMixedMatchReview") {
            await prepareMixedMatchReviewState()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-singreadyExistingPlanForCandidateLifecycle") {
                useSimulatedVoice(navigate: false)
                scenarioConfig = ScenarioConfig(
                    scenario: .friends,
                    peopleCount: 5,
                    durationMinutes: 90,
                    vibe: .chorus,
                    chorusPreference: .moreChorus
                )
                generatePlan(navigate: false, schedulesPersistence: false)
                await planGenerationTask?.value
                _ = await persistWorkflowSnapshot()
            }
            #endif
            replaceNavigation(with: .matchReport)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-singreadySeedGeneratingPlanState"),
               let basis = currentPlanBasis {
                setPlanGenerationState(
                    planGenerationState.preparingGeneration(for: basis)
                )
            }
            #endif
            return
        }
        if launchStage == .matchReport,
           ProcessInfo.processInfo.arguments.contains("-singreadyNoReferenceInsights") {
            await prepareNoReferenceInsightsState()
            replaceNavigation(with: .matchReport)
            return
        }

        do {
            var playlist = try ImportCoordinator().resolveDemoPlaylist()
            if ProcessInfo.processInfo.arguments.contains("-singreadySingleReviewSong") {
                playlist.songs = Array(playlist.songs.prefix(1))
                playlist.title = "单曲整理测试"
            }
            try await installStableDemoWorkflow(
                playlist: playlist,
                recommendationInputSource: .example
            )
        } catch {
            errorMessage = error.localizedDescription
            replaceNavigation(with: .importHub)
            return
        }

        if launchStage == .review {
            replaceNavigation(with: .review)
            return
        }

        await beginMatchingReviewedSongs(navigate: false)
        if ProcessInfo.processInfo.arguments.contains("-singreadyMeasuredVoiceBeforeMatch") {
            voiceProfile = VoiceProfile(
                type: .unknown,
                minMidi: 48,
                maxMidi: 72,
                stableLowMidi: 52,
                stableHighMidi: 69,
                averageMidi: 60.5,
                confidence: 0.72,
                note: "这是本次唱到的音区，仅作排歌参考，不代表完整音域。",
                source: .measured
            )
        }
        if launchStage == .matchReport {
            replaceNavigation(with: .matchReport)
            return
        }

        if launchStage == .voiceSetup {
            voiceProfile = nil
            recordingState = .idle
            replaceNavigation(with: .voice)
            return
        }

        useSimulatedVoice(navigate: false)
        if launchStage == .voiceResult {
            replaceNavigation(with: .voice)
            return
        }

        let usesShortPlanFixture = ProcessInfo.processInfo.arguments.contains("-singreadyShortPlanNotice")
        let usesSoloScenario = ProcessInfo.processInfo.arguments.contains("-singreadySoloScenario")
        scenarioConfig = ScenarioConfig(
            scenario: usesSoloScenario ? .soloPractice : .friends,
            peopleCount: usesSoloScenario ? 1 : 5,
            durationMinutes: usesShortPlanFixture ? 60 : 90,
            vibe: usesSoloScenario ? .balanced : .chorus,
            chorusPreference: usesSoloScenario ? .moreSolo : .moreChorus
        )
        if launchStage == .scenario {
            replaceNavigation(with: .scenario)
            return
        }

        if usesShortPlanFixture {
            let retainedTrackIDs = Set(catalog.prefix(4).map(\.id))
            removedTrackIDs = Set(catalog.lazy.filter { !retainedTrackIDs.contains($0.id) }.map(\.id))
        }

        if usesSoloScenario,
           ProcessInfo.processInfo.arguments.contains("-singreadySoloChorusFeedback") {
            feedbackProfile = SongFeedbackProfile(
                feedbackByTrackID: Dictionary(
                    uniqueKeysWithValues: catalog.map { ($0.id, [.chorusFriendly, .liked]) }
                )
            )
        }
        if seedsStaleFeedbackSnapshot {
            feedbackProfile = SongFeedbackProfile(
                feedbackByTrackID: Dictionary(
                    uniqueKeysWithValues: catalog.map { ($0.id, [.liked]) }
                )
            )
        }

        generatePlan(navigate: false, schedulesPersistence: false)
        await planGenerationTask?.value
        if ProcessInfo.processInfo.arguments.contains("-singreadyLongLockedTrackTitle"),
           var plan = visibleSongPlan,
           let sectionIndex = plan.sections.firstIndex(where: { !$0.items.isEmpty }),
           let itemIndex = plan.sections[sectionIndex].items.indices.first {
            let track = plan.sections[sectionIndex].items[itemIndex].track
            let trackID = track.id
            plan.sections[sectionIndex].items[itemIndex].track = KTVTrack(
                id: track.id,
                title: "这是一首用于验证常规字号警告完整展示的超长歌曲名称特别加长现场版",
                artist: track.artist,
                language: track.language,
                era: track.era,
                genre: track.genre,
                moodTags: track.moodTags,
                sceneTags: track.sceneTags,
                difficulty: track.difficulty,
                vocalRangeLowMidi: track.vocalRangeLowMidi,
                vocalRangeHighMidi: track.vocalRangeHighMidi,
                energy: track.energy,
                singAlongScore: track.singAlongScore,
                ktvAvailability: track.ktvAvailability,
                duetFriendly: track.duetFriendly,
                rapDensity: track.rapDensity,
                highNoteRisk: track.highNoteRisk,
                aliases: track.aliases,
                similarSongIds: track.similarSongIds,
                externalURL: track.externalURL,
                catalogSource: track.catalogSource,
                confidenceNote: track.confidenceNote,
                externalCandidateMetadata: track.externalCandidateMetadata
            )
            plan.sections[sectionIndex].items[itemIndex].isLocked = true
            lockedTrackIDs.insert(trackID)
            if case let .ready(_, basis) = planGenerationState {
                setPlanGenerationState(.ready(plan: plan, basis: basis))
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-singreadyCandidateChangeAfterPlan"),
           let candidate = catalog.last {
            externalCandidateTracks = [candidate]
            invalidatePlanForExternalCandidateChange()
        }
        switch launchStage {
        case .result:
            replaceNavigation(with: .result)
        case .export:
            replaceNavigation(with: .export)
        case .startTips:
            replaceNavigation(with: .startTips)
        default:
            break
        }
        do {
            try SongFeedbackLocalStore().save(
                SongFeedbackRecord(
                    revision: revisions.feedback,
                    profile: feedbackProfile
                )
            )
            standaloneFeedbackRevision = revisions.feedback
            hasStandaloneFeedbackRecord = true
        } catch {
            errorMessage = "测试场景的歌曲反馈暂时没保存下来。"
        }
        _ = await persistWorkflowSnapshot()
        if seedsStaleFeedbackSnapshot {
            let standaloneTruth = SongFeedbackProfile(
                feedbackByTrackID: Dictionary(
                    uniqueKeysWithValues: catalog.map { ($0.id, [.tooHigh]) }
                )
            )
            let standaloneRevision = revisions.feedback &+ 1
            try? SongFeedbackLocalStore().save(
                SongFeedbackRecord(
                    revision: standaloneRevision,
                    profile: standaloneTruth
                )
            )
            standaloneFeedbackRevision = standaloneRevision
            hasStandaloneFeedbackRecord = true
        }
    }

    private func installStableDemoWorkflow(
        playlist: ImportedPlaylist,
        recommendationInputSource: RecommendationInputSource
    ) async throws {
        let generation = workflowSnapshotPersistenceGate.begin()
        await workflowPersistenceExecutor.reserveWorkflowMutation(generation: generation)
        let candidate = makeInitialWorkflowCandidate(
            playlist: playlist,
            inputSource: recommendationInputSource
        )
        _ = try await commitImportedWorkflow(
            candidate,
            generation: generation,
            navigate: false,
            recordsRecentPlaylist: false
        )
    }

    private func prepareLargeMixedReviewState() async {
        guard !catalog.isEmpty else { return }
        let songs = (0..<120).map { index -> ImportedSong in
            let track = catalog[index % catalog.count]
            switch index % 3 {
            case 0:
                return ImportedSong(
                    title: track.title,
                    artist: track.artist,
                    source: .plainText,
                    confidence: 1
                )
            case 1:
                return ImportedSong(
                    title: track.title,
                    source: .plainText,
                    confidence: 0.9
                )
            default:
                return ImportedSong(
                    title: "待查歌曲 \(index + 1)",
                    artist: "测试歌手 \(index + 1)",
                    source: .plainText,
                    confidence: 1
                )
            }
        }
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "大型混合歌单",
            songs: songs,
            parseConfidence: 0.95
        )
        try? await installStableDemoWorkflow(
            playlist: playlist,
            recommendationInputSource: .userImport
        )
        statusMessage = "120 首歌已导入，可以先看建议核对的部分。"
    }

    private func prepareMixedMatchReviewState() async {
        let songs = [
            ImportedSong(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
                title: "晴天",
                artist: "周杰伦",
                source: .plainText,
                confidence: 1
            ),
            ImportedSong(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
                title: "喜欢你",
                source: .plainText,
                confidence: 0.7
            ),
            ImportedSong(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!,
                title: "不存在的测试歌名",
                artist: "未知歌手",
                source: .plainText,
                confidence: 0.4
            ),
            ImportedSong(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000204")!,
                title: "稻香现场记忆版",
                artist: "周杰伦",
                source: .plainText,
                confidence: 0.7
            ),
            ImportedSong(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000205")!,
                title: "冬天里",
                artist: "汪峰",
                source: .plainText,
                confidence: 0.6
            )
        ]
        let playlist = ImportedPlaylist(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000200")!,
            source: .plainText,
            title: "逐首核对歌单",
            songs: songs,
            parseConfidence: 0.7
        )
        try? await installStableDemoWorkflow(
            playlist: playlist,
            recommendationInputSource: .userImport
        )
        guard let exact = catalog.first(where: { $0.id == "t001" }),
              let identity = catalog.first(where: { $0.id == "t029" }),
              let unmatchedBackup = catalog.first(where: { $0.id == "t003" }),
              let fuzzy = catalog.first(where: { $0.id == "t002" }) else {
            await beginMatchingReviewedSongs(navigate: false)
            return
        }
        let preparedMatches = [
            MatchResult(
                importedSong: songs[0],
                matchedTrack: exact,
                alternatives: [],
                status: .exact,
                score: 1,
                reason: "歌名和歌手在本地参考曲库中命中"
            ),
            MatchResult(
                importedSong: songs[1],
                matchedTrack: nil,
                alternatives: [identity],
                status: .fuzzy,
                confirmationState: .required,
                score: 1,
                reason: "找到同名歌曲，请确认歌手"
            ),
            MatchResult(
                importedSong: songs[2],
                matchedTrack: nil,
                alternatives: [unmatchedBackup],
                status: .unmatched,
                score: 0.2,
                reason: "本地参考曲库中未找到足够接近的歌曲"
            ),
            MatchResult(
                importedSong: songs[3],
                matchedTrack: fuzzy,
                alternatives: [],
                status: .fuzzy,
                score: 0.88,
                reason: "歌名相近，请核对版本"
            ),
            MatchResult(
                importedSong: songs[4],
                matchedTrack: nil,
                alternatives: [exact],
                status: .alternative,
                score: 0.72,
                reason: "找到一首可明确采用的替代歌"
            )
        ]
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
        if ProcessInfo.processInfo.arguments.contains("-singreadySeedExternalCandidate") {
            externalCandidateTracks = [unmatchedBackup]
            externalCandidateStatus = "已保留 1 首公开备选"
        }
        statusMessage = "还有几首需要核对备选"
    }

    private func prepareNoReferenceInsightsState() async {
        let songs = [
            ImportedSong(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000211")!,
                title: "喜欢你",
                source: .plainText,
                confidence: 0.7
            ),
            ImportedSong(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000212")!,
                title: "冬天里",
                artist: "汪峰",
                source: .plainText,
                confidence: 0.6
            ),
            ImportedSong(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000213")!,
                title: "不存在的测试歌名",
                artist: "未知歌手",
                source: .plainText,
                confidence: 0.4
            )
        ]
        let playlist = ImportedPlaylist(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000210")!,
            source: .plainText,
            title: "暂无参考洞察歌单",
            songs: songs,
            parseConfidence: 0.6
        )
        try? await installStableDemoWorkflow(
            playlist: playlist,
            recommendationInputSource: .userImport
        )
        guard let identity = catalog.first(where: { $0.id == "t029" }),
              let alternative = catalog.first(where: { $0.id == "t001" }),
              let unmatchedBackup = catalog.first(where: { $0.id == "t003" }) else {
            await beginMatchingReviewedSongs(navigate: false)
            return
        }
        let preparedMatches = [
            MatchResult(
                importedSong: songs[0],
                matchedTrack: nil,
                alternatives: [identity],
                status: .fuzzy,
                confirmationState: .required,
                score: 1,
                reason: "找到同名歌曲，请确认歌手"
            ),
            MatchResult(
                importedSong: songs[1],
                matchedTrack: nil,
                alternatives: [alternative],
                status: .alternative,
                score: 0.72,
                reason: "找到一首可明确采用的替代歌"
            ),
            MatchResult(
                importedSong: songs[2],
                matchedTrack: nil,
                alternatives: [unmatchedBackup],
                status: .unmatched,
                score: 0.2,
                reason: "本地参考曲库中未找到足够接近的歌曲"
            )
        ]
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
        statusMessage = "还没有足够的本地参考信息"
    }
}

enum DemoLaunchStage: String {
    case home
    case importHub
    case review
    case matchReport
    case voiceSetup
    case voiceResult
    case scenario
    case result
    case export
    case startTips

    init?(stage: WorkflowStage) {
        switch stage {
        case .home:
            self = .home
        case .importHub:
            self = .importHub
        case .review:
            self = .review
        case .matchReport:
            self = .matchReport
        case .voice:
            self = .voiceSetup
        case .scenario:
            self = .scenario
        case .result:
            self = .result
        case .export:
            self = .export
        case .startTips:
            self = .startTips
        }
    }

    static func fromProcessArguments() -> DemoLaunchStage? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-singreadyStage"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return DemoLaunchStage(rawValue: arguments[index + 1])
    }
}
#endif
