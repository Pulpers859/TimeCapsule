Review the current change only for delete-flow regressions in TimeCapsule.

Use:
- `delete-refresh-check`

Focus on:
- batch delete in `TimeCapsuleView.swift`
- single delete in `FullScreenPhotoView.swift`
- selection cleanup
- `.timeCapsulePhotosDidChange`
- `PhotoLibraryModel` refresh behavior
- notification schedule refresh behavior
- empty-state and error-state handling

Return:
1. Findings with file references.
2. Any missing refresh or stale-state path.
3. A short manual delete checklist for device testing.
