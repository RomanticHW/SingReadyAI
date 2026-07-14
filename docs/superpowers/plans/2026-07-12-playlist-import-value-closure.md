# 歌单导入价值闭环实施计划

> **实施要求：** 按任务顺序推进，每个步骤使用复选框（`- [ ]`）记录状态；每个任务都要先验证失败场景，再完成实现、回归并独立提交。

**Goal:** 让用户导入 10～1000 首外部歌单后，无需逐首处理即可得到来源清楚、可直接使用、可安全导出的正式排歌结果，并确保待确认候选和公开网络候选永远不会混入正式计划。

**Architecture:** 以 SharedKit 的受约束领域模型作为唯一事实源：歌曲版本身份决定是否可自动接受，`SongMatchDisposition` 决定哪些歌曲可进入画像，带来源的候选安全门决定哪些歌曲可进入正式计划，`MatchBasis`/`PlanBasis` 决定派生结果是否仍有效。App Store 只负责任务编排、进度与原子发布；SwiftUI 只读取摘要和异常集合；版本化快照保存最后一个完整提交点，并兼容旧数据。

**Tech Stack:** Swift 5.9、SwiftUI、Swift Concurrency、Combine、Codable、XCTest/XCUITest、Swift Package Manager、XcodeGen、xcodebuild。

---

## 实施边界与文件职责

这是一个纵向闭环，不拆成互相独立的子项目：任一层单独上线都会留下“已识别但不知道能做什么”或“待确认歌曲混入正式计划”的缺口。实施时仍按以下边界分批提交，每个批次均可独立回归：

- `Sources/SingReadyAISharedKit/Catalog/SongVersionIdentity.swift`（新建）：解析歌名、别名和版本标记，产出可比较的歌曲版本身份；不负责打分。
- `Sources/SingReadyAISharedKit/Models/Models.swift`：保存可编码的匹配 disposition、计划条目来源和生成摘要；只保留兼容解码，不承载候选选择算法。
- `Sources/SingReadyAISharedKit/Recommendation/RecommendationContracts.swift`（新建）：定义正式候选、来源、数量守恒错误和计划生成上下文。
- `Sources/SingReadyAISharedKit/Recommendation/RecommendationCandidateGate.swift`（新建）：正式计划的唯一准入门；拒绝待确认、未采用替代和外部公开候选。
- `Sources/SingReadyAISharedKit/Workflow/PlaylistWorkflowContracts.swift`（新建）：定义修订、basis、操作状态和恢复时的有效性判定。
- `Sources/SingReadyAISharedKit/ExternalMusic/ExternalCandidateCollection.swift`（新建）：保存公开候选的原始可验证字段，不伪装成 `KTVTrack`。
- `SingReadyAI/App/DemoWorkflowStore+Import.swift`：分阶段导入、整理修订和批量匹配的原子提交。
- `SingReadyAI/App/DemoWorkflowStore+Recommendation.swift`：构造 `PlanBasis`、后台生成、校验数量并原子发布。
- `SingReadyAI/App/DemoWorkflowStore+Persistence.swift`：快照 v2、旧快照迁移、恢复一致性和失效矩阵。
- `SingReadyAI/Features/ProductFlow/*.swift`：首页下一步、异常优先整理、匹配摘要、来源计数和独立公开候选卡。
- `Sources/SingReadyAISharedKit/Export/Exporters.swift` 与 `StartTipsContentPolicy.swift`：只消费 ready 的正式计划；再次防御性剔除公开候选。

Task 1–22 的早期验证闭环不扩大当前约 215 首本地参考曲库；公开发布阶段必须由 Task 24A/24B 建立机器门禁并实际交付经批准的正式资源、覆盖和来源权利证据。本轮不承诺从第三方音乐 App 直接读取私有歌单接口，也不把在线公开搜索结果当成可唱曲库。对应产品边界以 `docs/superpowers/specs/2026-07-12-playlist-import-value-closure-design.md` 为准。

每个任务提交前除任务内的聚焦红绿灯外，都必须通过以下增量构建门，确保破坏性类型或 API 迁移不会把编译断点留给下一个任务：

    swift test
    xcodebuild build -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'generic/platform=iOS Simulator' -derivedDataPath Build/PlaylistImportClosure-Incremental CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

Expected: Swift 全套 PASS，App 模拟器构建 `** BUILD SUCCEEDED **`。若任务新增 App 文件，先运行 `xcodegen generate --use-cache`。

### Task 1: 建立歌曲版本身份合同

**Files:**
- Create: `Sources/SingReadyAISharedKit/Catalog/SongVersionIdentity.swift`
- Modify: `Sources/SingReadyAISharedKit/Catalog/SongNormalizer.swift`
- Modify: `Sources/SingReadyAISharedKit/ImportPipeline/PlainTextPlaylistParser.swift`
- Modify: `Sources/SingReadyAISharedKit/Models/Models.swift`
- Create: `Tests/SingReadyAISharedKitTests/SongVersionIdentityTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ExporterAndNormalizerTests.swift`

- [x] **Step 1: 写版本标记与兼容性红灯测试**

测试必须覆盖：无标记对无标记可兼容；Live/现场同义；Cover/翻唱同义；Remix/DJ、伴奏、Edit/剪辑分别归一；一侧有版本标记、双方冲突、未知版本均为 `requiresConfirmation`；带版本词的泛化别名只能召回，不能成为自动接受证据。

核心测试形态：

    func testSingleSidedVersionMarkerRequiresConfirmation() {
        let imported = SongVersionIdentity.parse(title: "后来 Live", versionTags: ["Live"])
        let catalog = SongVersionIdentity.parse(title: "后来", versionTags: [])
        XCTAssertEqual(imported.compatibility(with: catalog), .requiresConfirmation)
    }

    func testVersionedAliasIsSearchEvidenceOnly() {
        let evidence = SongIdentityEvidence.alias(
            rawValue: "后来 现场版",
            identity: .parse(title: "后来 现场版", versionTags: [])
        )
        XCTAssertFalse(evidence.allowsAutomaticAcceptance)
    }

- [x] **Step 2: 运行测试，确认因类型尚不存在而失败**

Run: `swift test --filter SongVersionIdentityTests`
Expected: FAIL，提示找不到 `SongVersionIdentity`、`SongVersionCompatibility` 或 `SongIdentityEvidence`。

- [x] **Step 3: 实现最小版本身份 API**

在新文件中完整实现以下公开边界，内部正则统一放在此处；`PlainTextPlaylistParser` 不再维护第二套版本词表：

    public enum SongVersionKind: String, Codable, CaseIterable, Hashable, Sendable {
        case live
        case cover
        case remix
        case accompaniment
        case edit
        case unknown
    }

    public enum SongVersionCompatibility: Equatable, Sendable {
        case compatible
        case requiresConfirmation
    }

    public struct SongVersionIdentity: Equatable, Sendable {
        public let normalizedBaseTitle: String
        public let kinds: Set<SongVersionKind>
        public let hasExplicitMarker: Bool

        public static func parse(title: String, versionTags: [String]) -> Self
        public func compatibility(with other: Self) -> SongVersionCompatibility
    }

    public enum SongIdentityEvidence: Equatable, Sendable {
        case canonicalTitle(identity: SongVersionIdentity)
        case alias(rawValue: String, identity: SongVersionIdentity)

        public var allowsAutomaticAcceptance: Bool { get }
    }

`KTVTrack` 增加 `versionTags: [String]`，初始化默认空数组，旧 JSON 解码缺字段时也回落为空数组；现有 215 首 fixture 无需批量改写。`ImportedSong.versionTags` 保持源数据，解析器改为调用同一个版本提取器。

- [x] **Step 4: 运行版本与旧数据回归**

Run: `swift test --filter SongVersionIdentityTests && swift test --filter ExporterAndNormalizerTests`
Expected: 两组测试 PASS；现有短标题、别名和旧曲库 JSON 解码合同不回退。

- [x] **Step 5: 提交版本身份基础**

    git add Sources/SingReadyAISharedKit/Catalog Sources/SingReadyAISharedKit/ImportPipeline/PlainTextPlaylistParser.swift Sources/SingReadyAISharedKit/Models/Models.swift Tests/SingReadyAISharedKitTests
    git commit -m "feat: 建立歌曲版本身份规则"

### Task 2: 用受约束 disposition 取代自由组合匹配状态

**Files:**
- Modify: `Sources/SingReadyAISharedKit/Catalog/SongMatcher.swift`
- Modify: `Sources/SingReadyAISharedKit/Models/Models.swift`
- Modify: `Sources/SingReadyAISharedKit/Recommendation/PreferenceProfiler.swift`
- Modify: `Sources/SingReadyAISharedKit/Recommendation/RecommendationEngine.swift`
- Modify: `Tests/SingReadyAISharedKitTests/SongMatcherTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/RecommendationEngineTests.swift`

- [x] **Step 1: 为六种状态和旧 JSON 迁移写红灯测试**

测试六种且仅六种 disposition：

    public enum SongMatchDisposition: Codable, Sendable {
        case acceptedOriginalExact(track: KTVTrack)
        case acceptedOriginalConfirmed(track: KTVTrack)
        case identityConfirmationRequired(candidates: [KTVTrack])
        case alternativeSuggested(candidates: [KTVTrack])
        case adoptedAlternative(track: KTVTrack)
        case unmatched
    }

断言 `acceptedTrack` 只对 `acceptedOriginalExact`、`acceptedOriginalConfirmed`、`adoptedAlternative` 返回曲目；`identityConfirmationRequired`、`alternativeSuggested`、`unmatched` 一律返回 nil 且不贡献画像。补充旧 `status + confirmationState + matchedTrack + alternatives` JSON 的逐类迁移 fixture，并断言无效组合归一成待确认或未找到，不得凭空接受。

- [x] **Step 2: 运行现有匹配/闭环测试，确认新合同红灯**

Run: `swift test --filter SongMatcherTests && swift test --filter ProductClosureTests`
Expected: FAIL；失败点应集中在缺少 `disposition`、旧自由组合构造器仍可创建非法状态，以及画像仍读取旧字段。

- [x] **Step 3: 改造 MatchResult 并保留单向兼容解码**

`MatchResult` 的主存储字段改为 `disposition`；提供以下派生属性供 App 迁移，禁止生产代码再同时判断多个旧字段：

    public var acceptedTrack: KTVTrack? { get }
    public var candidateTracks: [KTVTrack] { get }
    public var isVerified: Bool { get }
    public var isPending: Bool { get }
    public var isUnmatched: Bool { get }
    public var hasOriginalReferenceMatch: Bool { get }
    public var isAdoptedAlternative: Bool { get }

`SongMatchDisposition` 自定义 Codable，固定写入 `kind / track / candidates`，不依赖关联枚举的编译器自动 JSON 形状。`MatchResult.init(from:)` 优先解码 `disposition`；缺失时读取旧键并执行保守迁移。编码只写新格式。`PreferenceProfiler` 只遍历 `acceptedTrack`，并用 disposition 区分原歌与采用替代。

`MatchResult` 另存受约束的 `suggestedAlternatives`，用于已确认原曲之后仍可执行“改用替代歌曲”；该集合不参与 `acceptedTrack`、画像或推荐准入。初始化时按 disposition 规范化并去重，不能重新形成 `matchedTrack? × alternatives` 的非法组合。

为了让 Task 2 的提交独立可构建，在同一类型提供临时、只读兼容适配器：`matchedTrack/status/confirmationState/alternatives` 全部由 `disposition + suggestedAlternatives` 计算，旧 initializer 接收完整的 matchedTrack、alternatives、status、confirmationState、score 和 reason 后只做一次保守映射。不得提供 setter 或保存第二份旧字段。暂不添加 deprecated 属性，因为增量构建启用了 warnings-as-errors；用“migration-only”注释和 Task 16 删除门约束生命周期。这样当前 App/测试可编译，但 disposition 始终是唯一真源；Task 3、5、10、14、15 分层迁移真实调用点。

- [x] **Step 4: 更新统计与用户动作迁移测试**

将 `MatchStatistics` 改为从 disposition 完整分区，至少暴露 `verified/pending/unmatched/originalAccepted/adoptedAlternative`；动作状态机必须覆盖：

    identityConfirmationRequired + "就是这首"
        -> acceptedOriginalConfirmed

    alternativeSuggested + "用这首替代"
        -> adoptedAlternative

    identityConfirmationRequired + "用这首替代"
        -> adoptedAlternative

    acceptedOriginalExact / acceptedOriginalConfirmed + "改用这首"
        -> adoptedAlternative

    adoptedAlternative + "改用这首"
        -> adoptedAlternative(newTrack)

只有当前 `candidateTracks / suggestedAlternatives` 中的 track ID 可被采用。候选外的 ID、对 unmatched 的动作和语义相同的重复动作均保持原状态。

- [x] **Step 5: 运行两组聚焦回归**

Run:

    swift test --filter SongMatcherTests
    swift test --filter ProductClosureTests
    swift test
    xcodebuild build -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'generic/platform=iOS Simulator' -derivedDataPath Build/PlaylistImportClosure-Incremental CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

Expected: PASS 且 App 构建成功；旧快照 fixture 可解码，未确认歌曲不进入画像。增量构建通过依赖只读适配器，而不是保留旧可写状态。

- [x] **Step 5A: 关闭复核发现的数据准入漏洞**

旧 initializer 与旧 JSON 解码统一进入同一保守迁移函数：`acceptedOriginalExact` 必须同时满足歌名身份、非空导入歌手和歌手身份兼容，`acceptedOriginalConfirmed` 至少必须满足歌名身份；不满足时只保留同歌名身份候选并进入待确认，否则归为未命中。歌曲版本兼容继续由 Task 3 处理。

推荐候选池只从 disposition 的 `acceptedTrack` 准入，待确认排除集合只读取 `candidateTracks`，不再经由兼容 `alternatives` 把 `suggestedAlternatives` 带入正式计划。画像的歌手与其他维度保持一致，只从 `acceptedTrack` 统计；待确认、未命中和采用前的导入歌手均不贡献画像。

- [x] **Step 6: 提交匹配状态模型**

    git add Sources/SingReadyAISharedKit/Models/Models.swift Sources/SingReadyAISharedKit/Recommendation/PreferenceProfiler.swift Tests/SingReadyAISharedKitTests/SongMatcherTests.swift Tests/SingReadyAISharedKitTests/ProductClosureTests.swift
    git commit -m "refactor: 收紧歌曲匹配状态合同"

### Task 3: 落实唯一身份、阈值、进度与规模预算

**Files:**
- Modify: `Sources/SingReadyAISharedKit/Catalog/SongMatcher.swift`
- Modify: `Sources/SingReadyAISharedKit/Catalog/SongNormalizer.swift`
- Modify: `Tests/SingReadyAISharedKitTests/SongMatcherTests.swift`
- Create: `Tests/SingReadyAISharedKitTests/PlaylistScaleContractTests.swift`

- [x] **Step 1: 写自动接受安全门红灯测试**

用表驱动测试锁定以下顺序：

1. 规范化歌名身份、歌手身份、版本身份均兼容且候选唯一，才是 `acceptedOriginalExact`。
2. 非完全精确，但同身份有冲突或总分 `>= 0.78`，进入 `identityConfirmationRequired`。
3. 分数 `>= 0.60 && < 0.78`，进入 `alternativeSuggested`。
4. 更低为 `unmatched`。
5. 缺歌手即使唯一、别名带版本标记、同名多候选、单侧版本标记均不得自动接受。

边界值必须包含 `0.5999 / 0.60 / 0.7799 / 0.78`，避免以后比较符漂移。

- [x] **Step 2: 运行匹配测试，确认旧 `0.95`/`0.78` 自由接受逻辑失败**

Run: `swift test --filter SongMatcherTests`
Expected: FAIL；现有 fuzzy 自动接受、title-only 分支和版本词剥离逻辑与新断言冲突。

- [x] **Step 3: 实现候选证据与唯一性判定**

`CatalogMatchSession` 先召回候选，再为每个候选构造 `SongIdentityEvidence` 和版本兼容性；自动接受判定集中为一个纯函数：

    struct AutomaticAcceptanceDecision {
        static func allows(
            importedSong: ImportedSong,
            candidate: KTVTrack,
            evidence: SongIdentityEvidence,
            compatibleCandidateCount: Int
        ) -> Bool
    }

不得在 title-only 快路径、alias 快路径或分数路径重复实现“看起来差不多就接受”。`smartAlternatives` 仅返回供用户核对的候选，不再暗示这些候选已可进入推荐。

- [x] **Step 4: 给分析执行器增加单调进度**

为 `PlaylistAnalysisExecutor.analyze` 增加可选 `progress: @Sendable (Int, Int) async -> Void`；每处理固定批次（建议 20 首）报告一次，保证首个事件为 `0/total`、最后一个为 `total/total`、中间单调递增。回调只用于展示，不发布部分 matches/profile。

- [x] **Step 5: 写 500/1000 混合 fixture、取消和主线程心跳红灯**

`PlaylistScaleContractTests` 用确定性构造器生成 25% 精确、25% 缺歌手、25% 相近/替代、25% 未找到的歌单；测试范围从已构造的 `ImportedPlaylist` 开始，只包含曲库索引、匹配、画像与摘要：

    500 首完整分析 < 5 秒
    1000 首完整分析 < 8 秒
    1000 首精确匹配继续 < 5 秒
    主线程心跳最长间隔 < 100 毫秒
    取消后不返回部分 PlaylistAnalysisOutput

性能断言使用 `ContinuousClock`；不要把网络、OCR、SwiftUI 或磁盘计入该测试。

- [x] **Step 6: 运行规模合同并优化到绿灯**

Run: `swift test --filter PlaylistScaleContractTests && swift test --filter SongMatcherTests`
Expected: PASS；若超时，先复用规范化索引和预计算身份，不降低阈值、不跳过候选。

- [x] **Step 7: 提交匹配安全门与规模合同**

    git add Sources/SingReadyAISharedKit/Catalog Tests/SingReadyAISharedKitTests/SongMatcherTests.swift Tests/SingReadyAISharedKitTests/PlaylistScaleContractTests.swift
    git commit -m "feat: 完善批量匹配安全门与进度"

### Task 4: 建立正式推荐来源与数量守恒

**Files:**
- Create: `Sources/SingReadyAISharedKit/Recommendation/RecommendationContracts.swift`
- Modify: `Sources/SingReadyAISharedKit/Models/Models.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/RecommendationCapacityContractTests.swift`

- [x] **Step 1: 写 Codable 与数量守恒红灯测试**

定义并测试：

    public enum SongRecommendationOrigin: String, Codable, CaseIterable, Sendable {
        case importedMatch
        case adoptedAlternative
        case sameArtistSupplement
        case styleSupplement
        case sceneSupplement
        case popularSupplement
        case legacyUnknown
    }

    public struct SongPlanGenerationSummary: Codable, Equatable, Sendable {
        public let playlistID: UUID
        public let playlistTitle: String
        public let importedSongCount: Int
        public let verifiedSongCount: Int
        public let pendingSongCount: Int
        public let unmatchedSongCount: Int
        public let formalPlanCount: Int
        public let importedMatchCount: Int
        public let adoptedAlternativeCount: Int
        public let supplementCount: Int
        public let scenario: KTVScenario
        public let peopleCount: Int
        public let durationMinutes: Int
        public let voiceSource: VoiceProfileSource
        public let feedbackCount: Int

        public init(
            context: SongPlanGenerationContext,
            items: [SongPlanItem]
        ) throws
    }

`SongPlanGenerationContext` 完整携带上述歌单、匹配分区、场景、人数、时长、音区来源和反馈数；构造 summary 时从最终 items 单遍统计 N/X/R/Y。断言 `formalPlanCount == importedMatchCount + adoptedAlternativeCount + supplementCount`，且 context 计数均非负；不满足时抛 `RecommendationGenerationError.countMismatch`。旧 `SongPlanItem` 缺 origin 时为 `legacyUnknown`，旧 `SongPlan` 缺 summary 时为 `nil`，不反推虚假来源。

`SongPlanGenerationContext` 和 `SongPlanGenerationSummary` 都必须显式声明覆盖全部字段的 public initializer；不能依赖 Swift 默认的 internal memberwise initializer，否则 App target 无法构造。

- [x] **Step 2: 运行聚焦测试，确认类型与解码缺失**

Run: `swift test --filter ProductClosureTests && swift test --filter RecommendationCapacityContractTests`
Expected: FAIL，原因是 origin/summary 尚不存在或数量不守恒。

- [x] **Step 3: 实现来源模型与只读展示名称**

`SongPlanItem` 增加 `origin` 并贯穿初始化、解码、`sanitizedForTrustBoundaries`；`SongPlan` 增加可选 `generationSummary`。在本任务同时实现 `SongPlanGenerationContext` 与 throwing summary 构造器；Task 5 把真实上下文接到所有生成调用，Task 11 再把同一 context 与 `PlanBasis` 一起冻结，避免到结果页再扩模型。展示名称使用大陆产品语言：

    importedMatch        -> "来自导入歌单"
    adoptedAlternative   -> "你采用的替代"
    sameArtistSupplement -> "同歌手补充"
    styleSupplement      -> "风格补充"
    sceneSupplement      -> "场景补充"
    popularSupplement    -> "热门补充"
    legacyUnknown        -> "历史排歌"

- [x] **Step 4: 运行 Codable、容量和旧计划回归**

Run: `swift test --filter ProductClosureTests && swift test --filter RecommendationCapacityContractTests`
Expected: PASS；现有容量、锁定和旧 JSON 合同不回退。

- [x] **Step 5: 提交来源与摘要模型**

    git add Sources/SingReadyAISharedKit/Recommendation/RecommendationContracts.swift Sources/SingReadyAISharedKit/Models/Models.swift Tests/SingReadyAISharedKitTests/ProductClosureTests.swift Tests/SingReadyAISharedKitTests/RecommendationCapacityContractTests.swift
    git commit -m "feat: 增加排歌来源与数量守恒"

