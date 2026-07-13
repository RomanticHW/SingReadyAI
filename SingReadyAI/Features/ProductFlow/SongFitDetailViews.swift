import SwiftUI
import SingReadyAISharedKit

#if canImport(UIKit)
import UIKit
#endif

struct SuitabilityBadge: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(TypographyTokens.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, SpacingTokens.sm)
            .padding(.vertical, SpacingTokens.xs)
            .frame(minHeight: 34)
            .background(tint.opacity(0.16))
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.32), lineWidth: 0.8)
            )
            .clipShape(Capsule())
            .foregroundStyle(DesignSystem.ink)
            .accessibilityLabel(title)
    }
}

struct SongFitBreakdownView: View {
    let breakdown: RecommendationScoreBreakdown
    let scenario: KTVScenario
    let inputSource: RecommendationInputSource
    let hasValidMeasuredRange: Bool

    var body: some View {
        DisclosureGroup {
            VStack(spacing: SpacingTokens.xs) {
                if inputSource.allowsPlaylistPersonalization {
                    FitReasonRow(title: "喜好接近", value: breakdown.preferenceAffinity, high: "很像你会点的歌", middle: "风格比较接近", low: "更多是补位")
                }
                FitReasonRow(title: "常见度参考", value: breakdown.ktvAvailabilityScore, high: "本地参考中较常见", middle: "有一定参考", low: "建议留备选")
                if hasValidMeasuredRange {
                    FitReasonRow(title: "本次音区", value: breakdown.vocalFitScore, high: "和本次音区接近", middle: "可以结合状态判断", low: "唱前看一下调性")
                }
                if scenario == .soloPractice {
                    FitReasonRow(title: "练唱节奏", value: breakdown.singAlongScore, high: "旋律容易跟上", middle: "熟悉后会更顺", low: "适合慢慢练")
                    FitReasonRow(title: "练唱安排", value: breakdown.sceneFitScore, high: "贴合练唱目标", middle: "可以放进练唱单", low: "更适合后面尝试")
                } else {
                    FitReasonRow(title: "合唱感", value: breakdown.singAlongScore, high: "大家容易接", middle: "适合有人一起唱", low: "更适合独唱")
                    FitReasonRow(title: "今晚氛围", value: breakdown.sceneFitScore, high: "很贴这场", middle: "放进去顺", low: "更适合后面补位")
                }
                FitReasonRow(title: "注意点", value: 1 - breakdown.riskPenalty, high: "没什么压力", middle: "唱前看一眼", low: "别放太靠前", tint: DesignSystem.warning)
            }
        } label: {
            Text("为什么放这首")
                .font(TypographyTokens.caption.weight(.semibold))
        }
        .tint(DesignSystem.cyan)
    }
}

private struct FitReasonRow: View {
    let title: String
    let value: Double
    let high: String
    let middle: String
    let low: String
    var tint: Color = DesignSystem.cyan

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(TypographyTokens.caption.weight(.semibold))
                    .stageText()
                Spacer()
                Text(text)
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DesignSystem.separator)
                    Capsule().fill(tint)
                        .frame(width: proxy.size.width * clampedValue)
                }
            }
            .frame(height: 6)
        }
    }

    private var text: String {
        if value >= 0.76 {
            return high
        }
        if value >= 0.48 {
            return middle
        }
        return low
    }

    private var clampedValue: Double {
        min(max(value, 0), 1)
    }
}

struct RiskBadge: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(TypographyTokens.caption)
            .foregroundStyle(DesignSystem.warning)
    }
}

struct AlternativeSongChips: View {
    let tracks: [KTVTrack]

    var body: some View {
        TagCloud(values: tracks.map { "替代：\($0.title) - \($0.artist)" }, tint: DesignSystem.amber)
    }
}
