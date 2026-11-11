# Development

How to work on Dokumentum. Product and architecture: [plan.md](./plan.md).
Workflow, roles and review rules: `CLAUDE.md` and
[pklnx/dev-process](https://github.com/pklnx/dev-process).

This page grows with the steps. It describes what exists now: repository
basics, the Xcode project, the packages, the test infrastructure and the checks.

## Where work runs

| Where | Used for |
|---|---|
| The maintainer's Mac mini, local Claude Code sessions (`gh` available) | Implementation: Xcode, simulators, `xcodebuild`, `swift test` for the packages. The primary evidence for app code, except for signing and entitlements: agents have no signing identity and build unsigned, see "Build and test". |
| The MacBook Pro, signed by the maintainer with their Apple Account | Signed builds and runs on the iPhone and the Mac: the only place that exercises the macOS entitlements and the sandbox. None has run yet: the signed output and the device check are deferred to before signed or iCloud work relies on them ([plan.md](./plan.md), section 4). |
| Cloud session (Linux, no Xcode) | Planning, plan reviews, and everything that runs on Linux: the scripts below, workflows, docs, and (once the packages exist) `swift test` and `swift format lint` for `DokumentumKit`. |
| Xcode Cloud | The PR check for build and app tests (workflows `PR` and `Main`), later TestFlight. Configured by the maintainer in Xcode and App Store Connect. |
| GitHub Actions, `ubuntu-24.04` | The checks below. |

## Setup on the development Mac

1. macOS 27, Xcode 27.x installed and selected
   (`xcode-select -p`). Agents have no signing identity and never create a
   certificate, a profile or a device registration; signed builds are the
   maintainer's (the Account Holder of the individually enrolled team).
   Selecting Xcode with `xcode-select -s` needs `sudo`; without it, set
   `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (in
   `~/.zprofile` for login shells).
2. `gh auth status` is OK.
3. Once per clone, enable the secret-scan hook:

   ```sh
   brew install gitleaks
   git config core.hooksPath .githooks
   ```
4. The iOS 27.0 simulator runtime (it has the iPhone 18 Pro), installed through Xcode, Settings,
   Components.
5. For macOS UI tests: the screen unlocked, the test runner allowed under System Settings, Privacy &
   Security, Screen & System Audio Recording, and the app window on a display that draws. Windows open on
   the display with the pointer; on a second display that is asleep or off, every window screenshot and
   `performAccessibilityAudit` fail with "Failed to create screenshot. Image creation failed".
6. If the SQL-log tests fail with `markerNotFound` although the unified log is enabled, look for a stray
   file in `/var/db/diagnostics/timesync/`; removing it fixed the log on 2026-11-07.
7. Several agents on one Mac serialize their `xcodebuild` runs through a shared lock directory (`mkdir`
   to take it, `rmdir` after the run).

## The project

`Dokumentum.xcodeproj` has one multiplatform app target (`Dokumentum`: iOS and native
macOS, iPhone only), the share extension `DokumentumShare` (iOS only, embedded through platform
filters; it links `DokumentumKit` and nothing else, see "Share extension and queue"),
`DokumentumTests` (Swift Testing, hosted by the app) and `DokumentumUITests`. Two local packages
live in `Packages/`.

- **Folders are synchronized** (`objectVersion = 77`, `PBXFileSystemSynchronizedRootGroup`):
  adding a file to `Dokumentum/`, `DokumentumShare/`, `DokumentumTests/` or `DokumentumUITests/`
  does not change `project.pbxproj`. An `Info.plist` must stay out of them ("Multiple commands
  produce"), so those files live in `Config/`.
- **Settings live in `Config/Project.xcconfig`**, the project's base configuration. A setting in the
  `.pbxproj` overrides it unseen, so `scripts/check-project.py` fails `lint` when the project or a
  target sets a key from that file. What differs per target goes through a variable named after the
  target (`DOKUMENTUM_ENTITLEMENTS_$(TARGET_NAME)` and the like), and the script asserts what each
  target resolves to; a new target needs a row in its `TARGETS`. Personal overrides go into
  `Config/Local.xcconfig` (not in git), the only include `Project.xcconfig` may have.
- **Capabilities change by editing the entitlements files in `Config/`**, which the script pins key by
  key, so an unreviewed capability fails `lint`. Do not use Xcode's Signing & Capabilities editor; strip
  whatever it writes into the `.pbxproj`. The settings of Xcode's "App Sandbox & Hardened Runtime"
  category inject entitlements past these files, so the script rejects them all, except
  `ENABLE_HARDENED_RUNTIME = NO` until step 8.
- **The Mac app reads files the user picks** through `com.apple.security.files.user-selected.read-only`
  (an App Sandbox key, not an App ID capability): the open panel and ⌘O need it, and the import only
  reads. A drop needs no key when the app receives it as a file (`FileRepresentation`, a copy); a
  dropped file URL taken as a plain `URL` could not be read in the sandbox, with or without the key
  (probe on #58). The unsigned path below drops all keys, so only a sandboxed build shows what this key
  does.
- **Each package is a folder reference in the project**, not an
  `XCLocalSwiftPackageReference`. With the latter `xcodebuild` builds the package but silently drops
  its tests from a test plan and still reports success. `check-project.py` guards this.
- **Signing is automatic with the committed team.** Signed builds run on the maintainer's machine. Agents'
  local builds and Xcode Cloud's test workflows build macOS without team and entitlements, see "The unsigned
  path".

## Build and test

From the repository root (`-derivedDataPath build` keeps a build in the ignored `build/` folder). These
are the agents' commands. A machine with a signing identity leaves out the `XCODE_XCCONFIG_FILE` prefix.

```sh
# Test plan Default: DokumentumTests, DokumentumKitTests, DokumentumTestSupportTests, DokumentumCoreTests
XCODE_XCCONFIG_FILE=Config/Unsigned.xcconfig xcodebuild -scheme Dokumentum -destination 'platform=macOS' test
XCODE_XCCONFIG_FILE=Config/Unsigned.xcconfig xcodebuild -scheme Dokumentum -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' test

# Test plan UISmoke: DokumentumUITests
XCODE_XCCONFIG_FILE=Config/Unsigned.xcconfig xcodebuild -scheme Dokumentum -testPlan UISmoke -destination 'platform=macOS' test
XCODE_XCCONFIG_FILE=Config/Unsigned.xcconfig xcodebuild -scheme Dokumentum -testPlan UISmoke -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' test

# A build for a device, compiled and embedded but not signed
xcodebuild -scheme Dokumentum -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

# The packages alone, without a simulator
swift test --package-path Packages/DokumentumKit
swift test --package-path Packages/DokumentumCore

# Formatting: the same command as `kit-linux`
swift format lint --strict --recursive --configuration .swift-format Dokumentum*/ Packages/
```

**The unsigned path.** With the team and the entitlements in the project, a macOS build without a
signing identity exits 65 (`No profiles for 'space.pklnx.Dokumentum'`); simulator builds and
`swift test` do not need one. That error ends with the advice to pass `-allowProvisioningUpdates`: it
does not apply, and the flag stays barred for agents. The fix for a forgotten prefix is the prefix.
`Config/Unsigned.xcconfig` makes the macOS build ad hoc, without a team and without entitlements. It
sets only macOS-conditioned keys, so the simulator keeps the real team and keys, which a build shows in
its `*-Simulated.xcent` files. The project does not reference the file: it reaches a build only through
this variable, or through Xcode Cloud's copy (see "Xcode Cloud").

**What this leaves untested.** macOS tests in local unsigned builds and in Xcode Cloud run without the entitlements and
outside the sandbox, with no iCloud or push keys. Only the maintainer's signed build exercises them. A
macOS test passing here says nothing about behaviour that depends on them.

- Use the variable as a prefix on a command run from the repository root, and do not export it in a
  profile. Its path is resolved against the current directory. Exported, it would break every build from
  another directory and on every commit without the file.
- A wrong path fails a build loudly (exit 65, `Unable to open file ... referenced by
  XCODE_XCCONFIG_FILE`), but `-showBuildSettings` exits 0 and silently shows the override absent. Do not
  take its output as proof that the override applies.
- A device build (`generic/platform=iOS`) has no ad hoc form: it needs `CODE_SIGNING_ALLOWED=NO`, as
  above. No agent ever creates a certificate, a profile or a device registration, or passes
  `-allowProvisioningUpdates`.

The iPhone 18 Pro exists only on the iOS 27.0 simulator runtime, so the destination names the OS.
UI tests on macOS need Automation Mode: without it the run ends with "Timed out while enabling
automation mode". `automationmodetool` shows its state ("This device DOES NOT REQUIRE user
authentication" is what a run without a person needs; the mode itself stays disabled between runs).
Allowing that needs the machine's administrator password once
(`sudo automationmodetool enable-automationmode-without-authentication`).

## Waiting in tests

**Tests never wait for time.** No `Task.sleep`, no `Task.yield()` loops, no fixed debounce and no
"wait N ms, then check": a test waits for a signal that says the thing happened, and a scaled timeout
is only the safety net that ends a test whose signal never comes. Why: under parallel tests on a busy
runner, every `Task.sleep` in the test host needs a thread of the cooperative pool to wake up. While
text recognition and PDF rendering fill the pool, every sleep stalls, on the predecessor's iOS CI
runner for a minute and more. A wait that then compares the clock with its deadline finds it passed,
while the work it waits for has not had its turn yet. A fixed sleep "long enough" for a debounce or a
request is the same bet.

`scripts/check-test-waits.py`, part of `lint`, enforces this in `DokumentumTests`, `DokumentumUITests`,
`Packages/*/Tests`, `DokumentumTestSupport` and `DokumentumCoreTestSupport`. A use that is justified stays when it says why, on its
line or in the comment lines directly above it: `// allow-wait: <reason>`. Waits of XCTest with a
condition (`waitForExistence`) are fine: UI tests use them. The script does not flag `clock.sleep(for:)`
on a `Clock`: its pattern leaves out `.sleep(`, because `debounce.sleep(…)` must stay allowed. That rule
holds without the script.

One timed wait is allowed: a negative check, which has no signal because it shows that something does
not happen. `negativeCheck()` in `WaitingTests` is the helper for it, and `BlockedActorTests` does the
same with a longer net. Both use `safetyNet`, and a slow machine can make them miss a broken helper, but
they can never fail a correct one.

The tools are in the library `DokumentumTestSupport` (`Packages/DokumentumKit`), which every test
target can import:

| Tool | For | Instead of |
|---|---|---|
| `Checkpoint` | A handshake with any hook or stub: the hook stops at `pass()` (`passBlocking()` in a synchronous hook), the test awaits `reached()`, acts, and calls `release()`. Release in a `defer`, so a failing test does not leave the hook waiting | A stub delay or a sleep in a hook; `Task.yield()` and hoping the work got that far |
| `ManualDebounce` | Code that sleeps through an injected function: the test sees each event start the quiet period (`waitForStarts`) and ends it with `fire()` | A short debounce and sleeping "twice the debounce" |
| `TestSignal` | Any event: the hook calls `fire()`, the test awaits `wait(for:)`; `TestSignal.counting(stream)` counts the elements of a stream | Polling a counter |
| `TestSupport.waitForCancellation` | A body that must keep running until its test stops it | Sleeping for a long time |
| `TestSupport.waitUntil` | State that has no signal. It counts rounds, not the clock, so a stall costs one round, not the budget | A hand-written poll with a deadline |

```swift
let reached = Checkpoint()
defer { reached.release() }
var environment = ProcessingEnvironment.live
environment.someHook = { await reached.pass() }   // each step adds its own hooks
let run = Task { await work(environment) }
await reached.reached()   // the work stands at the hook now
run.cancel()
reached.release()
```

**A test must not hang when a helper or the code under test is broken.** Wait with a tool above, and
await `task.value` only once a signal said that the task ends. `Checkpoint.pass()` holds a task forever
when nobody releases it; `WaitingTests` shows the pattern.

**Tests never block the main actor** with synchronous work that can take long: they call the
`@concurrent` API instead.

**The safety net waits with the waiter's actor.** A `TestSignal` wait (and `Checkpoint.reached`,
`ManualDebounce.waitForStarts`) passes its caller's isolation (`#isolation`) to
`TestSupport.safetyNet`, and every round takes a turn on that actor after its sleep. The work a
main-actor test waits for usually needs the main actor too, so while the main actor is busy the net
stands still with it instead of running out. A wait from a nonisolated test counts pool rounds only.
`BlockedActorTests` checks the net and each of the three waits.

**The timeout scale.** Every wait multiplies its timeout by `DOKUMENTUM_TEST_TIMEOUT_SCALE` (1 when it
is missing or not a positive number), for a run that is slowed down on purpose. `swift test` passes the
variable on as it is. For `xcodebuild`, set `TEST_RUNNER_DOKUMENTUM_TEST_TIMEOUT_SCALE=3`: it strips
the prefix and passes the variable on to the test host.

**The seam.** `ProcessingEnvironment` (`DokumentumCore`) holds what the pipeline reads from outside. A
test runs its body in `ProcessingEnvironment.$current.withValue(…) { … }`, so tests running in parallel
each see their own. It is a task-local: `Task {}` inherits it, `Task.detached` does not, so code that
detaches captures it first. Each step adds the fields it needs. `TestEnvironment.isIsolated` says
whether this run stays away from real data; it holds in the app host, in the test bundles `xcodebuild`
runs, and under `swift test`.

## Data model and sync

The model is `DokumentumSchemaV1` in `Packages/DokumentumCore/Sources/DokumentumCore/Model/`, seven
`@Model` classes that `NSPersistentCloudKitContainer` mirrors to the private database of
`iCloud.space.pklnx.Dokumentum` (record types `CD_<entity>`). Features name the typealiases in `Model.swift`
(`Document`, `Tag`, …), never a schema version. Fields and reasons: [plan.md](./plan.md), section 3.3.

**CloudKit rules.** Every attribute has a default or is optional; every relationship is optional and has an
inverse; nothing is `@Attribute(.unique)`; no delete rule is `deny`; no relationship is ordered. Synced enums
are raw `String`s read through typed accessors with a fallback (`source`, `textSource`, `processingState`); a
setter never writes a fallback back. `SchemaTests` checks the model, `scripts/check-schema-snapshots.py` the
committed snapshots.

**Large data in records of their own.** `Document` holds no large field. The PDF (`DocumentFile`), the
thumbnail (`DocumentThumbnail`) and the extracted text (`DocumentText`) are one each per document, behind
to-one cascade relationships. SwiftData on 27 ignores `propertiesToFetch` (measured on #29), so this shape is
what keeps lists light. **A document's file and text are created once, at import**, in the same save as the
document, the text with an empty `extractedText`. Later steps write `pdfData` and `extractedText` in place and
never insert a second file or text; processing requires `text != nil`. A second one that still arises (two
devices before syncing) stays unlinked and is counted by the repair, never deleted.

**The store.** `ArchiveStore` is the one boundary around it. `StoreChoice` decides per launch:

| Launch | Store |
|---|---|
| A test run (`TestEnvironment.isRunningTests`) | in memory, never synced |
| DEBUG build with `-UITestSeed YES` / `-UITestEmptyStore YES` | in memory, with sample data / empty |
| With the CloudKit entitlement (every iOS build; a signed macOS build) | `Application Support/Dokumentum/Dokumentum.store`, mirrored to CloudKit |
| Without it (an unsigned macOS build) | the same file, local only |

If CloudKit cannot open, the same file opens locally; if that fails too, `Dokumentum-local.store` next to it.
The store is in the app's own container, never in the app group. UI tests pass the launch arguments as
`-key value` pairs: a bare flag swallows the next argument. Tests get containers from
`DokumentumCoreTestSupport` (`TestSupport.makeContainer()`, `makeContainerOnDisk()`), which keeps them alive
until the end of the run.

**The list query.** `DocumentListQuery` is the only list fetch of documents and returns `DocumentSummary`
values (inbox, all, trash). `DocumentListQuerySQLTests` records the SQL of the fetch with `SQLLog` and fails if
a statement names `ZDOCUMENTTEXT`, `ZDOCUMENTFILE` or `ZDOCUMENTTHUMBNAIL`. Core Data's SQL can be read only
under `swift test` (in the `xctest` runner of `xcodebuild` it logs none, measured on #29), so that test runs
in `swift test --package-path Packages/DokumentumCore` and is skipped in Xcode. Core Data reads the SQL
setting once per process, at its first store: `SQLLog.enable()` comes before any store opens (the container
helpers call it).

**The trash.** `DocumentTrash` (DokumentumCore) is the only code outside DEBUG tools that deletes a `Document`
(#3, part 4). Moving to the trash and restoring set or clear `deletedAt` and `touch()` the document; nothing else
changes, so a restored document keeps its inbox state and metadata. Empty Trash deletes only the documents its
confirmation counted, after reading them again in a context of its own: one restored or trashed meanwhile stays.
A document's linked PDF, thumbnail and text go with it by the model's cascade; tags, correspondents and types
stay. **A PDF or its text that is not linked to its document at that moment is not deleted** (it can still be
arriving by sync, or arrive after the delete): it stays as a hidden orphan that the repair counts, until #32
decides what happens to orphans (plan of #3, T7). #31 moves this note to `sync.md` once that file exists.

**Adding schema version N** (only with a real model change: identical versions have the same checksum):
1. Copy the models into `DokumentumSchemaV<N>` (version `N.0.0`) and change them additively: new attributes
   optional or defaulted, new relationships optional with an inverse.
2. Add it to `DokumentumMigrationPlan.schemas` with one `.lightweight(fromVersion:toVersion:)` stage. A
   conversion of synced data is a one-time pass behind a flag, never a custom stage.
3. Move the typealiases in `Model.swift` to V(N).
4. Write the snapshot: `DOKUMENTUM_SCHEMA_DUMP_DIRECTORY=$PWD/Packages/DokumentumCore/Tests/DokumentumCoreTests/Schema
   swift test --package-path Packages/DokumentumCore --filter SchemaTests` writes `schema-v1.txt`; add the
   same for `schema-v<N>.txt` in `SchemaTests`. Review the diff: only added lines.
5. Add a `StoreMigrationTests` case that writes a store with V(N-1) and opens it with V(N).

**Production freezes a version.** Until step 8 nothing is in Production, and V1 may still change in place (with
its snapshot, in the same PR, with the reason; a non-additive change also needs "Reset Development
Environment" in the CloudKit Console, a maintainer step). The PR that records step 8's deploy adds `1` to
`Schema/production-versions.txt`; from then on `check-schema-snapshots.py --base <sha>` fails if that snapshot
changes. Deploying the schema to Production is the maintainer's.

**Development schema.** CloudKit creates record types when records are first saved, or all at once through
`DebugSchemaInitializer.run()` (DEBUG, from #2's Sync lab, on a temporary store; never at launch and never
from tests or an unsigned build).

**The repair.** `RepairPlanner` (DokumentumKit) decides, `DokumentumCore/Repair/` carries it out on the store:
re-point references to tombstones, merge same-name metadata into tombstones, break tag cycles, relink early
blobs, revive tombstones; it never deletes (plan of #2, "Repair passes"). `RepairScheduler` runs it at launch,
after debounced store changes (`StoreChangeObserver`) and at the end of a CloudKit import, only for stores on
disk, off the main thread. A run reads a light snapshot once to plan (no linked blob is loaded; `RepairSQLTests`
checks the SQL under `swift test`), and saves once per pass that changed something and never otherwise. Each
pass re-reads only the records it writes and re-checks every operation on that read (I6).

**Concurrent saves (I6).** A `ModelContext` that saves over a row another save changed since it read it writes
back the whole row, every field, not only the ones it changed (measured on #56: Core Data re-selects the row on
the optimistic-locking conflict, and the `UPDATE` sets every field the stale object holds). So the repair never
writes over a row state it has not read: right before a pass saves, it reads the rows it changed (inverse-only
rows included) and the records its operations name in another context and compares every field with what it
read. If one differs, the pass writes nothing and the next run, which that save triggers, plans again. Nothing
is ever written to undo. Residual window: a save to one of those rows that commits between that check and the
pass's commit is overwritten in that row. Measured on 2026-11-07 in #56's review (`swift test` debug build, from the check's start
to the pass's `didSave`, 3,000 documents in two correspondents' halves): about 0.06 s for a merge moving 300
documents, and 0.24 to 0.40 s for one moving 1,500, with one to five tags per document, depending on the data
and the machine's load (review A measured 0.40 s). It grows with the rows the pass writes, never with the archive.
A document's file, thumbnail and text links are part of its row (by identifier, without loading the blob), so a
link another save makes in the window is seen. The external-storage data of a relinked blob is not compared.
Also not re-checked: records inserted in the window. A revived tombstone whose chain end arrives just then, or a
document that newly points at a merge's loser, is left for the next run, which merges or re-points it; nothing
is lost, but the keeper can differ from the one another device chose until both converge.

Repair tests seed a `RepairSnapshot` into a store on disk (`RepairStoreFixtures.swift`) and check
`RepairInvariants` and that the store ends where the planner's simulation ends (`CheckedRepair`).

The check before the save (`RowState`, `RowState.read`) lives in `DokumentumCore/Store/RowStates.swift`, one copy for
both background writers: the repair and the processing queue. `RowStateTests` pins its fields against the schema.
**Copies sharing an `instanceID`** (a copied record) are read by one rule, `RowRecords.oldestFirst`: every reader keeps
the oldest `createdAt`, and among equal dates the first row the store returns. The repair's plan (`RepairStore.read`),
its apply and check (`RepairStore.touched`, where a merge's loser names its documents through its relationship and
they are read again by `instanceID`; `RowState.read`), and the queue's scan, fetches and check all follow it, so a plan,
its write and the check before the save meet the same row. The other copy is neither written nor checked by either:
its references stay as they are, also one to a record that a merge made a tombstone (`SharedInstanceIDTests`). The
order is applied in memory after the fetch, so the SQL the tests pin stays as it is.

**The processing queue** (#4, part 5). `ProcessingClaimRules` (DokumentumKit) decides per document; `ProcessingQueue`
(DokumentumCore, an actor) carries it out, one document at a time, off the main actor. Every document is claimed at
import by the importing device (`processingDeviceID`, `processingClaimedAt`, state `pending`); another device waits
until the claim is 6 hours old by its own clock, then takes it over. A claim more than 6 hours in the future counts as
expired, so a device with a fast clock that never comes back cannot keep a document waiting; a device with a slow clock
can be taken over early. Both cost at most a double processing with the same result. `done` and a state of a newer
build (`unknown`) are never touched; a trashed document waits for its restore; a document without its file data or its
text record waits, and processing never creates a text. Each attempt is counted in this device's `UserDefaults`
(`ProcessingFailures`, never synced) **before** its stage runs, so a crash or an out-of-memory kill during the stage
counts too; a stage that returns clears the counter. The third failed attempt writes `failed`, and an attempt beyond
the third (the earlier ones never returned) writes `failed` without running the stage, so such a PDF cannot crash every
launch. Another device whose own counter is below 3 still tries a `failed` document. A counter also goes when its
document is seen `done` or gone. Of copies sharing an `instanceID`, the queue uses the one the rule above names.
- **Reads.** The scan reads only `Document` rows that are not `done`; the PDF is read once per processed document, by
  key, in a context that ends with the load, before anything is written (a file whose data has not arrived causes no
  write). `ProcessingSQLTests` checks the SQL under `swift test`.
- **Writes** (T6): the claim write (only when the claim is not already this device's and fresh) and the result write
  (`pageCount` when it differs, `done` or `failed`). Each is one synchronous call with no `await`: a fresh context
  fetches the document, re-checks what the decision was based on (state, claim device and time, not trashed, the same
  file, a text record) and writes nothing if one differs; it sets only the changed fields, reads the row again in a
  second fresh context (`RowState.read`) and saves only if every field still equals what it fetched. Otherwise it rolls
  back and writes nothing; the next run comes from the other save's store change. Never a compensating write. A result
  is dropped when the row no longer holds the claim the work ran under (a takeover) or links another file than the one
  processed (compared by the file row's identifier, read from the document row without loading the file).
- **Residual window**, as for the repair: a save to the same document that commits between the queue's re-read and the
  commit of its save is written over with the values the queue read. Plan §3.2's "never overwrite an edit" holds on one
  device except within this window, which is one document row's read plus its save; across devices it depends on how
  CloudKit merges the record (#31's C1 and C2). A save at the queue's own `willSave` lies inside it, so the tests save
  their edits through `ProcessingQueue.Hooks.beforeCheck`, between the fetch and the re-read
  (`ProcessingConcurrentEditTests`, including #56's repair as the other writer, in both orders).
- **Triggers** (`ProcessingScheduler`, stores on disk only): launch, every save that inserts a `Document` (an import,
  from any context), `scenePhase == .active`, every debounced store change, and the next expiry of another device's
  claim that a run waited for, while the app runs. One run at a time; requests during a run queue one more. The
  queue's own save is a store change; the run it triggers writes nothing, and the chain ends there. A document left in
  `processing` by a quit is processed again by the launch run.
- **Debug only:** `-ProcessingTakeoverSeconds <n>` replaces the 6 hours (the two-device check, #4's M4). Release
  builds do not contain it.

## Library UI

The library window (step 2, #3) is one `NavigationSplitView`: three columns on the Mac, a navigation stack on
the iPhone. Its code is in `Dokumentum/Features/Library/` and `Dokumentum/Features/Detail/`.

**The source seam.** The views never see `@Model` objects. `LibraryModel` (`@MainActor @Observable`) reads
values from a `LibrarySource`: `snapshot()` (rows, tags, correspondents, types), `changes` and
`loadPDF(instanceID:)`. The app's source is `StoreLibrarySource` (DokumentumCore), which reads the documents
only through `DocumentListQuery` and the open document's PDF off the main actor (`DocumentFileLoader`).
Sidebar filters, counts and the tag tree are pure Kit code over these values (`LibrarySelection`,
`LibraryCounts`, `TagTree`). Edits go through `DocumentEditor`, the trash through `DocumentTrash`.

**When the library reads again.** `changes` fires at once after any save of a context of the app's container
(an edit, a trash move, an import), and after every debounced signal of the app's one `StoreChangeObserver`
(#30). That observer adds what arrives without a context of the app: the CloudKit mirroring's remote changes
(`NSPersistentStoreRemoteChange` of the store) and, through `RepairScheduler`, the end of each CloudKit import.
The repair follows the same observer. It exists for stores on disk only; an in-memory store follows its own
saves. A local save therefore reads the library once more after the debounce (5 s); a read is light.

**Fixtures.** `Dokumentum/Features/Fixtures/` is `#if DEBUG` only, so a Release build contains no sample data
(checked with `strings` on its binary). `FixtureCatalog` has the sample documents, with fixed `id`s and
`instanceID`s (`5EED…`), and `SyntheticPDF` draws their PDFs; no real document is read.
- `-UITestSeed YES`: an in-memory store with the samples. UI tests, screenshots and a look at the app use it;
  nothing is saved. `-UITestEmptyStore YES`: an empty in-memory store. `-UITestLocalStore <name>`: a new local
  store on disk in a temporary folder, removed when the app quits. `-UITestFailingSaves YES` (in-memory stores
  only): every save of the info panel's editor fails and is rolled back, for the "The title could not be saved."
  line under the title field.
- The debug command "Add Sample Documents" (the Debug menu on the Mac, the sidebar's toolbar menu on the
  iPhone) writes the samples into the open store, with fresh `instanceID`s; a second run adds nothing. With a
  store on disk it asks first.
- To look at the app with sample data: Mac,
  `open -n build/Build/Products/Debug/Dokumentum.app --args -UITestSeed YES -ApplePersistenceIgnoreState YES`;
  iPhone simulator, `xcrun simctl launch <udid> space.pklnx.Dokumentum -UITestSeed YES`.

**Stale window state (T5 of #3).** In an unsigned local build, the Mac app under its real bundle ID opened no window
after the root view's type changed: restoration state for that ID names the old type. Hence one stable root,
`LibraryRootView`, in `WindowGroup(id: "library")`, and `-ApplePersistenceIgnoreState YES` in every UI test
launch (`UITestApp`) and in the command above. Every launch argument comes as a `-key value` pair: a bare flag
takes the next argument as its value, and a left-over `YES` is opened as a document, after which SwiftUI opens
no window. Whether the explicit scene id prevents the state on a signed, sandboxed build is checked on the
maintainer's Mac (#1, step 9).

**Mac menus (PQ15).** Go: Inbox ⌘1, All Documents ⌘2, Trash ⌘3. Document: Show Info ⌘I. Edit: Move to
Trash ⌘⌫. File: Import Documents… ⌘O, Empty Trash… ⌘⇧⌫ (asks first). Each item is disabled when it has
nothing to act on (`@FocusedValue` of the focused window). ⌘⌫ while a text field is edited stays with the
field (`CommandDeleteRouting`), so the field must lose the focus when the user turns to the list: a click on a
document row, the selected one too, and a change of the selection give the list the focus (`DocumentListView`;
without it ⌘⌫ emptied the title instead of trashing the document, review of #74). `MenuCommandsSmokeTests`
drives them through the menu bar's key equivalents.

**Accessibility.** Tests query identifiers (`AccessibilityID`), never localized text. Every sidebar row has
the count as its VoiceOver value ("3 documents"): on the Mac the rows are tagged labels, not
`NavigationLink`s, because a link exposes no value there. Such a label is a button to VoiceOver, so it has an
accessibility action that selects the row, as a click does. Document rows read as one sentence
(`LibraryDocument.accessibilityLabel`). On the Mac they are tagged rows too, not links, for the same reason
the audit gave ("Unknown role" on a link's row, #82): a button to VoiceOver through its select action, which
selects the document. They have no button trait: the action alone makes the row a button, and without the action
the row has "Unknown role" with or without the trait (review of #88, #89).
The Mac document list is named by its navigation title ("Inbox"). The Mac placeholders ("No document selected",
"Inbox empty", "Still downloading" and the others) are `PlaceholderView`, not `ContentUnavailableView`: the
system view's title is secondary (3.11:1 on white in light mode) and it gives VoiceOver its symbol and title as
one element. `PlaceholderView` keeps the system view's positions, fonts and weights, draws the title and the
description in the primary colour (#82, maintainer decision P1; #89, maintainer decision of 2026-11-11), hides
the symbol from VoiceOver, puts the identifier on the title and `<identifier>.description` on the description
(#82, P2; #89). The iPhone keeps `ContentUnavailableView`, whose title is already primary.

The audit cannot guard the placeholders' contrast. In light it reports "Contrast failed" on the regular-weight
15 pt description whatever its colour: `.primary`, `.secondary`, black and `labelColor` all fail, the medium and
semibold weights pass (measured in the plan of #89 and again in its PR). The UI tests therefore measure the text
contrast of the placeholders' titles and descriptions from each element's own screenshot
(`UITestApp.assertTextContrast`: the background is the most common pixel, the text the pixel farthest from it in
relative luminance, at least 10 pixels must reach 4.5:1). `LibrarySmokeTests` measures "Still downloading" and
"This PDF cannot be shown", `SampleDocumentsSmokeTests` "No documents". The descriptions'
`documentDetail.*.description` identifiers start with an app prefix, so an audit added later in one of these
states would fail in light on that false positive instead of only listing it.

`LibrarySmokeTests` runs `performAccessibilityAudit(for: .all)` (`UITestApp.auditAccessibility`): an issue on
an element with one of the app's identifiers fails the test, the others are listed in an `audit-…` text
attachment of the run. On the Mac two issues are accepted (`UITestApp.acceptedAuditIssues`). Each matches the
exact identifier, audit type and description; any other issue on the same element still fails. An accepted
issue is listed in the attachment as `ACCEPTED (<reason>)`, and one the audit did not report in that run as
`ACCEPTED, not reported`, without failing, because the audit is not fully stable.
- `sidebar.syncOff`, contrast, "Contrast failed": text on the `.bar` material. The lowest measured contrast is
  7.34:1 in light (#74) and 10.35:1 in dark (#82), on window PNGs. The bar is translucent, so the values depend
  on what lies behind the window. The audit fails text over the material whatever its contrast; the background
  stays (#74, maintainer decision 4).
- `import.menu`, action, "Action is missing": the AppKit toolbar menu button that a SwiftUI `Menu` becomes.
  None of the 13 SwiftUI variants tried passes (#82). VoiceOver opening the menu: not verified, #3 Done-when.

**Evidence screenshots.** Only of the app's window: `UITestApp.attachWindowScreenshot` takes
`app.windows.firstMatch.screenshot()`. Never `XCUIScreen.main` and never `screencapture`: on the Mac they show
the whole desktop with other apps' windows. The xcresult's automatic screen recording shows the desktop too,
and test plan options did not turn it off, so every `UISmoke` run gets a new temporary `-resultBundlePath`,
the PNGs are exported from it, and the bundle is deleted right away, whether the run passed or failed:

```sh
R=$(mktemp -d)/run.xcresult
TEST_RUNNER_DOKUMENTUM_UI_LANGUAGE=de XCODE_XCCONFIG_FILE=Config/Unsigned.xcconfig xcodebuild -scheme Dokumentum \
  -testPlan UISmoke -destination 'platform=macOS' -derivedDataPath build -resultBundlePath "$R" test
xcrun xcresulttool export attachments --path "$R" --output-path <evidence folder>
rm -rf "$R"   # keep only the window PNGs; delete any video the export wrote
```

- `TEST_RUNNER_DOKUMENTUM_UI_LANGUAGE=de|en`: the language of the run (the screenshot names end with it).
- `TEST_RUNNER_DOKUMENTUM_UI_CONTENT_SIZE=XXXL`: the Dynamic Type size on the iPhone (a `UIContentSizeCategory`
  name without its prefix, such as `XXXL` or `AccessibilityXXXL`).
- `TEST_RUNNER_DOKUMENTUM_UI_APPEARANCE=light|dark`: the Mac app alone in light or dark mode; the system's
  appearance setting stays as it is (#82). Light through the launch argument `-NSRequiresAquaSystemAppearance
  YES`, dark through the app's own `-UITestAppearance dark` (Debug builds; `-AppleInterfaceStyle Dark` as a
  launch argument left the app light). The screenshot names then end with `-light-<language>` or
  `-dark-<language>`. Record the system's appearance with the run: a Mac set to "Auto" is light by day.
- On the Mac the screen must be unlocked during a run (`ioreg -n Root -d1 | grep IOConsoleLocked`, recorded
  before the run), and the test runner needs the screen-recording permission. Without it every window
  screenshot failed with "Failed to create screenshot. Image creation failed" (#67).
- A window screenshot can still show another window lying over the app's; whoever passes PNGs on opens each
  first. PNGs never go into the repository: a PR lists each with its SHA-256.

## Share extension and queue

On the iPhone, sharing a PDF or an image to Dokumentum (#4, part 4) goes through the app group
`group.space.pklnx.dokumentum`. **The extension never opens the store**: it copies each shared file into
the group's queue folder and closes, and the app imports the items at launch and on every activation.

- **The format** is `ShareQueue` (`DokumentumKit`, Foundation and the C library only, tested on Linux), the
  one piece both sides link. `ShareQueue/Items/<UUID>/` holds `payload` (the bytes, always under this name)
  and `item.json` (`version` 1, `originalFileName`, `typeIdentifier`, `createdAt`, `attempts`). The writer
  builds an item in `Incoming/<UUID>/` and renames the folder into `Items/` as its last step, so the reader
  never sees a half-written item; the app removes `Incoming/` leftovers older than a day. The file name is
  data, never a path: it only becomes the title, without path components and control characters (`../../x.pdf`
  gives "x"). An `item.json` of a newer version is left alone; an unreadable one moves to `Failed/`.
- **The extension** (`DokumentumShare/`) takes each attachment's PDF type, else its image type, through
  `loadFileRepresentation` (copied inside the call), else `loadDataRepresentation`. It never decodes an
  image, so an attachment that offers only an image object is not saved and the sheet shows "This item
  cannot be saved" with OK. Otherwise it shows "Saving to Dokumentum…" and closes on its own. It does not log
  (`Log` lives in Core). Its strings are in its own catalog, `DokumentumShare/Localizable.xcstrings`.
  `check-project.py` holds it to linking exactly `DokumentumKit` and fails on the words `SwiftData` and
  `DokumentumCore` in its sources.
- **The app** (`ShareQueueImporter`, iOS only) reads `Items/` oldest first and imports each item through the
  app's one `DocumentImporter`. One run at a time: a launch also produces `.active`, and a request during a
  run queues exactly one more run. Before each import it counts an attempt in `item.json` (written
  atomically). **An item is removed only after its document was saved or the importer reported a
  duplicate**; a crash in between imports it again next time, which becomes a duplicate, and then it goes.
  A failure keeps the item; its third failure moves it to `Failed/`, which nothing empties, and the notice
  names it once. Share-queue imports never select or open a document (PQ12); duplicates and items moved to
  `Failed/` appear as the usual import notice. A run that stays away from real data (`TestEnvironment.isIsolated`)
  and every `-UITestLocalStore` launch refuse the group container (`ArchiveStore.isLiveStorePath`), so unit tests
  and UI-test launches never touch the queue; tests pass a temporary folder.
- **Regular files only, opened once, no symbolic link from the item's folder down** (#85, #87). Every file is
  opened once (`O_NOFOLLOW`, `O_NONBLOCK`) and checked on the open descriptor (`fstat`); a symbolic link, a
  folder, a FIFO, a socket or a device throws `NotARegularFile`, a missing file `POSIXError(.ENOENT)`, and a
  link swapped in after the open is never followed. The extension copies a lent file from that descriptor with
  `read(2)` and `write(2)` through one 1 MiB buffer, so its memory stays bounded whatever the file's size (a
  150 MB share, #95); the app reads a payload from the descriptor. Inside an item the app goes only through
  the descriptor of the item's folder, itself opened without following a link (`O_DIRECTORY`, `O_NOFOLLOW`):
  it reads `payload` and `item.json`, and counts an attempt with a new file written in full, synced and
  renamed over `item.json` in that folder (removed again if the rename fails). So an item folder swapped for a
  link is refused, and nothing is read or written through it. A linked `item.json` moves the item to
  `Failed/`, and an `Items/` entry is read only when it is a real folder. Not covered, by design: a symbolic
  link at `ShareQueue/` or `Items/` is followed (both are reached by path, our code creates them, and swapping
  them needs the same group access), so is one among the folders above a lent file (`/var` is a link to
  `/private/var`), and a hard link counts as a regular file. The item's name follows
  `ShareQueue.itemFileName`: the suggested name, else the lent file's, else the share's date and time; the
  type's extension is added only when the name has no PDF or image extension.
- **Signing.** Agents build the extension unsigned like the app; the simulator gets the group from the
  entitlements file. The app group on a device (both App IDs, the profiles) is the maintainer's (#4, M2 and M3).

## Logging

Every logger comes from `Log` (`DokumentumCore`): categories `store`, `sync`, `repair`, `import`, `processing`,
subsystem `space.pklnx.Dokumentum`. Counts, enum states and error domain and code are `.public`; names, titles, paths,
text and `localizedDescription` are `.private`. App code never prints, and a crash message is a fixed text.
`scripts/check-logging.py` enforces this in the app, the share extension and the packages' library code.

## Checks

| Check | Where | What it does |
|---|---|---|
| `lint` | GitHub Actions, `checks.yml` | Python only. Runs the self-tests of the check scripts, validates `.github/labels.json` (`scripts/check-labels.py`) and the project's invariants (`scripts/check-project.py`), flags tests that wait for time (`scripts/check-test-waits.py`), checks the logging rules (`scripts/check-logging.py`) and that the schema snapshots are additive and meet the CloudKit rules (`scripts/check-schema-snapshots.py --base`, with the full history checked out). |
| `localization` | GitHub Actions, `checks.yml` | `scripts/check-localization.py --catalog`: every entry of `Dokumentum/Localizable.xcstrings` and of the share extension's `DokumentumShare/Localizable.xcstrings` has a finished German translation (a plural `one` and `other`), and none is stale. |
| `kit-linux` | GitHub Actions, `checks.yml` | The only job with the Swift toolchain (`.github/actions/install-swift`, pinned with a SHA-256, one download per run): `swift format lint --strict` with the committed `.swift-format`, then the `DokumentumKit` tests, which include `DokumentumTestSupportTests`. |
| `secret-scan` | GitHub Actions, `secrets.yml` | Installs the pinned gitleaks, runs the scan's self-test (`scripts/secret-scan-test.sh`), then scans the commits the PR adds (`scripts/secret-scan-range.sh` prints the range). |
| Xcode Cloud `PR` | Xcode Cloud | Build and tests, see below. Checks: `Dokumentum \| PR \| Default - iOS`, `Dokumentum \| PR \| Default - macOS`, `Dokumentum \| PR`. |

Run the Python checks from the repository root:

```sh
python3 scripts/check-labels.py --self-test
python3 scripts/check-labels.py
python3 scripts/check-project.py --self-test
python3 scripts/check-project.py
python3 scripts/check-localization.py --self-test
python3 scripts/check-localization.py --catalog
python3 scripts/check-test-waits.py --self-test
python3 scripts/check-test-waits.py
python3 scripts/check-logging.py --self-test
python3 scripts/check-logging.py
python3 scripts/check-schema-snapshots.py --self-test
python3 scripts/check-schema-snapshots.py --base origin/main
```

`--catalog` only reads the catalogs. `python3 scripts/check-localization.py <derived data path>` also
finds strings the code uses that never reached their target's catalog: `xcodebuild` does not add them, only
Xcode's IDE does. Run it after a build with `-derivedDataPath <derived data path>`. A macOS build has no
strings of the iOS-only extension, so they are checked only once its target was built.

### Xcode Cloud

The maintainer sets up the workflows in Xcode and App Store Connect (plan on #1, maintainer step 6);
the repository holds only the shared scheme and `ci_scripts/`.

- Workflow `PR` (Pull Request Changes, target `main`, no file filter) and workflow `Main` (Branch
  Changes on `main`): Test action, scheme `Dokumentum`, test plan `Default`, once for one iPhone
  simulator and once for macOS. The Xcode version is the one in `.xcode-version`, macOS 27.
- `ci_scripts/ci_post_clone.sh` prints `xcodebuild -version`, `xcodebuild -showsdks` and `sw_vers`. It
  fails when the Xcode differs from `.xcode-version`, or when there is no SDK for the minimum OS in
  `Config/Project.xcconfig`.
- **Xcode Cloud's test actions sign ad hoc**: their command line has `CODE_SIGN_IDENTITY=-`, and macOS
  refuses to launch an ad hoc test host with `com.apple.developer.*` keys ("Runningboard has returned
  error 5", "Launchd job spawn failed"). So for the workflows `PR`, `Main` or `main`,
  `ci_post_clone.sh` copies `Config/Unsigned.xcconfig` to `Config/Local.xcconfig`, and prints that it
  did. Any other workflow, such as step 8's `Release`, keeps the real signing settings, and the script
  prints that it left them alone. Under Xcode Cloud without `CI_WORKFLOW` it fails.
- `ci_scripts/ci_post_xcodebuild.sh` runs the localisation check's build mode on
  `$CI_DERIVED_DATA_PATH` after `build`, `build-for-testing` and `archive`, unless `xcodebuild` failed.

Both can be tried locally by setting Xcode Cloud's variables by hand:

```sh
CI_PRIMARY_REPOSITORY_PATH="$PWD" ci_scripts/ci_post_clone.sh
CI_XCODEBUILD_ACTION=build-for-testing CI_XCODEBUILD_EXIT_CODE=0 CI_DERIVED_DATA_PATH=build \
  CI_PRIMARY_REPOSITORY_PATH="$PWD" ci_scripts/ci_post_xcodebuild.sh
```

### Secret scan

This repository is private, but credentials must still never be committed.
Three layers check for them:

- **Pre-commit hook** (local, opt-in, see Setup): runs gitleaks on the staged
  changes and refuses the commit on a finding. Without gitleaks installed it
  prints a notice and lets the commit through; CI checks again.
- **CI job `secret-scan`** (required): scans the commits of every pull request
  and of every push to `main`. The gitleaks version and the SHA-256 of its
  release archive are pinned in `.github/workflows/secrets.yml`; to update,
  change both (`sha256sum` of the new `gitleaks_<version>_linux_x64.tar.gz`,
  compared with the release's `checksums.txt`), and `minVersion` in
  `.gitleaks.toml`. Findings are printed redacted.
- **GitHub secret scanning with push protection** for known provider formats.

`.gitleaks.toml` uses gitleaks' default rules only. For a false positive,
prefer changing the code over an allowlist. If an exception is needed, add one
narrow `[[allowlists]]` block (exact path AND exact fake value, with a comment
saying why it is safe). A PR that touches the scan's configuration, scripts,
workflow or hook needs the maintainer's explicit OK before the merge
(`CLAUDE.md`, ticket flow step 7).

Run the scan's self-test locally with the pinned binary (the test builds
throwaway repositories in a temporary directory; no network, no real data):

```sh
# Linux x64; on macOS use the darwin archive from the same release page.
curl -sSfL -o gitleaks.tar.gz \
  https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz
echo "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb  gitleaks.tar.gz" | sha256sum --check --strict
tar -xzf gitleaks.tar.gz gitleaks
GITLEAKS="$PWD/gitleaks" sh scripts/secret-scan-test.sh
```

**After a leak, revoke the credential first.** Once something was pushed to
the repository it must be treated as known, even if the history is rewritten.

## Swift toolchain in a cloud session

A cloud session has no Swift. For `DokumentumKit` it installs
the pinned Swift for Linux release into its own scratchpad directory, not into
the system:

```sh
# Swift 6.4.1, ubuntu24.04; SHA-256 7d246c7114077ad01dba4ad897628446ada4c489d6c7dbcf39ae3f25cbe17e8b
dir=<scratchpad>/swift-toolchain && mkdir -p "$dir" && cd "$dir"
curl -sSfL -O https://download.swift.org/swift-6.4.1-release/ubuntu2404/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE-ubuntu24.04.tar.gz
echo "7d246c7114077ad01dba4ad897628446ada4c489d6c7dbcf39ae3f25cbe17e8b  swift-6.4.1-RELEASE-ubuntu24.04.tar.gz" | sha256sum --check --strict
tar -xzf swift-6.4.1-RELEASE-ubuntu24.04.tar.gz
export PATH="$dir/swift-6.4.1-RELEASE-ubuntu24.04/usr/bin:$PATH"
swift --version
```

The archive is about 1.1 GB. `swift format lint` is the formatter bundled with
it. The `kit-linux` job installs the same release with the same checksum, once
per run (`.github/actions/install-swift/action.yml`). Xcode bundles its own
swift-format for local use; its version cannot be compared with this one (it
prints `main`), so `kit-linux` has the last word on formatting.
