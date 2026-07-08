# Quality Audit

更新时间：2026-07-09 00:27 Asia/Shanghai

## 审查范围

- 本地运行 iOS App，并用 UI test 启动 10 个关键状态截图。
- 审查产品流程、布局、交互、动效、可访问性、代码结构、性能预算、配置、文档一致性和可重复验证能力。
- 修复后重复验证，直到连续两轮完整复查未发现新问题。

## 初始发现

- P0：Share Extension `Info.plist` 缺少真实 `NSExtension` 注册信息。
- P0：App 录音权限用途文案缺失。
- P0：录音链路只做计时和音量展示，最终仍使用模拟声线。
- P1：设计系统散落在页面文件中，缺少独立 token 和组件层。
- P1：`ProductFlowViews.swift` 超过 1000 行，页面、状态和组件耦合。
- P1：旧四 Tab 页面仍在 target 中，视觉和文案与新流程冲突。
- P1：缺少真实截图证据和 UI test 覆盖。
- P1：文档声称的验证结果与当前代码不一致。

## 修复结果

- 补齐 Share Extension activation rule、principal class、display name 和 App Group 配置。
- App target 补齐麦克风隐私用途文案。
- 新增 `VoiceRecordingService` 和 `AudioFrameSplitter`，真机使用 `AVAudioEngine` tap 收集 10 秒 PCM 样本并进入 `PitchDetector` 分析；模拟声线只保留为明确 fallback。
- 拆出 `SingReadyAI/App/DesignSystem`，包含颜色、字体、间距、动效、组件、无障碍和材质 token。
- 删除旧四 Tab 页面，按流程拆分 Onboarding、Import、Match/Voice/Scenario、Result/Export/Interview。
- 新增 UI test target 与 `scripts/capture_ui_test_screenshots.sh`，覆盖 onboarding、导入、确认、匹配、声线、场景、歌单、导出、面试 10 个状态。
- 新增本地质量门禁脚本，覆盖 Swift tests、fixture、plist/privacy、docs、design、performance、screenshots、XcodeGen 和通用模拟器构建。

## 修复中发现并解决的回归

- Onboarding 标题在真实窗口截图中被底部按钮遮挡：改为明确分区布局、自定义分页点和滑动手势。
- 导出页从 demo stage 启动时继承上一阶段长列表滚动位置，导致标题离屏：给 `currentPage` 增加 stage id，阶段切换重建页面并重置滚动。
- Onboarding 修复后主按钮底部仍接近安全区边缘：压缩中段视觉元素并使用底部 safe-area padding。

## 最终验证

- `./scripts/capture_ui_test_screenshots.sh`：通过，1 个 UI test 覆盖 10 个关键状态，导出 10 张窗口截图到 `docs/screenshots/`。
- `./scripts/validate.sh`：通过。
- `swift test`：通过，50 个测试，0 失败。
- `scripts/validate_catalog.py`：通过，215 首曲库。
- `scripts/validate_plist.py`：通过。
- `scripts/validate_docs.py`：通过。
- `scripts/validate_design.py`：通过，`DemoWorkflowStore.swift` 406 行为 warning，不阻塞。
- `scripts/validate_performance_budget.py`：通过。
- `scripts/validate_screenshots.py`：通过，10 张 PNG。
- `xcodegen generate`：通过。
- `xcodebuild -scheme SingReadyAIApp -project SingReadyAI.xcodeproj -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`：通过。

## 最终结论

当前 diff 已具备本地可重复验证能力，关键用户路径可运行、可截图、可审查。最后两轮复查未发现新的 P0/P1 问题；剩余事项属于后续增强，例如真实平台授权曲库同步、后端化文案改写和导出海报位图保存。
