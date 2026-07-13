import XCTest
@testable import SingReadyAISharedKit

#if canImport(Network)
import Network
#endif

final class PlaylistResolverTests: XCTestCase {
    func testQQMusicPublicURLOnlyRequiresShareTextBeforeNetwork() async {
        let urlStrings = [
            "https://y.qq.com/n/ryqq/playlist/42",
            "https://i.y.qq.com/v8/playsong.html?songid=42",
            "https://c.y.qq.com/base/fcgi-bin/u?disstid=42",
            "https://qqmusic.qq.com/playlist/42",
            "https://share.i.y.qq.com/v8/playsong.html?songid=42",
            "https://sub.qqmusic.qq.com/playlist/42",
            "https://y.qq.com./n/ryqq/playlist/42",
            "https://share.i.y.qq.com./v8/playsong.html?songid=42"
        ]

        for urlString in urlStrings {
            let fetcher = UnexpectedPlaylistPageFetcher()
            let resolver = PublicWebPlaylistResolver(fetcher: fetcher)
            let payload = PendingImportPayload(sourceHint: .genericURL, urlString: urlString)

            do {
                _ = try await resolver.resolve(payload: payload)
                XCTFail("Expected QQ Music share-text guidance for \(urlString)")
            } catch let error as PlaylistResolveError {
                XCTAssertEqual(error, .qqMusicRequiresShareText)
                XCTAssertEqual(
                    error.errorDescription,
                    "QQ 音乐公开链接不能直接读取；请分享/粘贴歌名文字或发截图"
                )
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(fetcher.callCount, 0, "QQ Music URL must be handled before network access")
        }
    }

    func testQQMusicShareWithOnlyOneSongReturnsActionablePartialTextErrorBeforeNetwork() async {
        let fetcher = UnexpectedPlaylistPageFetcher()
        let resolver = PublicWebPlaylistResolver(fetcher: fetcher)
        let payload = PendingImportPayload(
            sourceHint: .qqMusic,
            rawText: "晴天 - 周杰伦",
            urlString: "https://y.qq.com/n/ryqq/playlist/42"
        )

        do {
            _ = try await resolver.resolve(payload: payload)
            XCTFail("Expected actionable guidance for a single retained QQ song")
        } catch let error as PlaylistResolveError {
            XCTAssertEqual(error, .qqMusicNeedsMoreSongText)
            XCTAssertEqual(
                error.errorDescription,
                "QQ 音乐分享内容里只识别到一首歌；请再粘贴至少一首歌名，或发截图"
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(fetcher.callCount, 0)
    }

    func testQQMusicPublicURLUsesTwoRetainedRawSongsBeforeNetwork() async throws {
        let urlStrings = [
            "https://y.qq.com/n/ryqq/playlist/42",
            "https://y.qq.com./n/ryqq/playlist/42",
            "https://share.i.y.qq.com./v8/playsong.html?songid=42"
        ]

        for urlString in urlStrings {
            let fetcher = UnexpectedPlaylistPageFetcher()
            let resolver = PublicWebPlaylistResolver(fetcher: fetcher)
            let payload = PendingImportPayload(
                sourceHint: .genericURL,
                rawText: """
                \(urlString)
                晴天 - 周杰伦
                后来 - 刘若英
                """,
                urlString: urlString,
                displayTitle: "QQ 分享歌单"
            )

            let playlist = try await resolver.resolve(payload: payload)

            XCTAssertEqual(playlist.source, .qqMusic)
            XCTAssertEqual(playlist.externalURL?.absoluteString, urlString)
            XCTAssertEqual(playlist.songs.map(\.title), ["晴天", "后来"])
            XCTAssertEqual(fetcher.callCount, 0)
        }
    }

    func testQQMusicURLOnlyRejectsLeadingDotHostBeforeNetwork() async {
        let fetcher = UnexpectedPlaylistPageFetcher()
        let resolver = PublicWebPlaylistResolver(fetcher: fetcher)
        let payload = PendingImportPayload(
            sourceHint: .qqMusic,
            urlString: "https://.y.qq.com/n/ryqq/playlist/42"
        )

        do {
            _ = try await resolver.resolve(payload: payload)
            XCTFail("Expected leading-dot host to be rejected")
        } catch let error as PlaylistResolveError {
            XCTAssertEqual(error, .invalidURL)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(fetcher.callCount, 0)
    }

    func testQQMusicRawTextShortcutRejectsUnsafeURLsBeforeNetwork() async {
        let unsafeURLStrings = [
            "https://user:password@y.qq.com/n/ryqq/playlist/42",
            "https://127.0.0.1/n/ryqq/playlist/42",
            "https://.y.qq.com/n/ryqq/playlist/42"
        ]

        for urlString in unsafeURLStrings {
            let fetcher = UnexpectedPlaylistPageFetcher()
            let resolver = PublicWebPlaylistResolver(fetcher: fetcher)
            let payload = PendingImportPayload(
                sourceHint: .qqMusic,
                rawText: "晴天 - 周杰伦\n后来 - 刘若英",
                urlString: urlString
            )

            do {
                _ = try await resolver.resolve(payload: payload)
                XCTFail("Expected URL policy rejection for \(urlString)")
            } catch let error as PlaylistResolveError {
                XCTAssertEqual(error, .invalidURL)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(fetcher.callCount, 0)
        }
    }

    func testQQMusicRawTextShortcutDoesNotTrustSourceHintOrLookalikeHost() async {
        let nonQQURLStrings = [
            "https://example.com/playlist/42",
            "https://y.qq.com.example.com/playlist/42"
        ]

        for urlString in nonQQURLStrings {
            let fetcher = UnexpectedPlaylistPageFetcher()
            let resolver = PublicWebPlaylistResolver(fetcher: fetcher)
            let payload = PendingImportPayload(
                sourceHint: .qqMusic,
                rawText: "晴天 - 周杰伦\n后来 - 刘若英",
                urlString: urlString
            )

            do {
                _ = try await resolver.resolve(payload: payload)
                XCTFail("Expected unsupported non-QQ host to be rejected: \(urlString)")
            } catch let error as PlaylistResolveError {
                XCTAssertEqual(error, .unsupportedPublicWebHost)
                XCTAssertEqual(
                    error.errorDescription,
                    "目前只直接读取 Apple Music 和网易云公开歌单；其他网页请粘贴歌名文字或发截图"
                )
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(fetcher.callCount, 0)
        }
    }

    func testProductionFetcherRejectsUnknownPublicHostBeforeTransport() async {
        let loader = CountingPlaylistPageDataLoader()
        let fetcher = URLSessionPlaylistPageFetcher(loader: loader)

        do {
            _ = try await fetcher.pageText(for: URL(string: "https://music.example.com/playlist")!)
            XCTFail("Expected an unsupported public host error")
        } catch let error as PlaylistResolveError {
            XCTAssertEqual(error, .unsupportedPublicWebHost)
            XCTAssertEqual(
                error.errorDescription,
                "目前只直接读取 Apple Music 和网易云公开歌单；其他网页请粘贴歌名文字或发截图"
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(loader.callCount, 0)
    }

    func testTrustedPlatformFetchUsesStubTransport() async throws {
        let url = URL(string: "https://music.apple.com/cn/playlist/example")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/plain; charset=utf-8"]
        )!
        let fetcher = URLSessionPlaylistPageFetcher(
            loader: StubPlaylistPageDataLoader(
                data: Data("一路向北 - 周杰伦".utf8),
                response: response
            )
        )

        let text = try await fetcher.pageText(for: url)

        XCTAssertEqual(text, "一路向北 - 周杰伦")
    }

    func testProductionFetcherRejectsRedirectOutsideSupportedMusicHosts() async {
        for redirectURLString in [
            "https://example.com/playlist",
            "https://127.0.0.1/private",
            "https://music.apple.com.example.com/playlist"
        ] {
            let delegate = BoundedPlaylistPageSessionDelegate(
                maximumBytes: 128,
                urlPolicy: PublicWebURLPolicy()
            )
            let session = URLSession(configuration: .ephemeral)
            let task = session.dataTask(with: URL(string: "https://music.apple.com/cn/playlist/example")!)
            let callback = expectation(description: "unsupported redirect rejected")
            var followedRequest: URLRequest?

            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: HTTPURLResponse(
                    url: task.originalRequest!.url!,
                    statusCode: 302,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                newRequest: URLRequest(url: URL(string: redirectURLString)!)
            ) { request in
                followedRequest = request
                callback.fulfill()
            }

            await fulfillment(of: [callback], timeout: 1)
            XCTAssertNil(followedRequest, redirectURLString)
            XCTAssertTrue([.canceling, .completed].contains(task.state), redirectURLString)
            session.invalidateAndCancel()
        }
    }

    func testDetectorAndResolverAgreeOnCanonicalSupportedHosts() async throws {
        let detector = ShareProviderDetector()
        let resolver = PublicWebPlaylistResolver(
            fetcher: StubPlaylistPageFetcher(text: "一路向北 - 周杰伦")
        )
        let cases: [(String, ImportSource)] = [
            ("https://MUSIC.APPLE.COM./cn/playlist/example", .appleMusic),
            ("https://share.music.163.com./playlist?id=42", .netEaseMusic)
        ]

        for (urlString, expectedSource) in cases {
            XCTAssertEqual(detector.detect(urlString: urlString).source, expectedSource)
            let playlist = try await resolver.resolve(
                payload: PendingImportPayload(sourceHint: .genericURL, urlString: urlString)
            )
            XCTAssertEqual(playlist.source, expectedSource)
        }
    }

    func testPublicPlaylistPageUsesItsOwnSongsInsteadOfDemoFixture() async throws {
        let fetcher = StubPlaylistPageFetcher(text: """
        公路旅行歌单
        一路向北 - 周杰伦
        旅行的意义 - 陈绮贞
        """)
        let resolver = PublicWebPlaylistResolver(fetcher: fetcher)
        let payload = PendingImportPayload(
            sourceHint: .netEaseMusic,
            urlString: "https://music.163.com/playlist?id=123",
            displayTitle: "分享链接"
        )

        let playlist = try await resolver.resolve(payload: payload)

        XCTAssertEqual(playlist.source, .netEaseMusic)
        XCTAssertEqual(playlist.songs.map(\.title), ["一路向北", "旅行的意义"])
        XCTAssertFalse(playlist.songs.contains { $0.title == "晴天" })
    }

    func testPublicPlaylistPageRejectsPagesWithoutSongs() async {
        let resolver = PublicWebPlaylistResolver(
            fetcher: StubPlaylistPageFetcher(text: "登录后查看歌单")
        )
        let payload = PendingImportPayload(
            sourceHint: .appleMusic,
            urlString: "https://music.apple.com/cn/playlist/example"
        )

        do {
            _ = try await resolver.resolve(payload: payload)
            XCTFail("Expected an actionable empty-page error")
        } catch let error as PlaylistResolveError {
            XCTAssertEqual(error, .webPageHasNoSongs)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCoordinatorTreatsPastedStandaloneURLAsLinkInsteadOfSongTitle() async throws {
        let coordinator = ImportCoordinator(resolvers: [
            PublicWebPlaylistResolver(fetcher: StubPlaylistPageFetcher(text: "一路向北 - 周杰伦")),
            PlainTextPlaylistResolver()
        ])
        let payload = PendingImportPayload(
            sourceHint: .plainText,
            rawText: "https://music.163.com/playlist?id=123",
            displayTitle: "粘贴导入歌单"
        )

        let playlist = try await coordinator.resolve(payload: payload)

        XCTAssertEqual(playlist.source, .netEaseMusic)
        XCTAssertEqual(playlist.externalURL?.absoluteString, "https://music.163.com/playlist?id=123")
        XCTAssertEqual(playlist.songs.map(\.title), ["一路向北"])
    }

    func testCoordinatorPromotesTheReportedNetEaseShareTextShortLink() async throws {
        let coordinator = ImportCoordinator(resolvers: [
            PublicWebPlaylistResolver(
                fetcher: StubPlaylistPageFetcher(text: "一路向北 - 周杰伦\n旅行的意义 - 陈绮贞")
            ),
            PlainTextPlaylistResolver()
        ])
        let payload = PendingImportPayload(
            sourceHint: .plainText,
            rawText: "分享歌单: 苏北Romantic喜欢的音乐 https://163cn.tv/baQqV8be (@网易云音乐)",
            displayTitle: "粘贴导入歌单"
        )

        let playlist = try await coordinator.resolve(payload: payload)

        XCTAssertEqual(playlist.source, .netEaseMusic)
        XCTAssertEqual(playlist.externalURL?.absoluteString, "https://163cn.tv/baQqV8be")
        XCTAssertEqual(playlist.songs.map(\.title), ["一路向北", "旅行的意义"])
    }

    func testCoordinatorRejectsPastedStandaloneQQURLBeforeParsingItAsSongText() async {
        let fetcher = UnexpectedPlaylistPageFetcher()
        let coordinator = ImportCoordinator(resolvers: [
            PublicWebPlaylistResolver(fetcher: fetcher),
            PlainTextPlaylistResolver()
        ])
        let payload = PendingImportPayload(
            sourceHint: .plainText,
            rawText: "https://y.qq.com/n/ryqq/playlist/1374105607",
            displayTitle: "粘贴导入歌单"
        )

        do {
            _ = try await coordinator.resolve(payload: payload)
            XCTFail("Expected QQ Music share-text guidance")
        } catch let error as PlaylistResolveError {
            XCTAssertEqual(error, .qqMusicRequiresShareText)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(fetcher.callCount, 0)
    }

    func testPublicPlaylistFallsBackToRetainedRawTextWhenPageIsUnavailable() async throws {
        let resolver = PublicWebPlaylistResolver(fetcher: UnavailablePlaylistPageFetcher())
        let payload = PendingImportPayload(
            sourceHint: .netEaseMusic,
            rawText: """
            来自网易云音乐的歌单
            一路向北 - 周杰伦
            """,
            urlString: "https://music.163.com/playlist?id=123",
            displayTitle: "分享歌单"
        )

        let playlist = try await resolver.resolve(payload: payload)

        XCTAssertEqual(playlist.externalURL?.absoluteString, "https://music.163.com/playlist?id=123")
        XCTAssertEqual(playlist.songs.map(\.title), ["一路向北"])
    }

    func testPublicPlaylistFallbackKeepsTitleOnlySongsFromRetainedRawText() async throws {
        let resolver = PublicWebPlaylistResolver(fetcher: UnavailablePlaylistPageFetcher())
        let payload = PendingImportPayload(
            sourceHint: .netEaseMusic,
            rawText: """
            https://music.163.com/playlist?id=123
            小幸运
            后来
            """,
            urlString: "https://music.163.com/playlist?id=123",
            displayTitle: "分享歌单"
        )

        let playlist = try await resolver.resolve(payload: payload)

        XCTAssertEqual(playlist.externalURL?.absoluteString, "https://music.163.com/playlist?id=123")
        XCTAssertEqual(playlist.songs.map(\.title), ["小幸运", "后来"])
        XCTAssertTrue(playlist.songs.allSatisfy { $0.artist == nil })
    }

    func testCoordinatorKeepsRawTextAfterPromotingEmbeddedURL() async throws {
        let coordinator = ImportCoordinator(resolvers: [
            PublicWebPlaylistResolver(fetcher: UnavailablePlaylistPageFetcher()),
            PlainTextPlaylistResolver()
        ])
        let payload = PendingImportPayload(
            sourceHint: .plainText,
            rawText: """
            https://music.163.com/playlist?id=123
            旅行的意义 - 陈绮贞
            """,
            displayTitle: "分享歌单"
        )

        let playlist = try await coordinator.resolve(payload: payload)

        XCTAssertEqual(playlist.externalURL?.absoluteString, "https://music.163.com/playlist?id=123")
        XCTAssertEqual(playlist.songs.map(\.title), ["旅行的意义"])
    }

    func testCoordinatorDoesNotPromoteInsecureHTTPLinkOverUsableSongText() async throws {
        let coordinator = ImportCoordinator(resolvers: [
            PublicWebPlaylistResolver(fetcher: SecurityRejectingPlaylistPageFetcher()),
            PlainTextPlaylistResolver()
        ])
        let payload = PendingImportPayload(
            sourceHint: .plainText,
            rawText: """
            http://music.example.com/playlist
            旅行的意义 - 陈绮贞
            """
        )

        let playlist = try await coordinator.resolve(payload: payload)

        XCTAssertNil(playlist.externalURL)
        XCTAssertEqual(playlist.songs.map(\.title), ["旅行的意义"])
    }

    func testCoordinatorPromotesHTTPSLinkWhenExistingURLStringIsBlank() async throws {
        let coordinator = ImportCoordinator(resolvers: [
            PublicWebPlaylistResolver(fetcher: UnavailablePlaylistPageFetcher()),
            PlainTextPlaylistResolver()
        ])
        let payload = PendingImportPayload(
            sourceHint: .plainText,
            rawText: """
            https://music.163.com/playlist?id=123
            旅行的意义 - 陈绮贞
            """,
            urlString: "   "
        )

        let playlist = try await coordinator.resolve(payload: payload)

        XCTAssertEqual(playlist.externalURL?.absoluteString, "https://music.163.com/playlist?id=123")
        XCTAssertEqual(playlist.songs.map(\.title), ["旅行的意义"])
    }

    func testPublicPlaylistDoesNotFallBackAfterCancellation() async {
        let resolver = PublicWebPlaylistResolver(fetcher: CancelledPlaylistPageFetcher())
        let payload = PendingImportPayload(
            sourceHint: .netEaseMusic,
            rawText: "一路向北 - 周杰伦",
            urlString: "https://music.163.com/playlist?id=123"
        )

        do {
            _ = try await resolver.resolve(payload: payload)
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Cancellation must stop the workflow instead of returning stale fallback content.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPublicPlaylistDoesNotMaskSecurityRejectionWithRawTextFallback() async {
        let resolver = PublicWebPlaylistResolver(fetcher: SecurityRejectingPlaylistPageFetcher())
        let payload = PendingImportPayload(
            sourceHint: .netEaseMusic,
            rawText: "一路向北 - 周杰伦",
            urlString: "https://music.163.com/playlist?id=123"
        )

        do {
            _ = try await resolver.resolve(payload: payload)
            XCTFail("Expected URL security rejection to propagate")
        } catch let error as PlaylistResolveError {
            XCTAssertEqual(error, .invalidURL)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPlainTextResolverRejectsInputWithoutAnySongs() async {
        let resolver = PlainTextPlaylistResolver()
        let payload = PendingImportPayload(
            sourceHint: .plainText,
            rawText: """
            登录后查看完整歌单
            https://music.example.com/playlist/123
            """
        )

        do {
            _ = try await resolver.resolve(payload: payload)
            XCTFail("Expected empty input error")
        } catch let error as PlaylistResolveError {
            XCTAssertEqual(error, .emptyInput)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPublicPlaylistRejectsCredentialsAndNonPublicNetworkAddresses() async {
        let resolver = PublicWebPlaylistResolver(
            fetcher: StubPlaylistPageFetcher(text: "一路向北 - 周杰伦")
        )
        let unsafeURLStrings = [
            "http://music.example.com/playlist",
            "https://user:password@example.com/playlist",
            "https://localhost/playlist",
            "https://localhost./playlist",
            "https://127.0.0.1/playlist",
            "https://10.0.0.8/playlist",
            "https://172.16.0.8/playlist",
            "https://192.168.1.8/playlist",
            "https://169.254.1.8/playlist",
            "https://100.64.0.1/playlist",
            "https://192.88.99.2/playlist",
            "https://[::1]/playlist",
            "https://[fe80::1]/playlist",
            "https://[fc00::1]/playlist",
            "https://[::ffff:127.0.0.1]/playlist",
            "https://[::ffff:8.8.8.8]/playlist",
            "https://[fec0::1]/playlist",
            "https://[64:ff9b::7f00:1]/playlist",
            "https://[64:ff9b:1::c0a8:1]/playlist",
            "https://[100::1]/playlist",
            "https://[2001:1::4]/playlist",
            "https://[2001:2::1]/playlist",
            "https://[2001:10::1]/playlist",
            "https://[2001:db8::1]/playlist",
            "https://[2002:c0a8:101::1]/playlist",
            "https://[3fff::1]/playlist",
            "https://[5f00::1]/playlist",
            "https://[4000::1]/playlist"
        ]

        for urlString in unsafeURLStrings {
            let payload = PendingImportPayload(sourceHint: .genericURL, urlString: urlString)
            do {
                _ = try await resolver.resolve(payload: payload)
                XCTFail("Expected unsafe URL to be rejected: \(urlString)")
            } catch let error as PlaylistResolveError {
                XCTAssertEqual(error, .invalidURL, urlString)
            } catch {
                XCTFail("Unexpected error for \(urlString): \(error)")
            }
        }
    }

    func testPublicPlaylistAllowsSupportedMusicHostsAndRealSubdomains() async throws {
        let resolver = PublicWebPlaylistResolver(
            fetcher: StubPlaylistPageFetcher(text: "一路向北 - 周杰伦")
        )

        for urlString in [
            "https://music.apple.com/cn/playlist/example",
            "https://embed.music.apple.com/cn/playlist/example",
            "https://itunes.apple.com/cn/album/example",
            "https://music.163.com/playlist?id=42",
            "https://share.music.163.com/playlist?id=42",
            "https://163cn.tv/example",
            "https://music.163cn.tv/example"
        ] {
            let playlist = try await resolver.resolve(
                payload: PendingImportPayload(sourceHint: .genericURL, urlString: urlString)
            )
            XCTAssertEqual(playlist.songs.map(\.title), ["一路向北"])
        }
    }

    func testPageFetcherRejectsUnsafeRedirectDestination() async {
        let redirectedURL = URL(string: "https://127.0.0.1/private-playlist")!
        let response = HTTPURLResponse(
            url: redirectedURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/plain; charset=utf-8"]
        )!
        let fetcher = URLSessionPlaylistPageFetcher(
            loader: StubPlaylistPageDataLoader(data: Data("一路向北 - 周杰伦".utf8), response: response)
        )

        do {
            _ = try await fetcher.pageText(for: URL(string: "https://music.apple.com/cn/playlist/example")!)
            XCTFail("Expected unsafe redirect destination to be rejected")
        } catch let error as PlaylistResolveError {
            XCTAssertEqual(error, .invalidURL)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAppleMusicStorefrontRedirectKeepsTheOriginalPlaylistPath() {
        let originalURL = URL(string: "https://music.apple.com/us/playlist/%E5%96%9C%E7%88%B1%E6%AD%8C%E6%9B%B2/pl.u-vvUz36Y7Lv?l=zh")!
        let proposedURL = URL(string: "https://music.apple.com/cn")!
        let normalized = PlaylistRedirectNormalizer().normalize(
            proposedRequest: URLRequest(url: proposedURL),
            currentRequest: URLRequest(url: originalURL)
        )

        XCTAssertEqual(
            normalized.url?.absoluteString,
            "https://music.apple.com/cn/playlist/%E5%96%9C%E7%88%B1%E6%AD%8C%E6%9B%B2/pl.u-vvUz36Y7Lv?l=zh"
        )
    }

    func testAppleMusicStorefrontRedirectCanonicalizesTrailingDotHost() {
        let originalURL = URL(string: "https://music.apple.com./us/playlist/%E5%96%9C%E7%88%B1%E6%AD%8C%E6%9B%B2/pl.u-vvUz36Y7Lv?l=zh")!
        let proposedURL = URL(string: "https://music.apple.com./cn")!
        let normalized = PlaylistRedirectNormalizer().normalize(
            proposedRequest: URLRequest(url: proposedURL),
            currentRequest: URLRequest(url: originalURL)
        )

        XCTAssertEqual(
            normalized.url?.absoluteString,
            "https://music.apple.com./cn/playlist/%E5%96%9C%E7%88%B1%E6%AD%8C%E6%9B%B2/pl.u-vvUz36Y7Lv?l=zh"
        )
    }

    func testPageFetcherAcceptsOnlySupportedTextMIMETypes() async throws {
        let url = URL(string: "https://music.apple.com/cn/playlist/example")!
        for mimeType in ["text/html", "text/plain", "application/xhtml+xml"] {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "\(mimeType); charset=utf-8"]
            )!
            let body = mimeType == "text/plain"
                ? Data("一路向北 - 周杰伦".utf8)
                : Data("<html><body>一路向北 - 周杰伦</body></html>".utf8)
            let fetcher = URLSessionPlaylistPageFetcher(
                loader: StubPlaylistPageDataLoader(data: body, response: response)
            )

            let text = try await fetcher.pageText(for: url)

            XCTAssertTrue(text.contains("一路向北"), mimeType)
        }

        let imageResponse = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
        )!
        let imageFetcher = URLSessionPlaylistPageFetcher(
            loader: StubPlaylistPageDataLoader(data: Data("一路向北 - 周杰伦".utf8), response: imageResponse)
        )
        do {
            _ = try await imageFetcher.pageText(for: url)
            XCTFail("Expected non-text MIME type to be rejected")
        } catch let error as PlaylistResolveError {
            XCTAssertEqual(error, .webPageUnavailable)
        }
    }

    func testPageFetcherSniffsMissingMIMEWithoutAcceptingBinaryData() async throws {
        let url = URL(string: "https://music.apple.com/cn/playlist/example")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!
        let textFetcher = URLSessionPlaylistPageFetcher(
            loader: StubPlaylistPageDataLoader(data: Data("一路向北 - 周杰伦".utf8), response: response)
        )
        let binaryFetcher = URLSessionPlaylistPageFetcher(
            loader: StubPlaylistPageDataLoader(data: Data([0, 1, 2, 3, 0, 10]), response: response)
        )

        let text = try await textFetcher.pageText(for: url)
        XCTAssertEqual(text, "一路向北 - 周杰伦")
        do {
            _ = try await binaryFetcher.pageText(for: url)
            XCTFail("Expected binary body without MIME to be rejected")
        } catch let error as PlaylistResolveError {
            XCTAssertEqual(error, .webPageUnavailable)
        }
    }

    func testPageFetcherRejectsDeclaredContentLengthBeforeTrustingSmallBody() async {
        let url = URL(string: "https://music.apple.com/cn/playlist/example")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "text/plain",
                "Content-Length": "100"
            ]
        )!
        let fetcher = URLSessionPlaylistPageFetcher(
            maximumBytes: 16,
            loader: StubPlaylistPageDataLoader(data: Data("一首歌".utf8), response: response)
        )

        do {
            _ = try await fetcher.pageText(for: url)
            XCTFail("Expected declared oversized body to be rejected")
        } catch let error as PlaylistResolveError {
            XCTAssertEqual(error, .webPageTooLarge)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPageFetcherRejectsActualBodyLargerThanLimit() async {
        let url = URL(string: "https://music.apple.com/cn/playlist/oversized")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/plain"]
        )!
        let fetcher = URLSessionPlaylistPageFetcher(
            maximumBytes: 16,
            loader: StubPlaylistPageDataLoader(data: Data(repeating: 65, count: 17), response: response)
        )

        do {
            _ = try await fetcher.pageText(for: url)
            XCTFail("Expected actual oversized body to be rejected")
        } catch let error as PlaylistResolveError {
            XCTAssertEqual(error, .webPageTooLarge)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPageFetcherClampsNonPositiveMaximumSizeToOneByte() async throws {
        let url = URL(string: "https://music.apple.com/cn/playlist/one-byte")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/plain", "Content-Length": "1"]
        )!
        let fetcher = URLSessionPlaylistPageFetcher(
            maximumBytes: 0,
            loader: StubPlaylistPageDataLoader(data: Data("A".utf8), response: response)
        )

        let text = try await fetcher.pageText(for: url)

        XCTAssertEqual(text, "A")
    }

    func testStreamingLoaderCancelsTransportBeforeBufferingOverflowChunk() {
        let delegate = BoundedPlaylistPageSessionDelegate(
            maximumBytes: 16,
            urlPolicy: PublicWebURLPolicy()
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://music.apple.com/cn/playlist/oversized")!)

        delegate.urlSession(session, dataTask: task, didReceive: Data(repeating: 65, count: 8))
        delegate.urlSession(session, dataTask: task, didReceive: Data(repeating: 66, count: 8))
        delegate.urlSession(session, dataTask: task, didReceive: Data(repeating: 67, count: 8))

        XCTAssertEqual(delegate.bufferedByteCount, 16)
        XCTAssertEqual(task.state, .canceling, "Crossing the limit must cancel the URLSession task immediately")
    }

    func testStreamingLoaderClaimsBodyLimitErrorBeforeCancelCompletionCanRace() async throws {
        let delegate = BoundedPlaylistPageSessionDelegate(
            maximumBytes: 16,
            urlPolicy: PublicWebURLPolicy()
        )
        let session = makeHangingSession(delegate: delegate)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://music.apple.com/cn/playlist/oversized")!)
        let loadTask = Task { try await delegate.load(request: request, session: session) }
        let dataTask = try await waitForDataTask(in: session)
        let completionInjected = expectation(description: "cancel completion injected")
        let once = OneShotGate()
        let observation = dataTask.observe(\.state, options: [.new]) { task, _ in
            guard task.state == .canceling, once.claim() else { return }
            delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
            completionInjected.fulfill()
        }
        defer { observation.invalidate() }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/plain"]
        )!

        delegate.urlSession(session, dataTask: dataTask, didReceive: response) { disposition in
            XCTAssertEqual(disposition, .allow)
        }
        delegate.urlSession(session, dataTask: dataTask, didReceive: Data(repeating: 65, count: 17))

        await fulfillment(of: [completionInjected], timeout: 1)
        do {
            _ = try await loadTask.value
            XCTFail("Expected the body-size error")
        } catch let error as PlaylistResolveError {
            XCTAssertEqual(error, .webPageTooLarge)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamingLoaderClaimsHeaderErrorBeforeCancelCompletionCanRace() async throws {
        let delegate = BoundedPlaylistPageSessionDelegate(
            maximumBytes: 16,
            urlPolicy: PublicWebURLPolicy()
        )
        let session = makeHangingSession(delegate: delegate)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://music.apple.com/cn/playlist/oversized")!)
        let loadTask = Task { try await delegate.load(request: request, session: session) }
        let dataTask = try await waitForDataTask(in: session)
        let completionInjected = expectation(description: "cancel completion injected")
        let once = OneShotGate()
        let observation = dataTask.observe(\.state, options: [.new]) { task, _ in
            guard task.state == .canceling, once.claim() else { return }
            delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
            completionInjected.fulfill()
        }
        defer { observation.invalidate() }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/plain", "Content-Length": "100"]
        )!

        delegate.urlSession(session, dataTask: dataTask, didReceive: response) { disposition in
            XCTAssertEqual(disposition, .cancel)
            guard once.claim() else { return }
            delegate.urlSession(session, task: dataTask, didCompleteWithError: URLError(.cancelled))
            completionInjected.fulfill()
        }

        await fulfillment(of: [completionInjected], timeout: 1)
        do {
            _ = try await loadTask.value
            XCTFail("Expected the declared-size error")
        } catch let error as PlaylistResolveError {
            XCTAssertEqual(error, .webPageTooLarge)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamingLoaderClaimsRedirectErrorBeforeCancelCompletionCanRace() async throws {
        let delegate = BoundedPlaylistPageSessionDelegate(
            maximumBytes: 128,
            urlPolicy: PublicWebURLPolicy()
        )
        let session = makeHangingSession(delegate: delegate)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://music.apple.com/cn/playlist/start")!)
        let loadTask = Task { try await delegate.load(request: request, session: session) }
        let dataTask = try await waitForDataTask(in: session)
        let completionInjected = expectation(description: "cancel completion injected")
        let redirectDecided = expectation(description: "redirect rejected")
        let once = OneShotGate()
        let observation = dataTask.observe(\.state, options: [.new]) { task, _ in
            guard task.state == .canceling, once.claim() else { return }
            delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
            completionInjected.fulfill()
        }
        defer { observation.invalidate() }

        delegate.urlSession(
            session,
            task: dataTask,
            willPerformHTTPRedirection: HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: nil
            )!,
            newRequest: URLRequest(url: URL(string: "https://127.0.0.1/private")!)
        ) { followedRequest in
            XCTAssertNil(followedRequest)
            redirectDecided.fulfill()
        }

        await fulfillment(of: [redirectDecided, completionInjected], timeout: 1)
        do {
            _ = try await loadTask.value
            XCTFail("Expected the redirect security error")
        } catch let error as PlaylistResolveError {
            XCTAssertEqual(error, .invalidURL)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamingLoaderClaimsTaskCancellationBeforeTransportCompletionCanRace() async throws {
        let delegate = BoundedPlaylistPageSessionDelegate(
            maximumBytes: 128,
            urlPolicy: PublicWebURLPolicy()
        )
        let session = makeHangingSession(delegate: delegate)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://music.apple.com/cn/playlist/pending")!)
        let loadTask = Task { try await delegate.load(request: request, session: session) }
        let dataTask = try await waitForDataTask(in: session)
        let completionInjected = expectation(description: "cancel completion injected")
        let once = OneShotGate()
        let observation = dataTask.observe(\.state, options: [.new]) { task, _ in
            guard task.state == .canceling, once.claim() else { return }
            delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
            completionInjected.fulfill()
        }
        defer { observation.invalidate() }

        loadTask.cancel()

        await fulfillment(of: [completionInjected], timeout: 1)
        do {
            _ = try await loadTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Cancellation must win over URLSession's NSURLErrorCancelled callback.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamingLoaderRejectsNonTrustedRedirectBeforeFollowingIt() async {
        let delegate = BoundedPlaylistPageSessionDelegate(
            maximumBytes: 128,
            urlPolicy: PublicWebURLPolicy()
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://music.apple.com/cn/playlist/start")!)
        let callback = expectation(description: "redirect decision")
        var followedRequest: URLRequest?

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: HTTPURLResponse(
                url: URL(string: "https://music.apple.com/cn/playlist/start")!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: nil
            )!,
            newRequest: URLRequest(url: URL(string: "https://music.apple.com.example.com/private")!)
        ) { request in
            followedRequest = request
            callback.fulfill()
        }

        await fulfillment(of: [callback], timeout: 1)
        XCTAssertNil(followedRequest)
        XCTAssertTrue([.canceling, .completed].contains(task.state))
    }

    func testStreamingLoaderRejectsDeclaredLengthBeforeAllowingBody() {
        let delegate = BoundedPlaylistPageSessionDelegate(
            maximumBytes: 16,
            urlPolicy: PublicWebURLPolicy()
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://music.apple.com/cn/playlist/oversized")!)
        let response = HTTPURLResponse(
            url: task.originalRequest!.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/plain", "Content-Length": "100"]
        )!
        var disposition: URLSession.ResponseDisposition?

        delegate.urlSession(session, dataTask: task, didReceive: response) {
            disposition = $0
        }

        XCTAssertEqual(disposition, .cancel)
        XCTAssertEqual(delegate.bufferedByteCount, 0)
        XCTAssertTrue(
            [.canceling, .completed].contains(task.state),
            "Rejected responses must leave the URLSession task canceling or completed"
        )
    }

    func testHTMLExtractorReadsStructuredNetEasePlaylistData() throws {
        let html = """
        <html><body><script>
        window.REDUX_STATE = {"Playlist":{"data":[
          {"songName":"海屿你","singerName":"马也_Crabbit"},
          {"songName":"玻璃","singerName":"Gareth.T"}
        ]}};
        </script></body></html>
        """

        let text = try PlaylistPageTextExtractor().text(fromHTMLData: Data(html.utf8))

        XCTAssertEqual(text, "海屿你 - 马也_Crabbit\n玻璃 - Gareth.T")
    }

    #if canImport(Network)
    func testHTMLExtractorDoesNotLoadEmbeddedNetworkResources() throws {
        let probe = try LocalHTTPResourceProbe()
        defer { probe.stop() }
        let html = """
        <html>
          <head>
            <link rel="stylesheet" href="\(probe.resourceURL(path: "playlist.css"))">
          </head>
          <body>
            <img src="\(probe.resourceURL(path: "cover.png"))">
            <p>一路向北 - 周杰伦</p>
          </body>
        </html>
        """

        let text = try PlaylistPageTextExtractor().text(fromHTMLData: Data(html.utf8))

        XCTAssertFalse(
            probe.receivedRequest(timeout: 0.3),
            "HTML 文本抽取不得加载图片、样式或任何页面子资源"
        )
        XCTAssertEqual(text, "一路向北 - 周杰伦")
    }
    #endif

    func testHTMLExtractorPreservesBlocksAndEntitiesWhileDiscardingExecutableContent() throws {
        let html = """
        <!doctype html>
        <html>
          <head>
            <style>.song { background: url(https://127.0.0.1/private); }</style>
            <script>window.secret = "不应进入歌单";</script>
          </head>
          <body>
            <div>海阔天空 &amp; Beyond</div>
            <p>一路向北 &#45; 周杰伦<br>旅行的意义 &#x2D; 陈绮贞</p>
            <noscript>也不应进入歌单</noscript>
          </body>
        </html>
        """

        let text = try PlaylistPageTextExtractor().text(fromHTMLData: Data(html.utf8))

        XCTAssertEqual(
            text,
            "海阔天空 & Beyond\n一路向北 - 周杰伦\n旅行的意义 - 陈绮贞"
        )
        XCTAssertFalse(text.contains("window.secret"))
        XCTAssertFalse(text.contains("background"))
        XCTAssertFalse(text.contains("不应进入歌单"))
    }

    func testHTMLExtractorReadsAppleMusicSerializedPlaylistTracks() throws {
        let html = """
        <!doctype html>
        <html><body>
        <script type="application/json" id="serialized-server-data">
        {
          "data": [{
            "sections": [{
              "id": "track-list - pl.u-vvUz36Y7Lv",
              "items": [
                {
                  "id": "track-lockup - pl.u-vvUz36Y7Lv - 1543958429",
                  "title": "Beautiful World",
                  "artistName": "Westlife"
                },
                {
                  "id": "track-lockup - pl.u-vvUz36Y7Lv - 1134344911",
                  "title": "爱错",
                  "subtitleLinks": [{"title": "王力宏"}]
                }
              ]
            }]
          }]
        }
        </script>
        </body></html>
        """

        let text = try PlaylistPageTextExtractor().text(fromHTMLData: Data(html.utf8))

        XCTAssertEqual(text, "Beautiful World - Westlife\n爱错 - 王力宏")
    }

    func testHTMLExtractorReportsPrivateNetEasePlaylist() {
        let html = """
        <html><body><script>
        window.REDUX_STATE = {"Playlist":{"code":"401"},"userAgent":"Mobile"};
        </script></body></html>
        """

        do {
            _ = try PlaylistPageTextExtractor().text(fromHTMLData: Data(html.utf8))
            XCTFail("Expected a private playlist error")
        } catch let error as PlaylistResolveError {
            XCTAssertEqual(error, .privatePlaylist)
            XCTAssertEqual(
                error.localizedDescription,
                "这个歌单是私人歌单，公开链接无法读取；请复制歌曲文字或发截图"
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeHangingSession(delegate: URLSessionDelegate) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingPlaylistURLProtocol.self]
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    private func waitForDataTask(in session: URLSession) async throws -> URLSessionDataTask {
        for _ in 0..<200 {
            let tasks = await withCheckedContinuation { continuation in
                session.getAllTasks { continuation.resume(returning: $0) }
            }
            if let dataTask = tasks.first as? URLSessionDataTask {
                return dataTask
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw PlaylistResolverTestError.dataTaskDidNotStart
    }
}

#if canImport(Network)
private final class LocalHTTPResourceProbe: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "PlaylistResolverTests.LocalHTTPResourceProbe")
    private let requestReceived = DispatchSemaphore(value: 0)
    private let listenerReady = DispatchSemaphore(value: 0)
    private let listenerFailed = DispatchSemaphore(value: 0)

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [listenerReady, listenerFailed] state in
            switch state {
            case .ready:
                listenerReady.signal()
            case .failed:
                listenerFailed.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [queue, requestReceived] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { data, _, _, _ in
                if data?.isEmpty == false {
                    requestReceived.signal()
                }
                let response = Data(
                    "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8
                )
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: queue)

        let ready = listenerReady.wait(timeout: .now() + 2) == .success
        let failed = listenerFailed.wait(timeout: .now()) == .success
        guard ready, !failed, listener.port != nil else {
            listener.cancel()
            throw PlaylistResolverTestError.localProbeDidNotStart
        }
    }

    func resourceURL(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/\(path)")!
    }

    func receivedRequest(timeout: TimeInterval) -> Bool {
        requestReceived.wait(timeout: .now() + timeout) == .success
    }

    func stop() {
        listener.cancel()
    }
}
#endif

private enum PlaylistResolverTestError: Error {
    case dataTaskDidNotStart
    case localProbeDidNotStart
}

private final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

private final class HangingPlaylistURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {}
    override func stopLoading() {}
}

private struct StubPlaylistPageFetcher: PlaylistPageFetching {
    let text: String

    func pageText(for url: URL) async throws -> String {
        text
    }
}

private final class UnexpectedPlaylistPageFetcher: PlaylistPageFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.withLock { calls }
    }

    func pageText(for url: URL) async throws -> String {
        lock.withLock { calls += 1 }
        throw PlaylistResolveError.parseFailed("unexpected network access")
    }
}

private struct UnavailablePlaylistPageFetcher: PlaylistPageFetching {
    func pageText(for url: URL) async throws -> String {
        throw PlaylistResolveError.webPageUnavailable
    }
}

private struct CancelledPlaylistPageFetcher: PlaylistPageFetching {
    func pageText(for url: URL) async throws -> String {
        throw CancellationError()
    }
}

private struct SecurityRejectingPlaylistPageFetcher: PlaylistPageFetching {
    func pageText(for url: URL) async throws -> String {
        throw PlaylistResolveError.invalidURL
    }
}

private struct StubPlaylistPageDataLoader: PlaylistPageDataLoading {
    let data: Data
    let response: URLResponse

    func data(
        for request: URLRequest,
        maximumBytes: Int,
        urlPolicy: PublicWebURLPolicy
    ) async throws -> PlaylistPageDataResponse {
        return PlaylistPageDataResponse(data: data, response: response)
    }
}

private final class CountingPlaylistPageDataLoader: PlaylistPageDataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.withLock { calls }
    }

    func data(
        for request: URLRequest,
        maximumBytes: Int,
        urlPolicy: PublicWebURLPolicy
    ) async throws -> PlaylistPageDataResponse {
        lock.withLock { calls += 1 }
        throw PlaylistResolveError.parseFailed("unexpected transport access")
    }
}
