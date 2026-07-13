import SwiftUI
import SingReadyAISharedKit

#if canImport(UIKit)
import UIKit
#endif

struct PreferenceInsightCard: View {
    let profile: PreferenceProfile
    let inputSource: RecommendationInputSource

    var body: some View {
        GlassCard {
            Text(inputSource.preferenceInsightTitle)
                .font(TypographyTokens.section)
                .stageText()
            DistributionBars(title: "语种", values: profile.languageDistribution, valueFormatter: localizedLanguageName)
            DistributionBars(title: "年代", values: profile.eraDistribution)
            DistributionBars(title: "曲风", values: profile.genreDistribution)
            DistributionBars(title: "情绪", values: profile.moodTags, valueFormatter: localizedMoodName)
        }
    }
}

struct DistributionBars: View {
    let title: String
    let values: [String: Double]
    var valueFormatter: (String) -> String = { $0 }

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.xs) {
            Text(title)
                .font(TypographyTokens.callout.weight(.semibold))
                .stageText()
            ForEach(values.sorted(by: { $0.value > $1.value }).prefix(5), id: \.key) { key, value in
                MetricBar(title: valueFormatter(key), value: value, valueLabel: shareLabel)
            }
        }
    }

    private func shareLabel(_ value: Double) -> String {
        switch value {
        case 0.72...: return "最多"
        case 0.42...: return "不少"
        case 0.18...: return "有一些"
        default: return "少量"
        }
    }
}

private func localizedLanguageName(_ value: String) -> String {
    switch value {
    case "Mandarin": return "普通话"
    case "Cantonese": return "粤语"
    case "English": return "英文"
    case "Japanese": return "日语"
    case "Korean": return "韩语"
    default: return value
    }
}

private func localizedMoodName(_ value: String) -> String {
    switch value {
    case "旋律熟": return "熟悉旋律"
    default: return value
    }
}

struct VoiceSetupView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        FlowPage {
            HeroHeader(
                eyebrow: voiceEyebrow,
                title: voiceTitle,
                subtitle: voiceSubtitle,
                systemImage: "waveform"
            )
            GlassCard {
                recordingContent
                ResponsiveActionRow {
                    if isRecordingBusy {
                        SecondaryGlassButton(title: "取消录音", systemImage: "xmark.circle") {
                            store.cancelVoiceRecording()
                        }
                    } else if store.voiceProfile == nil {
                        SecondaryGlassButton(title: "开始录音", systemImage: "record.circle") {
                            store.startVoiceRecording()
                        }
                        SecondaryGlassButton(title: "先不测", systemImage: "waveform.path") {
                            store.useSimulatedVoice()
                        }
                    } else {
                        SecondaryGlassButton(title: "重新测一下", systemImage: "record.circle") {
                            store.startVoiceRecording()
                        }
                    }
                }
                if store.microphonePermissionDenied {
                    SecondaryGlassButton(title: "打开系统设置", systemImage: "gear") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        openURL(url)
                    }
                }
                PrivacyNoteView(text: "原始录音不保存，最近一次有效实测音区结果仅保存在本机；这里只整理本次唱到的音区，不代表完整音域。")
            }
            if store.voiceProfile == nil {
                VoiceQuickGuideCard()
            }
            if let voice = store.voiceProfile {
                GlassCard {
                    Text(voice.source.displayName)
                        .font(TypographyTokens.section)
                        .stageText()
                    VoiceRangeVisualizer(profile: voice)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 144), spacing: SpacingTokens.sm)], spacing: SpacingTokens.sm) {
                        MetricPill(
                            title: voice.source == .measured ? "本次音区" : "参考范围",
                            value: midiDisplayRange(voice),
                            systemImage: "music.quarternote.3"
                        )
                        if voice.source == .measured {
                            MetricPill(title: "这次结果", value: voiceConfidenceLabel(voice.confidence), systemImage: "gauge.with.dots.needle.bottom.50percent")
                        }
                    }
                    if !isRecordingBusy {
                        PrimaryGradientButton(
                            title: store.scenarioConfig.scenario == .soloPractice ? "去排练唱单" : "去排今晚歌单",
                            systemImage: "person.3.sequence"
                        ) {
                            store.setStage(.scenario)
                        }
                    }
                    if voice.source == .measured {
                        Text("记录于 \(voice.createdAt.formatted(date: .abbreviated, time: .shortened))；如果今天状态变了，可以重新测一下。")
                            .font(TypographyTokens.caption)
                            .foregroundStyle(DesignSystem.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(voice.note)
                        .font(TypographyTokens.caption)
                        .foregroundStyle(DesignSystem.muted)
                    TagCloud(values: voice.userFacingSuitableSongTypes, tint: DesignSystem.success)
                    TagCloud(values: voice.userFacingAvoidSongTypes, tint: DesignSystem.warning)
                }
            }
        }
        .onDisappear {
            store.cancelVoiceRecording()
        }
    }

    private var isRecordingBusy: Bool {
        switch store.recordingState {
        case .requestingPermission, .recording, .analyzing:
            return true
        case .idle, .failed:
            return false
        }
    }

    private var voiceEyebrow: String {
        store.voiceProfile?.source.displayName ?? "测一下音域"
    }

    private var voiceTitle: String {
        guard let voice = store.voiceProfile else { return "唱 10 秒就行" }
        return voice.source == .measured ? "本次音区大概这样" : "先按常见范围排"
    }

    private var voiceSubtitle: String {
        guard let voice = store.voiceProfile else {
            return "大概看一下唱哪段更舒服，赶时间也能先排。"
        }
        return voice.source == .measured
            ? "按本次唱到的范围排歌，高音别连续上。"
            : "这是尚未实测时使用的参考，之后可以随时回来录一段。"
    }

    @ViewBuilder
    private var recordingContent: some View {
        switch store.recordingState {
        case .idle:
            if store.voiceProfile == nil {
                EmptyStateView(systemImage: "mic", text: "可以唱一小段，也可以先不测。")
            } else {
                EmptyStateView(systemImage: "checkmark.seal", text: "已经有一个参考范围，不确定的话可以重新测一次。")
            }
        case .requestingPermission:
            LoadingStateView(text: "正在打开麦克风")
        case .recording:
            VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                Text("录音中，\(store.recordingRemainingSeconds)s")
                    .font(TypographyTokens.metric)
                    .stageText()
                LiveWaveformView(level: store.recordingLevel)
            }
        case .analyzing:
            LoadingStateView(text: "正在整理本次音区")
        case let .failed(message):
            ErrorStateView(text: message)
        }
    }
}

