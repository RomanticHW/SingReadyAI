import XCTest

final class SingReadyAIUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testScreenshotsForCriticalFlow() throws {
        let cases: [(name: String, arguments: [String], expectedText: String)] = [
            ("01_onboarding", ["-singreadyResetOnboarding"], "开始使用"),
            ("02_home", ["-singreadyStage", "home"], "先做哪件事"),
            ("03_import_hub", ["-singreadyStage", "importHub"], "选一种方式"),
            ("04_import_review", ["-singreadyStage", "review"], "先看一眼歌名"),
            ("05_match_report", ["-singreadyStage", "matchReport"], "本地参考基本都命中"),
            ("06_voice_setup", ["-singreadyStage", "voiceSetup"], "开始录音"),
            ("07_voice_result", ["-singreadyStage", "voiceResult"], "先按常见范围排"),
            ("08_scenario_builder", ["-singreadyStage", "scenario"], "排今晚歌单"),
            ("09_song_plan_result", ["-singreadyStage", "result"], "调整场景"),
            ("10_export_center", ["-singreadyStage", "export"], "发群里更省事"),
            ("11_start_tips", ["-singreadyStage", "startTips"], "今晚怎么开场")
        ]

        for testCase in cases {
            let app = XCUIApplication()
            app.launchArguments = testCase.arguments
            app.launch()

            waitForText(testCase.expectedText, in: app)

            let window = app.windows.firstMatch
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = testCase.name
            attachment.lifetime = .keepAlways
            add(attachment)

            app.terminate()
        }
    }

    func testStageMenuCanOpenEveryFeature() throws {
        let cases: [(title: String, expectedText: String)] = [
            ("导入歌单", "选一种方式"),
            ("整理歌单", "还没有歌单"),
            ("核对参考匹配", "把歌单放进来"),
            ("测一下音域", "唱 10 秒就行"),
            ("排今晚歌单", "排一份今晚歌单"),
            ("今晚歌单", "还没有歌单")
        ]

        for testCase in cases {
            let app = XCUIApplication()
            app.launchArguments = ["-singreadyStage", "home"]
            app.launch()

            XCTAssertTrue(app.buttons["打开功能菜单"].waitForExistence(timeout: 8))
            app.buttons["打开功能菜单"].tap()
            app.buttons["打开\(testCase.title)"].tap()

            waitForText(testCase.expectedText, in: app)
            app.terminate()
        }

        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "home"]
        app.launch()
        assertStageMenuReadyOutputsUnavailable(in: app)
    }

    func testHomeFeatureCardsOpenModulesWithoutCreatingDemoPlan() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "home"]
        app.launch()

        assertHomeReadyOutputsUnavailable(in: app)
    }

    func testHomeGroupsFunctionsByUseCase() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "home"]
        app.launch()

        waitForText("先做哪件事", in: app)
        waitForText("我有歌单", in: app)
        waitForText("唱前准备", in: app)
        waitForText("到了现场", in: app)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "第一步")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "最后")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "步骤")).firstMatch.exists)

        assertHomeReadyOutputsUnavailable(in: app)
    }

    func testContentViewportIsNotCrowdedByTopBar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "home"]
        app.launch()

        let content = app.scrollViews.firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 8))
        XCTAssertLessThan(content.frame.minY, 240, "顶部栏占用了过多内容空间")

        let menu = app.buttons["打开功能菜单"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        XCTAssertLessThanOrEqual(menu.frame.height, 56, "功能菜单不应随大字号膨胀")
    }

    func testHomeFeatureSupportsNativeEdgeSwipeBack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "home"]
        app.launch()

        tapButton("导入歌单", in: app)
        waitForText("先把歌单放进来", in: app)

        assertEdgeSwipeBack(reveals: "先做哪件事", in: app)
    }

    func testHomeOpensBundledPrivacyPolicyInsideTheApp() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "home"]
        app.launch()

        assertBundledPrivacyPolicy(in: app, usesAccessibleBackButton: false)
    }

    func testHomePrivacyPolicySupportsAccessibilityXXXL() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "home",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()

        assertBundledPrivacyPolicy(in: app, usesAccessibleBackButton: true)
    }

    private func assertBundledPrivacyPolicy(
        in app: XCUIApplication,
        usesAccessibleBackButton: Bool
    ) {

        let policyLink = app.descendants(matching: .any)["privacy-policy-link"]
        XCTAssertTrue(scrollToHittable(policyLink, in: app))
        XCTAssertGreaterThanOrEqual(policyLink.frame.height, 44)
        XCTAssertGreaterThanOrEqual(policyLink.frame.width, 44)
        policyLink.tap()

        XCTAssertTrue(app.navigationBars["隐私政策"].waitForExistence(timeout: 8))
        waitForText("我们处理的信息", in: app)
        waitForText("第三方服务", in: app, timeout: 60)
        let applePolicyLink = app.links.matching(
            NSPredicate(format: "label CONTAINS %@", "Apple 隐私政策")
        ).firstMatch
        XCTAssertTrue(
            waitForElement(applePolicyLink, in: app, timeout: 15),
            "政策正文里的第三方隐私链接应保持为可访问链接"
        )
        waitForText("政策更新与联系", in: app, timeout: 30)
        let feedbackLink = app.links.matching(
            NSPredicate(format: "label CONTAINS %@", "问题反馈页面")
        ).firstMatch
        XCTAssertTrue(
            waitForElement(feedbackLink, in: app, timeout: 15),
            "政策正文里的联系入口应保持为可访问链接"
        )
        if usesAccessibleBackButton {
            let backButton = app.navigationBars["隐私政策"].buttons.firstMatch
            assertMinimumTouchTarget(backButton)
            backButton.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["privacy-policy-link"]
                    .waitForExistence(timeout: 8),
                "导航栏返回按钮应回到首页"
            )
        } else {
            assertEdgeSwipeBack(reveals: "先做哪件事", in: app)
        }
    }

    func testForwardActionKeepsPreviousFeatureInNavigationHistory() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "scenario"]
        app.launch()

        tapButton("排一份今晚歌单", in: app)
        waitForText("调整场景", in: app)

        assertEdgeSwipeBack(reveals: "按今晚的局来排", in: app)
    }

    func testGlobalFeatureSwitchBacksToHomeInsteadOfPreviousModule() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result"]
        app.launch()

        XCTAssertTrue(app.buttons["打开功能菜单"].waitForExistence(timeout: 8))
        app.buttons["打开功能菜单"].tap()
        app.buttons["打开导入歌单"].tap()
        waitForText("先把歌单放进来", in: app)

        assertEdgeSwipeBack(reveals: "先做哪件事", in: app)
        XCTAssertFalse(app.staticTexts["调整场景"].exists)
    }

    func testSelectingCurrentStageFromMenuKeepsNativeBackHistory() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "home"]
        app.launch()

        tapButton("导入歌单", in: app)
        waitForText("先把歌单放进来", in: app)

        let textView = app.textViews["粘贴歌单文本"]
        XCTAssertTrue(waitForElement(textView, in: app))
        textView.tap()
        app.typeText("晴天 - 周杰伦\n稻香 - 周杰伦")
        tapButton("整理这段歌单", in: app)
        waitForText("先看一眼歌名", in: app)

        app.buttons["打开功能菜单"].tap()
        let currentStageButton = app.buttons["stage-menu-review"]
        XCTAssertTrue(currentStageButton.waitForExistence(timeout: 8))
        XCTAssertTrue(currentStageButton.isSelected)
        XCTAssertEqual(currentStageButton.label, "整理歌单，当前页面")
        currentStageButton.tap()
        waitForText("先看一眼歌名", in: app)

        assertEdgeSwipeBack(reveals: "先把歌单放进来", in: app)
    }

    func testLeavingReviewCancelsSlowMatchingWithoutLateNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "review",
            "-singreadySlowPlaylistAnalysis"
        ]
        app.launch()

        let matchButton = app.buttons["开始批量匹配"]
        XCTAssertTrue(scrollToHittable(matchButton, in: app))
        matchButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["matching-progress"].waitForExistence(timeout: 3))

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开导入歌单"].tap()
        waitForText("先把歌单放进来", in: app)
        XCTAssertFalse(app.descendants(matching: .any)["matching-progress"].exists)
        XCTAssertFalse(app.buttons["取消本次导入"].exists)
        XCTAssertTrue(app.buttons["用示例歌单"].isEnabled, "离开核对页后导入操作应立即解锁")

        let unexpectedMatchReport = app.staticTexts["本地参考基本都命中"]
        let lateNavigation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: unexpectedMatchReport
        )
        lateNavigation.isInverted = true
        wait(for: [lateNavigation], timeout: 9)
        XCTAssertTrue(app.staticTexts["先把歌单放进来"].exists)
    }

    func testLargeCleanReviewSkipsEditorsAndCanStartBatchMatching() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "review",
            "-singreadyLargeCleanReview"
        ]
        app.launch()

        waitForText("共 1000 首 · 建议看 0 首 · 缺歌名 0 首", in: app)
        waitForText("歌名都整理好了，可以直接批量匹配", in: app)
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "review-song-editor").count,
            0,
            "零异常时不应创建全量编辑器"
        )
        XCTAssertTrue(app.buttons["开始批量匹配"].isEnabled)
        XCTAssertTrue(app.buttons["查看全部歌曲"].exists)
    }

    func testLargeReviewDefaultsToExceptionsAndLoadsAllSongsTwentyAtATime() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "review",
            "-singreadyLargeReviewExceptions"
        ]
        app.launch()

        waitForText("共 68 首 · 建议看 28 首 · 缺歌名 3 首", in: app)
        waitForText("补上歌名后才能开始匹配", in: app)
        XCTAssertFalse(app.buttons["开始批量匹配"].isEnabled)
        XCTAssertFalse(app.buttons["删除正常歌曲 1"].exists, "默认只展示建议处理的歌曲")
        XCTAssertTrue(waitForElement(app.buttons["删除需核对歌曲 1"], in: app))
        waitForText("已显示 20 / 28 首", in: app)

        tapButton("查看全部歌曲", in: app)
        waitForText("已显示 20 / 68 首", in: app)
        XCTAssertTrue(waitForElement(app.buttons["删除正常歌曲 1"], in: app, scrollDirection: .down))
        tapButton("再显示 20 首", in: app)
        waitForText("已显示 40 / 68 首", in: app)
    }

    func testMissingArtistDoesNotBlockBatchMatching() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "review",
            "-singreadyLargeMixedReview"
        ]
        app.launch()

        waitForText("共 120 首 · 建议看 40 首 · 缺歌名 0 首", in: app)
        waitForText("这些信息可能不完整，不处理也能继续", in: app)
        XCTAssertTrue(app.buttons["开始批量匹配"].isEnabled)
    }

    func testLargeReviewShowsMonotonicMatchingProgressBeforeSummary() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "review",
            "-singreadyLargeMixedReview",
            "-singreadySlowPlaylistAnalysisProgress"
        ]
        app.launch()

        waitForText("共 120 首 · 建议看 40 首 · 缺歌名 0 首", in: app)
        let matchButton = app.buttons["开始批量匹配"]
        XCTAssertTrue(scrollToHittable(matchButton, in: app))
        matchButton.tap()
        waitForText("已处理 0 / 120 首", in: app)
        let advancedProgress = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "已处理 (20|40|60|80|100|120) / 120 首")
        ).firstMatch
        XCTAssertTrue(advancedProgress.waitForExistence(timeout: 6))

        XCTAssertTrue(app.navigationBars["核对参考匹配"].waitForExistence(timeout: 15))
        waitForText("已确认 40 / 待确认 40 / 未找到 40", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["match-outcome-summary"].exists)
        XCTAssertTrue(app.buttons["按这份歌单排一版"].exists)
    }

    func testCancellingLargeMatchKeepsAllReviewDrafts() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "review",
            "-singreadyLargeMixedReview",
            "-singreadySlowPlaylistAnalysis"
        ]
        app.launch()

        waitForText("共 120 首 · 建议看 40 首 · 缺歌名 0 首", in: app)
        let matchButton = app.buttons["开始批量匹配"]
        XCTAssertTrue(scrollToHittable(matchButton, in: app))
        matchButton.tap()
        XCTAssertTrue(app.buttons["取消匹配"].waitForExistence(timeout: 3))
        app.buttons["取消匹配"].tap()

        waitForText("共 120 首 · 建议看 40 首 · 缺歌名 0 首", in: app)
        waitForText("已取消匹配，整理好的歌曲都还在。", in: app)
        let retryButton = app.buttons["开始批量匹配"]
        XCTAssertTrue(scrollToHittable(retryButton, in: app))
        XCTAssertTrue(retryButton.isEnabled)
    }

    func testLocalMatchTimeoutIsRetryableAndDoesNotBecomeImportFailure() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "review",
            "-singreadySlowPlaylistAnalysis",
            "-singreadyShortMatchTimeout"
        ]
        app.launch()

        let matchButton = app.buttons["开始批量匹配"]
        XCTAssertTrue(scrollToHittable(matchButton, in: app))
        matchButton.tap()
        waitForText("核对时间有点长，已停止。歌单内容都还在，可以重新核对。", in: app, timeout: 5)
        XCTAssertTrue(app.buttons["开始批量匹配"].isEnabled)
        XCTAssertFalse(app.buttons["取消本次导入"].exists)
    }

    func testCancellingScenarioPreparationDoesNotLateNavigateToReviewOrResult() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "review",
            "-singreadySlowPlaylistAnalysis"
        ]
        app.launch()

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开排今晚歌单"].tap()
        waitForText("按今晚的局来排", in: app)

        tapButton("排一份今晚歌单", in: app)
        XCTAssertTrue(app.buttons["取消核对"].waitForExistence(timeout: 3))
        app.buttons["取消核对"].tap()
        XCTAssertTrue(app.buttons["排一份今晚歌单"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["排一份今晚歌单"].isEnabled)

        let lateDestination = app.staticTexts.matching(
            NSPredicate(format: "label IN %@", ["先看一眼歌名", "朋友局歌单"])
        ).firstMatch
        let lateNavigation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: lateDestination
        )
        lateNavigation.isInverted = true
        wait(for: [lateNavigation], timeout: 9)

        XCTAssertTrue(app.staticTexts["按今晚的局来排"].exists)
        XCTAssertTrue(app.buttons["排一份今晚歌单"].isEnabled)
    }

    func testOnboardingCanStartImmediately() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyResetOnboarding"]
        app.launch()

        XCTAssertTrue(app.buttons["开始使用"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["看看怎么用"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["跳过引导"].exists)
        app.buttons["开始使用"].tap()
        waitForText("先做哪件事", in: app)
        XCTAssertFalse(app.buttons["下一页"].exists)
    }

    func testOnboardingGuideCanBeBrowsedWithoutForcedSteps() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyResetOnboarding"]
        app.launch()

        XCTAssertTrue(app.buttons["看看怎么用"].waitForExistence(timeout: 8))
        app.buttons["看看怎么用"].tap()
        waitForText("想测就测，不想测也能排", in: app)

        app.buttons["再看一页"].tap()
        waitForText("不同场合用不同顺序", in: app)

        app.buttons["再看一页"].tap()
        waitForText("只处理你给的内容", in: app)
        XCTAssertFalse(app.buttons["再看一页"].exists)

        app.buttons["开始使用"].tap()
        waitForText("先做哪件事", in: app)
    }

    func testExportControlsAvoidTechnicalCopy() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "export"]
        app.launch()

        XCTAssertTrue(app.buttons["保存海报"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["复制歌单"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["复制数据"].exists)
        XCTAssertFalse(app.buttons["复制 JSON"].exists)
        XCTAssertFalse(app.buttons["完整 JSON"].exists)
    }

    func testGlobalPersistenceErrorIsVisibleOutsideImportHubAndDismissible() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result", "-singreadyShowGlobalError"]
        app.launch()

        let banner = app.descendants(matching: .any)["global-error-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 8))
        XCTAssertTrue(banner.label.contains("当前进度暂时没保存下来"))
        let closeButton = app.buttons["关闭错误提示"]
        XCTAssertTrue(closeButton.exists)
        closeButton.tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 8))
    }

    func testExportOffersDetailedTextFileShare() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "export"]
        app.launch()

        let detailedFileButton = app.buttons["分享详细文本文件"]
        XCTAssertTrue(waitForElement(detailedFileButton, in: app))
        detailedFileButton.tap()

        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 8), "详细文本文件没有打开系统分享面板")
        app.otherElements["PopoverDismissRegion"].tap()
        XCTAssertTrue(shareSheet.waitForNonExistence(timeout: 8))
    }

    func testCompleteSampleFlowReachesExport() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "importHub"]
        app.launch()

        tapButton("用示例歌单", in: app)
        waitForText("先看一眼歌名", in: app)

        tapButton("开始批量匹配", in: app)
        waitForText("本地参考基本都命中", in: app)

        tapButton("测一下音域", in: app, timeout: 35)
        waitForText("唱 10 秒就行", in: app)

        tapButton("先不测", in: app)
        waitForText("先按常见范围排", in: app)

        tapButton("去排今晚歌单", in: app)
        waitForText("排今晚歌单", in: app)

        tapButton("排一份今晚歌单", in: app)
        waitForText("调整场景", in: app)

        tapButton("发给朋友", in: app)
        waitForText("发群里更省事", in: app)

        XCTAssertTrue(app.buttons["保存海报"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["复制歌单"].waitForExistence(timeout: 8))
    }

    func testSongPlanItemActionsAreInteractive() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result"]
        app.launch()

        waitForText("调整场景", in: app)
        XCTAssertFalse(songActionButton("搜索", in: app).exists)
        XCTAssertFalse(songActionButton("复制", in: app).exists)

        tapSongDetail(in: app)
        waitForText("为什么放这首", in: app)
        waitForText("搜索", in: app)
        waitForText("复制", in: app)

        tapButton("锁定", in: app)
        waitForText("取消锁定", in: app)

        waitForText("为什么放这首", in: app)
        XCTAssertTrue(songActionButton("收起", in: app).exists, "锁定后应保留当前歌曲的展开状态")
        let likeButton = app.buttons["喜欢"].firstMatch
        XCTAssertTrue(scrollToHittable(likeButton, in: app))
        likeButton.tap()
        waitForText("已记录", in: app)
        waitForText("撤销上次选择", in: app, scrollDirection: .down)
    }

    func testLockedSongCannotBeRemovedAndDoesNotShowRemovalUndo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result"]
        app.launch()

        waitForText("调整场景", in: app)
        tapSongDetail(in: app)
        tapButton("锁定", in: app)
        waitForText("取消锁定", in: app)
        waitForText("移除", in: app)

        tapButton("移除", in: app)

        waitForText("《稻香》已锁定，请先取消锁定再移除。", in: app)
        XCTAssertFalse(app.buttons["撤销移除"].exists)

        tapButton("取消锁定", in: app)
        waitForText("锁定", in: app)
        tapButton("移除", in: app)
        waitForText("已移除《稻香》", in: app)
        XCTAssertTrue(app.buttons["撤销移除"].exists)
    }

    func testLockedRemovalToastReflowsAndRemainsVisibleAtAccessibilitySize() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "result",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()

        waitForText("调整场景", in: app)
        tapSongDetail(in: app)
        tapStableSongAction("锁定", in: app)
        waitForText("取消锁定", in: app)
        waitForText("移除", in: app)
        tapStableSongAction("移除", in: app)

        let message = "《稻香》已锁定，请先取消锁定再移除。"
        let toast = app.descendants(matching: .any)["floating-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 8))
        XCTAssertEqual(toast.label, message)
        XCTAssertEqual(toast.value as? String, "警告")
        XCTAssertGreaterThan(toast.frame.height, 42, "无障碍字号下完整说明需要多行自适应高度")
        XCTAssertLessThanOrEqual(
            toast.frame.width,
            app.windows.firstMatch.frame.width - 32,
            "无障碍字号 toast 应在页面边缘保留可读留白"
        )

        Thread.sleep(forTimeInterval: 2.2)
        XCTAssertTrue(toast.exists, "无障碍字号下长反馈不应在用户读完前消失")
    }

    func testRepeatedIdenticalWarningRestartsToastLifetime() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result"]
        app.launch()

        waitForText("调整场景", in: app)
        tapSongDetail(in: app)
        tapStableSongAction("锁定", in: app)
        waitForText("取消锁定", in: app)
        tapStableSongAction("移除", in: app)

        let toast = app.descendants(matching: .any)["floating-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 2.4)
        tapStableSongAction("移除", in: app)
        Thread.sleep(forTimeInterval: 2.0)

        XCTAssertTrue(toast.exists, "重复警告应从最后一次触发重新计算展示时间")
        XCTAssertEqual(toast.value as? String, "警告")
    }

    func testOlderToastTaskCannotClearANewerRepeatedMessage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result"]
        app.launch()

        waitForText("调整场景", in: app)
        tapSongDetail(in: app)
        tapStableSongAction("锁定", in: app)
        waitForText("取消锁定", in: app)
        tapStableSongAction("移除", in: app)

        let toast = app.descendants(matching: .any)["floating-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.4)
        let copyButton = songActionButton("复制", in: app)
        XCTAssertTrue(scrollToHittable(copyButton, in: app, scrollDirection: .down))
        copyButton.tap()
        waitForText("已复制到剪贴板", in: app)
        Thread.sleep(forTimeInterval: 0.2)
        tapStableSongAction("移除", in: app)
        waitForText("《稻香》已锁定，请先取消锁定再移除。", in: app)
        Thread.sleep(forTimeInterval: 3.0)

        XCTAssertTrue(toast.exists, "旧提示的计时任务不能提前清除新一轮同文案警告")
        XCTAssertEqual(toast.value as? String, "警告")
    }

    func testLongWarningUsesMultipleLinesAtStandardTextSize() throws {
        let app = XCUIApplication()
        let longTitle = "这是一首用于验证常规字号警告完整展示的超长歌曲名称特别加长现场版"
        app.launchArguments = [
            "-singreadyStage", "result",
            "-singreadyLongLockedTrackTitle"
        ]
        app.launch()

        waitForText("调整场景", in: app)
        let detailButton = app.buttons["详情《\(longTitle)》"]
        XCTAssertTrue(scrollToHittable(detailButton, in: app))
        detailButton.tap()
        XCTAssertTrue(app.buttons["取消锁定《\(longTitle)》"].waitForExistence(timeout: 4))
        let removeLabel = "移除《\(longTitle)》并补位"
        let removeButton = app.buttons[removeLabel]
        XCTAssertTrue(scrollToHittable(removeButton, in: app))
        app.swipeUp()
        let centeredRemoveButton = app.buttons[removeLabel]
        XCTAssertTrue(waitForStableHittableFrame(centeredRemoveButton))
        centeredRemoveButton.tap()

        let toast = app.descendants(matching: .any)["floating-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 8))
        XCTAssertTrue(toast.label.contains(longTitle))
        XCTAssertEqual(toast.value as? String, "警告")
        XCTAssertGreaterThan(toast.frame.height, 42, "常规字号的长警告也应多行自适应")
        XCTAssertLessThanOrEqual(toast.frame.width, app.windows.firstMatch.frame.width - 32)
    }

    func testSuccessToastRemainsCompactAtStandardTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result"]
        app.launch()

        waitForText("调整场景", in: app)
        tapSongDetail(in: app)
        let copyButton = songActionButton("复制", in: app)
        XCTAssertTrue(scrollToHittable(copyButton, in: app))
        copyButton.tap()

        let toast = app.descendants(matching: .any)["floating-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 8))
        XCTAssertEqual(toast.value as? String, "成功")
        XCTAssertLessThanOrEqual(toast.frame.height, 44, "短成功提示应保持紧凑")
    }

    func testCandidateShortageNoticeIsVisibleOnResultPage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result", "-singreadyShortPlanNotice"]
        app.launch()

        let notice = app.staticTexts["song-plan-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 8))
        XCTAssertTrue(notice.label.contains("候选不足目标 12 首"))
    }

    func testExistingRemovalUndoSurvivesRejectedLockedRemoval() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result"]
        app.launch()

        waitForText("调整场景", in: app)
        let firstDetail = app.buttons["详情《稻香》"]
        XCTAssertTrue(scrollToHittable(firstDetail, in: app))
        firstDetail.tap()
        let firstRemoval = app.buttons["移除《稻香》并补位"]
        XCTAssertTrue(
            scrollToHittable(firstRemoval, in: app),
            "详情展开后应能滚动到移除按钮"
        )
        XCTAssertTrue(
            waitForStableHittableFrame(firstRemoval),
            "详情展开后应等待移除按钮完成布局再交互"
        )
        firstRemoval.tap()
        waitForText("已移除《稻香》", in: app)
        XCTAssertTrue(app.buttons["撤销移除"].exists)

        let nextDetail = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "详情《")
        ).firstMatch
        XCTAssertTrue(scrollToHittable(nextDetail, in: app, scrollDirection: .down))
        let nextDetailLabel = nextDetail.label
        XCTAssertTrue(nextDetailLabel.hasPrefix("详情《") && nextDetailLabel.hasSuffix("》"))
        let nextTitle = String(nextDetailLabel.dropFirst("详情《".count).dropLast())
        nextDetail.tap()

        let lockButton = app.buttons["锁定《\(nextTitle)》"]
        XCTAssertTrue(scrollToHittable(lockButton, in: app))
        lockButton.tap()
        XCTAssertTrue(app.buttons["取消锁定《\(nextTitle)》"].waitForExistence(timeout: 4))

        let lockedRemoval = app.buttons["移除《\(nextTitle)》并补位"]
        XCTAssertTrue(scrollToHittable(lockedRemoval, in: app))
        XCTAssertTrue(waitForStableHittableFrame(lockedRemoval))
        lockedRemoval.tap()

        waitForText("《\(nextTitle)》已锁定，请先取消锁定再移除。", in: app)
        XCTAssertTrue(app.buttons["撤销移除"].exists)
        app.buttons["撤销移除"].tap()
        waitForText("稻香", in: app)
    }

    func testInteractiveControlsMeetMinimumTouchTarget() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result"]
        app.launch()

        waitForText("调整场景", in: app)
        assertMinimumTouchTarget(songActionButton("锁定", in: app))
        let detailLabel = NSPredicate(format: "label BEGINSWITH %@", "详情")
        assertMinimumTouchTarget(app.buttons.matching(detailLabel).firstMatch)
        let detailButtons = app.buttons.matching(detailLabel).allElementsBoundByIndex
        XCTAssertGreaterThan(detailButtons.count, 1)
        let detailContexts = detailButtons.map(\.label)
        XCTAssertTrue(
            detailContexts.allSatisfy { $0.hasPrefix("详情《") },
            "每个详情按钮都应包含歌曲上下文，实际标签：\(detailContexts)"
        )
        XCTAssertEqual(Set(detailContexts).count, detailContexts.count, "多首歌的详情按钮应能被辅助功能区分")

        tapSongDetail(in: app)
        let likeButton = app.buttons["喜欢"].firstMatch
        XCTAssertTrue(scrollToHittable(likeButton, in: app))
        assertMinimumTouchTarget(likeButton)
        waitForText("移除", in: app)
        assertMinimumTouchTarget(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "移除")).firstMatch)

        app.terminate()

        let scenarioApp = XCUIApplication()
        scenarioApp.launchArguments = ["-singreadyStage", "scenario"]
        scenarioApp.launch()
        waitForText("排今晚歌单", in: scenarioApp)
        waitForText("想唱多难", in: scenarioApp)
        tapButton("稳妥", in: scenarioApp)
        assertMinimumTouchTarget(scenarioApp.buttons["稳妥"].firstMatch)
    }

    func testSongPlanCardsAvoidRawScores() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result"]
        app.launch()

        waitForText("调整场景", in: app)
        XCTAssertFalse(app.staticTexts["84"].exists)
        XCTAssertFalse(app.staticTexts["81"].exists)
        let qualitativeBadge = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["很适合", "适合唱", "可备选"])
        ).firstMatch
        XCTAssertTrue(waitForElement(qualitativeBadge, in: app), "歌曲卡片应显示定性结论，而不是裸分数")
    }

    func testResultSummaryUsesSelectedScenarioCopy() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result"]
        app.launch()

        waitForText("朋友局歌单", in: app)
        waitForText("朋友局先唱大家熟的", in: app)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "这份歌单里")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "出现较多")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "适合车载 K 歌")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "高光")).firstMatch.exists)
    }

    func testImportReviewAvoidsParserConfidenceCopy() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "review"]
        app.launch()

        waitForText("先看一眼歌名", in: app)
        XCTAssertFalse(app.staticTexts["100%"].exists)
        XCTAssertFalse(app.staticTexts["待确认"].exists)
        waitForText("共 12 首 · 建议看 0 首 · 缺歌名 0 首", in: app)
        waitForText("歌名都整理好了，可以直接批量匹配", in: app)
    }

    func testImportReviewRequiresEveryActiveSongToHaveATitle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "review"]
        app.launch()

        tapButton("查看全部歌曲", in: app)
        let firstTitle = app.textFields["编辑歌名"].firstMatch
        XCTAssertTrue(firstTitle.waitForExistence(timeout: 8))
        firstTitle.tap()
        let existingTitle = firstTitle.value as? String ?? ""
        firstTitle.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingTitle.count))

        waitForText("歌名不能为空，补上后才能继续。", in: app)
        waitForText("补歌名", in: app)
        XCTAssertFalse(app.buttons["开始批量匹配"].firstMatch.isEnabled)

        let deleteButton = app.buttons["删除未命名歌曲"].firstMatch
        XCTAssertTrue(deleteButton.exists)
        deleteButton.tap()
        waitForText("已删《未命名歌曲》", in: app)
    }

    func testImportPasteButtonRequiresText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "importHub"]
        app.launch()

        let pasteButton = app.buttons["整理这段歌单"]
        XCTAssertTrue(waitForElement(pasteButton, in: app))
        XCTAssertFalse(pasteButton.isEnabled)
        XCTAssertFalse(app.staticTexts["先选你现在想做的事"].exists)
    }

    func testImportPasteButtonEnablesAfterText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "importHub"]
        app.launch()

        let textView = app.textViews["粘贴歌单文本"]
        XCTAssertTrue(waitForElement(textView, in: app))
        textView.tap()
        app.typeText("晴天 - 周杰伦\n稻香 - 周杰伦")

        let pasteButton = app.buttons["整理这段歌单"]
        XCTAssertTrue(pasteButton.exists)
        XCTAssertTrue(pasteButton.isEnabled)
    }

    func testQQMusicURLShowsActionableRecoveryWithoutHanging() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "importHub"]
        app.launch()

        let textView = app.textViews["粘贴歌单文本"]
        XCTAssertTrue(waitForElement(textView, in: app))
        textView.tap()
        app.typeText("https://y.qq.com/n/ryqq/playlist/1374105607")

        tapButton("整理这段歌单", in: app)

        let recoveryFeedback = app.staticTexts[
            "QQ 音乐公开链接不能直接读取；请分享/粘贴歌名文字或发截图"
        ].firstMatch
        XCTAssertTrue(
            recoveryFeedback.waitForExistence(timeout: 5),
            "QQ 音乐公开链接应快速返回可操作的恢复说明"
        )
        XCTAssertTrue(
            scrollToHittable(recoveryFeedback, in: app, timeout: 5),
            "恢复说明应在页面上可见"
        )

        let pasteButton = app.buttons["整理这段歌单"]
        let controlsDeadline = Date().addingTimeInterval(5)
        while (!textView.isHittable || !pasteButton.isHittable) && Date() < controlsDeadline {
            app.swipeDown()
        }
        XCTAssertTrue(textView.isEnabled && textView.isHittable, "输入区应恢复可操作")
        XCTAssertTrue(pasteButton.isEnabled && pasteButton.isHittable, "整理按钮应恢复可操作")
    }

    func testPastedImportDismissesKeyboardAndKeepsProgressVisible() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "importHub", "-singreadySlowImport"]
        app.launch()

        let textView = app.textViews["粘贴歌单文本"]
        XCTAssertTrue(waitForElement(textView, in: app))
        textView.tap()
        app.typeText("晴天 - 周杰伦\n稻香 - 周杰伦")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))

        tapButton("整理这段歌单", in: app)

        let keyboardDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: keyboard
        )
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardDismissed], timeout: 3), .completed)
        let progress = app.staticTexts["正在整理歌单"]
        XCTAssertTrue(progress.waitForExistence(timeout: 3))
        XCTAssertTrue(progress.isHittable, "粘贴导入的进度应在按钮附近直接可见")
    }

    func testRecentImportSurvivesRelaunchAndCanBeReopened() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "importHub"]
        app.launch()

        tapButton("用示例歌单", in: app)
        waitForText("先看一眼歌名", in: app)
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launchArguments = ["-singreadyStage", "importHub"]
        relaunched.launch()

        waitForText("周末朋友局常听", in: relaunched)
        let recent = relaunched.buttons["reopen-recent-53494E47-5245-4144-8000-000000000001"]
        XCTAssertTrue(waitForElement(recent, in: relaunched))
        XCTAssertEqual(recent.value as? String, "热门歌单，12 首")
        recent.tap()
        waitForText("先看一眼歌名", in: relaunched)
        waitForText("晴天", in: relaunched)
    }

    func testGeneratedPlanSurvivesRelaunchAndHomeOffersResumeActions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result"]
        app.launch()

        waitForText("朋友局歌单", in: app)
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launch()

        waitForText("朋友局歌单", in: relaunched)
        XCTAssertTrue(relaunched.buttons["继续调整今晚歌单"].waitForExistence(timeout: 8))
        XCTAssertTrue(relaunched.buttons["直接发给朋友"].exists)
        XCTAssertTrue(relaunched.buttons["查看开唱小抄"].exists)

        relaunched.buttons["继续调整今晚歌单"].tap()
        waitForText("调整场景", in: relaunched)
    }

    func testReviewedEditsReplaceTheRecentPlaylistSnapshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "review"]
        app.launch()

        tapButton("查看全部歌曲", in: app)
        let firstTitle = app.textFields["编辑歌名"].firstMatch
        XCTAssertTrue(firstTitle.waitForExistence(timeout: 8))
        firstTitle.tap()
        firstTitle.typeText("现场版")
        tapButton("删除稻香", in: app)
        tapButton("开始批量匹配", in: app)
        XCTAssertTrue(app.navigationBars["核对参考匹配"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any)["matching-progress"].exists)
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launchArguments = ["-singreadyStage", "importHub"]
        relaunched.launch()

        let recent = relaunched.buttons["reopen-recent-53494E47-5245-4144-8000-000000000001"]
        XCTAssertTrue(waitForElement(recent, in: relaunched))
        XCTAssertEqual(recent.value as? String, "热门歌单，11 首")
        recent.tap()
        waitForText("先看一眼歌名", in: relaunched)
        tapButton("查看全部歌曲", in: relaunched)
        XCTAssertEqual(relaunched.textFields["编辑歌名"].firstMatch.value as? String, "晴天现场版")
        XCTAssertFalse(relaunched.buttons["删除稻香"].exists)
    }

    func testUnfinishedReviewEditSurvivesColdRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "review"]
        app.launch()

        tapButton("查看全部歌曲", in: app)
        let firstTitle = app.textFields["编辑歌名"].firstMatch
        XCTAssertTrue(firstTitle.waitForExistence(timeout: 8))
        firstTitle.tap()
        firstTitle.typeText("待核对")
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launch()

        XCTAssertTrue(relaunched.buttons["继续整理这份歌单"].waitForExistence(timeout: 8))
        relaunched.buttons["继续整理这份歌单"].tap()
        waitForText("先看一眼歌名", in: relaunched)
        tapButton("查看全部歌曲", in: relaunched)
        XCTAssertEqual(relaunched.textFields["编辑歌名"].firstMatch.value as? String, "晴天待核对")
    }

    func testEditingAReviewedPlanInvalidatesStaleDownstreamResults() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result"]
        app.launch()
        waitForText("朋友局歌单", in: app)

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开整理歌单"].tap()
        tapButton("查看全部歌曲", in: app)
        let firstTitle = app.textFields["编辑歌名"].firstMatch
        XCTAssertTrue(firstTitle.waitForExistence(timeout: 8))
        firstTitle.tap()
        firstTitle.typeText("新版本")

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开首页"].tap()
        XCTAssertTrue(app.buttons["继续整理这份歌单"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["继续调整今晚歌单"].exists)
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["继续整理这份歌单"].waitForExistence(timeout: 8))
        XCTAssertFalse(relaunched.buttons["继续调整今晚歌单"].exists)
    }

    func testChangingScenarioInvalidatesOldPlanUntilRegenerated() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "result",
            "-singreadyDelayPlanGeneration"
        ]
        app.launch()
        waitForText("朋友局歌单", in: app)

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开排今晚歌单"].tap()
        tapButton("选择情侣局", in: app)
        app.buttons["打开功能菜单"].tap()
        app.buttons["打开今晚歌单"].tap()

        XCTAssertTrue(app.otherElements["stale-plan-banner"].waitForExistence(timeout: 8))
        waitForText("朋友局歌单", in: app)
        XCTAssertFalse(app.buttons["发给朋友"].exists)

        app.buttons["按最新选择重排"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["plan-generation-progress"]
                .waitForExistence(timeout: 8)
        )
        waitForText("情侣局歌单", in: app, timeout: 12)
        XCTAssertFalse(app.otherElements["stale-plan-banner"].exists)
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["继续调整今晚歌单"].waitForExistence(timeout: 8))
    }

    func testColdRelaunchDoesNotRestoreInFlightPlanAsReady() throws {
        let app = launchReadyPlanAndBeginReplan()
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launch()

        assertRestoredPlanNeedsRegeneration(in: relaunched)
    }

    func testColdRelaunchDoesNotRestoreCancelledPlanAsReady() throws {
        let app = launchReadyPlanAndBeginReplan()
        tapButton("取消重排", in: app)
        XCTAssertTrue(app.buttons["按最新选择重排"].waitForExistence(timeout: 8))
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launch()

        assertRestoredPlanNeedsRegeneration(in: relaunched)
    }

    func testClearLocalDataCancelsInFlightImportWithoutResurrection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "importHub", "-singreadySlowImport"]
        app.launch()

        let textView = app.textViews["粘贴歌单文本"]
        XCTAssertTrue(waitForElement(textView, in: app))
        textView.tap()
        app.typeText("晴天 - 周杰伦\n稻香 - 周杰伦")
        tapButton("整理这段歌单", in: app)
        waitForText("正在整理这段歌单", in: app)

        let clearButton = app.buttons["清除本机记录"]
        XCTAssertTrue(waitForElement(clearButton, in: app))
        clearButton.tap()
        XCTAssertTrue(app.buttons["全部清除"].waitForExistence(timeout: 8))
        app.buttons["全部清除"].tap()
        waitForText("本机记录已清除", in: app)
        Thread.sleep(forTimeInterval: 3)

        XCTAssertFalse(app.staticTexts["先看一眼歌名"].exists)
        XCTAssertFalse(app.buttons["继续调整今晚歌单"].exists)
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launch()
        waitForText("先做哪件事", in: relaunched)
        XCTAssertFalse(relaunched.buttons["继续整理这份歌单"].exists)
        XCTAssertFalse(relaunched.buttons["继续调整今晚歌单"].exists)
    }

    func testSlowImportDisablesRecentReopenToPreventLateReplacement() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "review", "-singreadySlowImport"]
        app.launch()
        waitForText("先看一眼歌名", in: app)

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开导入歌单"].tap()
        let textView = app.textViews["粘贴歌单文本"]
        XCTAssertTrue(waitForElement(textView, in: app))
        textView.tap()
        app.typeText("海阔天空 - Beyond")
        tapButton("整理这段歌单", in: app)
        waitForText("正在整理这段歌单", in: app)

        let recent = app.buttons.matching(identifier: "重新打开周末朋友局常听").firstMatch
        XCTAssertTrue(waitForElement(recent, in: app))
        XCTAssertFalse(recent.isEnabled, "在途导入完成前不应允许打开最近歌单")

        let deleteRecent = app.buttons.matching(identifier: "删除最近导入周末朋友局常听").firstMatch
        XCTAssertTrue(waitForElement(deleteRecent, in: app))
        XCTAssertFalse(deleteRecent.isEnabled, "在途导入完成前不应允许删除最近歌单")
    }

    func testCancellingAnImportKeepsCurrentPlanAndHistory() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result", "-singreadySlowImport"]
        app.launch()
        waitForText("朋友局歌单", in: app)

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开导入歌单"].tap()
        let textView = app.textViews["粘贴歌单文本"]
        XCTAssertTrue(waitForElement(textView, in: app))
        textView.tap()
        app.typeText("晴天 - 周杰伦\n稻香 - 周杰伦")
        tapButton("整理这段歌单", in: app)
        waitForText("正在整理这段歌单", in: app)

        let cancelButton = app.buttons["取消本次导入"]
        XCTAssertTrue(waitForElement(cancelButton, in: app, scrollDirection: .down))
        cancelButton.tap()
        waitForText("已取消本次导入", in: app)

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开首页"].tap()
        XCTAssertTrue(app.buttons["继续调整今晚歌单"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["直接发给朋友"].exists)
    }

    func testLeavingAndReturningDoesNotCommitAnOldImportRequest() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "importHub", "-singreadySlowImport"]
        app.launch()

        let textView = app.textViews["粘贴歌单文本"]
        XCTAssertTrue(waitForElement(textView, in: app))
        textView.tap()
        app.typeText("晴天 - 周杰伦\n稻香 - 周杰伦")
        tapButton("整理这段歌单", in: app)
        waitForText("正在整理这段歌单", in: app)

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开首页"].tap()
        waitForText("先做哪件事", in: app)
        tapButton("导入歌单", in: app)
        waitForText("先把歌单放进来", in: app)
        XCTAssertFalse(app.staticTexts["正在整理这段歌单"].exists)

        Thread.sleep(forTimeInterval: 13)
        XCTAssertTrue(app.staticTexts["先把歌单放进来"].exists)
        XCTAssertFalse(app.staticTexts["先看一眼歌名"].exists)
        XCTAssertFalse(app.buttons["继续整理这份歌单"].exists)
    }

    func testImportTimeoutReturnsToRetryableStateWithoutLateCommit() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "importHub",
            "-singreadySlowImport",
            "-singreadyShortImportTimeout"
        ]
        app.launch()

        let textView = app.textViews["粘贴歌单文本"]
        XCTAssertTrue(waitForElement(textView, in: app))
        textView.tap()
        app.typeText("晴天 - 周杰伦\n稻香 - 周杰伦")
        tapButton("整理这段歌单", in: app)
        waitForText("处理时间太久，已取消", in: app)
        XCTAssertFalse(app.buttons["取消本次导入"].exists)
        XCTAssertEqual(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "处理时间太久，已取消")
            ).count,
            1,
            "同一导入错误不应在状态文字和错误提示中重复出现"
        )

        Thread.sleep(forTimeInterval: 13)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "处理时间太久，已取消")
        ).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["先看一眼歌名"].exists)
    }

    func testBackgroundPersistenceCannotSupersedeInFlightImport() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result", "-singreadySlowImport"]
        app.launch()
        waitForText("朋友局歌单", in: app)

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开导入歌单"].tap()
        let textView = app.textViews["粘贴歌单文本"]
        XCTAssertTrue(waitForElement(textView, in: app))
        textView.tap()
        app.typeText("晴天 - 周杰伦\n稻香 - 周杰伦")
        tapButton("整理这段歌单", in: app)
        waitForText("正在整理这段歌单", in: app)

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()

        waitForText("先看一眼歌名", in: app, timeout: 18)
        XCTAssertFalse(app.buttons["继续调整今晚歌单"].exists)
    }

    func testCommittedImportLocksNavigationUntilReviewIsReady() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "importHub",
            "-singreadyDelayImportedWorkflowFinalization"
        ]
        app.launch()

        let textView = app.textViews["粘贴歌单文本"]
        XCTAssertTrue(waitForElement(textView, in: app))
        textView.tap()
        app.typeText("晴天 - 周杰伦\n稻香 - 周杰伦")
        tapButton("整理这段歌单", in: app)

        waitForText("正在保存新歌单", in: app)
        XCTAssertFalse(app.buttons["取消本次导入"].exists)
        let stageMenu = app.buttons["打开功能菜单"]
        XCTAssertTrue(stageMenu.exists)
        XCTAssertFalse(stageMenu.isEnabled)
        let screenEdge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let dragTarget = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        screenEdge.press(forDuration: 0.1, thenDragTo: dragTarget)
        XCTAssertTrue(app.staticTexts["正在保存新歌单"].exists)
        XCTAssertFalse(stageMenu.isEnabled)

        waitForText("先看一眼歌名", in: app, timeout: 12)
    }

    func testCompletedImportCannotBeOverwrittenByLateTimeout() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "importHub",
            "-singreadyShortImportTimeout",
            "-singreadyDelayWorkflowCompletion"
        ]
        app.launch()

        let textView = app.textViews["粘贴歌单文本"]
        XCTAssertTrue(waitForElement(textView, in: app))
        textView.tap()
        app.typeText("晴天 - 周杰伦\n稻香 - 周杰伦")
        tapButton("整理这段歌单", in: app)
        waitForText("先看一眼歌名", in: app)

        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.descendants(matching: .any)["global-error-banner"].exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "处理时间太久，已取消")
        ).firstMatch.exists)
    }

    func testRecentImportCanBeDeletedAfterConfirmation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "review"]
        app.launch()
        waitForText("先看一眼歌名", in: app)

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开导入歌单"].tap()
        waitForText("最近导入", in: app)

        let recentButtons = app.buttons.matching(identifier: "重新打开周末朋友局常听")
        let countBeforeDeletion = recentButtons.count
        XCTAssertGreaterThan(countBeforeDeletion, 0)
        tapButton("删除最近导入周末朋友局常听", in: app)
        XCTAssertTrue(app.buttons["删除记录"].waitForExistence(timeout: 8))
        app.buttons["删除记录"].tap()

        let countDecreased = expectation(
            for: NSPredicate { _, _ in recentButtons.count == countBeforeDeletion - 1 },
            evaluatedWith: recentButtons
        )
        wait(for: [countDecreased], timeout: 8)
    }

    func testPendingShareCanBeDeletedAfterConfirmation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "importHub", "-singreadySeedPendingImport"]
        app.launch()

        let deleteButton = app.buttons["删除待整理测试分享"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 8))
        deleteButton.tap()
        XCTAssertTrue(app.buttons["删除内容"].waitForExistence(timeout: 8))
        app.buttons["删除内容"].tap()

        XCTAssertTrue(deleteButton.waitForNonExistence(timeout: 8))
    }

    func testPendingShareSurvivesWhenNeitherRecoveryStoreCanSave() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "importHub",
            "-singreadySeedPendingImport",
            "-singreadyFailRecoverableImportPersistence"
        ]
        app.launch()

        let importButton = app.buttons["整理测试分享"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 8))
        importButton.tap()
        waitForText("待整理内容已保留，请稍后重试", in: app)
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launchArguments = ["-singreadyStage", "importHub"]
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["整理测试分享"].waitForExistence(timeout: 8))

        let deleteButton = relaunched.buttons["删除待整理测试分享"]
        deleteButton.tap()
        XCTAssertTrue(relaunched.buttons["删除内容"].waitForExistence(timeout: 8))
        relaunched.buttons["删除内容"].tap()
        XCTAssertTrue(deleteButton.waitForNonExistence(timeout: 8))
    }

    func testClearLocalRecordsCanCancelThenRemoveCurrentPlanAndHistory() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result"]
        app.launch()
        waitForText("朋友局歌单", in: app)

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开导入歌单"].tap()
        waitForText("最近导入", in: app)

        tapButton("清除本机记录", in: app)
        waitForText("最近一次实测音区", in: app)
        waitForText("临时导出文件", in: app)
        let cancelButton = app.buttons
            .matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"]))
            .firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 8))
        cancelButton.tap()
        XCTAssertTrue(app.buttons["重新打开周末朋友局常听"].exists)

        tapButton("清除本机记录", in: app)
        XCTAssertTrue(app.buttons["全部清除"].waitForExistence(timeout: 8))
        waitForText("最近一次实测音区", in: app)
        app.buttons["全部清除"].tap()
        waitForText("用过的歌单会放在这里", in: app)
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launch()
        waitForText("先做哪件事", in: relaunched)
        XCTAssertFalse(relaunched.staticTexts["朋友局歌单"].exists)
        XCTAssertFalse(relaunched.buttons["继续调整今晚歌单"].exists)
    }

    func testReviewDeleteCanUndoAndMeetsTouchTarget() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "review"]
        app.launch()

        tapButton("查看全部歌曲", in: app)
        let deleteButton = app.buttons["删除晴天"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 8))
        assertMinimumTouchTarget(deleteButton)
        deleteButton.tap()

        waitForText("已删《晴天》", in: app)
        tapButton("撤销删除", in: app)
        waitForText("晴天", in: app)
    }

    func testDeletingEveryReviewSongShowsRecoverableEmptyState() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "review",
            "-singreadySingleReviewSong"
        ]
        app.launch()

        tapButton("查看全部歌曲", in: app)
        let deleteButton = app.buttons["删除晴天"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 8))
        deleteButton.tap()

        waitForText("歌单里的歌都删掉了", in: app)
        XCTAssertTrue(app.buttons["重新导入歌单"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["撤销删除"].exists)
        XCTAssertFalse(app.buttons["开始批量匹配"].exists)

        app.buttons["撤销删除"].tap()
        waitForText("晴天", in: app)
        XCTAssertTrue(app.buttons["开始批量匹配"].exists)
    }

    func testVoiceResultUsesResultCopy() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "voiceResult"]
        app.launch()

        waitForText("先按常见范围排", in: app)
        waitForText("常见音域参考", in: app)
        waitForText("参考范围", in: app)
        XCTAssertFalse(app.staticTexts["你的音域"].exists)
        XCTAssertFalse(app.staticTexts["这次结果"].exists)
        XCTAssertFalse(app.staticTexts["够不够用"].exists)
        XCTAssertFalse(app.staticTexts["参考程度"].exists)
        XCTAssertFalse(app.staticTexts["唱 10 秒就行"].exists)
    }

    func testScenarioHasSingleGenerateAction() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "scenario"]
        app.launch()

        waitForText("排今晚歌单", in: app)
        waitForText("先唱大家熟的", in: app)
        waitForText("想唱多难", in: app)
        waitForText("合唱多少", in: app)
        let generateButtons = app.buttons.matching(NSPredicate(format: "label == %@", "排一份今晚歌单"))
        XCTAssertEqual(generateButtons.count, 1)
        tapButton("排一份今晚歌单", in: app)
        waitForText("调整场景", in: app)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "段安排")).firstMatch.exists)
        XCTAssertFalse(app.buttons["就按这样排"].exists)
    }

    func testGeneratingFromImportedReviewKeepsTheImportedPlaylistContext() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "review"]
        app.launch()

        waitForText("先看一眼歌名", in: app)
        app.buttons["打开功能菜单"].tap()
        let scenarioButton = app.buttons["打开排今晚歌单"]
        XCTAssertTrue(scenarioButton.waitForExistence(timeout: 8))
        scenarioButton.tap()

        waitForText("按今晚的局来排", in: app)
        tapButton("排一份今晚歌单", in: app)
        waitForText("朋友局歌单", in: app)
        let inputSource = app.descendants(matching: .any)["song-plan-input-source"]
        XCTAssertTrue(inputSource.waitForExistence(timeout: 8))
        XCTAssertEqual(inputSource.value as? String, "示例歌单")
    }

    func testScenarioControlsExposeSelectionAndMinuteValue() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "scenario"]
        app.launch()

        let friends = app.buttons["选择朋友局"]
        XCTAssertTrue(friends.waitForExistence(timeout: 8))
        XCTAssertTrue(friends.isSelected)

        let slider = app.sliders["时长"]
        XCTAssertTrue(waitForElement(slider, in: app))
        XCTAssertTrue((slider.value as? String)?.contains("分钟") == true)
    }

    func testSoloAndCouplesScenariosExposeFixedPeopleCountsWithoutStepper() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "scenario"]
        app.launch()

        let solo = app.buttons["选择独自练歌"]
        XCTAssertTrue(scrollToHittable(solo, in: app))
        solo.tap()

        let fixedCount = app.descendants(matching: .any)["scenario-fixed-people-count"]
        XCTAssertTrue(waitForElement(fixedCount, in: app))
        XCTAssertEqual(fixedCount.label, "人数 1")
        XCTAssertFalse(app.descendants(matching: .any)["scenario-people-stepper"].exists)

        let couples = app.buttons["选择情侣局"]
        XCTAssertTrue(scrollToHittable(couples, in: app))
        couples.tap()

        XCTAssertEqual(fixedCount.label, "人数 2")
        XCTAssertFalse(app.descendants(matching: .any)["scenario-people-stepper"].exists)
    }

    func testSwitchingFromSoloToGroupScenarioRestoresTwoPersonMinimum() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "scenario"]
        app.launch()

        let solo = app.buttons["选择独自练歌"]
        XCTAssertTrue(scrollToHittable(solo, in: app))
        solo.tap()

        let friends = app.buttons["选择朋友局"]
        XCTAssertTrue(scrollToHittable(friends, in: app))
        friends.tap()

        let peopleStepper = app.descendants(matching: .any)["scenario-people-stepper"]
        XCTAssertTrue(waitForElement(peopleStepper, in: app))
        XCTAssertTrue(peopleStepper.label.contains("人数 2"))
    }

    func testCarScenarioKeepsDriverSafetyNoticeVisibleThroughResult() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "scenario"]
        app.launch()

        tapButton("选择车载 K 歌", in: app)
        let scenarioNotice = app.descendants(matching: .any)["car-safety-notice"]
        XCTAssertTrue(waitForElement(scenarioNotice, in: app))
        XCTAssertTrue(scenarioNotice.label.contains("驾驶者不操作手机"))
        XCTAssertTrue(scenarioNotice.label.contains("乘客操作"))
        XCTAssertTrue(scenarioNotice.label.contains("停车后再操作"))

        tapButton("排一份今晚歌单", in: app)
        waitForText("车载 K 歌歌单", in: app)

        let resultNotice = app.descendants(matching: .any)["car-safety-notice"]
        XCTAssertTrue(waitForElement(resultNotice, in: app))
        XCTAssertTrue(resultNotice.label.contains("驾驶者不操作手机"))
        XCTAssertTrue(resultNotice.label.contains("停车后再操作"))
    }

    func testSoloPracticeHidesGroupSingingControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "scenario"]
        app.launch()

        let solo = app.buttons["选择独自练歌"]
        XCTAssertTrue(scrollToHittable(solo, in: app))
        solo.tap()

        let soloMode = app.descendants(matching: .any)["scenario-solo-practice-mode"]
        XCTAssertTrue(scrollToHittable(soloMode, in: app))
        XCTAssertEqual(soloMode.label, "练唱方式 独自练唱")
        waitForText("按今天的练唱来排", in: app, scrollDirection: .down)
        XCTAssertTrue(app.buttons["排一份练唱单"].exists)
        XCTAssertFalse(app.staticTexts["合唱多少"].exists)
        XCTAssertFalse(app.buttons["合唱"].exists)
        XCTAssertFalse(app.buttons["多合唱"].exists)
    }

    func testSoloPlanUsesPersonalPracticeCopyAcrossHomeAndExport() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "result",
            "-singreadySoloScenario"
        ]
        app.launch()

        waitForText("独自练歌歌单", in: app)
        XCTAssertTrue(app.buttons["保存练唱单"].exists)
        XCTAssertFalse(app.buttons["发给朋友"].exists)
        assertEdgeSwipeBack(reveals: "练唱工具", in: app)
        waitForText("保存练唱单", in: app)
        waitForText("练唱小抄", in: app)
        XCTAssertFalse(app.staticTexts["到了现场"].exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "发群里")
        ).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "冷场")
        ).firstMatch.exists)

        app.buttons["打开功能菜单"].tap()
        XCTAssertTrue(app.buttons["打开保存练唱单"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["打开练唱小抄"].exists)
        XCTAssertFalse(app.buttons["打开发给朋友"].exists)
        app.buttons["完成"].tap()

        tapButton("保存练唱单", in: app)
        waitForText("把练唱安排留在手边", in: app)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "发群里")
        ).firstMatch.exists)
    }

    func testSoloPlanDetailsAvoidGroupOnlyLanguage() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "result",
            "-singreadySoloScenario",
            "-singreadySoloChorusFeedback"
        ]
        app.launch()

        waitForText("独自练歌歌单", in: app)
        XCTAssertFalse(app.staticTexts["适合合唱"].exists)
        XCTAssertTrue(app.staticTexts["喜欢"].exists, "solo 仍应显示适用的历史反馈")

        tapSongDetail(in: app)
        tapButton("为什么放这首", in: app)
        waitForText("练唱节奏", in: app)
        XCTAssertFalse(app.staticTexts["合唱感"].exists)
        XCTAssertFalse(app.buttons["适合合唱"].exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "大家")
        ).firstMatch.exists)
    }

    func testSoloScenarioNavigationUsesPracticeCopy() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "scenario",
            "-singreadySoloScenario"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["排练唱单"].waitForExistence(timeout: 8))
        app.buttons["打开功能菜单"].tap()
        let currentScenario = app.buttons["stage-menu-scenario"]
        XCTAssertTrue(currentScenario.waitForExistence(timeout: 8))
        XCTAssertTrue(currentScenario.isSelected)
        XCTAssertEqual(currentScenario.label, "排练唱单，当前页面")
        XCTAssertFalse(currentScenario.label.contains("排今晚歌单"))
    }

    func testSoloStartTipsUsesPracticeNavigationCopy() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "startTips",
            "-singreadySoloScenario"
        ]
        app.launch()

        waitForText("练唱小抄", in: app)
        waitForText("今晚怎么练", in: app)
        XCTAssertFalse(app.staticTexts["开唱小抄"].exists)
    }

    func testMatchReportWithUnmatchedImportGuidesBackToReview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "review"]
        app.launch()

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开核对参考匹配"].tap()

        waitForText("这份歌单还没完成整理和参考匹配", in: app)
        XCTAssertTrue(app.buttons["先整理这份歌单"].exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "把歌单放进来")
        ).firstMatch.exists)
    }

    func testSongFeedbackDimensionsStayIndependentlySelected() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result"]
        app.launch()

        tapSongDetail(in: app)
        tapButton("锁定", in: app)
        waitForText("取消锁定", in: app)
        for title in ["喜欢", "太高", "不熟"] {
            let button = app.buttons[title].firstMatch
            XCTAssertTrue(scrollToHittable(button, in: app))
            button.tap()
        }

        XCTAssertTrue(app.buttons["喜欢"].firstMatch.isSelected)
        XCTAssertTrue(app.buttons["太高"].firstMatch.isSelected)
        XCTAssertTrue(app.buttons["不熟"].firstMatch.isSelected)
        XCTAssertEqual(app.buttons["喜欢"].firstMatch.value as? String, "已选择")
        XCTAssertEqual(app.buttons["太高"].firstMatch.value as? String, "已选择")
        XCTAssertEqual(app.buttons["不熟"].firstMatch.value as? String, "已选择")

        app.buttons["太高"].firstMatch.tap()

        XCTAssertTrue(app.buttons["喜欢"].firstMatch.isSelected)
        XCTAssertFalse(app.buttons["太高"].firstMatch.isSelected)
        XCTAssertTrue(app.buttons["不熟"].firstMatch.isSelected)
    }

    func testColdLaunchRestoresStalePlanAsReadOnlyUntilRegenerated() throws {
        persistStaleFeedbackSnapshot()

        let relaunched = XCUIApplication()
        relaunched.launch()

        assertHomeReadyOutputsUnavailable(in: relaunched)
        assertStageMenuReadyOutputsUnavailable(in: relaunched)

        let previousPlan = relaunched.buttons["查看上一版"]
        XCTAssertTrue(
            scrollHomeActionBelowNavigationBar(previousPlan, in: relaunched),
            "失效歌单应允许从首页查看上一版"
        )
        previousPlan.tap()

        XCTAssertTrue(
            relaunched.descendants(matching: .any)["stale-plan-banner"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertFalse(relaunched.buttons["发给朋友"].exists)

        tapSongDetail(in: relaunched)
        let collapseDetail = relaunched.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "收起")
        ).firstMatch
        XCTAssertTrue(collapseDetail.waitForExistence(timeout: 8), "上一版歌曲详情应保持可查看")
        XCTAssertFalse(songActionButton("喜欢", in: relaunched).exists)
        XCTAssertFalse(songActionButton("锁定", in: relaunched).exists)
        XCTAssertFalse(songActionButton("移除", in: relaunched).exists)
    }

    func testStandaloneFeedbackTruthRefreshesStaleRestoredPlan() throws {
        persistStaleFeedbackSnapshot()

        let relaunched = XCUIApplication()
        relaunched.launch()

        assertHomeReadyOutputsUnavailable(in: relaunched)
        assertStageMenuReadyOutputsUnavailable(in: relaunched)

        let resume = relaunched.buttons["按最新选择重排"]
        XCTAssertTrue(
            scrollHomeActionBelowNavigationBar(resume, in: relaunched),
            "首页应提供按最新反馈重排的主操作"
        )
        resume.tap()
        waitForText("调整场景", in: relaunched)
        tapSongDetail(in: relaunched)

        let liked = songActionButton("喜欢", in: relaunched)
        let tooHigh = songActionButton("太高", in: relaunched)
        XCTAssertTrue(scrollToHittable(liked, in: relaunched, timeout: 8))
        XCTAssertTrue(scrollToHittable(tooHigh, in: relaunched, timeout: 8))
        XCTAssertEqual(liked.value as? String, "未选择")
        XCTAssertEqual(tooHigh.value as? String, "已选择")
    }

    func testExportPosterUsesShortShareCopy() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "export"]
        app.launch()

        waitForText("发群里更省事", in: app)
        waitForText("朋友局先唱大家熟的", in: app)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "这份歌单里")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "为什么放这首")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "https://")).firstMatch.exists)
    }

    func testStartTipsScrollsThroughAllCards() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "startTips"]
        app.launch()

        waitForText("今晚怎么开场", in: app)
        waitForText("按这份歌单开场", in: app)
        waitForText("现场怎么换", in: app)
        waitForText("发到群里", in: app)
    }

    func testStartTipsUsesCurrentSongPlan() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "startTips"]
        app.launch()

        waitForText("按这份歌单开场", in: app)
        waitForText("今晚先唱", in: app)
        waitForText("稻香", in: app)
    }

    func testMatchReportUsesMainlandChineseLabels() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "matchReport"]
        app.launch()

        waitForText("普通话", in: app)
        XCTAssertFalse(app.staticTexts["Mandarin"].exists)
    }

    func testMatchReportUsesUserFacingConclusionInsteadOfPercentHeadline() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "matchReport"]
        app.launch()

        waitForText("本地参考基本都命中", in: app)
        let matchRateRing = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "本地参考全部命中"))
            .firstMatch
        XCTAssertTrue(matchRateRing.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "KTV 能唱 100%")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["歌名相近"].exists)
        XCTAssertFalse(app.staticTexts["可以替换"].exists)
        XCTAssertFalse(app.staticTexts["暂时没找到"].exists)
        XCTAssertFalse(app.staticTexts["还没加备选歌"].exists)
        XCTAssertFalse(app.staticTexts["再备几首"].exists)
    }

    func testMatchReportShowsPerSongStatesAndConfirmsCandidate() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "matchReport", "-singreadyMixedMatchReview"]
        app.launch()

        let automaticRow = app.descendants(matching: .any)["match-result-00000000-0000-0000-0000-000000000201"]
        let requiredRow = app.descendants(matching: .any)["match-result-00000000-0000-0000-0000-000000000202"]
        let unmatchedRow = app.descendants(matching: .any)["match-result-00000000-0000-0000-0000-000000000203"]
        waitForText("参考命中 1/5", in: app)
        XCTAssertTrue(automaticRow.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForElement(requiredRow, in: app))
        waitForText("晴天", in: app)
        waitForText("喜欢你", in: app)
        waitForText("待确认", in: app)
        waitForText("同名候选：喜欢你 - 邓紫棋", in: app)

        let confirmButton = app.buttons["match-confirm-00000000-0000-0000-0000-000000000202-t029"]
        XCTAssertTrue(scrollToHittable(confirmButton, in: app))
        confirmButton.tap()

        waitForText("已确认", in: app, scrollDirection: .down)
        waitForText("参考命中 2/5", in: app, scrollDirection: .down)
        XCTAssertTrue(waitForElement(unmatchedRow, in: app))
        waitForText("不存在的测试歌名", in: app)
        XCTAssertFalse(app.buttons["match-confirm-00000000-0000-0000-0000-000000000202-t029"].exists)
    }

    func testSavingMatchReviewActionLocksNavigationUntilTheChoiceIsCommitted() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "matchReport",
            "-singreadyMixedMatchReview",
            "-singreadyDelayMatchReviewCommit"
        ]
        app.launch()

        let confirmButton = app.buttons[
            "match-confirm-00000000-0000-0000-0000-000000000202-t029"
        ]
        XCTAssertTrue(scrollToHittable(confirmButton, in: app))
        confirmButton.tap()

        let stageMenu = app.buttons["打开功能菜单"]
        let menuDisabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == false"),
            object: stageMenu
        )
        wait(for: [menuDisabled], timeout: 3)
        let screenEdge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let dragTarget = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        screenEdge.press(forDuration: 0.1, thenDragTo: dragTarget)
        XCTAssertFalse(stageMenu.isEnabled)

        waitForText("已确认", in: app, timeout: 10, scrollDirection: .down)
        XCTAssertFalse(confirmButton.exists)
    }

    func testMatchConfirmationIsDisabledWhileReplanStateIsActive() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "matchReport",
            "-singreadyMixedMatchReview",
            "-singreadyExistingPlanForCandidateLifecycle",
            "-singreadySeedGeneratingPlanState"
        ]
        app.launch()

        let confirmButton = app.buttons[
            "match-confirm-00000000-0000-0000-0000-000000000202-t029"
        ]
        XCTAssertTrue(waitForElement(confirmButton, in: app))
        XCTAssertFalse(confirmButton.isEnabled, "重排状态结束前不能同时提交匹配确认")
    }

    func testMatchConfirmationWaitsForCancelledReplanAndSurvivesRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "matchReport",
            "-singreadyMixedMatchReview",
            "-singreadyExistingPlanForCandidateLifecycle",
            "-singreadyDelayPlanGeneration"
        ]
        app.launch()

        let confirmButton = app.buttons[
            "match-confirm-00000000-0000-0000-0000-000000000202-t029"
        ]
        XCTAssertTrue(waitForElement(confirmButton, in: app))

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开排今晚歌单"].tap()
        tapButton("再排一版", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["plan-generation-progress"]
                .waitForExistence(timeout: 8)
        )

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开核对参考匹配"].tap()
        let cancelledReplanConfirmButton = app.buttons[
            "match-confirm-00000000-0000-0000-0000-000000000202-t029"
        ]
        XCTAssertTrue(waitForElement(cancelledReplanConfirmButton, in: app))

        let confirmationEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: cancelledReplanConfirmButton
        )
        wait(for: [confirmationEnabled], timeout: 8)
        XCTAssertTrue(scrollToHittable(cancelledReplanConfirmButton, in: app))
        cancelledReplanConfirmButton.tap()
        let confirmationCompleted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: cancelledReplanConfirmButton
        )
        wait(for: [confirmationCompleted], timeout: 10)
        waitForText("参考命中 2/5", in: app, timeout: 10, scrollDirection: .down)
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["打开功能菜单"].waitForExistence(timeout: 8))
        relaunched.buttons["打开功能菜单"].tap()
        relaunched.buttons["打开核对参考匹配"].tap()
        waitForText(
            "参考命中 2/5",
            in: relaunched,
            timeout: 12,
            scrollDirection: .down
        )
        XCTAssertFalse(
            relaunched.buttons[
                "match-confirm-00000000-0000-0000-0000-000000000202-t029"
            ].exists
        )
    }

    func testConfirmingMatchKeepsAlreadyLoadedExternalCandidates() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "matchReport",
            "-singreadyMixedMatchReview",
            "-singreadySeedExternalCandidate"
        ]
        app.launch()

        waitForText("已保留 1 首公开备选", in: app)
        let confirmButton = app.buttons["match-confirm-00000000-0000-0000-0000-000000000202-t029"]
        XCTAssertTrue(scrollToHittable(confirmButton, in: app))
        confirmButton.tap()

        waitForText("已确认", in: app, scrollDirection: .down)
        waitForText("已保留 1 首公开备选", in: app, scrollDirection: .down)
    }

    func testMatchReportShowsTrueStatusesAndAdoptsOrdinaryAlternative() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "matchReport", "-singreadyMixedMatchReview"]
        app.launch()

        let fuzzyRow = app.descendants(matching: .any)["match-result-00000000-0000-0000-0000-000000000204"]
        let alternativeRow = app.descendants(matching: .any)["match-result-00000000-0000-0000-0000-000000000205"]
        XCTAssertTrue(waitForElement(fuzzyRow, in: app))
        waitForText("歌名相近", in: app)
        XCTAssertTrue(waitForElement(alternativeRow, in: app))
        waitForText("可替代", in: app)
        waitForText("暂时没找到", in: app)

        let adoptButton = app.buttons["match-adopt-00000000-0000-0000-0000-000000000205-t001"]
        XCTAssertTrue(scrollToHittable(adoptButton, in: app))
        XCTAssertEqual(adoptButton.label, "用这首替换：晴天 - 周杰伦")
        adoptButton.tap()

        waitForText("已采用替代", in: app, scrollDirection: .down)
        let adoptedMetric = app.descendants(matching: .any)["match-metric-adopted-alternative"]
        XCTAssertTrue(waitForElement(adoptedMetric, in: app, scrollDirection: .down))
        XCTAssertEqual(adoptedMetric.label, "已采用替代 1")
        waitForText("已采用替代歌：晴天 - 周杰伦", in: app, scrollDirection: .up)
        waitForText("参考命中 1/5", in: app, scrollDirection: .down)
        XCTAssertFalse(app.buttons["match-adopt-00000000-0000-0000-0000-000000000205-t001"].exists)
    }

    func testExternalCandidateSearchDisclosesAppleDataUseBeforeAction() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "matchReport", "-singreadyMixedMatchReview"]
        app.launch()

        let privacyNote = app.descendants(matching: .any)["external-candidate-privacy-note"]
        let searchButton = app.buttons["external-candidate-search-button"]

        XCTAssertTrue(waitForElement(privacyNote, in: app))
        XCTAssertTrue(scrollToHittable(searchButton, in: app))
        XCTAssertTrue(privacyNote.label.contains("最多 4 首歌"))
        XCTAssertTrue(privacyNote.label.contains("Apple 公开搜索"))
        XCTAssertTrue(privacyNote.label.contains("只发送歌手名称"))
        XCTAssertFalse(privacyNote.label.contains("歌名和歌手发送"))
        XCTAssertTrue(privacyNote.label.contains("不会发送录音或完整歌单"))
        XCTAssertEqual(searchButton.label, "找同歌手备选")
        XCTAssertFalse(app.buttons["补几首相近的"].exists)
    }

    func testLeavingMatchReportCancelsCandidateSearchWithoutInvalidatingExistingPlan() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "matchReport",
            "-singreadyMixedMatchReview",
            "-singreadyExistingPlanForCandidateLifecycle",
            "-singreadySlowExternalCandidateSearch"
        ]
        app.launch()

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开今晚歌单"].tap()
        XCTAssertTrue(app.buttons["调整场景"].waitForExistence(timeout: 8), "测试前置必须已有方案")
        app.buttons["打开功能菜单"].tap()
        app.buttons["打开核对参考匹配"].tap()

        let searchButton = app.buttons["external-candidate-search-button"]
        XCTAssertTrue(scrollToHittable(searchButton, in: app))
        searchButton.tap()
        XCTAssertEqual(searchButton.label, "正在找")
        waitForText("正在通过 Apple 公开搜索找同歌手备选", in: app)
        XCTAssertFalse(app.staticTexts["还没找同歌手备选"].exists)

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开今晚歌单"].tap()
        waitForText("调整场景", in: app)

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开核对参考匹配"].tap()
        let returnedSearchButton = app.buttons["external-candidate-search-button"]
        XCTAssertTrue(scrollToHittable(returnedSearchButton, in: app))
        XCTAssertNotEqual(returnedSearchButton.label, "正在找", "离开匹配页后搜索应立即取消")

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开今晚歌单"].tap()
        XCTAssertTrue(app.buttons["调整场景"].waitForExistence(timeout: 8), "迟到结果不能清空已有方案")
        let emptyPlanState = app.staticTexts["还没有歌单，先按今晚的局排一份。"]
        let unexpectedInvalidation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: emptyPlanState
        )
        unexpectedInvalidation.isInverted = true
        wait(for: [unexpectedInvalidation], timeout: 13)
        XCTAssertTrue(app.buttons["调整场景"].exists, "跨过搜索超时窗口后已有方案仍应保留")
    }

    func testLeavingCandidateSearchForImportDoesNotLeaveSearchingStatusBehind() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "matchReport",
            "-singreadyMixedMatchReview",
            "-singreadySlowExternalCandidateSearch"
        ]
        app.launch()

        let searchButton = app.buttons["external-candidate-search-button"]
        XCTAssertTrue(scrollToHittable(searchButton, in: app))
        searchButton.tap()
        XCTAssertEqual(searchButton.label, "正在找")

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开导入歌单"].tap()
        waitForText("先把歌单放进来", in: app)

        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "正在通过 Apple 公开搜索")
            ).firstMatch.exists,
            "离开核对页后不应在导入页继续显示搜索中"
        )
        XCTAssertTrue(app.buttons["用示例歌单"].isEnabled)
    }

    func testCompletedCandidateResultsSurviveNormalVoiceAndScenarioNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "matchReport",
            "-singreadyMixedMatchReview",
            "-singreadySeedExternalCandidate"
        ]
        app.launch()

        waitForText("已保留 1 首公开备选", in: app)
        let measureButton = app.buttons["match-insights-measure"]
        XCTAssertTrue(scrollToHittable(measureButton, in: app))
        measureButton.tap()
        waitForText("唱 10 秒就行", in: app)

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开核对参考匹配"].tap()
        waitForText("已保留 1 首公开备选", in: app)
        let skipButton = app.buttons["match-insights-skip"]
        XCTAssertTrue(scrollToHittable(skipButton, in: app))
        skipButton.tap()
        waitForText("按今晚的局来排", in: app)

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开核对参考匹配"].tap()
        waitForText("已保留 1 首公开备选", in: app)
    }

    func testNoReferenceInsightsStillOffersBothForwardPaths() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "matchReport", "-singreadyNoReferenceInsights"]
        app.launch()

        let measureButton = app.buttons["match-no-insights-measure"]
        let skipButton = app.buttons["match-no-insights-skip"]
        XCTAssertTrue(scrollToHittable(measureButton, in: app))
        XCTAssertTrue(scrollToHittable(skipButton, in: app))
        XCTAssertEqual(measureButton.label, "测一下音区")
        XCTAssertEqual(skipButton.label, "先不测，去选场景")

        skipButton.tap()
        waitForText("按今晚的局来排", in: app)
    }

    func testReferenceInsightsAlsoOfferSkipToScenario() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "matchReport"]
        app.launch()

        let measureButton = app.buttons["match-insights-measure"]
        let skipButton = app.buttons["match-insights-skip"]
        XCTAssertTrue(scrollToHittable(measureButton, in: app))
        XCTAssertTrue(scrollToHittable(skipButton, in: app))
        XCTAssertEqual(measureButton.label, "测一下音域")
        XCTAssertEqual(skipButton.label, "先不测，去选场景")

        skipButton.tap()
        waitForText("按今晚的局来排", in: app)
    }

    func testHomeResumeKeepsExplicitAdvancePastUnresolvedMatchesAfterRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "matchReport",
            "-singreadyMixedMatchReview"
        ]
        app.launch()

        let skipButton = app.buttons["match-insights-skip"]
        XCTAssertTrue(scrollToHittable(skipButton, in: app))
        skipButton.tap()
        waitForText("按今晚的局来排", in: app)

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开首页"].tap()
        XCTAssertTrue(app.buttons["继续排今晚歌单"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["继续核对参考匹配"].exists)

        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["继续排今晚歌单"].waitForExistence(timeout: 8))
        XCTAssertFalse(relaunched.buttons["继续核对参考匹配"].exists)
    }

    func testHomeResumeKeepsDirectScenarioAdvanceAfterAutomaticMatching() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "review"]
        app.launch()

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开排今晚歌单"].tap()
        waitForText("按今晚的局来排", in: app)
        tapButton("排一份今晚歌单", in: app)
        waitForText("朋友局歌单", in: app, timeout: 12)

        assertEdgeSwipeBack(reveals: "按今晚的局来排", in: app)
        tapButton("有挑战", in: app)
        app.buttons["打开功能菜单"].tap()
        app.buttons["打开首页"].tap()
        XCTAssertTrue(app.buttons["按最新选择重排"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["继续核对参考匹配"].exists)

        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["按最新选择重排"].waitForExistence(timeout: 8))
        XCTAssertFalse(relaunched.buttons["继续核对参考匹配"].exists)
    }

    func testSkippingNewMeasurementKeepsExistingMeasuredVoice() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "matchReport",
            "-singreadyMeasuredVoiceBeforeMatch"
        ]
        app.launch()

        let skipButton = app.buttons["match-insights-skip"]
        XCTAssertTrue(scrollToHittable(skipButton, in: app))
        skipButton.tap()
        waitForText("按今晚的局来排", in: app)

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开测一下音域"].tap()
        waitForText("本次音区大概这样", in: app)
    }

    func testEmptyMatchCopyClearlyRefersToSongs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "home"]
        app.launch()

        tapButton("核对参考匹配", in: app)
        waitForText("逐首核对本地参考命中和待确认候选", in: app)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "哪些 KTV 好点")).firstMatch.exists)
    }

    func testVoiceGuideUsesNaturalMainlandChinese() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "voiceSetup"]
        app.launch()

        waitForText("不用唱完整", in: app)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "清唱得很完整")).firstMatch.exists)
    }

    func testVoiceResultHasOneForwardAction() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "voiceResult"]
        app.launch()

        waitForText("先按常见范围排", in: app)
        XCTAssertFalse(app.buttons["用这个范围"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "去排今晚歌单")).count, 1)
    }

    func testMicrophoneDeniedOffersSettingsAndFallback() throws {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .microphone)
        app.launchArguments = ["-singreadyStage", "voiceSetup"]

        app.launch()
        tapButton("开始录音", in: app)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = springboard.buttons.matching(
            NSPredicate(format: "label IN %@", ["不允许", "Don't Allow"])
        ).firstMatch
        XCTAssertTrue(deny.waitForExistence(timeout: 8), "Microphone denial button is missing")
        deny.tap()
        waitForText("没开麦克风权限", in: app)
        XCTAssertTrue(app.buttons["打开系统设置"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["先不测"].exists)
    }

    func testFirstMicrophoneGrantContinuesPastPermissionRequest() throws {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .microphone)
        app.launchArguments = ["-singreadyStage", "voiceSetup"]

        addUIInterruptionMonitor(withDescription: "麦克风权限") { alert in
            let allow = alert.buttons.matching(
                NSPredicate(format: "label IN %@", ["允许", "Allow", "Allow While Using App"])
            ).firstMatch
            guard allow.exists else { return false }
            allow.tap()
            return true
        }

        app.launch()
        tapButton("开始录音", in: app)
        app.tap()
        let progressed = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "录音中", "这次没录好")
        ).firstMatch
        XCTAssertTrue(progressed.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "正在打开麦克风")
        ).firstMatch.exists)
    }

    func testChangingVoiceMeasurementInvalidatesOldPlanUntilRegenerated() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result", "-singreadySimulatedRecording"]
        app.launch()
        waitForText("朋友局歌单", in: app)

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开测一下音域"].tap()
        tapButton("重新测一下", in: app)
        waitForText("本次音区大概这样", in: app, timeout: 8)

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开首页"].tap()
        XCTAssertTrue(app.buttons["按最新选择重排"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["继续调整今晚歌单"].exists)

        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["按最新选择重排"].waitForExistence(timeout: 8))
        XCTAssertFalse(relaunched.buttons["继续调整今晚歌单"].exists)
    }

    func testDelayedVoiceRestoreKeepsReadyOutputsClosedUntilPlanBecomesStale() throws {
        persistMeasuredVoiceAgainstReadyPlanSnapshot()

        let relaunched = XCUIApplication()
        relaunched.launchArguments = ["-singreadyDelayVoiceProfileRestoreRace"]
        relaunched.launch()

        XCTAssertFalse(relaunched.buttons["直接发给朋友"].exists)
        XCTAssertFalse(relaunched.buttons["查看开唱小抄"].exists)
        assertStageMenuReadyOutputsUnavailableWithoutScrolling(in: relaunched)

        XCTAssertTrue(
            relaunched.buttons["按最新选择重排"].waitForExistence(timeout: 12),
            "实测音域恢复完成后，旧歌单应明确转为待重排"
        )
        assertHomeReadyOutputsUnavailable(in: relaunched)
        XCTAssertFalse(relaunched.buttons["继续调整今晚歌单"].exists)
        XCTAssertFalse(relaunched.buttons["直接发给朋友"].exists)
    }

    func testStandaloneMeasuredVoiceSurvivesColdRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "importHub", "-singreadySimulatedRecording"]
        app.launch()

        tapButton("清除本机记录", in: app)
        XCTAssertTrue(app.buttons["全部清除"].waitForExistence(timeout: 8))
        app.buttons["全部清除"].tap()
        waitForText("本机记录已清除", in: app, scrollDirection: .down)

        app.buttons["打开功能菜单"].tap()
        app.buttons["打开测一下音域"].tap()
        waitForText("原始录音不保存，最近一次有效实测音区结果仅保存在本机", in: app)
        tapButton("开始录音", in: app)
        waitForText("本次音区大概这样", in: app, timeout: 8)
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["打开功能菜单"].waitForExistence(timeout: 8))
        relaunched.buttons["打开功能菜单"].tap()
        relaunched.buttons["打开测一下音域"].tap()

        waitForText("本次音区大概这样", in: relaunched, timeout: 8)
        waitForText("本次唱到的音区", in: relaunched)

        relaunched.buttons["打开功能菜单"].tap()
        relaunched.buttons["打开导入歌单"].tap()
        tapButton("清除本机记录", in: relaunched)
        XCTAssertTrue(relaunched.buttons["全部清除"].waitForExistence(timeout: 8))
        relaunched.buttons["全部清除"].tap()
        waitForText("本机记录已清除", in: relaunched, scrollDirection: .down)
    }

    func testClearingDuringColdVoiceRestoreCannotResurrectMeasuredVoice() throws {
        let seed = XCUIApplication()
        seed.launchArguments = ["-singreadyStage", "importHub", "-singreadySimulatedRecording"]
        seed.launch()

        tapButton("清除本机记录", in: seed)
        XCTAssertTrue(seed.buttons["全部清除"].waitForExistence(timeout: 8))
        seed.buttons["全部清除"].tap()
        waitForText("本机记录已清除", in: seed, scrollDirection: .down)
        seed.buttons["打开功能菜单"].tap()
        seed.buttons["打开测一下音域"].tap()
        tapButton("开始录音", in: seed)
        waitForText("本次音区大概这样", in: seed, timeout: 8)
        seed.terminate()

        let clearing = XCUIApplication()
        clearing.launchArguments = [
            "-singreadyStage", "importHub",
            "-singreadyDelayVoiceProfileRestoreRace"
        ]
        clearing.launch()
        tapButton("清除本机记录", in: clearing)
        XCTAssertTrue(clearing.buttons["全部清除"].waitForExistence(timeout: 8))
        clearing.buttons["全部清除"].tap()
        waitForText("本机记录已清除", in: clearing, timeout: 12, scrollDirection: .down)

        clearing.buttons["打开功能菜单"].tap()
        clearing.buttons["打开测一下音域"].tap()
        let resurrectedResult = clearing.staticTexts["本次音区大概这样"]
        let lateRestore = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: resurrectedResult
        )
        lateRestore.isInverted = true
        wait(for: [lateRestore], timeout: 4)
        XCTAssertTrue(clearing.buttons["开始录音"].exists)

        clearing.terminate()
        let relaunched = XCUIApplication()
        relaunched.launch()
        relaunched.buttons["打开功能菜单"].tap()
        relaunched.buttons["打开测一下音域"].tap()
        XCTAssertTrue(relaunched.buttons["开始录音"].waitForExistence(timeout: 8))
        XCTAssertFalse(relaunched.staticTexts["本次音区大概这样"].exists)
    }

    func testCandidateSetChangeDoesNotInvalidateFormalPlan() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result", "-singreadyCandidateChangeAfterPlan"]
        app.launch()

        waitForText("朋友局歌单", in: app)
        XCTAssertTrue(app.buttons["发给朋友"].exists)
        app.buttons["打开功能菜单"].tap()
        app.buttons["打开首页"].tap()
        XCTAssertTrue(app.buttons["继续调整今晚歌单"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["按最新选择重排"].exists)

        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["继续调整今晚歌单"].waitForExistence(timeout: 8))
        XCTAssertFalse(relaunched.buttons["按最新选择重排"].exists)
    }

    func testLeavingVoicePageCancelsRecordingWithoutReopeningIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "voiceSetup", "-singreadySimulatedRecording"]

        app.launch()
        tapButton("开始录音", in: app)
        waitForText("录音中", in: app)

        let labeledBack = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["返回", "Back"])).firstMatch
        let backButton = labeledBack.exists ? labeledBack : app.navigationBars.buttons.firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 8))
        backButton.tap()
        waitForText("先做哪件事", in: app)
        Thread.sleep(forTimeInterval: 3)

        XCTAssertTrue(app.staticTexts["先做哪件事"].exists)
        XCTAssertFalse(app.staticTexts["先按常见范围排"].exists)
    }

    func testRecordingBusyStateOnlyOffersCancelAndFallbackCannotBeOverwritten() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "voiceSetup", "-singreadySimulatedRecording"]

        app.launch()
        tapButton("开始录音", in: app)
        waitForText("录音中", in: app)

        XCTAssertTrue(app.buttons["取消录音"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["开始录音"].exists)
        XCTAssertFalse(app.buttons["先不测"].exists)

        app.buttons["取消录音"].tap()
        tapButton("先不测", in: app)
        waitForText("先按常见范围排", in: app)
        Thread.sleep(forTimeInterval: 3)

        XCTAssertTrue(app.staticTexts["先按常见范围排"].exists)
        XCTAssertFalse(app.staticTexts["本次音区大概这样"].exists)
    }

    func testRemeasuringExistingVoiceHidesForwardActionUntilCancelled() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "voiceResult", "-singreadySimulatedRecording"]

        app.launch()
        waitForText("先按常见范围排", in: app)
        tapButton("重新测一下", in: app)
        waitForText("录音中", in: app)

        XCTAssertTrue(app.buttons["取消录音"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["重新测一下"].exists)
        XCTAssertFalse(app.buttons["去排今晚歌单"].exists)

        app.buttons["取消录音"].tap()

        waitForText("先按常见范围排", in: app)
        XCTAssertTrue(app.buttons["重新测一下"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["去排今晚歌单"].exists)
    }

    func testPosterPermissionDeniedOffersSettingsAndShareFallback() throws {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launchArguments = ["-singreadyStage", "export"]

        addUIInterruptionMonitor(withDescription: "相册权限") { alert in
            let deny = alert.buttons.matching(NSPredicate(format: "label IN %@", ["不允许", "Don't Allow"])).firstMatch
            guard deny.exists else { return false }
            deny.tap()
            return true
        }

        app.launch()
        tapButton("保存海报", in: app)
        app.tap()
        waitForText("请允许添加到相册", in: app)
        let warningToast = app.descendants(matching: .any)["floating-toast"]
        XCTAssertTrue(warningToast.waitForExistence(timeout: 8))
        XCTAssertEqual(warningToast.value as? String, "警告")
        XCTAssertTrue(app.buttons["打开系统设置"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["发给朋友"].exists)
    }

    func testCarPlanSummaryUsesNaturalMainlandChinese() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "scenario"]
        app.launch()

        tapButton("选择车载 K 歌", in: app)
        tapButton("排一份今晚歌单", in: app)
        waitForText("车里适合轻松一点", in: app)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "轻松顺序")).firstMatch.exists)
    }

    func testRemovedSongCanBeRestored() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result"]
        app.launch()

        waitForText("调整场景", in: app)
        tapSongDetail(in: app)
        waitForText("移除", in: app)
        let firstTitle = app.staticTexts["稻香"]
        XCTAssertTrue(firstTitle.exists)

        tapButton("移除", in: app)
        waitForText("已移除《稻香》", in: app)
        tapButton("撤销移除", in: app)
        waitForText("稻香", in: app)
    }

    func testRemovedSongCanBeManagedAfterRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "result"]
        app.launch()

        waitForText("调整场景", in: app)
        tapSongDetail(in: app)
        tapButton("移除", in: app)
        waitForText("已移除歌曲", in: app)
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["继续调整今晚歌单"].waitForExistence(timeout: 8))
        relaunched.buttons["继续调整今晚歌单"].tap()
        waitForText("已移除歌曲", in: relaunched)
        tapButton("恢复《稻香》", in: relaunched)
        XCTAssertTrue(relaunched.descendants(matching: .any)["removed-tracks-management"].waitForNonExistence(timeout: 8))
    }

    func testEveryFeaturePageCanReachItsLowerContent() throws {
        let cases: [(stage: String, expectedText: String)] = [
            ("home", "只处理你主动导入的内容"),
            ("importHub", "链接认不出来时"),
            ("review", "不确定的歌名先留给你看一眼"),
            ("matchReport", "想排得更贴自己"),
            ("voiceSetup", "不评价唱得好不好"),
            ("voiceResult", "连续高强度摇滚"),
            ("scenario", "排一份今晚歌单"),
            ("result", "收尾大合唱"),
            ("export", "看开唱小抄"),
            ("startTips", "遇到不熟的歌")
        ]

        for testCase in cases {
            let app = XCUIApplication()
            app.launchArguments = ["-singreadyStage", testCase.stage]
            app.launch()
            waitForText(testCase.expectedText, in: app, timeout: 35)
            app.terminate()
        }
    }

    func testPhotoPickerCanOpenAndClose() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "importHub"]
        app.launch()

        tapButton("选择截图识别歌单", in: app)
        let cancelButton = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 8), "Photo picker did not open")
        cancelButton.tap()
        waitForText("选一种方式", in: app)
    }

    func testShareSheetCanOpenAndClose() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "export"]
        app.launch()

        tapButton("发给朋友", in: app)
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 8), "Share sheet did not open")
        app.otherElements["PopoverDismissRegion"].tap()
        XCTAssertTrue(shareSheet.waitForNonExistence(timeout: 8), "Share sheet did not close")
        waitForText("发群里更省事", in: app)
    }

    func testShareExtensionReceivesSharedPlaylist() throws {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let sharedURL = try XCTUnwrap(URL(string: "https://music.apple.com/us/playlist/%E5%96%9C%E7%88%B1%E6%AD%8C%E6%9B%B2/pl.u-vvUz36Y7Lv?l=zh"))
        safari.terminate()
        safari.open(sharedURL)

        let shareButton = safari.buttons.matching(
            NSPredicate(
                format: "identifier == %@ OR label IN %@",
                "ShareButton",
                ["分享", "共享", "Share"]
            )
        ).firstMatch
        if !shareButton.waitForExistence(timeout: 3) {
            let moreMenu = safari.buttons["MoreMenuButton"]
            XCTAssertTrue(moreMenu.waitForExistence(timeout: 8), "Safari More menu is missing")
            moreMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(shareButton.waitForExistence(timeout: 12), "Safari share button is missing")
        shareButton.tap()

        let extensionCell = safari.cells.matching(NSPredicate(format: "label == %@", "今晚唱什么")).firstMatch
        let activityRow = safari.scrollViews.containing(.cell, identifier: "shareCell").firstMatch
        XCTAssertTrue(activityRow.waitForExistence(timeout: 8), "Share activity row did not open")
        for _ in 0..<6 where !extensionCell.exists {
            activityRow.swipeLeft()
        }
        if !extensionCell.exists {
            let moreCell = safari.cells.matching(
                NSPredicate(format: "label IN %@", ["更多", "More"])
            ).firstMatch
            XCTAssertTrue(moreCell.waitForExistence(timeout: 8), "Share activity More button is missing")
            moreCell.tap()
            let extensionTitle = safari.staticTexts["今晚唱什么"]
            XCTAssertTrue(extensionTitle.waitForExistence(timeout: 8), "Share extension is missing from the activity list")
            extensionTitle.tap()
        } else {
            extensionCell.tap()
        }

        waitForText("歌单已收到", in: safari, timeout: 12)
        XCTAssertTrue(safari.buttons["完成"].waitForExistence(timeout: 8))
        safari.buttons["完成"].tap()

        let app = XCUIApplication()
        app.launchArguments = ["-singreadyStage", "importHub"]
        app.launch()
        waitForText("选一种方式", in: app)
        let sharedImport = app.buttons["整理Apple Music"]
        XCTAssertTrue(
            sharedImport.waitForExistence(timeout: 12),
            "分享成功后待整理内容应出现在导入页顶部"
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "music.apple.com")).firstMatch.exists,
            "待整理内容应保留 Apple Music 链接"
        )
    }

    func testColdLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            let app = XCUIApplication()
            app.launchArguments = ["-singreadyStage", "home"]
            app.launch()
            XCTAssertTrue(app.staticTexts["先做哪件事"].waitForExistence(timeout: 8))
            app.terminate()
        }
    }

    private func assertHomeReadyOutputsUnavailable(in app: XCUIApplication) {
        waitForText("先做哪件事", in: app)

        let export = app.buttons["发给朋友"]
        XCTAssertTrue(waitForElement(export, in: app), "首页应保留发给朋友入口")
        XCTAssertFalse(export.isEnabled, "没有可用歌单时，发给朋友入口必须关闭")

        let startTips = app.buttons["开唱小抄"]
        XCTAssertTrue(waitForElement(startTips, in: app), "首页应保留开唱小抄入口")
        XCTAssertFalse(startTips.isEnabled, "没有可用歌单时，开唱小抄入口必须关闭")

        waitForText("排好当前歌单后可用", in: app)
    }

    private func assertStageMenuReadyOutputsUnavailable(in app: XCUIApplication) {
        let menu = app.buttons["打开功能菜单"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()

        let export = app.buttons["stage-menu-export"]
        XCTAssertTrue(waitForElement(export, in: app), "功能菜单应保留发给朋友入口")
        XCTAssertFalse(export.isEnabled, "没有可用歌单时，功能菜单不能进入发给朋友")

        let startTips = app.buttons["stage-menu-startTips"]
        XCTAssertTrue(waitForElement(startTips, in: app), "功能菜单应保留开唱小抄入口")
        XCTAssertFalse(startTips.isEnabled, "没有可用歌单时，功能菜单不能进入开唱小抄")

        let done = app.buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        done.tap()
    }

    private func assertStageMenuReadyOutputsUnavailableWithoutScrolling(in app: XCUIApplication) {
        let menu = app.buttons["打开功能菜单"]
        XCTAssertTrue(menu.waitForExistence(timeout: 4))
        menu.tap()

        let export = app.buttons["stage-menu-export"]
        XCTAssertTrue(export.waitForExistence(timeout: 4), "恢复完成前应能确认发给朋友入口已关闭")
        XCTAssertFalse(export.isEnabled)

        let startTips = app.buttons["stage-menu-startTips"]
        XCTAssertTrue(startTips.waitForExistence(timeout: 4), "恢复完成前应能确认开唱小抄入口已关闭")
        XCTAssertFalse(startTips.isEnabled)

        let done = app.buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 4))
        done.tap()
    }

    private func persistStaleFeedbackSnapshot() {
        let seedingApp = XCUIApplication()
        seedingApp.launchArguments = [
            "-singreadyStage", "result",
            "-singreadySeedStaleFeedbackSnapshot"
        ]
        seedingApp.launch()
        waitForText("调整场景", in: seedingApp)
        seedingApp.terminate()
    }

    private func persistMeasuredVoiceAgainstReadyPlanSnapshot() {
        let seedingApp = XCUIApplication()
        seedingApp.launchArguments = [
            "-singreadyStage", "result",
            "-singreadySimulatedRecording"
        ]
        seedingApp.launch()

        waitForText("朋友局歌单", in: seedingApp)
        XCTAssertTrue(seedingApp.buttons["发给朋友"].waitForExistence(timeout: 8))
        seedingApp.buttons["打开功能菜单"].tap()
        let voice = seedingApp.buttons["stage-menu-voice"]
        XCTAssertTrue(waitForElement(voice, in: seedingApp))
        voice.tap()
        tapButton("重新测一下", in: seedingApp)
        waitForText("本次音区大概这样", in: seedingApp, timeout: 8)
        seedingApp.terminate()
    }

    private func launchReadyPlanAndBeginReplan() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-singreadyStage", "result",
            "-singreadyDelayPlanGeneration"
        ]
        app.launch()

        waitForText("朋友局歌单", in: app, timeout: 12)
        XCTAssertTrue(app.buttons["发给朋友"].waitForExistence(timeout: 8))
        app.buttons["打开功能菜单"].tap()
        let scenario = app.buttons["stage-menu-scenario"]
        XCTAssertTrue(waitForElement(scenario, in: app))
        scenario.tap()
        waitForText("按今晚的局来排", in: app)

        tapButton("再排一版", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["plan-generation-progress"]
                .waitForExistence(timeout: 8),
            "重排开始后应立即显示生成进度"
        )
        return app
    }

    private func assertRestoredPlanNeedsRegeneration(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["按最新选择重排"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["继续调整今晚歌单"].exists)
        XCTAssertFalse(app.buttons["直接发给朋友"].exists)
        assertStageMenuReadyOutputsUnavailable(in: app)
    }

    private enum ScrollDirection {
        case up
        case down
    }

    private func waitForText(_ text: String, in app: XCUIApplication, timeout: TimeInterval = 8, scrollDirection: ScrollDirection = .up) {
        if visibleTextOrButton(text, in: app) {
            return
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !visibleTextOrButton(text, in: app) && Date() < deadline {
            switch scrollDirection {
            case .up:
                app.swipeUp()
            case .down:
                app.swipeDown()
            }
            if visibleTextOrButton(text, in: app) {
                return
            }
        }

        XCTAssertTrue(visibleTextOrButton(text, in: app), "Missing \(text)")
    }

    private func visibleTextOrButton(_ text: String, in app: XCUIApplication) -> Bool {
        if app.staticTexts[text].exists || app.buttons[text].exists {
            return true
        }
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return app.staticTexts.matching(predicate).firstMatch.exists ||
            app.buttons.matching(predicate).firstMatch.exists ||
            app.descendants(matching: .any).matching(predicate).firstMatch.exists
    }

    private func tapButton(_ title: String, in app: XCUIApplication, timeout: TimeInterval = 8) {
        let button = songActionButton(title, in: app)
        let deadline = Date().addingTimeInterval(timeout)
        while !button.exists && Date() < deadline {
            app.swipeUp()
        }
        XCTAssertTrue(button.exists, "Missing button \(title)")
        button.tap()
    }

    private func tapStableSongAction(
        _ title: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 8
    ) {
        let button = songActionButton(title, in: app)
        let deadline = Date().addingTimeInterval(timeout)
        while !button.exists && Date() < deadline {
            app.swipeUp()
        }
        XCTAssertTrue(button.exists, "Missing button \(title)")
        XCTAssertTrue(
            scrollToHittable(button, in: app, timeout: min(5, timeout)),
            "Button \(title) could not be scrolled into view"
        )
        XCTAssertTrue(
            waitForStableHittableFrame(button, timeout: min(3, timeout)),
            "Button \(title) did not settle into a hittable frame"
        )
        button.tap()
    }

    private func songActionButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@",
                title,
                "\(title)《"
            )
        ).firstMatch
    }

    private func tapSongDetail(in app: XCUIApplication, timeout: TimeInterval = 8) {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", "详情")
        let button = app.buttons.matching(predicate).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while !button.exists && Date() < deadline {
            app.swipeUp()
        }
        XCTAssertTrue(button.exists, "Missing song detail button")
        button.tap()
    }

    private func waitForElement(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 12,
        scrollDirection: ScrollDirection = .up
    ) -> Bool {
        if element.exists {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !element.exists && Date() < deadline {
            switch scrollDirection {
            case .up:
                app.swipeUp()
            case .down:
                app.swipeDown()
            }
        }
        return element.exists
    }

    private func waitForStableHittableFrame(
        _ element: XCUIElement,
        timeout: TimeInterval = 3,
        requiredStableSamples: Int = 3
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previousFrame: CGRect?
        var stableSamples = 0

        while Date() < deadline {
            guard element.exists, element.isHittable else {
                previousFrame = nil
                stableSamples = 0
                RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.05)))
                continue
            }

            let currentFrame = element.frame
            if let previousFrame,
               abs(previousFrame.minX - currentFrame.minX) < 0.5,
               abs(previousFrame.minY - currentFrame.minY) < 0.5,
               abs(previousFrame.width - currentFrame.width) < 0.5,
               abs(previousFrame.height - currentFrame.height) < 0.5 {
                stableSamples += 1
            } else {
                previousFrame = currentFrame
                stableSamples = 0
            }
            if stableSamples >= requiredStableSamples {
                return true
            }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
        return false
    }

    private func scrollToHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        scrollDirection: ScrollDirection = .up
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while (!element.exists || !element.isHittable) && Date() < deadline {
            switch scrollDirection {
            case .up:
                app.swipeUp()
            case .down:
                app.swipeDown()
            }
        }
        return element.exists && element.isHittable
    }

    private func scrollHomeActionBelowNavigationBar(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 8
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while (!element.exists || !element.isHittable || element.frame.minY < 120),
              Date() < deadline {
            app.swipeDown()
        }
        return element.exists && element.isHittable && element.frame.minY >= 120
    }

    private func edgeSwipeBack(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.50))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.50))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func assertEdgeSwipeBack(reveals text: String, in app: XCUIApplication) {
        let destination = app.staticTexts[text]
        for _ in 0..<2 {
            edgeSwipeBack(in: app)
            if destination.waitForExistence(timeout: 4) {
                return
            }
        }
        XCTFail("Edge swipe did not reveal \(text)")
    }

    private func assertMinimumTouchTarget(_ button: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(button.waitForExistence(timeout: 8), "Missing button \(button)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(button.frame.height, 44, "Touch target is shorter than 44 pt", file: file, line: line)
        XCTAssertGreaterThanOrEqual(button.frame.width, 44, "Touch target is narrower than 44 pt", file: file, line: line)
    }
}
