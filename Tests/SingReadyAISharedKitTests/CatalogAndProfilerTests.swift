import XCTest
@testable import SingReadyAISharedKit

final class CatalogAndProfilerTests: XCTestCase {
    func testDemoPlaylistIdentityIsStableAcrossLoads() throws {
        let coordinator = ImportCoordinator()

        let first = try coordinator.resolveDemoPlaylist()
        let second = try coordinator.resolveDemoPlaylist()

        XCTAssertEqual(first.id, second.id)
    }

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
        XCTAssertTrue(profile.hasReferenceInsights)
        XCTAssertGreaterThan(profile.ktvMatchRate, 0.5)
        XCTAssertGreaterThan(profile.averageDifficulty, 0)
        XCTAssertGreaterThan(profile.chorusFriendliness, 0)
        XCTAssertEqual(Set(profile.scenarioFitScores.keys), Set(KTVScenario.allCases.map(\.rawValue)))
        XCTAssertFalse(profile.profileTags.isEmpty)
        XCTAssertTrue(profile.summary.contains("先用大家熟的歌"))
        XCTAssertFalse(profile.summary.contains("旋律熟"))
        XCTAssertFalse(profile.summary.contains("出现较多"))
        XCTAssertFalse(profile.profileTags.contains("旋律熟"))
    }

    func testProfilerReturnsNeutralEmptyProfileWithoutUsableReferenceMatches() throws {
        let track = try XCTUnwrap(try KTVCatalogRepository().loadTracks().first)
        let pendingSong = ImportedSong(
            title: track.title,
            source: .plainText,
            confidence: 0.9
        )
        let pendingPlaylist = ImportedPlaylist(
            source: .plainText,
            title: "待确认歌单",
            songs: [pendingSong],
            parseConfidence: 0.9
        )
        let pendingMatch = SongMatcher().match(song: pendingSong, catalog: [track])

        let unmatchedSong = ImportedSong(
            title: "不存在的测试歌名",
            artist: "测试歌手",
            source: .plainText,
            confidence: 0.9
        )
        let unmatchedPlaylist = ImportedPlaylist(
            source: .plainText,
            title: "未命中歌单",
            songs: [unmatchedSong],
            parseConfidence: 0.9
        )
        let unmatchedMatch = MatchResult(
            importedSong: unmatchedSong,
            matchedTrack: nil,
            alternatives: [],
            status: .unmatched,
            score: 0,
            reason: "本地参考曲库中未找到足够接近的歌曲"
        )

        let cases = [
            (name: "pending", playlist: pendingPlaylist, matches: [pendingMatch]),
            (name: "unmatched", playlist: unmatchedPlaylist, matches: [unmatchedMatch])
        ]
        for testCase in cases {
            let profile = PreferenceProfiler().buildProfile(
                importedPlaylist: testCase.playlist,
                matches: testCase.matches
            )

            XCTAssertTrue(profile.languageDistribution.isEmpty, testCase.name)
            XCTAssertTrue(profile.eraDistribution.isEmpty, testCase.name)
            XCTAssertTrue(profile.genreDistribution.isEmpty, testCase.name)
            XCTAssertTrue(profile.moodTags.isEmpty, testCase.name)
            XCTAssertTrue(profile.sceneAffinity.isEmpty, testCase.name)
            XCTAssertTrue(profile.scenarioFitScores.isEmpty, testCase.name)
            XCTAssertTrue(profile.profileTags.isEmpty, testCase.name)
            XCTAssertFalse(profile.hasReferenceInsights, testCase.name)
            XCTAssertEqual(profile.ktvMatchRate, 0, testCase.name)
            XCTAssertEqual(profile.averageDifficulty, 0, testCase.name)
            XCTAssertEqual(profile.averageSingAlongScore, 0, testCase.name)
            XCTAssertEqual(profile.highNoteRisk, 0, testCase.name)
            XCTAssertEqual(profile.chorusFriendliness, 0, testCase.name)
            XCTAssertEqual(
                profile.summary,
                "还没有可用的本地参考匹配，先逐首核对待确认和未命中歌曲。",
                testCase.name
            )
        }
    }
}
