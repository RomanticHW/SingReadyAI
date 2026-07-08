import Foundation

public struct PitchDetector: Sendable {
    public init() {}

    public func detectPitch(samples: [Float], sampleRate: Double) -> Double? {
        guard sampleRate > 0, samples.count > 8 else { return nil }
        let doubles = samples.map(Double.init)
        let rms = sqrt(doubles.map { $0 * $0 }.reduce(0, +) / Double(doubles.count))
        guard rms > 0.01 else { return nil }
        if let zeroCrossingFrequency = estimatedFrequencyFromZeroCrossings(samples: doubles, sampleRate: sampleRate),
           !(70...1050).contains(zeroCrossingFrequency) {
            return nil
        }

        let minLag = max(1, Int(sampleRate / 1000.0))
        let maxLag = min(samples.count - 2, Int(sampleRate / 80.0))
        guard minLag < maxLag else { return nil }

        var bestLag = 0
        var bestCorrelation = 0.0
        var correlations: [(lag: Int, value: Double)] = []
        for lag in minLag...maxLag {
            var sum = 0.0
            var energyA = 0.0
            var energyB = 0.0
            for index in 0..<(doubles.count - lag) {
                let a = doubles[index]
                let b = doubles[index + lag]
                sum += a * b
                energyA += a * a
                energyB += b * b
            }
            let denominator = sqrt(energyA * energyB)
            guard denominator > 0 else { continue }
            let correlation = sum / denominator
            correlations.append((lag, correlation))
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }
        guard bestLag > 0, bestCorrelation >= 0.45 else { return nil }
        let strongThreshold = max(0.45, bestCorrelation * 0.82)
        let selectedLag = firstStrongPeak(in: correlations, threshold: strongThreshold) ?? bestLag
        let frequency = sampleRate / Double(selectedLag)
        guard (80...1000).contains(frequency) else { return nil }
        return frequency
    }

    public func midi(fromFrequency frequency: Double) -> Double {
        69 + 12 * log2(frequency / 440)
    }

    public func analyze(midiValues: [Double]) -> VoiceProfile {
        let filtered = midiValues
            .filter { $0.isFinite && (35...90).contains($0) }
            .sorted()
        guard filtered.count >= 3 else {
            return VoiceProfile(
                type: .unknown,
                minMidi: 0,
                maxMidi: 0,
                stableLowMidi: 0,
                stableHighMidi: 0,
                averageMidi: 0,
                confidence: 0.1,
                note: "有效音高样本不足，请靠近麦克风重试。"
            )
        }
        let minMidi = Int(filtered.first!.rounded())
        let maxMidi = Int(filtered.last!.rounded())
        let stableLow = Int(percentile(filtered, 0.1).rounded())
        let stableHigh = Int(percentile(filtered, 0.9).rounded())
        let average = filtered.reduce(0, +) / Double(filtered.count)
        let type = voiceType(averageMidi: average, stableHigh: stableHigh)
        let confidence = min(0.95, 0.45 + Double(filtered.count) / 80.0)
        let advice = voiceAdvice(type: type, stableLow: stableLow, stableHigh: stableHigh)
        return VoiceProfile(
            type: type,
            minMidi: minMidi,
            maxMidi: maxMidi,
            stableLowMidi: stableLow,
            stableHighMidi: stableHigh,
            averageMidi: average,
            confidence: confidence,
            note: "稳定音域约 \(stableLow)-\(stableHigh) MIDI，推荐优先选择副歌不长期超过该范围的歌曲。",
            suitableSongTypes: advice.suitable,
            avoidSongTypes: advice.avoid,
            singingStrategy: advice.strategy
        )
    }

    public func analyzeFrames(_ frames: [[Float]], sampleRate: Double) -> VoiceProfile {
        let midiValues = frames.compactMap { frame -> Double? in
            guard let frequency = detectPitch(samples: frame, sampleRate: sampleRate) else { return nil }
            return midi(fromFrequency: frequency)
        }
        return analyze(midiValues: midiValues)
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let clamped = min(max(p, 0), 1)
        let position = clamped * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }

