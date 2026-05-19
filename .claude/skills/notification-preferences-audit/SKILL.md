---
name: notification-preferences-audit
description: Audit the contract between SettingsView and NotificationManager for notification defaults, storage keys, enable or disable behavior, and refresh rules.
---

# Notification Preferences Audit

## Problem
`SettingsView.swift` and `NotificationManager.swift` share notification state through duplicated keys and defaults. Small edits can break the reminder flow without obvious compiler errors.

## Why It Is Worth Having
This is a compact, high-value safety check around user-visible reminders and stored preferences.

## Risk
It may focus attention on a low-risk copy change.

## Why That Risk Is Acceptable
The audit is cheap, and notification regressions are annoying for users and easy to miss during code review.

## Use When
- Editing `@AppStorage`, `UserDefaults`, scheduling times, enable or disable logic, or notification authorization UX.

## Workflow
1. Compare `SettingsView` storage keys and defaults with `NotificationManager.Keys`, `notificationHour`, `notificationMinute`, and `notificationsEnabled`.
2. Trace what happens when reminders are turned on, turned off, or denied at the OS level.
3. Check whether `refreshScheduleIfNeeded(force:)` and `lastNotificationRefresh` still make sense for the change.
4. Flag any default-value drift or partial update paths.

## Output
- Storage-key or default mismatches.
- Reminder enable or disable regressions.
- iPhone-only checks still needed.
