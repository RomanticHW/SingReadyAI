import Foundation

public protocol LLMProvider: Sendable {
    func rewritePlanTitle(_ plan: SongPlan, scenario: ScenarioConfig) async throws -> String
    func summarize(profile: PreferenceProfile, voice: VoiceProfile) async throws -> String
}

public struct LocalRuleLLMProvider: LLMProvider {
    public init() {}

    public func rewritePlanTitle(_ plan: SongPlan, scenario: ScenarioConfig) async throws -> String {
        "今晚的\(scenario.scenario.displayName)歌单"
    }

    public func summarize(profile: PreferenceProfile, voice: VoiceProfile) async throws -> String {
        guard voice.hasValidMeasuredRange else { return profile.summary }
        return "\(profile.summary) 本次唱到的音区只作排歌参考，现场可以先试唱再决定是否移调。"
    }
}

public struct RemoteLLMProvider: LLMProvider {
    public init() {}

    public func rewritePlanTitle(_ plan: SongPlan, scenario: ScenarioConfig) async throws -> String {
        throw RemoteLLMError.backendProxyRequired
    }

    public func summarize(profile: PreferenceProfile, voice: VoiceProfile) async throws -> String {
        throw RemoteLLMError.backendProxyRequired
    }
}

public enum RemoteLLMError: Error, LocalizedError {
    case backendProxyRequired

    public var errorDescription: String? {
        "这次没写出来，稍后再试。"
    }
}
