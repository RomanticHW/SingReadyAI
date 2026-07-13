# Product Closure Hardening Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复平台链接、正式真机、系统能力和交付证据缺口，使所有可自动验证功能具备当前证据，并清楚隔离必须人工参与的外部验收。

**Architecture:** 保持现有公开网页解析管线与平台解析器边界。QQ 公开页面没有静态歌曲数据，因此 URL-only 返回平台专用恢复提示，带歌曲原文的分享载荷继续走文本回退；不扩大 synthetic-address 例外。系统功能沿现有服务和 SwiftUI 入口做聚焦测试；所有代码稳定后统一刷新交付产物和文档。

**Tech Stack:** Swift 6、SwiftUI、XCTest/XCUITest、Vision、AVFoundation、Photos、Share Extension、xcodebuild、devicectl。

---

### Task 1: QQ 音乐公开链接闭环

**Files:**
- Modify: `Sources/SingReadyAISharedKit/ImportPipeline/PlaylistResolver.swift`
- Modify: `SingReadyAI/App/DemoWorkflowStore+Import.swift`
- Modify: `Tests/SingReadyAISharedKitTests/PlaylistResolverTests.swift`
- Modify: `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`

- [ ] 在测试文件增加 `UnexpectedCallPlaylistPageFetcher`，其 `pageText` 一旦被调用就抛出 `.parseFailed("unexpected network call")`；增加 `testQQMusicURLOnlyReturnsPlatformSpecificRecoveryBeforeNetwork`，注入该 spy，输入 `https://y.qq.com/n/ryqq/playlist/1374105607`，期望 `.qqMusicRequiresShareText`，并断言文案包含“QQ 音乐”“歌名文字或截图”。
- [ ] 运行 `swift test --filter PlaylistResolverTests.testQQMusicURLOnlyReturnsPlatformSpecificRecoveryBeforeNetwork`，确认当前因 spy 被调用而得到 `.parseFailed`，形成正确红灯。
- [ ] 增加回归 `testQQMusicShareWithSongTextUsesPreservedTextWithoutNetwork`：同样注入 spy，URL 加 `一路向北 - 周杰伦\n旅行的意义 - 陈绮贞`，期望两首歌且来源为 `.qqMusic`；该测试用于约束回退，不要求在生产改动前单独形成第二个红灯。
- [ ] 增加安全回归：`y.qq.com.example.com`、带凭据 QQ URL、私网 URL、混合 public+`198.18.*` DNS、QQ synthetic 地址、QQ 重定向到私网，即使 `sourceHint=.qqMusic` 且带歌曲原文也必须 `.invalidURL`；Apple/网易精确受信 host 的现有例外继续通过。
- [ ] 在解析入口最小实现 QQ URL-only 专用错误，不新增 QQ synthetic host，也不调用私有接口；应用层映射为可操作提示。
- [ ] 增加 UI 测试 `testQQMusicURLFailureOffersTextAndScreenshotRecovery`，验证按钮点击后可见反馈且仍可编辑输入。
- [ ] 运行上述聚焦 Swift/UI 测试，再运行 `swift test`，期望全部通过。

### Task 2: 跨平台链接真实回归

**Files:**
- Modify: `Tests/SingReadyAISharedKitTests/PlaylistResolverTests.swift`
- Fixture: existing deterministic HTML fixtures in `Tests/SingReadyAISharedKitTests/PlaylistResolverTests.swift`
- Runtime evidence: `Build/RuntimeProbes/2026-07-11/`（gitignored，只保存脱敏状态、数量和错误类型，不保存第三方页面或原始响应头）

- [ ] 在临时目录分别执行三条探针，固定 UA 为 `Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148`；URL 分别为 Apple `https://music.apple.com/us/playlist/%E5%96%9C%E7%88%B1%E6%AD%8C%E6%9B%B2/pl.u-vvUz36Y7Lv?l=zh`、网易 `https://163cn.tv/baQqV8be`、QQ `https://y.qq.com/n/ryqq/playlist/1374105607`。命令形式固定为 `tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; curl -L --max-time 20 --compressed -A "$UA" -sS -o "$tmp/body" -w 'final_url=%{url_effective}\nhttp_status=%{http_code}\nbody_bytes=%{size_download}\n' "$URL" > Build/RuntimeProbes/2026-07-11/<platform>-summary.txt`；随后追加 `timestamp_utc` 和产品解析的 `parse_result`。不使用 `-D`，临时 body 在 shell 退出时删除。
- [ ] 在线 smoke 不进入确定性门禁；把确认的页面结构裁成最小脱敏 fixture，契约测试只依赖 fixture。
- [ ] 若在线 smoke 发现新结构缺口，先增加对应 fixture 失败测试，再修改平台解析器。
- [ ] 运行 `swift test --filter PlaylistResolverTests`，期望所有确定性契约通过；在线 smoke 单独报告第三方页面可达性。

### Task 2A: 关闭任意域名 DNS rebinding 边界

