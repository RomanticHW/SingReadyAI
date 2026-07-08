import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0

    private let pages: [(title: String, subtitle: String, image: String, tint: Color)] = [
        ("把喜欢听的歌变成适合唱的歌", "从分享链接、粘贴文本或截图开始，先确认歌名，再匹配 KTV 可唱度。", "music.note.list", DesignSystem.primary),
        ("用声线和曲库降低点歌风险", "10 秒录音只在本机内存分析音域，也可以明确选择模拟声线跑演示。", "waveform.path.ecg", DesignSystem.cyan),
        ("为不同场景编排气氛", "朋友局、生日局、团建局、车载 K 歌都有不同节奏和合唱策略。", "sparkles", DesignSystem.amber),
        ("隐私边界清楚可解释", "只读取你主动分享的内容，不连接硬件，也不抓取音乐平台私有数据。", "lock.shield", DesignSystem.success)
    ]

    var body: some View {
        ZStack {
            PremiumBackground()
            VStack(spacing: 0) {
                header
                Spacer(minLength: SpacingTokens.sm)
                ZStack {
                    onboardingPage(pages[page])
                        .id(page)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
                .padding(.horizontal, SpacingTokens.page)
                .gesture(pageSwipeGesture)
                Spacer(minLength: SpacingTokens.sm)
                pageIndicator
                    .padding(.bottom, SpacingTokens.sm)
                PrimaryGradientButton(title: page == pages.count - 1 ? "开始使用" : "下一页", systemImage: "arrow.right", action: advancePage)
                .padding(.horizontal, SpacingTokens.page)
                .safeAreaPadding(.bottom, SpacingTokens.lg)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("今晚唱什么")
                .font(TypographyTokens.title)
                .foregroundStyle(DesignSystem.ink)
            Spacer()
            Button("跳过", action: onFinish)
                .font(TypographyTokens.callout.weight(.semibold))
                .foregroundStyle(DesignSystem.cyan)
                .accessibilityLabel("跳过引导")
        }
        .padding(.horizontal, SpacingTokens.page)
        .padding(.top, SpacingTokens.lg)
    }

    private var pageIndicator: some View {
        HStack(spacing: SpacingTokens.xs) {
            ForEach(pages.indices, id: \.self) { index in
                Button {
                    withAnimation(MotionTokens.micro) { page = index }
                } label: {
                    Capsule()
                        .fill(index == page ? DesignSystem.primary : DesignSystem.separator)
                        .frame(width: index == page ? 28 : 8, height: 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("引导第 \(index + 1) 页")
            }
        }
    }

    private func onboardingPage(_ item: (title: String, subtitle: String, image: String, tint: Color)) -> some View {
        VStack(spacing: SpacingTokens.lg) {
            ZStack {
                Circle()
                    .fill(item.tint.opacity(0.16))
                    .frame(width: 152, height: 152)
                Image(systemName: item.image)
                    .font(.system(size: 62, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(item.tint)
            }
            VStack(spacing: SpacingTokens.sm) {
                Text(item.title)
                    .font(TypographyTokens.title)
                    .lineLimit(3)
                    .minimumScaleFactor(0.86)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignSystem.ink)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.subtitle)
                    .font(TypographyTokens.callout)
                    .lineLimit(4)
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
            withAnimation(MotionTokens.page) { page += 1 }
        }
    }

    private func retreatPage() {
        guard page > 0 else { return }
        withAnimation(MotionTokens.page) { page -= 1 }
    }
}