### Task 5: 把候选安全门变成推荐唯一入口

**Files:**
- Create: `Sources/SingReadyAISharedKit/Recommendation/RecommendationCandidateGate.swift`
- Modify: `Sources/SingReadyAISharedKit/Recommendation/RecommendationContracts.swift`
- Modify: `Sources/SingReadyAISharedKit/Recommendation/RecommendationEngine.swift`
- Modify: `Sources/SingReadyAISharedKit/Recommendation/RecommendationReasonBuilder.swift`
- Modify: `Sources/SingReadyAISharedKit/Models/Models.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Recommendation.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/RecommendationEngineTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/RecommendationCapacityContractTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ExternalCandidateContractTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ExternalMusicCandidateProviderTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ExporterAndNormalizerTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/RecommendationInteractionContractTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/VoiceMeasurementContractTests.swift`

- [x] **Step 1: 写三条拒绝路径和合法重合路径红灯测试**

必须分别证明：

- `identityConfirmationRequired` 的候选不进正式计划。
- `alternativeSuggested` 在用户未采用前不进正式计划。
- `unmatched` 附带的候选不进正式计划。
- A 歌曲待确认某 track、B 歌曲明确接受同一 track 时，该 track 可经 B 的合法路径进入一次，origin 为 `importedMatch`；不能用全局 pending ID 误杀。
- 外部 `catalogSource == .externalSimilar` 即使从 match、catalog 或 locked ID 三条路径进入，也全部拒绝。
- 锁定已确认原曲、已采用替代或合法本地补充时保留原有 origin；锁定不能创造来源。仅由待确认、未采用替代、暂未找到猜测、外部候选或无独立合法分类支持的 locked ID 必须让整次生成抛 `RecommendationGenerationError.lockedTrackUnavailable(trackIDs:)`，不得静默少歌或伪装为 `legacyUnknown`/`popularSupplement`。错误 ID 去重后按稳定顺序返回。

- [x] **Step 2: 运行推荐测试，确认当前 `acceptedTrack + alternatives` 池红灯**

Run: `swift test --filter ProductClosureTests && swift test --filter ExternalCandidateContractTests`
Expected: FAIL；当前 `RecommendationEngine.buildCandidatePool` 会把未采用 alternatives 或外部候选加入池。

- [x] **Step 3: 实现 path-aware 候选安全门**

核心接口：

    struct RecommendationCandidate: Sendable {
        let track: KTVTrack
        let origin: SongRecommendationOrigin
    }

    struct RecommendationCandidateGate: Sendable {
        func candidates(
            matches: [MatchResult],
            preferenceProfile: PreferenceProfile,
            scenario: ScenarioConfig,
            catalog: [KTVTrack],
            lockedTrackIDs: Set<String>
        ) throws -> [RecommendationCandidate]
    }

候选路径：

- `acceptedOriginalExact / acceptedOriginalConfirmed` -> `importedMatch`
- `adoptedAlternative` -> `adoptedAlternative`
- 本地 catalog 再按同歌手、风格、场景、热门依次标记 supplement origin
- 其他 disposition 不产生正式候选

同一语义歌曲多路径出现时，来源优先级为 `adoptedAlternative > importedMatch > sameArtistSupplement > styleSupplement > sceneSupplement > popularSupplement`。只接受 `.ktvCatalog`。

候选完成后再逐一验证 locked ID：只有已经通过上述某条合法路径且来源不是 `legacyUnknown` 的本地歌曲可以继续生成。锁定不新增来源类型，也不读取上一版计划 origin；否则同一 `PlanBasis` 会因历史计划不同产生不同结果。失败时 Store 不发布新计划、不持久化、不导航，并显示 `有 N 首已保留歌曲无法按当前条件核对来源，请取消保留或重新确认后再试。`；Task 11 再把同一错误接入带 previous 的 failed/stale 状态。

- [x] **Step 4: 让排序、替换和 plan item 全程携带 origin**

`ScoredTrack` 增加 origin；`planItem`、锁定插入、场景 hard-rule 替换和去重均保留来源。删除外部 provisional 的评分、分区和 hard-rule 特判；`normalizeSongPlanSectionsForTrustBoundary` 对旧 provisional item 直接丢弃，不再放进 `externalVerification` 分区。

- [x] **Step 5: 在生成末尾校验摘要**

`RecommendationEngine.generatePlan` 增加必填 `generationContext: SongPlanGenerationContext`，在所有 hard-rule 调整完成后从 context 与最终 items 构造 `SongPlanGenerationSummary`；任何 count mismatch 都抛错，不返回可发布 `SongPlan`。公开 API 采用 `throws`，不得提供伪造历史来源的默认 context。

破坏性签名必须在本任务一次迁完：用

    rg -l 'recommendationEngine\.generatePlan|RecommendationEngine\(\)\.generatePlan|engine\.generatePlan' SingReadyAI Tests Sources

列出全部调用点；测试方法增加 `throws`/`try`，App 的同步调用先用 `do/catch` 保守处理为“不发布计划并显示可重试错误”。Task 11 再把这个 catch 接入正式 `failed/stale` 状态，但 Task 5 提交本身必须可编译、不可使用 `try!` 或静默 fallback。

- [x] **Step 6: 运行推荐全套聚焦测试**

Run:

    swift test --filter ProductClosureTests
    swift test --filter RecommendationEngineTests
    swift test --filter RecommendationCapacityContractTests
    swift test --filter ExternalCandidateContractTests
    swift test
    xcodebuild build -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'generic/platform=iOS Simulator' -derivedDataPath Build/PlaylistImportClosure-Incremental CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

Expected: 全部 PASS 且 `** BUILD SUCCEEDED **`；正式条目数始终等于 X+R+Y，外部候选数不参与容量和 hard rules，仓库内不存在遗漏的非 `try` 调用点。

- [x] **Step 7: 提交候选准入门**

    git add Sources/SingReadyAISharedKit/Recommendation Sources/SingReadyAISharedKit/Models/Models.swift SingReadyAI/App/DemoWorkflowStore+Recommendation.swift Tests/SingReadyAISharedKitTests
    git commit -m "refactor: 统一正式推荐候选准入"

### Task 6: 建立公开候选的独立领域集合

**Files:**
- Create: `Sources/SingReadyAISharedKit/ExternalMusic/ExternalCandidateCollection.swift`
- Modify: `Sources/SingReadyAISharedKit/ExternalMusic/ExternalMusicCandidateProvider.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ExternalMusicCandidateProviderTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ExternalCandidateContractTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`

- [ ] **Step 1: 反转“外部候选可参与推荐”的旧测试**

将 `testRecommendationEngineCanUseMappedExternalCandidates` 改成“公开候选即使被旧 mapper 转成 KTVTrack 也不会进入正式计划”。将“高相关候选进入计划”“重新安置到待核对分区”等旧合同改为：

    formal plan count unchanged
    external candidate title absent from every SongPlanItem
    hard-rule denominator unchanged
    ExternalCandidateCollection.count == E

- [ ] **Step 2: 运行外部候选测试，确认旧行为红灯**

Run: `swift test --filter ExternalMusicCandidateProviderTests && swift test --filter ExternalCandidateContractTests`
Expected: FAIL；当前公开候选的唯一聚合产物仍是带占位难度/音区的 `KTVTrack`。

- [ ] **Step 3: 实现不依赖 App 状态的原始集合**

    public struct ExternalCandidateBasis: Codable, Equatable, Sendable {
        public let playlistID: UUID
        public let reviewRevision: UInt64
        public let requestRevision: UInt64

        public init(
            playlistID: UUID,
            reviewRevision: UInt64,
            requestRevision: UInt64
        )
    }

    public struct ExternalCandidateCollection: Codable, Equatable, Sendable {
        public let basis: ExternalCandidateBasis
        public let candidates: [ExternalSongCandidate]
        public var count: Int { candidates.count }

        public init(
            basis: ExternalCandidateBasis,
            candidates: [ExternalSongCandidate]
        )
    }

本任务只定义领域模型和纯聚合器，不提前改 App 字段；`reviewRevision` 在下一任务建立工作流账本后才由 Store 提供真实值。这样本提交没有未定义的运行时依赖。

- [ ] **Step 4: 将聚合器改为 raw candidate 语义去重**

集合只保存 `ExternalSongCandidate` 已有的公开原始元数据；不得制造 difficulty、vocalRange、sceneTags 或 KTV availability，也不得把本地 fallback 写入集合。新 `ExternalCandidateCollectionAccumulator` 按歌曲身份语义 key 去重，稳定保留更高相关度。语义 key 必须复用 Task 1 的版本身份：studio 与 Live/Remix 保持不同，`Live/现场版` 等同义版本可以归并；不能直接复用会剥离版本的旧 `normalizedKey`。相同 confidence 但来源、URL、reasons 不同的候选也必须按固定 tie-break 得到与输入顺序无关的唯一结果，排序后再应用 limit。

`ExternalCandidateCollection` 的 public initializer 与自定义 decoder 都必须经过同一规范化入口，不能允许调用方或旧 JSON 绕过语义去重制造重复 E。Accumulator 合并时只有 basis 完全相等才继承 existing candidates；basis 不同从空集合开始。旧 `ExternalCandidateTrackMapper/Accumulator` 在 Task 12 运行时迁移前仍是 legacy runtime bridge，只加准确注释，不加会触发 warnings-as-errors 的 deprecated 属性；Task 12 移除实时调用后再降为 migration-only。

- [ ] **Step 5: 验证 Codable、稳定顺序和正式计划隔离**

新增 round-trip、public init 与 decoder 同边界、不同输入顺序结果一致、同语义保留高相关项、同 confidence 完整 tie-break、studio/Live/Remix 版本隔离、basis 变化不继承、limit 在稳定排序后生效、collection count 为 E 的测试；继续运行 Task 5 的三条外部候选拒绝路径。

- [ ] **Step 6: 运行领域与完整构建门**

Run:

    swift test --filter ExternalMusicCandidateProviderTests
    swift test --filter ExternalCandidateContractTests
    swift test --filter ProductClosureTests
    swift test

Expected: PASS；collection 可编码、去重稳定，推荐计划中没有任何公开候选。App 此时仍可用旧字段展示候选，但候选已被 Task 5 的安全门拒绝；运行时字段和快照在 Task 12 同批迁移。

- [ ] **Step 7: 提交公开候选领域模型**

    git add Sources/SingReadyAISharedKit/ExternalMusic Tests/SingReadyAISharedKitTests
    git commit -m "feat: 建立独立公开候选集合"

### Task 7: 建立 workflow 修订、basis 与恢复有效性

**Files:**
- Create: `Sources/SingReadyAISharedKit/Workflow/PlaylistWorkflowContracts.swift`
- Create: `Tests/SingReadyAISharedKitTests/PlaylistWorkflowContractTests.swift`

- [ ] **Step 1: 为 basis 相等性与失效矩阵写红灯测试**

测试同一 playlistID 但 reviewRevision 不同不能接受旧匹配；catalogRevision 变化会让 match 和 plan 失效；scenario、voice、feedback、lock/remove 任一指纹变化只让 plan 失效；外部候选变化不影响 plan basis。

- [ ] **Step 2: 运行测试，确认合同类型不存在**

Run: `swift test --filter PlaylistWorkflowContractTests`
Expected: FAIL，提示缺少 revision ledger、`MatchBasis`、`PlanBasis`、`CompletedPlaylistAnalysis`、准备摘要和有效性 policy。

- [ ] **Step 3: 实现可编码 basis 与修订账本**

    public struct WorkflowRevisionLedger: Codable, Equatable, Sendable {
        public var review: UInt64
        public var match: UInt64
        public var feedback: UInt64
        public var trackControls: UInt64

        public init(
            review: UInt64 = 0,
            match: UInt64 = 0,
            feedback: UInt64 = 0,
            trackControls: UInt64 = 0
        )
    }

    public struct MatchBasis: Codable, Equatable, Sendable {
        public let playlistID: UUID
        public let reviewRevision: UInt64
        public let catalogRevision: String

        public init(
            playlistID: UUID,
            reviewRevision: UInt64,
            catalogRevision: String
        )
    }

    public struct PlanBasis: Codable, Equatable, Sendable {
        public let matchBasis: MatchBasis
        public let matchRevision: UInt64
        public let scenarioFingerprint: String
        public let voiceSource: VoiceProfileSource
        public let voiceFingerprint: String
        public let feedbackRevision: UInt64
        public let trackControlsRevision: UInt64
        public let catalogRevision: String

        public init(
            matchBasis: MatchBasis,
            matchRevision: UInt64,
            scenarioFingerprint: String,
            voiceSource: VoiceProfileSource,
            voiceFingerprint: String,
            feedbackRevision: UInt64,
            trackControlsRevision: UInt64,
            catalogRevision: String
        )
    }

`catalogRevision` 由当前本地曲库的稳定 ID/标题/歌手/版本身份生成，不使用进程随机 `Hasher`。场景、音区和内容指纹同样使用稳定串或固定摘要。`voiceFingerprint` 必须包含实际音区结果，`voiceSource` 单独保存，防止“通用参考”和“实测音区”结果碰巧相同却被视为同一 basis。

- [ ] **Step 4: 实现完整分析、准备摘要和显式状态类型**

    public struct CompletedPlaylistAnalysis: Codable, Sendable {
        public let basis: MatchBasis
        public let matchRevision: UInt64
        public let matches: [MatchResult]
        public let preferenceProfile: PreferenceProfile

        public init(
            basis: MatchBasis,
            matchRevision: UInt64,
            matches: [MatchResult],
            preferenceProfile: PreferenceProfile
        )
    }

    public struct PlaylistPreparationSummary: Equatable, Sendable {
        public let importedCount: Int
        public let validReviewedCount: Int
        public let verifiedCount: Int
        public let pendingCount: Int
        public let unmatchedCount: Int
        public let canContinue: Bool

        public init(
            importedCount: Int,
            validReviewedCount: Int,
            verifiedCount: Int,
            pendingCount: Int,
            unmatchedCount: Int,
            canContinue: Bool
        )
    }

    public enum ImportOperationState: Equatable, Sendable {
        case idle
        case resolving
        case failed(message: String, retryable: Bool)
        case cancelled
    }

    public enum MatchOperationState: Equatable, Sendable {
        case notStarted
        case running(processed: Int, total: Int)
        case ready(MatchBasis)
        case failed(message: String, retryable: Bool)
        case cancelled
    }

    public struct StalePlanSnapshot: Codable, Sendable {
        public let plan: SongPlan
        public let previousBasis: PlanBasis?
        public let reason: String

        public init(
            plan: SongPlan,
            previousBasis: PlanBasis?,
            reason: String
        )
    }

    public enum PlanGenerationState: Sendable {
        case absent
        case generating(basis: PlanBasis, previous: StalePlanSnapshot?)
        case ready(plan: SongPlan, basis: PlanBasis)
        case stale(StalePlanSnapshot)
        case failed(message: String, retryable: Bool, previous: StalePlanSnapshot?)
    }

`PlaylistPreparationSummary` 由 playlist、有效 review 草稿和一份完整 analysis 单次遍历计算，不持久化、不从 UI 字符串反推。Task 7 只提交 SharedKit 类型和纯函数，不提前删除 Store 的 `isWorking/songPlan/matches`；Task 9、10、11 分别迁移 import、match、plan 真源，Task 11 最后删除旧的可写派生字段，避免任何中间提交出现双真源或编译断点。

- [ ] **Step 5: 增加纯函数有效性 policy**

    public enum PlaylistWorkflowValidityPolicy {
        public static func accepts(matchBasis: MatchBasis, current: MatchBasis) -> Bool
        public static func accepts(planBasis: PlanBasis, current: PlanBasis) -> Bool
        public static func restoredMatchState(
            persistedAnalysis: CompletedPlaylistAnalysis?,
            currentBasis: MatchBasis
        ) -> MatchOperationState
    }

只有 `persistedAnalysis?.basis == currentBasis` 时才返回 `.ready(persistedAnalysis.basis)`；其余一律 `notStarted`。运行中的临时 progress 不进入参数、不持久化；不能根据导航 stage 推断 ready。

- [ ] **Step 6: 运行合同测试**

Run: `swift test --filter PlaylistWorkflowContractTests`
Expected: PASS；每个上游变化只失效规格矩阵规定的下游。

- [ ] **Step 7: 提交状态合同**

    git add Sources/SingReadyAISharedKit/Workflow Tests/SingReadyAISharedKitTests/PlaylistWorkflowContractTests.swift
    git commit -m "feat: 增加工作流有效性合同"

### Task 8: 先建立可渐进迁移的 v2 快照壳

**Files:**
- Modify: `Sources/SingReadyAISharedKit/Storage/WorkflowSnapshotStore.swift`
- Modify: `Tests/SingReadyAISharedKitTests/StoragePrivacyHardeningTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/WorkflowPersistenceExecutorTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/AppGroupStoreTests.swift`

- [ ] **Step 1: 写 v1 读取、v2 新字段与旧 App 构造兼容红灯**

测试同一存储层同时满足：

- schema 1 archive 可解码为 v2 `WorkflowSnapshot`，但缺 basis 的旧派生结果只进入 legacy bridge，不冒充 `CompletedPlaylistAnalysis` 或 ready `PersistedPlanRecord`。
- schema 2 可 round-trip `WorkflowRevisionLedger`、`CompletedPlaylistAnalysis?`、`PersistedPlanRecord?`、`ExternalCandidateCollection?`。
- 当前 App 使用的旧 WorkflowSnapshot initializer 和只读 `matches/preferenceProfile/songPlan/externalCandidateTracks` 访问器仍可编译，但它们只读 legacy bridge，没有第二份可写状态。
- running/generating/failed operation state不直接编码；只能编码最后一个完整 ready/stale plan record。

- [ ] **Step 2: 运行存储测试，确认当前 schema 1 红灯**

Run: `swift test --filter StoragePrivacyHardeningTests && swift test --filter WorkflowPersistenceExecutorTests`
Expected: FAIL；当前 archive 没有 v2 字段、ArchiveV1 分流或 persisted plan record。

- [ ] **Step 3: 定义稳定的持久化计划记录**

    public enum PersistedPlanRecord: Codable, Sendable {
        case ready(plan: SongPlan, basis: PlanBasis)
        case stale(StalePlanSnapshot)
    }

`PlanGenerationState.generating/failed` 若携带 previous，只把 previous 编成 `.stale`；无 previous 时不写 plan record。自定义 Codable 固定 `kind / plan / basis / reason` 键，不依赖关联枚举自动形状。

- [ ] **Step 4: 扩展 WorkflowSnapshot 并提供两个显式 public initializer**

v2 主 initializer 覆盖原始歌单/草稿、`revisions`、`completedAnalysis`、`persistedPlanRecord`、`externalCandidateCollection`、音区、场景、反馈和控制项，并声明为 public。另保留一个加“migration-only”注释但暂不标 deprecated 的旧 initializer，把旧 matches/profile/songPlan/external tracks 仅写进内部 `LegacyWorkflowDerivationBridge`；待 App 调用点迁完后由 Task 16 删除。

旧属性全部是 bridge/new state 的只读计算值，不提供 setter；读取优先 new state，只有对应 new state 为 nil 时才回落 bridge。Task 10、11、12 每迁移一个领域，就在写入 v2 新字段时清空该领域的 bridge 值，并删除 App 对相应适配器的使用；适配器最终只服务 ArchiveV1 测试与迁移，因此不会出现两套同时可写的真源。

- [ ] **Step 5: 显式分流 ArchiveV1 与 ArchiveV2**

`currentSchemaVersion = 2`。先读取 version header，再分别解码：

    switch header.schemaVersion {
    case 1:
        return .loaded(migrateShell(try decoder.decode(ArchiveV1.self, from: data)))
    case 2:
        return .loaded(try decoder.decode(ArchiveV2.self, from: data).snapshot)
    default:
        try quarantineCurrentArchive()
        return .quarantined(.incompatibleVersion)
    }

`migrateShell` 只搬运可安全保留的数据和 legacy bridge；完整 v1 有效性归一、公开候选丢弃和超限写保护在 Task 12 完成。

- [ ] **Step 6: 运行全量 Swift 与 App 增量构建**

Run:

    swift test --filter StoragePrivacyHardeningTests
    swift test --filter WorkflowPersistenceExecutorTests
    swift test --filter AppGroupStoreTests
    swift test
    xcodebuild build -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'generic/platform=iOS Simulator' -derivedDataPath Build/PlaylistImportClosure-Incremental CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

Expected: PASS 且 `** BUILD SUCCEEDED **`；当前 App 通过只读持久化 bridge 保持可编译，新写入 archive 已是 schema 2。

- [ ] **Step 7: 提交 v2 快照壳**

    git add Sources/SingReadyAISharedKit/Storage/WorkflowSnapshotStore.swift Tests/SingReadyAISharedKitTests
    git commit -m "feat: 建立工作流快照 v2 结构"

### Task 9: 把新导入和整理编辑改成线性提交

**Files:**
- Modify: `Sources/SingReadyAISharedKit/Storage/WorkflowSnapshotStore.swift`
- Modify: `SingReadyAI/App/WorkflowState.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Operations.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Import.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Persistence.swift`
- Modify: `SingReadyAI/Features/ProductFlow/ImportFlowViews.swift`
- Modify: `SingReadyAI/Features/ProductFlow/ImportReviewComponents.swift`
- Modify: `Tests/SingReadyAISharedKitTests/WorkflowPersistenceExecutorTests.swift`
- Modify: `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`

- [ ] **Step 1: 写“旧工作流直到新工作流持久化成功”红灯**

