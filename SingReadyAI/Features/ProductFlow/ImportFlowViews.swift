import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import SingReadyAISharedKit

struct ImportHubView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var store: DemoWorkflowStore
    @State private var pastedText = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoLoadTask: Task<Void, Never>?
    @State private var pendingDeleteID: UUID?
    @State private var recentDeleteID: UUID?
    @State private var showClearLocalDataConfirmation = false
    @FocusState private var isPasteEditorFocused: Bool

    var body: some View {
        FlowPage {
            HeroHeader(
                eyebrow: "导入歌单",
                title: "先把歌单放进来",
                subtitle: "公开歌单链接、截图、粘贴文本都可以，先把歌名弄清楚。",
                systemImage: "tray.and.arrow.down"
            )
            pendingImportsPanel
            importActionsPanel
            pasteImportPanel
            if store.shouldShowImportStatus {
                statusPanel
            }
            recentImportsPanel
            localDataPanel
            PrivacyNoteView(text: "只读取本次主动分享、粘贴或选择的内容；公开 HTTPS 链接认不出来时，可改用分享文本或截图。")
        }
        .task { await store.loadPendingImports() }
        .onChange(of: selectedPhoto) { _, newValue in
            guard let newValue else { return }
            photoLoadTask?.cancel()
            let epoch = store.localDataEpoch
            selectedPhoto = nil
            photoLoadTask = Task { @MainActor in
                defer { photoLoadTask = nil }
                do {
                    guard let importedFile = try await newValue.loadTransferable(
                        type: ImportedScreenshotFile.self
                    ) else {
                        throw ImageImportSafetyError.invalidImage
                    }
                    guard !Task.isCancelled,
                          store.acceptsLocalDataEpoch(epoch) else {
                        try? await OCRTemporaryFileStore().removePreparedImage(at: importedFile.url)
                        return
                    }
                    await store.importScreenshotFile(at: importedFile.url)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled,
                          store.acceptsLocalDataEpoch(epoch) else { return }
                    store.errorMessage = error.localizedDescription
                    store.statusMessage = store.errorMessage ?? store.statusMessage
                }
            }
        }
        .onDisappear {
            photoLoadTask?.cancel()
            photoLoadTask = nil
        }
        .confirmationDialog(
            "删除这份待整理内容？",
            isPresented: pendingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除内容", role: .destructive) {
                guard let pendingDeleteID else { return }
                self.pendingDeleteID = nil
                Task { await store.removePendingImport(id: pendingDeleteID) }
            }
            Button("取消", role: .cancel) {
                pendingDeleteID = nil
            }
        } message: {
            Text("如果这份内容带截图，对应的本机图片也会一起删除。")
        }
        .confirmationDialog(
            "删除这条最近导入？",
            isPresented: recentDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除记录", role: .destructive) {
                guard let recentDeleteID else { return }
                Task { await store.removeRecentPlaylist(id: recentDeleteID) }
                self.recentDeleteID = nil
            }
            Button("取消", role: .cancel) {
                recentDeleteID = nil
            }
        } message: {
            Text("只删除最近导入记录，不影响当前正在整理或已经排好的歌单。")
        }
        .alert("清除所有本机记录？", isPresented: $showClearLocalDataConfirmation) {
            Button("取消", role: .cancel) {}
            Button("全部清除", role: .destructive) {
                photoLoadTask?.cancel()
                photoLoadTask = nil
                Task { await store.clearAllLocalData() }
            }
        } message: {
            Text("待整理分享、最近导入、当前歌单、歌曲反馈、最近一次实测音区、共享截图和临时导出文件都会删除，且无法撤销。")
        }
    }

    private var statusPanel: some View {
        GlassCard {
            if store.errorMessage == nil, !store.isImportResolving {
                Text(store.statusMessage)
                    .font(TypographyTokens.callout)
                    .foregroundStyle(DesignSystem.muted)
            }
            if store.isImportResolving {
                LoadingStateView(
                    text: store.isCommittingImportedWorkflow
                        ? "正在保存新歌单"
                        : store.statusMessage
                )
                if !store.isCommittingImportedWorkflow {
                    Button {
                        store.cancelCurrentImport()
                    } label: {
                        Label("取消本次导入", systemImage: "xmark.circle")
                            .font(TypographyTokens.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: ComponentTokens.minTouchTarget)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("取消本次导入")
                }
            }
            if let error = store.errorMessage {
                ErrorStateView(text: error)
            }
        }
    }

    private var pendingImportsPanel: some View {
        GlassCard {
            HStack {
                Label("刚分享过来的歌单", systemImage: "square.and.arrow.down")
                    .font(TypographyTokens.section)
                    .stageText()
                Spacer()
                if !store.pendingImports.isEmpty || store.isUsingFallbackStore {
                    SourceBadge(title: store.isUsingFallbackStore ? "本机保存" : "还没整理", tint: store.isUsingFallbackStore ? DesignSystem.warning : DesignSystem.cyan)
                }
            }
            if store.pendingImports.isEmpty {
                EmptyStateView(systemImage: "square.and.arrow.up", text: "从音乐软件、相册或备忘录分享过来的歌单会放在这里。")
            } else {
                ForEach(store.pendingImports) { payload in
                    HStack(spacing: SpacingTokens.sm) {
                        Button {
                            Task { await store.analyzePending(payload) }
                        } label: {
                            HStack(spacing: SpacingTokens.sm) {
                                Image(systemName: payload.sourceHint == .screenshot ? "photo" : "link")
                                    .foregroundStyle(DesignSystem.cyan)
                                VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                                    Text(payload.displayTitle ?? payload.sourceHint.displayName)
                                        .font(TypographyTokens.callout.weight(.semibold))
                                    Text(payload.urlString ?? payload.rawText ?? payload.imageFileName ?? "这份歌单")
                                        .font(TypographyTokens.caption)
                                        .foregroundStyle(DesignSystem.muted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .frame(maxWidth: .infinity, minHeight: ComponentTokens.minTouchTarget, alignment: .leading)
                        }
                        .buttonStyle(PressedScaleButtonStyle(scale: 0.98))
                        .foregroundStyle(DesignSystem.ink)
                        .accessibilityLabel("整理\(payload.displayTitle ?? payload.sourceHint.displayName)")
                        .disabled(store.isImportInteractionDisabled)

                        Button(role: .destructive) {
                            pendingDeleteID = payload.id
                        } label: {
                            Image(systemName: "trash")
                                .frame(minWidth: ComponentTokens.minTouchTarget, minHeight: ComponentTokens.minTouchTarget)
                        }
                        .accessibilityLabel("删除待整理\(payload.displayTitle ?? payload.sourceHint.displayName)")
                        .disabled(store.isImportInteractionDisabled)
                    }
                    .padding(.vertical, SpacingTokens.xs)
                }
            }
        }
    }

    private var importActionsPanel: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            Text("选一种方式")
                .font(TypographyTokens.section)
                .stageText()
            GlassSurfaceGroup {
                LazyVGrid(columns: importActionColumns, spacing: SpacingTokens.sm) {
                    Button {
                        Haptics.selection()
                        Task { await store.useDemoPlaylist() }
                    } label: {
                        ImportActionTile(title: "用示例歌单", subtitle: "先拿一份热门歌单试试", systemImage: "play.fill", tint: DesignSystem.cyan)
                    }
                    .buttonStyle(PressedScaleButtonStyle(scale: 0.97))
                    .foregroundStyle(DesignSystem.ink)
                    .accessibilityLabel("用示例歌单")
                    .disabled(store.isImportInteractionDisabled)

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        ImportActionTile(title: "识别截图", subtitle: "从截图里找歌名", systemImage: "text.viewfinder", tint: DesignSystem.primary)
                    }
                    .buttonStyle(PressedScaleButtonStyle(scale: 0.97))
                    .foregroundStyle(DesignSystem.ink)
                    .accessibilityLabel("选择截图识别歌单")
                    .disabled(store.isImportInteractionDisabled)
                }
            }
        }
    }

    private var importActionColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: SpacingTokens.sm), GridItem(.flexible(), spacing: SpacingTokens.sm)]
    }

    private var pasteImportPanel: some View {
        GlassCard {
            Text("粘贴链接或文本")
                .font(TypographyTokens.section)
                .stageText()
            ZStack(alignment: .topLeading) {
                TextEditor(text: $pastedText)
                    .stageTextEditor()
                    .focused($isPasteEditorFocused)
                    .accessibilityLabel("粘贴歌单文本")
                    .accessibilityHint("也支持公开歌单链接")
                if pastedText.isEmpty {
                    Text("粘贴公开歌单链接，或歌名文本，比如：周杰伦 - 晴天")
                        .font(TypographyTokens.callout)
                        .foregroundStyle(DesignSystem.weak)
                        .padding(.horizontal, SpacingTokens.md)
                        .padding(.vertical, SpacingTokens.md)
                        .allowsHitTesting(false)
                }
            }
            SecondaryGlassButton(title: "整理这段歌单", systemImage: "text.badge.checkmark") {
                let text = trimmedPastedText
                isPasteEditorFocused = false
                Task { @MainActor in
                    await Task.yield()
                    await store.importText(text)
                }
            }
            .disabled(!hasPastedText || store.isImportInteractionDisabled)
        }
    }

    private var trimmedPastedText: String {
        pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasPastedText: Bool {
        !trimmedPastedText.isEmpty
    }

    private var recentImportsPanel: some View {
        GlassCard {
            Text("最近导入")
                .font(TypographyTokens.section)
                .stageText()
            if store.recentPlaylists.isEmpty {
                EmptyStateView(systemImage: "clock", text: "用过的歌单会放在这里。")
            } else {
                ForEach(store.recentPlaylists) { playlist in
                    HStack(spacing: SpacingTokens.sm) {
                        Button {
                            store.reopenRecentPlaylist(playlist)
                        } label: {
                            HStack(spacing: SpacingTokens.sm) {
                                VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                                    Text(playlist.title)
                                        .font(TypographyTokens.callout.weight(.semibold))
                                    Text("\(playlist.source.displayName)，\(playlist.songs.count) 首")
                                        .font(TypographyTokens.caption)
                                        .foregroundStyle(DesignSystem.muted)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.forward.app")
                                    .foregroundStyle(DesignSystem.cyan)
                            }
                            .frame(maxWidth: .infinity, minHeight: ComponentTokens.minTouchTarget, alignment: .leading)
                        }
                        .buttonStyle(PressedScaleButtonStyle(scale: 0.98))
                        .foregroundStyle(DesignSystem.ink)
                        .accessibilityIdentifier("reopen-recent-\(playlist.id.uuidString)")
                        .accessibilityLabel("重新打开\(playlist.title)")
                        .accessibilityValue("\(playlist.source.displayName)，\(playlist.songs.count) 首")
                        .disabled(store.isImportInteractionDisabled)

                        Button(role: .destructive) {
                            recentDeleteID = playlist.id
                        } label: {
                            Image(systemName: "trash")
                                .frame(minWidth: ComponentTokens.minTouchTarget, minHeight: ComponentTokens.minTouchTarget)
                        }
                        .accessibilityIdentifier("delete-recent-\(playlist.id.uuidString)")
                        .accessibilityLabel("删除最近导入\(playlist.title)")
                        .accessibilityValue("\(playlist.source.displayName)，\(playlist.songs.count) 首")
                        .disabled(store.isImportInteractionDisabled)
                    }
                    .padding(.vertical, SpacingTokens.xs)
                }
            }
        }
    }

    private var localDataPanel: some View {
        GlassCard {
            Text("本机数据")
                .font(TypographyTokens.section)
                .stageText()
            Text("可以一次清除待整理分享、最近导入、当前歌单、反馈、最近一次实测音区和共享截图。")
                .font(TypographyTokens.caption)
                .foregroundStyle(DesignSystem.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(role: .destructive) {
                showClearLocalDataConfirmation = true
            } label: {
                Label("清除本机记录", systemImage: "trash")
                    .font(TypographyTokens.callout.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: ComponentTokens.minTouchTarget)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("清除本机记录")
            .disabled(store.isManagingLocalData || store.isCommittingImportedWorkflow)
        }
    }

    private var pendingDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        )
    }

    private var recentDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { recentDeleteID != nil },
            set: { if !$0 { recentDeleteID = nil } }
        )
    }
}

