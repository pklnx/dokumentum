# Dokumentum: product and architecture plan

Status: plan review done (approve with changes, worked in); maintainer answers of 2026-10-26 included.
Replaces pklnx/document-archive (native app) and pklnx/paperless-go (server);
both are frozen, nothing is migrated from them.

## 1. Product

A personal document archive in the style of paperless-ngx for exactly two
devices of one person: an iPhone 18 Pro and a MacBook Air (M5). Native
SwiftUI, data in the owner's private iCloud, no server, no accounts of its
own, no web UI.

Name and domain: **Dokumentum**, `dokumentum.app` (maintainer decision,
2026-10-26). The identifiers below use the maintainer's developer domain
`pklnx.space` in reverse-DNS form (`space.pklnx.*`), shared by future pklnx
apps.

### Maintainer decisions (2026-10-26)
- Native app only (iPhone and Mac), sync through iCloud (CloudKit). No server.
- New private repository `pklnx/dokumentum` (private while planning); proven parts of
  document-archive are ported on purpose, not copied wholesale.
- Fresh start: no data migration from document-archive or paperless-go.
- Work on paperless-go and document-archive stops now.
- v1 = the core: scan and import, local OCR, full-text search, tags,
  correspondents, document types, inbox, iCloud sync.
- Classification on the device with Apple's Foundation Models. No external
  services: Mistral and every other cloud OCR or AI are out (2026-10-26);
  documents never leave the owner's devices and iCloud.
- Distribution through TestFlight, CloudKit in Production. No App Store
  listing for now.
- Also in v1: duplicate detection (step 3), a minimal trash (step 2),
  on-device classification (step 7).
- Backup export comes after v1 (step 16, milestone 4); until then the only copy is
  iCloud (accepted).
- Icon and look come from `pklnx/design-system`.

### Out of scope
iPad, Apple Watch, visionOS, Mistral or any other external OCR/AI service, older OS versions, other users, sharing with
other people, a server, a web UI, e-mail import, Windows/Android.

## 2. Platform and identifiers

