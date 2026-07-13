import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @AccessibilityFocusState private var accessibilityFocusedPage: Int?
    @State private var page = 0

    private let pages: [(title: String, subtitle: String, image: String, tint: Color)] = [
        ("把喜欢听的歌变成适合唱的歌", "分享链接、粘贴文本或截图都可以。整理歌名、核对本地参考、排歌，都能直接做。", "music.note.list", DesignSystem.primary),
        ("想测就测，不想测也能排", "唱 10 秒大概看一下哪段更舒服，赶时间就先按常见音域排。", "waveform.path.ecg", DesignSystem.cyan),
        ("不同场合用不同顺序", "朋友局、生日局、团建局、车载 K 歌，都按现场气氛来排。", "sparkles", DesignSystem.amber),
        ("只处理你给的内容", "只读取你主动分享的内容，不会翻其他歌单，也不会保存录音。", "lock.shield", DesignSystem.success)
    ]

    var body: some View {
        ZStack {
            PremiumBackground()
            VStack(spacing: 0) {
                header
                Spacer(minLength: SpacingTokens.sm)
                ScrollView {
                    ZStack {
                        onboardingPage(pages[page])
                            .id(page)
                            .accessibilityIdentifier("onboarding-page-\(page)")
                            .accessibilityFocused($accessibilityFocusedPage, equals: page)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SpacingTokens.sm)
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, SpacingTokens.page)
                .gesture(pageSwipeGesture)
                Spacer(minLength: SpacingTokens.sm)
                pageIndicator
                    .padding(.bottom, SpacingTokens.sm)
                VStack(spacing: SpacingTokens.sm) {
                    PrimaryGradientButton(title: "开始使用", systemImage: "arrow.right", action: onFinish)
                    if page < pages.count - 1 {
                        SecondaryGlassButton(title: page == 0 ? "看看怎么用" : "再看一页", systemImage: "chevron.right") {
                            advancePage()
                        }
                    }
                }
                .padding(.horizontal, SpacingTokens.page)
                .safeAreaPadding(.bottom, SpacingTokens.lg)
            }
        }
        .environment(
            \.appAccessibilityFlags,
             AccessibilityFlags(
                reduceMotion: accessibilityReduceMotion,
                reduceTransparency: accessibilityReduceTransparency
             )
        )
    }

    private var header: some View {
        HStack {
            Text("今晚唱什么")
                .font(TypographyTokens.title)
                .foregroundStyle(DesignSystem.ink)
            Spacer()
        }
        .padding(.horizontal, SpacingTokens.page)
        .padding(.top, SpacingTokens.lg)
    }

    private var pageIndicator: some View {
        HStack(spacing: SpacingTokens.xs) {
            ForEach(pages.indices, id: \.self) { index in
                Button {
                    changePage(to: index, animation: MotionTokens.micro)
                } label: {
                    Capsule()
                        .fill(index == page ? DesignSystem.cyan : DesignSystem.separator)
                        .frame(width: index == page ? 28 : 8, height: 8)
                }
                .buttonStyle(PressedScaleButtonStyle(scale: 0.92))
                .frame(
                    minWidth: ComponentTokens.minTouchTarget,
                    minHeight: ComponentTokens.minTouchTarget
                )
                .contentShape(Rectangle())
                .accessibilityLabel("引导第 \(index + 1) 页")
                .accessibilityValue(index == page ? "当前页" : "")
            }
        }
    }

    private func onboardingPage(_ item: (title: String, subtitle: String, image: String, tint: Color)) -> some View {
        VStack(spacing: SpacingTokens.lg) {
            BrandSignalVisual(systemImage: item.image, tint: item.tint, scale: .showcase)
            VStack(spacing: SpacingTokens.sm) {
                Text(item.title)
                    .font(TypographyTokens.title)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignSystem.ink)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.subtitle)
                    .font(TypographyTokens.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignSystem.muted)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var pageSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 28)
            .onEnded { value in
                let horizontal = value.translation.width
                guard abs(horizontal) > abs(value.translation.height), abs(horizontal) > 48 else { return }
                if horizontal < 0 {
                    advancePage()
                } else {
                    retreatPage()
                }
            }
    }

    private func advancePage() {
        if page == pages.count - 1 {
            onFinish()
        } else {
            changePage(to: page + 1, animation: MotionTokens.page)
        }
    }

    private func retreatPage() {
        guard page > 0 else { return }
        changePage(to: page - 1, animation: MotionTokens.page)
    }

    private func changePage(to newPage: Int, animation: Animation) {
        guard page != newPage else { return }
        if accessibilityReduceMotion {
            page = newPage
        } else {
            withAnimation(animation) { page = newPage }
        }
        Task { @MainActor in
            await Task.yield()
            accessibilityFocusedPage = newPage
        }
    }
}
