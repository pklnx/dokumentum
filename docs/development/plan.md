# Dokumentum: product and architecture plan

Status: plan review done (approve with changes, worked in); maintainer answers of 2026-10-26 included.
Replaces pklnx/document-archive (native app) and pklnx/paperless-go (server);
both are frozen, nothing is migrated from them.

## 1. Product

A personal document archive in the style of paperless-ngx for exactly two
devices of one person: an iPhone 18 Pro and a MacBook Air 13" (M4). Native
SwiftUI, data in the owner's private iCloud, no server, no accounts of its
own, no web UI.

Name: **Dokumentum** (maintainer decision, 2026-10-26). The maintainer owns
`documentum.app` (with c); the identifiers below use it in reverse-DNS form,
which needs no matching app name. Website domain: open question 2.

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
| Targets | One multiplatform SwiftUI app target (iOS + native macOS, not Mac Catalyst); a share extension for iOS (step 3) |
| Minimum OS | iOS 27, macOS 27 (the systems on both devices). Checked in step 0 against the Xcode on GitHub's macOS runners; if the runners lag behind, the minimum stays at the newest SDK they offer until they catch up |
| Bundle ID | `app.documentum.Dokumentum` (extension: `app.documentum.Dokumentum.Share`) |
| iCloud container | `iCloud.app.documentum.Dokumentum` (new; the old container stays untouched) |
| App group | `group.app.documentum` (app and share extension) |
| Languages | English source strings, German translation (String Catalogs), as in the old app |
| Device classes | iPhone (compact) and Mac (regular); no iPad layout, no size-class branches beyond these two |

Because only current systems are supported, nothing is weak-linked and there
are no `#available` branches (the old app carried both for iOS 18/macOS 15).

## 3. Architecture

### 3.1 Layers
```
Dokumentum (app target, SwiftUI)
  App/        entry point, scenes, commands (Mac menu), routing
  Features/   one folder per feature: Library, Detail, Import, Scan, Metadata, Search, Settings
  Core/       pure Swift, no SwiftUI: model, processing pipeline, OCR, PDF, search, classification
  Platform/   thin wrappers around PDFKit, VisionKit, Vision, FoundationModels, CloudKit status
DokumentumShare (iOS share extension)
DokumentumTests (Swift Testing), DokumentumUITests (a small smoke suite)
```
Two local Swift packages, so their tests run with `swift test` on macOS
without a simulator:
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
- **Large data in its own models.** `Document` holds metadata and the
  extracted text; `DocumentFile` (one per document) holds the PDF and
  `DocumentThumbnail` the thumbnail, each as `@Attribute(.externalStorage)`.
  The old app kept both blobs on `Document`, so every list query could fault
  them in. Separating them keeps lists and search light. The three records sync
independently and arrive in any order: `file` and `thumbnail` are optional,
the UI shows "still downloading", the delete rule is cascade, and the
repair pass removes orphans. List queries fetch without `extractedText`
(`propertiesToFetch`); if that is not enough, the text moves to its own
model too (decided in step 1 by measurement).
- **Schema versions from day one** (`VersionedSchema`, `SchemaMigrationPlan`),
  with a rule: a CloudKit schema change is additive, and deploying to
  Production is a maintainer step (it cannot be undone).
- **Sync status** is shown: last import/export event, iCloud account
  state, account change or sign-out, "iCloud storage full". The app works
  fully offline.
- **Frozen enums.** Values that sync (`processingState`, `textSource`,
  `source`) are stored as raw `String`s and mapped to a fallback when a
  value is unknown, so an older TestFlight build on the other device never
  fails to decode a newer case (lesson from the old app).
- **Repair passes after sync**, run after launch and after every CloudKit
  import event, with deterministic winners (`createdAt`, then id): dedupe
  by id, merge tags/correspondents/types with the same name (created
  offline on both devices), repair tag cycles (concurrent moves), remove
  orphaned files and thumbnails. Ported from the old app
  (`TagHierarchy.mergeDuplicates`, `TagCycleRepair`, `StoreChangeObserver`,
  `SyncMonitor`).
- **Conflicts:** the field-level behaviour of `NSPersistentCloudKitContainer`
  is proven with a two-device test in step 1, not assumed. Automatic writes
  (classification) check the field again right before saving and save in
  one transaction, so they never overwrite an edit from the other device.
- **Migrations:** with CloudKit only lightweight stages are possible;
  conversions of synced data are one-time, flagged passes. Every schema
  version has a migration test.
