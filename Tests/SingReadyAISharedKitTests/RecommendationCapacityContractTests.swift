import XCTest
@testable import SingReadyAISharedKit

final class RecommendationCapacityContractTests: XCTestCase {
    func testDurationProducesExactFiveMinuteCapacityAndExactQuotas() {
        let catalog = makeCatalog(count: 40)
        let expectedCounts = [
            30: 6,
            45: 9,
            60: 12,
            90: 18,
            120: 24,
            180: 30
        ]

        for duration in expectedCounts.keys.sorted() {
            let plan = makePlan(catalog: catalog, duration: duration)
            let expected = try! XCTUnwrap(expectedCounts[duration])
            let actualQuotas = plan.sections.map(\.items.count)
            let sectionCount = plan.sections.count
            let base = expected / sectionCount
            let remainder = expected % sectionCount
            let expectedQuotas = (0..<sectionCount).map { base + ($0 < remainder ? 1 : 0) }

            XCTAssertEqual(plan.sections.flatMap(\.items).count, expected, "\(duration) 分钟")
            XCTAssertEqual(actualQuotas, expectedQuotas, "\(duration) 分钟的分段配额")
        }
    }

    func testEightLocksExpandThirtyMinutePlanWithoutDroppingAnyLock() {
        let catalog = makeCatalog(count: 20)
        let locks = Set(catalog.prefix(8).map(\.id))

        let plan = makePlan(catalog: catalog, duration: 30, locked: locks)
        let items = plan.sections.flatMap(\.items)

        XCTAssertEqual(items.count, 8)
        XCTAssertEqual(Set(items.filter(\.isLocked).map(\.track.id)), locks)
    }

    func testCarScenarioKeepsLockedTrackEvenWhenItViolatesSectionFiltersAndIsRemoved() {
        var catalog = makeCatalog(count: 12)
        let locked = makeTrack(
            id: "locked-hard-car",
            title: "锁定高难歌",
            artist: "锁定歌手",
            difficulty: 5,
            energy: 0.2,
            singAlong: 0.2,
            highRisk: 0.95,
            sceneTags: []
        )
        catalog.insert(locked, at: 0)

        let plan = makePlan(
            catalog: catalog,
            duration: 30,
            scenario: .carKTV,
            locked: [locked.id],
            removed: [locked.id]
        )

        XCTAssertTrue(plan.sections.flatMap(\.items).contains { $0.track.id == locked.id && $0.isLocked })
        XCTAssertEqual(plan.sections.flatMap(\.items).count, 6)
    }

    func testHardRulesReplaceInsteadOfAppendingAndNeverReplaceLockedItems() {
        let locked = makeTrack(
            id: "locked-non-chorus",
            title: "锁定独唱",
            artist: "锁定歌手",
            singAlong: 0.1,
            sceneTags: ["friends"]
        )
        let catalog = [locked] + makeCatalog(count: 15)

        let plan = makePlan(catalog: catalog, duration: 30, locked: [locked.id])
        let items = plan.sections.flatMap(\.items)

        XCTAssertEqual(items.count, 6)
        XCTAssertTrue(items.contains { $0.track.id == locked.id && $0.isLocked })
    }

    func testBirthdayHardRuleKeepsLocksReplacesOneItemAndKeepsExactCapacity() {
        let locks = (0..<3).map { index in
            makeTrack(
                id: "birthday-lock-\(index)",
                title: "锁定普通歌 \(index)",
                artist: "锁定歌手 \(index)",
                energy: 0.7,
                singAlong: 0.25,
                sceneTags: ["friends"],
                moodTags: ["普通"]
            )
        }
        let fillers = (0..<5).map { index in
            makeTrack(
                id: "birthday-filler-\(index)",
                title: "普通歌 \(index)",
                artist: "普通歌手 \(index)",
                energy: 0.7,
                singAlong: 0.7,
                sceneTags: ["friends"],
                moodTags: ["普通"]
            )
        }
        let birthday = makeTrack(
            id: "birthday-rule",
            title: "生日祝福歌",
            artist: "祝福歌手",
            energy: 0.4,
            singAlong: 0.2,
            sceneTags: ["birthday"],
            moodTags: ["喜庆"]
        )
        let catalog = locks + fillers + [birthday]
        let lockedIDs = Set(locks.map(\.id))

        let plan = makePlan(
            catalog: catalog,
            duration: 30,
            scenario: .birthday,
            locked: lockedIDs
        )
        let items = plan.sections.flatMap(\.items)

        XCTAssertEqual(items.count, 6)
        XCTAssertTrue(items.contains { $0.track.id == birthday.id })
        XCTAssertEqual(Set(items.filter(\.isLocked).map(\.track.id)), lockedIDs)
    }

