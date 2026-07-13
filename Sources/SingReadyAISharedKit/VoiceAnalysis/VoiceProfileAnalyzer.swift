import Foundation

public struct VoiceProfileAnalyzer: Sendable {
    private let pitchDetector: PitchDetector

    public init(pitchDetector: PitchDetector = PitchDetector()) {
        self.pitchDetector = pitchDetector
    }

    public func analyzePCMFrames(_ frames: [[Float]], sampleRate: Double) -> VoiceProfile {
        pitchDetector.analyzeFrames(frames, sampleRate: sampleRate)
    }

    public func analyzeSamples(
        _ samples: [Float],
        sampleRate: Double,
        frameSplitter: AudioFrameSplitter,
        sampleRateReducer: AudioSampleRateReducer
    ) throws -> VoiceProfile {
        let reduced = try sampleRateReducer.reduce(
            samples: samples,
            sourceSampleRate: sampleRate
        )
        var midiValues: [Double] = []
        midiValues.reserveCapacity(
            frameSplitter.frameCount(forSampleCount: reduced.samples.count)
        )
        try frameSplitter.forEachFrame(samples: reduced.samples) { frame in
            try Task.checkCancellation()
            guard let frequency = try pitchDetector.detectPitchCancellable(
                samples: frame,
                sampleRate: reduced.sampleRate
            ) else { return }
            midiValues.append(pitchDetector.midi(fromFrequency: frequency))
        }
        try Task.checkCancellation()
        return pitchDetector.analyze(midiValues: midiValues)
    }

    public func simulatedProfile() -> VoiceProfile {
        .simulatedMiddle
    }
}

public actor VoiceSampleAnalysisExecutor {
    typealias Operation = @Sendable ([Float], Double) throws -> VoiceProfile

    private let operation: Operation

    public init(
        analyzer: VoiceProfileAnalyzer = VoiceProfileAnalyzer(),
        frameSplitter: AudioFrameSplitter = AudioFrameSplitter(frameSize: 4096, hopSize: 2048),
        sampleRateReducer: AudioSampleRateReducer = AudioSampleRateReducer()
    ) {
        operation = { samples, sampleRate in
            try analyzer.analyzeSamples(
                samples,
                sampleRate: sampleRate,
                frameSplitter: frameSplitter,
                sampleRateReducer: sampleRateReducer
            )
        }
    }

    init(_ operation: @escaping Operation) {
        self.operation = operation
    }

    public func analyze(
        samples: [Float],
        sampleRate: Double,
        onAnalysisStarted: @escaping @MainActor @Sendable () -> Void = {}
    ) async throws -> VoiceProfile {
        try Task.checkCancellation()
        await onAnalysisStarted()
        try Task.checkCancellation()
        let profile = try operation(samples, sampleRate)
        try Task.checkCancellation()
        return profile
    }
}

public protocol AudioRecordingServicing: Sendable {
    func requestPermission() async -> Bool
    func recordTenSecondPitchProfile() async throws -> VoiceProfile
}

public struct SimulatedAudioRecorderService: AudioRecordingServicing {
    public init() {}

    public func requestPermission() async -> Bool { true }

    public func recordTenSecondPitchProfile() async throws -> VoiceProfile {
        VoiceProfile.simulatedMiddle
    }
}