private struct ImportedScreenshotFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { receivedFile in
            let preparedURL = try await OCRTemporaryFileStore().prepareImageFile(
                from: receivedFile.file
            )
            return ImportedScreenshotFile(url: preparedURL)
        }
    }
}

private struct ImportActionTile: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                Text(title)
                    .font(TypographyTokens.callout.weight(.semibold))
                Text(subtitle)
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
            Spacer(minLength: 0)
        }
        .padding(SpacingTokens.md)
        .frame(maxWidth: .infinity, minHeight: 106, alignment: .leading)
        .liquidGlassSurface(
            cornerRadius: DesignSystem.cornerRadius,
            tint: tint.opacity(0.035),
            fallback: DesignSystem.raisedBackground,
            interactive: true
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                .stroke(DesignSystem.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))
    }
}

struct ImportReviewView: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        FlowPage {
            HeroHeader(
                eyebrow: "整理歌单",
                title: "先看一眼歌名",
                subtitle: reviewSubtitle,
                systemImage: "checklist"
            )
            if let playlist = store.importedPlaylist {
                TagCloud(values: [playlist.source.displayName, "大多能认出来", playlist.title])
            }
            if store.reviewSongs.isEmpty {
                GlassCard {
                    EmptyStateView(systemImage: "music.note.list", text: "还没有歌单，先放进来一份。")
                    SecondaryGlassButton(title: "导入歌单", systemImage: "tray.and.arrow.down") {
                        store.setStage(.importHub)
                    }
                }
            } else if store.activeReviewSongs.isEmpty {
                if let undo = store.lastReviewSongUndo {
                    UndoBanner(message: "已删《\(undo.title)》", actionTitle: "撤销删除") {
                        store.undoReviewSongDeletion()
                    }
                }
                GlassCard {
                    EmptyStateView(systemImage: "music.note.list", text: "歌单里的歌都删掉了，可以撤销上一首或重新导入。")
                    SecondaryGlassButton(title: "重新导入歌单", systemImage: "tray.and.arrow.down") {
                        store.setStage(.importHub)
                    }
                }
            } else {
                matchButton
                if let undo = store.lastReviewSongUndo {
                    UndoBanner(message: "已删《\(undo.title)》", actionTitle: "撤销删除") {
                        store.undoReviewSongDeletion()
                    }
                }
                ForEach(store.reviewSongs) { draft in
                    if !draft.isDeleted {
                        SongDraftEditor(
                            draft: draft,
                            onTitleChange: {
                                store.commitReviewMutation(.updateTitle(id: draft.id, value: $0))
                            },
                            onArtistChange: {
                                store.commitReviewMutation(.updateArtist(id: draft.id, value: $0))
                            },
                            onDelete: {
                                store.commitReviewMutation(.delete(id: draft.id))
                            }
                        )
                        .disabled(store.isWorking)
                    }
                }
                matchButton
                PrivacyNoteView(text: "不确定的歌名先留给你看一眼，后面排歌会更准。")
            }
        }
    }

    @ViewBuilder
    private var matchButton: some View {
        if store.isWorking {
            GlassCard {
                LoadingStateView(text: "正在核对本地参考命中")
                    .accessibilityIdentifier("matching-progress")
                SecondaryGlassButton(title: "取消核对", systemImage: "xmark.circle") {
                    store.cancelCurrentMatching()
                }
            }
        } else {
            PrimaryGradientButton(title: "看看本地参考命中", systemImage: "chart.bar.xaxis") {
                ReviewMatchingLauncher.begin(store: store)
            }
            .disabled(store.activeReviewSongs.isEmpty || !store.untitledReviewSongs.isEmpty)
        }
    }

    private var reviewSubtitle: String {
        let total = store.activeReviewSongs.count
        if !store.reviewSongs.isEmpty, total == 0 {
            return "刚才的歌曲都已删除，可以撤销上一首或重新导入。"
        }
        let untitled = store.untitledReviewSongs.count
        let uncertain = store.lowConfidenceReviewSongs.count
        if untitled > 0 {
            return "\(total) 首歌里有 \(untitled) 首缺少歌名，补上后才能核对参考命中。"
        }
        if uncertain == 0 {
            return "\(total) 首歌都整理好了，不想改就直接核对参考命中。"
        }
        return "\(total) 首歌里有 \(uncertain) 首建议看一下，可能是歌手或版本名。"
    }
}
