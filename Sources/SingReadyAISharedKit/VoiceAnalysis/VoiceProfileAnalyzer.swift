import Foundation

public struct VoiceProfileAnalyzer: Sendable {
    private let pitchDetector: PitchDetector

    public init(pitchDetector: PitchDetector = PitchDetector()) {
        self.pitchDetector = pitchDetector
    }

    public func analyzePCMFrames(_ frames: [[Float]], sampleRate: Double) -> VoiceProfile {
        pitchDetector.analyzeFrames(frames, sampleRate: sampleRate)
    }

    public func simulatedProfile() -> VoiceProfile {
        .simulatedMiddle
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
