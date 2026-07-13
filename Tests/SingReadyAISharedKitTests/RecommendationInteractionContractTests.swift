import XCTest
@testable import SingReadyAISharedKit

final class RecommendationInteractionContractTests: XCTestCase {
    func testFeedbackRestorePolicyKeepsStandaloneRecordInsteadOfStaleSnapshot() {
        let staleSnapshot = SongFeedbackProfile(feedbackByTrackID: ["track": [.liked]])

        XCTAssertEqual(
            SongFeedbackRestorePolicy.preferred(
                standalone: .empty,
                snapshot: staleSnapshot
            ),
            .empty,
            "空的独立记录也代表用户已取消或清除反馈，旧快照不能复活它"
        )
    }

    func testFeedbackRestorePolicyMigratesSnapshotOnlyWhenStandaloneRecordIsMissing() {
        let snapshot = SongFeedbackProfile(feedbackByTrackID: ["track": [.liked, .sung]])

        XCTAssertEqual(
            SongFeedbackRestorePolicy.preferred(
                standalone: nil,
                snapshot: snapshot
            ),
            snapshot
        )
    }

    func testFeedbackRestorePolicyRefreshesRestoredPlanWhenStandaloneTruthDiffers() {
        let standalone = SongFeedbackProfile(feedbackByTrackID: ["track": [.tooHigh]])
        let staleSnapshot = SongFeedbackProfile(feedbackByTrackID: ["track": [.liked]])

        XCTAssertTrue(
            SongFeedbackRestorePolicy.shouldRefreshPlan(
                standalone: standalone,
                snapshot: staleSnapshot,
                hasRestoredPlan: true
            )
        )
        XCTAssertFalse(
            SongFeedbackRestorePolicy.shouldRefreshPlan(
                standalone: standalone,
                snapshot: standalone,
                hasRestoredPlan: true
            )
        )
        XCTAssertFalse(
            SongFeedbackRestorePolicy.shouldRefreshPlan(
                standalone: nil,
                snapshot: staleSnapshot,
                hasRestoredPlan: true
            ),
            "缺少独立记录时会直接迁移快照，不需要刷新快照中的歌单"
        )
        XCTAssertFalse(
            SongFeedbackRestorePolicy.shouldRefreshPlan(
                standalone: standalone,
                snapshot: staleSnapshot,
                hasRestoredPlan: false
            )
        )
    }

    func testFeedbackDimensionsCanCoexistAndToggleIndependently() {
        var profile = SongFeedbackProfile.empty

        profile.toggle(trackID: "track", kind: .liked)
        profile.toggle(trackID: "track", kind: .tooHigh)
        profile.toggle(trackID: "track", kind: .unfamiliar)

        XCTAssertEqual(
            Set(profile.feedback(for: "track")),
            Set([.liked, .tooHigh, .unfamiliar])
        )

        profile.toggle(trackID: "track", kind: .tooHigh)

        XCTAssertEqual(
            Set(profile.feedback(for: "track")),
            Set([.liked, .unfamiliar])
        )
    }

    func testFeedbackRecordIsIdempotentWithoutRemovingOtherDimensions() {
        var profile = SongFeedbackProfile(feedbackByTrackID: [
            "track": [.liked, .tooHigh]
        ])

        profile.record(trackID: "track", kind: .liked)
        profile.record(trackID: "track", kind: .unfamiliar)

        XCTAssertEqual(
            Set(profile.feedback(for: "track")),
            Set([.liked, .tooHigh, .unfamiliar])
        )
    }

    func testFeedbackRoundTripAndPlanItemPreserveEverySelectedDimension() throws {
        let feedback = SongFeedbackProfile(feedbackByTrackID: [
            "track": [.liked, .tooHigh, .unfamiliar]
        ])
        let restored = try JSONDecoder().decode(
            SongFeedbackProfile.self,
            from: JSONEncoder().encode(feedback)
        )
        let track = makeTrack()
        let plan = RecommendationEngine().generatePlan(
            matches: [makeMatch(track)],
            preferenceProfile: makeProfile(),
            voiceProfile: .simulatedMiddle,
            scenario: ScenarioConfig(scenario: .friends, peopleCount: 4, durationMinutes: 30),
            catalog: [track],
            inputSource: .userImport,
            feedbackProfile: restored
        )
        let item = try XCTUnwrap(plan.sections.flatMap(\.items).first)

        XCTAssertEqual(
            Set(restored.feedback(for: track.id)),
            Set([.liked, .tooHigh, .unfamiliar])
        )
        XCTAssertEqual(
            Set(item.feedbackTags),
            Set([.liked, .tooHigh, .unfamiliar])
        )
    }

