import SwiftUI
import SingReadyAISharedKit

#if canImport(UIKit)
import UIKit
#endif

struct SongPlanResultView: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        FlowPage {
            if let plan = store.songPlan {
                HeroHeader(
                    eyebrow: plan.scenario.displayName,
                    title: plan.title,
                    subtitle: plan.preferenceSummary ?? "已根据导入歌单、声线和场景生成。",
                    systemImage: "sparkles"
                )
                GlassCard {
                    HStack(spacing: SpacingTokens.sm) {
                        SecondaryGlassButton(title: "重新生成", systemImage: "arrow.clockwise") {
                            store.regeneratePlan()
                        }
                        SecondaryGlassButton(title: "导出", systemImage: "square.and.arrow.up") {
                            store.currentStage = .export
                        }
                    }
                }
                SongPlanTimeline(plan: plan)
            } else {
                GlassCard {
                    EmptyStateView(systemImage: "sparkles", text: "选择场景后会生成分段歌单。")
                    SecondaryGlassButton(title: "去选择场景", systemImage: "person.3.sequence") {
                        store.currentStage = .scenario
                    }
                }
            }
        }
    }
}

struct SongPlanTimeline: View {
    let plan: SongPlan

    var body: some View {
        ForEach(plan.sections) { section in
            GlassCard {
                Text(section.title)
                    .font(TypographyTokens.section)
                    .stageText()
                Text(section.goal)
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
                ForEach(section.items) { item in
                    SongRecommendationCard(item: item)
                }
            }
        }
    }
}

struct SongRecommendationCard: View {
    @EnvironmentObject private var store: DemoWorkflowStore
    let item: SongPlanItem

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                    Text("\(item.track.title) - \(item.track.artist)")
                        .font(TypographyTokens.callout.weight(.bold))
                        .stageText()
                    TagCloud(values: [
                        item.track.genre,
                        "难度 \(item.track.difficulty)",
                        "音域 \(item.track.vocalRangeLowMidi)-\(item.track.vocalRangeHighMidi)",
                        "合唱 \(Int(item.track.singAlongScore * 100))",
                        "能量 \(Int(item.track.energy * 100))"
                    ])
                }
                Spacer()
                Text("\(Int(item.score * 100))")
                    .font(TypographyTokens.metric)
                    .foregroundStyle(DesignSystem.cyan)
            }
            ForEach(item.reasons, id: \.self) { reason in
                Label(reason, systemImage: "checkmark.circle")
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
            }
            ForEach(item.riskWarnings, id: \.self) { warning in
                RiskBadge(text: warning)
            }
            if !item.alternatives.isEmpty {
                AlternativeSongChips(tracks: Array(item.alternatives.prefix(2)))
            }
            ScoreBreakdownView(breakdown: item.scoreBreakdown)
            HStack(spacing: SpacingTokens.sm) {
                Button {
                    store.toggleLock(trackID: item.track.id)
                } label: {
                    Label(item.isLocked ? "已锁定" : "锁定", systemImage: item.isLocked ? "lock.fill" : "lock")
                }
                .buttonStyle(.bordered)
                .tint(DesignSystem.amber)
                .accessibilityLabel(item.isLocked ? "取消锁定\(item.track.title)" : "锁定\(item.track.title)")

                Button(role: .destructive) {
                    store.removeTrack(trackID: item.track.id)
                } label: {
                    Label("移除补位", systemImage: "minus.circle")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("移除\(item.track.title)并补位")
            }
            .font(TypographyTokens.caption.weight(.semibold))
        }
        .padding(.vertical, SpacingTokens.sm)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignSystem.separator)
                .frame(height: 1)
        }
    }
}

struct ScoreBreakdownView: View {
    let breakdown: RecommendationScoreBreakdown

