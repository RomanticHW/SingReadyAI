import XCTest
@testable import SingReadyAISharedKit

final class ExporterAndNormalizerTests: XCTestCase {
    func testTextJSONAndPosterExportIncludeInterviewDemoContext() throws {
        let plan = try makePlan()

        let text = PlaylistTextExporter().export(plan: plan)
        let json = try PlaylistJSONExporter().export(plan: plan)
        let poster = PosterRenderer().summary(for: plan)

        XCTAssertTrue(text.contains("今晚唱什么"))
        XCTAssertTrue(text.contains("推荐理由"))
        XCTAssertTrue(text.contains("替代建议"))
        XCTAssertTrue(json.contains("scoreBreakdown"))
        XCTAssertTrue(json.contains("voiceProfile"))
        XCTAssertTrue(json.contains("scenarioConfig"))
        XCTAssertEqual(poster.title, "今晚唱什么")
        XCTAssertGreaterThanOrEqual(poster.highlights.count, 5)
        XCTAssertLessThanOrEqual(poster.highlights.count, 10)
    }

    func testSongNormalizerCleansVersionsAndAvoidsShortSubstringOvermatch() {
        XCTAssertEqual(SongNormalizer.normalizeTitle("晴天 (Live 版)"), "晴天")
        XCTAssertEqual(SongNormalizer.normalizeTitle("告白氣球"), "告白气球")
        XCTAssertGreaterThan(SongNormalizer.similarity("蓝莲花新版", "蓝莲花"), 0.7)
        XCTAssertLessThan(SongNormalizer.similarity("不存在的测试歌名", "存在"), 0.45)
    }

    private func makePlan() throws -> SongPlan {
        let catalog = try KTVCatalogRepository().loadTracks()
        let playlist = try ImportCoordinator().resolveDemoPlaylist()
        let matches = SongMatcher().match(playlist: playlist, catalog: catalog)
        let profile = PreferenceProfiler().buildProfile(importedPlaylist: playlist, matches: matches)
        return RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: profile,
            voiceProfile: .simulatedMiddle,
            scenario: ScenarioConfig(scenario: .friends, durationMinutes: 120),
            catalog: catalog
        )
    }
}
