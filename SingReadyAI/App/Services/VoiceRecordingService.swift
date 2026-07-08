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
            return "没有麦克风权限，可使用模拟声线继续演示。"
        case .invalidInputFormat:
            return "麦克风输入格式不可用，请切换设备后重试。"
        case .insufficientPitchSamples:
            return "有效音高样本不足，请靠近麦克风并用稳定音量重试。"
        }
    }
}

final class VoiceRecordingService {
    private let analyzer: VoiceProfileAnalyzer
    private let frameSplitter: AudioFrameSplitter
    private var engine: AVAudioEngine?

    init(
        analyzer: VoiceProfileAnalyzer = VoiceProfileAnalyzer(),
        frameSplitter: AudioFrameSplitter = AudioFrameSplitter(frameSize: 4096, hopSize: 2048)
    ) {
        self.analyzer = analyzer
        self.frameSplitter = frameSplitter
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
        onLevel: @escaping @Sendable (Double) -> Void
    ) async throws -> VoiceProfile {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        let engine = AVAudioEngine()
        self.engine = engine
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceRecordingServiceError.invalidInputFormat
        }

        final class SampleBox {
            var samples: [Float] = []
        }
        let sampleBox = SampleBox()
        sampleBox.samples.reserveCapacity(Int(format.sampleRate * duration))

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frameLength > 0, channelCount > 0 else { return }

            if channelCount == 1 {
                let pointer = channelData[0]
                sampleBox.samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: frameLength))
            } else {
                for frameIndex in 0..<frameLength {
                    var mixed: Float = 0
                    for channelIndex in 0..<channelCount {
                        mixed += channelData[channelIndex][frameIndex]
                    }
                    sampleBox.samples.append(mixed / Float(channelCount))
                }
            }

            let recentCount = min(frameLength, sampleBox.samples.count)
            let recent = sampleBox.samples.suffix(recentCount)
            let rms = sqrt(recent.reduce(0) { $0 + Double($1 * $1) } / Double(max(recentCount, 1)))
            onLevel(min(1, max(0.06, rms * 9)))
        }

        func cleanup() {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }

        do {
            engine.prepare()
            try engine.start()
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            cleanup()
        } catch {
            cleanup()
            throw error
        }

        let frames = frameSplitter.split(samples: sampleBox.samples)
        let profile = analyzer.analyzePCMFrames(frames, sampleRate: format.sampleRate)
        guard profile.type != .unknown, profile.confidence >= 0.2 else {
            throw VoiceRecordingServiceError.insufficientPitchSamples
        }

        var realProfile = profile
        realProfile.note = "真实录音分析：已在本机内存中处理 10 秒 PCM 音高样本，不保存原始音频。稳定音域约 \(profile.stableLowMidi)-\(profile.stableHighMidi) MIDI。"
        return realProfile
    }
}
#endif
