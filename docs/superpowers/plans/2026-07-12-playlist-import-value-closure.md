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

本轮不扩大 215 首本地参考曲库，不承诺从第三方音乐 App 直接读取私有歌单接口，也不把在线公开搜索结果当成可唱曲库。对应产品边界以 `docs/superpowers/specs/2026-07-12-playlist-import-value-closure-design.md` 为准。

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
- Modify: `Sources/SingReadyAISharedKit/Models/Models.swift`
- Modify: `Sources/SingReadyAISharedKit/Recommendation/PreferenceProfiler.swift`
- Modify: `Tests/SingReadyAISharedKitTests/SongMatcherTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`

- [ ] **Step 1: 为六种状态和旧 JSON 迁移写红灯测试**

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

- [ ] **Step 2: 运行现有匹配/闭环测试，确认新合同红灯**

Run: `swift test --filter SongMatcherTests && swift test --filter ProductClosureTests`
Expected: FAIL；失败点应集中在缺少 `disposition`、旧自由组合构造器仍可创建非法状态，以及画像仍读取旧字段。

- [ ] **Step 3: 改造 MatchResult 并保留单向兼容解码**

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

- [ ] **Step 4: 更新统计与用户动作迁移测试**

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

- [ ] **Step 5: 运行两组聚焦回归**

Run:

    swift test --filter SongMatcherTests
    swift test --filter ProductClosureTests
    swift test
    xcodebuild build -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'generic/platform=iOS Simulator' -derivedDataPath Build/PlaylistImportClosure-Incremental CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

Expected: PASS 且 App 构建成功；旧快照 fixture 可解码，未确认歌曲不进入画像。增量构建通过依赖只读适配器，而不是保留旧可写状态。

- [ ] **Step 6: 提交匹配状态模型**

    git add Sources/SingReadyAISharedKit/Models/Models.swift Sources/SingReadyAISharedKit/Recommendation/PreferenceProfiler.swift Tests/SingReadyAISharedKitTests/SongMatcherTests.swift Tests/SingReadyAISharedKitTests/ProductClosureTests.swift
    git commit -m "refactor: 收紧歌曲匹配状态合同"

### Task 3: 落实唯一身份、阈值、进度与规模预算

**Files:**
- Modify: `Sources/SingReadyAISharedKit/Catalog/SongMatcher.swift`
- Modify: `Sources/SingReadyAISharedKit/Catalog/SongNormalizer.swift`
- Modify: `Tests/SingReadyAISharedKitTests/SongMatcherTests.swift`
- Create: `Tests/SingReadyAISharedKitTests/PlaylistScaleContractTests.swift`

- [ ] **Step 1: 写自动接受安全门红灯测试**

用表驱动测试锁定以下顺序：

1. 规范化歌名身份、歌手身份、版本身份均兼容且候选唯一，才是 `acceptedOriginalExact`。
2. 非完全精确，但同身份有冲突或总分 `>= 0.78`，进入 `identityConfirmationRequired`。
3. 分数 `>= 0.60 && < 0.78`，进入 `alternativeSuggested`。
4. 更低为 `unmatched`。
5. 缺歌手即使唯一、别名带版本标记、同名多候选、单侧版本标记均不得自动接受。

边界值必须包含 `0.5999 / 0.60 / 0.7799 / 0.78`，避免以后比较符漂移。

- [ ] **Step 2: 运行匹配测试，确认旧 `0.95`/`0.78` 自由接受逻辑失败**

Run: `swift test --filter SongMatcherTests`
Expected: FAIL；现有 fuzzy 自动接受、title-only 分支和版本词剥离逻辑与新断言冲突。

- [ ] **Step 3: 实现候选证据与唯一性判定**

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

- [ ] **Step 4: 给分析执行器增加单调进度**

为 `PlaylistAnalysisExecutor.analyze` 增加可选 `progress: @Sendable (Int, Int) async -> Void`；每处理固定批次（建议 20 首）报告一次，保证首个事件为 `0/total`、最后一个为 `total/total`、中间单调递增。回调只用于展示，不发布部分 matches/profile。

- [ ] **Step 5: 写 500/1000 混合 fixture、取消和主线程心跳红灯**

`PlaylistScaleContractTests` 用确定性构造器生成 25% 精确、25% 缺歌手、25% 相近/替代、25% 未找到的歌单；测试范围从已构造的 `ImportedPlaylist` 开始，只包含曲库索引、匹配、画像与摘要：

    500 首完整分析 < 5 秒
    1000 首完整分析 < 8 秒
    1000 首精确匹配继续 < 5 秒
    主线程心跳最长间隔 < 100 毫秒
    取消后不返回部分 PlaylistAnalysisOutput

性能断言使用 `ContinuousClock`；不要把网络、OCR、SwiftUI 或磁盘计入该测试。