**Files:**
- Modify: `Sources/SingReadyAISharedKit/ImportPipeline/PlaylistResolver.swift`
- Modify: `Sources/SingReadyAISharedKit/ImportPipeline/ShareProviderDetector.swift`
- Modify: `Tests/SingReadyAISharedKitTests/PlaylistResolverTests.swift`

- [ ] 增加红灯 `testProductionFetcherRejectsUnknownPublicHostBeforeDNSOrTransport`：为 host resolver 和 data loader 加调用计数，输入 `https://music.example.com/playlist`，期望 `.unsupportedPublicWebHost` 且两个计数均为 0。
- [ ] 增加红灯 `testProductionFetcherRejectsRedirectOutsideSupportedMusicHosts`：初始 Apple/网易 host 跳转到 `https://example.com/...` 时必须 `.invalidURL`，不能跟随。
- [ ] 把 canonical host 规范化与匹配集中成一个真源；生产可抓取集合只包含 Apple Music 与网易云公开 host，QQ 由网络前分支处理。普通域名、伪造子域、前导点、非受信重定向均不发请求。删除 URLSession 前无法绑定到实际连接的 DNS 预检，受信官方 host 依赖 HTTPS 系统证书校验，不保留重复 DNS 查询的伪安全流程。
- [ ] 增加 `.unsupportedPublicWebHost` 可操作文案：“目前只直接读取 Apple Music 和网易云公开歌单；其他网页请粘贴歌名文字或发截图”。更新 README/手动验收中的“任意公开静态网页”承诺。
- [ ] 运行聚焦与全量 Swift 测试，并再次进行规格与代码质量复核；不得以重复 DNS 查询冒充关闭 TOCTOU。

### Task 3: 正式标识真机与系统能力

**Files:**
- Modify only after static contract test fails for a repo defect: `project.yml`, entitlements and signing configuration.
- Test: focused UI tests under `UITests/SingReadyAIUITests/SingReadyAIUITests.swift`.

- [ ] 创建 `Build/ClosureEvidence/`，把 `security find-identity -v -p codesigning` 保存为 `signing-identities.txt`；正式构建完整输出分别保存为 `formal-debug-build.log` 和 `formal-release-build.log`。若失败，日志必须保留 `No Accounts`/profile 等原始错误。
- [ ] 运行 `python3 scripts/validate_plist.py` 验证源码静态合同；`scripts/validate_release.py` 只用于签名 Release 产物，不用于含测试启动钩子的 Debug 产物。
- [ ] 若仓库配置确有缺陷，先在 `scripts/test_delivery_gates.py` 增加失败合同测试，再修改 `project.yml`/entitlements；若是 Xcode Account/profile 外部阻塞，不把旧 `com.example` 作为替代结果。
- [ ] Debug 系统能力构建：`set -o pipefail; xcodebuild build -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -configuration Debug -destination 'platform=iOS,id=00008150-001A0C5A2284401C' -derivedDataPath Build/FormalDeviceDebug -allowProvisioningUpdates 2>&1 | tee Build/ClosureEvidence/formal-debug-build.log`。
- [ ] Release 产物构建：`set -o pipefail; xcodebuild build -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -configuration Release -destination 'platform=iOS,id=00008150-001A0C5A2284401C' -derivedDataPath Build/FormalDeviceRelease -allowProvisioningUpdates 2>&1 | tee Build/ClosureEvidence/formal-release-build.log`；对 `Build/FormalDeviceRelease/Build/Products/Release-iphoneos/SingReadyAIApp.app` 运行 `python3 scripts/validate_release.py Build/FormalDeviceRelease/Build/Products/Release-iphoneos/SingReadyAIApp.app`。
- [ ] 用 `codesign -d --entitlements :- Build/FormalDeviceDebug/Build/Products/Debug-iphoneos/SingReadyAIApp.app > Build/ClosureEvidence/app-entitlements.plist 2>&1` 和 `codesign -d --entitlements :- Build/FormalDeviceDebug/Build/Products/Debug-iphoneos/SingReadyAIApp.app/PlugIns/SingReadyAIShareExtension.appex > Build/ClosureEvidence/share-extension-entitlements.plist 2>&1`。期望 `application-identifier` 分别为 `7UGQ23VSF7.com.huangwei.singreadyai`、`7UGQ23VSF7.com.huangwei.singreadyai.shareextension`，两者 `com.apple.security.application-groups` 都只有 `group.com.huangwei.singreadyai`。
- [ ] 安装与启动使用 `set -o pipefail`：`xcrun devicectl device install app --device 73070EF4-B03F-5210-97DD-069DA3B0A16B Build/FormalDeviceDebug/Build/Products/Debug-iphoneos/SingReadyAIApp.app 2>&1 | tee Build/ClosureEvidence/device-install.txt`，再 `xcrun devicectl device process launch --device 73070EF4-B03F-5210-97DD-069DA3B0A16B com.huangwei.singreadyai 2>&1 | tee Build/ClosureEvidence/device-launch.txt`。运行 `xcrun devicectl device info apps --device 73070EF4-B03F-5210-97DD-069DA3B0A16B > Build/ClosureEvidence/device-apps.txt 2>&1` 和对应 `device info processes` 命令生成 `device-processes.txt`。
- [ ] 模拟器重置权限：`xcrun simctl privacy 1218EBD6-C2E9-4EC7-BAD4-A9A07AABA453 reset all com.huangwei.singreadyai`。聚焦 UI 命令为 `xcodebuild test -project SingReadyAI.xcodeproj -scheme SingReadyAIApp -destination 'id=1218EBD6-C2E9-4EC7-BAD4-A9A07AABA453' -resultBundlePath Build/Closure-SystemUI.xcresult -only-testing:SingReadyAIUITests/SingReadyAIUITests/testPhotoPickerCanOpenAndClose -only-testing:SingReadyAIUITests/SingReadyAIUITests/testShareSheetCanOpenAndClose -only-testing:SingReadyAIUITests/SingReadyAIUITests/testShareExtensionReceivesSharedPlaylist -only-testing:SingReadyAIUITests/SingReadyAIUITests/testMicrophoneDeniedOffersSettingsAndFallback -only-testing:SingReadyAIUITests/SingReadyAIUITests/testFirstMicrophoneGrantContinuesPastPermissionRequest -only-testing:SingReadyAIUITests/SingReadyAIUITests/testPosterPermissionDeniedOffersSettingsAndShareFallback`。
- [ ] 真机人工输入项：用一张真实歌单截图完成 OCR；允许麦克风并唱 10 秒得到有效音区；允许相册并确认海报出现在照片；从网易/Apple Music 分享到扩展；点击搜索确认切到 Apple Music。逐项把日期、设备、结果写入 `docs/MANUAL_QA.md`。

