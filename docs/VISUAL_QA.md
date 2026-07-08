# Visual QA

更新时间：2026-07-09 00:27 Asia/Shanghai

## 设计目标

- 第一眼是克制的舞台感，避免高饱和霓虹堆叠。
- 信息层级服务完整流程：导入、确认、匹配、声线、场景、歌单、导出、面试。
- 数据可视化帮助用户理解推荐，而不是装饰。
- 小屏窗口中按钮、标题和说明不能互相遮挡。

## 截图生成

主截图脚本：

```bash
./scripts/capture_ui_test_screenshots.sh
```

脚本会运行 `SingReadyAIUITests.testScreenshotsForCriticalFlow`，启动 10 个关键状态并导出窗口级截图：

- `docs/screenshots/01_onboarding.png`
- `docs/screenshots/02_import_hub.png`
- `docs/screenshots/03_import_review.png`
- `docs/screenshots/04_match_report.png`
- `docs/screenshots/05_voice_setup.png`
- `docs/screenshots/06_voice_result.png`
- `docs/screenshots/07_scenario_builder.png`
- `docs/screenshots/08_song_plan_result.png`
- `docs/screenshots/09_export_center.png`
- `docs/screenshots/10_interview_mode.png`

`scripts/capture_screenshots.sh` 保留为模拟器手动截图辅助；最终审查以 UI test 窗口截图为准。

## 审查 Checklist

- 色彩：coral/cyan 只做强调，背景以午夜黑、深青为主。
- 文字：正文不放在高亮背景上，长内容进入 ScrollView。
- 操作：每页最多一个主操作，次操作用玻璃按钮或图标按钮。
- 布局：顶部阶段栏可横向滚动，当前阶段始终可见。
- 动效：页面切换和声线波形节制，并尊重 Reduce Motion。
- 透明度：Reduce Transparency 下背景和玻璃材质可降级。
- 数据：匹配率、分布、声线、评分解释来自模型字段。

## 第一轮发现

- Onboarding 标题被底部按钮遮挡。
- 导出页启动后继承上一阶段长列表滚动位置，导致“导出中心”标题离屏。
- Onboarding 压缩后底部主按钮仍接近安全区边缘。

## 已执行修复

- Onboarding 去掉 `PageTabView` 的隐式高度挤压，改为明确头部、中段、分页点、底部主按钮布局。
- Onboarding 中段图标和标题降级到小屏可承载尺寸，并使用底部 safe-area padding。
- `ProductFlowShell` 对 `currentPage` 使用 `store.currentStage.id`，阶段切换时重建页面，重置 ScrollView 位置。
- `StepProgressRail` 使用 `ScrollViewReader`，当前阶段切换后自动居中。

## 连续 Clean Review

### Clean Review 1

- 运行 `./scripts/capture_ui_test_screenshots.sh`：通过，10 张截图全部生成。
- 复查 `01_onboarding`：标题、说明、分页点、主按钮完整可见。
- 复查 `02_import_hub`、`03_import_review`、`04_match_report`：阶段栏和首屏内容无遮挡，长内容可滚动。
- 复查 `09_export_center`：标题位于顶部，海报预览在首屏下方露出，不再继承旧滚动位置。
- 复查 `10_interview_mode`：能力标签和首屏文案完整，无按钮重叠。
- 结论：未发现新问题。

### Clean Review 2

- 运行 `./scripts/validate.sh`：通过，包含截图证据校验和通用模拟器构建。
- 复核 10 张最终截图拼图 `Build/visual-review-contact-sheet.jpg` 与关键原图：未发现新的裁切、错页、遮挡或空白渲染。
- 结论：未发现新问题。

## 剩余非阻塞增强

- 导出海报当前是 SwiftUI 预览，后续可增加位图渲染和保存。
- 结果页锁定/移除已有即时重新生成，后续可加入撤销 toast。
