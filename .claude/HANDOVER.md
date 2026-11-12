# Handover

## State (2026-11-11)
- Dokumentum (`pklnx/dokumentum`, public since 2026-11-12) replaces pklnx/document-archive and pklnx/paperless-go. Both are frozen, and there is no data migration. Plan: `docs/development/plan.md`.
- Coordinator state, open tickets in order, and maintainer actions: the latest handover comment on issue #76 (https://github.com/pklnx/dokumentum/issues/76#issuecomment-6798451358). Read it first.
- Issue #1 (repository and skeleton, `ready`): the parts are merged. On 2026-11-11 steps 3 and 9 passed for the Mac (signed, sandboxed build on the MacBook Air; results on #1). Open: steps 3 and 9 for the iPhone (with #4's M2/M3) and step 7.
- Issue #2 (data model and sync): parts merged up to #30 (PR #56); #31 is open.
- Issue #3 (library UI): all five parts are merged, and the Mac accessibility audit passes (#82). The VoiceOver check of the Import menu passed on the signed Mac build (2026-11-11). It stays open for the maintainer's own look (PQ17).
- Issue #4 (import): parts 1–5 are merged (sub-issues #58–#62; part 4, the share extension, is #85; part 5, the processing queue, is #96). Follow-up #87 hardens the share queue: part 1 is merged as #95, and part 2 (#94) is in review as PR #100. Multi-page TIFFs (#90) are in review as PR #101; the Mac placeholder follow-up #89 has a plan in `review`. M1 (signed Mac build) passed on 2026-11-11; M2–M4 are open.
- Apple: enrolment is done, Team ID `88GY2V9C2A`. The iCloud container, the app group and both App IDs are registered. The App Store Connect record "Dokumentum" exists (primary language German, store metadata only).
- Xcode Cloud is onboarded and is the PR check. The ruleset `main` with the required checks is active.

## Development machine
- Signed builds and device runs: the maintainer's MacBook Air (M5), which replaced the MacBook Pro permanently on 2026-11-11 (maintainer decision on #1).
- The maintainer's Mac mini (since 2026-11-10). Sessions, the coordinator's included, run through one Remote Control server for the workspace folder (since 2026-11-11), which holds this repository, `dev-process`, `.coordination/reports/` and `evidence/`. Agent worktrees live in the session scratchpad.
- Main working trees: dev-process's `/home/user/<repo>` (`briefs.md`, `decisions.md` Never 5) is `<workspace>/<repo>` on this machine; the workspace's own `CLAUDE.md` (outside this repository) names the paths.
- `gh` runs as the bot account `robert-dot-pklnx-bot` (write access, no admin). Reviews stay COMMENT reviews with a verdict line (maintainer decision 2026-11-10).
- Agents build unsigned and never touch signing. Setup and Mac pitfalls: `docs/development/index.md`, "Setup on the development Mac".
- Agents and sessions share the Mac. Every `xcodebuild` run takes a shared lock directory (with several sessions, one fixed path outside any scratchpad; see #76), and long runs go to the background. macOS UI tests need an unlocked screen with no system dialog over the app.

## Maintainer actions open
- #1: steps 3 and 9 for the iPhone (with #4's M2/M3), and step 7 (compute hours). The Mac part passed on 2026-11-11.
- #3: the maintainer's own look on the iPhone and the Mac (PQ17).
- #4: M2/M3, signing and provisioning for the share extension, then the device check on the iPhone. M4, the two-device check of the processing queue. (M1 passed on 2026-11-11.)

## Notes
- Cloud sessions run on Linux, with no Swift or Xcode. There, `gh api` (REST) works and GraphQL does not. Builds and app tests run on the Mac mini.
