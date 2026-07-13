import Foundation
import SingReadyAISharedKit

#if os(iOS) && canImport(AVFoundation)
import AVFoundation

enum VoiceRecordingServiceError: Error, LocalizedError {
    case permissionDenied
    case invalidInputFormat
    case insufficientPitchSamples

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "没开麦克风权限，也可以先不测，直接排。"
        case .invalidInputFormat:
            return "这次没接到麦克风声音，请换个设备再试。"
        case .insufficientPitchSamples:
            return "这次还不足以确定音区，请从舒服低音逐步唱到舒服高音再试一次。"
        }
    }
}

private final class VoiceSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float]

    init(capacity: Int) {
        samples = []
        samples.reserveCapacity(max(0, capacity))
    }

    func append(_ values: [Float]) -> Double {
        guard !values.isEmpty else { return 0.06 }
        lock.lock()
        samples.append(contentsOf: values)
        lock.unlock()
        let energy = values.reduce(0) { $0 + Double($1 * $1) }
        let rms = sqrt(energy / Double(values.count))
        return min(1, max(0.06, rms * 9))
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

@MainActor
final class VoiceRecordingService {
    private let analysisExecutor: VoiceSampleAnalysisExecutor
    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var hasInstalledTap = false
    private var isSessionActive = false
    private var activeRecordingID: UUID?

    init(
        analysisExecutor: VoiceSampleAnalysisExecutor = VoiceSampleAnalysisExecutor()
    ) {
        self.analysisExecutor = analysisExecutor
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func recordPitchProfile(
        duration: TimeInterval,
        onLevel: @escaping @Sendable (Double) -> Void,
        onAnalysisStarted: @escaping @MainActor @Sendable () -> Void
    ) async throws -> VoiceProfile {
        stop()
        let recordingID = UUID()
        activeRecordingID = recordingID
        defer { cleanup(ifCurrent: recordingID) }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        isSessionActive = true

        let engine = AVAudioEngine()
        self.engine = engine
        let inputNode = engine.inputNode
        self.inputNode = inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceRecordingServiceError.invalidInputFormat
        }

        let sampleBox = VoiceSampleBuffer(capacity: Int(format.sampleRate * duration))

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frameLength > 0, channelCount > 0 else { return }

            let incoming: [Float]
            if channelCount == 1 {
                let pointer = channelData[0]
                incoming = Array(UnsafeBufferPointer(start: pointer, count: frameLength))
            } else {
                var mixedSamples: [Float] = []
                mixedSamples.reserveCapacity(frameLength)
                for frameIndex in 0..<frameLength {
                    var mixed: Float = 0
                    for channelIndex in 0..<channelCount {
                        mixed += channelData[channelIndex][frameIndex]
                    }
                    mixedSamples.append(mixed / Float(channelCount))
                }
                incoming = mixedSamples
            }
            onLevel(sampleBox.append(incoming))
        }
        hasInstalledTap = true

        engine.prepare()
        try engine.start()
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        try Task.checkCancellation()
        guard activeRecordingID == recordingID else { throw CancellationError() }

        cleanupResources()
        let samples = sampleBox.snapshot()
        let profile = try await analysisExecutor.analyze(
            samples: samples,
            sampleRate: format.sampleRate,
            onAnalysisStarted: onAnalysisStarted
        )
        try Task.checkCancellation()
        guard activeRecordingID == recordingID else { throw CancellationError() }
        guard profile.hasValidMeasuredRange else {
            throw VoiceRecordingServiceError.insufficientPitchSamples
        }

        var realProfile = profile
        realProfile.type = .unknown
        realProfile.note = "这是本次唱到的音区，仅作排歌参考，不代表完整音域；原始音频不保存。"
        return realProfile
    }

    func stop() {
        activeRecordingID = nil
        cleanupResources()
    }

    private func cleanup(ifCurrent recordingID: UUID) {
        guard activeRecordingID == recordingID else { return }
        activeRecordingID = nil
        cleanupResources()
    }

    private func cleanupResources() {
        if hasInstalledTap {
            inputNode?.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        engine?.stop()
        engine = nil
        inputNode = nil
        if isSessionActive {
            isSessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
#endif