    func testGroupHardRuleKeepsThirtyPercentChorusWithoutAppendingOrReplacingLock() {
        let locks = (0..<3).map { index in
            makeTrack(
                id: "chorus-lock-\(index)",
                title: "锁定独唱 \(index)",
                artist: "锁定歌手 \(index)",
                singAlong: 0.2,
                moodTags: ["普通"],
                duetFriendly: false
            )
        }
        let fillers = (0..<5).map { index in
            makeTrack(
                id: "chorus-filler-\(index)",
                title: "普通独唱 \(index)",
                artist: "普通歌手 \(index)",
                singAlong: 0.7,
                moodTags: ["普通"],
                duetFriendly: false
            )
        }
        let chorus = (0..<2).map { index in
            makeTrack(
                id: "chorus-rule-\(index)",
                title: "对唱歌 \(index)",
                artist: "对唱歌手 \(index)",
                singAlong: 0.55,
                moodTags: ["普通"],
                duetFriendly: true
            )
        }
        let lockedIDs = Set(locks.map(\.id))

        let plan = makePlan(
            catalog: locks + fillers + chorus,
            duration: 30,
            scenario: .friends,
            locked: lockedIDs
        )
        let items = plan.sections.flatMap(\.items)
        let chorusCount = items.filter { $0.track.singAlongScore >= 0.78 || $0.track.duetFriendly }.count

        XCTAssertEqual(items.count, 6)
        XCTAssertGreaterThanOrEqual(chorusCount, 2)
        XCTAssertEqual(Set(items.filter(\.isLocked).map(\.track.id)), lockedIDs)
    }

    func testAllLockedBirthdayPlanReportsUnsatisfiedHardRuleInsteadOfAppending() {
        let locks = (0..<6).map { index in
            makeTrack(
                id: "all-lock-\(index)",
                title: "锁定普通歌 \(index)",
                artist: "锁定普通歌手 \(index)",
                singAlong: 0.2,
                sceneTags: ["friends"],
                moodTags: ["普通"],
                duetFriendly: false
            )
        }
        let birthday = makeTrack(
            id: "unselected-birthday",
            title: "未选生日歌",
            artist: "生日歌手",
            singAlong: 0.2,
            sceneTags: ["birthday"],
            moodTags: ["喜庆"]
        )

        let plan = makePlan(
            catalog: locks + [birthday],
            duration: 30,
            scenario: .birthday,
            locked: Set(locks.map(\.id))
        )

        XCTAssertEqual(plan.sections.flatMap(\.items).count, 6)
        XCTAssertFalse(plan.sections.flatMap(\.items).contains { $0.track.id == birthday.id })
        XCTAssertTrue(plan.notices.contains { $0.contains("锁定") && $0.contains("生日") && $0.contains("未能") })
    }

    func testSoloPracticeStableAndChallengeSectionsSelectRoleAppropriateTracks() throws {
        let stable = (0..<8).map { index in
            makeTrack(
                id: "stable-\(index)",
                title: "稳定练习 \(index)",
                artist: "稳定歌手 \(index)",
                difficulty: 2,
                singAlong: 0.9,
                highRisk: 0.2,
                moodTags: ["平稳"]
            )
        }
        let challenges = (0..<2).map { index in
            makeTrack(
                id: "challenge-\(index)",
                title: "挑战练习 \(index)",
                artist: "挑战歌手 \(index)",
                difficulty: 4,
                singAlong: 0.5,
                highRisk: 0.65,
                moodTags: ["挑战"]
            )
        }

        let plan = makePlan(
            catalog: stable + challenges,
            duration: 30,
            scenario: .soloPractice
        )
        let stableSection = try XCTUnwrap(plan.sections.first { $0.role == .stablePractice })
        let challengeSection = try XCTUnwrap(plan.sections.first { $0.role == .challengePractice })

        XCTAssertTrue(stableSection.items.allSatisfy { $0.track.difficulty <= 3 && $0.track.highNoteRisk <= 0.55 })
        XCTAssertTrue(challengeSection.items.allSatisfy { $0.track.difficulty >= 3 || $0.track.moodTags.contains("高光") })
    }

