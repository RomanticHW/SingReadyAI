# 产品闭环修复记录

> 本记录按实施顺序保留问题、修复边界与验证要求，便于后续维护和回归。

**目标：** 修复数据来源误导、核心匹配不可操作、声线兜底冒充实测、推荐控制失真、状态不可恢复和声明不可达等问题，并完成一次新的深度审查。

**架构：** 在 SharedKit 增加来源与快照模型，把可测试业务语义放在共享层；App store 只负责协调导航、持久化和异步任务；SwiftUI 页面根据来源决定文案和可用动作。

**技术栈：** Swift 5.9 Package tools、Swift 5 language mode、SwiftUI、AVFoundation、PhotosUI、Transferable、XCTest、XCUITest。

**当前状态（2026-07-12）：** 任务 1 至任务 7 已完成；最终验证为 Swift `363/363`、交付脚本 `60/60`、Xcode 单元测试 `357/357`、完整 UI `108/108`、系统流程聚焦回归 `6/6`、双字号截图 `11+11`，通用 simulator/device-SDK Release 与静态总门禁通过。本轮最终验收按要求仅使用模拟器。发布前外部事项另列，不计作代码闭环未完成。

---

## 任务 1：来源模型与可信文案

**修改文件：**

- `Sources/SingReadyAISharedKit/Models/Models.swift`
- `Sources/SingReadyAISharedKit/Recommendation/RecommendationEngine.swift`
- `Sources/SingReadyAISharedKit/Recommendation/RecommendationReasonBuilder.swift`
- `Sources/SingReadyAISharedKit/Recommendation/SingingAdjustmentAdvisor.swift`
- `Sources/SingReadyAISharedKit/Export/Exporters.swift`
- `SingReadyAI/App/DemoWorkflowStore.swift`
- `SingReadyAI/Features/ProductFlow/VoiceAndPreferenceViews.swift`
- `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`
- `Tests/SingReadyAISharedKitTests/ExporterAndNormalizerTests.swift`

- [x] 添加失败测试：常见音域来源不生成性别、实测置信度和精确调性建议。
- [x] 添加失败测试：热门兜底计划不生成“你歌单里”“你的声线”理由。
- [x] 运行聚焦测试并确认因来源字段或条件缺失而失败。
- [x] 增加可向后兼容解码的歌单来源、声线来源和用户可见音区摘要。
- [x] 让推荐理由、调性建议和导出根据来源降级。
- [x] 运行聚焦测试至通过。

## 任务 2：逐歌匹配与歧义处理

**修改文件：**

- `Sources/SingReadyAISharedKit/Catalog/SongMatcher.swift`
- `Sources/SingReadyAISharedKit/Models/Models.swift`
- `SingReadyAI/App/DemoWorkflowStore+Import.swift`
- `SingReadyAI/Features/ProductFlow/MatchVoiceScenarioViews.swift`
- `SingReadyAI/App/WorkflowState.swift`
- `Tests/SingReadyAISharedKitTests/SongMatcherTests.swift`
- `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`

- [x] 添加失败测试：缺歌手且存在同名歌曲时不能直接精确命中。
- [x] 添加失败测试：缺歌手时单候选和多候选都进入待确认，确认前不参与画像与匹配率。
- [x] 添加失败 UI 测试：混合歌单逐首显示原歌、状态、原因和备选。
- [x] 运行测试并确认旧页面只显示汇总、旧 matcher 误判。
- [x] 增加逐歌结果卡片和“采用这个备选”操作。
- [x] 增加 `needsConfirmation/confirmed` 语义；确认后重建画像并写入快照，恢复后保持已确认选择。
- [x] 将用户可见命名统一为“本地参考曲库/常见 K 歌参考”。
- [x] 采用备选后重新构建画像并保存当前状态。
- [x] 运行聚焦单元和 UI 测试至通过。

## 任务 3：声线测量与录音生命周期

**修改文件：**