    func testSoloPracticeAndCouplesInitializersUseFixedPeopleCounts() {
        XCTAssertEqual(
            ScenarioConfig(scenario: .soloPractice, peopleCount: 12).peopleCount,
            1
        )
        XCTAssertEqual(
            ScenarioConfig(scenario: .couples, peopleCount: 9).peopleCount,
            2
        )
        XCTAssertEqual(
            ScenarioConfig(scenario: .friends, peopleCount: 9).peopleCount,
            9
        )
        XCTAssertEqual(
            ScenarioConfig(scenario: .carKTV, peopleCount: 1).peopleCount,
            2,
            "车载场景至少需要驾驶者与一名负责操作手机的乘客"
        )
    }

    func testChangingScenarioImmediatelyNormalizesFixedPeopleCount() {
        var config = ScenarioConfig(scenario: .friends, peopleCount: 8)

        config.scenario = .soloPractice
        XCTAssertEqual(config.peopleCount, 1)

        config.scenario = .couples
        XCTAssertEqual(config.peopleCount, 2)

        config.scenario = .birthday
        XCTAssertEqual(config.peopleCount, 2, "离开固定人数场景时保留当前人数")
    }

    func testEveryGroupScenarioRequiresAtLeastTwoPeopleAcrossInitializationMutationAndDecoding() throws {
        let groupScenarios = KTVScenario.allCases.filter(\.isGroupScenario)

        for scenario in groupScenarios {
            XCTAssertEqual(
                ScenarioConfig(scenario: scenario, peopleCount: 1).peopleCount,
                2,
                "\(scenario.displayName) 初始化时不应保留单人配置"
            )

            var changed = ScenarioConfig(scenario: .soloPractice)
            changed.scenario = scenario
            XCTAssertEqual(
                changed.peopleCount,
                2,
                "从独自练歌切换到 \(scenario.displayName) 时应恢复多人下限"
            )

            let decoded = try JSONDecoder().decode(
                ScenarioConfig.self,
                from: Data(
                    #"{"scenario":"\#(scenario.rawValue)","peopleCount":1,"durationMinutes":60,"vibe":"balanced","chorusPreference":"balanced","difficultyPreference":"balanced"}"#.utf8
                )
            )
            XCTAssertEqual(
                decoded.peopleCount,
                2,
                "历史单人 \(scenario.displayName) 配置不应恢复"
            )
        }
    }

