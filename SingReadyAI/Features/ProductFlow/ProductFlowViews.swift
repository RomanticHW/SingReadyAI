import PhotosUI
import SwiftUI
import SingReadyAISharedKit

#if canImport(UIKit)
import UIKit
#endif

struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0

    private let pages: [(title: String, subtitle: String, image: String, color: Color)] = [
        ("导入你的音乐喜好", "从分享链接、粘贴文本或截图中识别常听歌曲。", "music.note.list", DesignSystem.primary),
        ("分析声线和可唱度", "匹配 KTV 曲库、识别高音风险，并保留模拟声线入口。", "waveform.path.ecg", DesignSystem.cyan),
        ("生成适合场景的歌单", "按朋友局、生日局、团建局、车载 K 歌等场景编排顺序。", "sparkles", DesignSystem.amber)
    ]

    var body: some View {
        ZStack {
            DesignSystem.background.ignoresSafeArea()
            VStack(spacing: 18) {
                HStack {
                    Text("今晚唱什么")
                        .font(.title.bold())
                    Spacer()
                    Button("跳过", action: onFinish)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(DesignSystem.ink)
                .padding(.horizontal, 20)
                .padding(.top, 24)

                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { index in
                        VStack(spacing: 28) {
                            Image(systemName: pages[index].image)
                                .font(.system(size: 88, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(pages[index].color)
                                .frame(width: 180, height: 180)
                                .background(pages[index].color.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(spacing: 10) {
                                Text(pages[index].title)
                                    .font(.largeTitle.bold())
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(DesignSystem.ink)
                                Text(pages[index].subtitle)
                                    .font(.body)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(DesignSystem.muted)
                                    .frame(maxWidth: 320)
                            }
                        }
                        .tag(index)
                        .padding(.horizontal, 24)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                Button {
                    if page == pages.count - 1 {
                        onFinish()
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            page += 1
                        }
                    }
                } label: {
                    Label(page == pages.count - 1 ? "开始使用" : "下一页", systemImage: page == pages.count - 1 ? "arrow.right.circle.fill" : "arrow.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.primary)
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
    }
}

struct ImportHubView: View {
    @EnvironmentObject private var store: DemoWorkflowStore
    @State private var pastedText = """
    周杰伦 - 晴天
    陈奕迅《十年》
    01 稻香 周杰伦
    歌名：告白气球 歌手：周杰伦
    分享 周杰伦 的单曲 七里香
    """
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        FlowPage {
            Panel {
                Label("从你的音乐喜好生成 KTV 可唱歌单", systemImage: "music.mic")
                    .font(.title3.bold())
                    .stageText()
                Text(store.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(DesignSystem.muted)
                if store.isWorking {
                    ProgressView()
                        .tint(DesignSystem.primary)
                }
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            pendingImportsPanel
            importActionsPanel
            recentImportsPanel
        }
        .onAppear { store.loadPendingImports() }
        .onChange(of: selectedPhoto) { _, newValue in
            guard let newValue else { return }
            Task {
                if let data = try? await newValue.loadTransferable(type: Data.self) {
                    await store.importScreenshotData(data)
                } else {
                    store.errorMessage = "图片读取失败"
                }
                selectedPhoto = nil
            }
        }
    }

    private var pendingImportsPanel: some View {
        Panel {
            HStack {
                Label("分享导入", systemImage: "tray.and.arrow.down.fill")
                    .font(.headline)
                    .stageText()
                Spacer()
                Text(store.isUsingFallbackStore ? "开发模式 fallback" : "App Group")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(store.isUsingFallbackStore ? .orange : DesignSystem.cyan)
            }

            if store.pendingImports.isEmpty {
                EmptyStateRow(systemImage: "square.and.arrow.up", text: "从音乐 App 分享链接、文本或截图后会出现在这里。")
            } else {
                ForEach(store.pendingImports) { payload in
                    Button {
                        Task { await store.analyzePending(payload) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: payload.sourceHint == .screenshot ? "photo" : "link")
                                .foregroundStyle(DesignSystem.cyan)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(payload.displayTitle ?? payload.sourceHint.displayName)
                                    .font(.subheadline.weight(.semibold))
                                Text(payload.urlString ?? payload.rawText ?? payload.imageFileName ?? "待分析")
                                    .font(.caption)
                                    .foregroundStyle(DesignSystem.muted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.ink)
                }
            }
        }
    }

    private var importActionsPanel: some View {
        Panel {
            Text("导入方式")
                .font(.headline)
                .stageText()

            PrimaryActionButton(title: "使用 Demo 歌单", systemImage: "play.fill") {
                Task { await store.useDemoPlaylist() }
            }

            TextEditor(text: $pastedText)
                .frame(minHeight: 136)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.black.opacity(0.24))
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius))
                .foregroundStyle(DesignSystem.ink)

            SecondaryActionButton(title: "解析粘贴文本", systemImage: "text.badge.checkmark") {
                Task { await store.importText(pastedText) }
            }

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label("截图 OCR 识别", systemImage: "text.viewfinder")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(DesignSystem.cyan)

            Label("建议截取歌单列表区域，尽量包含歌名和歌手；复杂截图可在下一步修正。", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(DesignSystem.muted)
        }
    }

    private var recentImportsPanel: some View {
        Panel {
            Text("最近导入")
                .font(.headline)
                .stageText()
            if store.recentImports.isEmpty {
                EmptyStateRow(systemImage: "clock", text: "完成一次导入后会显示最近记录。")
            } else {
                ForEach(store.recentImports) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.title)
                                .font(.subheadline.weight(.semibold))
                            Text("\(record.source.displayName) · \(record.songCount) 首")
                                .font(.caption)
                                .foregroundStyle(DesignSystem.muted)
                        }
                        Spacer()
                    }
                    .foregroundStyle(DesignSystem.ink)
                }
            }
        }
    }
}

struct ImportReviewView: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        FlowPage {
            Panel {
                Text("确认导入结果")
                    .font(.title3.bold())
                    .stageText()
                Text("\(store.activeReviewSongs.count) 首待匹配 · \(store.lowConfidenceReviewSongs.count) 首需要确认")
                    .font(.subheadline)
                    .foregroundStyle(DesignSystem.muted)
                if let playlist = store.importedPlaylist {
                    TagCloud(values: [playlist.source.displayName, "置信度 \(Int(playlist.parseConfidence * 100))%", playlist.title])
                }
            }

            if store.reviewSongs.isEmpty {
                Panel {
                    EmptyStateRow(systemImage: "music.note.list", text: "暂无解析歌曲，请返回导入。")
                    SecondaryActionButton(title: "返回导入", systemImage: "arrow.left") {
                        store.currentStage = .importHub
                    }
                }
            } else {
                ForEach($store.reviewSongs) { $draft in
                    if !draft.isDeleted {
                        SongDraftEditor(draft: $draft)
                    }
                }

                PrimaryActionButton(title: "开始匹配 KTV 曲库", systemImage: "chart.bar.xaxis") {
                    store.beginMatchingReviewedSongs()
                }
            }
        }
    }
}

struct MatchReportView: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        FlowPage {
            if let profile = store.preferenceProfile {
                Panel {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("KTV 匹配报告")
                                .font(.title3.bold())
                                .stageText()
                            Text(profile.summary)
                                .font(.subheadline)
                                .foregroundStyle(DesignSystem.muted)
                        }
                        Spacer()
                        CircularRateView(value: profile.ktvMatchRate)
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 10)], spacing: 10) {
                    MetricPill(title: "精确命中", value: "\(store.matchStats.exact)", systemImage: "checkmark.seal")
                    MetricPill(title: "模糊匹配", value: "\(store.matchStats.fuzzy)", systemImage: "scope")
                    MetricPill(title: "替代推荐", value: "\(store.matchStats.alternative)", systemImage: "arrow.triangle.branch")
                    MetricPill(title: "未匹配", value: "\(store.matchStats.unmatched)", systemImage: "questionmark.circle")
                }

                Panel {
                    Text("画像洞察")
                        .font(.headline)
                        .stageText()
                    TagCloud(values: profile.profileTags)
                    DistributionBars(title: "语种", values: profile.languageDistribution)
                    DistributionBars(title: "年代", values: profile.eraDistribution)
                    DistributionBars(title: "曲风", values: profile.genreDistribution)
                    DistributionBars(title: "情绪", values: profile.moodTags)
                }

                Panel {
                    Text("场景适配")
                        .font(.headline)
                        .stageText()
                    ForEach(KTVScenario.allCases, id: \.self) { scenario in
                        MetricBar(title: scenario.displayName, value: profile.scenarioFitScores[scenario.rawValue] ?? 0)
                    }
                }

                Panel {
                    Text("高音风险与下一步")
                        .font(.headline)
                        .stageText()
                    MetricBar(title: "平均难度", value: min(1, profile.averageDifficulty / 5))
                    MetricBar(title: "高音风险", value: profile.highNoteRisk)
                    MetricBar(title: "合唱友好度", value: profile.chorusFriendliness)
                    PrimaryActionButton(title: "去做声线分析", systemImage: "waveform") {
                        store.currentStage = .voice
                    }
                }
            } else {
                Panel {
                    EmptyStateRow(systemImage: "chart.bar", text: "完成导入确认后会生成匹配报告。")
                    SecondaryActionButton(title: "返回确认", systemImage: "arrow.left") {
                        store.currentStage = .review
                    }
                }
            }
        }
    }
}

