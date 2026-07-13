import XCTest
@testable import SingReadyAISharedKit

final class RecommendationEngineTests: XCTestCase {
    func testGeneratesSegmentedPlanWithReasonsAndRisks() throws {
        let fixture = try makeFixture()
        let scenario = ScenarioConfig(
            scenario: .friends,
            peopleCount: 5,
            durationMinutes: 60,
            vibe: .balanced,
            chorusPreference: .moreChorus,
            difficultyPreference: .balanced
        )

        let plan = fixture.engine.generatePlan(
            matches: fixture.matches,
            preferenceProfile: fixture.profile,
            voiceProfile: .simulatedMiddle,
            scenario: scenario,
            catalog: fixture.catalog
        )

        XCTAssertEqual(plan.sections.count, KTVScenario.friends.sectionTemplates.count)
        XCTAssertGreaterThan(plan.sections.flatMap(\.items).count, 6)
        XCTAssertTrue(plan.sections.flatMap(\.items).allSatisfy { !$0.reasons.isEmpty })
        XCTAssertFalse(plan.sections.first?.items.first?.track.difficulty == 5)
        XCTAssertTrue(plan.sections.flatMap(\.items).allSatisfy { $0.scoreBreakdown.finalScore > 0 })
        XCTAssertEqual(plan.scenarioConfig?.peopleCount, 5)
        XCTAssertEqual(plan.voiceProfile?.type, .unknown)
        XCTAssertEqual(plan.voiceProfile?.source, .commonReference)
    }

    func testCarKTVReducesDifficultSongs() throws {
        let fixture = try makeFixture(useQQPlaylist: true)
        let scenario = ScenarioConfig(scenario: .carKTV, durationMinutes: 45, difficultyPreference: .easy)

        let plan = fixture.engine.generatePlan(
            matches: fixture.matches,
            preferenceProfile: fixture.profile,
            voiceProfile: .simulatedMiddle,
            scenario: scenario,
            catalog: fixture.catalog
        )

        let difficultCount = plan.sections.flatMap(\.items).filter { $0.track.difficulty >= 5 }.count
        XCTAssertEqual(difficultCount, 0)
        XCTAssertTrue(plan.sections.flatMap(\.items).allSatisfy { $0.track.rapDensity < 0.75 })
    }

    func testAllScenariosUseExpectedSectionTemplates() throws {
        let fixture = try makeFixture()

        for scenario in KTVScenario.allCases {
            let config = ScenarioConfig(scenario: scenario, durationMinutes: 75)
            let plan = fixture.engine.generatePlan(
                matches: fixture.matches,
                preferenceProfile: fixture.profile,
                voiceProfile: .simulatedMiddle,
                scenario: config,
                catalog: fixture.catalog
            )

            XCTAssertEqual(plan.sections.map(\.title), scenario.sectionTemplates.map(\.title), scenario.rawValue)
            XCTAssertGreaterThan(plan.sections.flatMap(\.items).count, 0, scenario.rawValue)
        }
    }

    func testBirthdayPlanContainsBlessingOrChorusSong() throws {
        let fixture = try makeFixture()
        let plan = fixture.engine.generatePlan(
            matches: fixture.matches,
            preferenceProfile: fixture.profile,
            voiceProfile: .simulatedMiddle,
            scenario: ScenarioConfig(scenario: .birthday, durationMinutes: 90, vibe: .chorus),
            catalog: fixture.catalog
        )

        XCTAssertTrue(plan.sections.flatMap(\.items).contains { item in
            item.track.sceneTags.contains("birthday")
                || item.track.moodTags.contains("温暖")
                || item.track.moodTags.contains("甜蜜")
                || item.track.singAlongScore >= 0.86
        })
    }

    func testGroupScenarioKeepsEnoughChorusFriendlySongs() throws {
        let fixture = try makeFixture()
        let plan = fixture.engine.generatePlan(
            matches: fixture.matches,
            preferenceProfile: fixture.profile,
            voiceProfile: .simulatedMiddle,
            scenario: ScenarioConfig(scenario: .teamBuilding, durationMinutes: 90, chorusPreference: .moreChorus),
            catalog: fixture.catalog
        )

        let items = plan.sections.flatMap(\.items)
        let chorusCount = items.filter { $0.track.singAlongScore >= 0.78 || $0.track.duetFriendly }.count
        XCTAssertGreaterThanOrEqual(Double(chorusCount) / Double(max(items.count, 1)), 0.3)
    }

