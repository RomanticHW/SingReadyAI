import SwiftUI
import SingReadyAISharedKit

struct ProfileView: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        NightScreen(title: "画像") {
            if let profile = store.preferenceProfile {
                preferencePanel(profile)
                matchPanel
            } else {
                emptyPanel("先导入歌单，系统会生成偏好画像和 KTV 匹配报告。")
            }

            voicePanel
        }
    }

    private func preferencePanel(_ profile: PreferenceProfile) -> some View {
        Panel {
            Text("偏好画像")
                .font(.headline)
                .stageText()
            Text(profile.summary)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))

            metricRow("KTV 命中率", value: profile.ktvMatchRate)
            metricRow("平均可唱度", value: profile.averageSingAlongScore)
            metricRow("高音风险", value: profile.highNoteRisk)

            if !profile.topArtists.isEmpty {
                Text("高频歌手")
                    .font(.subheadline.bold())
                    .stageText()
                FlowLine(values: profile.topArtists.map { "\($0.name) ×\($0.count)" })
            }
        }
    }

    private var matchPanel: some View {
        Panel {
            Text("曲库匹配报告")
                .font(.headline)
                .stageText()
            let exact = store.matches.filter { $0.status == .exact }.count
            let fuzzy = store.matches.filter { $0.status == .fuzzy }.count
            let alternative = store.matches.filter { $0.status == .alternative }.count
            let unmatched = store.matches.filter { $0.status == .unmatched }.count
            FlowLine(values: ["精确 \(exact)", "模糊 \(fuzzy)", "替代 \(alternative)", "未匹配 \(unmatched)"])
        }
    }

    private var voicePanel: some View {
        Panel {
            HStack {
                Text("声线画像")
                    .font(.headline)
                    .stageText()
                Spacer()
                Button {
                    store.useSimulatedVoice()
                } label: {
                    Label("模拟声线", systemImage: "waveform")
                }
                .buttonStyle(.bordered)
                .tint(.cyan)
            }

            if let voice = store.voiceProfile {
                Text("\(voice.type.displayName) · 置信度 \(Int(voice.confidence * 100))%")
                    .font(.subheadline.bold())
                    .stageText()
                Text("稳定音域：\(voice.stableLowMidi)-\(voice.stableHighMidi) MIDI")
                    .foregroundStyle(.white.opacity(0.75))
                Text(voice.note)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            } else {
                Text("可录音 10 秒或使用模拟声线；默认不保存原始音频。")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    private func emptyPanel(_ text: String) -> some View {
        Panel {
            Label(text, systemImage: "music.note.list")
                .stageText()
        }
    }

    private func metricRow(_ title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text("\(Int(value * 100))%")
                    .stageText()
            }
            ProgressView(value: value)
                .tint(.pink)
        }
    }
}

struct FlowLine: View {
    let values: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .stageText()
            }
        }
    }
}
