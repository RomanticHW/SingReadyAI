import XCTest
@testable import SingReadyAISharedKit

final class PitchDetectorTests: XCTestCase {
    func testReturnsNilForEmptyAndSilence() {
        let detector = PitchDetector()

        XCTAssertNil(detector.detectPitch(samples: [], sampleRate: 44_100))
        XCTAssertNil(detector.detectPitch(samples: Array(repeating: 0, count: 4096), sampleRate: 44_100))
    }

    func testDetectsPitchFromSineWave() {
        let sampleRate = 44_100.0
        let frequency = 440.0
        let samples = (0..<4096).map { index in
            Float(sin(2.0 * Double.pi * frequency * Double(index) / sampleRate) * 0.7)
        }

        let detected = PitchDetector().detectPitch(samples: samples, sampleRate: sampleRate)

        XCTAssertNotNil(detected)
        XCTAssertEqual(detected ?? 0, frequency, accuracy: 5)
    }

    func testRejectsOutOfSupportedFrequencyRange() {
        let sampleRate = 44_100.0
        let frequency = 1_200.0
        let samples = (0..<4096).map { index in
            Float(sin(2.0 * Double.pi * frequency * Double(index) / sampleRate) * 0.7)
        }

        XCTAssertNil(PitchDetector().detectPitch(samples: samples, sampleRate: sampleRate))
    }

    func testBuildsStableVoiceProfileFromMidiValues() {
        let profile = PitchDetector().analyze(midiValues: [52, 55, 57, 60, 62, 64, 65, 67, 70])

        XCTAssertEqual(profile.type, .midMale)
        XCTAssertGreaterThanOrEqual(profile.stableLowMidi, 52)
        XCTAssertLessThanOrEqual(profile.stableHighMidi, 70)
        XCTAssertGreaterThan(profile.confidence, 0.45)
        XCTAssertFalse(profile.suitableSongTypes.isEmpty)
        XCTAssertFalse(profile.singingStrategy.isEmpty)
    }

    func testHandlesInvalidMidiSamples() {
        let profile = PitchDetector().analyze(midiValues: [10, 120, .nan, .infinity])

        XCTAssertEqual(profile.type, .unknown)
        XCTAssertEqual(profile.confidence, 0.1)
    }

    func testHighNoteRiskIncreasesWhenTrackExceedsStableRange() {
        let track = KTVTrack(
            id: "risk",
            title: "测试高音歌",
            artist: "测试歌手",
            language: "Mandarin",
            era: "2020s",
            genre: "情歌",
            moodTags: ["高光"],
            sceneTags: ["friends"],
            difficulty: 5,
            vocalRangeLowMidi: 50,
            vocalRangeHighMidi: 78,
            energy: 0.6,
            singAlongScore: 0.7,
            ktvAvailability: 0.9,
            duetFriendly: false,
            rapDensity: 0.0,
            highNoteRisk: 0.8,
            aliases: [],
            similarSongIds: []
        )

        let risk = PitchDetector().highNoteRisk(for: track, voiceProfile: .simulatedMiddle)

        XCTAssertGreaterThan(risk, 0.8)
    }
}
