import SwiftUI
import UIKit
import SingReadyAISharedKit

struct ExportView: View {
    @EnvironmentObject private var store: DemoWorkflowStore
    @State private var showJSON = false

    var body: some View {
        NightScreen(title: "导出") {
            if let plan = store.songPlan {
                posterPanel(plan)
                textPanel
                jsonPanel
            } else {
                Panel {
                    Label("暂无歌单，请先完成导入、画像和生成。", systemImage: "square.and.arrow.up")
                        .stageText()
                }
            }
        }
    }

    private func posterPanel(_ plan: SongPlan) -> some View {
        let summary = PosterRenderer().summary(for: plan)
        return Panel {
            Text(summary.title)
                .font(.title3.bold())
                .stageText()
            Text(summary.subtitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
            ForEach(summary.highlights, id: \.self) { line in
                Label(line, systemImage: "music.mic")
                    .font(.subheadline)
                    .stageText()
            }
        }
    }

    private var textPanel: some View {
        Panel {
            HStack {
                Text("文本歌单")
                    .font(.headline)
                    .stageText()
                Spacer()
                Button {
                    UIPasteboard.general.string = store.exportedText()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .tint(.cyan)
            }
            Text(store.exportedText())
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78))
                .textSelection(.enabled)
        }
    }

    private var jsonPanel: some View {
        Panel {
            Toggle(isOn: $showJSON) {
                Text("JSON 预览")
                    .font(.headline)
                    .stageText()
            }
            .tint(.pink)

            if showJSON {
                Text(store.exportedJSON())
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .textSelection(.enabled)
            }
        }
    }
}