在 persistence executor 测试中模拟：A 为当前完整计划，B 为新导入；B 保存失败、被取消或被更新的 C 抢先时，磁盘和内存都必须仍是 A 或最终 C，不能出现“磁盘写入 B、内存拒绝 B”的分叉。

UI 测试补充：导入过程中首页已有计划仍可恢复；取消后原计划、最近导入和导出内容不变；新歌单只有在非空 playlist 与 review drafts 一起落盘后才导航到整理页。

另补文本边界：50,000 字且不超过 1,000 行可进入解析；50,001 字或 1,001 行在解析/匹配前失败，并保留上一份稳定工作流。网络解析超时仍走导入任务 deadline，不得复用本地分析的 20 秒预算。

- [ ] **Step 2: 运行聚焦测试，确认当前先清空内存的实现失败**

Run: `swift test --filter WorkflowPersistenceExecutorTests`
Expected: FAIL；当前 `prepareForReview` 在持久化完成前已经替换 `importedPlaylist` 并清空 matches/plan。

- [ ] **Step 3: 给 actor 增加带 generation 的稳定提交**

在 `WorkflowPersistenceExecutor` 内实现 generation 预约和唯一线性化点：

    public enum WorkflowCommitResult: Sendable {
        case applied
        case superseded
    }

    public func reserveWorkflowMutation(generation: UInt64)

    public func commitWorkflowSnapshot(
        _ snapshot: WorkflowSnapshot,
        generation: UInt64
    ) async throws -> WorkflowCommitResult

导入开始、取消、清除和新提交都先预约同一单调 generation；commit 只接受当前预约值。进入最终文件替换后设置短暂 `isCommittingImportedWorkflow`，这段临界区禁用重新导入/最近导入/取消按钮；谁先进入 actor 临界区谁先线性化，避免“磁盘接受 B、内存拒绝 B、C 又被取消”的分叉。App 侧 gate 只管理任务 token，不能推翻 actor 已完成的提交。

- [ ] **Step 4: 将 `prepareForReview` 拆成候选构造与提交**

    func makeInitialWorkflowCandidate(
        playlist: ImportedPlaylist,
        inputSource: RecommendationInputSource
    ) -> WorkflowSnapshot

    func commitImportedWorkflow(
        _ candidate: WorkflowSnapshot,
        generation: UInt64,
        navigate: Bool
    ) async throws

先用 Task 8 的 v2 initializer 构造 B：review revision 从 0 开始，`completedAnalysis/persistedPlanRecord/externalCandidateCollection` 均为 nil；不修改 A。B 快照和整理草稿保存成功且 request 仍有效后，一次性发布到 Store，再记录最近导入。最近导入保存失败只提示“歌单已经打开，最近导入暂时没保存”，不得回滚已完成的主快照。

- [ ] **Step 5: 集中整理修订与下游失效**

接入 `ImportOperationState` 作为导入任务唯一真源；导入扩展不再写通用 `isWorking`。所有标题/歌手编辑、删除、撤销经过单一入口：

    func commitReviewMutation(_ mutation: ReviewMutation) {
        revisions.review &+= 1
        cancelCurrentMatching()
        matches = []
        preferenceProfile = nil
        songPlan = nil
        externalCandidateTracks = []
        lockedTrackIDs.removeAll()
        removedTrackIDs.removeAll()
    }

这里有意只清理各领域尚未迁移的旧运行时字段：Task 10 同批把 `matches/preferenceProfile` 换成 completedAnalysis，Task 11 同批把 `songPlan` 换成 plan state，Task 12 同批把 `externalCandidateTracks` 换成 collection。每一阶段同一领域都只有一套可写状态；Task 9 不提前引用尚未接入 Store 的字段。

`reviewSongs` 改成 `private(set)`；`SongDraftEditor` 不再绑定 `$store.reviewSongs`，改为 value + `onTitleChange/onArtistChange/onDelete` closure 调用 `commitReviewMutation`。空歌名是唯一硬阻塞；缺歌手、低置信度和版本不确定只标记 `needsAttention`，不禁止继续。

- [ ] **Step 6: 运行持久化与导入取消 UI 聚焦测试**

Run:

    swift test --filter WorkflowPersistenceExecutorTests
    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SingReadyAIUITests/SingReadyAIUITests/testCancellingAnImportKeepsCurrentPlanAndHistory -only-testing:SingReadyAIUITests/SingReadyAIUITests/testLeavingAndReturningDoesNotCommitAnOldImportRequest -only-testing:SingReadyAIUITests/SingReadyAIUITests/testImportTimeoutReturnsToRetryableStateWithoutLateCommit

Expected: PASS；取消、超时和迟到完成都不覆盖最后稳定工作流。

- [ ] **Step 7: 提交线性导入**

    git add Sources/SingReadyAISharedKit/Storage/WorkflowSnapshotStore.swift SingReadyAI/App Tests/SingReadyAISharedKitTests/WorkflowPersistenceExecutorTests.swift UITests/SingReadyAIUITests/SingReadyAIUITests.swift
    git commit -m "refactor: 原子提交导入与整理修订"

### Task 10: 原子发布完整匹配分析并提供可取消进度

**Files:**
- Modify: `Sources/SingReadyAISharedKit/Catalog/SongMatcher.swift`
- Modify: `Sources/SingReadyAISharedKit/Workflow/PlaylistWorkflowContracts.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Import.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Operations.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Persistence.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+ProductClosure.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Recommendation.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+DemoLaunch.swift`
- Modify: `Tests/SingReadyAISharedKitTests/SongMatcherTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/PlaylistWorkflowContractTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`
- Modify: `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`

- [ ] **Step 1: 写完整分析快照与迟到发布红灯**

使用 Task 7 已定义的 `CompletedPlaylistAnalysis`。测试证明 matches/profile 不能分别发布；reviewRevision、catalogRevision、任务 token 任一变化，整份 output 丢弃；取消后只保留 review 内容；旧完整分析仅在 basis 未变时可继续显示。

- [ ] **Step 2: 运行聚焦测试，确认当前分散字段无法保证一致**

Run: `swift test --filter PlaylistWorkflowContractTests && swift test --filter SongMatcherTests`
Expected: FAIL；当前 Store 仍分别维护 `matches` 与 `preferenceProfile`，且运行态没有 basis。

- [ ] **Step 3: Store 使用单一 completedAnalysis**

`DemoWorkflowStore` 保存 `completedAnalysis: CompletedPlaylistAnalysis?`；`matches` 和 `preferenceProfile` 改为只读计算属性。开始任务时冻结 `MatchBasis`，将 `MatchOperationState` 作为匹配任务唯一真源，progress 更新为 `.running(processed,total)`；worker 完成后在主线程同时检查：

    task token is current
    frozen MatchBasis == currentMatchBasis
    output.matches.count == activeReviewSongs.count
    Task.isCancelled == false

全部满足后，先构造包含完整 analysis 的候选快照，通过 Task 9 的 actor generation 提交成功，再一次性发布 `completedAnalysis + .ready(basis)`；持久化失败或 superseded 时继续保留旧稳定 analysis，不能先改内存再异步保存。

同一任务迁移 `DemoWorkflowStore`、`+Import`、`+Persistence`、`+ProductClosure`、`+Recommendation`、`+DemoLaunch` 中所有对可写 `matches/preferenceProfile` 的赋值；读取方统一使用只读计算属性。v2 快照写 `completedAnalysis`，不再写 legacy match bridge。

- [ ] **Step 4: 原子实现确认原曲与采用替代**

在 SharedKit 增加受约束动作与纯转换：

    public enum MatchReviewAction: Sendable {
        case confirmOriginal(resultID: UUID, trackID: String)
        case adoptAlternative(resultID: UUID, trackID: String)
    }

    public func applying(
        _ action: MatchReviewAction,
        profiler: PreferenceProfiler
    ) throws -> CompletedPlaylistAnalysis

转换只替换命中的一个 `MatchResult`，用整份新 matches 重建 `PreferenceProfile`，`matchRevision += 1`，保持 `MatchBasis` 不变且结果总数不变。App 的 `confirmMatch/adoptAlternative` 改为异步提交候选快照，actor 成功后一次性替换 analysis；失败时原 analysis 和计数不动。Task 10 的兼容行为先清除旧 `songPlan`，Task 11 同批把所有此类失效改为 `stale(previousPlan, reason)`，并新增交叉测试保证不会长期停留在 nil 语义。

- [ ] **Step 5: 调整取消、失败、20 秒预算和导航语义**

本地分析使用独立 `MonotonicOperationDeadline(timeoutNanoseconds: 20_000_000_000)`，不与网络解析/公开搜索共用 timer。取消 -> `.cancelled`，保留整理内容，不保存部分 output；超出 20 秒或其他可重试失败 -> `.failed(message,retryable:true)`；离开整理页取消慢任务且迟到结果不跳页。用户可以用已验证歌曲继续，即使 pending/unmatched 非零。

- [ ] **Step 6: 新增进度 UI fixture 与 UI 测试**

新增 `-singreadyLargeMixedReview` 和可控慢分析 fixture。断言：

- 整理页显示“已处理 n / 总数”，n 单调增加。
- 取消后仍停留整理页，草稿数量不变。
- 完成后顶部先出现 verified/pending/unmatched 汇总，而不是自动展开全部歌曲。
- 使用测试专用短 deadline 模拟本地 20 秒超时，断言进入可重试匹配失败，不改变导入任务状态。

- [ ] **Step 7: 运行聚焦测试**

Run:

    swift test --filter SongMatcherTests
    swift test --filter PlaylistWorkflowContractTests
    swift test --filter ProductClosureTests
    rg -n 'matches\s*=|preferenceProfile\s*=' SingReadyAI/App
    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SingReadyAIUITests/SingReadyAIUITests/testLeavingReviewCancelsSlowMatchingWithoutLateNavigation

Expected: 测试 PASS；`rg` 只允许命中局部变量或 `completedAnalysis` 构造参数，不再命中 Store 字段赋值；无半份画像、无迟到导航、进度最终到 total，确认/采用后分析、画像和 revision 同时更新。

- [ ] **Step 8: 提交原子匹配**

    git add Sources/SingReadyAISharedKit/Catalog/SongMatcher.swift Sources/SingReadyAISharedKit/Workflow SingReadyAI/App Tests/SingReadyAISharedKitTests UITests/SingReadyAIUITests/SingReadyAIUITests.swift
    git commit -m "refactor: 原子发布歌单匹配分析"

### Task 11: 用 PlanBasis 原子生成、失效和重排

**Files:**
- Modify: `SingReadyAI/App/DemoWorkflowStore.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Operations.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Import.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Recommendation.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+ProductClosure.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Persistence.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+DemoLaunch.swift`
- Modify: `SingReadyAI/App/RootTabView.swift`
- Modify: `SingReadyAI/App/Services/SongFeedbackLocalStore.swift`
- Modify: `SingReadyAI/Features/ProductFlow/HomeDashboardView.swift`
- Modify: `SingReadyAI/Features/ProductFlow/ResultExportStartTipsViews.swift`
- Modify: `SingReadyAI/Features/ProductFlow/ExportStartTipsViews.swift`
- Modify: `Sources/SingReadyAISharedKit/Workflow/PlaylistWorkflowContracts.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/PlaylistWorkflowContractTests.swift`
- Modify: `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`

- [ ] **Step 1: 写 basis 变化和数量失败不发布红灯**

覆盖生成期间改变场景、音区、反馈、锁定/移除、曲库 revision；旧任务即使完成也不得覆盖。模拟 engine 抛 `countMismatch`：无旧计划时进入 failed 且没有 ready；有旧计划时 `failed.previous` 保留同一 stale 快照，可查看但不可导出/分享。

- [ ] **Step 2: 运行 workflow 测试，确认当前同步赋值红灯**

Run: `swift test --filter PlaylistWorkflowContractTests && swift test --filter ProductClosureTests`
Expected: FAIL；当前 `generatePlan` 同步设置 `songPlan`，没有 basis 或发布校验。

- [ ] **Step 3: 构造稳定 PlanBasis 并在后台生成**

`generatePlan` 冻结当前 `PlanBasis` 和完整 `SongPlanGenerationContext`。若当前有 ready/stale/`generating.previous`/`failed.previous`，先构造 `StalePlanSnapshot`，再设置 `.generating(basis: basis, previous: previous)`，在非 MainActor 执行 engine。context 必须写入 playlistID/title、导入/有效/待确认/未找到计数、scenario、peopleCount、durationMinutes、voiceSource、feedbackCount；不能使用 Task 5 的临时可变读取结果。完成后只在 basis/token 仍当前且 `generationSummary` 守恒时继续提交。

先构造含新 ready plan+basis 的候选快照并通过 persistence actor 线性提交，成功后才发布 `.ready(plan,basis)`；保存失败、superseded 或 basis 变化时不发布。外部 E 不进入 context、不进入 `PlanBasis`，只供独立候选卡读取。

生成失败时设置 `.failed(message:retryable:previous:)`；previous 原样保留。v2 快照把 generating/failed 的 previous 编码为 `PersistedPlanRecord.stale`，因此冷启动仍可查看上一份计划但 ready 导出门关闭。

- [ ] **Step 4: 将确认、采用和所有上游变化统一转 stale**

Task 10 的 analysis 转换提交成功后，若已有可见计划，立刻变为 `.stale(StalePlanSnapshot(plan: oldPlan, previousBasis: oldBasis, reason: "歌曲确认已更新"))`；场景、音区、反馈、锁定/移除同理。stale 保留查看能力，但 ready 导出门立即关闭；开始重排后进入 carrying previous 的 generating。补交叉测试证明 `identityConfirmationRequired -> adoptedAlternative` 与“已确认原曲 -> adoptedAlternative”都会重建画像、递增 match revision、让旧计划 stale，且迟到重排不能覆盖。

- [ ] **Step 5: 修订反馈和歌曲控制记录**

`SongFeedbackLocalStore` 改存：

    struct SongFeedbackRecord: Codable {
        var revision: UInt64
        var profile: SongFeedbackProfile
    }

兼容旧裸 profile 并迁移 revision=0。锁定/移除共享 `trackControlsRevision`。反馈或控制变化先把 ready 计划标 stale，再启动一次新 basis 重排；旧重排结果无法覆盖更新后的选择。

- [ ] **Step 6: 删除旧可写真源并收紧 ready 门**

同一任务迁移 `DemoWorkflowStore.swift`、`+Import`、`+Operations`、`+Persistence`、`+Recommendation`、`+ProductClosure`、`+DemoLaunch` 中所有 `songPlan =` 和 `isWorking =`，并同批迁移 `RootTabView`、`HomeDashboardView`、`ResultExportStartTipsViews`、`ExportStartTipsViews` 的 `store.songPlan` 读取。最终只保留：

    var visibleSongPlan: SongPlan? {
        switch planGenerationState {
        case let .ready(plan, _): return plan
        case let .stale(snapshot): return snapshot.plan
        case let .generating(_, previous), let .failed(_, _, previous):
            return previous?.plan
        default: return nil
        }
    }

    var readySongPlan: SongPlan? {
        guard case let .ready(plan, basis) = planGenerationState,
              basis == currentPlanBasis else { return nil }
        return plan
    }

`isWorking` 若为兼容 UI 所需，只能是 import/match/plan 显式状态的只读计算属性；`statusMessage` 只做文案，不参与提交判断。

Store 的三个导出方法保持现有 `String` 返回类型并通过 `readySongPlan` 守门；`exportedText/exportedShareText` 使用：

    guard let plan = readySongPlan else {
        return "歌单还没按最新选择更新，请先重新排一版。"
    }

JSON 不可用时仍返回现有安全值 `"{}"`，同时由 `readyPlanUnavailableMessage` 提供页面提示。跳转 export/startTips 和按钮 enabled 状态使用 `canUseReadyPlan = (readySongPlan != nil)`；不得只判断 visible plan 非空，也不引入未定义的泛型 availability 返回类型。

- [ ] **Step 7: 运行重排、恢复和 UI 失效测试**

Run:

    swift test --filter ProductClosureTests
    swift test --filter PlaylistWorkflowContractTests
    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SingReadyAIUITests/SingReadyAIUITests/testChangingScenarioInvalidatesOldPlanUntilRegenerated -only-testing:SingReadyAIUITests/SingReadyAIUITests/testChangingVoiceMeasurementInvalidatesOldPlanUntilRegenerated -only-testing:SingReadyAIUITests/SingReadyAIUITests/testStandaloneFeedbackTruthRefreshesStaleRestoredPlan

Expected: PASS；stale 可解释、不可分享，最新 basis 生成后恢复 ready。

- [ ] **Step 8: 运行全仓调用点检查并提交**

Run:

    rg -n 'songPlan\s*=|isWorking\s*=|store\.songPlan\b' SingReadyAI/App SingReadyAI/Features
    swift test
    xcodebuild build -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'generic/platform=iOS Simulator' -derivedDataPath Build/PlaylistImportClosure-Incremental CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

Expected: `rg` 无输出；测试 PASS；构建 `** BUILD SUCCEEDED **`。

- [ ] **Step 9: 提交原子计划生成**

    git add \
      SingReadyAI/App/DemoWorkflowStore.swift \
      SingReadyAI/App/DemoWorkflowStore+Operations.swift \
      SingReadyAI/App/DemoWorkflowStore+Import.swift \
      SingReadyAI/App/DemoWorkflowStore+Recommendation.swift \
      SingReadyAI/App/DemoWorkflowStore+ProductClosure.swift \
      SingReadyAI/App/DemoWorkflowStore+Persistence.swift \
      SingReadyAI/App/DemoWorkflowStore+DemoLaunch.swift \
      SingReadyAI/App/RootTabView.swift \
      SingReadyAI/App/Services/SongFeedbackLocalStore.swift \
      SingReadyAI/Features/ProductFlow/HomeDashboardView.swift \
      SingReadyAI/Features/ProductFlow/ResultExportStartTipsViews.swift \
      SingReadyAI/Features/ProductFlow/ExportStartTipsViews.swift \
      Sources/SingReadyAISharedKit/Workflow/PlaylistWorkflowContracts.swift \
      Tests/SingReadyAISharedKitTests/ProductClosureTests.swift \
      Tests/SingReadyAISharedKitTests/PlaylistWorkflowContractTests.swift \
      UITests/SingReadyAIUITests/SingReadyAIUITests.swift
    git commit -m "refactor: 按有效输入原子发布排歌结果"

### Task 12: 补全快照迁移、公开候选与超限写保护

**Files:**
- Modify: `Sources/SingReadyAISharedKit/Storage/WorkflowSnapshotStore.swift`
- Modify: `Sources/SingReadyAISharedKit/Models/Models.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Operations.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Import.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Persistence.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+ProductClosure.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Recommendation.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+DemoLaunch.swift`
- Modify: `SingReadyAI/Features/ProductFlow/MatchVoiceScenarioViews.swift`
- Modify: `Tests/SingReadyAISharedKitTests/StoragePrivacyHardeningTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/WorkflowPersistenceExecutorTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/AppGroupStoreTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ExternalCandidateContractTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ExternalMusicCandidateProviderTests.swift`

- [ ] **Step 1: 写 v1 迁移、v2 回环和 16MB 红灯**

测试：

- v2 round-trip 保留 revisions、completedAnalysis、ready/stale plan+basis、origin/summary、ExternalCandidateCollection。
- v1 保留导入歌单、整理草稿、场景、音区和反馈；缺 basis 的旧 matches/profile 不算 ready；旧 plan 变 stale(reason: legacyBasisMissing)，不可导出；旧 provisional tracks 丢弃。
- `ImportedSong.versionTags` 和 `WorkflowReviewSong.versionTags` 缺字段默认空，不导致整份旧 JSON 失败。
- 1000 首混合完整快照编码、原子写入、读取、解码，并且 archive `< 16 * 1_024 * 1_024` bytes。
- 先保存一份合法快照，再尝试保存编码后大于或等于 16 MB 的快照；`save` 必须抛 `WorkflowSnapshotStoreError.archiveTooLarge`，磁盘仍可读出前一份合法快照，不能写入后再等读取时 quarantine。

- [ ] **Step 2: 运行存储测试，确认 v2 壳仍缺完整迁移与写保护**

Run: `swift test --filter StoragePrivacyHardeningTests && swift test --filter AppGroupStoreTests`
Expected: FAIL；Task 8 已能分流 schema 1/2，但 `migrateShell` 尚未执行完整 basis 失效语义，`save` 也尚未在写入前拒绝超限 archive。

- [ ] **Step 3: 将 v1 壳迁移收紧为最终保守迁移**

    switch header.schemaVersion {
    case 1:
        return .loaded(migrate(try decoder.decode(ArchiveV1.self, from: data)))
    case 2:
        return .loaded(try decoder.decode(ArchiveV2.self, from: data).snapshot)
    default:
        try quarantineCurrentArchive()
        return .quarantined(.incompatibleVersion)
    }

沿用 Task 8 的 ArchiveV1/ArchiveV2 分流，将 `migrateShell` 替换为最终 `migrate`：不要把旧 schema 直接判定 incompatible；旧 matches/profile 没有 basis 时不成为 completed analysis；旧 plan 只能成为 stale；旧 external tracks 丢弃。为 `ImportedSong`、`WorkflowReviewSong`、`KTVTrack` 和新计划字段写默认值明确的自定义 decode。`save` 必须先在内存编码并检查 byte count，小于上限才执行原子替换；超限时不碰现有文件。

- [ ] **Step 4: 同批迁移所有 externalCandidateTracks 运行时引用**

将 `DemoWorkflowStore.externalCandidateTracks` 改为 `externalCandidateCollection`，并在同一任务迁移 `+Operations`、`+Import`、`+Persistence`、`+ProductClosure`、`+Recommendation`、`+DemoLaunch`、`MatchVoiceScenarioViews`、`MatchConfirmationWorkflowState` 和相关测试，禁止留下临时 KTVTrack adapter。

