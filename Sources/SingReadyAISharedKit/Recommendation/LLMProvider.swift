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
        "\(profile.summary) 声线判断为\(voice.type.displayName)，建议优先选择音域稳定、合唱参与度高的歌曲。"
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
        "真实模型调用应通过后端代理完成，iOS 端不应硬编码 API Key。"
    }
}
