import Foundation

public struct AudioFrameSplitter: Sendable {
    public let frameSize: Int
    public let hopSize: Int

    public init(frameSize: Int = 4096, hopSize: Int = 2048) {
        self.frameSize = max(256, frameSize)
        self.hopSize = max(128, hopSize)
    }

    public func split(samples: [Float]) -> [[Float]] {
        guard samples.count >= frameSize else { return [] }
        var frames: [[Float]] = []
        frames.reserveCapacity(max(1, (samples.count - frameSize) / hopSize + 1))

        var offset = 0
        while offset + frameSize <= samples.count {
            let frame = Array(samples[offset..<(offset + frameSize)])
            frames.append(applyHannWindow(to: frame))
            offset += hopSize
        }
        return frames
    }

    private func applyHannWindow(to samples: [Float]) -> [Float] {
        guard samples.count > 1 else { return samples }
        let denominator = Float(samples.count - 1)
        return samples.enumerated().map { index, sample in
            let phase = 2 * Float.pi * Float(index) / denominator
            let window = 0.5 * (1 - cos(phase))
            return sample * window
        }
    }
}
