import SwiftUI
import SingReadyAISharedKit

struct MatchReportView: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        FlowPage {
            if let profile = store.preferenceProfile {
                HeroHeader(
                    eyebrow: "KTV 曲库匹配",
                    title: "可唱率 \(Int(profile.ktvMatchRate * 100))%",
                    subtitle: profile.summary,
                    systemImage: "chart.bar.xaxis"
                )
                GlassCard {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                            Text("匹配结果")
                                .font(TypographyTokens.section)
                                .stageText()
                            TagCloud(values: profile.profileTags)
                        }
                        Spacer()
                        MatchRateRing(value: profile.ktvMatchRate)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: SpacingTokens.sm)], spacing: SpacingTokens.sm) {
                    MetricPill(title: "精确命中", value: "\(store.matchStats.exact)", systemImage: "checkmark.seal")
                    MetricPill(title: "模糊匹配", value: "\(store.matchStats.fuzzy)", systemImage: "scope")
                    MetricPill(title: "替代推荐", value: "\(store.matchStats.alternative)", systemImage: "arrow.triangle.branch")
                    MetricPill(title: "未匹配", value: "\(store.matchStats.unmatched)", systemImage: "questionmark.circle")
                }
                PreferenceInsightCard(profile: profile)
                GlassCard {
                    Text("场景适配")
                        .font(TypographyTokens.section)
                        .stageText()
                    ForEach(KTVScenario.allCases, id: \.self) { scenario in
                        MetricBar(title: scenario.displayName, value: profile.scenarioFitScores[scenario.rawValue] ?? 0)
                    }
                }
                GlassCard {
                    Text("下一步")
                        .font(TypographyTokens.section)
                        .stageText()
                    MetricBar(title: "平均难度", value: min(1, profile.averageDifficulty / 5), tint: DesignSystem.amber)
                    MetricBar(title: "高音风险", value: profile.highNoteRisk, tint: DesignSystem.warning)
                    MetricBar(title: "合唱友好度", value: profile.chorusFriendliness, tint: DesignSystem.success)
                    PrimaryGradientButton(title: "去做声线分析", systemImage: "waveform") {
                        store.currentStage = .voice
                    }
                }
            } else {
                GlassCard {
                    EmptyStateView(systemImage: "chart.bar", text: "完成导入确认后会生成匹配报告。")
                    SecondaryGlassButton(title: "返回确认", systemImage: "arrow.left") {
                        store.currentStage = .review
                    }
                }
            }
        }
    }
}

struct PreferenceInsightCard: View {
    let profile: PreferenceProfile

    var body: some View {
        GlassCard {
            Text("画像洞察")
                .font(TypographyTokens.section)
                .stageText()
            DistributionBars(title: "语种", values: profile.languageDistribution)
            DistributionBars(title: "年代", values: profile.eraDistribution)
            DistributionBars(title: "曲风", values: profile.genreDistribution)
            DistributionBars(title: "情绪", values: profile.moodTags)
        }
    }
}

struct DistributionBars: View {
    let title: String
    let values: [String: Double]

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.xs) {
            Text(title)
                .font(TypographyTokens.callout.weight(.semibold))
                .stageText()
            ForEach(values.sorted(by: { $0.value > $1.value }).prefix(5), id: \.key) { key, value in
                MetricBar(title: key, value: value)
            }
        }
    }
}

struct VoiceSetupView: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        FlowPage {
            HeroHeader(
                eyebrow: "声线分析",
                title: "10 秒找到稳定音域",
                subtitle: "真机录音只在本机内存处理 PCM 样本；模拟器可选择模拟声线继续演示。",
                systemImage: "waveform"
            )
            GlassCard {
                recordingContent
                HStack(spacing: SpacingTokens.sm) {
                    SecondaryGlassButton(title: "录音分析", systemImage: "record.circle") {
                        Task { await store.startVoiceRecording() }
                    }
                    SecondaryGlassButton(title: "模拟声线", systemImage: "waveform.path") {
                        store.useSimulatedVoice()
                    }
                }
                PrivacyNoteView(text: "不会保存原始音频；权限拒绝或样本不足时可以使用模拟声线继续。")
            }
            if let voice = store.voiceProfile {
                GlassCard {
                    Text("分析结果")
                        .font(TypographyTokens.section)
                        .stageText()
                    VoiceRangeVisualizer(profile: voice)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 144), spacing: SpacingTokens.sm)], spacing: SpacingTokens.sm) {
                        MetricPill(title: "声线类型", value: voice.type.displayName, systemImage: "person.wave.2")
                        MetricPill(title: "稳定音域", value: "\(voice.stableLowMidi)-\(voice.stableHighMidi)", systemImage: "music.quarternote.3")
                        MetricPill(title: "置信度", value: "\(Int(voice.confidence * 100))%", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    }
                    Text(voice.note)
                        .font(TypographyTokens.caption)
                        .foregroundStyle(DesignSystem.muted)
                    TagCloud(values: voice.suitableSongTypes, tint: DesignSystem.success)
                    TagCloud(values: voice.avoidSongTypes, tint: DesignSystem.warning)
                    PrimaryGradientButton(title: "选择 K 歌场景", systemImage: "person.3.sequence") {
                        store.currentStage = .scenario
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recordingContent: some View {
        switch store.recordingState {
        case .idle:
            EmptyStateView(systemImage: "mic", text: "可录音 10 秒，也可使用明确标识的模拟声线跑完整流程。")
        case .requestingPermission:
            LoadingStateView(text: "正在请求麦克风权限")
        case .recording:
            VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                Text("录音中 · \(store.recordingRemainingSeconds)s")
                    .font(TypographyTokens.metric)
                    .stageText()
                LiveWaveformView(level: store.recordingLevel)
            }
        case .analyzing:
            LoadingStateView(text: "正在分析音高稳定区间")
        case let .failed(message):
            ErrorStateView(text: message)
        }
    }
}

