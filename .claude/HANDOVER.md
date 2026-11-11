# Handover

## State (2026-11-11)
- Dokumentum (`pklnx/dokumentum`, private) replaces pklnx/document-archive and pklnx/paperless-go. Both are frozen, and there is no data migration. Plan: `docs/development/plan.md`.
- Coordinator state, open tickets in order, and maintainer actions: the latest handover comment on issue #76 (https://github.com/pklnx/dokumentum/issues/76#issuecomment-6797563081). Read it first.
- Issue #1 (repository and skeleton, `ready`): the parts are merged. Maintainer steps 3, 7 and 9 are open (see below). Step 9 is deferred until signed or iCloud work relies on it.
- Issue #2 (data model and sync): parts merged up to #30 (PR #56); #31 is open.
- Issue #3 (library UI): all five parts are merged, and the Mac accessibility audit passes (#82). It stays open for the maintainer's own look (PQ17) and the VoiceOver check of the Import menu.
- Issue #4 (import): parts 1–5 are merged (sub-issues #58–#62; part 4, the share extension, is #85; part 5, the processing queue, is #96). Follow-up #87 hardens the share queue: part 1 is merged as #95, and part 2 (#94) is `ready`. Maintainer steps M1–M4 are open.
- Apple: enrolment is done, Team ID `88GY2V9C2A`. The iCloud container, the app group and both App IDs are registered. The App Store Connect record "Dokumentum" exists (primary language German, store metadata only).
- Xcode Cloud is onboarded and is the PR check. The ruleset `main` with the required checks is active.

## Development machine
- The maintainer's Mac mini (since 2026-11-10). The coordinator runs as a Claude Code CLI session in `tmux` (since 2026-11-11). Workspace: `/Users/robert/Mac Mini`, holding this repository, `dev-process`, `.coordination/reports/` and `evidence/`. Agent worktrees live in the session scratchpad.
- `gh` runs as the bot account `robert-dot-pklnx-bot` (write access, no admin). Reviews stay COMMENT reviews with a verdict line (maintainer decision 2026-11-10).
- Agents build unsigned and never touch signing. Setup and Mac pitfalls: `docs/development/index.md`, "Setup on the development Mac".
- Agents share the Mac. Every `xcodebuild` run takes a shared lock directory in the scratchpad, and long runs go to the background. macOS UI tests need an unlocked screen with no system dialog over the app.

## Maintainer actions open
- #1: steps 3 (devices), 7 (compute hours) and 9 (device check, signed output). See the plan and the last comments on #1.
- #3: the maintainer's own look on the iPhone and the Mac (PQ17), and the VoiceOver check that "+" opens the Import menu on the Mac.
- #4: M1, the signed Mac build (together with #1's step 9). M2/M3, signing and provisioning for the share extension, then the device check. M4, the two-device check of the processing queue.

## Notes
- Cloud sessions run on Linux, with no Swift or Xcode. There, `gh api` (REST) works and GraphQL does not. Builds and app tests run on the Mac mini.
