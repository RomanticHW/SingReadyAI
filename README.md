# SingReadyAI / 今晚唱什么

作品级 iOS 应用：面向 KTV、车载 K 歌、朋友聚会、生日局和团建局的本地歌单助手。它不连接真实 KTV 硬件，不抓取音乐平台私有接口，不包含音频、歌词、MV 或版权封面；当前结果来自用户主动分享或粘贴的内容、内置示例、用于早期验证的本地参考曲库，以及用户主动触发的 Apple 公开元数据搜索。

## 功能范围

- Share Extension：接收 `public.url`、`public.plain-text`、`public.image`，源码、entitlements 与 Bundle 合同通过 App Group 把待整理内容交给主 App；URL 与文本表示并行读取，单个表示挂起不会阻塞已经可用的原文。读取中可取消，整体读取有时限；共享容器不可用或读取超时时不会伪装成已保存，链接或文本可手动复制回 App，截图需要重新选择。正式标识的开发签名、共享 App Group、安装与启动已经验证；分发 Archive 仍需上架前单独完成。
- 导入解析：支持粘贴链接或文本、截图识别和示例歌单。Apple Music 与网易云音乐官方公开链接可直接解析，重定向逐跳限制在对应官方 HTTPS 主机；QQ 音乐纯链接会立即提示改用分享原文或截图，其他网页不会发起读取。分享载荷保留可识别歌名原文时，可继续做本地文本解析。导入可单独取消或超时，不会因此清空已有计划和历史；已完成结果不会被迟到超时覆盖。
- 歌名单整理：展示解析出的歌曲，支持编辑歌名/歌手、删除不想保留的条目；空歌名会明确提示并阻止进入本地参考匹配。
- 参考匹配：215 首本地参考曲库 fixture，支持歌名、别名、艺人别名、括号版本清洗和替代建议；它用于验证整理、匹配和推荐逻辑，不代表任一地区、门店或设备的实时可点情况。
- 偏好画像：基于已确认的本地参考匹配汇总高频歌手、语种、年代、曲风、情绪、场景适配、难度、高音风险和合唱友好度；待确认候选不计入确定性结论。
- 同歌手候选：运行时从最多 4 首种子歌曲中提取歌手，只把歌手名称发送到 Apple 公开搜索，查找同艺人公开曲目；这不是音乐相似度算法，候选的 KTV 收录、音域、难度和现场适配均标记为待核对。确认本地匹配或采用替代歌不会清空已经取得的公开候选。
- 声线分析：真机录音权限、倒计时和音量反馈，原始录音仅在内存中用于音高分析且不会保存；最近一次有效实测音区结果只保存在本机，即使未导入歌单也可跨重启恢复。未测时使用单独标记的“常见音域参考”，它不会写成个人实测记录、冒充用户实测或输出精确调性结论。
- 推荐编排：支持朋友局、生日局、团建局、车载 K 歌、情侣局、独自练歌；人数、声线、反馈会影响排序，每首歌保留推荐理由、演唱建议和替代曲。已有导入但尚未核对时会先基于当前内容建立匹配，不会静默换成热门示例；车载场景至少两人，确保由乘客操作手机。
- 导航层级：使用原生 `NavigationStack`，保留系统返回按钮和左缘滑动返回；流程内前进可回上一页，全局功能切换则回到首页层级。
- 交互：锁定歌曲、移除补位、逐首/全部恢复已移除歌曲、重新生成、切换场景重新生成、打开搜索、复制歌名、本地反馈重排。歌名、场景、声线或外部候选变化后，旧计划会失效并要求重新生成。
- 恢复与数据管理：当前整理进度、已生成计划和最近一次有效实测音区结果可跨重启恢复；工作流快照没有有效实测音区时，会恢复独立保存的本机实测结果，不让常见参考覆盖个人测量。整理结果按同一歌单 ID 回写最近导入，并支持删除单条待处理内容、删除单条最近导入和清除全部本机记录（含本机音区结果）。分享待处理项只有在最近导入或当前快照至少一处确认落盘后才会被消费，双写失败时原内容保持可重试。
- 导出：群聊精简文本、UTF-8 详细 `.txt` 文件、海报预览、保存海报、系统分享和按场景生成的开唱小抄；详细文件包含分段目标、来源、可用的推荐理由、注意事项和备选歌。独自练歌、情侣局和车载场景不会复用多人聚会指令，车载小抄明确由乘客操作手机。
- 隐私：应用内首页可直接打开随包提供的离线完整隐私政策；截图 OCR 与音区分析在本机完成，原始录音不保存。用户主动找同歌手候选时只向 Apple iTunes Search 发送歌手名称；用户主动打开单曲搜索时，Apple Music 搜索链接包含歌名和歌手。完整说明见 [PRIVACY.md](PRIVACY.md)。

## 运行

```bash
swift test
open SingReadyAI.xcodeproj
```

在 Xcode 中选择 `SingReadyAIApp` scheme，使用 iOS 17+ 模拟器或真机构建运行。

