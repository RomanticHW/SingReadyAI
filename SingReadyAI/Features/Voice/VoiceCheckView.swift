import SwiftUI
import SingReadyAISharedKit

struct VoiceCheckView: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        Panel {
            Text("10 秒声线检查")
                .font(.headline)
                .stageText()
            Text("MVP 中保留录音服务接口，面试和模拟器环境可直接使用模拟声线跑完整流程。")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
            PrimaryActionButton(title: "使用模拟声线", systemImage: "waveform") {
                store.useSimulatedVoice()
            }
        }
    }
}
