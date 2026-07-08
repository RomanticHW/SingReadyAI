import PhotosUI
import SwiftUI
import SingReadyAISharedKit

struct ImportHubView: View {
    @EnvironmentObject private var store: DemoWorkflowStore
    @State private var pastedText = "周杰伦 - 晴天\n陈奕迅《十年》\n01 稻香 周杰伦\n歌名：告白气球 歌手：周杰伦"
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        FlowPage {
            HeroHeader(
                eyebrow: "导入入口",
                title: "今晚唱什么？",
                subtitle: "先把常听歌单变成可确认、可解释、可唱的 KTV 候选。",
                systemImage: "tray.and.arrow.down"
            )
            statusPanel
            pendingImportsPanel
            importActionsPanel
            recentImportsPanel
            PrivacyNoteView(text: "只读取本次主动分享、粘贴或选择的内容；平台链接会使用可演示 fixture 或文本 fallback。")
        }
        .onAppear { store.loadPendingImports() }
        .onChange(of: selectedPhoto) { _, newValue in
            guard let newValue else { return }
            Task {
                if let data = try? await newValue.loadTransferable(type: Data.self) {
                    await store.importScreenshotData(data)
                } else {
                    store.errorMessage = "图片读取失败，请改用粘贴文本。"
                }
                selectedPhoto = nil
            }
        }
    }

    private var statusPanel: some View {
        GlassCard {
            Text(store.statusMessage)
                .font(TypographyTokens.callout)
                .foregroundStyle(DesignSystem.muted)
            if store.isWorking {
                LoadingStateView(text: "正在处理导入内容")
            }
            if let error = store.errorMessage {
                ErrorStateView(text: error)
            }
        }
    }

    private var pendingImportsPanel: some View {
        GlassCard {
            HStack {
                Label("分享面板导入", systemImage: "square.and.arrow.down")
                    .font(TypographyTokens.section)
                    .stageText()
                Spacer()
                SourceBadge(title: store.isUsingFallbackStore ? "开发 fallback" : "App Group", tint: store.isUsingFallbackStore ? DesignSystem.warning : DesignSystem.cyan)
            }
            if store.pendingImports.isEmpty {
                EmptyStateView(systemImage: "square.and.arrow.up", text: "从音乐 App、照片或备忘录分享后会出现在这里。")
            } else {
                ForEach(store.pendingImports) { payload in
                    Button {
                        Task { await store.analyzePending(payload) }
                    } label: {
                        HStack(spacing: SpacingTokens.sm) {
                            Image(systemName: payload.sourceHint == .screenshot ? "photo" : "link")
                                .foregroundStyle(DesignSystem.cyan)
                            VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                                Text(payload.displayTitle ?? payload.sourceHint.displayName)
                                    .font(TypographyTokens.callout.weight(.semibold))
                                Text(payload.urlString ?? payload.rawText ?? payload.imageFileName ?? "待分析内容")
                                    .font(TypographyTokens.caption)
                                    .foregroundStyle(DesignSystem.muted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.ink)
                    .accessibilityLabel("分析\(payload.displayTitle ?? payload.sourceHint.displayName)")
                }
            }
        }
    }

    private var importActionsPanel: some View {
        GlassCard {
            Text("导入方式")
                .font(TypographyTokens.section)
                .stageText()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: SpacingTokens.sm)], spacing: SpacingTokens.sm) {
                PrimaryGradientButton(title: "Demo 歌单", systemImage: "play.fill") {
                    Task { await store.useDemoPlaylist() }
                }
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("截图 OCR", systemImage: "text.viewfinder")
                        .font(TypographyTokens.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: ComponentTokens.controlHeight)
                }
                .buttonStyle(.plain)
                .background(DesignSystem.raisedBackground)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
                .foregroundStyle(DesignSystem.ink)
                .accessibilityLabel("选择截图进行 OCR 识别")
            }
            TextEditor(text: $pastedText)
                .frame(minHeight: 128)
                .scrollContentBackground(.hidden)
                .padding(SpacingTokens.sm)
                .background(DesignSystem.raisedBackground)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
                .foregroundStyle(DesignSystem.ink)
                .accessibilityLabel("粘贴歌单文本")
            SecondaryGlassButton(title: "解析粘贴文本", systemImage: "text.badge.checkmark") {
                Task { await store.importText(pastedText) }
            }
        }
    }

    private var recentImportsPanel: some View {
        GlassCard {
            Text("最近导入")
                .font(TypographyTokens.section)
                .stageText()
            if store.recentImports.isEmpty {
                EmptyStateView(systemImage: "clock", text: "完成一次导入后会显示最近记录。")
            } else {
                ForEach(store.recentImports) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                            Text(record.title)
                                .font(TypographyTokens.callout.weight(.semibold))
                            Text("\(record.source.displayName) · \(record.songCount) 首")
                                .font(TypographyTokens.caption)
                                .foregroundStyle(DesignSystem.muted)
                        }
                        Spacer()
                    }
                    .foregroundStyle(DesignSystem.ink)
                }
            }
        }
    }
}

struct ImportReviewView: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        FlowPage {
            HeroHeader(
                eyebrow: "导入确认",
                title: "先确认，再匹配",
                subtitle: "\(store.activeReviewSongs.count) 首待匹配 · \(store.lowConfidenceReviewSongs.count) 首需要确认",
                systemImage: "checklist"
            )
            if let playlist = store.importedPlaylist {
                TagCloud(values: [playlist.source.displayName, "置信度 \(Int(playlist.parseConfidence * 100))%", playlist.title])
            }
            if store.reviewSongs.isEmpty {
                GlassCard {
                    EmptyStateView(systemImage: "music.note.list", text: "暂无解析歌曲，请返回导入。")
                    SecondaryGlassButton(title: "返回导入", systemImage: "arrow.left") {
                        store.currentStage = .importHub
                    }
                }
            } else {
                ForEach($store.reviewSongs) { $draft in
                    if !draft.isDeleted {
                        SongDraftEditor(draft: $draft)
                    }
                }
                PrimaryGradientButton(title: "开始匹配 KTV 曲库", systemImage: "chart.bar.xaxis") {
                    store.beginMatchingReviewedSongs()
                }
                PrivacyNoteView(text: "低置信度条目保留给你确认，避免把错误解析直接带入推荐。")
            }
        }
    }
}

struct SongDraftEditor: View {
    @Binding var draft: EditableImportedSongDraft

    var body: some View {
        GlassCard {
            HStack {
                SourceBadge(title: draft.needsReview ? "待确认" : "已识别", tint: draft.needsReview ? DesignSystem.warning : DesignSystem.success)
                Spacer()
                Text("\(Int(draft.confidence * 100))%")
                    .font(TypographyTokens.caption.monospacedDigit())
                    .foregroundStyle(DesignSystem.muted)
            }
            ConfidenceMeter(value: draft.confidence)
            TextField("歌名", text: $draft.title)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("编辑歌名")
            TextField("歌手", text: $draft.artist)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("编辑歌手")
            if !draft.versionTags.isEmpty {
                TagCloud(values: draft.versionTags, tint: DesignSystem.amber)
            }
            if !draft.rawText.isEmpty {
                Text(draft.rawText)
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
                    .lineLimit(2)
            }
            Button(role: .destructive) {
                draft.isDeleted = true
            } label: {
                Label("删除该条", systemImage: "trash")
            }
            .font(TypographyTokens.caption.weight(.semibold))
            .accessibilityLabel("删除\(draft.title)")
        }
    }
}
