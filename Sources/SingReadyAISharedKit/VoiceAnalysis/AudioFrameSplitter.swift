import Foundation

public struct AudioFrameSplitter: Sendable {
    public let frameSize: Int
    public let hopSize: Int

    public init(frameSize: Int = 4096, hopSize: Int = 2048) {
        self.frameSize = max(256, frameSize)
        self.hopSize = max(128, hopSize)
    }

    public func split(samples: [Float]) -> [[Float]] {
        var frames: [[Float]] = []
        frames.reserveCapacity(frameCount(forSampleCount: samples.count))
        forEachFrame(samples: samples) { frame in
            frames.append(frame)
        }
        return frames
    }

    public func frameCount(forSampleCount sampleCount: Int) -> Int {
        guard sampleCount >= frameSize else { return 0 }
        return (sampleCount - frameSize) / hopSize + 1
    }

    public func forEachFrame(
        samples: [Float],
        _ body: ([Float]) throws -> Void
    ) rethrows {
        guard samples.count >= frameSize else { return }
        let denominator = Float(frameSize - 1)
        let window = (0..<frameSize).map { index in
            let phase = 2 * Float.pi * Float(index) / denominator
            return 0.5 * (1 - cos(phase))
        }
        var frame = Array(repeating: Float.zero, count: frameSize)
        var offset = 0
        while offset + frameSize <= samples.count {
            for index in 0..<frameSize {
                frame[index] = samples[offset + index] * window[index]
            }
            try body(frame)
            offset += hopSize
        }
    }
}

public struct ReducedAudioSamples: Sendable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

public struct AudioSampleRateReducer: Sendable {
    public let targetSampleRate: Double

    public init(targetSampleRate: Double = 8_000) {
        self.targetSampleRate = max(2_000, targetSampleRate)
    }

    public func reduce(
        samples: [Float],
        sourceSampleRate: Double
    ) throws -> ReducedAudioSamples {
        guard sourceSampleRate > targetSampleRate,
              !samples.isEmpty else {
            return ReducedAudioSamples(samples: samples, sampleRate: sourceSampleRate)
        }

        let sourceSamplesPerOutput = sourceSampleRate / targetSampleRate
        let outputCount = Int(Double(samples.count) / sourceSamplesPerOutput)
        var output = Array(repeating: Float.zero, count: outputCount)
        for outputIndex in 0..<outputCount {
            if outputIndex.isMultiple(of: 2_048) {
                try Task.checkCancellation()
            }
            let start = min(
                samples.count - 1,
                Int(Double(outputIndex) * sourceSamplesPerOutput)
            )
            let end = min(
                samples.count,
                max(start + 1, Int(Double(outputIndex + 1) * sourceSamplesPerOutput))
            )
            var sum: Float = 0
            for sourceIndex in start..<end {
                sum += samples[sourceIndex]
            }
            output[outputIndex] = sum / Float(end - start)
        }
        return ReducedAudioSamples(samples: output, sampleRate: targetSampleRate)
    }
}
