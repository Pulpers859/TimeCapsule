---
name: delete-refresh-check
description: Verify that both delete entry points keep gallery state, selection state, and notification refresh behavior in sync.
---

# Delete Refresh Check

## Problem
Deletion exists in both `TimeCapsuleView.swift` and `FullScreenPhotoView.swift`. A change can fix one path and break the other.

## Why It Is Worth Having
Delete flows are high-impact, user-facing, and hard to undo mentally during review because the refresh path crosses several files.

## Risk
The skill assumes `NotificationCenter` remains the refresh mechanism.

## Why That Risk Is Acceptable
That assumption matches the current architecture, and if the mechanism changes, this skill should be updated rather than silently ignored.

## Use When
- Editing delete UI, selection state, photo refresh behavior, or notification refresh behavior.

## Workflow
1. Inspect `TimeCapsuleView.deleteSelectedPhotos()` and `FullScreenPhotoView.deleteCurrentPhoto()`.
2. Verify both paths still post `.timeCapsulePhotosDidChange` after success.
3. Check `PhotoLibraryModel` subscription and `NotificationManager` observer behavior.
4. Confirm error handling, empty-state behavior, and selection cleanup still make sense.

## Output
- Any one-sided delete regressions.
- Any stale-state or refresh bugs.
- Manual device checks for delete UX.