若本机已安装 `xcodegen`，可在打开项目前先运行 `xcodegen generate`；未安装时直接使用仓库内已经验证的 `SingReadyAI.xcodeproj`。

命令行验证示例：

```bash
RESULT_BUNDLE=Build/ScreenshotQA-Large.xcresult \
EXPORT_DIR=Build/ScreenshotQA-Large \
SCREENSHOT_DIR=docs/screenshots \
CONTENT_SIZE=large \
./scripts/capture_ui_test_screenshots.sh

RESULT_BUNDLE=Build/ScreenshotQA-AXXXL.xcresult \
EXPORT_DIR=Build/ScreenshotQA-AXXXL \
SCREENSHOT_DIR=docs/screenshots-large-text \
CONTENT_SIZE=accessibility-extra-extra-extra-large \
./scripts/capture_ui_test_screenshots.sh

./scripts/validate.sh
```

两次截图分别生成常规字号与最大辅助字号证据；`validate.sh` 会同时检查两套各 11 张截图是否完整，并用源码树 SHA-256 摘要确认截图确实来自当前实现。完整门禁还包含 Swift 包测试、iOS 单测、模拟器 Release、device-SDK Release、隐私清单和 Bundle 合同校验。

## 当前验证

2026-07-12 最终源码的结果：Swift Package `363/363`、交付脚本 `60/60`、Xcode iOS 单元测试 `357/357`、完整 UI `108/108`，常规字号与最大辅助字号截图 `11+11`。两套截图已通过源码指纹校验。iOS 26.5 模拟器上的系统能力聚焦回归 `6/6`，覆盖麦克风允许/拒绝、相册拒绝、照片选择器、系统分享面板和 Safari → Share Extension → App Group → 主 App 往返。本轮最终验收按要求仅使用模拟器；先前开发签名构建的真机安装不作为本轮通过依据。分发 Archive、完整真机人工验收，以及最低声明版本 iOS 17 的运行时兼容性仍需另行验证。

单独构建示例：

```bash
xcodebuild -scheme SingReadyAIApp \
  -project SingReadyAI.xcodeproj \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

截图和完整 UI 回归脚本默认使用 `iPhone Air`。如果本机没有该模拟器，先运行：

```bash
xcodebuild -showdestinations -scheme SingReadyAIApp -project SingReadyAI.xcodeproj
```

然后通过 `DESTINATION='platform=iOS Simulator,name=<可用名称>'` 运行对应脚本。

## 主要入口

- 我有歌单：导入链接、截图或文本，整理歌名，再逐首核对本地参考匹配和待确认候选。
- 唱前准备：可以测一下音域，也可以直接按朋友局、生日局、车载 K 歌等场景排一版。
- 到了现场：查看今晚歌单、发给朋友、保存海报，或者打开开唱小抄处理冷场和接歌。

## 工程结构

- `Sources/SingReadyAISharedKit`：可测试业务核心。
- `SingReadyAI/App`：应用入口、功能状态、设计组件。
- `SingReadyAI/Features/ProductFlow`：主要功能页面。
- `SingReadyAI/ShareExtension`：分享扩展 UI、payload 提取和 App Group 存储。
- `Tests/SingReadyAISharedKitTests`：解析、匹配、画像、声线、推荐、导出、曲库测试。
- `docs`：差距分析、手动 QA、开唱小抄脚本。

## 文档

- [PRIVACY.md](PRIVACY.md)
- [GAP_ANALYSIS.md](docs/GAP_ANALYSIS.md)
- [MANUAL_QA.md](docs/MANUAL_QA.md)
- [START_TIPS_SCRIPT.md](docs/START_TIPS_SCRIPT.md)
- [QUALITY_AUDIT.md](docs/QUALITY_AUDIT.md)
- [VISUAL_QA.md](docs/VISUAL_QA.md)
- [ShareExtensionREADME.md](ShareExtensionREADME.md)
- [FINAL_REPORT.md](FINAL_REPORT.md)

## 边界

- 不接入真实厂商设备协议。
- 不抓取网易云音乐、QQ 音乐等第三方私有接口。
- 不包含真实音乐音频、歌词、MV 或版权封面。
- 外部音乐数据只用于元数据和搜索跳转；不提供播放、下载、歌词或封面复用。
- iOS 端不硬编码 API Key。
- 215 首本地参考曲库和示例歌单仅用于 early-validation，不代表实时平台曲库或场所可唱情况。
- 本地整理、参考匹配和推荐可离线运行；受支持的 Apple Music/网易云官方链接读取与 Apple 同歌手搜索需要网络。QQ 音乐或其他网页不会作为通用网页抓取入口；链接失败时不会自动替换成示例数据，只有载荷中保留的可识别歌名原文可用于文本回退。
- 当前仓库达到代码、自动化、模拟器系统流程和开发签名安装范围的交付标准，但尚不是可直接上架状态：仍需完成分发证书 Archive / Export、完整真机人工验收、App Store Connect 元数据与公开稳定的隐私政策 URL，以及第三方数据保留政策人工确认。