网络完成时同时核对 playlistID、reviewRevision、requestRevision；迟到结果拒写。移除本地 fallback，失败文案为“暂时没找到更多公开候选，可以继续按已确认歌曲排歌”。推荐调用永远只传本地 `catalog`。删除 `$externalCandidateTracks -> invalidatePlan` 观察链；collection 变化只保存快照和刷新 E 卡，不在 `PlanBasis` 中。

匹配页先做最小 raw candidate 展示（title/artist/provider/link/待核对），Task 14 再调整完整信息层级。v1 的 `externalCandidateTracks` 因缺 review basis 全部丢弃，不迁移为可用 collection。

- [ ] **Step 5: 保存最后完整提交点**

快照只编码 committed workflow：运行中的导入不替换旧快照；运行中的匹配不保存部分结果；生成中的计划保存上一个 ready/stale 计划状态。冷启动恢复到 `notStarted` 或上一个完整 `ready/stale`，绝不恢复成 running/generating。

- [ ] **Step 6: 恢复后先校验 basis 再决定首页入口**

`restoreWorkflowSnapshot` 先通过 `PlaylistWorkflowValidityPolicy` 规范化分析与计划，再设置导航提示。曲库 revision 不同则保留原始导入/整理，丢弃匹配与画像，旧计划转 stale；不能用 `hasAdvancedToScenario` 或导航 stage 冒充数据有效。

- [ ] **Step 7: 运行存储、候选和 App 构建回归**

Run:

    swift test --filter StoragePrivacyHardeningTests
    swift test --filter WorkflowPersistenceExecutorTests
    swift test --filter AppGroupStoreTests
    swift test --filter ExternalCandidateContractTests
    swift test --filter ProductClosureTests
    rg -n 'externalCandidateTracks' SingReadyAI Sources Tests
    xcodebuild build -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'generic/platform=iOS Simulator' -derivedDataPath Build/PlaylistImportClosure-Incremental CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

Expected: 测试 PASS；`rg` 只允许命中 `ArchiveV1` 解码字段和带“v1 migration”命名的 fixture；App 构建成功。未来版本仍隔离，读取损坏/超大文件仍 quarantine，写入超大快照先拒绝且旧文件不变。

- [ ] **Step 8: 提交快照与公开候选运行时迁移**

    git add Sources/SingReadyAISharedKit/Storage Sources/SingReadyAISharedKit/Models/Models.swift SingReadyAI/App SingReadyAI/Features/ProductFlow/MatchVoiceScenarioViews.swift Tests/SingReadyAISharedKitTests
    git commit -m "feat: 升级工作流快照与恢复校验"

### Task 13: 把整理页改成“默认继续、只处理异常”

**Files:**
- Modify: `SingReadyAI/Features/ProductFlow/ImportFlowViews.swift`
- Modify: `SingReadyAI/Features/ProductFlow/ImportReviewComponents.swift`
- Modify: `SingReadyAI/App/WorkflowState.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+DemoLaunch.swift`
- Modify: `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`

- [ ] **Step 1: 先写大歌单正常操作逻辑 UI 红灯**

新增 UI 测试：

- 1000 首、零异常时首屏不出现 1000 个编辑控件，主按钮可直接开始批量匹配。
- 有异常时先显示“共 N 首 · 建议看 X 首 · 缺歌名 Y 首”，默认只展开异常；“查看全部歌曲”按 20 首懒加载。
- 缺歌手不禁用主按钮；空歌名才禁用。
- 主按钮文案改为“开始批量匹配”，进度文案为“已处理 n / N 首”。

- [ ] **Step 2: 运行聚焦 UI 测试，确认当前 ForEach 全量渲染红灯**

Run:

    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SingReadyAIUITests/SingReadyAIUITests/testImportReviewAvoidsParserConfidenceCopy -only-testing:SingReadyAIUITests/SingReadyAIUITests/testImportReviewRequiresEveryActiveSongToHaveATitle -only-testing:SingReadyAIUITests/SingReadyAIUITests/testLargeReviewDefaultsToExceptionsAndBoundedRows

Expected: FAIL；当前页面对所有草稿直接 `ForEach`，按钮仍写“看看本地参考命中”。

- [ ] **Step 3: 实现摘要、异常分区和有界加载**

`ImportReviewView` 顶部先展示：

    已整理 N 首
    建议看一下 X 首
    缺少歌名 Y 首

零异常时显示“歌名都整理好了，可以直接批量匹配”；有非阻塞异常时显示“这些信息可能不完整，不处理也能继续”；空歌名显示“补上歌名后才能开始匹配”。使用 `LazyVStack` + visible count 20，只对当前展开集合创建 `SongDraftEditor`。

- [ ] **Step 4: 保留批量入口上下各一个但共享同一语义**

顶部与底部可复用同一个 `matchButton`，无论列表规模都不要求用户滚到底。工作中显示进度条、`已处理 n / N 首` 和“取消匹配”；取消后恢复“开始批量匹配”。

- [ ] **Step 5: 运行整理页 UI 回归**

Run: 使用 Step 2 命令，并追加 `-only-testing:SingReadyAIUITests/SingReadyAIUITests/testReviewDeleteCanUndoAndMeetsTouchTarget`。
Expected: PASS；删除/撤销仍可用，最大字号不截断摘要和按钮。

- [ ] **Step 6: 提交整理页批量交互**

    git add SingReadyAI/Features/ProductFlow/ImportFlowViews.swift SingReadyAI/Features/ProductFlow/ImportReviewComponents.swift SingReadyAI/App/WorkflowState.swift SingReadyAI/App/DemoWorkflowStore+DemoLaunch.swift UITests/SingReadyAIUITests/SingReadyAIUITests.swift
    git commit -m "feat: 优化大歌单批量整理交互"

### Task 14: 重做匹配完成页的结论、异常处理与主行动

**Files:**
- Modify: `SingReadyAI/Features/ProductFlow/MatchVoiceScenarioViews.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+DemoLaunch.swift`
- Modify: `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`

- [ ] **Step 1: 写“三类状态 + 一次继续”UI 红灯**

新增/改写测试断言：

- 顶部结论为“已匹配 N 首，可以直接排歌”，并展示“已确认 X / 待确认 P / 未找到 U”。
- 主操作始终是“按这份歌单排一版”，pending/unmatched 非零时也可点。
- 默认不显示“逐首核对”长列表，只展开“待确认”和“未找到”；已确认列表按需查看。
- “就是这首”只处理身份确认；“用这首替代”只处理替代建议，操作后计数立即更新。
- 身份待确认可以直接选择“用这首替代”；已确认原曲在折叠详情里也可“换一首”，两者都转为 adoptedAlternative 并触发原子重建画像。
- 数百首待确认时不要求全部处理即可继续。

- [ ] **Step 2: 运行现有 match report UI 测试，确认旧流程红灯**

Run:

    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SingReadyAIUITests/SingReadyAIUITests/testMatchReportUsesMainlandChineseLabels -only-testing:SingReadyAIUITests/SingReadyAIUITests/testMatchReportShowsPerSongStatesAndConfirmsCandidate -only-testing:SingReadyAIUITests/SingReadyAIUITests/testMatchReportShowsTrueStatusesAndAdoptsOrdinaryAlternative -only-testing:SingReadyAIUITests/SingReadyAIUITests/testMatchReportCanContinueWithoutResolvingEveryException

Expected: FAIL；当前主行动分散为测音区/去场景，并默认从第一首开始逐首展示。

- [ ] **Step 3: 用 `PlaylistPreparationSummary` 驱动顶部摘要**

Match 页首屏顺序固定为：结果结论 -> 三类计数 -> “按这份歌单排一版” -> 可选“测一下音区” -> 异常集合 -> 公开候选卡。主按钮进入场景页，并将当前 verified 集合明确作为后续排歌输入。

- [ ] **Step 4: 异常列表按 disposition 分区**

`identityConfirmationRequired` 的同身份候选显示“就是这首”，另有替代建议时同时允许“用这首替代”；`alternativeSuggested` 只显示“用这首替代”；`unmatched` 仅提示“暂时没找到，不影响继续排歌”。已确认歌曲放进折叠区，按 20 首递增加载，展开后可从 `suggestedAlternatives` 选择“换成这首”。所有按钮在 analysis 快照提交期间禁用，成功后一次更新 disposition、画像、计数和 stale 计划提示。

- [ ] **Step 5: 更新产品文案**

移除“逐首核对”“参考命中率决定是否继续”等流程语言。采用以下自然文案：

- “已确认的歌会直接参与排歌。”
- “待确认和暂时没找到的歌先放在这里，不影响继续。”
- “公开候选只供你参考，不会自动加进排歌结果。”

- [ ] **Step 6: 运行 match report 回归**

Run: Step 2 命令并追加 `testHomeResumeKeepsExplicitAdvancePastUnresolvedMatchesAfterRelaunch`。
Expected: PASS；继续意图冷启动可恢复，未确认歌曲仍不进入画像和计划。

- [ ] **Step 7: 提交匹配完成页**

    git add SingReadyAI/Features/ProductFlow/MatchVoiceScenarioViews.swift SingReadyAI/App/DemoWorkflowStore.swift SingReadyAI/App/DemoWorkflowStore+DemoLaunch.swift UITests/SingReadyAIUITests/SingReadyAIUITests.swift
    git commit -m "feat: 完善匹配结果与继续排歌闭环"

### Task 15: 在首页、场景、结果和导出解释“导入后能做什么”

**Files:**
- Modify: `SingReadyAI/Features/ProductFlow/HomeDashboardView.swift`
- Modify: `SingReadyAI/Features/ProductFlow/ScenarioBuilderViews.swift`
- Modify: `SingReadyAI/Features/ProductFlow/ResultExportStartTipsViews.swift`
- Modify: `SingReadyAI/Features/ProductFlow/ExportStartTipsViews.swift`
- Modify: `Sources/SingReadyAISharedKit/Export/Exporters.swift`
- Modify: `Sources/SingReadyAISharedKit/Recommendation/RecommendationContracts.swift`
- Modify: `Sources/SingReadyAISharedKit/Recommendation/StartTipsContentPolicy.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+DemoLaunch.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ExporterAndNormalizerTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`
- Modify: `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`

- [ ] **Step 1: 写来源计数、独立 E 卡和导出隔离红灯**

测试完整链路：

- 正式计划标题区显示“共 N 首：原歌单 X 首 · 采用替代 R 首 · 补充 Y 首”。
- 每个卡片显示唯一 origin 标签。
- 公开候选独立显示“另有 E 首公开候选待核对”，不提供锁定、移除、反馈、难度、音区或场景标签。
- 文本、分享、JSON、海报和开唱小抄均不出现公开候选歌曲。
- 旧 plan 无 summary 时只显示“这是一份历史排歌结果”，不伪造 X/R/Y。

- [ ] **Step 2: 运行 exporter 和结果页测试，确认旧 provisional 分区红灯**

Run:

    swift test --filter ExporterAndNormalizerTests
    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SingReadyAIUITests/SingReadyAIUITests/testResultShowsPlanSourceBreakdown -only-testing:SingReadyAIUITests/SingReadyAIUITests/testExternalCandidatesStayOutsidePlanAndExport

Expected: FAIL；当前海报仍展示 pending verification 分区，结果页没有 X/R/Y 和 origin。

- [ ] **Step 3: 更新首页下一步与场景输入摘要**

首页按当前显式状态只显示一个 next-best action：

- 已导入未匹配：“继续整理并批量匹配”
- 匹配完成：“按这份歌单排一版”
- 计划 stale：“按最新选择重新排歌”
- ready：“查看这份排歌”并提供次级导出入口

场景页在生成按钮前显示“将使用已确认 X 首，待确认 P 首暂不参与”，以及音区来源、人数、时长和偏好；不展示匹配百分比作为决策门槛。

- [ ] **Step 4: 更新结果页来源摘要和卡片**

`userFacingPlanSummary` 直接读取 `generationSummary`。`SongRecommendationCard` 使用 `item.origin.displayName`，不再根据 catalogSource 或 reason 猜来源。正式时间线结束后再放 `ExternalCandidateCollectionCard`，E 不计入 N。

- [ ] **Step 5: 收紧所有导出边界**

`sanitizedPlanForExport` 防御性删除 `.externalSimilar` 条目和 `.externalVerification` 分区；详细文本包含 N/X/R/Y 和逐曲来源，短分享保留场景、分段、顺序和歌名；JSON 包含 origin/summary 但不含 ExternalCandidateCollection；海报和 start tips 只使用正式 items。

- [ ] **Step 6: 更新反馈重排文案**

增加 public 纯值类型 `SongPlanChangeSummary`，显式提供 `public init(previous: SongPlan, current: SongPlan)`，用旧/新正式 plan 的 track semantic key 集合计算 `retainedCount` 与 `changedCount`，并写单元测试覆盖顺序调整、同歌重复和补充歌曲替换。反馈后显示“已按你的选择重新排好：保留 L 首，调整 C 首”；若新计划仍在生成，显示“正在按最新选择调整”，导出按钮暂不可用。不要使用“模型学习”“算法刷新”等技术语言。

- [ ] **Step 7: 运行领域与 UI 聚焦回归**

Run:

    swift test --filter ExporterAndNormalizerTests
    swift test --filter ProductClosureTests
    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SingReadyAIUITests/SingReadyAIUITests/testResultShowsPlanSourceBreakdown -only-testing:SingReadyAIUITests/SingReadyAIUITests/testCandidateSetChangeDoesNotInvalidateFormalPlan -only-testing:SingReadyAIUITests/SingReadyAIUITests/testStartTipsUsesCurrentSongPlan -only-testing:SingReadyAIUITests/SingReadyAIUITests/testExportOffersDetailedTextFileShare

Expected: PASS；修改公开候选集合只更新 E 卡，不清空正式计划。

- [ ] **Step 8: 提交价值解释与输出边界**

    git add \
      SingReadyAI/Features/ProductFlow/HomeDashboardView.swift \
      SingReadyAI/Features/ProductFlow/ScenarioBuilderViews.swift \
      SingReadyAI/Features/ProductFlow/ResultExportStartTipsViews.swift \
      SingReadyAI/Features/ProductFlow/ExportStartTipsViews.swift \
      Sources/SingReadyAISharedKit/Export/Exporters.swift \
      Sources/SingReadyAISharedKit/Recommendation/RecommendationContracts.swift \
      Sources/SingReadyAISharedKit/Recommendation/StartTipsContentPolicy.swift \
      SingReadyAI/App/DemoWorkflowStore+DemoLaunch.swift \
      Tests/SingReadyAISharedKitTests/ExporterAndNormalizerTests.swift \
      Tests/SingReadyAISharedKitTests/ProductClosureTests.swift \
      UITests/SingReadyAIUITests/SingReadyAIUITests.swift
    git commit -m "feat: 展示排歌来源并收紧导出边界"

### Task 16: 建立早期验证版核心闭环的规模、恢复、截图和真机门禁基线

本任务定义全套门禁并为 Task 1–15 生成一次基线，只用于暴露后续补充任务前的问题，不是权威最终证据。固定执行顺序为：Task 1–15 → Task 16 基线 → Task 17–22 → Task 22A 权威复跑 → Task 23 → Task 24A → Task 24B → Task 25。Task 16 所列全套门禁只有在 Task 22 完成后由 Task 22A 从头重跑并提交，才能证明早期验证版核心闭环；它仍不等同公开 To C 可发布。

**Files:**
- Modify: `Sources/SingReadyAISharedKit/Models/Models.swift`
- Modify: `Sources/SingReadyAISharedKit/Catalog/SongMatcher.swift`
- Modify: `Sources/SingReadyAISharedKit/Recommendation/RecommendationEngine.swift`
- Modify: `Sources/SingReadyAISharedKit/ExternalMusic/ExternalMusicCandidateProvider.swift`
- Modify: `Sources/SingReadyAISharedKit/Export/Exporters.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Import.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+ProductClosure.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Recommendation.swift`
- Modify: `SingReadyAI/Features/ProductFlow/MatchVoiceScenarioViews.swift`
- Modify: `SingReadyAI/Features/ProductFlow/ResultExportStartTipsViews.swift`
- Modify: `Tests/SingReadyAISharedKitTests/CatalogAndProfilerTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ExternalCandidateContractTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ExternalMusicCandidateProviderTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/PlaylistScaleContractTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/RecommendationCapacityContractTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/RecommendationEngineTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/RecommendationInteractionContractTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/SongMatcherTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/StoragePrivacyHardeningTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/VoiceMeasurementContractTests.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+DemoLaunch.swift`
- Modify: `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`
- Modify: `scripts/capture_ui_test_screenshots.sh`
- Modify: `scripts/validate_performance_budget.py`
- Modify: `scripts/validate_screenshots.py`
- Modify: `scripts/validate_docs.py`
- Modify: `docs/VISUAL_QA.md`
- Modify: `docs/QUALITY_AUDIT.md`
- Create: `docs/DEVICE_QA.md`
- Modify: `docs/screenshots/*.png`
- Modify: `docs/screenshots-large-text/*.png`

- [ ] **Step 1: 补齐 10/100/500/1000 验收矩阵**

领域测试至少覆盖：

| 规模 | 解析/整理 | 匹配状态分区 | 计划守恒 | 快照 |
|---:|---|---|---|---|
| 10 | 完成 | 完整 | N=X+R+Y | 回环 |
| 100 | 完成 | 完整 | N=X+R+Y | 回环 |
| 500 | <5s 混合分析 | 25%×4 | pending 不入计划 | <16MB |
| 1000 | <8s 混合分析 | 25%×4 | 零异常无需点击 | <16MB |

UI 测试不创建 1000 个可访问性节点，只验证有界行数、摘要计数、主按钮、取消/继续和结果来源。

另保留两个硬边界测试：本地分析到 20 秒必须取消为可重试失败；编码后达到 16 MB 的快照保存必须失败且不覆盖上一份合法文件。

- [ ] **Step 2: 补齐取消、重启和 stale 矩阵**

至少覆盖：导入中取消、匹配中取消、匹配完成前编辑、生成中改场景、生成中改反馈、曲库 revision 变化、冷启动恢复 running、旧 v1 快照、公开候选迟到完成、清除本机记录后旧任务不得复活。

- [ ] **Step 3: 删除 MatchResult 的临时旧 API 适配器**

Task 3、5、10、14、15 应已把生产读取迁到 disposition/acceptedTrack/candidateTracks/suggestedAlternatives。先运行：

    rg -n '\.(matchedTrack|alternatives|status|confirmationState)\b' SingReadyAI Sources Tests

迁移所有仍依赖旧 `MatchResult` API 的调用点，然后删除 Task 2 添加的 migration-only 旧 initializer 和四个只读适配属性。保留 `MatchResult.init(from:)` 内部的旧 CodingKeys/JSON 迁移，不保留公开旧状态面。同步删除 WorkflowSnapshot 旧 initializer/只读 bridge 的 App 调用和 ExternalCandidateTrack mapper 的运行时调用；再次运行 `swift test` 和 App 增量构建，编译器必须证明没有漏点。

- [ ] **Step 4: 运行完整 Swift 与 iOS 单元测试**

Run:

    swift test
    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SingReadyAITests SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

Expected: 全部 PASS；无新增 warning。记录实际测试数，不沿用旧报告里的固定数字。

- [ ] **Step 5: 运行完整 UI 回归**

Run: `RESULT_BUNDLE=Build/PlaylistImportClosure-FullUI.xcresult ./scripts/run_ui_tests.sh`
Expected: 源码中的 UI 测试数与 xcresult 执行数一致，failedTests=0，result=Passed。用：

    rg -c '^[[:space:]]+func test' UITests/SingReadyAIUITests/SingReadyAIUITests.swift
    xcrun xcresulttool get test-results summary --path Build/PlaylistImportClosure-FullUI.xcresult --format json

- [ ] **Step 6: 采集常规与最大辅助字号截图**

Run:

    RESULT_BUNDLE=Build/PlaylistImportClosure-Screenshots.xcresult CONTENT_SIZE=large SCREENSHOT_DIR=docs/screenshots ./scripts/capture_ui_test_screenshots.sh
    RESULT_BUNDLE=Build/PlaylistImportClosure-Screenshots-AXXXL.xcresult CONTENT_SIZE=accessibility-extra-extra-extra-large SCREENSHOT_DIR=docs/screenshots-large-text ./scripts/capture_ui_test_screenshots.sh

Expected: 首页、整理摘要、匹配结果、场景输入摘要、结果来源、独立公开候选、导出/小抄关键状态均有新截图；无截断、遮挡、横向溢出或逐首信息淹没主行动。

- [ ] **Step 7: 人工视觉核对截图**

逐张打开两套 PNG，重点检查：

- 主行动在首屏且只有一个视觉主按钮。
- 500+ 歌曲状态用摘要而非密集卡片表达。
- “待确认/未找到”明确不阻塞。
- N/X/R/Y 与 E 视觉上分区，不能误读为 E 已加入计划。
- 最大字号下计数、来源标签、按钮和错误文案完整。

发现问题时先补 UI 红灯，再做最小修正并重新采集，不直接改截图文件。

- [ ] **Step 8: 在真实 iPhone 完成系统能力验收**

使用实施时已连接并信任的设备，不硬编码历史 UDID：

    test -n "$DEVICE_UDID" || { echo "请设置已连接 iPhone 的 DEVICE_UDID"; exit 1; }
    xcodebuild build -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -configuration Release -destination "platform=iOS,id=$DEVICE_UDID" -derivedDataPath Build/PlaylistImportClosure-Device -allowProvisioningUpdates SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
    xcrun devicectl device install app --device "$DEVICE_UDID" Build/PlaylistImportClosure-Device/Build/Products/Release-iphoneos/SingReadyAIApp.app
    xcrun devicectl device process launch --device "$DEVICE_UDID" --terminate-existing com.huangwei.singreadyai