    func testCanLockAndRemoveTracksBeforeRegenerating() throws {
        let fixture = try makeFixture()
        let lockedID = "t001"
        let removedID = "t002"

        let plan = fixture.engine.generatePlan(
            matches: fixture.matches,
            preferenceProfile: fixture.profile,
            voiceProfile: .simulatedMiddle,
            scenario: ScenarioConfig(scenario: .friends, durationMinutes: 90),
            catalog: fixture.catalog,
            lockedTrackIDs: [lockedID],
            removedTrackIDs: [removedID]
        )

        let items = plan.sections.flatMap(\.items)
        XCTAssertTrue(items.contains { $0.track.id == lockedID && $0.isLocked })
        XCTAssertFalse(items.contains { $0.track.id == removedID })
    }

    func testRecommendationAvoidsSameArtistBackToBackWhenPossible() throws {
        let fixture = try makeFixture()
        let plan = fixture.engine.generatePlan(
            matches: fixture.matches,
            preferenceProfile: fixture.profile,
            voiceProfile: .simulatedMiddle,
            scenario: ScenarioConfig(scenario: .friends, durationMinutes: 120),
            catalog: fixture.catalog
        )

        let artists = plan.sections.flatMap(\.items).map(\.track.artist)
        for pair in zip(artists, artists.dropFirst()) {
            XCTAssertNotEqual(pair.0, pair.1)
        }
    }

    func testScoreBreakdownFieldsAreExplainable() throws {
        let fixture = try makeFixture()
        let plan = fixture.engine.generatePlan(
            matches: fixture.matches,
            preferenceProfile: fixture.profile,
            voiceProfile: .simulatedMiddle,
            scenario: ScenarioConfig(scenario: .couples, durationMinutes: 60, vibe: .spotlight, difficultyPreference: .showcase),
            catalog: fixture.catalog
        )

        let item = try XCTUnwrap(plan.sections.flatMap(\.items).first)
        XCTAssertGreaterThanOrEqual(item.scoreBreakdown.preferenceAffinity, 0)
        XCTAssertGreaterThan(item.scoreBreakdown.ktvAvailabilityScore, 0)
        XCTAssertGreaterThan(item.scoreBreakdown.vocalFitScore, 0)
        XCTAssertGreaterThan(item.scoreBreakdown.sceneFitScore, 0)
        XCTAssertEqual(item.score, item.scoreBreakdown.finalScore, accuracy: 0.0001)
    }

    func testLockedTrackWinsEvenWhenAlsoRemoved() throws {
        let fixture = try makeFixture()
        let plan = makePlan(fixture: fixture, scenario: .friends, locked: ["t001"], removed: ["t001"])

        XCTAssertTrue(plan.sections.flatMap(\.items).contains { $0.track.id == "t001" && $0.isLocked })
    }

    func testRemovedTrackDoesNotAppear() throws {
        let fixture = try makeFixture()
        let plan = makePlan(fixture: fixture, scenario: .friends, removed: ["t002"])

        XCTAssertFalse(plan.sections.flatMap(\.items).contains { $0.track.id == "t002" })
    }

    func testPlanCarriesScenarioSummaryAndVoiceProfile() throws {
        let fixture = try makeFixture()
        let plan = makePlan(fixture: fixture, scenario: .birthday)

        XCTAssertEqual(plan.scenario, .birthday)
        XCTAssertEqual(plan.voiceProfile?.type, .unknown)
        XCTAssertEqual(plan.voiceProfile?.source, .commonReference)
        XCTAssertNotNil(plan.preferenceSummary)
    }

    func testPlanSummaryUsesSelectedScenarioInsteadOfProfileBestScenario() throws {
        let fixture = try makeFixture()
        let friendsPlan = makePlan(fixture: fixture, scenario: .friends)
        let carPlan = makePlan(fixture: fixture, scenario: .carKTV)

        XCTAssertTrue(friendsPlan.preferenceSummary?.contains("朋友局") == true)
        XCTAssertFalse(friendsPlan.preferenceSummary?.contains("车载 K 歌") == true)
        XCTAssertTrue(carPlan.preferenceSummary?.contains("车里") == true)
    }

    func testEverySectionHasGoalAndItems() throws {
        let fixture = try makeFixture()
        let plan = makePlan(fixture: fixture, scenario: .friends)

        XCTAssertTrue(plan.sections.allSatisfy { !$0.goal.isEmpty })
        XCTAssertTrue(plan.sections.allSatisfy { !$0.items.isEmpty })
    }