    private func firstStrongPeak(in correlations: [(lag: Int, value: Double)], threshold: Double) -> Int? {
        guard correlations.count >= 3 else { return nil }
        for index in 1..<(correlations.count - 1) {
            let previous = correlations[index - 1].value
            let current = correlations[index].value
            let next = correlations[index + 1].value
            if current >= threshold, current >= previous, current >= next {
                return correlations[index].lag
            }
        }
        return nil
    }

    private func estimatedFrequencyFromZeroCrossings(samples: [Double], sampleRate: Double) -> Double? {
        guard samples.count > 1, sampleRate > 0 else { return nil }
        var crossings = 0
        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            if previous == 0 || current == 0 { continue }
            if (previous < 0 && current > 0) || (previous > 0 && current < 0) {
                crossings += 1
            }
        }
        guard crossings >= 2 else { return nil }
        let duration = Double(samples.count) / sampleRate
        guard duration > 0 else { return nil }
        return Double(crossings) / (2 * duration)
    }

    public func highNoteRisk(for track: KTVTrack, voiceProfile: VoiceProfile) -> Double {
        let overshoot = max(0, track.vocalRangeHighMidi - voiceProfile.stableHighMidi)
        let rangePressure = Double(overshoot) * 0.08
        let catalogRisk = track.highNoteRisk * 0.65
        return min(1, catalogRisk + rangePressure)
    }

    private func voiceType(averageMidi: Double, stableHigh: Int) -> VoiceType {
        if averageMidi < 50 { return .lowMale }
        if averageMidi < 58 { return .midMale }
        if averageMidi < 64 { return stableHigh >= 72 ? .highMale : .midMale }
        if averageMidi < 69 { return .lowFemale }
        if averageMidi < 75 || stableHigh < 79 { return .midFemale }
        return .highFemale
    }

    private func voiceAdvice(type: VoiceType, stableLow: Int, stableHigh: Int) -> (suitable: [String], avoid: [String], strategy: [String]) {
        switch type {
        case .lowMale:
            return (
                ["男声低音", "民谣流行", "怀旧金曲", "车载轻唱"],
                ["女声高光", "连续升调副歌", "高密度快歌"],
                ["先选低音区稳定歌曲", "高音曲用降调或安排替代曲", "合唱段可承担低声部"]
            )
        case .midMale:
            return (
                ["华语流行", "情绪抒情", "朋友局合唱", "车载轻唱"],
                ["长时间高音", "强爆发女声歌"],
                ["开场用中低音歌曲热身", "高音歌放在中段", "连续慢歌后加入合唱曲提气氛"]
            )
        case .highMale:
            return (
                ["男声高光", "摇滚/乐队", "KTV 经典", "合唱收尾"],
                ["过低叙事歌", "密集 Rap"],
                ["高光歌曲不要连排", "开场先唱稳定旋律", "副歌前保留气息"]
            )
        case .lowFemale:
            return (
                ["女声中低音", "温柔情歌", "车载轻唱", "甜歌"],
                ["高音爆发歌", "连续真假声切换"],
                ["优先选择旋律线平稳歌曲", "高音歌准备替代曲", "多人局多用合唱降低压力"]
            )
        case .midFemale:
            return (
                ["女声流行", "甜歌/对唱", "情绪抒情", "朋友局合唱"],
                ["极高音转音", "Rap 密度高歌曲"],
                ["高音歌前安排热身", "主歌保持轻声", "副歌避免硬顶"]
            )
        case .highFemale:
            return (
                ["女声高光", "舞台感歌曲", "高能量收尾", "技巧挑战"],
                ["低音叙事歌", "连续高强度歌曲"],
                ["高光段集中展示", "每首高难歌后接一首稳妥歌", "注意副歌前换气"]
            )
        case .unknown:
            return (
                ["稳妥流行", "合唱歌曲", "中低音歌曲"],
                ["高音风险歌", "技巧挑战歌"],
                ["先用模拟声线跑流程", "真机环境靠近麦克风重试", "选择替代曲降低风险"]
            )
        }
    }
}
