import XCTest
@testable import SingReadyAISharedKit

final class PitchDetectorTests: XCTestCase {
    @MainActor
    func testVoiceAnalysisExecutorKeepsMainActorResponsiveWhileAnalysisRuns() async throws {
        let probe = BlockingAnalysisProbe()
        let executor = VoiceSampleAnalysisExecutor { _, _ in
            probe.runBlockingAnalysis()
            return .simulatedMiddle
        }
        var didPublishAnalyzingState = false

        let analysisTask = Task {
            try await executor.analyze(
                samples: [0.1],
                sampleRate: 8_000,
                onAnalysisStarted: {
                    didPublishAnalyzingState = true
                }
            )
        }
        await probe.waitUntilStarted()

        XCTAssertTrue(didPublishAnalyzingState, "重计算开始前应先发布 analyzing 状态")
        XCTAssertFalse(probe.didFinish, "分析完成前 MainActor 应有机会继续处理状态更新")
        XCTAssertFalse(probe.ranOnMainThread, "音高分析不能在 MainActor 执行")
        probe.release()
        _ = try await analysisTask.value
    }

    func testTenSecondNativeRecordingUsesBoundedAnalysisWork() throws {
        let nativeSampleRate = 44_100.0
        let nativeSamples = Array(repeating: Float(0.1), count: Int(nativeSampleRate * 10))
        let reducer = AudioSampleRateReducer(targetSampleRate: 8_000)
        let reduced = try reducer.reduce(samples: nativeSamples, sourceSampleRate: nativeSampleRate)
        let splitter = AudioFrameSplitter(frameSize: 4096, hopSize: 2048)
        let frameCount = splitter.frameCount(forSampleCount: reduced.samples.count)
        let maximumLag = Int(reduced.sampleRate / 80)
        let upperBound = frameCount * splitter.frameSize * maximumLag

        XCTAssertLessThanOrEqual(reduced.samples.count, 80_001)
        XCTAssertLessThanOrEqual(frameCount, 40)
        XCTAssertLessThan(upperBound, 20_000_000)
    }

    func testNativeRateSamplesRemainUsableAfterBoundedAnalysis() async throws {
        let sampleRate = 44_100.0
        let frequencies = [196.0, 220.0, 246.94, 261.63, 293.66, 329.63, 392.0]
        let samples = frequencies.flatMap { frequency in
            sineSamples(frequency: frequency, sampleRate: sampleRate, seconds: 1.45)
        }

        let profile = try await VoiceSampleAnalysisExecutor().analyze(
            samples: samples,
            sampleRate: sampleRate
        )

        XCTAssertTrue(profile.hasValidMeasuredRange)
        XCTAssertGreaterThanOrEqual(profile.stableHighMidi - profile.stableLowMidi, 5)
    }

    func testVoiceAnalysisExecutorRejectsCompletionAfterCancellation() async throws {
        let probe = BlockingAnalysisProbe()
        let executor = VoiceSampleAnalysisExecutor { _, _ in
            probe.runBlockingAnalysis()
            return .simulatedMiddle
        }
        let analysisTask = Task {
            try await executor.analyze(samples: [0.1], sampleRate: 8_000)
        }
        await probe.waitUntilStarted()

        analysisTask.cancel()
        probe.release()

        do {
            _ = try await analysisTask.value
            XCTFail("取消后的分析结果不能提交")
        } catch is CancellationError {
            // 预期路径
        }
    }

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

        let frames = [220.0, 246.94, 261.63, 293.66, 329.63, 349.23, 392.0]
            .flatMap { sineFrames(frequency: $0, sampleRate: sampleRate, seconds: 0.35) }

        let profile = detector.analyzeFrames(frames, sampleRate: sampleRate)

        XCTAssertEqual(profile.type, .unknown)
        XCTAssertTrue(profile.hasValidMeasuredRange)
        XCTAssertGreaterThanOrEqual(profile.stableHighMidi - profile.stableLowMidi, 5)
        XCTAssertGreaterThan(profile.confidence, 0)
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
        XCTAssertEqual(profile.confidence, 0)
        XCTAssertTrue(profile.note.contains("从舒服低音逐步唱到舒服高音"))
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
        let profile = PitchDetector().analyze(midiValues: [48, 50, 52, 54, 56, 58, 60, 62, 64, 66, 68, 70])

        XCTAssertEqual(profile.type, .unknown)
        XCTAssertGreaterThanOrEqual(profile.stableLowMidi, 48)
        XCTAssertLessThanOrEqual(profile.stableHighMidi, 70)
        XCTAssertTrue(profile.hasValidMeasuredRange)
        XCTAssertGreaterThan(profile.confidence, 0)
        XCTAssertFalse(profile.suitableSongTypes.isEmpty)
        XCTAssertFalse(profile.singingStrategy.isEmpty)
    }

    func testHandlesInvalidMidiSamples() {
        let profile = PitchDetector().analyze(midiValues: [10, 120, .nan, .infinity])

        XCTAssertEqual(profile.type, .unknown)
        XCTAssertEqual(profile.confidence, 0)
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

    private func sineFrames(frequency: Double, sampleRate: Double, seconds: Double = 1.2) -> [[Float]] {
        AudioFrameSplitter(frameSize: 1024, hopSize: 512)
            .split(samples: sineSamples(frequency: frequency, sampleRate: sampleRate, seconds: seconds))
    }
}

private final class BlockingAnalysisProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false
    private var finished = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var analysisRanOnMainThread = false

    var didFinish: Bool {
        condition.withLock { finished }
    }

    var ranOnMainThread: Bool {
        condition.withLock { analysisRanOnMainThread }
    }

    func runBlockingAnalysis() {
        condition.lock()
        analysisRanOnMainThread = Thread.isMainThread
        started = true
        let continuations = startedContinuations
        startedContinuations.removeAll()
        condition.unlock()
        continuations.forEach { $0.resume() }

        condition.lock()
        let deadline = Date().addingTimeInterval(1)
        while !released, condition.wait(until: deadline) {}
        finished = true
        condition.unlock()
    }

    func waitUntilStarted() async {
        if condition.withLock({ started }) { return }
        await withCheckedContinuation { continuation in
            condition.lock()
            if started {
                condition.unlock()
                continuation.resume()
            } else {
                startedContinuations.append(continuation)
                condition.unlock()
            }
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private extension NSCondition {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return body()
    }
}