struct VoiceRangeVisualizer: View {
    let profile: VoiceProfile

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.xs) {
            HStack {
                Text("低 \(profile.stableLowMidi)")
                Spacer()
                Text("高 \(profile.stableHighMidi)")
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
        .accessibilityLabel("稳定音域 \(profile.stableLowMidi) 到 \(profile.stableHighMidi) MIDI")
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
    }
}

typealias WaveformView = LiveWaveformView

struct ScenarioBuilderView: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        FlowPage {
            HeroHeader(
                eyebrow: "场景策划",
                title: "把歌排成一晚的节奏",
                subtitle: "根据人数、时长、氛围和难度偏好生成分段歌单。",
                systemImage: "person.3.sequence"
            )
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: SpacingTokens.sm)], spacing: SpacingTokens.sm) {
                ForEach(KTVScenario.allCases, id: \.self) { scenario in
                    ScenarioCard(scenario: scenario, isSelected: store.scenarioConfig.scenario == scenario) {
                        store.scenarioConfig.scenario = scenario
                    }
                }
            }
            GlassCard {
                Stepper("人数 \(store.scenarioConfig.peopleCount)", value: $store.scenarioConfig.peopleCount, in: 1...16)
                    .stageText()
                VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                    Text("时长 \(store.scenarioConfig.durationMinutes) 分钟")
                        .stageText()
                    Slider(value: Binding(get: {
                        Double(store.scenarioConfig.durationMinutes)
                    }, set: {
                        store.scenarioConfig.durationMinutes = Int($0)
                    }), in: 30...180, step: 15)
                    .tint(DesignSystem.primary)
                }
                optionBlock("氛围", values: PlaylistVibe.allCases, selected: store.scenarioConfig.vibe, title: \.displayName) {
                    store.scenarioConfig.vibe = $0
                }
                optionBlock("难度", values: DifficultyPreference.allCases, selected: store.scenarioConfig.difficultyPreference, title: \.displayName) {
                    store.scenarioConfig.difficultyPreference = $0
                }
                optionBlock("合唱", values: ChorusPreference.allCases, selected: store.scenarioConfig.chorusPreference, title: \.displayName) {
                    store.scenarioConfig.chorusPreference = $0
                }
            }
            PrimaryGradientButton(title: "生成今晚歌单", systemImage: "sparkles") {
                store.generatePlan()
            }
        }
    }

    private func optionBlock<Value: Hashable>(_ label: String, values: [Value], selected: Value, title: KeyPath<Value, String>, onSelect: @escaping (Value) -> Void) -> some View {
        VStack(alignment: .leading, spacing: SpacingTokens.xs) {
            Text(label)
                .font(TypographyTokens.section)
                .stageText()
            ButtonGrid(values: values, selected: selected, title: title, onSelect: onSelect)
        }
    }
}

struct ScenarioCard: View {
    let scenario: KTVScenario
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? DesignSystem.ink : DesignSystem.cyan)
                Text(scenario.displayName)
                    .font(TypographyTokens.section)
                Text("\(scenario.sectionTemplates.count) 段编排")
                    .font(TypographyTokens.caption)
                    .foregroundStyle(isSelected ? DesignSystem.ink.opacity(0.78) : DesignSystem.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .padding(SpacingTokens.md)
            .background(isSelected ? DesignSystem.primary.opacity(0.88) : DesignSystem.raisedBackground)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(DesignSystem.ink)
        .accessibilityLabel("选择\(scenario.displayName)")
    }

    private var icon: String {
        switch scenario {
        case .friends: return "person.3"
        case .birthday: return "gift"
        case .teamBuilding: return "building.2"
        case .carKTV: return "car"
        case .couples: return "heart"
        case .soloPractice: return "music.mic"
        }
    }
}

struct ButtonGrid<Value: Hashable>: View {
    let values: [Value]
    let selected: Value
    let title: KeyPath<Value, String>
    let onSelect: (Value) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: SpacingTokens.xs)], spacing: SpacingTokens.xs) {
            ForEach(values, id: \.self) { value in
                Button {
                    onSelect(value)
                } label: {
                    Text(value[keyPath: title])
                        .font(TypographyTokens.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.ink)
                .background(selected == value ? DesignSystem.primary.opacity(0.86) : DesignSystem.raisedBackground)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
                .accessibilityLabel(value[keyPath: title])
            }
        }
    }
}