struct VoiceSetupView: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        FlowPage {
            Panel {
                Text("声线分析")
                    .font(.title3.bold())
                    .stageText()
                Text("录音只用于本地估算音域；模拟器或无权限时可使用模拟声线。")
                    .font(.subheadline)
                    .foregroundStyle(DesignSystem.muted)
            }

            Panel {
                recordingContent
                HStack {
                    SecondaryActionButton(title: "录音 10 秒分析", systemImage: "record.circle") {
                        Task { await store.startVoiceRecording() }
                    }
                    SecondaryActionButton(title: "使用模拟声线", systemImage: "waveform.path") {
                        store.useSimulatedVoice()
                    }
                }
            }

            if let voice = store.voiceProfile {
                Panel {
                    Text("分析结果")
                        .font(.headline)
                        .stageText()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                        MetricPill(title: "声线类型", value: voice.type.displayName, systemImage: "person.wave.2")
                        MetricPill(title: "稳定音域", value: "\(voice.stableLowMidi)-\(voice.stableHighMidi)", systemImage: "music.quarternote.3")
                        MetricPill(title: "置信度", value: "\(Int(voice.confidence * 100))%", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    }
                    Text(voice.note)
                        .font(.caption)
                        .foregroundStyle(DesignSystem.muted)
                    TagCloud(values: voice.suitableSongTypes)
                    TagCloud(values: voice.avoidSongTypes, tint: .orange)
                    PrimaryActionButton(title: "选择 K 歌场景", systemImage: "person.3.sequence") {
                        store.currentStage = .scenario
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recordingContent: some View {
        switch store.recordingState {
        case .idle:
            EmptyStateRow(systemImage: "mic", text: "可真机录音 10 秒，也可直接使用模拟声线跑完整流程。")
        case .requestingPermission:
            Label("正在请求麦克风权限", systemImage: "lock.open")
                .stageText()
        case .recording:
            VStack(alignment: .leading, spacing: 12) {
                Text("录音中 · \(store.recordingRemainingSeconds)s")
                    .font(.headline.monospacedDigit())
                    .stageText()
                WaveformView(level: store.recordingLevel)
            }
        case .analyzing:
            Label("正在分析音高稳定区间", systemImage: "waveform.badge.magnifyingglass")
                .stageText()
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

struct ScenarioBuilderView: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        FlowPage {
            Panel {
                Text("场景构建")
                    .font(.title3.bold())
                    .stageText()
                Text("根据人数、时长、氛围和难度偏好调整推荐排序。")
                    .font(.subheadline)
                    .foregroundStyle(DesignSystem.muted)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: 10)], spacing: 10) {
                ForEach(KTVScenario.allCases, id: \.self) { scenario in
                    ScenarioCard(
                        scenario: scenario,
                        isSelected: store.scenarioConfig.scenario == scenario
                    ) {
                        store.scenarioConfig.scenario = scenario
                    }
                }
            }

            Panel {
                Stepper("人数 \(store.scenarioConfig.peopleCount)", value: $store.scenarioConfig.peopleCount, in: 1...16)
                    .stageText()
                VStack(alignment: .leading, spacing: 8) {
                    Text("时长 \(store.scenarioConfig.durationMinutes) 分钟")
                        .stageText()
                    Slider(
                        value: Binding(
                            get: { Double(store.scenarioConfig.durationMinutes) },
                            set: { store.scenarioConfig.durationMinutes = Int($0) }
                        ),
                        in: 30...180,
                        step: 15
                    )
                    .tint(DesignSystem.primary)
                }

                Text("氛围")
                    .font(.headline)
                    .stageText()
                ButtonGrid(values: PlaylistVibe.allCases, selected: store.scenarioConfig.vibe, title: \.displayName) { vibe in
                    store.scenarioConfig.vibe = vibe
                }

                Text("难度")
                    .font(.headline)
                    .stageText()
                ButtonGrid(values: DifficultyPreference.allCases, selected: store.scenarioConfig.difficultyPreference, title: \.displayName) { preference in
                    store.scenarioConfig.difficultyPreference = preference
                }

                Text("合唱")
                    .font(.headline)
                    .stageText()
                ButtonGrid(values: ChorusPreference.allCases, selected: store.scenarioConfig.chorusPreference, title: \.displayName) { preference in
                    store.scenarioConfig.chorusPreference = preference
                }
            }

            PrimaryActionButton(title: "生成今晚歌单", systemImage: "sparkles") {
                store.generatePlan()
            }
        }
    }
}

struct SongPlanResultView: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        FlowPage {
            if let plan = store.songPlan {
                Panel {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(plan.title)
                                .font(.title3.bold())
                                .stageText()
                            Text(plan.preferenceSummary ?? "已根据导入歌单、声线和场景生成。")
                                .font(.subheadline)
                                .foregroundStyle(DesignSystem.muted)
                        }
                        Spacer()
                    }
                    HStack {
                        SecondaryActionButton(title: "重新生成", systemImage: "arrow.clockwise") {
                            store.regeneratePlan()
                        }
                        SecondaryActionButton(title: "导出", systemImage: "square.and.arrow.up") {
                            store.currentStage = .export
                        }
                    }
                }

                ForEach(plan.sections) { section in
                    Panel {
                        Text(section.title)
                            .font(.headline)
                            .stageText()
                        Text(section.goal)
                            .font(.caption)
                            .foregroundStyle(DesignSystem.muted)

                        ForEach(section.items) { item in
                            SongPlanItemView(item: item)
                        }
                    }
                }
            } else {
                Panel {
                    EmptyStateRow(systemImage: "sparkles", text: "选择场景后会生成分段歌单。")
                    SecondaryActionButton(title: "去选择场景", systemImage: "person.3.sequence") {
                        store.currentStage = .scenario
                    }
                }
            }
        }
    }
}

