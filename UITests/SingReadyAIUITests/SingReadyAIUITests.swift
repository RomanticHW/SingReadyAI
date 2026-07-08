import XCTest

final class SingReadyAIUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testScreenshotsForCriticalFlow() throws {
        let cases: [(name: String, arguments: [String], expectedText: String)] = [
            ("01_onboarding", ["-singreadyResetOnboarding"], "下一页"),
            ("02_import_hub", ["-singreadyStage", "importHub"], "导入方式"),
            ("03_import_review", ["-singreadyStage", "review"], "先确认"),
            ("04_match_report", ["-singreadyStage", "matchReport"], "可唱率"),
            ("05_voice_setup", ["-singreadyStage", "voiceSetup"], "录音分析"),
            ("06_voice_result", ["-singreadyStage", "voiceResult"], "模拟声线"),
            ("07_scenario_builder", ["-singreadyStage", "scenario"], "场景策划"),
            ("08_song_plan_result", ["-singreadyStage", "result"], "重新生成"),
            ("09_export_center", ["-singreadyStage", "export"], "导出中心"),
            ("10_interview_mode", ["-singreadyStage", "interview"], "Interview Mode")
        ]

        for testCase in cases {
            let app = XCUIApplication()
            app.launchArguments = testCase.arguments
            app.launch()

            let predicate = NSPredicate(format: "label CONTAINS %@", testCase.expectedText)
            let expected = app.descendants(matching: .any).matching(predicate).firstMatch
            XCTAssertTrue(expected.waitForExistence(timeout: 8), "Missing \(testCase.expectedText) in \(testCase.name)")

            let window = app.windows.firstMatch
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = testCase.name
            attachment.lifetime = .keepAlways
            add(attachment)

            app.terminate()
        }
    }
}