| Item | Value |
|---|---|
| Targets | One multiplatform SwiftUI app target (iOS + native macOS, not Mac Catalyst); a share extension for iOS (step 3: it hands shared files to the app through the app-group queue) |
| Minimum OS | iOS 27, macOS 27 (the systems on both devices). Checked against the Xcode of the CI (`ci_scripts/ci_post_clone.sh`, pinned in `.xcode-version`; the GitHub Actions runner image and Xcode Cloud); if the CI lags behind, the minimum stays at the newest SDK it offers until it catches up |
| Bundle ID | `space.pklnx.Dokumentum` (extension: `space.pklnx.Dokumentum.Share`) |
| iCloud container | `iCloud.space.pklnx.Dokumentum` (new; the old container stays untouched) |
| App group | `group.space.pklnx.dokumentum` (iOS app and share extension) |
| Team | `88GY2V9C2A` (committed in `Config/Project.xcconfig`; automatic signing on the maintainer's machine; agents' local builds and the CI test jobs (GitHub Actions, formerly Xcode Cloud) build macOS unsigned, section 4) |
| Entitlements | iOS app: push, iCloud (CloudKit, the container above), the app group. Mac app: push, iCloud, App Sandbox; user-selected files, read only; no app group, no network. Share extension: the app group. The files are `Config/*.entitlements`; `scripts/check-project.py` pins them key by key. Hardened runtime: the app target only, with no exception entitlements (maintainer decision P1 on #9, 2026-11-13); the share extension and the test targets stay off |
| Languages | English source strings, German translation (String Catalogs), as in the old app |
| Device classes | iPhone (compact) and Mac (regular); no iPad layout, no size-class branches beyond these two |

Because only current systems are supported, nothing is weak-linked and there
are no `#available` branches (the old app carried both for iOS 18/macOS 15).

Measured toolchains (`sw_vers`, `xcodebuild -version`, `xcodebuild -showsdks`):
| Where | macOS | Xcode | SDKs | Simulator runtimes |
|---|---|---|---|---|
| MacBook Air, the maintainer's signing Mac (2026-11-11) | 27.2.1 (26B131) | 27.2 (27B52), Swift 6.4.2 | iOS 27.2, iOS Simulator 27.2, macOS 27.2 | none installed |
| MacBook Pro, returned to Apple (2026-11-07) | 27.2 (26B7124) | 27.2 (27B52), Swift 6.4.2 | iOS 27.2, iOS Simulator 27.2, macOS 27.2 | iOS 27.0 (has the iPhone 18 Pro), iOS 27.2 |
| GitHub Actions runner, image `xcode-27-arm64` 20261104.0337.1 (2026-11-12; Xcode selected by `DEVELOPER_DIR`) | 27.0.1 | 27.2 (27B52) (the image's default is 27.1) | iOS 27.2, iOS Simulator 27.2, macOS 27.2 | iOS 27.0 (has the iPhone 18 Pro), 27.1, 27.2 (`simctl list runtimes`, probe run 43291274218) |
| Xcode Cloud (2026-11-07) | not read | 27.2, build not read | not read | not recorded |

The Xcode Cloud row is an inference, not a reading of the log: `ci_post_clone.sh`
fails when the Xcode differs from `.xcode-version` (27.2) or has no SDK for iOS 27
and macOS 27, and both test actions passed on PR #41, which pinned 27.2. The exact
builds and SDK versions are in the Xcode Cloud log, which was not read for this
row. The last log read was PR #37's (build 4, action `Default - iOS`, commit
`87cc89a`, recorded on #1), under Xcode 27.1 (27A9275): macOS 27.0 (26A428), SDKs
iOS 27.1, iOS Simulator 27.1 and macOS 27.0. The script prints no simulator
runtimes. Since 2026-11-12 the build and test checks are `app-ios` and `app-macos` (GitHub Actions, `app.yml`). Xcode Cloud's former
checks were `Dokumentum | PR | Default - iOS`, `Dokumentum | PR | Default - macOS` and `Dokumentum | PR`.

## 3. Architecture

### 3.1 Layers
```
Dokumentum (app target, SwiftUI)
  App/        entry point, scenes, commands (Mac menu), routing
  Features/   one folder per feature: Library, Detail, Import, Scan, Metadata, Search, Settings
  Platform/   thin wrappers around PDFKit, VisionKit, Vision, FoundationModels, CloudKit status
DokumentumShare (iOS share extension)
DokumentumTests (Swift Testing), DokumentumUITests (a small smoke suite)
```
The app target has no `Core/` folder: model, processing pipeline, OCR, PDF,
search and classification live in two local Swift packages, so their tests run
with `swift test` on macOS without a simulator:
- `DokumentumKit`: pure logic, Foundation only (search normalisation, date
  and field detection, tag hierarchy, archive folder format, classifier
  prompts and limits).
- `DokumentumCore`: model and processing; imports SwiftData, PDFKit, Vision
  and FoundationModels. Holds `ArchiveStore`, the processing queue and the
  repair passes.
The app target imports both plus SwiftUI, VisionKit and PhotosUI. The share
extension imports neither store nor model (see 3.4).

### 3.2 Data and sync
- **SwiftData with the private CloudKit database**, as in the old app. It is
  the smallest amount of code for two devices of one person. Known limits we
  accept: no unique constraints (duplicates by id must be merged on read),
  last writer wins per field, and once the schema is deployed to Production
  only additive changes are possible.
- **Large data in its own models.** `Document` holds metadata only;
  `DocumentFile` (the PDF), `DocumentThumbnail` (the thumbnail, both
  `@Attribute(.externalStorage)`) and `DocumentText` (the extracted text) are
  one each per document. Measured in step 1 (#29): SwiftData on 27 ignores
  `propertiesToFetch` and selects every column of a fetched entity, so a large
  field on `Document` would load with every list. The old app kept both blobs
  on `Document`, so every list query could fault them in. The four records sync
  independently and arrive in any order: `file`, `thumbnail` and `text` are
  optional, the UI shows "still downloading", the delete rule is cascade, and
  the repair relinks early arrivals and counts orphans.
- **The list query.** `DocumentListQuery` is the only list fetch of
  documents. It prefetches correspondent, type and tags, never the file, the
  thumbnail or the text, and returns `DocumentSummary` values without text or
  blob fields. An automated SQL test (`DocumentListQuerySQLTests`) checks that
  it never reads those tables.
- **Schema versions from day one** (`VersionedSchema`, `SchemaMigrationPlan`),
  with a rule: a CloudKit schema change is additive, and deploying to
  Production is a maintainer step (it cannot be undone).
- **Sync status** is shown: one line in the sidebar footer (last
  import/export event, iCloud account state, account change or sign-out,
  "iCloud storage full"), and an "iCloud Sync" detail opened from it. The
  app works fully offline.
- **Frozen enums.** Values that sync (`processingState`, `textSource`,
  `source`) are stored as raw `String`s and mapped to a fallback when a
  value is unknown, so an older TestFlight build on the other device never
  fails to decode a newer case (lesson from the old app).
- **Repair passes after sync**, run after launch and after every CloudKit
  import event, with deterministic winners (`createdAt`, then `instanceID`).
  As built in step 1, they never delete a record or a blob: re-point
  references through merge tombstones, merge tags, correspondents and types
  with the same name (created offline on both devices; the merged-away record
  stays as a hidden tombstone), repair tag cycles (concurrent moves), relink
  files, thumbnails and texts that arrived before their document, and revive
  tombstones whose chain loops or whose end stays missing. Dedupe by id comes
  with step 16; orphaned files, thumbnails and texts and old tombstones are
  only counted until a later cleanup step (#32). Ported from the old app
  (`MetadataMaintenance.mergeDuplicates`, `TagHierarchy.breakCycles`,
  `TagCycleRepair`, `StoreChangeObserver`, `SyncMonitor`).
- **Conflicts:** the field-level behaviour of `NSPersistentCloudKitContainer`
  is proven with a two-device test in step 1, not assumed. Automatic writes
  (classification) check the field again right before saving and save in
  one transaction, so they never overwrite an edit from the other device.
- **Migrations:** with CloudKit only lightweight stages are possible;
  conversions of synced data are one-time, flagged passes. Every schema
  version has a migration test.
- **Store location** (decided in step 1): `Application Support/Dokumentum/Dokumentum.store`
  in the app's own container, not the app group. The share extension never
  opens the store, the app group exists only on iOS, and a second process
  would bring its memory limit to the CloudKit mirror. CloudKit and the local
  fallback use the same file. Moving it later is a migration.
- Fallback: should SwiftData + CloudKit hit a wall we cannot work around
  (performance with the PDFs, conflicts), the store sits behind one
  `ArchiveStore` boundary in `Core`, so a move to `CKSyncEngine` with SQLite
  stays possible without touching the features. Not planned.

### 3.3 Model (v1)
| Entity | Fields (all with defaults, as CloudKit requires) |
|---|---|
| `Document` | id, instanceID, title, createdAt, modifiedAt, documentDate, isInbox, pageCount, fileSize, textSourceRaw, processingStateRaw, processingDeviceID, processingClaimedAt, contentHash (SHA-256 of the original bytes), originalFileName, sourceRaw, deletedAt (trash), deadlineDay, deadlineLabel, deadlineSetAt, deadlineDoneAt, deadlineDismissedDay, correspondent, documentType, tags, file, thumbnail, text |
| `DocumentFile` | id, instanceID, createdAt, documentID, pdfData (external storage), document |
| `DocumentThumbnail` | id, instanceID, createdAt, documentID, imageData (external storage), document |
| `DocumentText` | id, instanceID, createdAt, documentID, extractedText, document |
| `Tag` | id, instanceID, name, colorHex, createdAt, mergedIntoID, mergedAt, matchModeRaw, matchPattern, parent (nested tags), children, documents |
| `Correspondent` | id, instanceID, name, createdAt, mergedIntoID, mergedAt, matchModeRaw, matchPattern, documents |
| `DocumentType` | id, instanceID, name, createdAt, mergedIntoID, mergedAt, matchModeRaw, matchPattern, documents |

Built in step 1 as `DokumentumSchemaV1` (#29). Names beyond the first draft:
- `instanceID` on every entity: set at insert, never changed or copied. It is
  the second key of every repair winner (after `createdAt`) and the handle of
  one record, because records can share an `id` until step 16. It is in V1
  because a migration cannot add it deterministically: each device would
  generate its own value.
- `createdAt` on metadata and blobs (the winner rule), `mergedIntoID` and
  `mergedAt` on metadata (tombstones of a same-name merge), `documentID` on
  blobs (relinking an early arrival).
- `colorHex` (the old app's and the folder format's name) instead of `color`;
  the frozen enums are stored as `textSourceRaw`, `processingStateRaw` and
  `sourceRaw` and read through typed accessors with a fallback.
- `DocumentText` instead of `Document.extractedText` (see 3.2). A document's
  file and text are created once, at import, in the importer's save; later
  steps write them in place.
- `matchModeRaw` and `matchPattern` on tags, correspondents and types (step 9,
  #10): the record's matching rule, as in paperless-ngx; `""` is no rule. The
  mode is the frozen enum `MatchMode` (none, any, all, exact, regex), always
  case-insensitive. Added additively as `DokumentumSchemaV2` (#10, part 1a),
  so V1 stores open through one lightweight stage.
- `deadlineDay`, `deadlineLabel`, `deadlineSetAt`, `deadlineDoneAt` and
  `deadlineDismissedDay` on documents (step 11, #12): one deadline per
  document. The day is an ISO 8601 `yyyy-MM-dd` string (`""` for none), a
  calendar day with no time zone, read by its first ten characters only, so
  a later build may append a time; `deadlineSetAt` is when a user last set
  it, `deadlineDoneAt` when it was marked done, and `deadlineDismissedDay`
  the day up to which due-date suggestions are dismissed. Added additively
  as `DokumentumSchemaV3` (#12, part 1), one lightweight stage from V2.

Later steps add fields additively (notes, favorite, ASN, saved views, trash
retention; matching rules are the first, in V2, and deadlines the second, in
V3). Names follow
the old app where they fit, so the archive folder format (step 16) can stay
compatible with its version 1.x.

### 3.4 Processing pipeline
Import → PDF (images become PDF pages) → store → background processing:
text from the PDF, else Vision OCR (German and English) → invisible text
layer → thumbnail → page count → (from step 7) classification, the same run
classifying a document right after its text; from step 9 the matching rules
(#10) set an empty correspondent and type and add tags in the text's write,
before the classification, and "Apply Matching Rules" applies them to every
document on request; from step 10 detection (#11) fills an empty
correspondent and issue date from the first page's sender block and text:
in the text's write when no classification follows, otherwise after the
classifier, in the classification's write (Apple Intelligence wins). From
step 11 a due date in the text (#12, part 2b) is not part of the pipeline: the
detail reads the open document's stored text on demand and only suggests it,
and nothing automatic writes a deadline. A processing queue with one job
at a time across the Vision and the model stage (the plan of #8, T6: the
system runs model requests one after the other anyway). Classification runs
once per document (state `classify`, then `done`).
- **Claims:** a device processes only documents it has claimed
  (`processingDeviceID`, `processingClaimedAt`). The importing device claims
  first. Another device takes over a claim older than 6 hours (the Mac
  preferably), so a document never stays "processing" because the iPhone
  was not opened again. Clocks can differ: a claim that looks younger also
  expires once the other device has seen it unchanged for 6 hours by its
  own clock (#97).
- **Resume at launch** is the normal path; on iOS
  `BGContinuedProcessingTask` / `BGProcessingTask` continue work in the
  background.
- **Share extension:** it never opens the store. It copies the files into a
  queue folder in the app group; the app imports them on its next launch or
  activation. This avoids two processes mirroring one CloudKit store and the
  extension's memory limit.
- **Duplicates:** SHA-256 over the original bytes before the text layer is
  added (a layered PDF has a different hash).

### 3.5 Search
v1: an in-memory index over title, correspondent, type, tags and text (read
from `DocumentText`; a text that arrives after its document is added then), built
off the main actor (`ModelActor`) at launch and updated incrementally from
local changes and remote imports, with German/English
normalisation (case, diacritics, simple prefix matching). Target: under
200 ms per query for 5,000 documents on the iPhone, measured in step 6 with
5,000 synthetic documents on the device. If the target is missed,
a local SQLite FTS5 index per device replaces it behind the same interface.

### 3.6 Porting from document-archive
| Ported (cleaned up, tests along) | Rebuilt | Dropped |
|---|---|---|
| PDF building from images, text layer (`TextLayer`), Vision OCR (`DocumentRecognition`), tag hierarchy with duplicate merge and cycle repair, `StoreChangeObserver`/`SyncMonitor`, test infrastructure (`ProcessingEnvironment` task-local seam, `TestSupport.waitUntil`, `VisionGate` probes, `Checkpoint`, rendered test pages) | store setup, list/detail/sidebar UI for two device classes, settings, the on-device classifier with its limits (step 7, #8: the predecessor was not readable, so its limits were measured again; P0, no refusal note in v1, P8), import flows, image cleanup and scanner wrapper (built in step 4, #5; the predecessor's code was not read, maintainer decision M1), sender and date detection (step 10, #11: the old `FieldDetector` was not readable, so it was designed fresh); new: the share extension and its queue (the old app never built them, #4) | iPad paths, `LegacyMigration`, container migration, weak linking and `#available` branches, `MistralClient` and all Mistral code, watch folder (for now), the old app's undo stash (step 15 has only an undo notice for a delete) |

## 4. Development process
- Workflow, roles, labels and review rules as in `pklnx/dev-process`; the
  repository's own CLAUDE.md names the risky changes for this app: CloudKit
  schema changes (label `schema`), deletes, rewriting user data, entitlements
  and capabilities, any new network access.
- Tests: Swift Testing for both packages (`swift test`, macOS), unit tests on the
  iPhone simulator for the app target, a UI smoke suite (iPhone and Mac) of
  at most 10 tests. No real documents, no network, no real iCloud in tests
  (in-memory store).
- CI (decided 2026-10-28, section 6, question 1; changed 2026-11-12: build and
  tests moved from Xcode Cloud to GitHub Actions macOS runners, `app.yml`, jobs
  `app-ios` and `app-macos`): GitHub Actions on Linux runners (`ubuntu-24.04`) run the rest.
  | Where | Check | Content |
  |---|---|---|
  | GitHub Actions `app.yml` (formerly Xcode Cloud `PR` and `Main`) | `app-ios`, `app-macos`: one job per platform: iOS (one iPhone simulator) and macOS, test plan `Default` (app tests plus the tests of both packages) | build and tests; the UI smoke suite follows as a separate action once its compute cost is known. The check names are in section 2 |
  | GitHub Actions `checks.yml` | `lint` | Python check scripts and their self-tests (labels file, project invariants; more scripts arrive with the steps that need them) |
  | GitHub Actions `checks.yml` | `localization` | the String Catalog check |
  | GitHub Actions `checks.yml` | `kit-linux` | `swift format lint` and the `DokumentumKit` tests with the pinned Swift for Linux toolchain |
  | GitHub Actions `secrets.yml` | `secret-scan` | gitleaks (pinned binary, SHA-256) over the commits a PR adds |

  swift-format, the formatter bundled with the Swift toolchain, replaces
  SwiftFormat and SwiftLint, so no extra tool is needed.
- Signing in tests: Xcode Cloud's test actions sign ad hoc (`CODE_SIGN_IDENTITY=-`
  in their log), whatever the project says, so the team in the project does not
  decide how they sign (question T4 of #1, answered for tests; whether a
  distribution build needs the team stays for step 8). macOS refuses to launch an ad
  hoc test host with `com.apple.developer.*` keys, so `ci_scripts/ci_post_clone.sh`
  applies `Config/Unsigned.xcconfig` in the workflows `PR` and `Main`, never in
  any other workflow (such as an archive workflow, #9 P2 b). So macOS tests in
  Xcode Cloud and in local builds run without the entitlements and outside the
  sandbox; only the maintainer's signed build
  exercises them.
- State of the signed check: part 3 of step 0 merged on unsigned local evidence,
  Xcode Cloud and its reviews, with the signed output deferred (2026-11-07). On
  2026-11-11 the maintainer ran the first signed, sandboxed Mac build on the MacBook
  Air (`main` at `2066e51`): the entitlements are exactly those of
  `Config/Dokumentum-macOS.entitlements`, and the imports of #4's M1 work in the
  sandbox (#1 step 9 and #4 M1, results on both issues). The signed iPhone build
  and the device check on the iPhone come with #4's M2/M3; #1 stays open until
  then.
- Development setup: implementation (Xcode, simulators, `xcodebuild`) happens
  on the maintainer's Mac mini (since 2026-11-10), with Claude Code there (local
  sessions, `gh` available). Agents have no signing identity and build unsigned; signed builds
  and device runs are the maintainer's, with their account. Cloud sessions (Linux) plan,
  review plans and verify only what runs on Linux: scripts, workflows, docs,
  and `swift test` / `swift format lint` for `DokumentumKit`. Details:
  [index.md](./index.md).
- Releases: TestFlight builds from a tag, version `YY.MM.N` (e.g. `26.11.1`);
  every TestFlight upload needs the maintainer's OK, like releases elsewhere.
  The upload is manual (decided 2026-11-13, #9 P2): the maintainer archives both
  platforms on the MacBook Air from a clean clone of the release commit, validates
  them in Organizer, then tags `vYY.MM.N` and distributes with "TestFlight Internal
  Only" (internal testing only, P8). The gate before it is `release.yml` (tests plus
  an unsigned Release build) at the release commit. Runbook, the CloudKit
  Production deploy, the soak test and the device checklist:
  [release.md](./release.md).

## 5. Roadmap

Four GitHub milestones, one per scope block the maintainer named on
2026-10-26. One issue per step; sub-issues per PR part come with each plan.
No due dates: the order matters, not the date. Sizes: S ≈ 1 PR,
M ≈ 2-3 PRs, L ≈ 4+ PRs.

### Milestone 1: Core (v1 on TestFlight)
| # | Step | Content | Size |
|---|---|---|---|
| 0 | Repository and skeleton | Xcode project (multiplatform target, two packages, share-extension placeholder), identifiers and entitlements, CI (Xcode Cloud + GitHub Actions on Linux), lint, CLAUDE.md, docs, issue templates, labels, ported test infrastructure. Maintainer steps: App ID, iCloud container, app group, capabilities in the developer portal. Empty app starts on both devices from Xcode | M |
| 1 | Data model and sync | Models of 3.3, versioned schema with migration test, `ArchiveStore`, store location, CloudKit private DB, in-memory store for tests, frozen-enum rule, repair passes, sync status view, two-device conflict test | L |
| 2 | Library UI | Sidebar (inbox, all, tags, correspondents, types), list, detail with PDFKit viewer, "still downloading" state, edit title/date/metadata, delete into a minimal trash (restore, empty); Mac: three columns and menu commands; iPhone: navigation stack. Works with fixture documents seeded by a debug command, since import comes in step 3 | L |
| 3 | Import | Files picker, drag and drop and ⌘O (Mac), share extension with app-group queue (iOS), photos from the library; images → PDF; duplicates by SHA-256; processing queue with claims | M |
| 4 | Scan | VisionKit document camera (iPhone), photo cleanup (corners, filter, rotate) | M |
| 5 | OCR and text layer | Vision OCR (de/en), text from existing PDFs, invisible text layer, thumbnails, page count, resume after quit | M |
| 6 | Search | Index and query of 3.5, search field in the library, filter by tag/correspondent/type/inbox | M |
| 7 | On-device classification | Foundation Models suggest title, correspondent, type, tags and date; suggestions are applied only to empty fields; a switch in settings; unavailable without Apple Intelligence, with the reason shown | M |
| 8 | v1 on TestFlight | App icon and colours from `pklnx/design-system`, a two-device sync soak test (a week of use on Development, with synthetic documents only: maintainer decision 2026-11-02) before the CloudKit schema goes to Production (maintainer; it freezes the v1 schema), TestFlight pipeline, privacy manifest, the hardened-runtime decision, a check list on both devices. Hardened runtime is decided (P1 on #9): on for the app target only, through one variable per target in `Config/Project.xcconfig`, which `scripts/check-project.py` pins; privacy manifests for the app and the share extension, kept matched to the code by `scripts/check-privacy-manifest.py` (#182, part 1 of #9); the app icon is a text-only Icon Composer bundle with design-system's layers, and the accent has two roles, tint and fill, with the system accent on the Mac (#184, part 2b of #9; development/index.md, "Look") | S |

Order: 0 → 1 → 2 (can start once the model is merged) → 3 → 4 and 5 →
6 and 7 in parallel → 8.

Step 2 as built (the source seam, fixtures and launch arguments, the debug command, menus, accessibility and
the evidence screenshots): [`index.md`, "Library UI"](./index.md#library-ui).

### Milestone 2: Automation
| # | Step | Content | Size |
|---|---|---|---|
| 9 | Matching rules | Rules on tags, correspondents and types (any word, all words, exact phrase, regex), applied on import and on request | M |
| 10 | Sender and date detection | Correspondent from the sender block, issue date from the text (rebuilt; the old `FieldDetector` was not readable) | M |

### Milestone 3: Deadlines and reminders
| # | Step | Content | Size |
|---|---|---|---|
| 11 | Deadlines and reminders | Deadlines on documents, an overview, local notifications, detection from the text as a suggestion | M |

Step 11 so far: the schema (V3, #12 part 1), the overview and editing (part 2a: the Deadlines list with its count, the
Go menu's ⌘4, the detail's deadline bar and the info panel's "Deadline" section), as built in
[`index.md`, "Deadlines"](./index.md#deadlines), and the due-date suggestion from the text (part 2b: `DueDateDetector`,
read on demand in the detail, with "Add Deadline" and "Dismiss"). Part 3 reminds.

### Milestone 4: System integration
| # | Step | Content | Size |
|---|---|---|---|
| 12 | Spotlight and Shortcuts | Spotlight index (on-device, can be turned off), App Intents: add a file, find documents | M |
| 13 | Notes, favorites, ASN | Markdown notes, favorites, archive serial number | M |
| 14 | Saved views | Saved filters in the sidebar | S |
| 15 | Full trash | Retention (30 days), automatic purge, an undo notice after a delete | S |
| 16 | Backup export | The archive folder format (PDF + JSON per document) to a folder in iCloud Drive or on the Mac; dedupe by id (with files, thumbnails and texts) for id-preserving imports | M |

### Without a milestone (backlog)
| # | Step | Content | Size |
|---|---|---|---|
| 17 | dokumentum.app | A small static site: product page, privacy policy, support address (needed before any App Store listing) | S |

## 6. Open questions
1. **CI for a private repository** (decided 2026-10-28). GitHub bills
   macOS minutes at 10× for private repositories, so the included minutes
   would cover roughly 10 PR runs a month (check github.com/pricing; GitHub
   has announced price changes). Decision: Xcode Cloud for build, tests and
   later the TestFlight uploads (25 compute hours a month with the developer
   program; to verify in App Store Connect, Xcode Cloud, Usage), and GitHub
   Actions on Linux runners for lint, the localisation check, the
   `DokumentumKit` tests and the secret scan. Section 4 lists the checks.
   The repository is public since 2026-11-12; the split stays as decided.
   **Changed 2026-11-12:** the Xcode Cloud quota was used up and it cancelled
   every build, and as the repository is public, GitHub Actions macOS runners
   cost nothing. Build and app tests now run there (`app.yml`, jobs `app-ios`
   and `app-macos`, the PR check); Xcode Cloud is kept for the TestFlight
   uploads. **Changed 2026-11-13** (#9, P2): v1's TestFlight uploads are manual
   from the MacBook Air, not an Xcode Cloud workflow, and the maintainer
   disabled Xcode Cloud's `PR` and `Main` workflows on 2026-11-13, before the
   quota resets on 6 December ([release.md](./release.md), M0 and M6).
   Archiving on GitHub Actions stays rejected: it would need signing certificates
   and an App Store Connect key as secrets in a public repository.

To settle inside the steps: the minimum OS against the CI runners' Xcode (step 0), what
`pklnx/design-system` offers for a native app (step 8; it may only have web
tokens, then the colours and the icon are derived from it).
