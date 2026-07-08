# Interview Script

## Why This Product

`今晚唱什么` is not a hardware controller demo. For an interview scenario, a fake KTV protocol integration would be low-signal and hard to validate without actual devices. This app focuses on the user-facing entry point before KTV ordering:

- Import music preference from user-initiated shares.
- Convert listening preference into KTV-singable recommendations.
- Reduce decision cost in group karaoke rooms and car karaoke scenes.
- Explain every recommendation so the result is credible, not a black-box list.

## Business Fit For Leishi

- Mobile song-ordering pre-entry: users can prepare a singable list before arriving at the KTV room.
- Playlist import: users bring preference data from music apps without requiring private API access.
- KTV catalog matching: imported songs are matched against a karaoke-style catalog with availability, difficulty, vocal range, chorus score, and alternatives.
- Car karaoke recommendation: car KTV scenes reduce difficult, rap-heavy, and attention-demanding songs.
- Voice analysis: simple pitch analysis helps avoid songs outside a stable vocal range.
- Scenario arrangement: friends, birthday, team building, couples, solo practice, and car KTV all have different pacing rules.

## 90-Second Product Talk

Tonight in a KTV room, people often know what they like listening to but do not know what is easy to sing, what fits their voice, or how to keep the group atmosphere moving. `今晚唱什么` starts from content users actively share: playlist URLs, text, or screenshots. It parses songs, matches a mock KTV catalog, builds preference and voice profiles, and generates a segmented list for the current scene. Each recommendation includes reasons, risks, alternatives, and scoring details. It can run offline, so it is reliable for interviews and demos.

## 3-Minute Technical Talk

The codebase is split into a SwiftUI app, Share Extension, and `SingReadyAISharedKit`. SharedKit contains provider detection, text parsing, OCR abstraction, fixture resolvers, KTV matching, preference profiling, pitch detection, recommendation, storage, and exporters. The Share Extension reads only the current `NSExtensionContext` and stores payloads through App Group with fallback.

The recommendation engine combines user hits, alternatives, and catalog expansion. It scores preference affinity, KTV availability, vocal fit, sing-along score, scene fit, variety, and risk penalty. It enforces product rules: first song avoids high-risk songs, no same artist back to back where possible, group scenes need chorus-friendly songs, car KTV penalizes high rap density, and birthday scenes require blessing or chorus atmosphere.

## 5-Minute Demo Flow

1. Launch app and show onboarding.
2. Use Demo import or paste mixed-format text.
3. Edit low-confidence songs in Import Review.
4. Start KTV catalog matching.
5. Explain match report: exact, fuzzy, alternative, unmatched, profile tags, scene fit, high-note risk.
6. Use simulated voice or real-device 10-second recording path.
7. Choose friends or birthday scenario and adjust duration/vibe/difficulty.
8. Generate plan and expand one song's scoring explanation.
9. Lock one song, remove another, regenerate.
10. Export text, JSON, and poster preview.
11. Open Interview Mode and summarize architecture.

## Technical Highlights

- Swift Package-first business core.
- Offline fixtures for deterministic demos.
- Share Extension handoff with App Group fallback.
- Vision OCR service behind protocol plus fake service for tests.
- Parser tests for noisy Chinese playlist formats.
- Matcher supports title alias, artist alias, normalization, fuzzy match, and alternatives.
- Pitch detector covers silence, frequency range, MIDI conversion, percentile stable range, and voice type.
- Recommendation engine stores explainable score breakdowns.
- XcodeGen project generation and command-line build are verified.

## Extensions

- Backend proxy for real LLM copywriting or reranking.
- Real KTV vendor catalog sync where authorized.
- Cloud account sync of generated plans.
- More advanced pitch tracking from recorded PCM buffers.
- UI tests for the full guided workflow.
