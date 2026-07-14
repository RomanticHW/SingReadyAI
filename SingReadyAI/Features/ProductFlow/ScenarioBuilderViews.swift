import SwiftUI
import SingReadyAISharedKit

struct ScenarioBuilderView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        FlowPage {
            HeroHeader(
                eyebrow: isSoloPractice ? "排练唱单" : "排今晚歌单",
                title: isSoloPractice ? "按今天的练唱来排" : "按今晚的局来排",
                subtitle: isSoloPractice
                    ? "不想细调就直接排；想换时长、难度或练唱氛围，再点下面的选项。"
                    : "不想细调就直接排；想换场合、人数或氛围，再点下面的选项。",
                systemImage: "person.3.sequence"
            )
            LazyVGrid(columns: scenarioColumns, spacing: SpacingTokens.sm) {
                ForEach(KTVScenario.allCases, id: \.self) { scenario in
                    ScenarioCard(scenario: scenario, isSelected: store.scenarioConfig.scenario == scenario) {
                        store.selectScenario(scenario)
                    }
                }
            }
            if store.scenarioConfig.scenario == .carKTV {
                CarSafetyNoticeView()
            }
            GlassCard {
                peopleCountControl
                VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                    Text("时长 \(store.scenarioConfig.durationMinutes) 分钟")
                        .stageText()
                    Slider(value: Binding(get: {
                        Double(store.scenarioConfig.durationMinutes)
                    }, set: {
                        store.setScenarioDuration(Int($0))
                    }), in: 30...180, step: 15)
                    .tint(DesignSystem.cyan)
                    .accessibilityLabel("时长")
                    .accessibilityValue("\(store.scenarioConfig.durationMinutes) 分钟")
                }
                optionBlock("氛围", values: availableVibes, selected: store.scenarioConfig.vibe, title: \.displayName) {
                    store.setScenarioVibe($0)
                }
                optionBlock("想唱多难", values: DifficultyPreference.allCases, selected: store.scenarioConfig.difficultyPreference, title: \.displayName) {
                    store.setScenarioDifficulty($0)
                }
                if store.scenarioConfig.scenario == .soloPractice {
                    HStack(spacing: SpacingTokens.sm) {
                        Text("练唱方式")
                            .font(TypographyTokens.section)
                            .stageText()
                        Spacer(minLength: SpacingTokens.sm)
                        Label("独自练唱", systemImage: "person.fill")
                            .font(TypographyTokens.callout.weight(.semibold))
                            .foregroundStyle(DesignSystem.cyan)
                    }
                    .frame(minHeight: ComponentTokens.minTouchTarget)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("练唱方式 独自练唱")
                    .accessibilityIdentifier("scenario-solo-practice-mode")
                } else {
                    optionBlock("合唱多少", values: ChorusPreference.allCases, selected: store.scenarioConfig.chorusPreference, title: \.displayName) {
                        store.setScenarioChorusPreference($0)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            generateButton
                .padding(.horizontal, DesignSystem.pageHorizontalPadding)
                .padding(.vertical, SpacingTokens.xs)
                .background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var generateButton: some View {
        if store.isGeneratingPlan {
            VStack(spacing: SpacingTokens.xs) {
                LoadingStateView(text: "正在按最新选择排歌")
                    .accessibilityIdentifier("plan-generation-progress")
                SecondaryGlassButton(title: "取消重排", systemImage: "xmark.circle") {
                    store.cancelCurrentPlanGeneration()
                }
            }
        } else if case let .failed(message, retryable, previous) = store.planGenerationState {
            VStack(spacing: SpacingTokens.xs) {
                ErrorStateView(text: message)
                if previous != nil {
                    Text("上一版还在，重新排好前不会用于分享或开唱小抄。")
                        .font(TypographyTokens.caption)
                        .foregroundStyle(DesignSystem.muted)
                }
                if retryable {
                    PrimaryGradientButton(
                        title: "重新排一版",
                        systemImage: "arrow.clockwise"
                    ) {
                        store.generatePlan()
                    }
                }
            }
        } else if case let .stale(snapshot) = store.planGenerationState {
            VStack(spacing: SpacingTokens.xs) {
                Text(snapshot.reason)
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
                PrimaryGradientButton(
                    title: "按最新选择重排",
                    systemImage: "arrow.triangle.2.circlepath"
                ) {
                    store.generatePlan()
                }
            }
        } else if case .running = store.matchOperationState {
            VStack(spacing: SpacingTokens.xs) {
                LoadingStateView(text: store.matchingProgressText)
                SecondaryGlassButton(title: "取消核对", systemImage: "xmark.circle") {
                    store.cancelCurrentMatching()
                }
            }
        } else {
            PrimaryGradientButton(
                title: store.readySongPlan == nil
                    ? (isSoloPractice ? "排一份练唱单" : "排一份今晚歌单")
                    : "再排一版",
                systemImage: "sparkles"
            ) {
                store.generatePlan()
            }
        }
    }

    private var isSoloPractice: Bool {
        store.scenarioConfig.scenario == .soloPractice
    }

    @ViewBuilder
    private var peopleCountControl: some View {
        if let fixedCount = store.scenarioConfig.scenario.fixedPeopleCount {
            HStack(spacing: SpacingTokens.sm) {
                Text("人数")
                    .stageText()
                Spacer(minLength: SpacingTokens.sm)
                Text("\(fixedCount) 人")
                    .font(TypographyTokens.callout.weight(.semibold))
                    .foregroundStyle(DesignSystem.cyan)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("人数 \(fixedCount)")
            .accessibilityIdentifier("scenario-fixed-people-count")
        } else {
            Stepper(
                "人数 \(store.scenarioConfig.peopleCount)",
                value: Binding(
                    get: { store.scenarioConfig.peopleCount },
                    set: { store.setScenarioPeopleCount($0) }
                ),
                in: store.scenarioConfig.scenario.minimumPeopleCount...16
            )
                .stageText()
                .accessibilityIdentifier("scenario-people-stepper")
        }
    }

    private var scenarioColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 150), spacing: SpacingTokens.sm)]
    }

    private var availableVibes: [PlaylistVibe] {
        store.scenarioConfig.scenario == .soloPractice
            ? PlaylistVibe.allCases.filter { $0 != .chorus }
            : PlaylistVibe.allCases
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

struct CarSafetyNoticeView: View {
    private let message = "驾驶者不操作手机，由乘客操作；没有乘客时，请安全停车后再操作。"

    var body: some View {
        Label(message, systemImage: "car.fill")
            .font(TypographyTokens.callout.weight(.semibold))
            .foregroundStyle(DesignSystem.warning)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SpacingTokens.sm)
            .background(DesignSystem.warning.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                    .stroke(DesignSystem.warning.opacity(0.34), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message)
            .accessibilityIdentifier("car-safety-notice")
    }
}

struct ScenarioCard: View {
    @Environment(\.appAccessibilityFlags) private var flags
    let scenario: KTVScenario
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            withAnimation(flags.reduceMotion ? nil : MotionTokens.micro) {
                action()
            }
        } label: {
            VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? DesignSystem.cyan : DesignSystem.muted)
                Text(scenario.displayName)
                    .font(TypographyTokens.section)
                Text(scenarioHint)
                    .font(TypographyTokens.caption)
                    .foregroundStyle(isSelected ? DesignSystem.ink.opacity(0.78) : DesignSystem.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .padding(SpacingTokens.md)
            .background {
                RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                    .fill(DesignSystem.raisedBackground)
                if isSelected {
                    selectedScenarioBackground
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                    .stroke(isSelected ? DesignSystem.cyan.opacity(0.62) : DesignSystem.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
        }
        .buttonStyle(PressedScaleButtonStyle(scale: 0.97))
        .foregroundStyle(DesignSystem.ink)
        .accessibilityLabel("选择\(scenario.displayName)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var selectedScenarioBackground: some View {
        LinearGradient(
            colors: [
                DesignSystem.cyan.opacity(0.24),
                DesignSystem.raisedBackgroundHigh.opacity(0.92),
                DesignSystem.cyan.opacity(0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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

    private var scenarioHint: String {
        switch scenario {
        case .friends: return "先唱大家熟的"
        case .birthday: return "先留祝福歌"
        case .teamBuilding: return "大家都会一点"
        case .carKTV: return "轻松一点"
        case .couples: return "甜歌和对唱"
        case .soloPractice: return "先稳再挑战"
        }
    }
}
