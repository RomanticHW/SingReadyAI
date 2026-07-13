import Foundation

public struct RecommendationReasonBuilder: Sendable {
    public init() {}

    public func reasons(
        for track: KTVTrack,
        preferenceProfile: PreferenceProfile,
        voiceProfile: VoiceProfile,
        scenario: ScenarioConfig,
        importedArtistCounts: [String: Int],
        inputSource: RecommendationInputSource = .legacyUnknown
    ) -> [String] {
        if track.isProvisionalExternalCandidate {
            return provisionalReasons(for: track)
        }
        var reasons: [String] = []
        if inputSource.allowsPlaylistPersonalization,
           importedArtistCounts[track.artist, default: 0] > 0 {
            reasons.append("你歌单里本来就有这位歌手")
        }
        if voiceProfile.hasValidMeasuredRange,
           vocalFit(track: track, voiceProfile: voiceProfile) > 0.72 {
            reasons.append("本次唱到的音区与歌曲接近")
        }
        if track.singAlongScore >= 0.82 {
            switch scenario.scenario {
            case .soloPractice:
                reasons.append("副歌旋律好记，适合反复练")
            case .carKTV:
                reasons.append("副歌好接，适合车里轻松跟唱")
            case .couples:
                reasons.append("副歌好接，两个人容易一起唱")
            case .friends, .birthday, .teamBuilding:
                reasons.append("副歌好接，适合\(scenario.scenario.displayName)合唱")
            }
        }
        if track.energy >= 0.75 {
            switch scenario.scenario {
            case .soloPractice:
                reasons.append("节奏感明显，适合练状态")
            case .carKTV:
                reasons.append("节奏感明显，车里更容易跟上")
            case .couples:
                reasons.append("节奏感明显，两个人更容易进入状态")
            case .friends, .birthday, .teamBuilding:
                reasons.append("气氛容易起来，适合带现场")
            }
        }
        if track.sceneTags.contains(scenario.scenario.rawValue) {
            reasons.append("和这场的氛围比较搭")
        }
        if reasons.isEmpty {
            reasons.append("在常见 K 歌参考中较常见，可作为补充歌")
        }
        return Array(reasons.prefix(4))
    }

    public func riskWarnings(for track: KTVTrack, voiceProfile: VoiceProfile, scenario: ScenarioConfig) -> [String] {
        guard !track.isProvisionalExternalCandidate else { return [] }
        var warnings: [String] = []
        if track.highNoteRisk >= 0.72
            || (voiceProfile.hasValidMeasuredRange
                && track.vocalRangeHighMidi > voiceProfile.stableHighMidi + 3) {
            warnings.append("副歌高音多，状态起来后再唱")
        }
        if track.rapDensity >= 0.55 {
            warnings.append("Rap 比较密，先熟悉节奏再唱")
        }
        if scenario.scenario == .carKTV && track.difficulty >= 4 {
            warnings.append("车里唱会偏累，放一小段就好")
        }
        return Array(warnings.prefix(2))
    }

    private func provisionalReasons(for track: KTVTrack) -> [String] {
        track.provisionalDisclosureReasons
    }

    private func vocalFit(track: KTVTrack, voiceProfile: VoiceProfile) -> Double {
        let overlapLow = max(track.vocalRangeLowMidi, voiceProfile.stableLowMidi)
        let overlapHigh = min(track.vocalRangeHighMidi, voiceProfile.stableHighMidi)
        let overlap = max(0, overlapHigh - overlapLow)
        let trackRange = max(1, track.vocalRangeHighMidi - track.vocalRangeLowMidi)
        let rangeScore = Double(overlap) / Double(trackRange)
        let highRiskPenalty = max(0, Double(track.vocalRangeHighMidi - voiceProfile.stableHighMidi)) * 0.035
        return max(0, min(1, rangeScore - highRiskPenalty))
    }
}