struct ExportCenterView: View {
    @EnvironmentObject private var store: DemoWorkflowStore
    @State private var showJSON = false

    var body: some View {
        FlowPage {
            if let plan = store.songPlan {
                PosterPreviewView(plan: plan)

                Panel {
                    Text("文本歌单")
                        .font(.headline)
                        .stageText()
                    Text(store.exportedText())
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(DesignSystem.ink)
                        .textSelection(.enabled)
                    HStack {
                        SecondaryActionButton(title: "复制文本", systemImage: "doc.on.doc") {
                            copy(store.exportedText())
                        }
                        ShareLink(item: store.exportedText()) {
                            Label("分享", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                        .tint(DesignSystem.cyan)
                    }
                }

                Panel {
                    Toggle(isOn: $showJSON) {
                        Text("JSON 预览")
                            .font(.headline)
                            .stageText()
                    }
                    .tint(DesignSystem.primary)
                    if showJSON {
                        Text(store.exportedJSON())
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(DesignSystem.muted)
                            .textSelection(.enabled)
                        SecondaryActionButton(title: "复制 JSON", systemImage: "curlybraces") {
                            copy(store.exportedJSON())
                        }
                    }
                }

                SecondaryActionButton(title: "查看面试演示脚本", systemImage: "briefcase") {
                    store.currentStage = .interview
                }
            } else {
                Panel {
                    EmptyStateRow(systemImage: "square.and.arrow.up", text: "暂无歌单，请先完成生成。")
                    SecondaryActionButton(title: "去生成", systemImage: "sparkles") {
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

struct InterviewModeView: View {
    private let productScript = [
        "产品定位：今晚唱什么是 KTV、车载 K 歌和朋友聚会前置歌单助手。",
        "核心问题：用户喜欢听的歌不一定适合唱，现场点歌效率低，多人局需要气氛编排。",
        "解决方案：从用户主动分享的歌单、文本或截图导入，离线匹配 mock KTV 曲库，结合声线与场景生成可解释歌单。"
    ]
    private let architectureScript = [
        "技术架构：SwiftUI App + Share Extension + SharedKit 业务核心。",
        "SharedKit 包含 provider 检测、文本解析、Vision OCR 协议、KTV 匹配、偏好画像、PitchDetector、推荐引擎和导出器。",
        "推荐引擎保留 preference、KTV 可唱度、声线适配、合唱分、场景适配、多样性和风险惩罚等分项评分。"
    ]
    private let demoScript = [
        "第 1 步：用 Demo 歌单或粘贴文本导入，并在 Review 页面修正低置信度条目。",
        "第 2 步：查看 KTV 可唱率、匹配原因、偏好画像和场景适配。",
        "第 3 步：使用模拟声线或真机录音流程生成声线画像。",
        "第 4 步：选择朋友局、生日局、团建局、车载 K 歌、情侣局或独自练歌。",
        "第 5 步：展示分段结果、每首歌理由、风险、替代曲、锁定/删除/重新生成。",
        "第 6 步：导出文本、JSON 和海报预览。"
    ]

    var body: some View {
        FlowPage {
            Panel {
                Text("面试模式")
                    .font(.title3.bold())
                    .stageText()
                Text("面向雷石天地电子技术相关 iOS 面试，突出 KTV/车载 K 歌业务贴合点和工程能力。")
                    .font(.subheadline)
                    .foregroundStyle(DesignSystem.muted)
                TagCloud(values: ["手机点歌前置入口", "歌单导入", "KTV 可唱匹配", "车载 K 歌推荐", "声线分析", "场景化编排"])
            }

            ScriptPanel(title: "90 秒产品介绍", lines: productScript)
            ScriptPanel(title: "3 分钟技术架构", lines: architectureScript)
            ScriptPanel(title: "5 分钟完整演示", lines: demoScript)
        }
    }
}

struct FlowPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.spacing) {
                content
            }
            .padding(DesignSystem.pageHorizontalPadding)
            .padding(.bottom, 28)
        }
    }
}

struct EmptyStateRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(DesignSystem.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SongDraftEditor: View {
    @Binding var draft: EditableImportedSongDraft

    var body: some View {
        Panel {
            HStack {
                Label(draft.needsReview ? "待确认" : "已识别", systemImage: draft.needsReview ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(draft.needsReview ? .orange : .green)
                Spacer()
                Text("\(Int(draft.confidence * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DesignSystem.muted)
            }
            TextField("歌名", text: $draft.title)
                .textFieldStyle(.roundedBorder)
            TextField("歌手", text: $draft.artist)
                .textFieldStyle(.roundedBorder)
            if !draft.versionTags.isEmpty {
                TagCloud(values: draft.versionTags, tint: DesignSystem.amber)
            }
            if !draft.rawText.isEmpty {
                Text(draft.rawText)
                    .font(.caption)
                    .foregroundStyle(DesignSystem.muted)
                    .lineLimit(2)
            }
            Button(role: .destructive) {
                draft.isDeleted = true
            } label: {
                Label("删除该条", systemImage: "trash")
            }
            .font(.caption.weight(.semibold))
        }
    }
}

struct CircularRateView: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 9)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(DesignSystem.primary, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(value * 100))%")
                .font(.headline.monospacedDigit())
                .stageText()
        }
        .frame(width: 74, height: 74)
    }
}

struct DistributionBars: View {
    let title: String
    let values: [String: Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .stageText()
            ForEach(values.sorted(by: { $0.value > $1.value }).prefix(5), id: \.key) { key, value in
                MetricBar(title: key, value: value)
            }
        }
    }
}

struct MetricBar: View {
    let title: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.caption.monospacedDigit())
            }
            .font(.caption)
            .foregroundStyle(DesignSystem.muted)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(DesignSystem.cyan)
                        .frame(width: proxy.size.width * min(max(value, 0), 1))
                }
            }
            .frame(height: 6)
        }
    }
}

