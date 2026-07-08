# Design System

## 目标

SingReadyAI / 今晚唱什么采用 dark-first、cinematic、premium、calm neon 的视觉方向。界面要像认真设计过的 iOS 工具，而不是信息堆叠页：每个页面只有一个主焦点，数据可视化服务于推荐可信度，舞台感背景不抢正文可读性。

## Token

- 色彩：`ColorTokens` 定义舞台黑、午夜蓝、深青、coral 主强调、cyan 辅助强调、amber 警示强调、success/warning/danger 语义色。
- 字体：`TypographyTokens` 使用系统字体，按 hero/title/section/body/callout/caption/metric 分层；关键数值使用 `monospacedDigit`。
- 间距：`SpacingTokens` 使用 4/8/12/16/20/28 的 8pt 友好网格。
- 圆角：`ComponentTokens` 统一 small/medium/large，按钮和标签更紧凑，核心卡片更舒展。
- 动效：`MotionTokens` 使用微交互、页面切换、结果 reveal 三类节奏；复杂动效必须尊重 Reduce Motion。

## 组件

- `PremiumBackground`：深色空间背景和克制舞台光。
- `GlassCard`：带 Reduce Transparency fallback 的玻璃卡片。
- `HeroHeader`：页面主标题区。
- `StepProgressRail`：流程进度入口。
- `PrimaryGradientButton` / `SecondaryGlassButton`：主次操作。
- `SourceBadge`、`ConfidenceMeter`、`MatchRateRing`、`MetricPill`、`MetricBar`、`TagCloud`：数据表达。
- `PreferenceInsightCard`、`VoiceRangeVisualizer`、`LiveWaveformView`、`ScenarioCard`、`SongPlanTimeline`、`SongRecommendationCard`、`ScoreBreakdownView`、`RiskBadge`、`AlternativeSongChips`：核心业务展示。
- `PosterPreviewView`、`EmptyStateView`、`ErrorStateView`、`LoadingStateView`、`PrivacyNoteView`、`InterviewScriptCard`：状态、导出和面试表达。

## 约束

- 页面文件不直接定义硬编码主色、字号、卡片背景和小圆角。
- 透明和舞台光必须有 Reduce Transparency fallback。
- 录音波形、页面切换和结果 reveal 必须有 Reduce Motion fallback 或保持低频。
- 不使用第三方平台 logo、真实音乐封面、歌词、MV 或版权素材。
- 主要按钮和关键行为必须有可读 label，不能只用颜色传达状态。
