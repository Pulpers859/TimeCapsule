Review the current change only for `FullScreenPhotoView.swift` regressions.

Use:
- `fullscreen-media-review`
- `delete-refresh-check` if delete behavior changed

Focus on:
- paging drag behavior
- zoom versus swipe conflicts
- video scrub and playback state
- player cleanup
- share behavior
- delete edge cases
- preheating side effects

Return:
1. Findings with file references.
2. The smallest useful iPhone test checklist.
3. Any state variable that now looks fragile.
