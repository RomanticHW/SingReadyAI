import XCTest
@testable import SingReadyAISharedKit

final class PlainTextPlaylistParserTests: XCTestCase {
    func testParsesAtLeastTwentyCommonPlaylistFormats() {
        let cases: [(line: String, title: String, artist: String?)] = [
            ("周杰伦 - 晴天", "晴天", "周杰伦"),
            ("晴天 - 周杰伦", "晴天", "周杰伦"),
            ("周杰伦《晴天》", "晴天", "周杰伦"),
            ("陈奕迅 / 十年", "十年", "陈奕迅"),
            ("十年 / 陈奕迅", "十年", "陈奕迅"),
            ("1. 五月天 - 突然好想你", "突然好想你", "五月天"),
            ("01 稻香 周杰伦", "稻香", "周杰伦"),
            ("歌名：告白气球 歌手：周杰伦", "告白气球", "周杰伦"),
            ("歌曲：小幸运 歌手：田馥甄", "小幸运", "田馥甄"),
            ("title: 遇见 artist: 孙燕姿", "遇见", "孙燕姿"),
            ("分享 周杰伦 的单曲 晴天", "晴天", "周杰伦"),
            ("陈奕迅<淘汰>", "淘汰", "陈奕迅"),
            ("Beyond - 海阔天空", "海阔天空", "Beyond"),
            ("张学友｜吻别", "吻别", "张学友"),
            ("刘德华—忘情水", "忘情水", "刘德华"),
            ("王菲–红豆", "红豆", "王菲"),
            ("梁静茹 / 勇气", "勇气", "梁静茹"),
            ("孙燕姿 绿光", "绿光", "孙燕姿"),
            ("五月天 恋爱ing", "恋爱ing", "五月天"),
            ("薛之谦 - 演员 (Live)", "演员", "薛之谦")
        ]

        let parser = PlainTextPlaylistParser()
        for testCase in cases {
            let song = parser.parseLine(testCase.line)
            XCTAssertEqual(song?.title, testCase.title, testCase.line)
            XCTAssertEqual(song?.artist, testCase.artist, testCase.line)
            XCTAssertGreaterThan(song?.confidence ?? 0, 0.6, testCase.line)
        }
    }

    func testKeepsLowConfidenceStandaloneSongLines() {
        let playlist = PlainTextPlaylistParser().parse(rawText: "后来\n打开 App 查看")

        XCTAssertEqual(playlist.songs.count, 1)
        XCTAssertEqual(playlist.songs.first?.title, "后来")
        XCTAssertLessThan(playlist.songs.first?.confidence ?? 1, 0.7)
    }

    func testDropsNoiseAndKeepsVersionTags() {
        let text = """
        分享自某音乐 App
        来自网易云音乐的歌单：华语怀旧
        QQ音乐歌单：KTV必点
        https://example.com/share
        播放全部
        收藏
        下载
        VIP
        周杰伦 - 晴天 (Live)
        陈奕迅 - 十年 DJ Remix
        """

        let songs = PlainTextPlaylistParser().parseSongs(text)

        XCTAssertEqual(songs.count, 2)
        XCTAssertEqual(songs.first?.title, "晴天")
        XCTAssertTrue(songs.first?.versionTags.contains("Live") == true)
        XCTAssertTrue(songs[1].versionTags.contains("DJ"))
        XCTAssertTrue(songs[1].versionTags.contains("Remix"))
        XCTAssertFalse(songs.contains { $0.rawText?.contains("http") == true })
    }
}