- `Sources/SingReadyAISharedKit/VoiceAnalysis/PitchDetector.swift`
- `SingReadyAI/App/Services/VoiceRecordingService.swift`
- `SingReadyAI/App/DemoWorkflowStore.swift`
- `SingReadyAI/Features/ProductFlow/VoiceAndPreferenceViews.swift`
- `Tests/SingReadyAISharedKitTests/PitchDetectorTests.swift`
- `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`

- [x] 添加失败测试：跨度不足的样本不能形成可信实测音区。
- [x] 添加失败 UI 测试：录音中没有重复开始和直接兜底按钮，取消后结果不会覆盖。
- [x] 运行测试并确认失败原因正确。
- [x] 调整测量引导、音区表达和最低有效跨度。
- [x] 串行化开始/取消流程，覆盖离页和 scene inactive。
- [x] 用顶层清理保证所有音频退出路径关闭 session。
- [x] 运行聚焦测试至通过。

## 任务 4：推荐控制与外部候选

**修改文件：**

- `Sources/SingReadyAISharedKit/Recommendation/RecommendationEngine.swift`
- `Sources/SingReadyAISharedKit/ExternalMusic/ExternalMusicCandidateProvider.swift`
- `Sources/SingReadyAISharedKit/Models/Models.swift`
- `SingReadyAI/App/DemoWorkflowStore+ProductClosure.swift`
- `SingReadyAI/Features/ProductFlow/MatchVoiceScenarioViews.swift`
- `Tests/SingReadyAISharedKitTests/RecommendationEngineTests.swift`
- `Tests/SingReadyAISharedKitTests/ExternalMusicCandidateProviderTests.swift`
- `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`

- [x] 添加失败测试：30、45、60、90、120、180 分钟精确生成 6、9、12、18、24、30 首；候选不足时返回全部唯一候选。
- [x] 添加失败测试：跨场景锁定歌曲仍保留。
- [x] 添加失败测试：锁定数超过基础目标时有效目标扩容并提示；锁定与移除冲突时锁定优先；场景硬规则只替换不追加。
- [x] 添加失败测试：喜欢、太高和不熟可以共存。
- [x] 添加失败测试：完整本地曲库下，高分外部候选仍进入候选池。
- [x] 添加失败测试：外部候选与本地同歌语义去重，且不生成调性、难度、可用性或声线结论。
- [x] 添加失败测试：修改 provisional 候选的占位音域、难度和可用性不会改变排名、理由或风险提示。
- [x] 运行聚焦测试并确认全部红灯对应旧行为。
- [x] 实现精确容量分配、锁定兜底、确定性排序和场景人数约束。
- [x] 外部候选优先纳入候选池，使用规范化键去重并保留 provisional 语义。
- [x] 请求增加时限、取消、playlist id/request id 提交校验。
- [x] 用确定性测试覆盖总时限、取消和旧歌单请求拒写。
- [x] UI 改称“同歌手备选”，补充公开搜索隐私说明。
- [x] 运行聚焦测试至通过。

## 任务 5：当前计划恢复、最近导入与数据删除

**创建文件：**

- `Sources/SingReadyAISharedKit/Storage/WorkflowSnapshotStore.swift`

**修改文件：**

- `Sources/SingReadyAISharedKit/Storage/AppGroupStore.swift`
- `SingReadyAI/App/DemoWorkflowStore.swift`
- `SingReadyAI/App/DemoWorkflowStore+Import.swift`
- `SingReadyAI/App/DemoWorkflowStore+ProductClosure.swift`
- `SingReadyAI/App/Services/SongFeedbackLocalStore.swift`
- `SingReadyAI/Features/ProductFlow/HomeDashboardView.swift`
- `SingReadyAI/Features/ProductFlow/ImportFlowViews.swift`
- `Tests/SingReadyAISharedKitTests/AppGroupStoreTests.swift`
- `Tests/SingReadyAISharedKitTests/ProductClosureTests.swift`
- `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`

