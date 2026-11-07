# Handover

## State (2026-11-07)
- Dokumentum (`pklnx/dokumentum`, private) replaces pklnx/document-archive and pklnx/paperless-go; both are frozen, no data migration. Plan: `docs/development/plan.md`.
- Step 0 (#1, `ready`) has four parts; plan and decisions are on #1 (plan comment, T1-T10 coordinator decisions, P1-P4 maintainer decisions).
  - Part 1 (#20) merged with #24: repository basics, Linux CI (`lint`, `secret-scan`), labels.
  - Part 2 (#21, Xcode project and packages) merged with #33. It runs in a macOS VM on the maintainer's MacBook Pro (Claude Code there), as all later parts do.
  - Part 4 (#23, test infrastructure) merged with #37.
  - Part 3 (#22, identifiers, entitlements, share-extension placeholder; `second-review`) is #39. Its signed output and step 9 are deferred under the maintainer's delegation window (comment on #1), so #1 stays open after it merges.
- Apple: enrolment done, Team ID `88GY2V9C2A`; iCloud container, app group and both App IDs registered; App Store Connect record "Dokumentum" (primary language German, store metadata only).

## Maintainer actions open
- Development machine: a macOS VM on the MacBook Pro, which replaces the Mac mini (returned) and the MacBook Air (not planned as a target). Measured versions: `docs/development/plan.md`, section 2. Agents use the GitHub account `dev-bot-pklnx` and a bot Apple Account with no signing access; the VM builds unsigned.
- Xcode Cloud is onboarded (plan on #1, maintainer step 6); next the ruleset with the required checks (step 8).
- The rest of #1's maintainer steps (3 devices, 7 compute hours, 9 device check and signed output on the iPhone and the MacBook Pro, deferred to before signed or iCloud work relies on them): see the plan and the last comments on #1.

## Notes
- Cloud sessions: Linux, no Swift/Xcode; `gh api` (REST) works, GraphQL does not. Builds and app tests run on the development MacBook Pro.
