# Handover

## State (2026-10-28)
- Dokumentum (`pklnx/dokumentum`, private) replaces pklnx/document-archive and pklnx/paperless-go; both are frozen, no data migration. Plan: `docs/development/plan.md`.
- Step 0 (#1, `ready`) has four parts; plan and decisions are on #1 (plan comment, T1-T10 coordinator decisions, P1-P4 maintainer decisions).
  - Part 1 (#20) merged with #24: repository basics, Linux CI (`lint`, `secret-scan`), labels.
  - Part 2 (#21, Xcode project and packages) is next; it runs in the macOS VM on the maintainer's Mac mini (Claude Code there).
  - Part 3 (#22, identifiers, entitlements, share-extension placeholder; `second-review`) waits only for part 2.
  - Part 4 (#23, test infrastructure) follows part 2, in parallel with part 3.
- Apple: enrolment done, Team ID `88GY2V9C2A`; iCloud container, app group and both App IDs registered; App Store Connect record "Dokumentum" (primary language German, store metadata only).

## Maintainer actions open
- VM: macOS 27 on host and guest, Xcode 27.x; confirm versions (`sw_vers`, `xcodebuild -version`) at the start of #21.
- Xcode Cloud onboarding once part 2's project exists (plan on #1, maintainer step 6); then the ruleset with the required checks (step 8).

## Notes
- Cloud sessions: Linux, no Swift/Xcode; `gh api` (REST) works, GraphQL does not. Builds and app tests run in the VM.
