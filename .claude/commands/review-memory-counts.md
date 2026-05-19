Review the current change only for memory-count and notification-count consistency in TimeCapsule.

Use:
- `memory-count-consistency`
- `notification-preferences-audit` when settings or reminder behavior is involved

Focus on:
- `PhotoLibraryModel.fetchOnThisDay()`
- `NotificationManager.countMemories(on:)`
- date boundaries
- year lookback behavior
- media-type filtering
- permission gating
- notification copy that implies a count

Return:
1. Findings with file references.
2. Whether any divergence is intentional or accidental.
3. Manual follow-up checks if needed.
