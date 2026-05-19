# TimeCapsule

## What This App Is
- Small SwiftUI iPhone app that shows photos and videos from this day in prior years.
- Core flows: photo permission, "on this day" fetch, grouped browsing, full-screen viewing, sharing, deleting, and daily local notifications.

## Architecture Map
- `ContentView.swift` + `PhotoLibraryModel.swift`: permission state, loading state, fetch pipeline.
- `TimeCapsuleView.swift`: grouped gallery, filters, multi-select, batch delete.
- `FullScreenPhotoView.swift`: swipe, zoom, video playback, share, single delete, preheating.
- `SettingsView.swift` + `NotificationManager.swift`: notification prefs, scheduling, refresh rules.
- `TimeCapsuleApp.swift`: app launch and refresh-on-active behavior.

## Real Failure Modes
- UI memory counts drift from notification counts because date filtering exists in both `PhotoLibraryModel.fetchOnThisDay()` and `NotificationManager.countMemories(on:)`.
- Delete behavior works in one surface but fails to refresh the gallery or notification schedule everywhere else.
- `SettingsView` and `NotificationManager` drift on key names, defaults, or enable/disable behavior.
- `FullScreenPhotoView.swift` regressions break swipe, zoom, scrub, player cleanup, or delete/share edge cases.
- Windows can only verify the Swift toolchain here, not iPhone runtime behavior.

## Working Rules
- Keep AI work narrow and tied to touched files.
- If you change one side of a paired behavior, inspect the other side before finalizing:
  - `PhotoLibraryModel.fetchOnThisDay()` and `NotificationManager.countMemories(on:)`
  - `SettingsView` `@AppStorage` keys and `NotificationManager.Keys`
  - `TimeCapsuleView.deleteSelectedPhotos()`, `FullScreenPhotoView.deleteCurrentPhoto()`, and `.timeCapsulePhotosDidChange`
- Prefer opt-in review commands over automatic mutation.
- No silent commits, pushes, destructive hooks, or broad auto-edits.
- After Swift edits on Windows, run `swift-sanity-check` and separate validated behavior from iPhone-only behavior.

## Use These
- `/preflight`
- `/review-memory-counts`
- `/review-delete-flow`
- `/review-fullscreen`
- `/session-brief`

## Intentionally Omitted
- Auto-commit or auto-push workflows.
- Always-on hooks that mutate files or spam reminders.
- Broad "analyze the whole app" commands.
- Automation that claims to validate SwiftUI, Photos, AVKit, or notifications on Windows.
