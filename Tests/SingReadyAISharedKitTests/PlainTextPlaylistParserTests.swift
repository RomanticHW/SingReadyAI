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
            ("薛之谦 - 演员 (Live)", "演员", "薛之谦"),
            ("林俊杰 - 江南", "江南", "林俊杰"),
            ("田馥甄｜小幸运", "小幸运", "田馥甄"),
            ("张惠妹—听海", "听海", "张惠妹"),
            ("邓紫棋 - 喜欢你", "喜欢你", "邓紫棋"),
            ("毛不易 消愁", "消愁", "毛不易"),
            ("许嵩《有何不可》", "有何不可", "许嵩"),
            ("A-Lin / 给我一个理由忘记", "给我一个理由忘记", "A-Lin"),
            ("S.H.E - Super Star", "Super Star", "S.H.E"),
            ("李荣浩《年少有为》", "年少有为", "李荣浩"),
            ("赵雷 - 成都 民谣版", "成都", "赵雷"),
            ("Beyond｜真的爱你", "真的爱你", "Beyond"),
            ("蔡依林 - 日不落", "日不落", "蔡依林")
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

    func testKeepsLegitimateLongClassicalTrackTitleFromAppleMusic() {
        let line = "Piano Sonata No. 14 in C-Sharp Minor, Op. 27 No. 2 \"Moonlight\": I. Adagio sostenuto - 默里・佩拉西亚"

        let song = PlainTextPlaylistParser().parseLine(line, source: .appleMusic)

        XCTAssertEqual(
            song?.title,
            "Piano Sonata No. 14 in C-Sharp Minor, Op. 27 No. 2 \"Moonlight\": I. Adagio sostenuto"
        )
        XCTAssertEqual(song?.artist, "默里・佩拉西亚")
        XCTAssertEqual(song?.source, .appleMusic)
    }

    func testDropsNoiseAndKeepsVersionTags() {
        let text = """
        分享自某音乐软件
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

    func testExtractsUnknownVersionFromParsedTitleInEitherDelimitedOrder() throws {
        let lines = [
            "后来 特别版 - 刘若英",
            "刘若英 - 后来 特别版"
        ]

        for line in lines {
            let song = try XCTUnwrap(PlainTextPlaylistParser().parseLine(line))
            let identity = SongVersionIdentity.parse(
                title: song.title,
                versionTags: song.versionTags
            )

            XCTAssertEqual(song.title, "后来", line)
            XCTAssertEqual(song.artist, "刘若英", line)
            XCTAssertEqual(song.versionTags, ["特别版"], line)
            XCTAssertEqual(identity.kinds, [.unknown], line)
        }
    }

    func testArtistNameDoesNotCreateVersionTags() throws {
        let song = try XCTUnwrap(
            PlainTextPlaylistParser().parseLine("歌名：Let Me Love You 歌手：DJ Snake")
        )

        XCTAssertEqual(song.title, "Let Me Love You")
        XCTAssertEqual(song.artist, "DJ Snake")
        XCTAssertTrue(song.versionTags.isEmpty)
    }

    func testDedupKeepsDistinctVersionIdentities() {
        let songs = PlainTextPlaylistParser().parseSongs(
            """
            刘若英 - 后来
            刘若英 - 后来 Live
            刘若英 - 后来 现场版
            刘若英 - 后来
            """
        )

        XCTAssertEqual(songs.count, 2)
        let identities = songs.map {
            SongVersionIdentity.parse(title: $0.title, versionTags: $0.versionTags)
        }
        XCTAssertTrue(identities.contains { !$0.hasExplicitMarker })
        XCTAssertTrue(identities.contains { $0.kinds == [.live] })
    }

    func testDedupKeepsDifferentUnknownVersionTags() {
        let songs = PlainTextPlaylistParser().parseSongs(
            """
            刘若英 - 后来 特别版
            刘若英 - 后来 民谣版
            """
        )

        XCTAssertEqual(songs.map(\.versionTags), [["特别版"], ["民谣版"]])
    }

    func testDedupRemovesOnlyRepeatedMatchingUnknownVersionTag() {
        let songs = PlainTextPlaylistParser().parseSongs(
            """
            刘若英 - 后来 特别版
            后来 特别版 - 刘若英
            刘若英 - 后来 民谣版
            """
        )

        XCTAssertEqual(songs.map(\.versionTags), [["特别版"], ["民谣版"]])
        XCTAssertEqual(songs.filter { $0.versionTags == ["特别版"] }.count, 1)
    }

    func testRejectsLabeledSongLineWhenTitleIsBlank() {
        let parser = PlainTextPlaylistParser()

        XCTAssertNil(parser.parseLine("歌名：    歌手：周杰伦"))
        XCTAssertNil(parser.parseLine("title:    artist: Jay Chou"))
    }

    func testValidatedOCRPlaylistRejectsRecognizedNoiseWithoutSongs() {
        XCTAssertThrowsError(
            try OCRPlaylistParser().parseValidated(
                recognizedText: "播放全部\n收藏\n下载"
            )
        ) { error in
            XCTAssertEqual(error as? OCRServiceError, .noTextRecognized)
        }
    }

    func testValidatedOCRPlaylistKeepsRecognizedSongsAndScreenshotSource() throws {
        let playlist = try OCRPlaylistParser().parseValidated(
            recognizedText: "周杰伦 - 晴天\n陈奕迅 - 十年",
            title: "分享截图"
        )

        XCTAssertEqual(playlist.title, "分享截图")
        XCTAssertEqual(playlist.source, .screenshot)
        XCTAssertEqual(playlist.songs.map(\.title), ["晴天", "十年"])
    }
}