private struct VoiceQuickGuideCard: View {
    private let tips = [
        "从舒服低音开始，慢慢唱到舒服高音，不用唱完整。",
        "赶时间可以先排歌，后面也能回来再测。",
        "这里只看大概音区，不评价唱得好不好。"
    ]

    var body: some View {
        GlassCard {
            Text("这样唱更容易听清")
                .font(TypographyTokens.section)
                .stageText()
            ForEach(tips, id: \.self) { tip in
                Label(tip, systemImage: "checkmark")
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
            }
        }
    }
}

struct VoiceRangeVisualizer: View {
    let profile: VoiceProfile

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.xs) {
            HStack {
                Text("低 \(midiNoteName(profile.stableLowMidi))")
                Spacer()
                Text("高 \(midiNoteName(profile.stableHighMidi))")
            }
            .font(TypographyTokens.caption.monospacedDigit())
            .foregroundStyle(DesignSystem.muted)
            GeometryReader { proxy in
                let low = CGFloat(max(0, profile.stableLowMidi - 40)) / 45
                let high = CGFloat(max(0, profile.stableHighMidi - 40)) / 45
                ZStack(alignment: .leading) {
                    Capsule().fill(DesignSystem.separator)
                    Capsule().fill(DesignSystem.cyan)
                        .frame(width: proxy.size.width * max(0.05, high - low))
                        .offset(x: proxy.size.width * min(max(low, 0), 1))
                }
            }
            .frame(height: 10)
        }
        .accessibilityLabel("\(profile.source.displayName) \(midiDisplayRange(profile))")
    }
}

struct LiveWaveformView: View {
    @Environment(\.appAccessibilityFlags) private var flags
    let level: Double

    var body: some View {
        HStack(alignment: .center, spacing: SpacingTokens.xs) {
            ForEach(0..<18, id: \.self) { index in
                let phase = Double(index % 6) / 6
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(DesignSystem.cyan)
                    .frame(width: 7, height: max(10, 64 * min(1, level + (flags.reduceMotion ? 0 : phase * 0.22))))
            }
        }
        .frame(height: 78)
        .frame(maxWidth: .infinity)
        .background(DesignSystem.raisedBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
        .accessibilityLabel("录音音量波形")
        .animation(flags.reduceMotion ? nil : .linear(duration: 0.10), value: level)
    }
}

typealias WaveformView = LiveWaveformView

private func midiDisplayRange(_ profile: VoiceProfile) -> String {
    "\(midiNoteName(profile.stableLowMidi)) 到 \(midiNoteName(profile.stableHighMidi))"
}

private func midiNoteName(_ midi: Int) -> String {
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    let note = names[(midi % 12 + 12) % 12]
    let octave = midi / 12 - 1
    return "\(note)\(octave)"
}

private func voiceConfidenceLabel(_ value: Double) -> String {
    switch value {
    case 0.75...:
        return "可以参考"
    case 0.45..<0.75:
        return "大概参考"
    default:
        return "建议再测"
    }
}