- [x] 添加失败测试：版本化快照可保存、恢复并隔离损坏文件。
- [x] 添加失败测试：整理编辑/删除、确认匹配、锁定、移除、场景变化和外部请求完成都会更新快照。
- [x] 添加失败测试：最近导入按 playlist id 覆盖修正版而非新增旧版。
- [x] 添加失败测试：删除/清空会移除对应 JSON、隔离文件、引用截图和孤立截图。
- [x] 添加失败 UI 测试：生成计划重启后可以从首页继续。
- [x] 运行测试并确认失败。
- [x] 实现 `WorkflowSnapshotStore` 与 store 的保存/恢复/清除协调。
- [x] 整理完成时 upsert 最近歌单。
- [x] 首页摘要变成可继续操作入口。
- [x] 导入页增加待处理/最近项删除和清除本机记录确认。
- [x] 运行聚焦测试至通过。

## 任务 6：导入回退、前台刷新与详细文件

**修改文件：**

- `Sources/SingReadyAISharedKit/ImportPipeline/PlaylistResolver.swift`
- `Sources/SingReadyAISharedKit/ImportPipeline/SharePayloadAssembler.swift`
- `Sources/SingReadyAISharedKit/Storage/AppGroupStore.swift`
- `SingReadyAI/App/RootTabView.swift`
- `SingReadyAI/ShareExtension/ShareViewController.swift`
- `SingReadyAI/Features/ProductFlow/ImportFlowViews.swift`
- `SingReadyAI/Features/ProductFlow/ExportStartTipsViews.swift`
- `Tests/SingReadyAISharedKitTests/PlaylistResolverTests.swift`
- `Tests/SingReadyAISharedKitTests/ExporterAndNormalizerTests.swift`
- `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`

- [x] 添加失败测试：带 URL 的分享载荷在公开网页失败后，仅使用同一载荷实际保留的原文解析歌曲。
- [x] 添加失败测试：同一次 Share Extension 输入同时包含 URL 与纯文本时，生成的 payload 同时保留二者。
- [x] 添加失败测试：App Group 不可用或保存失败时，文本/URL 进入手动复制路径，截图提示重新选择，不落入扩展私有后备目录冒充成功。
- [x] 添加失败测试：没有歌曲的纯文本返回可操作错误。
- [x] 添加失败 UI 测试：导出页存在可分享的详细文本文件入口。
- [x] 运行测试并确认失败。
- [x] 将扩展输入合并提取下沉为可测试纯逻辑；生产网络只读取 Apple Music 与网易云官方公开页面，QQ 音乐及其他网页进入文本/截图恢复路径；载荷保留可识别 raw text 时才尝试本地解析。
- [x] App 回到 active 时刷新 pending imports。
- [x] 用 `Transferable` 提供命名明确的详细 `.txt` 文件。
- [x] 运行聚焦测试至通过。

## 任务 7：文档、全量验证与再次深审

**修改文件：**

- `README.md`
- `FINAL_REPORT.md`
- `docs/GAP_ANALYSIS.md`
- `docs/QUALITY_AUDIT.md`
- `docs/MANUAL_QA.md`
- `docs/RECOMMENDATION_EXPLAINABILITY.md`
- `docs/VISUAL_QA.md`
- `ShareExtensionREADME.md`
- `scripts/validate_docs.py`

- [x] 根据 live UI 和代码更新能力边界、测试计数和手动验收。
- [x] 运行 `swift test`，`363/363` 通过。
- [x] 运行新增聚焦 UI 测试，再运行完整 UI 测试，`108/108` 通过。
- [x] 运行通用模拟器 build、截图回归和 `./scripts/validate.sh`，全部通过。
- [x] 运行 `git diff --check` 并核对没有覆盖无关改动。
- [x] 从产品声明、逐歌闭环、冷启动恢复、权限拒绝、慢网、损坏存储和大字号重新审查。
- [x] 开发签名与 App Group 已完成验证；将分发 Archive / Export、完整真机人工验收、最低 iOS 17 runtime、App Store Connect 与第三方保留政策确认单列为发布前外部事项。
