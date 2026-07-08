import SwiftUI

struct ShareExtensionView: View {
    let title: String
    let message: String
    let source: String
    let preview: String
    let usesFallbackStore: Bool
    let isDone: Bool
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: isDone ? "checkmark.circle.fill" : "tray.and.arrow.down")
                .font(.headline)
                .foregroundStyle(isDone ? .green : .primary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Label(source, systemImage: "music.note.list")
                    .font(.subheadline.weight(.semibold))
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                if usesFallbackStore {
                    Label("开发模式 fallback：未检测到 App Group 容器", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Label("只读取本次用户主动分享的内容，不访问第三方 App 私有歌单数据库。", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: onDone) {
                Label(isDone ? "打开今晚唱什么继续分析" : "完成", systemImage: isDone ? "arrow.up.forward.app" : "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
    }
}
