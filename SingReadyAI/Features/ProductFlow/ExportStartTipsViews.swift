import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import SingReadyAISharedKit

#if canImport(UIKit)
import UIKit
#endif
#if canImport(Photos)
import Photos
#endif

struct ExportCenterView: View {
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var store: DemoWorkflowStore
    @State private var toastPresentation: ToastPresentation?
    @State private var isSavingPoster = false
    @State private var photoAccessDenied = false

    var body: some View {
        FlowPage {
            HeroHeader(
                eyebrow: isSoloPractice ? "保存练唱单" : "发给朋友",
                title: isSoloPractice ? "把练唱安排留在手边" : "发群里更省事",
                subtitle: isSoloPractice
                    ? "复制、分享，或者存一张海报，练唱时随时能看。"
                    : "复制歌单、直接分享，或者存一张海报。",
                systemImage: "square.and.arrow.up"
            )
            if let plan = store.songPlan {
                GlassCard {
                    Text(isSoloPractice ? "保存练唱单" : "发给朋友")
                        .font(TypographyTokens.section)
                        .stageText()
                    ResponsiveActionRow {
                        SecondaryGlassButton(title: isSavingPoster ? "保存中" : "存海报", systemImage: "square.and.arrow.down") {
                            savePoster(plan)
                        }
                        .accessibilityLabel(isSavingPoster ? "保存中" : "保存海报")
                        .disabled(isSavingPoster)
                        SecondaryGlassButton(title: "复制", systemImage: "doc.on.doc") {
                            copy(store.exportedShareText())
                        }
                        .accessibilityLabel("复制歌单")
                        shareActionButton(text: store.exportedShareText())
                    }
                }
                GlassCard {
                    Text("保留完整说明")
                        .font(TypographyTokens.section)
                        .stageText()
                    Text("详细文本会带上分段目标、推荐理由、注意事项和备选歌，适合留档或继续编辑。")
                        .font(TypographyTokens.caption)
                        .foregroundStyle(DesignSystem.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    detailedFileShareButton(plan: plan)
                }
                if photoAccessDenied {
                    GlassCard {
                        Text("请允许添加到相册，才能保存海报。也可以先直接分享歌单。")
                            .font(TypographyTokens.callout)
                            .foregroundStyle(DesignSystem.muted)
                        SecondaryGlassButton(title: "打开系统设置", systemImage: "gear") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            openURL(url)
                        }
                    }
                }
                PosterPreviewView(plan: plan)
                GlassCard {
                    Text("歌单预览")
                        .font(TypographyTokens.section)
                        .stageText()
                    Text(store.exportedShareText())
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(DesignSystem.ink)
                        .textSelection(.enabled)
                }
                SecondaryGlassButton(title: isSoloPractice ? "看练唱小抄" : "看开唱小抄", systemImage: "quote.bubble") {
                    store.setStage(.startTips)
                }
            } else {
                GlassCard {
                    EmptyStateView(
                        systemImage: "square.and.arrow.up",
                        text: isSoloPractice ? "还没有可保存的练唱单，可以先排一份。" : "还没有能发的歌单，可以先排一份。"
                    )
                    SecondaryGlassButton(title: isSoloPractice ? "排练唱单" : "排今晚歌单", systemImage: "sparkles") {
                        store.setStage(.scenario)
                    }
                }
            }
        }
        .floatingToast($toastPresentation)
    }

    private var isSoloPractice: Bool {
        store.songPlan?.scenario == .soloPractice || store.scenarioConfig.scenario == .soloPractice
    }

    private func copy(_ value: String, message: String = "已复制到剪贴板") {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #endif
        Haptics.success()
        showToast(message, tone: .success)
    }