### Task 4: 交付证据与文档同步

**Files:**
- Modify: `FINAL_REPORT.md`
- Modify: `docs/MANUAL_QA.md`
- Modify: `README.md`
- Regenerate: `docs/screenshots/`, `docs/screenshots-large-text/`, metadata.
- Modify if required: `scripts/validate_docs.py`.

- [ ] 在 `scripts/test_delivery_gates.py` 增加临时文档 fixture 测试 `test_docs_validator_rejects_stale_test_counts_and_screenshot_claims`，调用待新增的纯函数 `validate_report_facts(report_text, swift_count, ui_count, screenshots_current)`；fixture 写 `345/345`、`106/106` 且 `screenshots_current=False`，期望返回三个错误。先运行确认因函数缺失形成红灯。
- [ ] 最小修改 `scripts/validate_docs.py`：新增上述纯函数；Swift 数直接统计 `Tests/SingReadyAISharedKitTests/*.swift` 中 `^[[:space:]]+func test`，UI 数统计 `UITests/SingReadyAIUITests/SingReadyAIUITests.swift` 同模式，截图状态复用当前 digest 校验；先让 fixture 测试通过，再更新真实报告并运行完整文档门禁。
- [ ] 常规截图：`RESULT_BUNDLE=Build/Closure-Screenshot-Large.xcresult EXPORT_DIR=Build/Closure-Screenshot-Large SCREENSHOT_DIR=docs/screenshots CONTENT_SIZE=large ./scripts/capture_ui_test_screenshots.sh`。
- [ ] 最大辅助字号截图：`RESULT_BUNDLE=Build/Closure-Screenshot-AXXXL.xcresult EXPORT_DIR=Build/Closure-Screenshot-AXXXL SCREENSHOT_DIR=docs/screenshots-large-text CONTENT_SIZE=accessibility-extra-extra-extra-large ./scripts/capture_ui_test_screenshots.sh`。
- [ ] 运行 `python3 scripts/validate_screenshots.py`，必须确认两套各 11 张、来源指纹和尺寸通过。
- [ ] 更新 `FINAL_REPORT.md`、`docs/MANUAL_QA.md`、`README.md`：测试数使用当前实际值，真机只写正式标识证据，外部阻塞与人工边界保留。
- [ ] 完整 UI：`RESULT_BUNDLE=Build/Closure-FullUI.xcresult ./scripts/run_ui_tests.sh`。源码计数用 `rg -c '^[[:space:]]+func test' UITests/SingReadyAIUITests/SingReadyAIUITests.swift`；结果用 `xcrun xcresulttool get test-results summary --path Build/Closure-FullUI.xcresult --format json` 读取 `totalTestCount`、`failedTests`、`result`，要求源码计数和执行数都不少于 `107`、两者相等、失败为 `0`、结果为 `Passed`。
- [ ] 最终运行 `./scripts/validate.sh`、`git diff --check`。其中无签名 device-SDK Release 只证明编译；正式签名真机必须单独满足 Task 3。

### Task 5: 再次深审与循环修复

- [ ] 逐项对照产品入口、外部依赖、持久化和系统权限清单。
- [ ] 对新发现的真实缺陷重复红—绿—全量回归。
- [ ] 只有当前完整门禁和所有可执行验收通过后才给出完成结论。