    var body: some View {
        DisclosureGroup {
            VStack(spacing: SpacingTokens.xs) {
                MetricBar(title: "偏好亲和", value: breakdown.preferenceAffinity)
                MetricBar(title: "KTV 可唱度", value: breakdown.ktvAvailabilityScore)
                MetricBar(title: "声线适配", value: breakdown.vocalFitScore)
                MetricBar(title: "合唱参与", value: breakdown.singAlongScore)
                MetricBar(title: "场景适配", value: breakdown.sceneFitScore)
                MetricBar(title: "风险惩罚", value: breakdown.riskPenalty, tint: DesignSystem.warning)
            }
        } label: {
            Text("评分解释")
                .font(TypographyTokens.caption.weight(.semibold))
        }
        .tint(DesignSystem.cyan)
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

struct ExportCenterView: View {
    @EnvironmentObject private var store: DemoWorkflowStore
    @State private var showJSON = false

    var body: some View {
        FlowPage {
            HeroHeader(
                eyebrow: "导出中心",
                title: "把今晚歌单带走",
                subtitle: "复制文本、查看 JSON 结构，或用海报预览做演示。",
                systemImage: "square.and.arrow.up"
            )
            if let plan = store.songPlan {
                PosterPreviewView(plan: plan)
                GlassCard {
                    Text("文本歌单")
                        .font(TypographyTokens.section)
                        .stageText()
                    Text(store.exportedText())
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(DesignSystem.ink)
                        .textSelection(.enabled)
                    HStack(spacing: SpacingTokens.sm) {
                        SecondaryGlassButton(title: "复制文本", systemImage: "doc.on.doc") {
                            copy(store.exportedText())
                        }
                        ShareLink(item: store.exportedText()) {
                            Label("分享", systemImage: "square.and.arrow.up")
                                .font(TypographyTokens.callout.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: ComponentTokens.minTouchTarget)
                        }
                        .buttonStyle(.plain)
                        .background(DesignSystem.raisedBackground)
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
                        .foregroundStyle(DesignSystem.ink)
                    }
                }
                GlassCard {
                    Toggle(isOn: $showJSON) {
                        Text("JSON 预览")
                            .font(TypographyTokens.section)
                            .stageText()
                    }
                    .tint(DesignSystem.primary)
                    if showJSON {
                        Text(store.exportedJSON())
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(DesignSystem.muted)
                            .textSelection(.enabled)
                        SecondaryGlassButton(title: "复制 JSON", systemImage: "curlybraces") {
                            copy(store.exportedJSON())
                        }
                    }
                }
                SecondaryGlassButton(title: "查看面试演示脚本", systemImage: "briefcase") {
                    store.currentStage = .interview
                }
            } else {
                GlassCard {
                    EmptyStateView(systemImage: "square.and.arrow.up", text: "暂无歌单，请先完成生成。")
                    SecondaryGlassButton(title: "去生成", systemImage: "sparkles") {
                        store.currentStage = .scenario
                    }
                }
            }
        }
    }

    private func copy(_ value: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #endif
    }
}

struct PosterPreviewView: View {
    let plan: SongPlan

    var body: some View {
        let summary = PosterRenderer().summary(for: plan)
        GlassCard {
            VStack(alignment: .leading, spacing: SpacingTokens.md) {
                Text(summary.title)
                    .font(TypographyTokens.hero)
                    .stageText()
                Text(summary.subtitle)
                    .font(TypographyTokens.section)
                    .foregroundStyle(DesignSystem.cyan)
                Text(plan.preferenceSummary ?? "KTV 场景歌单")
                    .font(TypographyTokens.caption)
                    .foregroundStyle(DesignSystem.muted)
                ForEach(summary.highlights, id: \.self) { line in
                    Label(line, systemImage: "music.note")
                        .font(TypographyTokens.callout)
                        .stageText()
                }
                HStack {
                    RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                        .stroke(DesignSystem.border, lineWidth: 1)
                        .frame(width: 60, height: 60)
                        .overlay(Text("QR").font(TypographyTokens.caption.monospaced()).foregroundStyle(DesignSystem.muted))
                    Text("分享占位：面试演示可替换为歌单链接或下载页。")
                        .font(TypographyTokens.caption)
                        .foregroundStyle(DesignSystem.muted)
                }
            }
            .padding(SpacingTokens.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [DesignSystem.primary.opacity(0.28), DesignSystem.cyan.opacity(0.16), DesignSystem.raisedBackground],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusLarge, style: .continuous))
        }
    }
}

struct InterviewModeView: View {
    private let productScript = [
        "定位：KTV、车载 K 歌和朋友聚会前置歌单助手。",
        "痛点：喜欢听的歌不一定适合唱，多人局还需要气氛节奏。",
        "方案：用户主动导入歌单，离线匹配曲库、声线和场景，输出可解释歌单。"
    ]
    private let architectureScript = [
        "架构：SwiftUI App、Share Extension、SharedKit 业务核心。",
        "能力：来源识别、文本解析、Vision OCR、KTV 匹配、PCM 音高分析、推荐引擎和导出。",
        "边界：不接入硬件，不抓取私有接口，不包含音频、歌词、MV 或版权封面。"
    ]
    private let demoScript = [
        "用 Demo 歌单或粘贴文本导入，在 Review 页面修正低置信度条目。",
        "查看可唱率、匹配分类、偏好画像和场景适配。",
        "使用录音分析或模拟声线，选择朋友局或生日局生成歌单。",
        "展开评分解释，锁定一首，移除一首并补位。",
        "导出文本、JSON 和海报预览。"
    ]

    var body: some View {
        FlowPage {
            HeroHeader(
                eyebrow: "Interview Mode",
                title: "5 分钟讲清产品和技术",
                subtitle: "面向 KTV/车载 K 歌业务，突出移动端入口价值和 iOS 工程能力。",
                systemImage: "briefcase"
            )
            TagCloud(values: ["手机点歌前置入口", "歌单导入", "KTV 可唱匹配", "车载 K 歌推荐", "PCM 声线分析", "场景化编排"])
            InterviewScriptCard(title: "90 秒产品介绍", lines: productScript)
            InterviewScriptCard(title: "3 分钟技术架构", lines: architectureScript)
            InterviewScriptCard(title: "5 分钟完整演示", lines: demoScript)
        }
    }
}

struct InterviewScriptCard: View {
    let title: String
    let lines: [String]

    var body: some View {
        GlassCard {
            Text(title)
                .font(TypographyTokens.section)
                .stageText()
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: SpacingTokens.sm) {
                    Text("\(index + 1)")
                        .font(TypographyTokens.caption.monospacedDigit())
                        .frame(width: 24, height: 24)
                        .background(DesignSystem.primary.opacity(0.22))
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
                    Text(line)
                        .font(TypographyTokens.callout)
                        .foregroundStyle(DesignSystem.muted)
                }
            }
        }
    }
}