先运行可自动化的真机系统 UI 子集：

    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination "platform=iOS,id=$DEVICE_UDID" -derivedDataPath Build/PlaylistImportClosure-DeviceTests -allowProvisioningUpdates -only-testing:SingReadyAIUITests/SingReadyAIUITests/testShareExtensionReceivesSharedPlaylist -only-testing:SingReadyAIUITests/SingReadyAIUITests/testPhotoPickerCanOpenAndClose -only-testing:SingReadyAIUITests/SingReadyAIUITests/testFirstMicrophoneGrantContinuesPastPermissionRequest -only-testing:SingReadyAIUITests/SingReadyAIUITests/testShareSheetCanOpenAndClose

再按 `docs/DEVICE_QA.md` 记录设备型号、系统版本、构建 commit、时间和逐项结果，完成真实数据 smoke：

1. 从“备忘录”或音乐 App 分享一段真实歌单文本/链接到分享扩展，确认 App 打开整理页且数量正确。
2. 从“照片”选择一张真实歌单截图，确认 OCR 结果可整理；不宣称截图入口支持数百首。
3. 粘贴一份至少 100 首的混合歌单，确认无需逐首操作即可完成匹配并看到“按这份歌单排一版”。
4. 授予麦克风权限，完成一次真实音区测量并回到场景/结果。
5. 生成 ready 计划，打开系统分享面板，确认详细文本、海报或分享文本只含正式歌曲。
6. 重新执行上面的 `xcrun devicectl device process launch --device "$DEVICE_UDID" --terminate-existing com.huangwei.singreadyai` 重启 App，确认回到最后完整工作流，N/X/R/Y 与修改前一致，stale/ready 导出门正确。

Expected: 自动化子集 PASS，六项真实数据 smoke 全部记录为 PASS；任何系统权限或设备问题必须留原始日志并重新验证，不能用 generic device build 替代。

- [ ] **Step 9: 更新事实型验证文档和脚本门禁**

`validate_performance_budget.py` 固化 500/1000 阈值来源；`validate_screenshots.py` 检查新关键状态；`validate_docs.py` 从测试源码/xcresult/截图 metadata 读取事实。更新 `VISUAL_QA.md` 和 `QUALITY_AUDIT.md`，只写本轮实际命令、结果、产物路径与已知边界。

- [ ] **Step 10: 运行基线交付门禁**

Run:

    git diff --check
    ./scripts/validate.sh

Expected: `git diff --check` 无输出；`validate.sh passed.`。若全量 UI 或第三方在线 smoke 因环境失败，保留日志并区分代码回归与环境问题，不把可选在线 smoke 伪报为通过。

- [ ] **Step 11: 提交基线验收证据**

    git add \
      Sources/SingReadyAISharedKit/Models/Models.swift \
      Sources/SingReadyAISharedKit/Catalog/SongMatcher.swift \
      Sources/SingReadyAISharedKit/Recommendation/RecommendationEngine.swift \
      Sources/SingReadyAISharedKit/ExternalMusic/ExternalMusicCandidateProvider.swift \
      Sources/SingReadyAISharedKit/Export/Exporters.swift \
      SingReadyAI/App/DemoWorkflowStore.swift \
      SingReadyAI/App/DemoWorkflowStore+Import.swift \
      SingReadyAI/App/DemoWorkflowStore+ProductClosure.swift \
      SingReadyAI/App/DemoWorkflowStore+Recommendation.swift \
      SingReadyAI/App/DemoWorkflowStore+DemoLaunch.swift \
      SingReadyAI/Features/ProductFlow/MatchVoiceScenarioViews.swift \
      SingReadyAI/Features/ProductFlow/ResultExportStartTipsViews.swift \
      Tests/SingReadyAISharedKitTests/CatalogAndProfilerTests.swift \
      Tests/SingReadyAISharedKitTests/ExternalCandidateContractTests.swift \
      Tests/SingReadyAISharedKitTests/ExternalMusicCandidateProviderTests.swift \
      Tests/SingReadyAISharedKitTests/ProductClosureTests.swift \
      Tests/SingReadyAISharedKitTests/PlaylistScaleContractTests.swift \
      Tests/SingReadyAISharedKitTests/RecommendationCapacityContractTests.swift \
      Tests/SingReadyAISharedKitTests/RecommendationEngineTests.swift \
      Tests/SingReadyAISharedKitTests/RecommendationInteractionContractTests.swift \
      Tests/SingReadyAISharedKitTests/SongMatcherTests.swift \
      Tests/SingReadyAISharedKitTests/StoragePrivacyHardeningTests.swift \
      Tests/SingReadyAISharedKitTests/VoiceMeasurementContractTests.swift \
      UITests/SingReadyAIUITests/SingReadyAIUITests.swift \
      scripts/capture_ui_test_screenshots.sh \
      scripts/validate_performance_budget.py \
      scripts/validate_screenshots.py \
      scripts/validate_docs.py \
      docs/VISUAL_QA.md \
      docs/QUALITY_AUDIT.md \
      docs/DEVICE_QA.md \
      docs/screenshots \
      docs/screenshots-large-text
    git commit -m "test: 补齐歌单导入闭环验收"

### Task 17: 建立完整导入去向对账

**优先级与门禁：** P0，早期验证版当前必做。

**Files:**
- Modify: `Sources/SingReadyAISharedKit/Models/Models.swift`
- Modify: `Sources/SingReadyAISharedKit/Storage/WorkflowSnapshotStore.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Import.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Recommendation.swift`
- Modify: `SingReadyAI/Features/ProductFlow/ImportReviewComponents.swift`
- Modify: `SingReadyAI/Features/ProductFlow/MatchVoiceScenarioViews.swift`
- Modify: `SingReadyAI/Features/ProductFlow/ResultExportStartTipsViews.swift`
- Test: `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`
- Test: `Tests/SingReadyAISharedKitTests/PlaylistScaleContractTests.swift`
- Test: `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`

- [ ] **Step 1: 写逐导入条目账本红灯测试**

计数边界固定为 parser 完成空行过滤和语义去重后的 `ImportedSong.id` 集合，而不是 OCR 原始行数或最终 track ID。为每个 stable importedSong ID 建立且只建立一个 `PlaylistReconciliationEntry`，但不再用一个 outcome 混合“匹配真相”和“本轮计划是否入选”：

```swift
public enum ReviewMatchOutcome: Codable, Equatable, Sendable {
    case reviewRemoved
    case activeAwaitingMatch
    case pending
    case unmatched
    case verifiedOriginal(trackID: String)
    case verifiedAdoptedAlternative(trackID: String)
}

public enum PlanDisposition: Codable, Equatable, Sendable {
    case notGenerated
    case selectedOriginal(planItemID: UUID, trackID: String)                 // X
    case selectedAlternative(planItemID: UUID, trackID: String)              // R
    case verifiedNotSelected(resolvedTrackID: String, reason: NotSelectedReason) // Q
}

public struct PlaylistReconciliationEntry: Codable, Equatable, Sendable {
    public let importedSongID: UUID
    public let importedPlaylistOrder: Int
    public let reviewMatchOutcome: ReviewMatchOutcome
    public let planDisposition: PlanDisposition
}
```

`PlaylistReconciliationLedger` 还持有 `supplements` 与 `dispositionPlanBasis`。所有 entries 的 `planDisposition`、完整 `supplements` 和 `dispositionPlanBasis` 共同构成一个不可拆分的 plan projection snapshot；三者不能分开写入、恢复或失效。

测试必须覆盖五个可表达阶段：

1. 导入完成：有效条目为 `.activeAwaitingMatch + .notGenerated`，整理删除为 `.reviewRemoved + .notGenerated`。
2. 匹配中：完整账本仍保持上一个稳定 `reviewMatchOutcome`，进度只在 operation state；不得逐条发布半份匹配。
3. 匹配完成未排歌：没有旧 projection 时，原曲/替代分别为 `.verifiedOriginal/.verifiedAdoptedAlternative + .notGenerated`，其余为 pending/unmatched，`supplements=[]` 且 `dispositionPlanBasis=nil`。
4. plan stale：`reviewMatchOutcome` 按新整理/匹配事实提交；旧 plan projection 若保留，必须连同所有 dispositions、supplements 和旧 basis 原样作为一个 stale snapshot 保留，导出和开唱由 plan state 禁用。
5. 重排成功：在新 plan/basis 校验通过时，一次性替换全量 `planDisposition + supplements + dispositionPlanBasis`；失败或取消保持旧 stale projection 整体不变。

两个不同导入 ID 命中同一个 semantic track 时，唯一 selected 归属固定按 `(importedPlaylistOrder, importedSongID.uuidString.lowercased())` 升序选择第一条；其余 verified 条目进入 `.verifiedNotSelected(..., reason: .semanticDuplicate(selectedImportedSongID:))`。测试要打乱 entries/matches 输入顺序 100 次，证明归属始终相同；alias 归并、版本归并、锁定歌曲和容量截断也使用同一 tie-break，不能依赖字典遍历顺序。

Y 不伪装成导入条目；使用独立 `PlaylistSupplementEntry(planItemID, trackID, origin)` 数组。账本构造输入为原始 importedSong ID 集合、entries 和 supplements，不接收任何计数字段：

```swift
let ledger = try PlaylistReconciliationLedger(
    importedSongIDs: Set(importedSongs.map(\.id)),
    entries: reconciliationEntries,
    supplements: supplementEntries,
    dispositionPlanBasis: planBasis
)
XCTAssertEqual(ledger.entry(for: importedSongs[8].id)?.reviewMatchOutcome, .pending)
XCTAssertEqual(ledger.entry(for: importedSongs[8].id)?.planDisposition, .notGenerated)
XCTAssertEqual(ledger.planSummary?.formalPlanCount, 6)
```

红灯还要覆盖：重复 importedSong ID、遗漏/额外 ID、负数或重复 playlist order、非法 outcome/disposition 组合、重复 planItemID，以及 selected/supplement planItem 集合与正式 plan.items 不同。另注入只改一个 entry disposition、只清 supplements、只换 basis 的中间状态，三者都必须被拒绝，证明 projection 不能局部混写。

- [ ] **Step 2: 运行聚焦测试，确认完整账本尚不存在**

Run:

    swift test --filter ProductClosureTests/testPlaylistReconciliation
    swift test --filter PlaylistScaleContractTests/testReconciliation

Expected: FAIL，错误明确指向 `ReviewMatchOutcome`、`PlanDisposition` 或五阶段转换合同不存在；不得把单一 outcome 或已有 `N=X+R+Y` 纯计数测试误记为通过。

- [ ] **Step 3: 实现以 stable importedSong ID 唯一的完整账本**

在 `Models.swift` 增加 `PlaylistReconciliationEntry`、`ReviewMatchOutcome`、`PlanDisposition`、`PlaylistSupplementEntry`、`PlaylistReconciliationLedger` 和可枚举的 `PlaylistReconciliationError`。entry 的唯一身份永远是 importedSong stable ID；`reviewMatchOutcome` 只由整理/匹配完整提交更新，`planDisposition` 只由成功 plan 发布更新。resolved trackID、semantic key、alias 或版本归并结果只能作为证据，不能取代导入身份。

`PlaylistReconciliationSummary` 只提供 `init(ledger:)` 或 `ledger.summary` 内部派生路径，不暴露接收计数的 public initializer。summary 从 entries/outcome/supplements 单次遍历派生，并继续满足：

```text
parsedImportedCount = entries.count
activeReviewedCount = entries.count - reviewMatchOutcome.reviewRemoved.count
activeReviewedCount = awaitingMatch.count + verified.count + pending.count + unmatched.count
verified.count = reviewMatchOutcome.verifiedOriginal.count + reviewMatchOutcome.verifiedAdoptedAlternative.count
ready/stale formalPlanCount(N) = planDisposition.selectedOriginal(X).count + selectedAlternative(R).count + supplements(Y).count
```

`PlaylistPreparationSummary` 永远从 `reviewMatchOutcome` 派生；当整个 projection 为“所有 entries `.notGenerated` + 空 supplements + nil basis”时，`planSummary` 为 `nil`，不能把“尚未排歌”显示成 X/R/Q 均为零。ready/stale 的 plan summary 从同一个 `dispositionPlanBasis` 对应的全量 dispositions/supplements 派生。快照将这三个部分作为同一 projection snapshot 编解码和提交；旧快照不能证明三者来自同一 basis 时恢复为 stale 并重新分析，不从汇总数字反造条目。

- [ ] **Step 4: 在匹配和计划原子发布点拒绝错账**

`prepareForReview` 保留 stable ID、原始顺序与身份快照。整理删除/撤销、歌名编辑或完整匹配可以原子更新 `reviewMatchOutcome`，但上游变化对已有 plan projection 只允许二选一：A）所有 dispositions、supplements 与旧 `dispositionPlanBasis` 原样保留为完整 stale snapshot；B）所有 entries 的 disposition 在一次提交中整体置为 `.notGenerated`，同时清空 supplements 并把 basis 置为 `nil`。禁止只清受影响条目、只保留部分 supplement 或让新旧 basis 混在同一 projection。

计划生成在语义去重、锁定和容量截断完成后，按固定 tie-break 计算新的 X/R/Q 与 supplements Y；只有 plan、basis、所有 entries 的新 dispositions 和 supplements 全部校验成功，才用新的 `dispositionPlanBasis` 一次替换整个 projection。

反馈、场景、音区、`planControlRemovedRecords` 和锁定等 plan controls 只增加对应 revision、把 plan 转 stale，不改 `reviewMatchOutcome`，也不提前改 projection 的任何部分。成功重排才原子替换全量 dispositions、supplements 与 basis；失败保留旧 stale projection，便于解释“上次方案”，但所有输出门继续关闭。

发布点校验：entries 的 ID/顺序与原始 imported playlist 完全一致；review outcome 与 plan disposition 组合合法；selected entry 和 supplement 的 planItemID 集合与正式 plan.items 完全相等；每个 planItemID 只出现一次；同一 semantic track 的 selected importedSong 必须等于稳定 tie-break winner。任一不一致都保留上一份 stable/stale 结果并显示可重试错误。

- [ ] **Step 5: 在三处 UI 给出同源、可展开的去向说明**

整理页显示“导入 10 · 整理时移除 2 · 继续分析 8”；匹配页显示“可用于排歌 5 · 待确认 2 · 未找到 1”；结果页显示“采用原歌 3 · 采用替代 1 · 未入选 1 · 补充 2 · 正式 6”。展开“查看导入歌曲去向”后，每条 importedSong 按 stable ID 找到账本 entry，并显示例如“采用原曲”“与另一条导入合并，未重复加入”“受 30 首容量限制未入选”“待确认”“暂未找到”。supplement 使用独立分区，不冒充导入歌曲。

500/1000 首只渲染 summary 和按需分页的 entries。UI/领域测试覆盖五阶段、整理删除、两个导入条目命中同一 track、输入顺序随机化、alias/版本归并、锁定、容量截断、projection 整体保留/整体清空、stale 重排失败/成功和恢复后重建；页面 summary 必须读取双阶段 ledger 的完整 projection，不能反向手填计数。

- [ ] **Step 6: 运行聚焦、规模与全量回归**

Run:

    swift test --filter ProductClosureTests/testPlaylistReconciliation
    swift test --filter PlaylistScaleContractTests/testReconciliation
    swift test
    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SingReadyAIUITests/SingReadyAIUITests/testImportReconciliationRemainsConsistentAfterDeleteAndRestore -only-testing:SingReadyAIUITests/SingReadyAIUITests/testResultExplainsEveryImportedSongDestination

Expected: 全部 PASS；每个 importedSong stable ID 都有稳定 reviewMatchOutcome 与当前/上次成功 planDisposition；dispositions、supplements、basis 始终作为不可拆分 projection 提交；五阶段均可表达，plan controls 不污染匹配真相，同 track 归属在随机输入、锁定和重排后仍确定；故意局部错账不覆盖 stable/stale 计划。

- [ ] **Step 7: 提交完整导入去向账本**

    git add \
      Sources/SingReadyAISharedKit/Models/Models.swift \
      Sources/SingReadyAISharedKit/Storage/WorkflowSnapshotStore.swift \
      SingReadyAI/App/DemoWorkflowStore.swift \
      SingReadyAI/App/DemoWorkflowStore+Import.swift \
      SingReadyAI/App/DemoWorkflowStore+Recommendation.swift \
      SingReadyAI/Features/ProductFlow/ImportReviewComponents.swift \
      SingReadyAI/Features/ProductFlow/MatchVoiceScenarioViews.swift \
      SingReadyAI/Features/ProductFlow/ResultExportStartTipsViews.swift \
      Tests/SingReadyAISharedKitTests/ProductClosureTests.swift \
      Tests/SingReadyAISharedKitTests/PlaylistScaleContractTests.swift \
      UITests/SingReadyAIUITests/SingReadyAIUITests.swift
    git commit -m "feat: 建立导入歌曲完整去向账本"

### Task 18: 提供反馈逐条管理并兼容“唱过”旧语义

**优先级与门禁：** P0，早期验证版当前必做。

**Files:**
- Modify: `Sources/SingReadyAISharedKit/Models/Models.swift`
- Modify: `Sources/SingReadyAISharedKit/Recommendation/RecommendationEngine.swift`
- Modify: `SingReadyAI/App/Services/SongFeedbackLocalStore.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Persistence.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+ProductClosure.swift`
- Modify: `SingReadyAI/Features/ProductFlow/ResultExportStartTipsViews.swift`
- Modify: `docs/superpowers/specs/2026-07-12-playlist-import-value-closure-design.md`
- Test: `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`
- Test: `Tests/SingReadyAISharedKitTests/RecommendationInteractionContractTests.swift`
- Test: `Tests/SingReadyAISharedKitTests/StoragePrivacyHardeningTests.swift`
- Test: `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`

- [ ] **Step 1: 写旧语义 decode/migrate、逐条管理与双失败路径红灯**

固定以下合同：旧 JSON 的 raw value `"sung"` 仍可解码；用户可见名称是“会唱”或“熟悉”；该信号仍表示跨会话熟悉度并参与当前 `+0.04` 偏好调整，不表示“今晚已经唱完”。`SongFeedbackProfile` 必须能枚举全部记录，包含稳定 trackID、歌名/歌手快照、反馈集合和更新时间；即使歌曲已被重排出当前计划，也能逐条修改或清除。

旧格式的纯 decoder 不得读取曲库或当前时间，只恢复 trackID、kinds 和确定性占位名称，`updatedAt` 保持 `nil`。另测显式 `SongFeedbackMigration.migrate(profile:catalog:now:)`：注入曲库与固定时钟后补齐 title/artist/updatedAt，返回 `didChange=true`，二次迁移必须幂等且 `didChange=false`。

```swift
func testLegacySungDecodesAsFamiliarUserMeaning() throws {
    let kind = try JSONDecoder().decode(SongFeedbackKind.self, from: Data(#""sung""#.utf8))
    XCTAssertEqual(kind, .sung)
    XCTAssertEqual(kind.displayName, "会唱")
}

func testFeedbackOutsideCurrentPlanCanStillBeRemoved() {
    var profile = fixtureProfileWithHiddenTrack()
    profile.removeFeedback(trackID: "hidden-9")
    XCTAssertNil(profile.record(for: "hidden-9"))
}
```

再写两条事务红灯：反馈持久化失败时，内存 profile、revision 和 ready plan 全部保持原值且不触发重排；反馈持久化成功但重排失败时，新反馈和 revision 必须保留，旧 plan 只能进入 `.stale(previousPlan, reason)`，导出和开唱入口禁用，并提供重试。

- [ ] **Step 2: 运行聚焦测试，确认旧模型只有字典和末次撤销**

Run:

    swift test --filter ProductClosureTests/testLegacySung
    swift test --filter RecommendationInteractionContractTests/testFeedbackOutsideCurrentPlan
    swift test --filter StoragePrivacyHardeningTests/testLegacyFeedbackDecoderRestoresPlaceholderWithoutCatalog
    swift test --filter StoragePrivacyHardeningTests/testSongFeedbackMigrationEnrichesAndPersistsOnce
    swift test --filter ProductClosureTests/testFeedbackPersistenceFailureRollsBackWithoutRevision
    swift test --filter ProductClosureTests/testRerankFailureKeepsPersistedFeedbackAndStalePlan

Expected: FAIL，原因分别为用户名称仍是“唱过”、decode 与 catalog/time 耦合、显式 migration 不存在、记录管理 API 缺失或两条失败路径没有不同的事务语义。

- [ ] **Step 3: 分离纯解码与显式反馈迁移**

增加 `SongFeedbackRecord`，由 `SongFeedbackProfile` 以 trackID 唯一索引；新写入同步保存 title、artist、按 `SongFeedbackKind.allCases` 稳定排序的 kinds 与 `updatedAt`。自定义 decoder 只兼容旧 `feedbackByTrackID` 字典并创建确定性占位记录，不访问曲库、不调用 `Date()`、不产生持久化副作用。

增加显式纯函数 `SongFeedbackMigration.migrate(profile:catalog:now:) -> SongFeedbackMigrationResult`。`DemoWorkflowStore+Persistence` 完成 decode 后注入当前 catalog 和 `DateProvider.now()` 执行一次迁移；仅 `didChange=true` 时回写新格式。分别测试 decoder、migration、幂等回写和曲库仍无法解析时保留可删除占位。继续编码 raw value `sung`，只把 `displayName` 改成“会唱”，避免旧数据断裂。

不得增加名为“本场已唱”的同义按钮。若后续实现现场队列，应使用独立的 session-scoped `performedThisSession`，不修改长期推荐偏好；该现场能力不属于本任务完成条件。

