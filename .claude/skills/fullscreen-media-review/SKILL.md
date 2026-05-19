---
name: fullscreen-media-review
description: Review FullScreenPhotoView changes for gesture conflicts, media playback state bugs, cleanup issues, and edge cases around share or delete.
---

# Fullscreen Media Review

## Problem
`FullScreenPhotoView.swift` is the app's largest and most interaction-heavy file. It mixes paging, zooming, video playback, sharing, deletion, and preheating.

## Why It Is Worth Having
This is the most likely place for subtle regressions that survive a quick code skim.

## Risk
The skill produces manual verification work because Windows cannot run the iPhone UI.

## Why That Risk Is Acceptable
The goal is targeted manual verification, not fake automation. A short accurate checklist is higher ROI than pretending this can be fully tested here.

## Use When
- Editing swipe, drag thresholds, zoom, video controls, player lifecycle, sharing, deletion, or adjacent preheating.

## Workflow
1. Trace the state touched by the change: `currentIndex`, `visibleAssets`, `dragOffset`, `isCurrentAssetZoomed`, `isVideoScrubbing`, `player`, and `progressObserver`.
2. Look for conflicts between paging, zooming, tapping, and scrubbing.
3. Check cleanup on `onChange`, `onDisappear`, and asset removal.
4. Produce a short manual iPhone checklist for the exact interaction paths affected.

## Output
- Findings with file references.
- The smallest useful device checklist.
- Any performance or memory suspicion worth follow-up.
