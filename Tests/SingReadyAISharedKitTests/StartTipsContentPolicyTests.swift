import XCTest
@testable import SingReadyAISharedKit

final class StartTipsContentPolicyTests: XCTestCase {
    func testSoloPracticeCopyNeverGivesGroupInstructions() {
        let content = StartTipsContentPolicy().content(for: makePlan(scenario: .soloPractice))
        let allCopy = content.allVisibleCopy.joined(separator: "\n")

        XCTAssertEqual(content.heroTitle, "今晚怎么练")
        XCTAssertEqual(content.openingTitle, "按这份歌单练")
        XCTAssertEqual(content.fallbackTitle, "状态不对怎么换")
        for forbidden in ["群聊", "群里", "大家", "合唱", "冷场", "开场", "现场"] {
            XCTAssertFalse(allCopy.contains(forbidden), "独自练歌不应出现\(forbidden)：\(allCopy)")
        }
        XCTAssertTrue(allCopy.contains("自己"))
        XCTAssertTrue(allCopy.contains("练"))
    }

    func testCarKTVCopyMakesDriverAndPassengerResponsibilitiesExplicit() {
        let content = StartTipsContentPolicy().content(for: makePlan(scenario: .carKTV))
        let allCopy = content.allVisibleCopy.joined(separator: "\n")

        XCTAssertEqual(content.heroTitle, "路上怎么安全开唱")
        XCTAssertEqual(content.openingTitle, "安全开始")
        XCTAssertEqual(content.fallbackTitle, "路上需要调整时")
        XCTAssertTrue(allCopy.contains("驾驶者不操作手机"))
        XCTAssertTrue(allCopy.contains("由乘客点歌和切歌"))
        XCTAssertFalse(allCopy.contains("驾驶者点歌"))
        XCTAssertFalse(allCopy.contains("边开边"))
    }

    func testCouplesCopyConsistentlyAddressesTwoPeople() {
        let content = StartTipsContentPolicy().content(for: makePlan(scenario: .couples))
        let allCopy = content.allVisibleCopy.joined(separator: "\n")

        XCTAssertTrue(allCopy.contains("两个人") || allCopy.contains("两人"))
        XCTAssertTrue(allCopy.contains("另一位"))
        XCTAssertFalse(allCopy.contains("大家"))
        XCTAssertFalse(allCopy.contains("发到群里"))
    }

    func testGroupScenariosUseTheirActualParticipants() {
        let expectations: [(KTVScenario, String)] = [
            (.friends, "朋友"),
            (.birthday, "寿星"),
            (.teamBuilding, "同事")
        ]

        for (scenario, participant) in expectations {
            let content = StartTipsContentPolicy().content(for: makePlan(scenario: scenario))
            let allCopy = content.allVisibleCopy.joined(separator: "\n")

            XCTAssertTrue(allCopy.contains(participant), "\(scenario.displayName) 应明确提到\(participant)")
            XCTAssertTrue(allCopy.contains("群里"), "\(scenario.displayName) 应提供群体协作指令")
        }
    }

    private func makePlan(scenario: KTVScenario) -> SongPlan {
        let tracks = [
            makeTrack(id: "opening", title: "热身歌", difficulty: 2, singAlong: 0.45),
            makeTrack(id: "together", title: "接唱歌", difficulty: 3, singAlong: 0.92),
            makeTrack(id: "closing", title: "收尾歌", difficulty: 4, singAlong: 0.62)
        ]
        let items = tracks.map {
            SongPlanItem(
                track: $0,
                score: 0.8,
                reasons: ["测试理由"],
                riskWarnings: [],
                alternatives: []
            )
        }
        return SongPlan(
            title: "测试歌单",
            scenario: scenario,
            scenarioConfig: ScenarioConfig(scenario: scenario, peopleCount: 5, durationMinutes: 60),
            sections: [SongPlanSection(title: "测试分段", goal: "测试目标", items: items)]
        )
    }

    private func makeTrack(
        id: String,
        title: String,
        difficulty: Int,
        singAlong: Double
    ) -> KTVTrack {
        KTVTrack(
            id: id,
            title: title,
            artist: "测试歌手",
            language: "Mandarin",
            era: "2010s",
            genre: "华语流行",
            moodTags: ["温暖"],
            sceneTags: KTVScenario.allCases.map(\.rawValue),
            difficulty: difficulty,
            vocalRangeLowMidi: 50,
            vocalRangeHighMidi: 68,
            energy: 0.65,
            singAlongScore: singAlong,
            ktvAvailability: 0.9,
            duetFriendly: true,
            rapDensity: 0.05,
            highNoteRisk: 0.25,
            aliases: [],
            similarSongIds: []
        )
    }
}