- [ ] **Step 4: 增加完整反馈管理界面和两阶段反馈提交**

在结果页反馈区增加“管理反馈”入口，按更新时间展示全部记录，可展开修改多个标签、清除单条，并保留“撤销上一次”。页面必须能管理当前计划之外的歌曲，不能只复用可见计划卡片数组。

提交顺序固定为：构造 candidate profile → 持久化 candidate → 持久化成功后发布内存 profile 并只增加一次 `feedbackRevision` → 立即把旧 ready plan 转 stale → 启动重排。无变化保存不得增加 revision。只有反馈持久化本身失败，才丢弃 candidate、保持旧 profile/revision/ready plan 并且不启动重排。

- [ ] **Step 5: 覆盖持久化、可访问性和重排验收**

UI fixture 至少准备 12 条反馈，其中第 9 条不在当前 plan。验证：打开管理页、加载更多后修改第 9 条、重启仍存在、清除后消失；“会唱”在普通和最大辅助字号下完整显示；修改只触发一次“正在按最新选择调整”。

注入重排失败时，新反馈和已递增 revision 跨重启仍存在，旧 plan 以“尚未按最新选择更新”的 `.stale` 内容查看，导出、分享和 Task 21 开唱入口都不可用，用户可重试；不得回滚为旧反馈，也不得让旧 plan 恢复 `.ready`。注入反馈存储失败时则验证完全回滚且旧 ready 能继续使用。

同步设计稿 5.8、7.5 与 11.1，明确 raw `sung` 兼容、UI“会唱/熟悉”、显式 migration 和两条失败语义。

- [ ] **Step 6: 运行聚焦与全量回归**

Run:

    swift test --filter ProductClosureTests/testLegacySung
    swift test --filter RecommendationInteractionContractTests
    swift test --filter StoragePrivacyHardeningTests/testLegacyFeedbackDecoderRestoresPlaceholderWithoutCatalog
    swift test --filter StoragePrivacyHardeningTests/testSongFeedbackMigrationEnrichesAndPersistsOnce
    swift test --filter ProductClosureTests/testFeedbackPersistenceFailureRollsBackWithoutRevision
    swift test --filter ProductClosureTests/testRerankFailureKeepsPersistedFeedbackAndStalePlan
    swift test
    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SingReadyAIUITests/SingReadyAIUITests/testFeedbackManagerEditsNinthRecordOutsideCurrentPlan -only-testing:SingReadyAIUITests/SingReadyAIUITests/testLegacySungAppearsAsFamiliar

Expected: 全部 PASS；源码和截图中不再把长期偏好显示为“唱过”，旧 `"sung"` JSON 先纯解码再显式迁移；持久化失败才回滚，重排失败则保留新反馈并严格保持 stale 禁出。

- [ ] **Step 7: 提交反馈语义与逐条管理**

    git add \
      Sources/SingReadyAISharedKit/Models/Models.swift \
      Sources/SingReadyAISharedKit/Recommendation/RecommendationEngine.swift \
      SingReadyAI/App/Services/SongFeedbackLocalStore.swift \
      SingReadyAI/App/DemoWorkflowStore.swift \
      SingReadyAI/App/DemoWorkflowStore+Persistence.swift \
      SingReadyAI/App/DemoWorkflowStore+ProductClosure.swift \
      SingReadyAI/Features/ProductFlow/ResultExportStartTipsViews.swift \
      docs/superpowers/specs/2026-07-12-playlist-import-value-closure-design.md \
      Tests/SingReadyAISharedKitTests/ProductClosureTests.swift \
      Tests/SingReadyAISharedKitTests/RecommendationInteractionContractTests.swift \
      Tests/SingReadyAISharedKitTests/StoragePrivacyHardeningTests.swift \
      UITests/SingReadyAIUITests/SingReadyAIUITests.swift
    git commit -m "feat: 支持歌曲反馈逐条管理"

### Task 19: 让全部已移除歌曲可分页管理并跨重启恢复

**优先级与门禁：** P0，早期验证版当前必做。

领域边界固定为两套互不混写的删除记录：Task 17 的 `reviewRemovedEntries` 以 importedSong stable ID 表示整理阶段删除，并参与导入去向账本；本任务的 `planControlRemovedRecords` 以正式 trackID 表示结果页“不想唱/移除”，只属于计划控制。两者不得共用集合、revision 或恢复动作。

**Files:**
- Modify: `Sources/SingReadyAISharedKit/Models/Models.swift`
- Modify: `Sources/SingReadyAISharedKit/Storage/WorkflowSnapshotStore.swift`
- Modify: `SingReadyAI/App/WorkflowState.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Persistence.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Recommendation.swift`
- Modify: `SingReadyAI/Features/ProductFlow/ResultExportStartTipsViews.swift`
- Test: `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`
- Test: `Tests/SingReadyAISharedKitTests/StoragePrivacyHardeningTests.swift`
- Test: `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`

- [ ] **Step 1: 写第 9 首跨重启恢复和未知旧记录红灯**

建立 12 首已移除 fixture，page size 固定为 8。首次只显示 8 首，点击“加载更多”后出现第 9–12 首；重启 App 后加载更多并单独恢复第 9 首，其他 11 首仍保持移除；随后“全部恢复”必须清空集合。另用一个当前曲库不存在的旧 ID 验证用户仍能看到占位记录并清除，不能形成永久不可管理的 tombstone。

同时增加纯领域测试：锁定歌曲删除被拒绝时不得消费已有 `lastRemovedTrackUndo`；成功单条恢复或全部恢复各只增加一次 `trackControlsRevision`，并只启动一次重排。结果页移除/恢复前后，Task 17 的 `reviewMatchOutcome`、`reviewRemovedEntries`、`removedDuringReviewCount` 和 `reviewRevision` 必须逐值相等；整理页删除/撤销也不得改变 `planControlRemovedRecords`。

测试必须分别截取三个时点：控制变化前、重排发布前、重排成功后。重排发布前，全量 `planDisposition + supplements + dispositionPlanBasis` 必须与变化前逐值相等，只是 plan state 转 stale；不得先把被移除/恢复条目的 disposition 单独改成 Q/X。重排成功后，整个 plan projection 一次替换为同一新 basis 下的结果，期间没有可观察的新旧混合快照；`reviewMatchOutcome` 在三个时点始终不变。

- [ ] **Step 2: 运行聚焦测试，确认当前前 8 首硬截断**

Run:

    swift test --filter ProductClosureTests/testRemovedTrackPagination
    swift test --filter StoragePrivacyHardeningTests/testNinthRemovedTrackRestoresAfterRelaunch

Expected: FAIL；当前 `removedTracksForManagement` 只返回前 8 首，且旧快照只保存 ID，无法保证未知记录有可管理文案。

- [ ] **Step 3: 用可迁移的 PlanControlRemovedRecord 取代结果页 ID 集合**

增加 `PlanControlRemovedRecord: Codable, Identifiable, Equatable, Sendable`，至少包含稳定 trackID、title、artist、semanticKeySnapshot 和 removedAt。快照新 schema 把它们只保存在 `planControlRemovedRecords`，按 removedAt/trackID 稳定排序；旧 `removedTrackIDs` 解码时只迁入这套计划控制记录，优先从曲库和外部候选补齐快照，无法补齐时创建明确的遗留占位记录。运行时以 `planControlRemovedRecords` 为唯一真源，可保留只读 `planControlRemovedTrackIDs` 计算属性服务推荐过滤，不再双写两个集合。

Task 17 的 `reviewRemovedEntries` 继续由 reconciliation ledger 持有并随 `reviewRevision` 变化；本任务的迁移、分页和恢复 API 不接受或返回 importedSong ID，防止把结果页控制误写成整理删除。

恢复语义固定为“恢复为候选歌曲”：删除 tombstone、增加一次 `trackControlsRevision`、转 stale 并重排，不承诺恢复后必然进入容量有限的正式计划。

- [ ] **Step 4: 实现有界分页和完整恢复操作**

在 `DemoWorkflowStore` 维护 `removedTrackVisibleLimit`，初值 8，每次“加载更多”增加 8；新删除或恢复后将 limit 夹在合法范围。管理卡显示“已移除 M 首”、当前页记录、单条“恢复为候选”和“全部恢复”。遗留占位记录显示“原歌曲信息暂不可用”，仍提供清除/恢复操作。最大辅助字号下按钮保持至少 44pt，分页不得一次创建 500 个节点。

- [ ] **Step 5: 验证恢复、重启、revision 和对账联动**

UI 测试必须真实执行：从结果页移除 12 首、终止并重启、加载更多、恢复第 9 首、确认 plan-control 计数从 12 变 11、全部恢复后卡片消失。每次结果页移除/恢复只能修改 `planControlRemovedRecords`、增加一次 `trackControlsRevision`、把 plan 转 stale 并触发一次重排；重排发布前完整 projection 逐值不变，成功发布后 dispositions、supplements、basis 一次整体替换。全程绝不修改 Task 17 的 `reviewMatchOutcome`、`reviewRemovedEntries`、`removedDuringReviewCount` 或 `reviewRevision`；迟到的旧重排不得重新写回已恢复 tombstone 或发布局部 projection。

- [ ] **Step 6: 运行聚焦与全量回归**

Run:

    swift test --filter ProductClosureTests/testRemovedTrackPagination
    swift test --filter StoragePrivacyHardeningTests/testNinthRemovedTrackRestoresAfterRelaunch
    swift test
    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SingReadyAIUITests/SingReadyAIUITests/testNinthRemovedTrackCanRestoreAfterRelaunch -only-testing:SingReadyAIUITests/SingReadyAIUITests/testRestoreAllRemovedTracksClearsEveryPage

Expected: 全部 PASS；第 9 首可跨重启单独恢复，未知旧记录可清除，恢复操作不会重复增加 revision 或发布迟到计划；重排前 projection 整体不变、成功后整体原子替换且 review outcomes 不变；两套删除记录在全部测试中互不变化。

- [ ] **Step 7: 提交已移除歌曲完整恢复**

    git add \
      Sources/SingReadyAISharedKit/Models/Models.swift \
      Sources/SingReadyAISharedKit/Storage/WorkflowSnapshotStore.swift \
      SingReadyAI/App/WorkflowState.swift \
      SingReadyAI/App/DemoWorkflowStore.swift \
      SingReadyAI/App/DemoWorkflowStore+Persistence.swift \
      SingReadyAI/App/DemoWorkflowStore+Recommendation.swift \
      SingReadyAI/Features/ProductFlow/ResultExportStartTipsViews.swift \
      Tests/SingReadyAISharedKitTests/ProductClosureTests.swift \
      Tests/SingReadyAISharedKitTests/StoragePrivacyHardeningTests.swift \
      UITests/SingReadyAIUITests/SingReadyAIUITests.swift
    git commit -m "feat: 支持已移除歌曲完整恢复"

### Task 20: 为 SongPlan 增加可信更新时间

**优先级与门禁：** P1，早期验证版当前必做。

**Files:**
- Modify: `Sources/SingReadyAISharedKit/Models/Models.swift`
- Modify: `Sources/SingReadyAISharedKit/Storage/WorkflowSnapshotStore.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Recommendation.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Persistence.swift`
- Modify: `SingReadyAI/Features/ProductFlow/ResultExportStartTipsViews.swift`
- Test: `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`
- Test: `Tests/SingReadyAISharedKitTests/StoragePrivacyHardeningTests.swift`
- Test: `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`

- [ ] **Step 1: 写 createdAt/updatedAt 迁移和发布时序红灯**

测试固定两个时间点 `t0`、`t1`：首次生成时 `createdAt == updatedAt == t0`；反馈、锁定、移除或场景改变后成功发布新 ready plan 时 `createdAt == t0` 且 `updatedAt == t1`；请求刚开始、失败、取消、超时或迟到结果被拒绝时，两者都保持上一份稳定值。删除旧 JSON 的 `updatedAt` 后解码，要求 `updatedAt == createdAt`。

```swift
XCTAssertEqual(initial.createdAt, t0)
XCTAssertEqual(initial.updatedAt, t0)
XCTAssertEqual(reranked.createdAt, t0)
XCTAssertEqual(reranked.updatedAt, t1)
```

- [ ] **Step 2: 运行聚焦测试，确认 SongPlan 只有 createdAt**

Run:

    swift test --filter ProductClosureTests/testSongPlanUpdatedAt
    swift test --filter StoragePrivacyHardeningTests/testLegacySongPlanDefaultsUpdatedAtToCreatedAt

Expected: FAIL，`SongPlan.updatedAt` 不存在，或当前 `preservingIdentity` 只保留旧 createdAt 而无法表达本次成功重排时间。

- [ ] **Step 3: 增加向后兼容的时间模型**

为 `SongPlan` 增加 `updatedAt`，initializer 默认使用传入的 `createdAt`，自定义 decoder 用 `decodeIfPresent(updatedAt) ?? createdAt`。所有 `sanitizedForTrustBoundaries`、快照迁移和复制构造必须同时保留两个时间。不得在解码旧记录时调用新的 `Date()` 伪造更新时间。

`DemoWorkflowStore` 注入已有 `DateProvider`，默认 `.init()`，测试传固定时钟；不在 View 内读取当前时间决定领域状态。

- [ ] **Step 4: 只在成功原子发布 ready 计划时推进 updatedAt**

首次成功计划用同一个 `now` 设置 createdAt/updatedAt。后续重排在最终 generation 与 basis 仍有效、数量守恒且快照提交成功后，才保留旧 createdAt 并把 updatedAt 设为本次 `now`。loading、stale、failure、cancelled 和被 generation gate 拒绝的结果不得改时间。相同 basis 的无变化重复请求不得制造虚假“刚刚更新”。

- [ ] **Step 5: 在结果页显示可解释的更新时间**

ready 状态显示“更新于 <本地短时间>”；若 createdAt 与 updatedAt 不同，可在辅助信息中显示“创建于 <时间>”。stale 状态固定显示“上次更新于……，尚未按最新选择更新”，同时保持导出禁用。普通和最大辅助字号下时间文案不得截断，也不得每秒刷新造成无意义重绘。

- [ ] **Step 6: 运行聚焦、持久化与全量回归**

Run:

    swift test --filter ProductClosureTests/testSongPlanUpdatedAt
    swift test --filter StoragePrivacyHardeningTests/testLegacySongPlanDefaultsUpdatedAtToCreatedAt
    swift test
    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SingReadyAIUITests/SingReadyAIUITests/testResultShowsLastSuccessfulPlanUpdateTime -only-testing:SingReadyAIUITests/SingReadyAIUITests/testStalePlanDoesNotClaimItWasJustUpdated

Expected: 全部 PASS；失败、取消和迟到请求不推进 updatedAt，旧快照稳定解码，大字号文案完整。

- [ ] **Step 7: 提交可信方案更新时间**

    git add \
      Sources/SingReadyAISharedKit/Models/Models.swift \
      Sources/SingReadyAISharedKit/Storage/WorkflowSnapshotStore.swift \
      SingReadyAI/App/DemoWorkflowStore.swift \
      SingReadyAI/App/DemoWorkflowStore+Recommendation.swift \
      SingReadyAI/App/DemoWorkflowStore+Persistence.swift \
      SingReadyAI/Features/ProductFlow/ResultExportStartTipsViews.swift \
      Tests/SingReadyAISharedKitTests/ProductClosureTests.swift \
      Tests/SingReadyAISharedKitTests/StoragePrivacyHardeningTests.swift \
      UITests/SingReadyAIUITests/SingReadyAIUITests.swift
    git commit -m "feat: 记录歌单方案更新时间"

### Task 21: 从结果页一跳进入开唱模式

**优先级与门禁：** P1，早期验证版当前必做。

**Files:**
- Modify: `SingReadyAI/App/WorkflowState.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+ProductClosure.swift`
- Modify: `SingReadyAI/Features/ProductFlow/ResultExportStartTipsViews.swift`
- Modify: `SingReadyAI/Features/ProductFlow/ExportStartTipsViews.swift`
- Modify: `Sources/SingReadyAISharedKit/Recommendation/StartTipsContentPolicy.swift`
- Modify: `docs/superpowers/specs/2026-07-12-playlist-import-value-closure-design.md`
- Test: `Tests/SingReadyAISharedKitTests/StartTipsContentPolicyTests.swift`
- Test: `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`
- Test: `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`

- [ ] **Step 1: 写 ready/stale/单人场景的一跳入口红灯**

UI 合同固定为：ready 的多人结果页首屏有唯一主行动“进入开唱模式”，单人练歌为“开始练唱”；点击一次直接到 `.startTips`，页面能看到正式计划的开场、下一首和收尾歌曲。stale 或无 plan 时不允许展示可误导的开唱入口，而显示“重新排歌”并回到场景页。外部候选 E 不能出现在开唱顺序。

领域测试让 `StartTipsContentPolicy` 接收含 X/R/Y/E fixture，断言 selection 只来自正式 sections.items，并按计划顺序选择 opening/chorus/closing。

- [ ] **Step 2: 运行聚焦测试，确认结果页目前需要绕行**

Run:

    swift test --filter StartTipsContentPolicyTests/testStartModeUsesOnlyFormalPlanItems
    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SingReadyAIUITests/SingReadyAIUITests/testReadyResultEntersStartModeInOneTap

Expected: FAIL；当前结果页只有“调整场景”和“发给朋友/保存练唱单”，没有一跳主行动。

- [ ] **Step 3: 集中定义开唱入口 policy**

在 Store 提供只读 `startModeAction`：只有 plan state 为 `.ready`、basis 当前有效、正式 items 非空时返回 `.enter(title:)`；soloPractice 标题为“开始练唱”，其他场景为“进入开唱模式”；其余状态返回 `.regenerate`。View 不自行组合 `songPlan != nil` 和 stale 标志，避免恢复瞬间误放行。

`.startTips` 仍是顺序和现场提示页，不增加音频播放、第三方点歌或 KTV 设备控制。所有文案禁止使用“一键播放”“一键点歌”等当前能力无法兑现的承诺。

- [ ] **Step 4: 把主行动放到结果首屏并保持一跳**

将主按钮放在 HeroHeader 后、次要按钮前；ready 时调用一次 `setStage(.startTips)`，不得先跳 export。start tips 首屏显示“先唱”“下一首”“收尾”及当前正式歌曲名，保留返回结果和分享入口。若点击前 basis 已变化，Store 在导航提交点再次检查并转到 scenario，不能展示过期顺序。

- [ ] **Step 5: 覆盖大字号、恢复和外部候选隔离**

UI 测试覆盖多人 ready、soloPractice、stale、冷启动恢复 ready、点击前失效和含 E 候选六种状态；普通与最大辅助字号下主按钮完整且至少 44pt。测试只点击一次并立即断言 `.startTips` 标题和首首歌曲，防止把“两步可到达”误当一跳通过。

同步设计稿 5.7、5.9 与 11.1，把 ready 结果页第一主行动固定为“进入开唱模式/开始练唱”，明确它只进入正式计划顺序和小抄，不代表播放器、KTV 点歌或设备控制。

- [ ] **Step 6: 运行聚焦与全量回归**

Run:

    swift test --filter StartTipsContentPolicyTests
    swift test --filter ProductClosureTests/testStartModeAction
    swift test
    python3 scripts/validate_docs.py
    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SingReadyAIUITests/SingReadyAIUITests/testReadyResultEntersStartModeInOneTap -only-testing:SingReadyAIUITests/SingReadyAIUITests/testSoloResultStartsPracticeInOneTap -only-testing:SingReadyAIUITests/SingReadyAIUITests/testStaleResultRequiresRegenerationBeforeStartMode

Expected: 全部 PASS；ready 一跳到达，stale 不放行，E 不进入小抄，没有出现播放或设备控制承诺。

- [ ] **Step 7: 提交结果页开唱入口**

    git add \
      SingReadyAI/App/WorkflowState.swift \
      SingReadyAI/App/DemoWorkflowStore+ProductClosure.swift \
      SingReadyAI/Features/ProductFlow/ResultExportStartTipsViews.swift \
      SingReadyAI/Features/ProductFlow/ExportStartTipsViews.swift \
      Sources/SingReadyAISharedKit/Recommendation/StartTipsContentPolicy.swift \
      docs/superpowers/specs/2026-07-12-playlist-import-value-closure-design.md \
      Tests/SingReadyAISharedKitTests/StartTipsContentPolicyTests.swift \
      Tests/SingReadyAISharedKitTests/ProductClosureTests.swift \
      UITests/SingReadyAIUITests/SingReadyAIUITests.swift
    git commit -m "feat: 增加结果页开唱入口"

### Task 22: 支持多截图批量导入并原子发布

**优先级与门禁：** P1，早期验证版当前必做，公开 To C 发布也强制通过。本轮已选择“全部按建议”实施，不存在收窄为单张截图后延期的完成分支。

**Files:**
- Create: `Sources/SingReadyAISharedKit/ImportPipeline/ScreenshotBatchImporter.swift`
- Modify: `Sources/SingReadyAISharedKit/ImportPipeline/OCRService.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Import.swift`
- Modify: `SingReadyAI/Features/ProductFlow/ImportFlowViews.swift`
- Modify: `docs/superpowers/specs/2026-07-12-playlist-import-value-closure-design.md`
- Create: `Tests/SingReadyAISharedKitTests/ScreenshotBatchImporterTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`
- Modify: `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`
- Modify: `docs/DEVICE_QA.md`

- [ ] **Step 1: 写稳定合并、部分失败、取消和迟到发布红灯**

用 fake OCR 输入三张图：第 1 张识别 A/B，第 2 张识别 B/C，第 3 张识别 D。要求输出顺序 A/B/C/D，B 以首次出现为准，并记录每首来自第几张。另覆盖第 2 张失败时明确返回“识别 2/3 张”、全部失败不替换旧工作流、用户取消保留旧工作流、旧 batch 晚到不能覆盖新 batch。