- [ ] **Step 6: 运行规模合同并优化到绿灯**

Run: `swift test --filter PlaylistScaleContractTests && swift test --filter SongMatcherTests`
Expected: PASS；若超时，先复用规范化索引和预计算身份，不降低阈值、不跳过候选。

- [ ] **Step 7: 提交匹配安全门与规模合同**

    git add Sources/SingReadyAISharedKit/Catalog Tests/SingReadyAISharedKitTests/SongMatcherTests.swift Tests/SingReadyAISharedKitTests/PlaylistScaleContractTests.swift
    git commit -m "feat: 完善批量匹配安全门与进度"

### Task 4: 建立正式推荐来源与数量守恒

**Files:**
- Create: `Sources/SingReadyAISharedKit/Recommendation/RecommendationContracts.swift`
- Modify: `Sources/SingReadyAISharedKit/Models/Models.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/RecommendationCapacityContractTests.swift`

- [ ] **Step 1: 写 Codable 与数量守恒红灯测试**

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

- [ ] **Step 2: 运行聚焦测试，确认类型与解码缺失**

Run: `swift test --filter ProductClosureTests && swift test --filter RecommendationCapacityContractTests`
Expected: FAIL，原因是 origin/summary 尚不存在或数量不守恒。

- [ ] **Step 3: 实现来源模型与只读展示名称**

`SongPlanItem` 增加 `origin` 并贯穿初始化、解码、`sanitizedForTrustBoundaries`；`SongPlan` 增加可选 `generationSummary`。在本任务同时实现 `SongPlanGenerationContext` 与 throwing summary 构造器；Task 5 把真实上下文接到所有生成调用，Task 11 再把同一 context 与 `PlanBasis` 一起冻结，避免到结果页再扩模型。展示名称使用大陆产品语言：

    importedMatch        -> "来自导入歌单"
    adoptedAlternative   -> "你采用的替代"
    sameArtistSupplement -> "同歌手补充"
    styleSupplement      -> "风格补充"
    sceneSupplement      -> "场景补充"
    popularSupplement    -> "热门补充"
    legacyUnknown        -> "历史排歌"

- [ ] **Step 4: 运行 Codable、容量和旧计划回归**

Run: `swift test --filter ProductClosureTests && swift test --filter RecommendationCapacityContractTests`
Expected: PASS；现有容量、锁定和旧 JSON 合同不回退。

- [ ] **Step 5: 提交来源与摘要模型**

    git add Sources/SingReadyAISharedKit/Recommendation/RecommendationContracts.swift Sources/SingReadyAISharedKit/Models/Models.swift Tests/SingReadyAISharedKitTests/ProductClosureTests.swift Tests/SingReadyAISharedKitTests/RecommendationCapacityContractTests.swift
    git commit -m "feat: 增加排歌来源与数量守恒"

### Task 5: 把候选安全门变成推荐唯一入口

**Files:**
- Create: `Sources/SingReadyAISharedKit/Recommendation/RecommendationCandidateGate.swift`
- Modify: `Sources/SingReadyAISharedKit/Recommendation/RecommendationEngine.swift`
- Modify: `Sources/SingReadyAISharedKit/Recommendation/RecommendationReasonBuilder.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Recommendation.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/RecommendationEngineTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/RecommendationCapacityContractTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ExternalCandidateContractTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ExternalMusicCandidateProviderTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/ExporterAndNormalizerTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/RecommendationInteractionContractTests.swift`
- Modify: `Tests/SingReadyAISharedKitTests/VoiceMeasurementContractTests.swift`

- [ ] **Step 1: 写三条拒绝路径和合法重合路径红灯测试**

必须分别证明：

- `identityConfirmationRequired` 的候选不进正式计划。
- `alternativeSuggested` 在用户未采用前不进正式计划。
- `unmatched` 附带的候选不进正式计划。
- A 歌曲待确认某 track、B 歌曲明确接受同一 track 时，该 track 可经 B 的合法路径进入一次，origin 为 `importedMatch`；不能用全局 pending ID 误杀。
- 外部 `catalogSource == .externalSimilar` 即使从 match、catalog 或 locked ID 三条路径进入，也全部拒绝。

- [ ] **Step 2: 运行推荐测试，确认当前 `acceptedTrack + alternatives` 池红灯**

Run: `swift test --filter ProductClosureTests && swift test --filter ExternalCandidateContractTests`
Expected: FAIL；当前 `RecommendationEngine.buildCandidatePool` 会把未采用 alternatives 或外部候选加入池。

- [ ] **Step 3: 实现 path-aware 候选安全门**

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
        ) -> [RecommendationCandidate]
    }

候选路径：

