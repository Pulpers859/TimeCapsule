---
name: memory-count-consistency
description: Check that the app's gallery count logic and notification count logic stay aligned when date filtering, media filtering, or lookback behavior changes.
---

# Memory Count Consistency

## Problem
`PhotoLibraryModel.fetchOnThisDay()` and `NotificationManager.countMemories(on:)` both implement "on this day" logic. They can drift silently.

## Why It Is Worth Having
A mismatch here creates one of the app's easiest-to-miss regressions: the notification promises one number while the gallery shows another.

## Risk
This skill can over-flag intentional differences.

## Why That Risk Is Acceptable
In this app, intentional divergence between those two paths should be explicit and documented, not accidental.

## Use When
- Editing date boundaries, year lookback, media type filters, sort behavior, or notification copy.
- Changing photo authorization behavior.

## Workflow
1. Read `PhotoLibraryModel.fetchOnThisDay()` and `NotificationManager.countMemories(on:)`.
2. Compare year range, start/end date boundaries, media type inclusion, and permission gating.
3. If one side changed without the other, decide whether that is intentional.
4. Report the user-visible effect: gallery count, notification count, or scheduling cost.

## Output
- Any mismatches with file references.
- Whether the mismatch is a bug, intentional, or still ambiguous.
- Any manual iPhone verification still required.