    func testNoDuplicateTracksInPlan() throws {
        let fixture = try makeFixture()
        let plan = makePlan(fixture: fixture, scenario: .friends, duration: 120)
        let ids = plan.sections.flatMap(\.items).map(\.track.id)

        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testAlternativesExcludeCurrentTrack() throws {
        let fixture = try makeFixture()
        let plan = makePlan(fixture: fixture, scenario: .friends)

        for item in plan.sections.flatMap(\.items) {
            XCTAssertFalse(item.alternatives.contains { $0.id == item.track.id })
        }
    }

    func testFinalScoresAreBounded() throws {
        let fixture = try makeFixture()
        let plan = makePlan(fixture: fixture, scenario: .teamBuilding)

        XCTAssertTrue(plan.sections.flatMap(\.items).allSatisfy { (0...1).contains($0.score) })
        XCTAssertTrue(plan.sections.flatMap(\.items).allSatisfy { (0...1).contains($0.scoreBreakdown.finalScore) })
    }

    func testLongerDurationProducesAtLeastAsManyItems() throws {
        let fixture = try makeFixture()
        let shortPlan = makePlan(fixture: fixture, scenario: .friends, duration: 45)
        let longPlan = makePlan(fixture: fixture, scenario: .friends, duration: 120)

        XCTAssertGreaterThanOrEqual(longPlan.sections.flatMap(\.items).count, shortPlan.sections.flatMap(\.items).count)
    }

    func testCouplesPlanContainsSweetOrDuetFriendlySong() throws {
        let fixture = try makeFixture()
        let plan = makePlan(fixture: fixture, scenario: .couples, vibe: .emotional)

        XCTAssertTrue(plan.sections.flatMap(\.items).contains { $0.track.duetFriendly || $0.track.genre == "甜歌" || $0.track.moodTags.contains("甜蜜") })
    }

    func testSoloPracticeUsesPracticeSections() throws {
        let fixture = try makeFixture()
        let plan = makePlan(fixture: fixture, scenario: .soloPractice)

        XCTAssertEqual(plan.sections.map(\.title), KTVScenario.soloPractice.sectionTemplates.map(\.title))
        XCTAssertTrue(plan.sections.flatMap(\.items).allSatisfy { $0.track.highNoteRisk <= 0.9 })
    }

    func testTeamBuildingKeepsAverageDifficultyModerate() throws {
        let fixture = try makeFixture()
        let plan = makePlan(fixture: fixture, scenario: .teamBuilding, difficulty: .easy)
        let difficulties = plan.sections.flatMap(\.items).map { Double($0.track.difficulty) }

        XCTAssertLessThanOrEqual(average(difficulties), 4.0)
    }

    func testCarKTVKeepsAverageRapDensityLow() throws {
        let fixture = try makeFixture(useQQPlaylist: true)
        let plan = makePlan(fixture: fixture, scenario: .carKTV, difficulty: .easy)
        let rapDensity = plan.sections.flatMap(\.items).map(\.track.rapDensity)

        XCTAssertLessThan(average(rapDensity), 0.45)
    }

    func testEasyPreferenceAvoidsHighRiskOpeners() throws {
        let fixture = try makeFixture()
        let plan = makePlan(fixture: fixture, scenario: .friends, difficulty: .easy)
        let first = try XCTUnwrap(plan.sections.first?.items.first)

        XCTAssertLessThan(first.track.highNoteRisk, 0.72)
        XCTAssertLessThan(first.track.difficulty, 5)
    }

    func testShowcasePreferenceCanStillProduceHighScoringItems() throws {
        let fixture = try makeFixture()
        let plan = makePlan(fixture: fixture, scenario: .friends, vibe: .spotlight, difficulty: .showcase)

        XCTAssertTrue(plan.sections.flatMap(\.items).contains { $0.score >= 0.55 })
    }

    func testLowVoiceProfileProducesRiskWarnings() throws {
        let fixture = try makeFixture()
        let lowVoice = VoiceProfile(
            type: .lowMale,
            minMidi: 43,
            maxMidi: 60,
            stableLowMidi: 45,
            stableHighMidi: 55,
            averageMidi: 50,
            confidence: 0.8,
            note: "测试声线"
        )
        let plan = fixture.engine.generatePlan(
            matches: fixture.matches,
            preferenceProfile: fixture.profile,
            voiceProfile: lowVoice,
            scenario: ScenarioConfig(scenario: .friends, durationMinutes: 90),
            catalog: fixture.catalog
        )

        XCTAssertTrue(plan.sections.flatMap(\.items).contains { !$0.riskWarnings.isEmpty })
    }

    func testMoreChorusPreferenceHasChorusFriendlyItems() throws {
        let fixture = try makeFixture()
        let plan = makePlan(fixture: fixture, scenario: .friends, chorus: .moreChorus)

        XCTAssertTrue(plan.sections.flatMap(\.items).contains { $0.track.singAlongScore >= 0.84 || $0.track.duetFriendly })
    }

    func testQQPlaylistStillGeneratesExplainablePlan() throws {
        let fixture = try makeFixture(useQQPlaylist: true)
        let plan = makePlan(fixture: fixture, scenario: .carKTV)

        XCTAssertGreaterThan(plan.sections.flatMap(\.items).count, 0)
        XCTAssertTrue(plan.sections.flatMap(\.items).allSatisfy { !$0.reasons.isEmpty })
    }

    func testBirthdayPlanTitleIsLocalized() throws {
        let fixture = try makeFixture()
        let plan = makePlan(fixture: fixture, scenario: .birthday)

        XCTAssertEqual(plan.title, "生日局歌单")
    }

    func testScoreBreakdownIncludesRiskPenaltyForEveryItem() throws {
        let fixture = try makeFixture()
        let plan = makePlan(fixture: fixture, scenario: .friends)

        XCTAssertTrue(plan.sections.flatMap(\.items).allSatisfy { $0.scoreBreakdown.riskPenalty >= 0 })
    }

    func test真实曲库高负载推荐中位耗时不超过一秒() throws {
        let fixture = try makePerformanceFixture()
        XCTAssertGreaterThanOrEqual(
            fixture.catalog.count - fixture.externalCandidateCount,
            200,
            "性能门槛应覆盖完整真实曲库规模"
        )
        XCTAssertEqual(fixture.matches.count, 90, "性能门槛应覆盖 90 条匹配输入")
        XCTAssertEqual(fixture.externalCandidateCount, 16, "性能门槛应覆盖外部候选上限")
        for _ in 0..<3 {
            _ = generatePerformancePlan(fixture)
        }

        var elapsedSeconds: [Double] = []
        var outputCounts: [Int] = []
        for _ in 0..<7 {
            let start = DispatchTime.now().uptimeNanoseconds
            let plan = generatePerformancePlan(fixture)
            let end = DispatchTime.now().uptimeNanoseconds
            elapsedSeconds.append(Double(end - start) / 1_000_000_000)
            outputCounts.append(plan.sections.flatMap(\.items).count)
        }

        let sortedSeconds = elapsedSeconds.sorted()
        let medianSeconds = sortedSeconds[sortedSeconds.count / 2]
        let maximumSeconds = try XCTUnwrap(sortedSeconds.last)
        print(
            String(
                format: "推荐性能采样：真实曲库 %d 首，匹配 %d 条，外部候选 %d 首，中位 %.4f 秒，最大 %.4f 秒",
                fixture.catalog.count - fixture.externalCandidateCount,
                fixture.matches.count,
                fixture.externalCandidateCount,
                medianSeconds,
                maximumSeconds
            )
        )
        XCTAssertEqual(Set(outputCounts), [30], "180 分钟上限场景应稳定产出 30 首排歌")
        XCTAssertLessThan(
            medianSeconds,
            1,
            String(
                format: "真实曲库高负载推荐的 7 次采样中位耗时应小于 1 秒，当前为 %.4f 秒",
                medianSeconds
            )
        )
    }

    private func makeFixture(useQQPlaylist: Bool = false) throws -> Fixture {
        let catalog = try KTVCatalogRepository().loadTracks()
        let playlist = useQQPlaylist
            ? try FixturePlaylistLoader.loadPlaylist(named: "fixtures_qqmusic_playlist", fallbackSource: .qqMusic)
            : try ImportCoordinator().resolveDemoPlaylist()
        let matches = SongMatcher().match(playlist: playlist, catalog: catalog)
        let profile = PreferenceProfiler().buildProfile(importedPlaylist: playlist, matches: matches)
        return Fixture(catalog: catalog, playlist: playlist, matches: matches, profile: profile, engine: RecommendationEngine())
    }

    private func makePlan(
        fixture: Fixture,
        scenario: KTVScenario,
        duration: Int = 75,
        vibe: PlaylistVibe = .balanced,
        chorus: ChorusPreference = .balanced,
        difficulty: DifficultyPreference = .balanced,
        locked: Set<String> = [],
        removed: Set<String> = []
    ) -> SongPlan {
        fixture.engine.generatePlan(
            matches: fixture.matches,
            preferenceProfile: fixture.profile,
            voiceProfile: .simulatedMiddle,
            scenario: ScenarioConfig(
                scenario: scenario,
                durationMinutes: duration,
                vibe: vibe,
                chorusPreference: chorus,
                difficultyPreference: difficulty
            ),
            catalog: fixture.catalog,
            lockedTrackIDs: locked,
            removedTrackIDs: removed
        )
    }

    private func makePerformanceFixture() throws -> RecommendationPerformanceFixture {
        let realCatalog = try KTVCatalogRepository().loadTracks()
        let matchedTracks = Array(realCatalog.prefix(90))
        let songs = matchedTracks.map { track in
            ImportedSong(
                title: track.title,
                artist: track.artist,
                source: .plainText,
                confidence: 1
            )
        }
        let matches = zip(songs.indices, songs).map { index, song in
            MatchResult(
                importedSong: song,
                matchedTrack: matchedTracks[index],
                alternatives: [
                    realCatalog[(index + 1) % realCatalog.count],
                    realCatalog[(index + 2) % realCatalog.count]
                ],
                status: .exact,
                score: 1,
                reason: "真实曲库精确命中"
            )
        }
        let playlist = ImportedPlaylist(
            source: .plainText,
            title: "性能预算歌单",
            songs: songs,
            parseConfidence: 1
        )
        let profile = PreferenceProfiler().buildProfile(
            importedPlaylist: playlist,
            matches: matches
        )
        let externalCandidateCount = 16
        let externalCandidates = (0..<externalCandidateCount).map { index in
            makePerformanceExternalCandidate(
                basedOn: realCatalog[index % realCatalog.count],
                index: index
            )
        }

        return RecommendationPerformanceFixture(
            engine: RecommendationEngine(),
            matches: matches,
            profile: profile,
            scenario: ScenarioConfig(
                scenario: .friends,
                peopleCount: 20,
                durationMinutes: 180,
                vibe: .balanced,
                chorusPreference: .moreChorus,
                difficultyPreference: .balanced
            ),
            catalog: realCatalog + externalCandidates,
            lockedTrackIDs: Set(matchedTracks.prefix(30).map(\.id)),
            externalCandidateCount: externalCandidateCount
        )
    }

    private func generatePerformancePlan(
        _ fixture: RecommendationPerformanceFixture
    ) -> SongPlan {
        fixture.engine.generatePlan(
            matches: fixture.matches,
            preferenceProfile: fixture.profile,
            voiceProfile: .simulatedMiddle,
            scenario: fixture.scenario,
            catalog: fixture.catalog,
            inputSource: .userImport,
            lockedTrackIDs: fixture.lockedTrackIDs
        )
    }

    private func makePerformanceExternalCandidate(
        basedOn track: KTVTrack,
        index: Int
    ) -> KTVTrack {
        KTVTrack(
            id: "performance-external-\(index)",
            title: "公开候选 \(index) \(track.title)",
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
            aliases: [],
            similarSongIds: [],
            externalURL: URL(string: "https://music.apple.com/cn/song/\(index)"),
            catalogSource: .externalSimilar,
            confidenceNote: "公开候选，现场数据待核对",
            externalCandidateMetadata: ExternalCandidateMetadata(
                relation: .similarTrack,
                relevance: 0.9,
                reasons: ["公开相似曲目"],
                provider: .iTunes
            )
        )
    }

    private func average(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(max(values.count, 1))
    }

    private struct Fixture {
        let catalog: [KTVTrack]
        let playlist: ImportedPlaylist
        let matches: [MatchResult]
        let profile: PreferenceProfile
        let engine: RecommendationEngine
    }

    private struct RecommendationPerformanceFixture {
        let engine: RecommendationEngine
        let matches: [MatchResult]
        let profile: PreferenceProfile
        let scenario: ScenarioConfig
        let catalog: [KTVTrack]
        let lockedTrackIDs: Set<String>
        let externalCandidateCount: Int
    }
}
