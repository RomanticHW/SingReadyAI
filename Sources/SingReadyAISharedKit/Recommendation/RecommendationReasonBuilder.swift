import Foundation

public struct RecommendationReasonBuilder: Sendable {
    public init() {}

    public func reasons(
        for track: KTVTrack,
        preferenceProfile: PreferenceProfile,
        voiceProfile: VoiceProfile,
        scenario: ScenarioConfig,
        importedArtistCounts: [String: Int]
    ) -> [String] {
        var reasons: [String] = []
        if importedArtistCounts[track.artist, default: 0] > 0 {
            reasons.append("你导入的歌单中出现过该歌手")
        }
        if vocalFit(track: track, voiceProfile: voiceProfile) > 0.72 {
            reasons.append("这首歌音域与你的声线更匹配")
        }
        if track.singAlongScore >= 0.82 {
            reasons.append("副歌参与度高，适合\(scenario.scenario.displayName)合唱")
        }
        if track.energy >= 0.75 {
            reasons.append("能量值较高，适合带动现场气氛")
        }
        if track.sceneTags.contains(scenario.scenario.rawValue) {
            reasons.append("歌曲标签和当前场景匹配")
        }
        if reasons.isEmpty {
            reasons.append("曲库可唱度较高，适合作为补充歌曲")
        }
        return Array(reasons.prefix(4))
    }

    public func riskWarnings(for track: KTVTrack, voiceProfile: VoiceProfile, scenario: ScenarioConfig) -> [String] {
        var warnings: [String] = []
        if track.highNoteRisk >= 0.72 || track.vocalRangeHighMidi > voiceProfile.stableHighMidi + 3 {
            warnings.append("副歌高音较多，建议状态好时唱")
        }
        if track.rapDensity >= 0.55 {
            warnings.append("Rap 密度偏高，不适合冷场时点")
        }
        if scenario.scenario == .carKTV && track.difficulty >= 4 {
            warnings.append("车载场景建议降低难度，可放在短时高光段")
        }
        return Array(warnings.prefix(2))
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
