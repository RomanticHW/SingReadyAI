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
group.com.huangwei.singreadyai
```

Enable App Groups in Xcode for both the app target and the share extension target, then add the same group identifier. The entitlement files are:

- `SingReadyAI/App/SingReadyAI.entitlements`
- `SingReadyAI/ShareExtension/SingReadyAIShareExtension.entitlements`

If the App Group container is unavailable or a queue write fails, the extension does not claim that the main app can read a private fallback copy. URL and text shares offer a manual copy path; screenshot shares tell the user to select the image again in the main app.

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
5. While loading, confirm `取消` stops the request and closes the extension.
6. After a successful save, tap `完成`.
7. Open the main app and check the pending import banner in Import Hub.
8. Simulate a provider timeout or App Group failure and confirm the extension offers manual copy for URL/text, or asks the user to reselect a screenshot.
9. Make the URL representation hang while plain text returns normally; after the overall deadline, confirm the loaded text remains available to copy.

## Limits

- The extension only reads the content explicitly shared by the user in this action.
- It cannot read third-party app private playlist databases.
- It does not call private music platform APIs.
- Image shares are passed to the app-side OCR flow; OCR quality depends on screenshot clarity.
- URL and plain-text representations are loaded concurrently, so one hung representation does not hide another representation that already completed.
- One extraction attempt has an overall deadline; provider work and staged images are cancelled and cleaned when the deadline expires.