struct WaveformView: View {
    let level: Double

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(0..<18, id: \.self) { index in
                let phase = Double(index % 6) / 6
                RoundedRectangle(cornerRadius: 3)
                    .fill(DesignSystem.cyan)
                    .frame(width: 6, height: max(10, 62 * min(1, level + phase * 0.25)))
            }
        }
        .frame(height: 76)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius))
    }
}

struct ScenarioCard: View {
    let scenario: KTVScenario
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isSelected ? .white : DesignSystem.cyan)
                Text(scenario.displayName)
                    .font(.headline)
                Text("\(scenario.sectionTemplates.count) 段编排")
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.78) : DesignSystem.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .padding(12)
            .background(isSelected ? DesignSystem.primary.opacity(0.85) : Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius))
        }
        .buttonStyle(.plain)
        .foregroundStyle(DesignSystem.ink)
    }

    private var icon: String {
        switch scenario {
        case .friends: return "person.3"
        case .birthday: return "gift"
        case .teamBuilding: return "building.2"
        case .carKTV: return "car"
        case .couples: return "heart"
        case .soloPractice: return "music.mic"
        }
    }
}

struct ButtonGrid<Value: Hashable>: View {
    let values: [Value]
    let selected: Value
    let title: KeyPath<Value, String>
    let onSelect: (Value) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
            ForEach(values, id: \.self) { value in
                Button {
                    onSelect(value)
                } label: {
                    Text(value[keyPath: title])
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.ink)
                .background(selected == value ? DesignSystem.primary.opacity(0.86) : Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius))
            }
        }
    }
}