    @ViewBuilder
    private func shareActionButton(text: String) -> some View {
        if #available(iOS 26.0, *), !accessibilityReduceTransparency {
            ShareLink(item: text) {
                shareActionLabel
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.roundedRectangle(radius: DesignSystem.radiusSmall))
            .tint(DesignSystem.cyan)
            .foregroundStyle(DesignSystem.ink)
            .accessibilityLabel(isSoloPractice ? "分享练唱单" : "发给朋友")
        } else {
            ShareLink(item: text) {
                shareActionLabel
            }
            .buttonStyle(PressedScaleButtonStyle(scale: 0.97))
            .liquidGlassSurface(
                cornerRadius: DesignSystem.radiusSmall,
                tint: DesignSystem.cyan.opacity(0.05),
                fallback: DesignSystem.raisedBackground,
                interactive: true
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                    .stroke(DesignSystem.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
            .foregroundStyle(DesignSystem.ink)
            .accessibilityLabel(isSoloPractice ? "分享练唱单" : "发给朋友")
        }
    }

    private var shareActionLabel: some View {
        Label("分享", systemImage: "square.and.arrow.up")
            .font(TypographyTokens.callout.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(height: ComponentTokens.minTouchTarget)
    }

    private func detailedFileShareButton(plan: SongPlan) -> some View {
        let payload = PlaylistTextFileExporter().export(plan: plan)
        return ShareLink(
            item: DetailedPlaylistTextFile(payload: payload),
            preview: SharePreview(payload.fileName)
        ) {
            Label("分享详细文件", systemImage: "doc.text")
                .font(TypographyTokens.callout.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: ComponentTokens.minTouchTarget)
        }
        .buttonStyle(PressedScaleButtonStyle(scale: 0.97))
        .liquidGlassSurface(
            cornerRadius: DesignSystem.radiusSmall,
            tint: DesignSystem.cyan.opacity(0.05),
            fallback: DesignSystem.raisedBackground,
            interactive: true
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                .stroke(DesignSystem.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
        .foregroundStyle(DesignSystem.ink)
        .accessibilityLabel("分享详细文本文件")
        .accessibilityHint("打开系统分享面板，发送 UTF-8 文本文件")
    }

    private func savePoster(_ plan: SongPlan) {
        #if canImport(UIKit) && canImport(Photos)
        isSavingPoster = true
        photoAccessDenied = false
        let renderer = ImageRenderer(
            content: PosterPreviewContent(plan: plan)
                .dynamicTypeSize(.xSmall ... .xxxLarge)
                .frame(width: 390)
                .padding(SpacingTokens.md)
                .background(DesignSystem.background)
        )
        renderer.scale = UIScreen.main.scale
        guard let image = renderer.uiImage else {
            isSavingPoster = false
            showToast("海报这次没存好，请再试一次", tone: .warning)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    isSavingPoster = false
                    photoAccessDenied = true
                    showToast("请允许添加到相册后再保存", tone: .warning)
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, error in
                Task { @MainActor in
                    isSavingPoster = false
                    showToast(
                        success ? "海报已保存到相册" : "这次没保存成功，请稍后再试",
                        tone: success ? .success : .warning
                    )
                }
            }
        }
        #else
        showToast("这台设备暂时不能保存海报", tone: .warning)
        #endif
    }

    private func showToast(_ message: String, tone: ToastTone) {
        toastPresentation = ToastPresentation(message: message, tone: tone)
    }
}

private struct DetailedPlaylistTextFile: Transferable, Sendable {
    let payload: PlaylistTextFilePayload

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { item in
            SentTransferredFile(try TemporaryExportFileStore().materialize(item.payload))
        }
    }
}

struct PosterPreviewView: View {
    let plan: SongPlan

    var body: some View {
        PosterPreviewContent(plan: plan)
            .dynamicTypeSize(.xSmall ... .xxxLarge)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(posterAccessibilityLabel)
    }

    private var posterAccessibilityLabel: String {
        let summary = PosterRenderer().summary(for: plan)
        let sections = summary.sections.map { section in
            let highlights = section.highlights.map(\.displayText).joined(separator: "、")
            return "\(section.title)：\(highlights)"
        }.joined(separator: "。")
        return "歌单海报，\(plan.title)。\(plan.scenario.planSummary)。\(sections)"
    }
}

private struct PosterPreviewContent: View {
    let plan: SongPlan

    var body: some View {
        let summary = PosterRenderer().summary(for: plan)
        PosterSurface {
            Text(summary.title)
                .font(TypographyTokens.hero)
                .stageText()
            Text(summary.subtitle)
                .font(TypographyTokens.section)
                .foregroundStyle(DesignSystem.cyan)
            Text(userFacingPlanSummary(for: plan))
                .font(TypographyTokens.caption)
                .foregroundStyle(DesignSystem.muted)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(summary.sections) { section in
                VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                    Text(section.title)
                        .font(TypographyTokens.callout.weight(.semibold))
                        .foregroundStyle(DesignSystem.ink)
                    if let disclosure = section.disclosure {
                        Label(disclosure, systemImage: "questionmark.circle")
                            .font(TypographyTokens.caption)
                            .foregroundStyle(DesignSystem.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(section.highlights) { highlight in
                        Label(
                            highlight.displayText,
                            systemImage: highlight.isPendingVerification
                                ? "questionmark.circle"
                                : "music.note"
                        )
                        .font(TypographyTokens.callout)
                        .stageText()
                    }
                }
            }
            HStack {
                RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                    .fill(DesignSystem.cyan.opacity(0.14))
                    .frame(width: 60, height: 60)
                    .overlay(
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(DesignSystem.cyan)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                            .stroke(DesignSystem.cyan.opacity(0.28), lineWidth: 1)
                    )
                Text(
                    plan.scenario == .soloPractice
                        ? "保存后练唱时随手打开，按顺序完成热身和挑战。"
                        : "保存后直接发群里，开唱前照着点歌。"
                )
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
            }
        }
    }
}

struct PosterSurface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.md) {
            content
        }
        .padding(SpacingTokens.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    DesignSystem.primary.opacity(0.22),
                    DesignSystem.cyan.opacity(0.14),
                    DesignSystem.cardBackgroundSolid
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(alignment: .topTrailing) {
            BrandSignalVisual(systemImage: "sparkles", tint: DesignSystem.cyan, scale: .tile)
                .padding(SpacingTokens.md)
                .opacity(0.76)
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.radiusLarge, style: .continuous)
                .stroke(DesignSystem.cyan.opacity(0.26), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusLarge, style: .continuous))
        .rotation3DEffect(.degrees(-1.4), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .shadow(color: DesignSystem.cyan.opacity(0.18), radius: 24, x: 0, y: 14)
    }
}

struct StartTipsView: View {
    @EnvironmentObject private var store: DemoWorkflowStore
    private let contentPolicy = StartTipsContentPolicy()

