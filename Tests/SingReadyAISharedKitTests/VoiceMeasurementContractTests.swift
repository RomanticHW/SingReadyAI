import XCTest
@testable import SingReadyAISharedKit

final class VoiceMeasurementContractTests: XCTestCase {
    func testRejectsFewerThanTwelveValidPitchFrames() {
        let profile = PitchDetector().analyze(
            midiValues: [48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58]
        )

        XCTAssertEqual(profile.type, .unknown)
        XCTAssertEqual(profile.confidence, 0)
        XCTAssertFalse(profile.hasValidMeasuredRange)
        XCTAssertTrue(profile.note.contains("从舒服低音逐步唱到舒服高音"))
    }

    func testRejectsTwelvePitchFramesWhenP10ToP90SpanIsUnderFiveSemitones() {
        let profile = PitchDetector().analyze(
            midiValues: [60, 60, 60.5, 60.5, 61, 61, 61.5, 61.5, 62, 62, 62.5, 62.5]
        )

        XCTAssertEqual(profile.type, .unknown)
        XCTAssertEqual(profile.confidence, 0)
        XCTAssertFalse(profile.hasValidMeasuredRange)
        XCTAssertTrue(profile.note.contains("从舒服低音逐步唱到舒服高音"))
    }

    func testValidMeasuredRangeUsesNeutralTypeAndMeasuredRangeWording() {
        let profile = PitchDetector().analyze(
            midiValues: [48, 49, 50, 51, 52, 54, 56, 58, 60, 62, 64, 66, 68, 70]
        )

        XCTAssertEqual(profile.type, .unknown)
        XCTAssertEqual(profile.source, .measured)
        XCTAssertTrue(profile.hasValidMeasuredRange)
        XCTAssertGreaterThan(profile.confidence, 0)
        XCTAssertGreaterThanOrEqual(profile.stableHighMidi - profile.stableLowMidi, 5)
        XCTAssertTrue(profile.note.contains("本次唱到的音区"))
        XCTAssertTrue(profile.note.contains("不代表完整音域"))
        XCTAssertFalse(profile.note.contains("48"))
        XCTAssertFalse(profile.note.contains("舒服范围"))
        XCTAssertFalse(profile.note.contains("男声"))
        XCTAssertFalse(profile.note.contains("女声"))
        XCTAssertFalse(profile.singingStrategy.joined().contains("常见音区"))
        XCTAssertFalse(profile.singingStrategy.joined().contains("再试一次"))
    }

    func testMeasuredRangeValidityRequiresMeasuredSourceConfidenceAndSpan() {
        var profile = measuredVoice(low: 50, high: 70)
        XCTAssertTrue(profile.hasValidMeasuredRange)

        profile.source = .commonReference
        XCTAssertFalse(profile.hasValidMeasuredRange)

        profile.source = .measured
        profile.confidence = 0.49
        XCTAssertFalse(profile.hasValidMeasuredRange)

        profile.confidence = 0.8
        profile.stableHighMidi = 54
        XCTAssertFalse(profile.hasValidMeasuredRange)
    }

    func testAdvisorKeepsOriginalKeyOnlyWhenBothTrackEdgesFitMeasuredRange() throws {
        let advice = try XCTUnwrap(
            SingingAdjustmentAdvisor().advice(
                for: track(low: 52, high: 68),
                voiceProfile: measuredVoice(low: 50, high: 70)
            )
        )

        XCTAssertEqual(advice.level, .originalKey)
        XCTAssertEqual(advice.semitoneShift, 0)
        XCTAssertTrue(advice.title.hasPrefix("可先试"))
        XCTAssertFalse(advice.detail.contains("舒服范围"))
    }

    func testAdvisorLowersKeyOnlyWhenShiftedLowAndHighEdgesBothFit() throws {
        let advice = try XCTUnwrap(
            SingingAdjustmentAdvisor().advice(
                for: track(low: 54, high: 74),
                voiceProfile: measuredVoice(low: 50, high: 70)
            )
        )

        XCTAssertEqual(advice.level, .lowerKey)
        XCTAssertEqual(advice.semitoneShift, -4)
        XCTAssertTrue(advice.title.hasPrefix("可先试"))
    }

    func testAdvisorRaisesKeyOnlyWhenShiftedLowAndHighEdgesBothFit() throws {
        let advice = try XCTUnwrap(
            SingingAdjustmentAdvisor().advice(
                for: track(low: 46, high: 66),
                voiceProfile: measuredVoice(low: 50, high: 70)
            )
        )

        XCTAssertEqual(advice.level, .raiseKey)
        XCTAssertEqual(advice.semitoneShift, 4)
        XCTAssertTrue(advice.title.hasPrefix("可先试"))
    }

