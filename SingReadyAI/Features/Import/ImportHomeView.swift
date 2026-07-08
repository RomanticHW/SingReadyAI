import PhotosUI
import SwiftUI
import SingReadyAISharedKit

struct ImportHomeView: View {
    @EnvironmentObject private var store: DemoWorkflowStore
    @State private var pastedText = """
    周杰伦 - 晴天
    陈奕迅《十年》
    孙燕姿 / 遇见
    歌名：告白气球 歌手：周杰伦
    """
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        NightScreen(title: "今晚唱什么") {
            statusPanel
            pendingPanel
            importActions
            if let playlist = store.importedPlaylist {
                importedSongsPanel(playlist)
            }
        }
        .onChange(of: selectedPhoto) { _, newValue in
            guard let newValue else { return }
            Task {
                if let data = try? await newValue.loadTransferable(type: Data.self) {
                    await store.importScreenshotData(data)
                }
                selectedPhoto = nil
            }
        }
    }

    private var statusPanel: some View {
        Panel {
            Text("KTV / 车载 K 歌歌单助手")
                .font(.title2.bold())
                .stageText()
            Text(store.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
            if store.isWorking {
                ProgressView()
                    .tint(.pink)
            }
        }
    }

    @ViewBuilder
    private var pendingPanel: some View {
        if !store.pendingImports.isEmpty {
            Panel {
                Label("发现分享导入", systemImage: "tray.and.arrow.down.fill")
                    .font(.headline)
                    .stageText()
                ForEach(store.pendingImports) { payload in
                    Button {
                        Task { await store.analyzePending(payload) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(payload.displayTitle ?? payload.sourceHint.displayName)
                                    .font(.subheadline.bold())
                                Text(payload.urlString ?? payload.rawText ?? payload.imageFileName ?? "待分析")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "arrow.right.circle.fill")
                        }
                    }
                    .buttonStyle(.plain)
                    .stageText()
                }
            }
        }
    }

    private var importActions: some View {
        Panel {
            Text("导入方式")
                .font(.headline)
                .stageText()

            PrimaryActionButton(title: "使用 Demo 歌单", systemImage: "play.fill") {
                Task { await store.useDemoPlaylist() }
            }

            TextEditor(text: $pastedText)
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.black.opacity(0.22))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)

            PrimaryActionButton(title: "解析粘贴文本", systemImage: "text.badge.checkmark") {
                Task { await store.importText(pastedText) }
            }

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label("截图 OCR 识别", systemImage: "text.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.cyan)
        }
    }

    private func importedSongsPanel(_ playlist: ImportedPlaylist) -> some View {
        Panel {
            Text(playlist.title)
                .font(.headline)
                .stageText()
            Text("\(playlist.source.displayName) · \(playlist.songs.count) 首 · 解析置信度 \(Int(playlist.parseConfidence * 100))%")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))

            ForEach(Array(store.matches.prefix(12))) { match in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: match.matchedTrack == nil ? "questionmark.circle" : "checkmark.circle.fill")
                        .foregroundStyle(match.matchedTrack == nil ? .orange : .green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(match.importedSong.title) - \(match.importedSong.artist ?? "未知歌手")")
                            .font(.subheadline.bold())
                            .stageText()
                        Text("\(match.status.displayName) · \(Int(match.score * 100))% · \(match.reason)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.62))
                    }
                }
            }
        }
    }
}
