import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

enum ToastTone: Equatable {
    case success
    case warning

    var systemImage: String {
        switch self {
        case .success:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success:
            DesignSystem.success
        case .warning:
            DesignSystem.warning
        }
    }

    var accessibilityValue: String {
        switch self {
        case .success:
            "成功"
        case .warning:
            "警告"
        }
    }
}

struct ToastPresentation: Equatable, Identifiable {
    let id: UUID
    let message: String
    let tone: ToastTone

    init(
        id: UUID = UUID(),
        message: String,
        tone: ToastTone
    ) {
        self.id = id
        self.message = message
        self.tone = tone
    }
}

struct FloatingToast: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let message: String
    let tone: ToastTone

    var body: some View {
        HStack(alignment: .top, spacing: SpacingTokens.xs) {
            Image(systemName: tone.systemImage)
                .foregroundStyle(tone.tint)
                .padding(.top, dynamicTypeSize.isAccessibilitySize ? SpacingTokens.xxs : 0)
            Text(message)
                .lineLimit(allowsMultiline ? nil : 1)
                .minimumScaleFactor(allowsMultiline ? 1 : 0.82)
                .fixedSize(horizontal: false, vertical: allowsMultiline)
        }
        .font(TypographyTokens.caption.weight(.semibold))
        .foregroundStyle(DesignSystem.ink)
        .padding(.horizontal, SpacingTokens.md)
        .padding(.vertical, verticalPadding)
        .frame(
            maxWidth: allowsMultiline ? .infinity : nil,
            minHeight: minimumHeight
        )
        .background(DesignSystem.cardBackgroundSolid.opacity(0.94))
        .overlay(
            RoundedRectangle(cornerRadius: toastCornerRadius, style: .continuous)
                .stroke(tone.tint.opacity(0.38), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: toastCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.26), radius: 18, x: 0, y: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityValue(tone.accessibilityValue)
        .accessibilityIdentifier("floating-toast")
    }

    private var toastCornerRadius: CGFloat {
        allowsMultiline ? DesignSystem.radiusSmall : 999
    }

    private var allowsMultiline: Bool {
        dynamicTypeSize.isAccessibilitySize || tone == .warning
    }

    private var verticalPadding: CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return SpacingTokens.sm
        }
        return tone == .warning ? SpacingTokens.xs : 0
    }

    private var minimumHeight: CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return 68
        }
        return tone == .warning ? 52 : 42
    }
}

private struct ToastPresenter: ViewModifier {
    @Environment(\.appAccessibilityFlags) private var flags
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var presentation: ToastPresentation?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let presentation {
                    FloatingToast(message: presentation.message, tone: presentation.tone)
                        .padding(
                            .horizontal,
                            usesReadableWidth(presentation.tone)
                                ? DesignSystem.pageHorizontalPadding
                                : 0
                        )
                        .padding(.bottom, SpacingTokens.lg)
                        .transition(flags.reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: presentation?.id) { _, newID in
                guard let newID,
                      let currentPresentation = presentation else { return }
                #if canImport(UIKit)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: currentPresentation.message
                )
                #endif
                let displayDuration: UInt64
                if dynamicTypeSize.isAccessibilitySize {
                    displayDuration = 5_000_000_000
                } else if currentPresentation.tone == .warning {
                    displayDuration = 4_000_000_000
                } else {
                    displayDuration = 1_800_000_000
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: displayDuration)
                    guard presentation?.id == newID else { return }
                    withAnimation(flags.reduceMotion ? nil : MotionTokens.micro) {
                        presentation = nil
                    }
                }
            }
    }

    private func usesReadableWidth(_ tone: ToastTone) -> Bool {
        dynamicTypeSize.isAccessibilitySize || tone == .warning
    }
}

extension View {
    func floatingToast(_ presentation: Binding<ToastPresentation?>) -> some View {
        modifier(ToastPresenter(presentation: presentation))
    }
}
