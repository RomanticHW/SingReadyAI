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

    func testAnalyzesCommonSineWaveFrames() {
        let sampleRate = 8_000.0
        let detector = PitchDetector()

        let lowFrames = sineFrames(frequency: 220, sampleRate: sampleRate)
        let middleFrames = sineFrames(frequency: 440, sampleRate: sampleRate)
        let highFrames = sineFrames(frequency: 660, sampleRate: sampleRate)

        let lowProfile = detector.analyzeFrames(lowFrames, sampleRate: sampleRate)
        let middleProfile = detector.analyzeFrames(middleFrames, sampleRate: sampleRate)
        let highProfile = detector.analyzeFrames(highFrames, sampleRate: sampleRate)

        XCTAssertEqual(lowProfile.type, .midMale)
        XCTAssertGreaterThanOrEqual(lowProfile.stableHighMidi, 56)
        XCTAssertEqual(middleProfile.type, .midFemale)
        XCTAssertEqual(Int(middleProfile.averageMidi.rounded()), 69, accuracy: 1)
        XCTAssertGreaterThanOrEqual(highProfile.stableHighMidi, 75)
        XCTAssertGreaterThan(highProfile.confidence, 0.55)
    }

    func testAudioFrameSplitterReturnsOverlappingFrames() {
        let sampleRate = 8_000.0
        let samples = sineSamples(frequency: 440, sampleRate: sampleRate, seconds: 1)
        let splitter = AudioFrameSplitter(frameSize: 1024, hopSize: 512)

        let frames = splitter.split(samples: samples)

        XCTAssertGreaterThan(frames.count, 10)
        XCTAssertEqual(frames.first?.count, 1024)
        let windowedEnergy = frames[0].map { abs($0) }.reduce(0, +)
        let rawEnergy = Array(samples[0..<1024]).map { abs($0) }.reduce(0, +)
        XCTAssertLessThan(windowedEnergy, rawEnergy)
    }

    func testAnalyzeFramesReturnsUnknownWhenValidSamplesAreInsufficient() {
        let profile = PitchDetector().analyzeFrames([], sampleRate: 44_100)

        XCTAssertEqual(profile.type, .unknown)
        XCTAssertEqual(profile.confidence, 0.1)
        XCTAssertTrue(profile.note.contains("有效音高样本不足"))
    }

    func testRejectsHighFrequencyNoiseFrames() {
        let sampleRate = 8_000.0
        let frames = sineFrames(frequency: 2_200, sampleRate: sampleRate)

        let profile = PitchDetector().analyzeFrames(frames, sampleRate: sampleRate)

        XCTAssertEqual(profile.type, .unknown)
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

    private func sineSamples(frequency: Double, sampleRate: Double, seconds: Double) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { index in
            Float(sin(2.0 * Double.pi * frequency * Double(index) / sampleRate) * 0.7)
        }
    }

    private func sineFrames(frequency: Double, sampleRate: Double) -> [[Float]] {
        AudioFrameSplitter(frameSize: 1024, hopSize: 512)
            .split(samples: sineSamples(frequency: frequency, sampleRate: sampleRate, seconds: 1.2))
    }
}
