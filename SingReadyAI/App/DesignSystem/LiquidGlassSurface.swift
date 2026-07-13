import SwiftUI

extension View {
    func liquidGlassSurface(
        cornerRadius: CGFloat,
        tint: Color? = nil,
        fallback: Color = DesignSystem.raisedBackground,
        interactive: Bool = false
    ) -> some View {
        modifier(LiquidGlassSurfaceModifier(cornerRadius: cornerRadius, tint: tint, fallback: fallback, interactive: interactive))
    }
}

struct GlassSurfaceGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                content
            }
        } else {
            content
        }
    }
}

private struct LiquidGlassSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat
    let tint: Color?
    let fallback: Color
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *), !reduceTransparency {
            let glass = (tint.map { Glass.regular.tint($0) } ?? Glass.regular).interactive(interactive)
            content
                .background(fallback.opacity(0.18), in: shape)
                .glassEffect(glass, in: shape)
        } else {
            content.background(fallback, in: shape)
        }
    }
}