```swift
let result = try await importer.importBatch([image1, image2, image3])
XCTAssertEqual(result.songs.map(\.title), ["A", "B", "C", "D"])
XCTAssertEqual(result.succeededImageCount, 3)
XCTAssertEqual(result.failedImages, [])
```

新增精确默认合同：

```swift
public struct ScreenshotBatchImportLimits: Equatable, Sendable {
    public var maxImageCount = 20
    public var maximumTotalBytes = 120 * 1024 * 1024       // 120 MiB
    public var maximumTotalPixels = 160_000_000
    public var maximumConcurrency = 2
}
```

字节总和、单图 `width * height` 和像素总和都用 `reportingOverflow`；任一溢出按 `.arithmeticOverflow` 在 OCR 前拒绝。红灯覆盖：20 张、每张 6 MiB 且 8,000,000 像素的最坏边界恰好通过；总字节多 1 byte、总像素多 1 pixel、21 张、单图尺寸乘法溢出和累计溢出分别失败，且不部分发布。

部分失败还要用 fake temporary-file store 与注入时钟测试页面级 `ScreenshotBatchRetrySession`：成功图片立即删除；失败图片最多保留 15 分钟，重试成功、用户放弃、离开导入页或期限到达时全部删除。session 不进入快照；进程重启后只恢复失败数/序号和“重新选择失败图片”，不得承诺直接重试旧文件。

- [ ] **Step 2: 运行聚焦测试，确认当前 PhotosPicker 为单选**

Run:

    swift test --filter ScreenshotBatchImporterTests
    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SingReadyAIUITests/SingReadyAIUITests/testScreenshotPickerSupportsMultipleSelection

Expected: FAIL；batch importer 不存在，`ImportFlowViews` 当前只有单个 `PhotosPickerItem?`。

- [ ] **Step 3: 实现有界、稳定、可取消的批量管线**

`ScreenshotBatchImporter` 接收已落入受控临时目录的 Sendable 输入，不让 `PhotosPickerItem` 穿过 actor 边界。所有数量、字节、像素和并发限制只读取 `ScreenshotBatchImportLimits`；先用 overflow-safe 累加完成全批 preflight，再按 selectionIndex 稳定排序、最多并发 2 个执行 OCR。每张复用 `OCRServicing` 和现有 parser，最终按标准 semantic key 保留首次出现。结果包含 total/succeeded/failed、逐图错误和稳定歌曲数组。

View 将 PhotosPicker 改为 `[PhotosPickerItem]`，逐个准备临时文件并显示“正在识别 i/n”。Store 使用独立 generation token；只有当前 batch 完成且至少一张成功、合并结果非空并通过导入校验时，才一次性替换 review candidate 并持久化。取消、全失败、超限、超时或迟到结果保持上一份完整工作流。

- [ ] **Step 4: 用有期限的页面 retry session 管理失败临时文件**

部分成功时，当前导入页显示“已识别 m/n 张”、失败序号、“重试失败图片”和“使用已识别结果继续”。`ScreenshotBatchRetrySession` 只持有失败图片的临时 URL、selectionIndex、创建/到期时间和 session token，TTL 固定 15 分钟；不持有成功图片，也不写入 workflow snapshot。

重试中只访问当前 session 且未过期的文件：某张重试成功立即删除该文件；全部成功、用户点击“使用已识别结果继续”（等同放弃剩余重试）、取消/放弃、离开导入页或到期时，清理全部剩余文件并关闭 session。App 被终止时 orphan cleaner 删除遗留文件；重启只显示“上次有 K 张未识别，请重新选择失败图片”，没有“继续重试”按钮。清理失败要记录可重试诊断，但不得把 URL 持久化。

- [ ] **Step 5: 增加 UI 与真实三图 smoke**

UI fixture 验证多选入口、i/n 进度、取消、部分失败、15 分钟内重试、到期、放弃、离页、重启后重新选择提示、稳定去重、批次晚到以及 500 首合并后有界节点。`docs/DEVICE_QA.md` 增加真机步骤：从照片一次选择 3 张真实歌单截图，其中两张含重合歌曲；确认成功数、失败明细、首次顺序和去重结果，并在重启后只恢复合并后的文本歌曲和“重新选择失败图片”提示，不恢复原图或 retry session。

同步设计稿 5.2、7.5、8.1 与 11，写入四个精确默认 limit、overflow-safe preflight、15 分钟页面 retry session、清理/重启语义、批次原子发布，以及多截图为早期闭环和公开发布共同门禁。

- [ ] **Step 6: 运行聚焦、全量和真机门禁**

Run:

    swift test --filter ScreenshotBatchImporterTests
    swift test --filter ProductClosureTests/testScreenshotBatch
    swift test
    python3 scripts/validate_docs.py
    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SingReadyAIUITests/SingReadyAIUITests/testScreenshotPickerSupportsMultipleSelection -only-testing:SingReadyAIUITests/SingReadyAIUITests/testScreenshotBatchPartialFailureIsVisible -only-testing:SingReadyAIUITests/SingReadyAIUITests/testCancelledScreenshotBatchKeepsStableWorkflow

真机再按更新后的 `docs/DEVICE_QA.md` 执行三图 smoke。Expected: 自动化全部 PASS；等于四项边界通过、+1/overflow 被拒绝；失败文件在成功/放弃/离页/到期清理；重启不出现直接重试旧文件。真机记录 3 张选择、实际合并计数和去重样例；系统 picker 或照片权限阻塞只能记为外部环境未通过。

- [ ] **Step 7: 提交多截图批量导入**

    git add \
      Sources/SingReadyAISharedKit/ImportPipeline/ScreenshotBatchImporter.swift \
      Sources/SingReadyAISharedKit/ImportPipeline/OCRService.swift \
      SingReadyAI/App/DemoWorkflowStore.swift \
      SingReadyAI/App/DemoWorkflowStore+Import.swift \
      SingReadyAI/Features/ProductFlow/ImportFlowViews.swift \
      docs/superpowers/specs/2026-07-12-playlist-import-value-closure-design.md \
      Tests/SingReadyAISharedKitTests/ScreenshotBatchImporterTests.swift \
      Tests/SingReadyAISharedKitTests/ProductClosureTests.swift \
      UITests/SingReadyAIUITests/SingReadyAIUITests.swift \
      docs/DEVICE_QA.md
    git commit -m "feat: 支持多截图批量导入"

### Task 22A: 在多截图与全部补充合同后重跑早期验证版权威门禁

**执行顺序与门禁：** 必须在 Task 17–22 全部提交后执行。Task 16 的旧结果只能作为基线；本任务从零重跑 Task 16 全套步骤，产出的提交和 SHA 才是早期验证版核心闭环的权威证据。

**Files:**
- Modify: `docs/VISUAL_QA.md`
- Modify: `docs/QUALITY_AUDIT.md`
- Modify: `docs/DEVICE_QA.md`
- Modify: `docs/screenshots/*.png`
- Modify: `docs/screenshots-large-text/*.png`

- [ ] **Step 1: 确认补充任务已提交且门禁从干净状态开始**

Run:

    test -z "$(git status --porcelain --untracked-files=all)"
    git log --oneline --grep='建立导入歌曲完整去向账本' -1
    git log --oneline --grep='支持歌曲反馈逐条管理' -1
    git log --oneline --grep='支持已移除歌曲完整恢复' -1
    git log --oneline --grep='记录歌单方案更新时间' -1
    git log --oneline --grep='增加结果页开唱入口' -1
    git log --oneline --grep='支持多截图批量导入' -1

Expected: 工作树干净，六个补充提交全部存在；不得复用 Task 16 之前的 xcresult、截图或真机记录。

- [ ] **Step 2: 从零重跑 Task 16 的领域、iOS 与完整 UI 门禁**

删除或移出旧 `Build/PlaylistImportClosure-*` 产物后，逐项执行 Task 16 Step 1–5；同时运行 Task 17–22 的全部聚焦测试。Expected: Swift、iOS 单测和完整 UI 均 PASS，实际测试数与 xcresult 一致，逐条导入账本、反馈失败语义、第 9 首恢复、updatedAt、一跳开唱和多截图均在本轮证据中出现。

- [ ] **Step 3: 重采两套跟踪截图并完成真机验收**

按 Task 16 Step 6–8 重新生成 `docs/screenshots` 与 `docs/screenshots-large-text`，人工逐张检查；真机必须包含 3 张截图批量选择、部分失败说明、结果页一跳开唱，以及重启后第 9 首计划控制恢复。更新三份 QA 文档，只写本轮命令、设备、系统、commit 和真实结果。

- [ ] **Step 4: 运行权威早期闭环门禁**

Run:

    git diff --check
    ./scripts/validate.sh

Expected: `git diff --check` 无输出，`validate.sh passed.`；Task 17–22 的所有门禁与新截图 fingerprint 均来自当前源码。任何失败都阻止本任务提交和早期闭环结论。

- [ ] **Step 5: 提交权威早期验证版证据**

    git add docs/VISUAL_QA.md docs/QUALITY_AUDIT.md docs/DEVICE_QA.md docs/screenshots docs/screenshots-large-text
    git commit -m "test: 更新早期验证版最终证据"
    test -z "$(git status --porcelain --untracked-files=all)"
    git rev-parse HEAD

记录输出为 `EARLY_CLOSURE_SHA`。Task 23–25 后续若修改产品代码或数据，不能继续拿该 SHA 冒充公开发布候选；公开候选仍须按 Task 25 在新冻结 SHA 上重跑非跟踪证据。

### Task 23: 建立帮助、客服与非公开隐私联系入口

**优先级与门禁：** P0-release，公开 To C 发布必做。

**Files:**
- Create: `Sources/SingReadyAISharedKit/Support/SupportLinkConfiguration.swift`
- Create: `SingReadyAI/Features/ProductFlow/HelpSupportPrivacyView.swift`
- Modify: `SingReadyAI/Features/ProductFlow/HomeDashboardView.swift`
- Modify: `PRIVACY.md`
- Modify: `project.yml`
- Modify: `SingReadyAI.xcodeproj/project.pbxproj`
- Modify: `scripts/validate_release.py`
- Modify: `scripts/test_delivery_gates.py`
- Create: `Tests/SingReadyAISharedKitTests/SupportLinkConfigurationTests.swift`
- Modify: `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`
- Modify: `docs/MANUAL_QA.md`
- Modify: `docs/QUALITY_AUDIT.md`

- [ ] **Step 1: 写入口、URL 安全和 Release 配置红灯**

测试要求首页可进入“帮助与反馈”，页面同时提供使用帮助、问题反馈/联系客服、隐私政策和隐私/删除请求。SharedKit 的 `SupportLinkConfiguration.validated(policy:)` 必须逐项覆盖：拒绝 `http`、`ftp`、`file`，拒绝 HTTPS 空 host 和未批准 host；接受 allowlist 内的合法 HTTPS；接受格式合法且收件地址获批的 `mailto`。运行时 policy 必须要求 support、privacyPolicy、privacyContact 三项齐全，Release 拒绝 example 占位、公开 GitHub Issues 和空配置。

App 层测试只能消费 SharedKit 返回的 `ValidatedSupportLinks`，不能在 View 或 App service 中再次解析原始 URL，也不能绕过 policy 直接 `URL(string:)`。

- [ ] **Step 2: 运行门禁，确认当前只有离线政策和公开 Issue**

Run:

    swift test --filter SupportLinkConfigurationTests
    python3 -m unittest scripts.test_delivery_gates.DeliveryGateTests.test_support_and_privacy_release_configuration
    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SingReadyAIUITests/SingReadyAIUITests/testHelpSupportAndPrivatePrivacyContactAreReachable

Expected: FAIL；SharedKit 配置与单测文件不存在，当前政策把问题/删除请求指向公开 Issues，且没有独立帮助/客服页面。

- [ ] **Step 3: 实现集中配置和帮助联系页面**

SharedKit 从构建层提供的字符串构造 `SupportLinkConfiguration`，使用注入的 `SupportLinkPolicy(approvedHTTPSHosts:approvedMailRecipients:requiredKinds:)` 一次性返回 `ValidatedSupportLinks` 或具名错误。测试通过 fixture 注入 policy；生产 Release 禁止回退占位值。App Store/首页只持有验证后的值，页面解释截图 OCR、音区测量、导入失败和本机数据清除，并使用系统方式打开链接。联系入口不得自动附加歌单、截图、录音或设备标识；`PRIVACY.md` 同步改为非公开渠道。运行 `xcodegen generate` 更新工程文件。

- [ ] **Step 4: 验证普通/最大字号和真实收件通路**

Run:

    swift test --filter SupportLinkConfigurationTests
    python3 -m unittest scripts.test_delivery_gates.DeliveryGateTests.test_support_and_privacy_release_configuration
    DERIVED_DATA=Build/SupportReleaseValidation
    xcodebuild build \
      -project SingReadyAI.xcodeproj \
      -scheme SingReadyAIApp \
      -configuration Release \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$DERIVED_DATA" \
      SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
    APP_BUNDLE="$DERIVED_DATA/Build/Products/Release-iphonesimulator/SingReadyAIApp.app"
    test -d "$APP_BUNDLE"
    python3 scripts/validate_release.py "$APP_BUNDLE"
    xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SingReadyAIUITests/SingReadyAIUITests/testHelpSupportAndPrivatePrivacyContactAreReachable -only-testing:SingReadyAIUITests/SingReadyAIUITests/testHelpSupportWorksAtLargestAccessibilityText
    swift test

Expected: Release generic iOS Simulator 构建生成在固定的 `Build/SupportReleaseValidation/Build/Products/Release-iphonesimulator/SingReadyAIApp.app`，校验器以该 app bundle 的位置参数运行；自动化全部 PASS，所有入口至少 44pt、文案不截断。再人工发送一条不含敏感数据的测试消息并确认私下收到；未取得实际收件证据时，本任务不得勾选完成。

- [ ] **Step 5: 提交帮助与隐私联系入口**

    git add Sources/SingReadyAISharedKit/Support/SupportLinkConfiguration.swift SingReadyAI/Features/ProductFlow/HelpSupportPrivacyView.swift SingReadyAI/Features/ProductFlow/HomeDashboardView.swift PRIVACY.md project.yml SingReadyAI.xcodeproj/project.pbxproj scripts/validate_release.py scripts/test_delivery_gates.py Tests/SingReadyAISharedKitTests/SupportLinkConfigurationTests.swift UITests/SingReadyAIUITests/SingReadyAIUITests.swift docs/MANUAL_QA.md docs/QUALITY_AUDIT.md
    git commit -m "feat: 增加帮助与隐私联系入口"

### Task 24A: 建立曲库版本、碰撞、覆盖与权利状态的机器门禁

**优先级与门禁：** P0-release，公开 To C 发布必做。本任务只交付可执行合同；当前真实资源可以继续被 release 模式明确判为 BLOCKED，不能把机器门禁实现误写成真实数据和权利已经交付。

**Files:**
- Create: `Sources/SingReadyAISharedKit/Catalog/CatalogManifest.swift`
- Create: `Sources/SingReadyAISharedKit/Resources/Catalog/catalog_manifest.json`
- Create: `Sources/SingReadyAISharedKit/Resources/Catalog/catalog_launch_coverage_cases.json`
- Modify: `Sources/SingReadyAISharedKit/Catalog/KTVCatalogRepository.swift`
- Modify: `Tests/SingReadyAISharedKitTests/CatalogAndProfilerTests.swift`
- Modify: `scripts/validate_catalog.py`
- Modify: `scripts/validate_performance_budget.py`
- Modify: `scripts/test_delivery_gates.py`
- Create: `docs/CATALOG_RELEASE_GATE.md`

- [ ] **Step 1: 写 manifest schema、摘要、碰撞和 release 状态红灯**

单元 fixture 覆盖 schema/catalog version、资源 SHA-256、维护人、审核日期、来源引用、适用范围、权利状态和 coverage case。重复 ID、语义碰撞、alias 冲突、必填演唱属性缺失、资源摘要不符、未批准权利或任一 case 不足 30 首都必须给出稳定错误码。

- [ ] **Step 2: 运行红灯并确认当前 180/215 下限不是发布证明**

Run:

    swift test --filter CatalogAndProfilerTests/testCatalogManifest
    python3 -m unittest scripts.test_delivery_gates.DeliveryGateTests.test_catalog_release_manifest

Expected: FAIL；类型和 release 合同尚不存在，不能拿当前数量校验替代来源、覆盖与权利状态。

- [ ] **Step 3: 实现 contract-only 与 release 两种机器校验**

Repository 与 Python validator 使用同一 manifest 语义。`--contract-only` 只证明解析、摘要、碰撞、错误码和测试 fixture；`--release` 还必须读取真实资源、coverage cases、负责人和 distribution-approved 权利状态。初始 manifest 明确标为 `early-validation/rights-unverified`，不得预填通过值。

- [ ] **Step 4: 验证机器合同并保留真实发布红灯**

Run:

    swift test --filter CatalogAndProfilerTests
    python3 scripts/validate_catalog.py --contract-only
    python3 scripts/validate_catalog.py --release

Expected: 前两条 PASS；第三条在 Task 24B 前必须以具名的 coverage/source/rights 缺口失败。若第三条意外 PASS，说明 fixture 或门禁伪造了外部状态，本任务不能提交。

- [ ] **Step 5: 提交曲库机器门禁**

    git add Sources/SingReadyAISharedKit/Catalog/CatalogManifest.swift Sources/SingReadyAISharedKit/Resources/Catalog/catalog_manifest.json Sources/SingReadyAISharedKit/Resources/Catalog/catalog_launch_coverage_cases.json Sources/SingReadyAISharedKit/Catalog/KTVCatalogRepository.swift Tests/SingReadyAISharedKitTests/CatalogAndProfilerTests.swift scripts/validate_catalog.py scripts/validate_performance_budget.py scripts/test_delivery_gates.py docs/CATALOG_RELEASE_GATE.md
    git commit -m "feat: 建立曲库机器发布门禁"

### Task 24B: 交付真实曲库资源、覆盖缺口清理与来源权利证据

**优先级与门禁：** P0-release，公开 To C 发布必做。外部数据或权利材料未取得时保持 BLOCKED，但必须按本任务步骤持续收敛，不能以“后续扩充”关闭。

**Files:**
- Modify: `Sources/SingReadyAISharedKit/Resources/Fixtures/fixtures_ktv_catalog.json`
- Modify: `Sources/SingReadyAISharedKit/Resources/Catalog/catalog_manifest.json`
- Modify: `Sources/SingReadyAISharedKit/Resources/Catalog/catalog_launch_coverage_cases.json`
- Create: `docs/CATALOG_COVERAGE_GAP_REPORT.md`
- Create: `docs/CATALOG_SOURCE_RIGHTS_REGISTER.md`
- Modify: `docs/CATALOG_RELEASE_GATE.md`
- Modify: `docs/QUALITY_AUDIT.md`
- Modify: `Tests/SingReadyAISharedKitTests/CatalogAndProfilerTests.swift`
- Modify: `scripts/validate_catalog.py`

- [ ] **Step 1: 对真实资源生成失败基线与逐 case 缺口报告**

Run:

    python3 scripts/validate_catalog.py --release --write-gap-report docs/CATALOG_COVERAGE_GAP_REPORT.md

Expected: FAIL，并在报告中列出每个 launch case 的合格唯一歌曲数、距 30 首差额、缺失属性、重复 ID、语义/alias 冲突、未映射来源和未确认权利；不得只有“总数不足”一行。

- [ ] **Step 2: 清理来源并实际修改正式曲库资源**

由数据负责人按缺口报告修改 `fixtures_ktv_catalog.json`（若实施时迁移为正式资源，则同提交删除旧 fixture 路径并更新 manifest），为每条新增/修订歌曲维护稳定 ID、标准化歌名/歌手/版本、来源引用和经过人工维护的演唱属性。禁止从公开元数据自动推断音区、难度、高音风险、合唱或场景标签；重复、冲突或来源不明数据必须删除或降级出确定性曲库。

- [ ] **Step 3: 建立负责人和真实权利证据登记**

`CATALOG_SOURCE_RIGHTS_REGISTER.md` 逐来源记录数据提供方、负责人、允许用途/地域/期限、审核日期、证据引用和状态。敏感合同留在批准的外部系统，仓库只保存可追溯引用；负责人必须核对引用真实存在并签署 distribution-approved。任一来源仍是 unknown/pending/expired，任务立即标记 BLOCKED，不运行“改布尔值”捷径。

- [ ] **Step 4: 让真实资源从红灯变为 release 绿灯**

Run:

    python3 scripts/validate_catalog.py --release --write-gap-report docs/CATALOG_COVERAGE_GAP_REPORT.md
    swift test --filter CatalogAndProfilerTests
    python3 scripts/validate_performance_budget.py
    python3 -m unittest scripts.test_delivery_gates.DeliveryGateTests.test_catalog_release_manifest
    swift test

Expected: 全部 PASS；报告中每个获批 launch case 均有至少 30 首合法唯一歌曲，manifest digest 与实际正式资源一致，无 ID/语义/alias 冲突，性能达标，来源登记由具名负责人批准。缺任一外部证据只能报告“机器合同通过、24B BLOCKED”。

- [ ] **Step 5: 独立提交真实曲库与权利登记**

    git add Sources/SingReadyAISharedKit/Resources/Fixtures/fixtures_ktv_catalog.json Sources/SingReadyAISharedKit/Resources/Catalog/catalog_manifest.json Sources/SingReadyAISharedKit/Resources/Catalog/catalog_launch_coverage_cases.json docs/CATALOG_COVERAGE_GAP_REPORT.md docs/CATALOG_SOURCE_RIGHTS_REGISTER.md docs/CATALOG_RELEASE_GATE.md docs/QUALITY_AUDIT.md Tests/SingReadyAISharedKitTests/CatalogAndProfilerTests.swift scripts/validate_catalog.py
    git commit -m "data: 交付公开发布曲库与覆盖证据"

