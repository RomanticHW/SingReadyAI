# Share Extension Setup

## Targets

The project defines two iOS targets in `project.yml`:

- `SingReadyAIApp`
- `SingReadyAIShareExtension`

Run:

```bash
xcodegen generate
open SingReadyAI.xcodeproj
```

## App Group

Both targets use:

```text
group.com.example.SingReadyAI
```

Enable App Groups in Xcode for both the app target and the share extension target, then add the same group identifier. The entitlement files are:

- `SingReadyAI/App/SingReadyAI.entitlements`
- `SingReadyAI/ShareExtension/SingReadyAIShareExtension.entitlements`

If the App Group container is unavailable, `AppGroupStore` falls back to Application Support. The app and extension UI both show a development fallback hint.

## Supported Share Types

`SingReadyAI/ShareExtension/Info.plist` enables:

- `public.url`
- `public.plain-text`
- `public.image`

The extension reads the current `NSExtensionContext`, extracts `NSItemProvider` values, detects source, and saves `PendingImportPayload` to `pending_imports.json`.

## Real Device Test

1. Install the app on a signed device.
2. Open NetEase Cloud Music, QQ Music, Apple Music, Safari, Photos, or Notes.
3. Share a song, playlist URL, text snippet, or screenshot to `今晚唱什么`.
4. Confirm the extension shows source, preview, and privacy note.
5. Tap `打开今晚唱什么继续分析`.
6. Open the main app and check the pending import banner in Import Hub.

## Limits

- The extension only reads the content explicitly shared by the user in this action.
- It cannot read third-party app private playlist databases.
- It does not call private music platform APIs.
- Image shares are passed to the app-side OCR flow; OCR quality depends on screenshot clarity.