- **Store location** is decided in step 1 (app container vs. app group);
  moving it later is a migration.
- Fallback: should SwiftData + CloudKit hit a wall we cannot work around
  (performance with the PDFs, conflicts), the store sits behind one
  `ArchiveStore` boundary in `Core`, so a move to `CKSyncEngine` with SQLite
  stays possible without touching the features. Not planned.

### 3.3 Model (v1)
| Entity | Fields (all with defaults, as CloudKit requires) |
|---|---|
| `Document` | id, title, createdAt, modifiedAt, documentDate, isInbox, pageCount, fileSize, extractedText, textSource, processingState, processingDeviceID, processingClaimedAt, contentHash (SHA-256 of the original bytes), originalFileName, source, deletedAt (trash), correspondent, documentType, tags, file, thumbnail |
| `DocumentFile` | id, pdfData (external storage), document |
| `DocumentThumbnail` | id, imageData (external storage), document |
| `Tag` | id, name, color, parent (nested tags), documents |
| `Correspondent` | id, name, documents |
| `DocumentType` | id, name, documents |

Later steps add fields additively (notes, favorite, ASN, deadlines, matching
rules, saved views, trash). Names follow the old app where they fit, so the
archive folder format (step 16) can stay compatible with its version 1.x.

### 3.4 Processing pipeline
Import → PDF (images become PDF pages) → store → background processing:
text from the PDF, else Vision OCR (German and English) → invisible text
layer → thumbnail → page count → (from step 7) classification. A processing
queue with one Vision job and one model job at a time (the old app's
`VisionGate` / `OnDeviceGate` idea).
- **Claims:** a device processes only documents it has claimed
  (`processingDeviceID`, `processingClaimedAt`). The importing device claims
  first. Another device takes over a claim older than 6 hours (the Mac
  preferably), so a document never stays "processing" because the iPhone
  was not opened again.
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
v1: an in-memory index over title, correspondent, type, tags and text, built
off the main actor (`ModelActor`) at launch and updated incrementally from
local changes and remote imports, with German/English
normalisation (case, diacritics, simple prefix matching). Target: under
200 ms per query for 5,000 documents on the iPhone, measured in step 6 with
5,000 synthetic documents on the device. If the target is missed,
a local SQLite FTS5 index per device replaces it behind the same interface.

### 3.6 Porting from document-archive
| Ported (cleaned up, tests along) | Rebuilt | Dropped |
|---|---|---|
| PDF building from images, text layer (`TextLayer`), Vision OCR (`DocumentRecognition`), image cleanup and scanner wrapper, tag hierarchy with duplicate merge and cycle repair, `StoreChangeObserver`/`SyncMonitor`, share queue, on-device classifier with its limits and refusal note, field/date detection (later steps), test infrastructure (`ProcessingEnvironment` task-local seam, `TestSupport.waitUntil`, `VisionGate` probes, `Checkpoint`, rendered test pages) | store setup, list/detail/sidebar UI for two device classes, settings, import flows | iPad paths, `LegacyMigration`, container migration, weak linking and `#available` branches, `MistralClient` and all Mistral code, watch folder (for now), undo stash |

## 4. Development process
- Workflow, roles, labels and review rules as in `pklnx/dev-process`; the
  repository's own CLAUDE.md names the risky changes for this app: CloudKit
  schema changes (label `schema`), deletes, rewriting user data, entitlements
  and capabilities, any new network access.
- Tests: Swift Testing for both packages (`swift test`, macOS), unit tests on the
  iPhone simulator for the app target, a UI smoke suite (iPhone and Mac) of
  at most 10 tests. No real documents, no network, no real iCloud in tests
  (in-memory store).
- CI (GitHub Actions): `packages` (swift test, macOS), `app-ios` (build + tests,
  simulator), `app-macos` (build + tests), `lint` (SwiftFormat/SwiftLint,
  localisation check), `secret-scan`. Where the macOS jobs run is open
  (see section 6): a private repository pays 10× for macOS minutes.
- Releases: TestFlight builds from a tag, version `YY.MM.N` (e.g. `26.11.1`);
  every TestFlight upload needs the maintainer's OK, like releases elsewhere.

## 5. Roadmap

Four GitHub milestones, one per scope block the maintainer named on
2026-10-26. One issue per step; sub-issues per PR part come with each plan.
No due dates: the order matters, not the date. Sizes: S ≈ 1 PR,
M ≈ 2-3 PRs, L ≈ 4+ PRs.

