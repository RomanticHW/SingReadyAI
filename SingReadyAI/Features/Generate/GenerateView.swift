import SwiftUI
import SingReadyAISharedKit

struct GenerateView: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        NightScreen(title: "生成") {
            scenarioPanel
            VoiceCheckView()
            if let plan = store.songPlan {
                generatedPlanPanel(plan)
            } else {
                Panel {
                    Text("生成后会按场景分段展示推荐理由和风险提示。")
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
        }
    }

    private var scenarioPanel: some View {
        Panel {
            Text("场景参数")
                .font(.headline)
                .stageText()

            Picker("场景", selection: $store.scenarioConfig.scenario) {
                ForEach(KTVScenario.allCases, id: \.self) { scenario in
                    Text(scenario.displayName).tag(scenario)
                }
            }
            .pickerStyle(.segmented)

            Stepper("人数 \(store.scenarioConfig.peopleCount)", value: $store.scenarioConfig.peopleCount, in: 1...12)
                .stageText()

            VStack(alignment: .leading) {
                Text("时长 \(store.scenarioConfig.durationMinutes) 分钟")
                    .stageText()
                Slider(
                    value: Binding(
                        get: { Double(store.scenarioConfig.durationMinutes) },
                        set: { store.scenarioConfig.durationMinutes = Int($0) }
                    ),
                    in: 30...120,
                    step: 15
                )
                .tint(.pink)
            }

            Picker("氛围", selection: $store.scenarioConfig.vibe) {
                ForEach(PlaylistVibe.allCases, id: \.self) { vibe in
                    Text(vibe.displayName).tag(vibe)
                }
            }
            .pickerStyle(.segmented)

            Picker("合唱", selection: $store.scenarioConfig.chorusPreference) {
                ForEach(ChorusPreference.allCases, id: \.self) { preference in
                    Text(preference.displayName).tag(preference)
                }
            }
            .pickerStyle(.segmented)

            Picker("难度", selection: $store.scenarioConfig.difficultyPreference) {
                ForEach(DifficultyPreference.allCases, id: \.self) { preference in
                    Text(preference.displayName).tag(preference)
                }
            }
            .pickerStyle(.segmented)

            PrimaryActionButton(title: "生成歌单", systemImage: "sparkles") {
                store.generatePlan()
            }
            .disabled(store.preferenceProfile == nil)
        }
    }

    private func generatedPlanPanel(_ plan: SongPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(plan.sections) { section in
                Panel {
                    Text(section.title)
                        .font(.headline)
                        .stageText()
                    Text(section.goal)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))

                    ForEach(section.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("\(item.track.title) - \(item.track.artist)")
                                    .font(.subheadline.bold())
                                    .stageText()
                                Spacer()
                                Text("\(Int(item.score * 100))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.cyan)
                            }
                            ForEach(item.reasons, id: \.self) { reason in
                                Label(reason, systemImage: "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.72))
                            }
                            ForEach(item.riskWarnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }
}
