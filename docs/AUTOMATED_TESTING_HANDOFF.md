# Automated Testing Handoff

## Repository Contract

- App: `TimeCapsule`
- Classification: `hybrid`
- Shipping project: `TimeCapsule.xcodeproj`, shared `TimeCapsule` scheme, iOS
- Deterministic harness: root `Package.swift`
- Default and delivery branch: `main`; do not create a PR branch for normal agent work
- Final release validation still requires a physical iPhone
- Profile: `.swift-automation.json`, schema version 1, `workflowMode: existing`
- Latest automation kit used: `Pulpers859/swift-agent-automation-kit` commit `4416998dd029d3f87269e04b39e06da28a56c1ac`

The app remains an Xcode project. The root Swift package compiles selected Foundation-safe shipping files in place so macOS and Windows can prove deterministic behavior without creating a second implementation.

## Workflows

- `.github/workflows/automation-swiftpm.yml`: deterministic XCTest on `macos-latest`
- `.github/workflows/automation-swiftpm-windows.yml`: deterministic XCTest on `windows-2022` with Swift 6.2
- `.github/workflows/automation-xcode.yml`: unsigned generic iOS Simulator build, privacy-manifest bundle check, failure log, and failure `.xcresult`

All direct actions are pinned to full commit SHAs, permissions are `contents: read`, and obsolete runs for the same workflow/ref are cancelled. The workflows intentionally preserve custom stronger test-evidence and Windows behavior, so a kit preview may label generated workflow names as stale. Do not use `-Force` to overwrite them without reconciling those protections.

## Deterministic Tests

Run from the repository root:

```powershell
swift test --enable-xctest --parallel
```

The `TimeCapsuleCore` harness compiles these shipping files:

- `MemoryWindow.swift`
- `NotificationPlan.swift`
- `GalleryStateLogic.swift`
- `RecapPlan.swift`

There are 19 network-free XCTest cases across five suites. They cover date-window clamping, half-open ranges, leap day, DST, year boundaries, notification slots and copy, selection pruning, post-delete index repair, recap sampling, and a sequential empty-state to widened-range to schedule to delete journey.

Both package workflows run `scripts/Assert-SwiftTestEvidence.ps1`. CI fails unless all 19 named cases appear in the log and the execution count is at least 19. This deliberately ignores Swift 6.2's unrelated trailing Swift Testing summary that reports zero tests after the XCTest cases have run.

## GitHub Evidence

Code evidence commit: `3e46f82ce0357dc1b43ff951d4be5b673174fcae`.

- [macOS deterministic run 29706565406](https://github.com/Pulpers859/TimeCapsule/actions/runs/29706565406), job `88244474437`: success; `Verified all 19 required XCTest cases.`
- [Windows deterministic run 29706565390](https://github.com/Pulpers859/TimeCapsule/actions/runs/29706565390), job `88244474456`: success; `Verified all 19 required XCTest cases.`
- [Xcode build run 29706565380](https://github.com/Pulpers859/TimeCapsule/actions/runs/29706565380), job `88244474392`: success; `BUILD SUCCEEDED` and `PrivacyInfo.xcprivacy` was copied into `TimeCapsule.app`.

The Xcode log has one non-fatal tool warning: App Intents metadata extraction is skipped because the app does not depend on `AppIntents.framework`. The app does not use App Intents, so adding that framework only to suppress the warning would be incorrect.

## Local Evidence

- Latest-kit repository inspection classified the repository as hybrid and found the real project, shared scheme, package, and three workflows.
- Latest-kit profile validation passed as `TimeCapsule [hybrid, existing]`.
- Latest-kit installer preview was reviewed without `-Apply` or `-Force`.
- `swift-sanity-check` passed for all four framework-free shipping files.
- All 25 Swift files passed `swiftc -parse` on Windows.
- `git diff --check`, privacy-manifest XML parsing, and credential-pattern scanning passed.
- The local Windows `swift test` command could not load the installed Swift 6.3.1 standard library. This is a local toolchain failure; the pinned Windows GitHub runner executed all 19 cases successfully.

## Security And Cost

- Live AI automation is disabled. No paid job, provider secret, fixture, prompt, or response artifact exists.
- No API keys, prompts, raw AI responses, personal data, medical data, or user photos are committed or uploaded.
- The existing `GH_TOKEN` was used only to inspect Actions through GitHub's API; its value is not stored.
- `PrivacyInfo.xcprivacy` declares Apple reason `CA92.1` for app-only `UserDefaults` access and declares no tracking or collected data.
- Photo coordinates are sent to Apple Maps only after the user presses `Load Map and Location Name` following an explicit disclosure.
- Shared videos are exported through an AVFoundation sharing filter with metadata cleared instead of sharing the original Photos resource.
- Recap frames and completed videos use complete file protection; cancellation and failure remove owned temporary output.

Do not add a paid live workflow without an independent default-off input, exact confirmation phrase, deterministic prerequisite, synthetic privacy-safe fixture, redacted output, enforced HTTP-call budget, and explicit owner approval.

## Adversarial Audit

Five initial expert audits covered architecture/concurrency, privacy/security, UI/accessibility, full-screen media, and testing/product direction. Three separate adversarial agents then assumed the repair was incomplete.

The second audit found and corrected issues that the first pass missed: a tuple type error hidden by syntax-only parsing, default-main-actor isolation gaps, destructive reminder replacement, uncancelled count work, stale permission fetch publication, modal video playback, pre-disclosure location transmission, metadata-bearing video shares, incomplete case guards, missing `.xcresult` retention, and an ineffective duplicate PhotoKit cache.

The result is not “hundreds of bugs.” The council found a concentrated set of roughly ten high-impact root causes plus medium/low polish and coverage gaps. The high-impact issues found in code were corrected and the final code commit passed all three GitHub lanes.

## Remaining Limits

- Xcode CI proves compilation and resource bundling, not launch-time behavior or rendering.
- There is no Xcode UI-test target. VoiceOver focus order, accessibility announcements, largest Dynamic Type sizes, iPad layouts, gestures, and visual polish still require device review.
- Photos permission prompts, limited-library picker callbacks, deletion confirmation, iCloud downloads, notification delivery, reverse geocoding, AVPlayer behavior, and metadata-filtered video export require real Apple runtime validation.
- Deterministic tests cover the pure notification plan, but the `UNUserNotificationCenter` orchestration is Apple-framework code and is currently compile-validated rather than mock-driven.
- The project still uses Swift 5 language mode with approachable concurrency settings. Moving to Swift 6 language mode should be a dedicated migration, not a blind build-setting flip.
- The full-screen toolbar and video-control row should be visually checked at accessibility text sizes. Their touch targets and scrolling/accessibility semantics are improved, but Windows cannot prove that no clipping remains.
- App termination can still leave an already completed share file until the operating system purges the temporary directory; normal completion, cancellation, and detected failure clean up owned files.

## Maintenance

Before changing CI, tests, workflows, or automation, read `AGENTS.md`, `.swift-automation.json`, and this file. Fetch the latest kit, run repository inspection and profile validation, preview installer destinations, and reconcile changes before any apply. Preserve the macOS, Windows, Xcode, exact-case guard, privacy bundle check, cancellation groups, pinned actions, and physical-device boundary.
