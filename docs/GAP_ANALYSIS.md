# SingReadyAI Gap Analysis

## Current Capability

- Swift Package exists with `SingReadyAISharedKit` for import parsing, provider detection, KTV catalog matching, preference profiling, pitch detection, recommendation, storage, OCR abstraction, and exporters.
- `project.yml` can describe an iOS app target, Share Extension target, and iOS unit test target.
- The app currently runs as a four-tab MVP: import, profile, generate, export.
- Demo import, pasted text import, basic OCR import, pending App Group imports, matching, preference profile, simulated voice, scenario generation, text export, and JSON export exist.
- Share Extension source reads URL, plain text, and image attachments from `NSExtensionContext`, writes `pending_imports.json`, and uses fallback storage when App Group is unavailable.
- Vision OCR service already exists behind conditional compilation with a mock service fallback.
- Unit tests exist for provider detection, parser, matcher, recommendation, and pitch detection.

## Missing Capability

- The app does not yet have the requested first-run onboarding and guided product flow.
- Import review is not a separate editable confirmation step; low-confidence items are displayed but not fixable.
- Match report is embedded in the profile tab and lacks full distribution, risk, and next-step guidance.
- Voice setup is simulator-friendly but lacks a real recording UI flow, countdown, level animation, and permission/error states.
- Scenario configuration covers only four scenarios and fewer atmosphere options than required.
- Recommendation items lack persisted score breakdown fields and lock/remove/regenerate interactions.
- Export is functional but not yet packaged as an export center with poster preview and interview script entry.
- Interview mode is missing from the app UI.
- The KTV fixture catalog has 80 tracks, below the required 180.
- Tests are below the requested breadth for parser, matcher, pitch detection, and recommendation rules.
- Share Extension `Info.plist` lacks complete extension activation metadata and the UI does not show enough received-content detail.
- Documentation is missing `ShareExtensionREADME.md`, `MANUAL_QA.md`, `INTERVIEW_SCRIPT.md`, and `FINAL_REPORT.md`.

## High-Risk Points

- Xcode app build may fail if generated project settings diverge from Swift Package resources, extension metadata, or code signing expectations.
- Large fixture expansion can introduce invalid JSON or duplicate IDs unless generated and validated.
- SwiftUI page migration touches many files and can cause compile errors through missing environment state.
- Real audio capture depends on simulator/device capabilities, so a robust mock fallback must remain available.
- Vision OCR may not be available in all test environments; tests must rely on protocol-level fakes.

## This Round Plan

1. Preserve the existing package-first architecture and upgrade the shared domain model before UI migration.
2. Expand parser formats, low-confidence handling, matcher explanations, profile output, pitch analysis, recommendation score breakdowns, and exporters.
3. Expand the fixture KTV catalog to at least 180 complete metadata records without audio, lyrics, MV, platform logos, or copyrighted cover assets.
4. Replace the four-tab MVP shell with a guided SwiftUI product flow: onboarding, import hub, review, match report, voice setup, scenario builder, result, export center, and interview mode.
5. Polish Share Extension configuration and handoff documentation.
6. Add focused tests and run `swift test` after each core package upgrade; then run XcodeGen and best-effort `xcodebuild`.
7. Write manual QA, interview, and final report docs after verification.

## Final Acceptance Checklist

- [x] App can run a complete demo path: onboarding, import, review, match, profile, voice simulation, scenario generation, result, export, interview mode.
- [x] Share Extension supports `public.url`, `public.plain-text`, and `public.image`, stores pending imports, and documents App Group setup.
- [x] OCR path uses Vision where available and keeps protocol/mock fallback for tests.
- [x] Voice setup supports simulator-friendly mock profile and a real-device recording path with failure states.
- [x] KTV catalog contains at least 180 complete mock tracks.
- [x] Recommendation output is segmented by scenario and includes reasons, risks, alternatives, and score breakdowns.
- [x] UI contains loading, empty, and error states for the core workflow.
- [x] Parser, matcher, profiler, pitch detector, recommendation engine, and exporters have focused tests.
- [x] `swift test` passes.
- [x] XcodeGen project generation succeeds, or failures are documented and fixed where possible.
- [x] Best-effort iOS build is attempted and results are recorded.
- [x] README, GAP_ANALYSIS, MANUAL_QA, INTERVIEW_SCRIPT, ShareExtensionREADME, and FINAL_REPORT are complete.
