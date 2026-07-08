import XCTest
@testable import SingReadyAISharedKit

final class SongMatcherTests: XCTestCase {
    func testExactAliasAndArtistAliasMatchesAgainstCatalog() throws {
        let catalog = try KTVCatalogRepository().loadTracks()
        let matcher = SongMatcher()
        let cases: [(title: String, artist: String?, expected: String)] = [
            ("晴天", "周杰伦", "晴天"),
            ("晴天 Live", "Jay Chou", "晴天"),
            ("K 歌之王", "陈奕迅", "K歌之王"),
            ("十年", "Eason", "十年"),
            ("告白气球 伴奏", "周杰伦", "告白气球"),
            ("恋爱 ING", "五月天", "恋爱ing"),
            ("海阔天空", "Beyond", "海阔天空"),
            ("月半小夜曲", "李克勤", "月半小夜曲"),
            ("爱的就是你", "王力宏", "爱的就是你"),
            ("大鱼", "周深", "大鱼"),
            ("说谎", "林宥嘉", "说谎"),
            ("王妃", "萧敬腾", "王妃"),
            ("飞得更高", "汪峰", "飞得更高"),
            ("蓝莲花", "许巍", "蓝莲花"),
            ("追", "张国荣", "追"),
            ("朋友", "周华健", "朋友"),
            ("夜空中最亮的星", "逃跑计划", "夜空中最亮的星"),
            ("云烟成雨", "房东的猫", "云烟成雨"),
            ("画心", "张靓颖", "画心"),
            ("给我一个理由忘记", "A-Lin", "给我一个理由忘记"),
            ("好久不见", "陈奕迅", "好久不见"),
            ("童话", "光良", "童话"),
            ("小情歌", "苏打绿", "小情歌"),
            ("双截棍", "周杰伦", "双截棍"),
            ("快乐崇拜", "潘玮柏", "快乐崇拜")
        ]

        for testCase in cases {
            let result = matcher.match(
                song: ImportedSong(title: testCase.title, artist: testCase.artist, source: .plainText, confidence: 0.9),
                catalog: catalog
            )
            XCTAssertTrue([MatchStatus.exact, .fuzzy].contains(result.status), testCase.title)
            XCTAssertEqual(result.matchedTrack?.title, testCase.expected, testCase.title)
            XCTAssertFalse(result.reason.isEmpty)
        }
    }

    func testUnmatchedSongStaysUnmatchedButOffersAlternatives() throws {
        let catalog = try KTVCatalogRepository().loadTracks()
        let result = SongMatcher().match(
            song: ImportedSong(title: "不存在的测试歌名", artist: "某歌手", source: .plainText, confidence: 0.4),
            catalog: catalog
        )

        XCTAssertEqual(result.status, .unmatched)
        XCTAssertNil(result.matchedTrack)
        XCTAssertEqual(result.alternatives.count, 3)
    }

    func testAlternativeMatchExplainsRecommendation() throws {
        let catalog = try KTVCatalogRepository().loadTracks()
        let result = SongMatcher().match(
            song: ImportedSong(title: "蓝莲花新版", artist: "许巍", source: .plainText, confidence: 0.7),
            catalog: catalog
        )

        XCTAssertTrue([MatchStatus.fuzzy, .alternative].contains(result.status))
        XCTAssertNotNil(result.matchedTrack)
        XCTAssertTrue(result.reason.contains("同歌手") || result.reason.contains("相似") || result.reason.contains("命中"))
        XCTAssertFalse(result.alternatives.isEmpty)
    }
}