    var body: some View {
        let content = currentContent
        FlowPage {
            HeroHeader(
                eyebrow: isSoloPractice ? "练唱小抄" : "开唱小抄",
                title: content.heroTitle,
                subtitle: content.heroSubtitle,
                systemImage: "quote.bubble"
            )
            TagCloud(values: content.tags)
            StartTipCard(title: content.openingTitle, lines: content.openingLines)
            StartTipCard(title: content.fallbackTitle, lines: content.fallbackLines)
            if store.songPlan == nil {
                SecondaryGlassButton(
                    title: isSoloPractice ? "排一份练唱单" : "排一份今晚歌单",
                    systemImage: "sparkles"
                ) {
                    store.setStage(.scenario)
                }
            }
            StartTipCard(title: content.sharingTitle, lines: content.sharingLines)
        }
    }

    private var currentContent: StartTipsContent {
        if let plan = store.songPlan {
            return contentPolicy.content(for: plan)
        }
        return contentPolicy.content(for: store.scenarioConfig.scenario)
    }

    private var isSoloPractice: Bool {
        store.songPlan?.scenario == .soloPractice || store.scenarioConfig.scenario == .soloPractice
    }
}

struct StartTipCard: View {
    let title: String
    let lines: [String]

    var body: some View {
        GlassCard {
            Text(title)
                .font(TypographyTokens.section)
                .stageText()
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: SpacingTokens.sm) {
                    Image(systemName: "checkmark")
                        .font(TypographyTokens.caption.weight(.bold))
                        .foregroundStyle(DesignSystem.cyan)
                        .frame(width: 24, height: 24)
                        .background(DesignSystem.cyan.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                                .stroke(DesignSystem.cyan.opacity(0.32), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
                    Text(line)
                        .font(TypographyTokens.callout)
                        .foregroundStyle(DesignSystem.muted)
                }
            }
        }
    }
}
