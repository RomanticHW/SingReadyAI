import SwiftUI

struct ButtonGrid<Value: Hashable>: View {
    @Environment(\.appAccessibilityFlags) private var flags
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let values: [Value]
    let selected: Value
    let title: KeyPath<Value, String>
    let onSelect: (Value) -> Void

    var body: some View {
        LazyVGrid(columns: columns, spacing: SpacingTokens.xs) {
            ForEach(values, id: \.self) { value in
                Button {
                    Haptics.selection()
                    withAnimation(flags.reduceMotion ? nil : MotionTokens.micro) {
                        onSelect(value)
                    }
                } label: {
                    Text(value[keyPath: title])
                        .font(TypographyTokens.caption.weight(.semibold))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: ComponentTokens.minTouchTarget)
                }
                .buttonStyle(PressedScaleButtonStyle(scale: 0.97))
                .foregroundStyle(DesignSystem.ink)
                .background(selected == value ? DesignSystem.cyan.opacity(0.18) : DesignSystem.raisedBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                        .stroke(selected == value ? DesignSystem.cyan.opacity(0.52) : .clear, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
                .accessibilityLabel(value[keyPath: title])
                .accessibilityAddTraits(selected == value ? .isSelected : [])
            }
        }
    }

    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 96), spacing: SpacingTokens.xs)]
    }
}