    func testSemanticDuplicatesProduceOneStableWinner() {
        let first = makeTrack(id: "first", title: "同一首歌（Live版）", artist: "歌手 A", singAlong: 0.8)
        let duplicate = makeTrack(id: "second", title: "同一首歌", artist: "歌手A", singAlong: 0.8)
        let catalog = [first, duplicate]

        let firstPlan = makePlan(catalog: catalog, duration: 30)
        let secondPlan = makePlan(catalog: catalog, duration: 30)
        let firstIDs = firstPlan.sections.flatMap(\.items).map(\.track.id)
        let secondIDs = secondPlan.sections.flatMap(\.items).map(\.track.id)

        XCTAssertEqual(firstIDs, secondIDs)
        XCTAssertEqual(firstIDs.filter { $0 == first.id || $0 == duplicate.id }.count, 1)
        XCTAssertTrue(firstIDs.contains(first.id))
    }

    func testCandidateShortageEncodesAVisiblePlanNotice() throws {
        let catalog = makeCatalog(count: 4)

        let plan = makePlan(catalog: catalog, duration: 60)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any]
        )
        let notices = try XCTUnwrap(object["notices"] as? [String])

        XCTAssertEqual(plan.sections.flatMap(\.items).count, 4)
        XCTAssertEqual(plan.sections.map(\.items.count), [1, 1, 1, 1, 0])
        XCTAssertTrue(notices.contains { $0.contains("4") && $0.contains("12") && $0.contains("不足") })
    }

    func testLockOverflowEncodesDurationNotice() throws {
        let catalog = makeCatalog(count: 10)
        let locks = Set(catalog.prefix(8).map(\.id))

        let plan = makePlan(catalog: catalog, duration: 30, locked: locks)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any]
        )
        let notices = try XCTUnwrap(object["notices"] as? [String])

        XCTAssertTrue(notices.contains { $0.contains("锁定") && $0.contains("8") && $0.contains("30") })
    }

    func testScenarioSectionsEncodeTypedRolesIncludingSoloPracticeRoles() throws {
        let plan = makePlan(catalog: makeCatalog(count: 20), duration: 60, scenario: .soloPractice)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any]
        )
        let sections = try XCTUnwrap(object["sections"] as? [[String: Any]])
        let roleByTitle = Dictionary(uniqueKeysWithValues: sections.compactMap { section -> (String, String)? in
            guard let title = section["title"] as? String,
                  let role = section["role"] as? String else { return nil }
            return (title, role)
        })

        XCTAssertEqual(roleByTitle["开嗓"], "warmup")
        XCTAssertEqual(roleByTitle["舒服范围"], "stablePractice")
        XCTAssertEqual(roleByTitle["挑战一下"], "challengePractice")
        XCTAssertEqual(roleByTitle["收尾再唱"], "closing")
    }

    func testLegacySectionDecodesToGeneralRoleAndPlanDefaultsNotices() throws {
        let legacyJSON = """
        {
          "id": "F9ABEE0C-58FB-498D-8A65-804BA47CD67C",
          "title": "旧歌单",
          "scenario": "friends",
          "sections": [{
            "id": "E1FD6D79-3344-4420-9D9F-8D0E08B60745",
            "title": "旧分段",
            "goal": "旧目标",
            "items": []
          }],
          "createdAt": 0
        }
        """

        let plan = try JSONDecoder().decode(SongPlan.self, from: Data(legacyJSON.utf8))
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any]
        )
        let notices = try XCTUnwrap(encoded["notices"] as? [String])
        let sections = try XCTUnwrap(encoded["sections"] as? [[String: Any]])

        XCTAssertEqual(notices, [])
        XCTAssertEqual(sections.first?["role"] as? String, "general")
    }

    func testTrackControlPolicyKeepsLockedTrackWhenRemoveIsRequested() {
        let state = TrackControlState(
            lockedTrackIDs: ["locked"],
            removedTrackIDs: []
        )

        let transition = TrackControlPolicy().remove(
            trackID: "locked",
            title: "锁定歌",
            from: state
        )

        XCTAssertFalse(transition.didRemove)
        XCTAssertEqual(transition.state.lockedTrackIDs, ["locked"])
        XCTAssertFalse(transition.state.removedTrackIDs.contains("locked"))
        XCTAssertTrue(transition.message.contains("先取消锁定"))
    }

    func testTrackControlPolicyRemovesUnlockedTrackWithoutChangingLocks() {
        let state = TrackControlState(
            lockedTrackIDs: ["other"],
            removedTrackIDs: []
        )

        let transition = TrackControlPolicy().remove(
            trackID: "remove",
            title: "待移除歌",
            from: state
        )

        XCTAssertTrue(transition.didRemove)
        XCTAssertEqual(transition.state.lockedTrackIDs, ["other"])
        XCTAssertTrue(transition.state.removedTrackIDs.contains("remove"))
        XCTAssertEqual(transition.message, "已移除《待移除歌》")
    }

    private func makePlan(
        catalog: [KTVTrack],
        duration: Int,
        scenario: KTVScenario = .friends,
        locked: Set<String> = [],
        removed: Set<String> = []
    ) -> SongPlan {
        RecommendationEngine().generatePlan(
            matches: catalog.map(match),
            preferenceProfile: makeProfile(),
            voiceProfile: .simulatedMiddle,
            scenario: ScenarioConfig(scenario: scenario, peopleCount: 4, durationMinutes: duration),
            catalog: catalog,
            inputSource: .userImport,
            lockedTrackIDs: locked,
            removedTrackIDs: removed
        )
    }

    private func makeCatalog(count: Int) -> [KTVTrack] {
        (0..<count).map { index in
            makeTrack(
                id: "track-\(index)",
                title: "测试歌 \(index)",
                artist: "测试歌手 \(index)",
                difficulty: 2,
                energy: 0.7,
                singAlong: 0.9,
                highRisk: 0.2,
                sceneTags: KTVScenario.allCases.map(\.rawValue)
            )
        }
    }

    private func match(_ track: KTVTrack) -> MatchResult {
        MatchResult(
            importedSong: ImportedSong(title: track.title, artist: track.artist, source: .plainText, confidence: 1),
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
            moodTags: ["怀旧": 1],
            sceneAffinity: ["friends": 1],
            ktvMatchRate: 1,
            averageDifficulty: 2,
            averageSingAlongScore: 0.9,
            highNoteRisk: 0.2,
            summary: "测试画像"
        )
    }

    private func makeTrack(
        id: String,
        title: String,
        artist: String,
        difficulty: Int = 2,
        energy: Double = 0.7,
        singAlong: Double = 0.9,
        highRisk: Double = 0.2,
        sceneTags: [String] = KTVScenario.allCases.map(\.rawValue),
        moodTags: [String] = ["怀旧", "温暖", "甜蜜", "高光"],
        duetFriendly: Bool? = nil
    ) -> KTVTrack {
        KTVTrack(
            id: id,
            title: title,
            artist: artist,
            language: "Mandarin",
            era: "2000s",
            genre: "甜歌",
            moodTags: moodTags,
            sceneTags: sceneTags,
            difficulty: difficulty,
            vocalRangeLowMidi: 48,
            vocalRangeHighMidi: 66,
            energy: energy,
            singAlongScore: singAlong,
            ktvAvailability: 0.9,
            duetFriendly: duetFriendly ?? (singAlong >= 0.8),
            rapDensity: 0.05,
            highNoteRisk: highRisk,
            aliases: [],
            similarSongIds: []
        )
    }
}
