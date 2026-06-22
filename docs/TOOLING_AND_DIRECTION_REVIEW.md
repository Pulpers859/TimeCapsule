# Tooling & Direction Review

Decision record from a review of 9 candidate tools/skills against TimeCapsule's
goals and rules. Date: 2026-06-21.

## Framing
None of the 9 candidates are features that ship *inside* the app. TimeCapsule is
a small, deliberately simple, native SwiftUI "on this day" photo/video app with
no LLM surface of its own. So each candidate was judged only on whether it helps
the solo dev + product process **without** violating the core rule: premium and
simple, not bloated.

## Verdict on the 9 candidates

| # | Candidate | Verdict | Why |
|---|-----------|---------|-----|
| 3 | PM-Skills | **Adopt** | Directly defends the anti-bloat rule: PRDs, prioritization, saying no. Highest signal of the nine. |
| 6 | Last30Days-Skill | **Adopt (occasional)** | Competitor pain-points + ASO research for a crowded "on this day" category. Run around launch/feature decisions, not infrastructure. |
| 4 | Taste-Skill | **Conditional** | Polish matters for a premium photo app, but it is tuned for generic/web AI UI, not SwiftUI + Apple HIG. Use as a taste check only. |
| 1 | Open-Notebook | Skip | Heavy NotebookLM machinery for a tiny `.md` knowledge base that already exists. |
| 2 | MarkItDown | Skip | No document-ingestion need in this app. Sometimes-utility at most. |
| 5 | Container / Second Brain | Skip | Duplicates the existing handoff discipline; upkeep cost > payoff at this scale. |
| 8 | Headroom | Skip (for now) | Token compression only pays off on large repos. A small app is the opposite case. |
| 7 | Agent-Reach | Drop | Overlaps #6 but more brittle. Redundant if #6 is adopted. |
| 9 | Career-Ops | Drop | Unrelated to the app. |

**If forced to pick one: #3 PM-Skills** — the only candidate that actively
protects the simplicity that is a core project rule.

## Beyond #3 and #6: what would actually elevate the app
Tooling does not elevate a product; product decisions do. These are
on-philosophy directions that raise the ceiling without adding bloat. Each is a
candidate, not a commitment — sequence them through the #3 prioritization lens.

1. **Sharpen the one moment that matters.** The emotional payload of this app is
   the instant a memory appears. Invest polish there first: the full-screen
   reveal, transitions, and the daily notification copy/preview. This is reach
   over breadth — make the core flow feel premium before adding surfaces.
2. **Make the daily notification worth opening.** The notification *is* the
   retention loop. A real preview (count + thumbnail where the platform allows)
   and warm, specific copy will move opens more than any new screen.
3. **Respect empty and sparse days.** "On this day" has days with nothing, or
   one item. A deliberate, kind empty state (and a nearby-day fallback) protects
   the experience for newer users with thin libraries — the people most likely
   to churn.
4. **Treat privacy as a visible feature, not a footnote.** This app reads the
   whole photo library. Stating plainly that everything stays on-device is a
   genuine differentiator in this category and a trust anchor on the App Store.
5. **Guard the simplicity rule explicitly.** Keep a short "won't build" list so
   feature pressure has somewhere to go besides the app. This is the #3 mindset
   captured in the repo itself.

## Risk notes tied to existing contracts
Any work above must respect the high-risk contracts in `CLAUDE.md`:
- Memory counts and notification counts stay aligned through the shared memory service.
- Settings `@AppStorage` keys and notification defaults stay aligned through shared preferences.
- Delete refresh stays aligned across gallery, full-screen, and `.timeCapsulePhotosDidChange`.

Notification and empty-state work (directions 2 and 3) touch these directly, so
run `/review-memory-counts`, `/review-delete-flow`, and the notification
preferences audit before landing changes there.
