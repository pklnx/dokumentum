# Handover

## State (2026-11-07)
- Dokumentum (`pklnx/dokumentum`, private) replaces pklnx/document-archive and pklnx/paperless-go; both are frozen, no data migration. Plan: `docs/development/plan.md`.
- Coordinator state, open PRs and the order of the next tickets: issue #76 (coordinator handover). Read it first.
- Issue #1 (repository and skeleton, `ready`): parts 1, 2, 4 merged (#24, #33, #37), part 3 merged as #39. #1 stays open for maintainer step 9 (device check and signed output on the iPhone and the MacBook Pro), deferred until signed or iCloud work relies on it.
- Issue #2 (data model and sync): parts merged up to #30 (PR #56); #31 open.
- Issue #3 (library UI): parts 1–4 merged; part 5 (#47) open.
- Issue #4 (import): parts 2 and 3 merged; #61 and #62 open.
- Apple: enrolment done, Team ID `88GY2V9C2A`; iCloud container, app group and both App IDs registered; App Store Connect record "Dokumentum" (primary language German, store metadata only).
- Xcode Cloud is onboarded and is the PR check; the ruleset `main` with the required checks is active.

## Development machine
- The maintainer's Mac mini (since 2026-11-10), local Claude Code sessions. Workspace `/Users/robert/Mac Mini` (this repository and `dev-process`). Agent worktrees live in the session scratchpad.
- `gh` runs as the bot account `robert-dot-pklnx-bot` (write access, no admin). Reviews stay COMMENT reviews with a verdict line (maintainer decision 2026-11-10), as before.
- Agents build unsigned and never touch signing; setup and Mac pitfalls: `docs/development/index.md`, "Setup on the development Mac".

## Maintainer actions open
- #1's steps 3 (devices), 7 (compute hours) and 9 (device check, signed output): see the plan and the last comments on #1.
- #3's Done-when: the maintainer's own look on the iPhone and the MacBook Pro (PQ17), and the Mac evidence for part 5.
- #61 needs the share extension's signing set up by the maintainer.

## Notes
- Cloud sessions: Linux, no Swift/Xcode; `gh api` (REST) works, GraphQL does not. Builds and app tests run on the Mac mini.