### Milestone 1: Core (v1 on TestFlight)
| # | Step | Content | Size |
|---|---|---|---|
| 0 | Repository and skeleton | Xcode project (multiplatform target, two packages, share-extension placeholder), identifiers and entitlements, CI, lint, CLAUDE.md, docs, issue templates, labels, ported test infrastructure. Maintainer steps: App ID, iCloud container, app group, capabilities in the developer portal. Empty app starts on both devices from Xcode | M |
| 1 | Data model and sync | Models of 3.3, versioned schema with migration test, `ArchiveStore`, store location, CloudKit private DB, in-memory store for tests, frozen-enum rule, repair passes, sync status view, two-device conflict test | L |
| 2 | Library UI | Sidebar (inbox, all, tags, correspondents, types), list, detail with PDFKit viewer, "still downloading" state, edit title/date/metadata, delete into a minimal trash (restore, empty); Mac: three columns and menu commands; iPhone: navigation stack. Works with fixture documents seeded by a debug command, since import comes in step 3 | L |
| 3 | Import | Files picker, drag and drop and ⌘O (Mac), share extension with app-group queue (iOS), photos from the library; images → PDF; duplicates by SHA-256; processing queue with claims | M |
| 4 | Scan | VisionKit document camera (iPhone), photo cleanup (corners, filter, rotate) | M |
| 5 | OCR and text layer | Vision OCR (de/en), text from existing PDFs, invisible text layer, thumbnails, page count, resume after quit | M |
| 6 | Search | Index and query of 3.5, search field in the library, filter by tag/correspondent/type/inbox | M |
| 7 | On-device classification | Foundation Models suggest title, correspondent, type, tags and date; suggestions are applied only to empty fields; a switch in settings; unavailable without Apple Intelligence, with the reason shown | M |
| 8 | v1 on TestFlight | App icon and colours from `pklnx/design-system`, a two-device sync soak test (a week of real use on Development) before the CloudKit schema goes to Production (maintainer; it freezes the v1 schema), TestFlight pipeline, privacy manifest, a check list on both devices | S |

Order: 0 → 1 → 2 (can start once the model is merged) → 3 → 4 and 5 →
6 and 7 in parallel → 8.

### Milestone 2: Automation
| # | Step | Content | Size |
|---|---|---|---|
| 9 | Matching rules | Rules on tags, correspondents and types (any word, all words, exact phrase, regex), applied on import and on request | M |
| 10 | Sender and date detection | Correspondent from the sender block, issue date from the text (port `FieldDetector`) | M |

### Milestone 3: Deadlines and reminders
| # | Step | Content | Size |
|---|---|---|---|
| 11 | Deadlines and reminders | Deadlines on documents, an overview, local notifications, detection from the text as a suggestion | M |

### Milestone 4: System integration
| # | Step | Content | Size |
|---|---|---|---|
| 12 | Spotlight and Shortcuts | Spotlight index (on-device, can be turned off), App Intents: add a file, find documents | M |
| 13 | Notes, favorites, ASN | Markdown notes, favorites, archive serial number | M |
| 14 | Saved views | Saved filters in the sidebar | S |
| 15 | Full trash | Retention (30 days), automatic purge, undo notice | S |
| 16 | Backup export | The archive folder format (PDF + JSON per document) to a folder in iCloud Drive or on the Mac | M |

### Without a milestone (backlog)
| # | Step | Content | Size |
|---|---|---|---|
| 17 | documentum.app | A small static site: product page, privacy policy, support address (needed before any App Store listing) | S |

## 6. Open questions
1. **CI for a private repository** (decided before step 0). GitHub bills
   macOS minutes at 10× for private repositories, so the included minutes
   cover roughly 10 PR runs a month (check github.com/pricing; GitHub has
   announced price changes). Options: Xcode Cloud (25 compute hours a month
   with the developer program, to be verified; also uploads to TestFlight),
   a self-hosted runner on the MacBook (only while it is awake), or a
   public repository later.
2. **Website domain.** `documentum.app` is spelled with c, the app with k.
   Register `dokumentum.app` as well, or keep the site on `documentum.app`?
   Not needed before step 17.

To settle inside the steps: store location
(step 1), whether `extractedText` gets its own model (step 1, by
measurement), the minimum OS against the CI runners' Xcode (step 0), what
`pklnx/design-system` offers for a native app (step 8; it may only have web
tokens, then the colours and the icon are derived from it).
