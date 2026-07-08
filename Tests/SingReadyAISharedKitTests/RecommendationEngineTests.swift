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
        XCTAssertEqual(plan.voiceProfile?.type, .midMale)
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

    private func makeFixture(useQQPlaylist: Bool = false) throws -> Fixture {
        let catalog = try KTVCatalogRepository().loadTracks()
        let playlist = useQQPlaylist
            ? try FixturePlaylistLoader.loadPlaylist(named: "fixtures_qqmusic_playlist", fallbackSource: .qqMusic)
            : try ImportCoordinator().resolveDemoPlaylist()
        let matches = SongMatcher().match(playlist: playlist, catalog: catalog)
        let profile = PreferenceProfiler().buildProfile(importedPlaylist: playlist, matches: matches)
        return Fixture(catalog: catalog, playlist: playlist, matches: matches, profile: profile, engine: RecommendationEngine())
    }

    private struct Fixture {
        let catalog: [KTVTrack]
        let playlist: ImportedPlaylist
        let matches: [MatchResult]
        let profile: PreferenceProfile
        let engine: RecommendationEngine
    }
}
