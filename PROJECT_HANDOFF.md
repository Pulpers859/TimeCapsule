# Project Handoff

This file is the `TimeCapsule`-specific companion to [AI_PROJECT_HANDOFF_TEMPLATE.md](/C:/Dev/TimeCapsule/docs/templates/AI_PROJECT_HANDOFF_TEMPLATE.md), which defines the broader machine-wide repo and workflow standard.

## Project Identity
- Project name: `TimeCapsule`
- Project type: `iOS app`
- Source-of-truth repo path: `C:\Dev\TimeCapsule`
- Stale/old copies to ignore if applicable: `C:\Users\Patrick's Computer\OneDrive - WV School of Osteopathic Medicine\Desktop\TimeCapsule` after migration to `C:\Dev\TimeCapsule`
- Primary target for normal work if multiple surfaces exist: `Main app`
- GitHub intent/status: `remote attached`
- GitHub remote: `https://github.com/Pulpers859/TimeCapsule.git`

## Repo State
- Stable branch: `main`
- Working branch: `main`
- Expected default branch for normal work: `main`
- If Git is not set up yet for this project, the agent should bootstrap it before doing major feature work.

## If No Git Exists Yet
If `git rev-parse --is-inside-work-tree` fails in the real project root, the agent should help set up the repo using this standard:
1. confirm the real project root
2. migrate the project to `C:\Dev\TimeCapsule` if the current location is a weak source of truth
3. initialize local Git
4. create a focused `.gitignore`
5. create `.gitattributes` enforcing LF for code files
6. set repo-local config:
   - `core.autocrlf=false`
   - `core.eol=lf`
   - `pull.ff=only`
   - `fetch.prune=true`
7. add repo-local aliases:
   - `git st` -> `status -sb`
   - `git lg` -> `log --oneline --graph --decorate --all --date=short`
8. create the initial commit
9. connect the GitHub remote if I want one
10. push `main`
11. create a dedicated PowerShell shortcut for this project

If the GitHub remote is unknown, the agent should finish local bootstrap first and only ask for the remote when push/setup is actually needed.

## PowerShell / Terminal Standard
- Do not globally pin every PowerShell session to this project.
- A dedicated shortcut should exist:
  - `TimeCapsule PowerShell`
- That shortcut should open directly in the source-of-truth repo path.
- Avoid fragile startup command strings if the path contains apostrophes or quoting hazards.

## How The Agent Should Operate
- Inspect before assuming.
- Work in the source-of-truth repo only.
- Fix root causes, not surface symptoms.
- Be honest and direct.
- Prefer architecture/data-flow fixes over hacks.
- Do not use brittle hardcoded special cases or band-aid fixes unless you explicitly explain why a deeper fix is not practical.
- Be proactive: inspect, diagnose, edit code directly, verify, and then audit nearby weaknesses.
- Do not stop at the first fix if adjacent code is obviously fragile.
- Tell me clearly what is evidence-backed, proven, inferred, or heuristic.
- If validation, linting, or review logic is too rigid and rejects good output, improve the rule when appropriate instead of dumbing down the product.
- Do not silently tolerate poor architecture if it is now a maintenance risk.
- Handle Git operations when appropriate.
- Keep normal work on `main`.
- Do not create, use, push, or propose side branches or pull requests unless I explicitly ask for that exact workflow.
- Audit adjacent risks after making fixes.
- Run the checks that are realistically available in the current environment.
- Clearly distinguish evidence-backed logic from heuristics.

## Communication Style
- Warm, collaborative, calm, disciplined
- High-effort and thoughtful
- Short progress updates while working
- Clear reasoning, no fluff, no fake certainty
- If the agent misses something, it should own it directly

## Post-Fix Audit Standard
After making changes, the agent should do another harsh pass focused on:
- root-cause completeness
- adjacent fragility
- architecture quality
- validation or rule correctness
- progression / flow coherence where relevant
- silent failure risk
- wasted retries / wasted cost / wasted work
- maintainability

## What The User Wants By Default
- The user describes the problem in chat.
- The agent investigates directly.
- The agent makes code changes directly.
- The agent audits adjacent risks.
- The agent runs local checks where possible.
- The agent handles Git steps when appropriate.
- After making code changes, the agent should commit and push them by default unless the user explicitly says not to.
- GitHub should use `main` only by default: no side branches, no PR workflow, and no alternate push targets unless the user explicitly requests them.
- The user should not need to babysit PowerShell, Git, or GitHub for normal work.

