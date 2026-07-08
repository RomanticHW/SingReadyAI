import XCTest
@testable import SingReadyAISharedKit

final class ShareProviderDetectorTests: XCTestCase {
    func testDetectsKnownMusicHosts() {
        let detector = ShareProviderDetector()

        XCTAssertEqual(detector.detect(urlString: "https://music.163.com/playlist?id=42").source, .netEaseMusic)
        XCTAssertEqual(detector.detect(urlString: "https://y.music.163.com/m/song?id=42").source, .netEaseMusic)
        XCTAssertEqual(detector.detect(urlString: "https://y.qq.com/n/ryqq/playlist/42").source, .qqMusic)
        XCTAssertEqual(detector.detect(urlString: "https://i.y.qq.com/v8/playsong.html?songid=42").source, .qqMusic)
        XCTAssertEqual(detector.detect(urlString: "https://music.apple.com/cn/playlist/demo").source, .appleMusic)
        XCTAssertEqual(detector.detect(urlString: "https://music.apple.com/us/album/demo").source, .appleMusic)
        XCTAssertEqual(detector.detect(urlString: "https://example.com/music/list").source, .genericURL)
    }

    func testDetectsPlainTextAndScreenshotPayloads() {
        let detector = ShareProviderDetector()

        let textPayload = PendingImportPayload(sourceHint: .unknown, rawText: "周杰伦 - 晴天\n陈奕迅《十年》")
        XCTAssertEqual(detector.detect(payload: textPayload).source, .plainText)

        let imagePayload = PendingImportPayload(sourceHint: .unknown, imageFileName: "share.png")
        XCTAssertEqual(detector.detect(payload: imagePayload).source, .screenshot)
    }

    func testDetectsProviderFromShareTextKeywords() {
        let detector = ShareProviderDetector()

        XCTAssertEqual(detector.detect(payload: PendingImportPayload(sourceHint: .unknown, rawText: "来自网易云音乐的歌单：https://music.163.com/playlist?id=1")).source, .netEaseMusic)
        XCTAssertEqual(detector.detect(payload: PendingImportPayload(sourceHint: .unknown, rawText: "QQ音乐歌单：KTV必点")).source, .qqMusic)
        XCTAssertEqual(detector.detect(payload: PendingImportPayload(sourceHint: .unknown, rawText: "Apple Music playlist")).source, .appleMusic)
        XCTAssertEqual(detector.detect(payload: PendingImportPayload(sourceHint: .unknown, rawText: "复制这段普通歌单文本\n周杰伦 - 晴天")).source, .plainText)
        XCTAssertEqual(detector.detect(payload: PendingImportPayload(sourceHint: .genericURL, urlString: "https://example.com/share")).source, .genericURL)
    }
}