    func testDecodedFixedPeopleScenariosCannotRestoreInvalidHistoricalCounts() throws {
        let solo = try JSONDecoder().decode(
            ScenarioConfig.self,
            from: Data(#"{"scenario":"soloPractice","peopleCount":16,"durationMinutes":60,"vibe":"balanced","chorusPreference":"balanced","difficultyPreference":"balanced"}"#.utf8)
        )
        let couples = try JSONDecoder().decode(
            ScenarioConfig.self,
            from: Data(#"{"scenario":"couples","peopleCount":1,"durationMinutes":60,"vibe":"balanced","chorusPreference":"balanced","difficultyPreference":"balanced"}"#.utf8)
        )
        let car = try JSONDecoder().decode(
            ScenarioConfig.self,
            from: Data(#"{"scenario":"carKTV","peopleCount":1,"durationMinutes":60,"vibe":"balanced","chorusPreference":"balanced","difficultyPreference":"balanced"}"#.utf8)
        )

        XCTAssertEqual(solo.peopleCount, 1)
        XCTAssertEqual(couples.peopleCount, 2)
        XCTAssertEqual(car.peopleCount, 2)
    }

    func testSoloPracticeNormalizesGroupOnlyPreferences() {
        var config = ScenarioConfig(
            scenario: .soloPractice,
            peopleCount: 8,
            vibe: .chorus,
            chorusPreference: .moreChorus
        )

        XCTAssertEqual(config.peopleCount, 1)
        XCTAssertEqual(config.vibe, .balanced)
        XCTAssertEqual(config.chorusPreference, .moreSolo)

        config.vibe = .chorus
        config.chorusPreference = .moreChorus

        XCTAssertEqual(config.vibe, .balanced)
        XCTAssertEqual(config.chorusPreference, .moreSolo)
    }

    func testChangingToSoloPracticeNormalizesGroupOnlyPreferences() {
        var config = ScenarioConfig(
            scenario: .friends,
            peopleCount: 8,
            vibe: .chorus,
            chorusPreference: .moreChorus
        )

        config.scenario = .soloPractice

        XCTAssertEqual(config.peopleCount, 1)
        XCTAssertEqual(config.vibe, .balanced)
        XCTAssertEqual(config.chorusPreference, .moreSolo)
    }

    func testDecodedSoloPracticeCannotRestoreGroupOnlyPreferences() throws {
        let config = try JSONDecoder().decode(
            ScenarioConfig.self,
            from: Data(#"{"scenario":"soloPractice","peopleCount":16,"durationMinutes":60,"vibe":"chorus","chorusPreference":"moreChorus","difficultyPreference":"balanced"}"#.utf8)
        )

        XCTAssertEqual(config.peopleCount, 1)
        XCTAssertEqual(config.vibe, .balanced)
        XCTAssertEqual(config.chorusPreference, .moreSolo)
    }

    func testMoreSoloPreferenceRaisesSoloFriendlySceneFitInGroupScenarios() throws {
        let soloFriendly = makeTrack(
            id: "solo-friendly",
            singAlongScore: 0.55,
            duetFriendly: false
        )
        let chorusFriendly = makeTrack(
            id: "chorus-friendly",
            singAlongScore: 0.92,
            duetFriendly: true
        )
        let matches = [makeMatch(soloFriendly), makeMatch(chorusFriendly)]
        let engine = RecommendationEngine()
        let balanced = engine.generatePlan(
            matches: matches,
            preferenceProfile: makeProfile(),
            voiceProfile: .simulatedMiddle,
            scenario: ScenarioConfig(scenario: .friends, durationMinutes: 30),
            catalog: [soloFriendly, chorusFriendly]
        )
        let moreSolo = engine.generatePlan(
            matches: matches,
            preferenceProfile: makeProfile(),
            voiceProfile: .simulatedMiddle,
            scenario: ScenarioConfig(
                scenario: .friends,
                durationMinutes: 30,
                chorusPreference: .moreSolo
            ),
            catalog: [soloFriendly, chorusFriendly]
        )

        let balancedItem = try XCTUnwrap(
            balanced.sections.flatMap(\.items).first { $0.track.id == soloFriendly.id }
        )
        let moreSoloItem = try XCTUnwrap(
            moreSolo.sections.flatMap(\.items).first { $0.track.id == soloFriendly.id }
        )

        XCTAssertGreaterThan(
            moreSoloItem.scoreBreakdown.sceneFitScore,
            balancedItem.scoreBreakdown.sceneFitScore
        )
    }

    func testSoloRecommendationCopyAvoidsGroupAndVenueLanguage() {
        let track = makeTrack(
            id: "solo-copy",
            singAlongScore: 0.92,
            duetFriendly: false,
            energy: 0.82,
            rapDensity: 0.65
        )
        let builder = RecommendationReasonBuilder()
        let scenario = ScenarioConfig(scenario: .soloPractice)
        let visibleCopy = (
            builder.reasons(
                for: track,
                preferenceProfile: makeProfile(),
                voiceProfile: .simulatedMiddle,
                scenario: scenario,
                importedArtistCounts: [:]
            )
            + builder.riskWarnings(
                for: track,
                voiceProfile: .simulatedMiddle,
                scenario: scenario
            )
        ).joined(separator: "\n")

        for forbidden in ["合唱", "现场", "冷场", "大家"] {
            XCTAssertFalse(visibleCopy.contains(forbidden), "独自练歌不应出现\(forbidden)：\(visibleCopy)")
        }
        XCTAssertTrue(visibleCopy.contains("练"))
        XCTAssertTrue(visibleCopy.contains("熟悉节奏"))
    }

    private func makeTrack(
        id: String = "track",
        singAlongScore: Double = 0.82,
        duetFriendly: Bool = false,
        energy: Double = 0.7,
        rapDensity: Double = 0.05
    ) -> KTVTrack {
        KTVTrack(
            id: id,
            title: "测试歌",
            artist: "测试歌手",
            language: "Mandarin",
            era: "2000s",
            genre: "华语流行",
            moodTags: ["温暖"],
            sceneTags: ["friends"],
            difficulty: 2,
            vocalRangeLowMidi: 50,
            vocalRangeHighMidi: 66,
            energy: energy,
            singAlongScore: singAlongScore,
            ktvAvailability: 0.9,
            duetFriendly: duetFriendly,
            rapDensity: rapDensity,
            highNoteRisk: 0.2,
            aliases: [],
            similarSongIds: []
        )
    }

    private func makeMatch(_ track: KTVTrack) -> MatchResult {
        MatchResult(
            importedSong: ImportedSong(
                title: track.title,
                artist: track.artist,
                source: .plainText,
                confidence: 1
            ),
            matchedTrack: track,
            alternatives: [],
            status: .exact,
            score: 1,
            reason: "测试匹配"
        )
    }

    private func makeProfile() -> PreferenceProfile {
        PreferenceProfile(
            topArtists: [],
            languageDistribution: ["Mandarin": 1],
            eraDistribution: ["2000s": 1],
            genreDistribution: ["华语流行": 1],
            moodTags: ["温暖": 1],
            sceneAffinity: ["friends": 1],
            ktvMatchRate: 1,
            averageDifficulty: 2,
            averageSingAlongScore: 0.82,
            highNoteRisk: 0.2,
            summary: "测试画像"
        )
    }
}
