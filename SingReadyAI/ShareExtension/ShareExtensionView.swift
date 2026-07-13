import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

enum ShareExtensionViewState: Equatable {
    case loading
    case success
    case failure
}

struct ShareExtensionView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let title: String
    let message: String
    let source: String
    let preview: String
    let fallbackCopyText: String?
    let state: ShareExtensionViewState
    let onCopy: (String) -> Void
    let onCancel: () -> Void
    let onDone: () -> Void
    @State private var didCopy = false

    var body: some View {
        ZStack {
            ShareExtensionBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: ShareExtensionMetrics.spacing) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: state.systemImage)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(state.tint)
                            .frame(width: 44, height: 44)
                            .shareExtensionSurface(
                                cornerRadius: ShareExtensionMetrics.radiusSmall,
                                tint: state.tint.opacity(0.10),
                                reduceTransparency: reduceTransparency
                            )

                        VStack(alignment: .leading, spacing: 6) {
                            Text(title)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(ShareExtensionPalette.ink)
                                .lineLimit(2)
                                .minimumScaleFactor(0.86)

                            Text(message)
                                .font(.subheadline)
                                .foregroundStyle(ShareExtensionPalette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    ShareExtensionCard {
                        Label(source, systemImage: "music.note.list")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ShareExtensionPalette.ink)
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(ShareExtensionPalette.muted)
                            .lineLimit(5)
                            .fixedSize(horizontal: false, vertical: true)
                        if fallbackCopyText != nil {
                            Label("这次没有直接存进 App，可以复制内容后回到今晚唱什么粘贴。", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(ShareExtensionPalette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Label("只读取这次分享的内容，不会翻你的其他歌单。", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(ShareExtensionPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    if let fallbackCopyText {
                        Button {
                            onCopy(fallbackCopyText)
                            didCopy = true
                            #if canImport(UIKit)
                            UIAccessibility.post(notification: .announcement, argument: "已复制")
                            #endif
                        } label: {
                            Label(didCopy ? "已复制" : "复制内容", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .shareExtensionSurface(
                                    cornerRadius: ShareExtensionMetrics.radiusSmall,
                                    tint: ShareExtensionPalette.cyan.opacity(0.12),
                                    reduceTransparency: reduceTransparency,
                                    interactive: true
                                )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ShareExtensionPalette.ink)
                        .accessibilityLabel("复制分享内容")
                    }

                    Button {
                        if state.isDone {
                            onDone()
                        } else {
                            onCancel()
                        }
                    } label: {
                        Label(state.isDone ? "完成" : "取消", systemImage: state.isDone ? "checkmark" : "xmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .shareExtensionSurface(
                                cornerRadius: ShareExtensionMetrics.radiusSmall,
                                tint: ShareExtensionPalette.cyan.opacity(0.12),
                                reduceTransparency: reduceTransparency,
                                interactive: true
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ShareExtensionPalette.ink)
                    .accessibilityHint(state.isDone ? "关闭分享窗口" : "停止读取并关闭分享窗口")
                }
                .padding(ShareExtensionMetrics.pagePadding)
            }
        }
        .onChange(of: state) { _, state in
            guard state.isDone else { return }
            #if canImport(UIKit)
            UIAccessibility.post(notification: .announcement, argument: title)
            #endif
        }
    }
}

private extension ShareExtensionViewState {
    var isDone: Bool {
        self != .loading
    }

    var systemImage: String {
        switch self {
        case .loading: return "tray.and.arrow.down"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .loading: return ShareExtensionPalette.cyan
        case .success: return ShareExtensionPalette.success
        case .failure: return ShareExtensionPalette.warning
        }
    }
}

private enum ShareExtensionMetrics {
    static let spacing: CGFloat = 16
    static let pagePadding: CGFloat = 20
    static let radiusSmall: CGFloat = 14
    static let radiusMedium: CGFloat = 18
}

private enum ShareExtensionPalette {
    static let ink = Color(red: 0.96, green: 0.97, blue: 0.98)
    static let muted = Color(red: 0.72, green: 0.78, blue: 0.82)
    static let panel = Color(red: 0.09, green: 0.12, blue: 0.16).opacity(0.84)
    static let stroke = Color(red: 0.86, green: 0.92, blue: 0.96).opacity(0.20)
    static let cyan = Color(red: 0.24, green: 0.82, blue: 0.86)
    static let success = Color(red: 0.34, green: 0.82, blue: 0.56)
    static let warning = Color(red: 1.0, green: 0.69, blue: 0.26)
}

private struct ShareExtensionBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.055, green: 0.08, blue: 0.13),
                Color(red: 0.065, green: 0.08, blue: 0.17),
                Color(red: 0.02, green: 0.15, blue: 0.15)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

private struct ShareExtensionCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shareExtensionSurface(
            cornerRadius: ShareExtensionMetrics.radiusMedium,
            tint: ShareExtensionPalette.cyan.opacity(0.04),
            reduceTransparency: reduceTransparency
        )
    }
}

private extension View {
    @ViewBuilder
    func shareExtensionSurface(
        cornerRadius: CGFloat,
        tint: Color,
        reduceTransparency: Bool,
        interactive: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *), !reduceTransparency {
            self
                .background(ShareExtensionPalette.panel.opacity(0.18), in: shape)
                .glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
                .overlay(shape.stroke(ShareExtensionPalette.stroke, lineWidth: 0.9))
                .clipShape(shape)
        } else {
            self
                .background(ShareExtensionPalette.panel, in: shape)
                .overlay(shape.stroke(ShareExtensionPalette.stroke, lineWidth: 1))
                .clipShape(shape)
        }
    }
}
