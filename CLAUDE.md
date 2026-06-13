# TimeCapsule

`PROJECT_HANDOFF.md` is the canonical project brief. This file stays short on purpose so tool-specific instructions do not drift from the main handoff.

## App Summary
- SwiftUI iPhone app for "on this day" photo and video memories.
- Core flows: photo permission, grouped browsing, full-screen viewing, deleting, sharing, and daily local notifications.

## Live Runtime Structure
- `TimeCapsule/App`: app launch and lifecycle wiring.
- `TimeCapsule/Features`: home, gallery, full-screen, and settings UI.
- `TimeCapsule/Models`: app-facing observable state.
- `TimeCapsule/Services`: photo-memory and notification logic.
- `TimeCapsule/Shared`: cross-feature support types and loaders.

## High-Risk Contracts
- Keep gallery memory counts and notification counts aligned through the shared memory service.
- Keep settings `@AppStorage` keys and notification defaults aligned through shared notification preferences.
- Keep delete refresh behavior aligned across gallery, full-screen, and `.timeCapsulePhotosDidChange`.

## Working Rules
- Keep edits narrow and evidence-based.
- Prefer root-cause fixes over cosmetic duplication.
- Run `swift-sanity-check` after Swift edits and separate Windows validation from iPhone-only behavior.
- For this repo, commit and push code changes by default unless the user explicitly asks not to.
- For this repo, GitHub workflow is `main` only: no side branches and no PR flow unless the user explicitly asks for them.

## Useful Commands
- `/preflight`
- `/review-memory-counts`
- `/review-delete-flow`
- `/review-fullscreen`
- `/session-brief`
