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

struct ImportReviewSummaryCard: View {
    let summary: ImportReviewSummary

    var body: some View {
        GlassCard {
            Text(summaryText)
                .font(TypographyTokens.section)
                .foregroundStyle(DesignSystem.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("review-summary")

            Label(guidanceText, systemImage: guidanceSystemImage)
                .font(TypographyTokens.callout)
                .foregroundStyle(guidanceTint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summaryText: String {
        "共 \(summary.totalCount) 首 · 建议看 \(summary.attentionCount) 首 · 缺歌名 \(summary.missingTitleCount) 首"
    }

    private var guidanceText: String {
        if summary.missingTitleCount > 0 {
            return "补上歌名后才能开始匹配"
        }
        if summary.attentionCount > 0 {
            return "这些信息可能不完整，不处理也能继续"
        }
        return "歌名都整理好了，可以直接批量匹配"
    }

    private var guidanceSystemImage: String {
        if summary.missingTitleCount > 0 { return "exclamationmark.circle.fill" }
        if summary.attentionCount > 0 { return "info.circle.fill" }
        return "checkmark.circle.fill"
    }

    private var guidanceTint: Color {
        if summary.missingTitleCount > 0 { return DesignSystem.warning }
        if summary.attentionCount > 0 { return DesignSystem.muted }
        return DesignSystem.success
    }
}

struct SongDraftEditor: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let draft: EditableImportedSongDraft
    let onTitleChange: (String) -> Void
    let onArtistChange: (String) -> Void
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
                TextField(
                    "歌名",
                    text: Binding(get: { draft.title }, set: onTitleChange)
                )
                    .stageInputField()
                    .accessibilityLabel("编辑歌名")
                TextField(
                    "歌手",
                    text: Binding(get: { draft.artist }, set: onArtistChange)
                )
                    .stageInputField()
                    .accessibilityLabel("编辑歌手")
            }

            if !draft.hasValidTitle {
                Label("歌名不能为空，补上后才能继续。", systemImage: "exclamationmark.circle")
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.warning)
            } else if draft.needsAttention {
                Label("少歌手也能继续，补一下会更准。", systemImage: "info.circle")
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
            }
            if !draft.versionTags.isEmpty {
                TagCloud(values: draft.versionTags, tint: DesignSystem.amber)
            }
            if draft.needsAttention, !draft.rawText.isEmpty {
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
                .stroke(statusTint.opacity(draft.needsAttention ? 0.42 : 0.24), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
        .accessibilityIdentifier("review-song-editor")
    }

    private var fieldColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())]
    }

    private var statusTitle: String {
        if !draft.hasValidTitle { return "补歌名" }
        return draft.needsAttention ? "看一下" : "已整理"
    }

    private var statusTint: Color {
        draft.needsAttention ? DesignSystem.warning : DesignSystem.success
    }
}
