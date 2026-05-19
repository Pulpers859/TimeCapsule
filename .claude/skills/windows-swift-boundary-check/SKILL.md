---
name: windows-swift-boundary-check
description: Run the Windows Swift toolchain sanity check, use it where valid, and clearly state what cannot be verified for this iPhone app on Windows.
---

# Windows Swift Boundary Check

## Problem
It is easy to overstate verification when editing Swift on Windows in an Apple-framework-heavy app.

## Why It Is Worth Having
This skill creates repeatable honesty: we still run the toolchain check, but we do not pretend it covers SwiftUI, Photos, AVKit, or notifications.

## Risk
Coverage is intentionally limited.

## Why That Risk Is Acceptable
Limited honest verification is safer than broad false confidence.

## Use When
- Before handoff after Swift edits.
- When reviewing whether a change has any framework-free logic that can be compiled or smoke-tested on Windows.

## Workflow
1. Run `swift-sanity-check`.
2. If touched files are framework-free, compile them directly with `swiftc`.
3. Explicitly list skipped Apple-framework files.
4. Report validated behavior separately from device-only behavior.

## Output
- Exact Windows checks run.
- Files skipped and why.
- iPhone-only validation still needed.
