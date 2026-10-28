# Workflow

Roles, models and coordination rules: [pklnx/dev-process](https://github.com/pklnx/dev-process). Maintainer (human) decides product questions and releases; coordinator (Claude) sets `plan`, plans, delegates, merges; implementers build one PR each; reviewers review only; an independent plan reviewer (never the planner) reviews plans. All Claude work runs in Claude sessions; there is no Claude GitHub Action.

Language: chat with the maintainer in German; everything on GitHub and in code in English. Every GitHub text ends with `— Claude, <role>` (no model names on GitHub).

## Product
Dokumentum: a native SwiftUI document archive (paperless-ngx style) for one person's iPhone and Mac, synced through the private CloudKit database. No external services (no Mistral, no cloud OCR or AI); documents stay on the owner's devices and iCloud. No server, no web UI, no iPad. Minimum iOS 27 / macOS 27 (or the newest SDK the CI runners offer, plan §2). Plan and roadmap: [`docs/development/plan.md`](docs/development/plan.md).

## Ticket flow
1. Issue (template). 2. Coordinator labels `plan` → `## Plan` comment (approach, files, data model, tests, open questions, size), label becomes `review`. 3. Independent plan review; an approving plan reviewer (or the maintainer) replaces `review` with `ready`; only `ready` issues are built.
4. A plan with parts gets one sub-issue per part ("<what> (#N, part K)"), created when the plan is posted; each lists the parent's "Done when" items it delivers.
5. One branch + PR per part; body "Closes #<sub>." and "Part K of #N.".
6. Review: one session reviewer for app code. Risky PRs get a second, independent reviewer; the coordinator adds the label `second-review`: CloudKit schema changes (label `schema`), deletes, rewriting user data, entitlements and capabilities, any new network access.
7. Merge: approving review + green required checks; before merging, a PR comment names the reports read and checks every "Done when" item (met with evidence, or "after merge"); squash merge pinned to the reviewed head SHA. Never auto-merge, never change rulesets or repo settings.
   - A PR that touches the secret scan's allowlist or configuration (`.gitleaks.toml` and files it extends, `.gitleaksignore`, a new `gitleaks:allow` comment, `.github/workflows/secrets.yml`, `scripts/secret-scan-*`, `.githooks/pre-commit`) is merged only after the maintainer's explicit OK. The coordinator asks via AskUserQuestion, names the changed entries (file, rule id, path or fingerprint) and never posts secret values; the OK is noted on the PR.

Maintainer-only steps: deploying the CloudKit schema to Production, TestFlight uploads, App Store Connect settings, signing certificates.

Blocking in reviews only: crash, data loss/corruption, hang, wrong result in a main function, security/privacy problem, broken main flow, missing/failing test for new behaviour, violation of plan or maintainer decision. Everything else is a follow-up issue labelled `followup`.

## Rules
- Tests never touch real documents, real iCloud, real credentials or the network (in-memory store; stub external APIs).
- Every behaviour change has tests; a bug fix has a regression test that fails without the fix. Tests wait for signals, never for time.
- CloudKit schema changes are additive only; every model change comes with a schema version and a migration test. Synced enums are stored as raw strings with a fallback for unknown values.
- The share extension never opens the store; it hands files to the app through the app-group queue.
- Locally run only the tests of what changed; CI runs everything. Agents never watch CI.
- Builds and app tests run in the macOS VM (local sessions); Xcode Cloud is the PR check; cloud sessions verify only what runs on Linux.
- Ask instead of guessing on product decisions (AskUserQuestion, recommendation first).

## Session handover
At session start read `.claude/HANDOVER.md`; update it before a session ends.