### Task 25: 冻结候选并完成 Archive、App Store Connect、TestFlight 与最终门禁

**优先级与门禁：** P0-release，公开 To C 发布必做；依赖开发者账号、Distribution 证书、真实 App Store Connect API 和平台状态。无真实平台回执时保持 BLOCKED。

**Files:**
- Create: `config/ExportOptions-AppStore.plist`
- Create: `scripts/archive_public_release.sh`
- Create: `scripts/run_frozen_release_gates.sh`
- Create: `scripts/fetch_app_store_build_receipt.py`
- Create: `scripts/validate_public_release.py`
- Modify: `scripts/validate_release.py`
- Modify: `scripts/validate.sh`
- Modify: `scripts/test_delivery_gates.py`
- Modify: `scripts/capture_ui_test_screenshots.sh`
- Create: `docs/PUBLIC_RELEASE_QA.md`
- Modify: `docs/MANUAL_QA.md`
- Modify: `docs/QUALITY_AUDIT.md`
- Modify: `README.md`
- Modify: `docs/screenshots/*.png`
- Modify: `docs/screenshots-large-text/*.png`

- [ ] **Step 1: 写候选清单、SHA 隔离证据、真实平台回执与 clean-tree 红灯**

fixture 要求先存在只读 `Build/PublicReleaseCandidate/candidate.json`。它必须记录冻结 `releaseSHA`、由 `git write-tree` 得到且与 `HEAD^{tree}` 相等的 `treeHash`、基线证据摘要、`bundleIdentifier`、`marketingVersion` 和 `buildNumber`；后续唯一证据根只能是 `Build/PublicReleaseEvidence/<releaseSHA>/`。基线证据摘要定义为：对已跟踪的 `docs/screenshots/**`、`docs/screenshots-large-text/**`、`docs/PUBLIC_RELEASE_QA.md`、`docs/MANUAL_QA.md`、`docs/QUALITY_AUDIT.md`、`README.md` 按 UTF-8 路径字节序排序，串联每个“路径 + NUL + 文件 SHA-256 + LF”后再做 SHA-256。缺文件、未跟踪文件或摘要漂移都失败。

证据还必须绑定 clean tree、完整 frozen-gates manifest、每条 Swift/Python/UI/截图/Task 24B 命令及退出码、xcarchive、IPA SHA-256、Bundle/version/build、签名团队、Task 23、Task 24A/24B、iOS 17 smoke、App Store Connect 原始 upload 回执、`GET /v1/apps/{ASC_APP_ID}` 的原始 app resource、真实 build resource ID、`processingState`、`buildBetaDetails` 状态和 TestFlight 安装记录。最终 evidence manifest 必须包含 app resource 原始响应文件的 SHA-256。

fixture 必须拒绝：候选清单可写或字段缺失、当前 HEAD/tree 与清单不符、漏跑命令/缺日志/非零退出码、手填 app/build ID 或状态、错误 SHA 目录、缺原始 JSON/UTC 时间戳、冻结后跟踪文件变化、证据引用其他 commit、ASC app/preReleaseVersion/build 任一查询为零条或多条、app resource ID 不等于 `ASC_APP_ID`、`attributes.bundleId` 与候选清单或 IPA 的 Bundle Identifier 不一致，以及 marketing version、build number、App ID 或 IPA SHA-256 任一不一致。

- [ ] **Step 2: 运行红灯，确认本地 Release `.app` 不能代替平台回执**

Run:

    python3 -m unittest scripts.test_delivery_gates.DeliveryGateTests.test_public_release_requires_sha_scoped_platform_receipts

Expected: FAIL；当前没有 SHA 隔离证据、唯一上传路径或 App Store Connect API 原始回执合同。

- [ ] **Step 3: 实现候选冻结、门禁编排、Archive/Export、API 查询和只读证据校验**

`validate_public_release.py` 的 `create-candidate` 模式是唯一可以创建 `candidate.json` 的入口：它要求 clean tree，执行并交叉校验 `git rev-parse HEAD`、`git write-tree` 与 `git rev-parse HEAD^{tree}`，按 Step 1 的固定文件集计算 `baselineEvidenceDigest`，并从显式 Release app bundle 的 `Info.plist` 读取 Bundle Identifier、`CFBundleShortVersionString` 和 `CFBundleVersion`。创建完成后清单设为 `0444`；之后该脚本只读校验清单、当前 HEAD/tree 和所有证据，任何流程不得重写清单。

`run_frozen_release_gates.sh` 接收 `--candidate-manifest` 与 `--evidence-dir`，只从清单读取候选 SHA/tree。它负责执行冻结候选的全部 Swift 测试、Python 校验、iOS/UI 测试、普通/最大字号截图和 Task 24B release 曲库门禁；Task 24B 的 gap report 必须写到 `$EVIDENCE_DIR/catalog/CATALOG_COVERAGE_GAP_REPORT.md`，所有截图、日志与 xcresult 也只能写入 `$EVIDENCE_DIR`。冻结运行禁止传入任何会写 `docs/` 或其他跟踪路径的参数，脚本发现输出越界即失败。

每条命令都把规范化命令字符串、开始/结束 UTC、退出码、stdout/stderr 日志路径、xcresult 路径（如有）、产物 SHA-256、候选 SHA/tree 写入 `$EVIDENCE_DIR/frozen-gates-manifest.json`；即使命令失败也必须落盘其退出码并把整轮标为失败。`validate_public_release.py` 按固定 required-command 集合验证 manifest 完整、全部退出码为零、日志/xcresult/产物存在且摘要匹配，不能用口头或手填记录代替。

`archive_public_release.sh` 只向传入的 `EVIDENCE_DIR` 写 xcarchive、IPA、哈希和命令日志。Export 后必须从 IPA 内 `.app/Info.plist` 读取 Bundle Identifier、marketing version 与 build number，计算 IPA SHA-256，写入不可手填的 `ipa-metadata.json`，并与候选清单三项版本身份逐项相等。

`fetch_app_store_build_receipt.py` 使用 App Store Connect API JWT：首先请求 `GET /v1/apps/{ASC_APP_ID}`，要求唯一 app resource 的 ID 等于 `ASC_APP_ID`，且 `attributes.bundleId` 同时等于候选清单与 IPA 的 Bundle Identifier；然后才按 `ASC_APP_ID + preReleaseVersion.version == marketingVersion` 查询唯一 pre-release version，再按 `ASC_APP_ID + preReleaseVersion ID + build.version == buildNumber` 查询唯一 build，最后查询对应 `buildBetaDetails`。原始响应分别保存为 `app-store-app.json`、`app-store-pre-release-versions.json`、`app-store-builds.json` 和 `build-beta-details.json`。

receipt metadata 必须验证并记录 `(ASC_APP_ID, bundleIdentifier, marketingVersion, buildNumber)` 元组、IPA SHA-256、候选 SHA/tree、唯一 build resource ID、HTTP 状态、查询 UTC 和 `processingState`；最终 evidence manifest 记录 `appResourceResponseSHA256` 并由 validator 对原始文件复算。app resource 缺失/重复、bundleId 不一致或后续任一步零条/多条都保持 BLOCKED。`validate_public_release.py` 要求 `processingState == VALID` 且 TestFlight 状态来自原始 API，不接受人工填写替代。

凭据只允许环境变量 `ASC_API_KEY_ID`、`ASC_API_ISSUER_ID`、`ASC_APP_ID` 和 keychain/`~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`；不得写入仓库、证据 manifest 或命令输出。Task 23、24A、24B 未完成时 archive 脚本直接拒绝。

- [ ] **Step 4: 运行聚焦与仓库全量代码门禁**

Run:

    python3 -m unittest scripts.test_delivery_gates.DeliveryGateTests.test_public_release_requires_sha_scoped_platform_receipts
    git diff --check
    ./scripts/validate.sh

Expected: 全部 PASS。这只证明工具合同有效，不代表真实上传完成。

- [ ] **Step 5: 提交所有跟踪文档和基线截图后冻结唯一候选**

先按当前候选重新采集 `docs/screenshots`、`docs/screenshots-large-text`，更新 `PUBLIC_RELEASE_QA.md` 模板、MANUAL/QUALITY/README 和脚本；运行 `git diff --check` 与 `./scripts/validate.sh` 后一次提交全部跟踪变化：

    git add config/ExportOptions-AppStore.plist scripts/archive_public_release.sh scripts/run_frozen_release_gates.sh scripts/fetch_app_store_build_receipt.py scripts/validate_public_release.py scripts/validate_release.py scripts/validate.sh scripts/test_delivery_gates.py scripts/capture_ui_test_screenshots.sh docs/PUBLIC_RELEASE_QA.md docs/MANUAL_QA.md docs/QUALITY_AUDIT.md README.md docs/screenshots docs/screenshots-large-text
    git commit -m "release: 建立冻结候选分发门禁"
    test -z "$(git status --porcelain --untracked-files=all)"

随后先构建固定 Release app，再由唯一创建入口生成候选清单：

    CANDIDATE_MANIFEST=Build/PublicReleaseCandidate/candidate.json
    CANDIDATE_DERIVED_DATA=Build/PublicReleaseCandidate/DerivedData
    xcodebuild build \
      -project SingReadyAI.xcodeproj \
      -scheme SingReadyAIApp \
      -configuration Release \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$CANDIDATE_DERIVED_DATA" \
      SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
    CANDIDATE_APP="$CANDIDATE_DERIVED_DATA/Build/Products/Release-iphonesimulator/SingReadyAIApp.app"
    test -d "$CANDIDATE_APP"
    python3 scripts/validate_release.py "$CANDIDATE_APP"
    python3 scripts/validate_public_release.py create-candidate \
      --manifest "$CANDIDATE_MANIFEST" \
      --app-bundle "$CANDIDATE_APP"
    test "$(stat -f '%Lp' "$CANDIDATE_MANIFEST")" = "444"

`create-candidate` 将冻结 SHA、`git write-tree` 的 tree hash、基线证据摘要和 app 的 Bundle/marketing/build 写入清单，并在落盘前校验 `git write-tree == HEAD^{tree}`。从此 Steps 6–8 的 `RELEASE_SHA` 和 `RELEASE_TREE` 只允许从该只读清单读取；新 shell 可以重复以下 bootstrap，但不得从 `git rev-parse` 给 `RELEASE_SHA` 重新赋值：

    RELEASE_SHA="$(python3 scripts/validate_public_release.py candidate-field --manifest "$CANDIDATE_MANIFEST" --field releaseSHA)"
    RELEASE_TREE="$(python3 scripts/validate_public_release.py candidate-field --manifest "$CANDIDATE_MANIFEST" --field treeHash)"
    CURRENT_HEAD="$(git rev-parse HEAD)"
    CURRENT_TREE="$(git write-tree)"
    test "$CURRENT_HEAD" = "$RELEASE_SHA"
    test "$CURRENT_TREE" = "$RELEASE_TREE"
    test -z "$(git status --porcelain --untracked-files=all)"
    python3 scripts/validate_public_release.py verify-candidate --manifest "$CANDIDATE_MANIFEST"
    EVIDENCE_DIR="Build/PublicReleaseEvidence/$RELEASE_SHA"
    mkdir -p "$EVIDENCE_DIR"

该 commit 是冻结前最后一次跟踪文件变更，`candidate.json` 是后续唯一候选身份源。冻结后所有重跑结果、截图、QA 填写和平台回执只能写入 `$EVIDENCE_DIR`；禁止修改 `candidate.json`、`docs/`、基线截图或任何跟踪文件。若必须修文档或代码，废弃候选清单和整个证据目录，提交后创建新清单并从头重跑。

- [ ] **Step 6: 使用唯一允许路径 Archive、Export 并上传 IPA**

Run:

    test -n "$ASC_API_KEY_ID" && test -n "$ASC_API_ISSUER_ID" && test -n "$ASC_APP_ID"
    python3 scripts/validate_public_release.py verify-candidate --manifest "$CANDIDATE_MANIFEST"
    ./scripts/archive_public_release.sh \
      --candidate-manifest "$CANDIDATE_MANIFEST" \
      --evidence-dir "$EVIDENCE_DIR"
    IPA_PATH="$EVIDENCE_DIR/export/SingReadyAIApp.ipa"
    test -f "$IPA_PATH"
    set -o pipefail
    xcrun altool --upload-app --type ios --file "$IPA_PATH" --apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_API_ISSUER_ID" 2>&1 | tee "$EVIDENCE_DIR/app-store-upload.log"

`altool` 是唯一首选上传路径。只有实施时 `xcrun altool --help` 明确不再提供 `--upload-app`，且仓库门禁记录该能力探测结果，才允许唯一替代：

    xcrun iTMSTransporter -m upload -assetFile "$IPA_PATH" -apiKey "$ASC_API_KEY_ID" -apiIssuer "$ASC_API_ISSUER_ID" 2>&1 | tee "$EVIDENCE_DIR/app-store-upload.log"

不得因认证、网络、处理或业务校验失败而自动换工具重试；fallback 只处理已安装 Xcode 确认不支持 altool 的情况，并在证据中记录唯一 `uploadTool`。任一上传命令无平台成功回执即 BLOCKED。Archive/Export 在上传前必须写出从 IPA 实读的 `ipa-metadata.json`；其中 Bundle Identifier、marketing version、build number 必须与候选清单一致，IPA SHA-256 随后成为平台回执的固定绑定值。

- [ ] **Step 7: 从 App Store Connect API 获取真实 build 与 TestFlight 状态**

Run:

    python3 scripts/fetch_app_store_build_receipt.py \
      --app-id "$ASC_APP_ID" \
      --ipa "$IPA_PATH" \
      --candidate-manifest "$CANDIDATE_MANIFEST" \
      --evidence-dir "$EVIDENCE_DIR" \
      --wait-for-processing VALID \
      --timeout-seconds 3600

脚本先从 IPA 实读 Bundle Identifier、`CFBundleShortVersionString`、`CFBundleVersion` 并重新计算 IPA SHA-256，拒绝与 `ipa-metadata.json` 或候选清单不一致。随后先请求 `GET /v1/apps/{ASC_APP_ID}`，把完整响应保存为 `app-store-app.json`；只有响应中存在唯一且 ID 匹配的 app resource，并且 `attributes.bundleId == candidate.bundleIdentifier == IPA Bundle Identifier`，才继续查询版本。

接着通过 `GET /v1/preReleaseVersions` 按 `ASC_APP_ID + preReleaseVersion.version == marketingVersion` 获取唯一 pre-release version，再通过 `GET /v1/builds` 按 `ASC_APP_ID + preReleaseVersion ID + build.version == buildNumber` 获取唯一真实 build resource ID，最后查询对应 `buildBetaDetails`。原始响应另存为 `app-store-pre-release-versions.json`、`app-store-builds.json` 和 `build-beta-details.json`；receipt metadata 绑定 `(ASC_APP_ID, bundleIdentifier, marketingVersion, buildNumber)`、IPA SHA-256、候选 SHA/tree、唯一 build ID、UTC 与 HTTP 状态，evidence manifest 绑定 `app-store-app.json` 的 SHA-256。app/preReleaseVersion/build 任一为零条或多条、bundleId 不一致、`processingState` 不是 `VALID`、TestFlight 状态未就绪、API 不可达或元组/hash 不符时保持 BLOCKED。

从 TestFlight 安装该真实 build，记录首次启动、终止重启、上一版本升级（若存在）、分享扩展、三截图导入、音区权限、开唱模式和导出；最低 iOS 17 runtime/真机 smoke 的日志也只写 `$EVIDENCE_DIR`。开发安装不能替代 TestFlight。

- [ ] **Step 8: 在冻结 SHA 上由唯一 runner 只写 Build 证据重跑最终全故事**

运行唯一编排入口：

    python3 scripts/validate_public_release.py verify-candidate --manifest "$CANDIDATE_MANIFEST"
    ./scripts/run_frozen_release_gates.sh \
      --candidate-manifest "$CANDIDATE_MANIFEST" \
      --evidence-dir "$EVIDENCE_DIR"

runner 的固定 required-command 集合至少包含：`swift test`；delivery/public-release Python 单测与全部 Python validator；固定 DerivedData 的 generic iOS Simulator Release build 加 `validate_release.py <app-bundle>`；Task 17–24B 聚焦 iOS 测试；完整 `run_ui_tests.sh`；普通字号与 accessibility-extra-extra-extra-large 两套截图；`./scripts/validate.sh`；以及 `validate_catalog.py --release --write-gap-report "$EVIDENCE_DIR/catalog/CATALOG_COVERAGE_GAP_REPORT.md"`。Task 16/22A 全量门禁、Task 17–24B 聚焦门禁、两套截图和最低 iOS 17 smoke 均须出现在 `frozen-gates-manifest.json`；manifest 还必须记录 `appResourceResponseSHA256`，并与 `app-store-app.json` 复算值相等。任何命令都不得使用写入 `docs/` 的参数。

App Store Connect 元数据、privacy/support URL、App Privacy 问卷、加密说明、第三方数据保留复核和人工设备结果使用 `PUBLIC_RELEASE_QA.md` 的冻结模板写入 `$EVIDENCE_DIR/public-release-qa.md`，不回写仓库。最后运行：

    CURRENT_HEAD="$(git rev-parse HEAD)"
    CURRENT_TREE="$(git write-tree)"
    test "$CURRENT_HEAD" = "$RELEASE_SHA"
    test "$CURRENT_TREE" = "$RELEASE_TREE"
    test -z "$(git status --porcelain --untracked-files=all)"
    python3 scripts/validate_public_release.py verify-release \
      --candidate-manifest "$CANDIDATE_MANIFEST" \
      --evidence-dir "$EVIDENCE_DIR" \
      --require-ios-major 17

Expected: runner 与最终只读校验成功，required-command 集合、退出码、日志、xcresult、截图/报告摘要、候选 SHA/tree、原始 upload/build/TestFlight 回执和人工证据完整。无真实平台回执、manifest 缺项、任何跟踪文件变化或任一外部门禁未通过时，允许的最高结论仍是“早期验证版核心闭环”。

## 分级实施完成判定

### 早期验证版核心闭环

以下“本功能完成”仅指 Task 1–22 加 Task 22A 的早期验证版核心闭环；Task 16 定义的全套门禁必须由 Task 22A 在补充任务之后从头复跑并提交权威证据。它不包含曲库分发权利、商店手续或公开 To C 发布结论。

只有同时满足以下条件才可宣称本功能完成：

- 导入完成后，首页和匹配页都能直接回答“接下来可以做什么”。
- 0 次逐首操作也能用 verified 歌曲生成正式计划。
- 每个 importedSong stable ID 都有且只有一组稳定 `reviewMatchOutcome` 与可变 `planDisposition`；五个提交点、同曲命中、alias/版本归并、锁定和容量截断均可逐条、确定性解释，summary 只从对应阶段的 entries/supplements 派生。
- 任一正式计划均满足 `N = X + R + Y`，并为每首歌持久化唯一 origin。
- pending、未采用 alternative、unmatched 附带候选和外部公开候选无法从任何路径进入正式计划。
- E 只存在于独立公开候选集合，不参与容量、hard rules、锁定、反馈、导出或开唱小抄。
- 取消、失败、重启、迟到任务和 basis 变化不会发布半份或过期结果。
- 500/1000 首规模预算、16MB 快照边界、100ms 主线程心跳、完整 UI、两套字号截图和 `./scripts/validate.sh` 全部有最新证据。
- 分享导入、真实截图识别、真实音区测量、系统分享和重启恢复已在连接的 iPhone 上逐项通过并记录设备证据。
- 多截图批量导入固定上限为 20 张、120 MiB、160,000,000 pixels、并发 2，overflow-safe preflight 与页面 retry session 清理语义通过；部分失败明确、批次原子发布，真机 3 张重叠截图 smoke 已通过。
- 反馈持久化失败与重排失败遵循不同事务语义；重排失败保留新反馈且 stale plan 禁止导出、分享和开唱。

### 公开 To C 发布

只有在早期验证版核心闭环成立，并且同时满足以下条件时，才可宣称公开 To C 发布候选通过门禁：

- Task 23 的帮助、客服、公开隐私政策 URL 和非公开隐私/删除联系渠道均真实可达。
- Task 24A 的版本化 manifest、碰撞、覆盖和性能机器门禁通过；Task 24B 已实际修改正式曲库资源、清零获批 coverage cases 缺口，并由具名负责人确认来源权利证据。
- Task 25 由只读 `Build/PublicReleaseCandidate/candidate.json` 绑定冻结 commit/tree、基线证据摘要和 Bundle/marketing/build，并在同一候选上完成 Distribution Archive/Export、唯一工具上传；ASC 原始 app resource 的 `bundleId` 必须与候选/IPA 一致，随后才接受唯一 `(app ID, marketing version, build number)` build/processing/TestFlight 回执，以及 TestFlight 安装升级、最低 iOS 17 smoke、元数据与隐私问卷。
- Task 16/22A 与 Task 17–24B 的最终自动化、截图、真机和人工证据全部由 frozen runner 写入 `Build/PublicReleaseEvidence/<RELEASE_SHA>/`，完整 manifest 记录命令、退出码、日志、xcresult 与摘要并绑定同一冻结 SHA/tree；冻结后候选清单和仓库跟踪文件均没有变化。
- 开发者账号、签名证书、第三方合同、Apple 处理/审核状态等外部依赖均有实际结果；缺失或等待时不得写成代码已完成。

最终门禁通过前，对外结论只能是“早期验证版核心闭环”；Apple 审核或发布尚未完成时，不得宣称已在公开商店可用。
