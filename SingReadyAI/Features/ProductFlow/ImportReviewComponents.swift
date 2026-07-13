import PhotosUI
import SwiftUI
import SingReadyAISharedKit
#if canImport(UIKit)
import UIKit
#endif

enum ReviewMatchingLauncher {
    @MainActor
    static func begin(store: DemoWorkflowStore) {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        #endif
        Task { @MainActor in
            await Task.yield()
            await store.beginMatchingReviewedSongs()
        }
    }
}

struct SongDraftEditor: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var draft: EditableImportedSongDraft
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            HStack(spacing: SpacingTokens.sm) {
                SourceBadge(title: statusTitle, tint: statusTint)
                Spacer()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删掉", systemImage: "trash")
                        .font(TypographyTokens.caption.weight(.semibold))
                        .frame(minWidth: ComponentTokens.minTouchTarget, minHeight: ComponentTokens.minTouchTarget)
                }
                .accessibilityLabel("删除\(draft.displayTitle)")
            }

            LazyVGrid(columns: fieldColumns, spacing: SpacingTokens.xs) {
                TextField("歌名", text: $draft.title)
                    .stageInputField()
                    .accessibilityLabel("编辑歌名")
                TextField("歌手", text: $draft.artist)
                    .stageInputField()
                    .accessibilityLabel("编辑歌手")
            }

            if !draft.hasValidTitle {
                Label("歌名不能为空，补上后才能继续。", systemImage: "exclamationmark.circle")
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.warning)
            } else if draft.needsReview {
                Label("少歌手也能继续，补一下会更准。", systemImage: "info.circle")
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
            }
            if !draft.versionTags.isEmpty {
                TagCloud(values: draft.versionTags, tint: DesignSystem.amber)
            }
            if draft.needsReview, !draft.rawText.isEmpty {
                Text(draft.rawText)
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
                    .lineLimit(2)
            }
        }
        .padding(SpacingTokens.sm)
        .liquidGlassSurface(
            cornerRadius: DesignSystem.radiusSmall,
            tint: statusTint.opacity(0.045),
            fallback: DesignSystem.raisedBackground
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                .stroke(statusTint.opacity(draft.needsReview ? 0.42 : 0.24), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
    }

    private var fieldColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())]
    }

    private var statusTitle: String {
        if !draft.hasValidTitle { return "补歌名" }
        return draft.needsReview ? "看一下" : "已整理"
    }

    private var statusTint: Color {
        draft.needsReview ? DesignSystem.warning : DesignSystem.success
    }
}