    func testAdvisorSubstitutesWhenTrackSpanCannotFitMeasuredRange() throws {
        let advice = try XCTUnwrap(
            SingingAdjustmentAdvisor().advice(
                for: track(low: 48, high: 72),
                voiceProfile: measuredVoice(low: 50, high: 70)
            )
        )

        XCTAssertEqual(advice.level, .substitute)
    }

    func testAdvisorSubstitutesWhenRequiredShiftExceedsEightSemitones() throws {
        let advice = try XCTUnwrap(
            SingingAdjustmentAdvisor().advice(
                for: track(low: 60, high: 76),
                voiceProfile: measuredVoice(low: 50, high: 66)
            )
        )

        XCTAssertEqual(advice.level, .substitute)
    }

    func testAdvisorDoesNotGiveExactAdviceForExternalOrInvalidProfiles() {
        let advisor = SingingAdjustmentAdvisor()
        let localTrack = track(low: 52, high: 68)
        let externalTrack = track(low: 52, high: 68, source: .externalSimilar)
        var invalidMeasured = measuredVoice(low: 50, high: 70)
        invalidMeasured.confidence = 0

        XCTAssertNil(advisor.advice(for: externalTrack, voiceProfile: measuredVoice(low: 50, high: 70)))
        XCTAssertNil(advisor.advice(for: localTrack, voiceProfile: invalidMeasured))
        XCTAssertNil(advisor.advice(for: localTrack, voiceProfile: .simulatedMiddle))
    }

    func testInvalidMeasuredRangeDoesNotAffectRecommendationScoreOrVisibleVoiceReasons() throws {
        let candidate = track(low: 52, high: 68)
        var invalidMeasured = measuredVoice(low: 50, high: 70)
        invalidMeasured.confidence = 0
        let importedSong = ImportedSong(
            title: candidate.title,
            artist: candidate.artist,
            source: .plainText,
            confidence: 1
        )
        let match = MatchResult(
            importedSong: importedSong,
            matchedTrack: candidate,
            alternatives: [],
            status: .exact,
            score: 1,
            reason: "测试匹配"
        )
        let scenario = ScenarioConfig(scenario: .friends, peopleCount: 4, durationMinutes: 45)

        let plan = try RecommendationEngine().generatePlan(
            matches: [match],
            preferenceProfile: preferenceProfile(),
            voiceProfile: invalidMeasured,
            scenario: scenario,
            catalog: [candidate],
            generationContext: makeRecommendationGenerationContext(
                matches: [match],
                scenario: scenario,
                voiceProfile: invalidMeasured
            ),
            inputSource: .userImport
        )
        let item = try XCTUnwrap(plan.sections.flatMap(\.items).first)

        XCTAssertEqual(item.scoreBreakdown.vocalFitScore, 0.5, accuracy: 0.000_001)
        XCTAssertFalse(item.reasons.joined().contains("本次唱到的音区"))
        XCTAssertFalse(item.riskWarnings.joined().contains("本次唱到的音区"))
        XCTAssertNil(item.singingAdvice)
    }

    func testExportersRemovePersistedExactClaimsWhenMeasuredRangeIsNoLongerValid() throws {
        let candidate = track(low: 52, high: 68)
        let importedSong = ImportedSong(
            title: candidate.title,
            artist: candidate.artist,
            source: .plainText,
            confidence: 1
        )
        let match = MatchResult(
            importedSong: importedSong,
            matchedTrack: candidate,
            alternatives: [],
            status: .exact,
            score: 1,
            reason: "测试匹配"
        )
        let voice = measuredVoice(low: 50, high: 70)
        let scenario = ScenarioConfig(scenario: .friends, peopleCount: 4, durationMinutes: 45)
        var plan = try RecommendationEngine().generatePlan(
            matches: [match],
            preferenceProfile: preferenceProfile(),
            voiceProfile: voice,
            scenario: scenario,
            catalog: [candidate],
            generationContext: makeRecommendationGenerationContext(
                matches: [match],
                scenario: scenario,
                voiceProfile: voice
            ),
            inputSource: .userImport
        )
        XCTAssertNotNil(plan.sections.flatMap(\.items).first?.singingAdvice)
        plan.voiceProfile?.confidence = 0.1

        let text = PlaylistTextExporter().export(plan: plan)
        let json = try PlaylistJSONExporter().export(plan: plan)
        let poster = PosterRenderer().summary(for: plan)

        XCTAssertFalse(text.contains("本次唱到的音区"))
        XCTAssertFalse(text.contains("可先试原调"))
        XCTAssertFalse(json.contains("本次唱到的音区与歌曲接近"))
        XCTAssertFalse(json.contains("可先试原调"))
        XCTAssertFalse(poster.subtitle.contains("本次唱到的音区"))
    }

