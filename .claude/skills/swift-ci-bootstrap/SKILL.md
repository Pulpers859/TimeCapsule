---
name: swift-ci-bootstrap
description: Audit and maintain this repository's Swift and Xcode GitHub Actions, deterministic tests, and separately authorized live AI contracts.
---

# Swift CI Bootstrap

Read `.swift-automation.json` and `docs/AUTOMATED_TESTING_HANDOFF.md` before changing tests or
workflows. Inspect the actual package/project/workspace and existing CI before editing.

Keep deterministic CI network-free. Keep every paid AI surface in its own default-off
`run_live_<surface>` job behind explicit billing confirmation. Never commit credentials or upload
private fixtures. Prove nonzero test discovery, report actual provider HTTP calls, and distinguish
CI, live-contract, Xcode-build, and physical-device evidence.
