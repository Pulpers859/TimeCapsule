# Automated Testing Handoff

## Repository Contract

- App: `TimeCapsule`
- Classification: `hybrid`
- Shipping project: `TimeCapsule.xcodeproj`, shared `TimeCapsule` scheme, iOS
- Deterministic harness: root `Package.swift`, compiling the shipping `TimeCapsule/Services/MemoryWindow.swift` file in place
- Default branch: `main`
- Final release validation still requires a physical iPhone
- Profile: `.swift-automation.json`, schema version 1, `workflowMode: generate`
- Automation kit source: `Pulpers859/swift-agent-automation-kit` commit `b85a6b34ae9ec30663aea9b7e9a996cc318e6574`

The repository began as Xcode-only. It is classified as hybrid after adding the narrow Foundation-safe SwiftPM harness; the app itself remains an Xcode project.

## Workflows

- `.github/workflows/automation-swiftpm.yml`: kit-managed deterministic tests on `macos-latest`
- `.github/workflows/automation-xcode.yml`: kit-managed unsigned simulator build on `macos-latest`
- `.github/workflows/automation-swiftpm-windows.yml`: supplemental deterministic tests on `windows-2022`

The Windows workflow is separate so a future kit regeneration cannot silently remove Windows coverage. All direct action references are pinned to full commit SHAs and all jobs have `contents: read` only.

## Deterministic Tests

Run from the repository root:

```powershell
swift test --enable-xctest --parallel
```

`TimeCapsuleCoreTests.MemoryWindowTests` executes nine network-free tests covering preference clamping, exact-day half-open ranges, widened ranges, leap-day acceptance and rejection, negative and oversized input, year boundaries, and DST-local calendar behavior.

Both package workflows fail when the command fails, when no executed-test evidence appears, or when the `TimeCapsuleCoreTests.MemoryWindowTests` marker is absent. Swift 6.2 currently prints a trailing Swift Testing summary that says `0 tests` for this XCTest suite; the same log contains nine `[n/9] Testing ...` execution records. The guard intentionally accepts those XCTest parallel-execution records and does not treat the unrelated Swift Testing summary as the test count.

## GitHub Evidence

Evidence commit: `a864144b9fd69caba64e0505e3faa2927ebba135`.

- [macOS deterministic run 29628733434](https://github.com/Pulpers859/TimeCapsule/actions/runs/29628733434), job `88038240778`: success; all nine test records executed.
- [Windows deterministic run 29628733427](https://github.com/Pulpers859/TimeCapsule/actions/runs/29628733427), job `88038240811`: success with Swift 6.2; all nine test records executed.
- [Xcode build run 29628733456](https://github.com/Pulpers859/TimeCapsule/actions/runs/29628733456), job `88038240938`: success on `macos-26-arm64`, Xcode 26.5, iPhone Simulator SDK 26.5; log ended with `BUILD SUCCEEDED`.

The Xcode log contained one non-fatal tool warning: App Intents metadata extraction was skipped because the app does not depend on `AppIntents.framework`. The app does not use App Intents, so adding that framework only to suppress the warning would be incorrect.

## Local Evidence

- Latest-kit repository inspection detected the Xcode project, shared scheme, and initially zero tests/workflows.
- Latest-kit profile validation: passed as `TimeCapsule [hybrid, generate]`.
- Latest-kit installer preview was reviewed before apply and listed only the two kit workflows, this handoff, and the Claude bridge.
- Windows Swift 6.3.1 local package run: nine tests executed successfully.
- The local Windows run reports a non-fatal inability to create the `.build/debug` convenience symlink after a successful build; CI does not show this warning.
- `swift-sanity-check`: Swift Foundation smoke test passed.
- Every app and test Swift file passed `swiftc -parse` on Windows.
- `git diff --check`: passed.
- Credential-pattern scan: no credential-like material detected.

## Security And Cost

- Live AI automation is disabled; this app has no paid AI surface or live-AI fixture.
- No provider secret is configured and no paid job exists.
- No API keys, prompts, raw model responses, personal data, medical data, or user photos are present in tests, workflows, logs, or artifacts.
- The existing local `GH_TOKEN` was used only to inspect GitHub Actions through the API. Its value is not stored in this repository.
- Do not add a paid live workflow without an independent default-off input, exact confirmation phrase, deterministic prerequisite, synthetic privacy-safe fixture, redacted output, enforced HTTP-call budget, and explicit owner approval.

## Adversarial Audit

The second pass assumed the initial setup was incomplete. It found that Windows had first been added by modifying the kit-managed macOS workflow, which meant a forced kit regeneration could remove Windows coverage. That was corrected by restoring the generated macOS workflow and moving Windows to its own supplemental workflow. No remaining zero-test bypass, unpinned direct action, secret exposure, or shipping/test implementation copy was found.

## Remaining Limits

- Xcode CI proves unsigned compilation for a generic simulator destination; it does not launch the app or validate runtime UI behavior.
- The deterministic harness covers the shared memory date-window logic only. Photos, SwiftUI, AVKit, permissions, deletion, sharing, and local-notification behavior require Apple-platform tests and device review.
- No Xcode unit-test target currently exists; package tests are the deterministic test authority.
- Physical-device behavior and final product quality remain manual release gates.

## Maintenance

Before changing automation, read `.swift-automation.json` and this file. Fetch the latest automation kit, run its repository inspection and profile validator, preview installer destinations, and review changes before any `-Apply` or `-Force`. Kit regeneration owns the macOS package workflow, Xcode workflow, handoff, and Claude bridge; it must leave `automation-swiftpm-windows.yml` intact.