    func testLocalSummaryDoesNotClaimVoiceSuitabilityWithoutValidMeasurement() async throws {
        let provider = LocalRuleLLMProvider()

        let commonSummary = try await provider.summarize(
            profile: preferenceProfile(),
            voice: .simulatedMiddle
        )
        var invalidMeasured = measuredVoice(low: 50, high: 70)
        invalidMeasured.confidence = 0.1
        let invalidSummary = try await provider.summarize(
            profile: preferenceProfile(),
            voice: invalidMeasured
        )
        let measuredSummary = try await provider.summarize(
            profile: preferenceProfile(),
            voice: measuredVoice(low: 50, high: 70)
        )

        XCTAssertFalse(commonSummary.contains("你的声音更适合"))
        XCTAssertFalse(invalidSummary.contains("你的声音更适合"))
        XCTAssertFalse(invalidSummary.contains("舒服范围"))
        XCTAssertTrue(measuredSummary.contains("本次唱到的音区"))
    }

    func testVoiceMeasurementRequestGateRejectsStaleCompletionAfterCancel() {
        var gate = VoiceMeasurementRequestGate()
        let firstRequest = gate.begin()

        gate.cancel()

        XCTAssertFalse(gate.accepts(firstRequest))
        XCTAssertFalse(gate.finish(firstRequest))
        XCTAssertFalse(gate.isActive)
    }

    func testVoiceMeasurementRequestGateAcceptsOnlyNewestRequest() {
        var gate = VoiceMeasurementRequestGate()
        let firstRequest = gate.begin()
        let secondRequest = gate.begin()

        XCTAssertFalse(gate.accepts(firstRequest))
        XCTAssertTrue(gate.accepts(secondRequest))
        XCTAssertTrue(gate.finish(secondRequest))
        XCTAssertFalse(gate.accepts(secondRequest))
    }

    func testVoiceMeasurementRequestGateRejectsAConcurrentBegin() throws {
        var gate = VoiceMeasurementRequestGate()
        let firstRequest = try XCTUnwrap(gate.beginIfIdle())

        XCTAssertNil(gate.beginIfIdle())
        XCTAssertTrue(gate.accepts(firstRequest))
    }

    private func measuredVoice(low: Int, high: Int) -> VoiceProfile {
        VoiceProfile(
            type: .unknown,
            minMidi: low,
            maxMidi: high,
            stableLowMidi: low,
            stableHighMidi: high,
            averageMidi: Double(low + high) / 2,
            confidence: 0.8,
            note: "本次唱到的音区",
            source: .measured
        )
    }

    private func track(
        low: Int,
        high: Int,
        source: TrackCatalogSource = .ktvCatalog
    ) -> KTVTrack {
        KTVTrack(
            id: "track-\(low)-\(high)-\(source.rawValue)",
            title: "测试歌曲",
            artist: "测试歌手",
            language: "Mandarin",
            era: "2020s",
            genre: "流行",
            moodTags: [],
            sceneTags: ["friends"],
            difficulty: 3,
            vocalRangeLowMidi: low,
            vocalRangeHighMidi: high,
            energy: 0.6,
            singAlongScore: 0.7,
            ktvAvailability: 0.8,
            duetFriendly: false,
            rapDensity: 0,
            highNoteRisk: 0.3,
            aliases: [],
            similarSongIds: [],
            catalogSource: source
        )
    }

    private func preferenceProfile() -> PreferenceProfile {
        PreferenceProfile(
            topArtists: [("测试歌手", 1)],
            languageDistribution: ["Mandarin": 1],
            eraDistribution: ["2020s": 1],
            genreDistribution: ["流行": 1],
            moodTags: [:],
            sceneAffinity: ["friends": 1],
            ktvMatchRate: 1,
            averageDifficulty: 3,
            averageSingAlongScore: 0.7,
            highNoteRisk: 0.3,
            summary: "测试画像"
        )
    }
}
