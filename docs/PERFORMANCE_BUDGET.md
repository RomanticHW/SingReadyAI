# 性能预算

## 启动和首屏

- 目标：冷启动后首屏进入引导页或导入页，离线可用。
- 首页不依赖网络；曲库为本地 fixture。
- `DemoWorkflowStore` 初始化会加载 215 首 JSON 本地参考 fixture，当前规模可接受；它不代表实时平台曲库。未来扩大数据规模时应改为后台异步加载或索引缓存。

## JSON 加载

- 目标：示例歌单导入到整理页主观瞬时。
- 曲库 JSON 校验由 `scripts/validate_catalog.py` 保证字段完整。
- SwiftUI View body 不做 `JSONDecoder` 或 `Data(contentsOf:)`。

## 推荐生成

- 目标：当前 215 首本地参考 fixture 内推荐生成 1 秒内完成。
- 当前 `RecommendationEngine` 在本地规则内完成候选构建、排序、硬规则和备选歌选择。
- 大曲库扩展方向：预建 title/artist/scene/genre 索引，避免重复全表扫描。

## OCR 处理

- Vision OCR 在用户选择截图后异步执行；失败给出粘贴文本兜底路径。
- 测试使用协议 fake，不依赖真实系统 OCR。

## 音乐平台链接读取

- 生产网络只请求 Apple Music 与网易云官方公开 HTTPS 页面，并逐跳限制官方主机、响应类型和响应体大小；QQ 音乐纯链接及其他网页不发起读取。
- 请求有总时限和取消路径；只有分享载荷保留可识别歌名原文时，失败后才继续做本地文本解析。

## 录音分析

- 真机录音使用 `AVAudioEngine` tap 收集 10 秒 mono PCM 样本。
- PCM 只在内存处理，不保存原始音频。
- `AudioFrameSplitter` 切 4096 frame / 2048 hop，调用 `PitchDetector.analyzeFrames`。
- 有效样本不足时返回可恢复错误，用户可重试，也可以先按常见音域排歌。

## 动效

- 微交互控制在 120ms 到 220ms。
- 页面切换和 reveal 使用 SwiftUI 原生动画。
- `PremiumBackground`、`LiveWaveformView` 读取 Reduce Motion，减少复杂变化。

## 内存

- 不保存原始录音文件。
- 海报在导出页预览，用户保存时才渲染为图片，避免反复大尺寸位图渲染。
- 导出 JSON 和文本在用户进入导出页时生成，规模随歌单数量线性增长。

## 大列表渲染

- 主流程容器使用 `LazyVStack`。
- 标签和场景选项使用 `LazyVGrid`。
- 结果页分段渲染，单次歌单控制在可扫读范围。

## 透明材质策略

- `GlassCard` 在 Reduce Transparency 打开时使用实色面板。
- 背景舞台光不承载信息，不影响正文对比度。

## Reduce Motion

- `PremiumBackground` 降低动态视觉权重。
- `LiveWaveformView` 在 Reduce Motion 下移除相位增量，只展示实时音量。

## Reduce Transparency

- `PremiumBackground` 关闭附加光效。
- `GlassCard` 使用 `cardBackgroundSolid`，确保文字对比稳定。
- `LiquidGlassSurface` 和分享扩展玻璃面使用同形实色背景降级，圆角和边线不跳变。