- `acceptedOriginalExact / acceptedOriginalConfirmed` -> `importedMatch`
- `adoptedAlternative` -> `adoptedAlternative`
- 本地 catalog 再按同歌手、风格、场景、热门依次标记 supplement origin
- 其他 disposition 不产生正式候选

同一语义歌曲多路径出现时，来源优先级为 `adoptedAlternative > importedMatch > sameArtistSupplement > styleSupplement > sceneSupplement > popularSupplement`。只接受 `.ktvCatalog`。

- [ ] **Step 4: 让排序、替换和 plan item 全程携带 origin**

`ScoredTrack` 增加 origin；`planItem`、锁定插入、场景 hard-rule 替换和去重均保留来源。删除外部 provisional 的评分、分区和 hard-rule 特判；`normalizeSongPlanSectionsForTrustBoundary` 对旧 provisional item 直接丢弃，不再放进 `externalVerification` 分区。

- [ ] **Step 5: 在生成末尾校验摘要**

`RecommendationEngine.generatePlan` 增加必填 `generationContext: SongPlanGenerationContext`，在所有 hard-rule 调整完成后从 context 与最终 items 构造 `SongPlanGenerationSummary`；任何 count mismatch 都抛错，不返回可发布 `SongPlan`。公开 API 采用 `throws`，不得提供伪造历史来源的默认 context。

破坏性签名必须在本任务一次迁完：用

    rg -l 'recommendationEngine\.generatePlan|RecommendationEngine\(\)\.generatePlan|engine\.generatePlan' SingReadyAI Tests Sources

列出全部调用点；测试方法增加 `throws`/`try`，App 的同步调用先用 `do/catch` 保守处理为“不发布计划并显示可重试错误”。Task 11 再把这个 catch 接入正式 `failed/stale` 状态，但 Task 5 提交本身必须可编译、不可使用 `try!` 或静默 fallback。

- [ ] **Step 6: 运行推荐全套聚焦测试**

Run:

    swift test --filter ProductClosureTests
    swift test --filter RecommendationEngineTests
    swift test --filter RecommendationCapacityContractTests
    swift test --filter ExternalCandidateContractTests
    swift test
    xcodebuild build -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'generic/platform=iOS Simulator' -derivedDataPath Build/PlaylistImportClosure-Incremental CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

Expected: 全部 PASS 且 `** BUILD SUCCEEDED **`；正式条目数始终等于 X+R+Y，外部候选数不参与容量和 hard rules，仓库内不存在遗漏的非 `try` 调用点。

- [ ] **Step 7: 提交候选准入门**

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

集合只保存公开来源提供的 title、artist、provider、relation、URL 和 confidence/relevance；不得制造 difficulty、vocalRange、sceneTags 或 KTV availability。新 `ExternalCandidateCollectionAccumulator` 按语义 key 去重，稳定保留更高相关度，本地 fallback 不进入集合。旧 `ExternalCandidateTrackMapper/Accumulator` 暂留为 v1 快照迁移兼容代码并加“migration-only”注释，不加会触发 warnings-as-errors 的 deprecated 属性，也不再被新领域测试或推荐引擎调用。

- [ ] **Step 5: 验证 Codable、稳定顺序和正式计划隔离**

新增 round-trip、不同输入顺序结果一致、同语义保留高相关项、collection count 为 E 的测试；继续运行 Task 5 的三条外部候选拒绝路径。

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

### Task 16: 完成规模矩阵、恢复回归、两套字号截图和交付门禁

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

- [ ] **Step 10: 运行最终交付门禁**

Run:

    git diff --check
    ./scripts/validate.sh

Expected: `git diff --check` 无输出；`validate.sh passed.`。若全量 UI 或第三方在线 smoke 因环境失败，保留日志并区分代码回归与环境问题，不把可选在线 smoke 伪报为通过。

- [ ] **Step 11: 提交验收证据**

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

## 实施完成判定

只有同时满足以下条件才可宣称本功能完成：

- 导入完成后，首页和匹配页都能直接回答“接下来可以做什么”。
- 0 次逐首操作也能用 verified 歌曲生成正式计划。
- 任一正式计划均满足 `N = X + R + Y`，并为每首歌持久化唯一 origin。
- pending、未采用 alternative、unmatched 附带候选和外部公开候选无法从任何路径进入正式计划。
- E 只存在于独立公开候选集合，不参与容量、hard rules、锁定、反馈、导出或开唱小抄。
- 取消、失败、重启、迟到任务和 basis 变化不会发布半份或过期结果。
- 500/1000 首规模预算、16MB 快照边界、100ms 主线程心跳、完整 UI、两套字号截图和 `./scripts/validate.sh` 全部有最新证据。
- 分享导入、真实截图识别、真实音区测量、系统分享和重启恢复已在连接的 iPhone 上逐项通过并记录设备证据。
