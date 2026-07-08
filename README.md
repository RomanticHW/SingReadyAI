# SingReadyAI / 今晚唱什么

作品集级 iOS Demo：面向 KTV、车载 K 歌、朋友聚会、生日局和团建局的本地 AI 歌单助手。它不连接真实 KTV 硬件，不抓取音乐平台私有接口，不包含音频、歌词、MV 或版权封面；所有演示数据都来自用户主动分享内容、fixture 和 mock KTV 曲库。

## Demo 能力

- Share Extension：接收 `public.url`、`public.plain-text`、`public.image`，通过 App Group 写入 `pending_imports.json`，App Group 不可用时显示开发模式 fallback。
- 导入解析：支持网易云音乐、QQ 音乐、Apple Music、普通链接、粘贴文本、截图 OCR 和 Demo 歌单。
- Import Review：展示解析歌曲，支持编辑歌名/歌手、删除低置信度条目，再进入 KTV 曲库匹配。
- KTV 匹配：215 首 mock KTV 曲库，支持精确、别名、艺人别名、括号版本清洗、模糊和替代推荐。
- 偏好画像：高频歌手、语种、年代、曲风、情绪、场景适配、可唱率、难度、高音风险和合唱友好度。
- 声线分析：真机录音权限/倒计时/音量动画路径 + 模拟声线 fallback；PitchDetector 覆盖静音过滤、频率范围、MIDI、分位数稳定音域和声线类型。
- 推荐编排：支持朋友局、生日局、团建局、车载 K 歌、情侣局、独自练歌；每首歌保存分项评分、推荐理由、风险提示和替代曲。
- 交互：锁定歌曲、移除补位、重新生成、切换场景重新生成。
- 导出：整洁文本、完整 JSON、海报预览、系统分享、面试模式。

## 运行

```bash
swift test
xcodegen generate
open SingReadyAI.xcodeproj
```

在 Xcode 中选择 `SingReadyAIApp` scheme，使用 iOS 17+ 模拟器或真机构建运行。

命令行验证示例：

```bash
./scripts/capture_ui_test_screenshots.sh
./scripts/validate.sh
```

单独构建示例：

```bash
xcodebuild -scheme SingReadyAIApp \
  -project SingReadyAI.xcodeproj \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

如果本机没有 `iPhone 17`，先运行：

```bash
xcodebuild -showdestinations -scheme SingReadyAIApp -project SingReadyAI.xcodeproj
```

然后替换为可用模拟器名称。

## 演示路径

1. 首次打开进入 Onboarding。
2. 在 Import Hub 点击 `使用 Demo 歌单`，也可以粘贴文本或选择截图 OCR。
3. 在 Import Review 修正低置信度条目，点击 `开始匹配 KTV 曲库`。
4. 查看 Match Report：可唱率、匹配分类、偏好画像和场景适配。
5. 进入 Voice Setup，使用模拟声线或真机录音流程。
6. 在 Scenario Builder 选择朋友局、生日局、团建局、车载 K 歌、情侣局或独自练歌。
7. 查看 Song Plan Result：分段、理由、风险、替代曲、评分解释、锁定/删除/重新生成。
8. 在 Export Center 复制文本、查看 JSON、预览海报并进入 Interview Mode。

## 工程结构

- `Sources/SingReadyAISharedKit`：可测试业务核心。
- `SingReadyAI/App`：App 入口、流程状态、设计组件。
- `SingReadyAI/Features/ProductFlow`：作品级完整产品流程页面。
- `SingReadyAI/ShareExtension`：分享扩展 UI、payload 提取和 App Group 存储。
- `Tests/SingReadyAISharedKitTests`：解析、匹配、画像、声线、推荐、导出、曲库测试。
- `docs`：差距分析、手动 QA、面试脚本。

## 文档

- [GAP_ANALYSIS.md](docs/GAP_ANALYSIS.md)
- [MANUAL_QA.md](docs/MANUAL_QA.md)
- [INTERVIEW_SCRIPT.md](docs/INTERVIEW_SCRIPT.md)
- [QUALITY_AUDIT.md](docs/QUALITY_AUDIT.md)
- [VISUAL_QA.md](docs/VISUAL_QA.md)
- [ShareExtensionREADME.md](ShareExtensionREADME.md)
- [FINAL_REPORT.md](FINAL_REPORT.md)

## 边界

- 不接入真实雷石设备协议。
- 不抓取网易云音乐、QQ 音乐等第三方私有接口。
- 不包含真实音乐音频、歌词、MV 或版权封面。
- iOS 端不硬编码 API Key。
- 离线可演示；真实平台解析失败时使用 fixture、OCR 或文本 fallback。
