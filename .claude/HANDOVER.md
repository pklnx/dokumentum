# Handover

## State (2026-10-28)
- Dokumentum (`pklnx/dokumentum`, private) replaces pklnx/document-archive and pklnx/paperless-go; both are frozen, no data migration. Plan: `docs/development/plan.md`.
- Step 0 (#1, `ready`) has four parts; plan and decisions are on #1 (plan comment, T1-T10 coordinator decisions, P1-P4 maintainer decisions).
  - Part 1 (#20) merged with #24: repository basics, Linux CI (`lint`, `secret-scan`), labels.
  - Part 2 (#21, Xcode project and packages) is next; it runs on the maintainer's MacBook Pro (M6, 32 GB, 1 TB; arriving), in a macOS VM or a separate macOS user, decided when it arrives (Claude Code there).
  - Part 3 (#22, identifiers, entitlements, share-extension placeholder; `second-review`) waits only for part 2.
  - Part 4 (#23, test infrastructure) follows part 2, in parallel with part 3.
- Apple: enrolment done, Team ID `88GY2V9C2A`; iCloud container, app group and both App IDs registered; App Store Connect record "Dokumentum" (primary language German, store metadata only).

## Maintainer actions open
- Development machine: the MacBook Pro replaces the Mac mini (returned) and the MacBook Air (not planned as a target). macOS 27, Xcode 27.x; confirm versions (`sw_vers`, `xcodebuild -version`) at the start of #21. For the agents: the Dev Apple Account (role Developer; accept its iCloud terms before the first sign-in) and a GitHub machine account (open, see #1); in a VM, 16 GB RAM.
- Xcode Cloud onboarding once part 2's project exists (plan on #1, maintainer step 6); then the ruleset with the required checks (step 8).
- The rest of #1's maintainer steps (3 devices, 7 compute hours, 9 device check on the iPhone and the MacBook Pro) and T10 (DW2/DW3 move to a later part if onboarding comes after #21): see the plan and the last comments on #1.

## Notes
- Cloud sessions: Linux, no Swift/Xcode; `gh api` (REST) works, GraphQL does not. Builds and app tests run on the development MacBook Pro.