## External-Agent Reconciliation Rule
If the user mentions prior work by another AI agent, another machine, another terminal, or another conversation, do not assume the current diff or latest visible commit tells the full story.

Before making new edits, rebases, resets, merges, or sync claims, the agent should perform an external-agent reconciliation pass:
1. inspect any outside artifact the user provides, such as a transcript, chat export, screenshot, commit list, or claimed fix summary
2. compare what that outside agent claimed to change against:
   - the current local files
   - the local Git history
   - the current `main` branch on GitHub
3. tell the user plainly whether each claimed change is present, missing, partially landed, or overwritten
4. only after that comparison decide whether to pull, rebase, merge, patch missing work, or leave newer work intact

The agent must not claim the repo is fully assessed or in sync until this reconciliation step is complete whenever outside agent work is part of the context.

## Before Starting Any New Task
The agent should confirm:
1. current repo path
2. current branch
3. repo status cleanliness
4. remote configuration
5. whether stale copies exist elsewhere
6. whether the active folder is truly the source of truth

## Architecture / Product Notes
- Main product purpose: Small SwiftUI iPhone app that shows photos and videos from this day in prior years, with grouped browsing, full-screen viewing, sharing, deleting, and daily local notifications.
- Key modules or directories: `TimeCapsule/App`, `TimeCapsule/Features`, `TimeCapsule/Models`, `TimeCapsule/Services`, `TimeCapsule/Shared`, `TimeCapsule/Resources`
- Known fragile areas:
  - UI memory counts and notification counts should both flow through `MemoryLibrary`; bypassing that shared path can silently reintroduce drift
  - Delete behavior can succeed in one surface but fail to refresh the gallery or notification schedule everywhere else
  - `SettingsView` and `NotificationManager` both depend on `NotificationPreferences`; edits should keep the shared defaults and keys authoritative
  - `FullScreenPhotoView.swift` is a regression-prone surface for swipe, zoom, scrub, player cleanup, and delete/share edge cases
- Important evidence/product constraints:
  - The live source of truth includes a verified `TimeCapsule.xcodeproj` at the repo root and the runtime app target under `TimeCapsule/`
  - Before bootstrap on 2026-05-19, no Git repo existed in the original OneDrive project folder
  - Windows can validate Swift syntax and toolchain behavior here, but not real iPhone runtime behavior for SwiftUI, Photos, AVKit, or local notifications
- Runtime environments that matter: `iOS simulator`, `iPhone device`, `Windows Swift toolchain sanity check`

## Git / Release Notes
- Preferred everyday flow:
  - `git st`
  - `git pull --ff-only`
  - `git diff`
  - `git add .`
  - `git commit -m "..."`
  - `git push`
- Branch model:
  - `main` is the only normal branch for this repo
  - do not create or use side branches unless I explicitly ask for them
  - do not use pull requests as the default workflow for this repo
  - do not recreate `dev` unless I explicitly ask for it

## Project-Specific Instructions For The Next Agent
```text
Project: TimeCapsule
Active repo path: C:\Dev\TimeCapsule
GitHub remote: https://github.com/Pulpers859/TimeCapsule.git
Stable branch: main
Working branch: main

Important:
- Treat C:\Dev\TimeCapsule as the source of truth.
- Do not work in stale copies unless explicitly asked.
- If Git is not already set up, bootstrap it using the repo standard in this file before major feature work.
- Use the standard workflow: investigate directly, fix root causes, audit adjacent risks, run checks, and handle Git when appropriate.
- After code changes, commit and push by default unless the user explicitly asks to hold changes locally.
- This repo is main-only: use `main` for normal work, do not assume `dev` exists, and do not create side branches or PRs unless the user explicitly asks.
- If outside-agent work is mentioned, perform the external-agent reconciliation pass before making new edits, rebases, resets, merges, or sync claims.
- If multiple surfaces exist, prioritize the stated primary target before exploring side surfaces.
- If the GitHub remote is unknown, finish local repo setup first and ask for the remote only when needed for push/setup.
```
