# Manual QA Checklist

## First Launch

- Delete the app or reset `singready.hasCompletedOnboarding`.
- Launch app.
- Verify three onboarding pages render and `跳过` / `开始使用` enters Import Hub.

## Demo Import

- Tap `使用 Demo 歌单`.
- Verify Import Review shows parsed songs.
- Edit one song title or artist.
- Delete one low-confidence item if present.
- Tap `开始匹配 KTV 曲库`.

## Paste Text Import

- Return to Import Hub.
- Paste mixed formats:
  - `周杰伦 - 晴天`
  - `晴天 - 周杰伦`
  - `陈奕迅《十年》`
  - `01 稻香 周杰伦`
  - `歌名：告白气球 歌手：周杰伦`
  - `分享 周杰伦 的单曲 七里香`
- Verify URL/noise lines are filtered and low-confidence lines stay editable.

## OCR Import

- Tap `截图 OCR 识别`.
- Select a screenshot containing song list text.
- Verify OCR goes to Import Review, not directly to match.
- Verify error state for unreadable image or too few recognized songs.

## Share Import Simulation

- On a real device, share URL/text/image to the Share Extension.
- Confirm extension source, preview, privacy note, and fallback state.
- Open app and verify pending import banner.
- Tap pending import and continue to Import Review.

## Match Report

- Verify KTV match rate ring.
- Verify exact, fuzzy, alternative, unmatched counts.
- Verify artist, language, era, genre, mood, scene fit, difficulty, high-note risk, and chorus friendliness.

## Voice

- Tap `去做声线分析`.
- Tap `使用模拟声线` in simulator.
- On device, tap `录音 10 秒分析`, allow microphone, verify countdown and waveform.
- Deny microphone permission and verify failure state plus mock fallback.

## Scenario

- Test all scenes: friends, birthday, team building, car KTV, couples, solo practice.
- Adjust people count, duration, vibe, difficulty, and chorus preference.
- Generate plan.

## Result Interaction

- Verify section titles match selected scenario.
- Expand score explanation.
- Verify each song has reasons, optional risks, alternatives, tags, difficulty, range, chorus score, and energy.
- Lock one song and regenerate.
- Remove one song and verify replacement.
- Switch scene and regenerate.

## Export

- Verify text export contains title, scenario, reasons, risk warnings, alternatives.
- Toggle JSON preview and verify `scenarioConfig`, `voiceProfile`, `scoreBreakdown`.
- Verify poster preview includes app name, scene, duration, highlights, profile summary, QR/share placeholder.
- Use ShareLink or copy buttons.

## Interview Mode

- Open `面试模式`.
- Verify 90-second product script, 3-minute architecture script, 5-minute demo script.
- Verify Leishi business fit tags are visible.

## Error States

- Empty import.
- OCR no text.
- No microphone permission.
- No matching songs after deleting all review rows.
- Export before generating a plan.