struct SongPlanItemView: View {
    @EnvironmentObject private var store: DemoWorkflowStore
    let item: SongPlanItem

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(item.track.title) - \(item.track.artist)")
                        .font(.subheadline.bold())
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
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(DesignSystem.cyan)
            }

            ForEach(item.reasons, id: \.self) { reason in
                Label(reason, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(DesignSystem.muted)
            }
            ForEach(item.riskWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !item.alternatives.isEmpty {
                Text("替代曲：\(item.alternatives.prefix(2).map { "\($0.title) - \($0.artist)" }.joined(separator: " / "))")
                    .font(.caption)
                    .foregroundStyle(DesignSystem.muted)
            }

            DisclosureGroup {
                VStack(spacing: 8) {
                    MetricBar(title: "偏好亲和", value: item.scoreBreakdown.preferenceAffinity)
                    MetricBar(title: "KTV 可唱度", value: item.scoreBreakdown.ktvAvailabilityScore)
                    MetricBar(title: "声线适配", value: item.scoreBreakdown.vocalFitScore)
                    MetricBar(title: "场景适配", value: item.scoreBreakdown.sceneFitScore)
                    MetricBar(title: "风险惩罚", value: item.scoreBreakdown.riskPenalty)
                }
            } label: {
                Text("评分解释")
                    .font(.caption.weight(.semibold))
            }
            .tint(DesignSystem.cyan)

            HStack {
                Button {
                    store.toggleLock(trackID: item.track.id)
                } label: {
                    Label(item.isLocked ? "已锁定" : "锁定", systemImage: item.isLocked ? "lock.fill" : "lock")
                }
                .buttonStyle(.bordered)
                .tint(DesignSystem.amber)

                Button(role: .destructive) {
                    store.removeTrack(trackID: item.track.id)
                } label: {
                    Label("移除补位", systemImage: "minus.circle")
                }
                .buttonStyle(.bordered)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }
}

struct PosterPreviewView: View {
    let plan: SongPlan

    var body: some View {
        let summary = PosterRenderer().summary(for: plan)
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                Text(summary.title)
                    .font(.largeTitle.bold())
                    .stageText()
                Text(summary.subtitle)
                    .font(.headline)
                    .foregroundStyle(DesignSystem.cyan)
                Text(plan.preferenceSummary ?? "KTV 场景歌单")
                    .font(.caption)
                    .foregroundStyle(DesignSystem.muted)
                ForEach(summary.highlights, id: \.self) { line in
                    Label(line, systemImage: "music.note")
                        .font(.subheadline)
                        .stageText()
                }
                HStack {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(DesignSystem.border, lineWidth: 1)
                        .frame(width: 58, height: 58)
                        .overlay(Text("QR").font(.caption.monospaced()).foregroundStyle(DesignSystem.muted))
                    Text("分享占位：面试演示可替换为歌单链接或 App 下载页。")
                        .font(.caption)
                        .foregroundStyle(DesignSystem.muted)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [DesignSystem.primary.opacity(0.28), DesignSystem.cyan.opacity(0.16), Color.white.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius))
        }
    }
}

