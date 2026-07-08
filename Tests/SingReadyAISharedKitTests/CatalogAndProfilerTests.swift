import XCTest
@testable import SingReadyAISharedKit

final class CatalogAndProfilerTests: XCTestCase {
    func testCatalogHasPortfolioScaleCompleteMetadata() throws {
        let catalog = try KTVCatalogRepository().loadTracks()

        XCTAssertGreaterThanOrEqual(catalog.count, 180)
        XCTAssertEqual(Set(catalog.map(\.id)).count, catalog.count)
        XCTAssertTrue(catalog.allSatisfy { !$0.title.isEmpty && !$0.artist.isEmpty })
        XCTAssertTrue(catalog.allSatisfy { !$0.language.isEmpty && !$0.era.isEmpty && !$0.genre.isEmpty })
        XCTAssertTrue(catalog.allSatisfy { !$0.moodTags.isEmpty && !$0.sceneTags.isEmpty })
        XCTAssertTrue(catalog.allSatisfy { (1...5).contains($0.difficulty) })
        XCTAssertTrue(catalog.allSatisfy { $0.vocalRangeLowMidi < $0.vocalRangeHighMidi })
        XCTAssertTrue(catalog.allSatisfy { (0...1).contains($0.energy) })
        XCTAssertTrue(catalog.allSatisfy { (0...1).contains($0.singAlongScore) })
        XCTAssertTrue(catalog.allSatisfy { (0...1).contains($0.ktvAvailability) })
        XCTAssertTrue(catalog.allSatisfy { (0...1).contains($0.rapDensity) })
        XCTAssertTrue(catalog.allSatisfy { (0...1).contains($0.highNoteRisk) })
    }

    func testPreferenceProfilerBuildsInsightfulProfile() throws {
        let catalog = try KTVCatalogRepository().loadTracks()
        let playlist = try ImportCoordinator().resolveDemoPlaylist()
        let matches = SongMatcher().match(playlist: playlist, catalog: catalog)

        let profile = PreferenceProfiler().buildProfile(importedPlaylist: playlist, matches: matches)

        XCTAssertLessThanOrEqual(profile.topArtists.count, 5)
        XCTAssertFalse(profile.languageDistribution.isEmpty)
        XCTAssertFalse(profile.eraDistribution.isEmpty)
        XCTAssertFalse(profile.genreDistribution.isEmpty)
        XCTAssertFalse(profile.moodTags.isEmpty)
        XCTAssertGreaterThan(profile.ktvMatchRate, 0.5)
        XCTAssertGreaterThan(profile.averageDifficulty, 0)
        XCTAssertGreaterThan(profile.chorusFriendliness, 0)
        XCTAssertEqual(Set(profile.scenarioFitScores.keys), Set(KTVScenario.allCases.map(\.rawValue)))
        XCTAssertFalse(profile.profileTags.isEmpty)
        XCTAssertTrue(profile.summary.contains("适合"))
    }
}