struct ScriptPanel: View {
    let title: String
    let lines: [String]

    var body: some View {
        Panel {
            Text(title)
                .font(.headline)
                .stageText()
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 22, height: 22)
                        .background(DesignSystem.primary.opacity(0.22))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(DesignSystem.muted)
                }
            }
        }
    }
}

#Preview("Onboarding") {
    OnboardingView {}
}

#Preview("Import Hub") {
    ImportHubView()
        .environmentObject(DemoWorkflowStore())
}

#Preview("Import Review") {
    let store = DemoWorkflowStore()
    let songs = [
        ImportedSong(title: "晴天", artist: "周杰伦", source: .demo, rawText: "周杰伦 - 晴天", confidence: 0.96),
        ImportedSong(title: "后来", artist: nil, source: .plainText, rawText: "后来", confidence: 0.52)
    ]
    store.prepareForReview(playlist: ImportedPlaylist(source: .demo, title: "Preview 歌单", songs: songs, parseConfidence: 0.74))
    return ImportReviewView()
        .environmentObject(store)
}

#Preview("Match Report") {
    let store = DemoWorkflowStore()
    Task { await store.useDemoPlaylist() }
    return MatchReportView()
        .environmentObject(store)
}

#Preview("Voice Setup") {
    let store = DemoWorkflowStore()
    store.useSimulatedVoice()
    return VoiceSetupView()
        .environmentObject(store)
}

#Preview("Scenario Builder") {
    ScenarioBuilderView()
        .environmentObject(DemoWorkflowStore())
}

#Preview("Song Plan Result") {
    let store = DemoWorkflowStore()
    Task {
        await store.useDemoPlaylist()
        store.beginMatchingReviewedSongs()
        store.useSimulatedVoice()
        store.generatePlan()
    }
    return SongPlanResultView()
        .environmentObject(store)
}

#Preview("Export Center") {
    let store = DemoWorkflowStore()
    Task {
        await store.useDemoPlaylist()
        store.beginMatchingReviewedSongs()
        store.useSimulatedVoice()
        store.generatePlan()
    }
    return ExportCenterView()
        .environmentObject(store)
}

#Preview("Interview Mode") {
    InterviewModeView()
}
