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
| The MacBook Air (M5), signed by the maintainer with their Apple Account | Signed builds and runs on the iPhone and the Mac: the only place that exercises the macOS entitlements and the sandbox. The MacBook Air replaced the MacBook Pro on 2026-11-11 (maintainer decision on #1). The first signed Mac build passed that day (#1 step 9, #4 M1); the iPhone follows with #4's M2/M3 ([plan.md](./plan.md), section 4). |
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
devices before syncing) stays unlinked and is counted by the repair, never deleted. **The thumbnail too is made at
import** (#6, part 4, T5), in the same save: page 1, crop box and rotation applied, JPEG at quality 0.7, 480 px on
the long side (`Thumbnail`, about 8 KB); a page that cannot be rendered leaves it out and the import still
succeeds. Processing makes one only for a document imported before step 5 that the re-queue pass recorded (N3,
below), never for a document imported since, so a device that has the document before its thumbnail (records
arrive in any order) never makes a second one. The text layer does not change how a page looks, so a thumbnail is
never made again.

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
until the claim is 6 hours old by its own clock, **or until it has seen the claim unchanged for 6 hours** by its own
clock (#97, T8 of #6), then takes it over. When this device first saw each other device's claim is kept per document in
its `UserDefaults` (`ClaimSightings`, never synced, pruned with the failure counters). So a claim in the future (a
device with a fast clock) is never taken over at once and waits at most 6 hours of this device's time; a device with a
slow clock can be taken over early, and it then waits for the taker's claim, which looks future to it, until the taker
has written its result. Two devices never take a document from each other in turn, whatever their skew
(`ClaimSkewSimulationTests`, −48 h to +48 h). The early takeover costs at most a double processing with the same
result. `done` and a state of a newer
build (`unknown`) are never touched; a trashed document waits for its restore; a document without its file data or its
text record waits, and processing never creates a text. Each attempt is counted in this device's `UserDefaults`
(`ProcessingFailures`, never synced) **before** its stage runs, so a crash or an out-of-memory kill during the stage
counts too; a stage that returns clears the counter. The third failed attempt writes `failed`, and an attempt beyond
the third (the earlier ones never returned) writes `failed` without running the stage, so such a PDF cannot crash every
launch. Another device whose own counter is below 3 still tries a `failed` document. A counter also goes when its
document is seen `done` or gone. Of copies sharing an `instanceID`, the queue uses the one the rule above names.
- **Backoff** (#97, T9): after a failed attempt (thrown or timed out), the next one does not start before 1 minute after
  the failed one started, the third not before 10 minutes after the second, on this device's clock
  (`ProcessingBackoff`; the counter keeps `attempts` and `lastAttemptAt`, and step 3's plain number reads as attempts
  without a time). A start in the future (the clock was set back) is stored as now, so the retry is at most the delay
  away. The two runs of one import (its insertion and its store change) therefore spend one attempt, and three
  failures take at least 11 minutes. The decision is `wait(.retryAfter)`.
- **Stall watchdog** (#97, T10): a stage reports progress per page; with none for 300 s the queue cancels it without
  waiting, counts the attempt as failed (`timedOut` in the report) and goes on with the next document. The watchdog
  sleeps on the suspending clock, so a sleeping device never stalls. **One Vision job at a time also after a cancel**
  (N1): a cancelled stage stops after its page, but a framework call that ignores cancellation runs on until it
  returns, and its result is always dropped. A stage starts only when every stage cancelled by an interruption has
  returned and at most one timed-out stage is still alive; a second timeout while the first is alive ends the run as
  `stalled`, and the next run waits for one of them (`StageTracker`; each wait is logged, so a stage that never
  returns and blocks every later run until a relaunch shows in the log). #5's interactive corner detection uses Vision
  outside the queue, so this rule covers processing only.
- **Interruptions** (#97, T11): a known interruption does not count, an unknown end does. `ProcessingQueue.interruptNow()`
  is synchronous and callable from any thread: it gives the running attempt back (the counter and the backoff return to
  their values before the attempt), cancels the stage and ends the wait for it; a stage that returns later writes
  nothing. The counter's read-modify-writes and each attempt's state (running, finished, interrupted) sit behind one
  `Mutex` (N2): a refund happens only while its attempt runs, and a success marks the attempt finished and removes the
  counter in one step. The scheduler's `pause()` cancels the run and then calls it; a run cancelled after it counted
  an attempt and before its stage started gives the attempt back and starts no stage, so a pause between the decision
  and the stage is not lost. `resume()` ends the pause and runs the queue. The app pauses when the scene goes to the background on iOS and when the Mac app quits
  (`willTerminateNotification`), and resumes on `.active` (`ProcessingLifecycle`). The refund completes before iOS
  suspends the app, so a later kill of the suspended app leaves nothing counted; a crash, an out-of-memory kill or a
  power loss during a stage still counts.
- **App Nap** (#130): on the Mac each drain of the scheduler (a run and the runs queued during it) holds one
  `ProcessInfo` activity with `.userInitiatedAllowingIdleSystemSleep` (`SystemProcessingActivity`, begun at the top of
  `drain()` and ended in its `defer`, also after `pause()`), so App Nap does not slow a run while the window is hidden
  and an idle Mac still sleeps; the wake timer between runs holds none, so a wake at a claim expiry or a backoff end
  may come late while the app is napped, when nothing is running.
- **The stage** (#6, part 2): `DocumentStage` opens the PDF with PDFKit (unreadable, locked or page-less fails the
  attempt) and keeps the `PDFDocument` alive until it returns, because PDFKit cannot draw a page of a released document
  (P-h). A page whose own text (`page.string`, trimmed) has at least 16 non-whitespace characters (counted as
  `Character`s, so a decomposed umlaut counts once) is a text page (T2);
  every other page is rendered in grayscale at 2400 px on the long side, crop box and rotation applied (T3), and
  recognised by `VisionTextRecognizer`: `RecognizeTextRequest`, `.accurate`, `[de-DE, en-US]`, language correction on
  (T1; the only `import Vision` of the queue). Tests inject a stub recogniser (`TextRecognizing`); the few real-Vision
  tests (`VisionRecognitionTests`) wait with a 120 s safety net, because the first recognition in a process loads the
  model (24 s measured). They skip with the reason only where Vision itself cannot run: Vision does not list German
  and English, or a preflight recognition by `VisionTextRecognizer` alone throws (Xcode Cloud's macOS host throws the
  ML runtime's `e5rtError`); anything the stage throws afterwards fails them, and on the development Mac they pass. The
  document's text is the pages' texts in page order **joined with a form feed** (`ExtractedText.pageSeparator`; search
  relies on it), `""` when no page has text. A form feed inside one page's text becomes a newline, so the stored text's
  form feeds are exactly the page boundaries. `textSource` is `.pdfText` when every page was a text page, else `.vision`, also for
  a blank document, so `.none` means "never extracted". The stage checks for cancellation before each page and reports
  progress after it (and once before the first), one page image alive at a time.
- **The text layer** (#6, part 3, T4, B1, N5, R1-N1; `TextLayer`): when pages were recognised, the stage draws their
  lines invisibly into a copy of the PDF, which then **replaces the stored file; no original is kept** (the
  maintainer's P4). Data integrity comes first, so the stored bytes stay exactly as they are unless all of these hold:
  at least one recognised line with a box to draw; not encrypted (an owner password too); no `DokumentumTextLayer` key
  in the Info dictionary (a layered PDF is never layered again, also when a short page is recognised again); a catalog
  with only `/Type` and `/Pages`; page dictionaries with only `/Type /Parent /Contents /Resources /MediaBox /CropBox
  /Rotate`; and no font without an embedded program (`/FontFile`, `/FontFile2`, `/FontFile3`; checked in each page's
  resources, inherited ones included, form XObjects, tiling patterns and Type 3 fonts). So e-invoices with embedded
  files, page labels, XMP metadata (PDF/A), tags, bookmarks, forms, links and other annotations, extra page boxes and
  most born-digital PDFs keep their bytes and are searchable in the app only; scans and imported images (written by a
  `CGContext`) get the layer. A source written by PDFKit (a PDF rotated in Preview) may carry further catalog keys and
  then keeps its bytes too (R1-N2). The rewrite redraws every page with `drawPDFPage` into a `CGContext` page with the
  source's media and crop box, draws each line in Helvetica, invisible, into its box (font size the box height, scaled
  to its width; the box is placed on the page as shown and mapped back through the page's rotation), then a PDFKit
  pass sets each page's rotation, and an incremental update replaces the Info dictionary with the source's entries,
  each with its CoreGraphics type and exact value (strings and names as their bytes), plus the marker. PDFKit's own
  Info would change values (Keywords to an array, which Spotlight no longer reads; dates to this device's time zone;
  booleans to integers; PR #134's B1), and an Info entry that cannot be carried exactly (a stream) means no rewrite. **The guard** keeps the original
  unless the new PDF opens unencrypted with the same page count, catalog and pages within the allow-lists, the same
  media box, crop box and rotation per page, the same Info attributes (PDFKit) and every Info entry with its type and
  exact value (CoreGraphics; a date compared as its original text) plus the marker, each source page's
  own text lines and every drawn line in the page's text (whitespace ignored), and every page pixel-identical to the
  source at 300 px (RGB, crop box, rotation). The 300 px compare alone misses a substituted font (measured: a page in
  Helvetica without its program, redrawn, differs at 300 px on macOS at 48 pt but not on the iOS simulator, and at
  16 pt on neither), which is why the font check comes first. Why a file was kept is logged as a fixed code. The
  redraw and the guard report progress per page, for the watchdog, and stop between pages when the stage is
  cancelled. During the layer the stage holds the original, the rewrite and the renders: about twice the file in
  memory. A rewrite **keeps** every page's look, size, boxes, rotation, order and count, the page's own text, and
  every Info entry with its type and exact value; it **drops** the original bytes (the file is re-encoded;
  `contentHash` stays the hash of the imported bytes, so importing them again is still a duplicate), the trailer's
  `/ID` of the original and its earlier incremental revisions; bilevel images (CCITT, JBIG2) may be re-encoded
  losslessly as Flate, so such a file can grow; and it gains the invisible text. A layered file that is exported or
  shared and imported again is **not** a duplicate of its document, because `contentHash` is the original's.
- **Re-queue of step 3's documents** (#6, part 2, T6, N7): `ProcessingRequeue`, run by the queue at the start of each
  run until one pass completed, then never again on this device (the flag `processingRequeue.textV1` in the per-device
  defaults). Every `Document` that is `done` with `textSource == .none` (trashed ones too) goes back to `pending` **with
  this device's claim**, so this device processes it at once and the other device waits instead of taking it over; a
  document the other device re-queued (`pending`) or processed (`.pdfText`, `.vision`) fails the re-check. Each is one
  write under the discipline below; one that backs off leaves the flag unset, so the next run's pass tries again. The
  re-queued documents without a thumbnail are recorded (`processingRequeue.thumbnailBackfill`) for the backfill (N3).
- **Thumbnail backfill** (#6, part 4, N3): only for a recorded document, the stage's task renders a thumbnail after the
  stage returned, and the result write inserts and links it only when the document still has none. A thumbnail
  another save links in the window makes the write back off (the link is part of the document row), so no second
  thumbnail and no orphan arises on this device. The record goes when a result write of the document saved, and when
  the queue sees the document `done` (the other device processed it) or gone. Two devices can still both backfill
  the same old document only in a takeover race; the thumbnail that loses the link then stays an orphan the repair
  counts, as for files and texts.
- **Try again** (#6, P2): `ProcessingQueue.retry(_:)`, through `ProcessingScheduler.retry(_:)`, which runs the queue
  after it. A `failed` document goes back to `pending` with this device's claim in one write under the discipline
  below (re-check `failed`, `RowState` check, one save), and this device's failure counter and claim sighting are
  cleared after the save, so the next run starts again at attempt 1 without a backoff. It writes nothing for a
  document that is not `failed`, on an edit in the window (the counter stays), and while the queue holds a stage of
  that document on this device, from its start until the queue has handled its outcome (`busy`: the other device's
  `failed` can arrive during this device's own retry). An in-memory
  store has no scheduler; its "Try again" writes through a queue that no scheduler runs.
- **Reads.** The scan reads only `Document` rows that are not `done`; the PDF is read once per processed document, by
  key, in a context that ends with the load, before anything is written (a file whose data has not arrived causes no
  write). `ProcessingSQLTests` checks the SQL under `swift test`.
- **Writes** (T6): the claim write (only when the claim is not already this device's and fresh) and the result write
  (`pageCount` and `textSource` when they differ, the text record's `extractedText`, with a text layer the file
  record's `pdfData` and the document's `fileSize`, `done` or `failed`). The text is
  capped at 500,000 UTF-8 bytes (T7, N6): cut at the last page boundary below the cap, or, when the first page with text
  alone is over it, at its last whole character, after one form feed per blank page before it; the report counts it (`textsCapped`) and it is logged. The result write's check
  also reads the text row again, by key (`RowState.readText`; the only background writer of a linked text), and with
  a layer the file row (`RowState.readFile`, without comparing `pdfData`; the only writer of a linked file's data, under
  the exact claim, T16), so a save to either in the window makes it back off too. Each is one synchronous call with no `await`: a fresh context
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
  from any context), `scenePhase == .active` (`resume()`), every debounced store change, and the earlier of the next
  expiry of another device's claim, the next backoff end that a run waited for and the own claim expiry of a document
  waiting for the model (`ProcessingReport.nextWake`), while
  the app runs (on iOS also while a background task holds the work). No run starts while paused. One run at a time; requests during a run queue one more. The
  queue's own save is a store change; the run it triggers writes nothing, and the chain ends there. A document left in
  `processing` by a quit is processed again by the launch run.
- **Background on iOS** (#6, part 5, T13, N4, P3; `BackgroundProcessing`): two background tasks, both only calling
  the scheduler's `resume()` and `pause()`. **Continued processing** (`BGContinuedProcessingTask`, strategy `.fail`,
  identifiers `space.pklnx.Dokumentum.continued.<UUID>`) is asked for only when a user's import on this device
  completes: the app's importer is wrapped (`BackgroundImportNotifying`), and every user import (files, photos, the
  share queue, #5's scans) goes through it, while a CloudKit import never does, so the system's progress ("Processing
  documents", "3 of 12 documents") never appears for documents of the other device. Its progress counts the user's
  documents that are no longer open (`OpenDocuments`: `pending`, `processing` or `classify`, not trashed), updated after each store change; it completes when the runs
  drain (`ProcessingScheduler.didDrain`), with success only when none of the user's documents is open any more. If the system cannot start it now, the work waits for the
  foreground or the processing task. **The processing task** (`space.pklnx.Dokumentum.backgroundProcessing`,
  `BGProcessingTask`, no power or network needed) is asked for when the scene goes to the background with open
  documents and no task holds the work; the scheduler is paused then as before, and the task resumes it until the
  runs drain. While a task holds the work, the background does not pause. An **expiry** pauses (the attempt is given
  back) and fails the task; in the foreground the queue goes on at once. The foreground is the application's state
  (`UIApplication.applicationState`), not assumed: a launch in the background for the processing task brings no scene
  phase. Each identifier is registered once per
  process, at launch (the SDK kills an app that registers one twice). `Config/Info-iOS.plist` permits exactly the
  two identifiers and the `processing` mode; `scripts/check-project.py` pins it and rejects an identifier under
  another one's wildcard. The Mac has neither task. The real tasks cannot run on the simulator: maintainer step M5.
- **Classification** (#8, part 1; plan of #8, T1–T7, T10, T11). A second step after the text, one document at a time,
  with the queue's claims, attempts, backoff, watchdog and interruptions. The queue runs it only with a classifier
  (`DocumentClassifying`; the Foundation Models classifier and its wiring in `ProcessingScheduler.start` are part 2, so
  until then the app's queue has none and every text write sets `done` as before). Tests use a stub
  (`StubClassifier`); the model never runs in the queue's tests.
  - **The state** `classify` (frozen enum, raw `"classify"`; no schema change). The text result write sets it instead of
    `done` when the classifier is not `unavailable` on this device, the switch is on (`ClassificationSettings`,
    per-device key `classification.enabled`, default on, read at each decision; its UI is part 3) and the document is
    not older than the **cut-off** (P9): `classification.since`, written once at this device's first run with a
    classifier; a document whose `createdAt` (the importing device's clock) is earlier, also one still waiting for its
    text then or one of step 3's documents re-queued later, ends in `done` unclassified. An older build reads
    `classify` as `unknown` and never touches it (`ProcessingClaimRules` skips `unknown` before every other rule);
    `OpenDocuments` counts it as open (review N2). The rules treat `classify` like `pending` for claims, takeover,
    trash and backoff; it needs the text record, not the file. After a text write that set `classify`, the same run
    classifies that document next (T7). A document in `classify` always ends in `done`, never `failed`, so it is
    classified at most once, on one device, and a field the user cleared later is never filled again.
  - **Outcomes** (T4): no classifier, the switch off, or `unavailable` (`deviceNotEligible`,
    `appleIntelligenceNotEnabled`) write `done` without a model call; `notReady` waits without an attempt until this
    device's own claim is 6 hours old, then writes `done`: the staleness is checked before the claim renewal the rules
    would make (`ClassificationWait`, N4), the report wakes the scheduler at the claim's expiry (`nextClaimEnd`), and
    without an own claim the step claims first. A request that **throws** `ClassificationFailure.notReady` (the
    availability said `available`) is decided on the claim as it was before this run renewed it, so a stale own claim
    ends the wait there too (review B1 of #146); the queue then remembers it in memory, asks again at most every 15
    minutes (`notReadyRetry`) and finishes the document at the claim's end without another request.
    A text with fewer than 50 non-whitespace characters writes `done` without a model call. An answer fills the
    empty fields and writes `done`; a decline (refusal, guardrail, unsupported language) writes `done` with nothing
    filled and is logged as a fixed code, never retried (P8: no note; a decline whose `done` write meets another save
    is kept in memory like an answer, so the next run finishes without asking). `rateLimited` gives the attempt back
    and pauses classification in this queue until its reset date, else 15 minutes, and at least 1 minute, also for a
    reset date in the past (`nextRetry`). Every other error and the 300 s
    watchdog count an attempt in **the classification counter** (`ProcessingFailures` under `classificationFailures`,
    T5, forgotten with the text counter when the document is `done` or gone, N3), with the backoff of the text step; the
    third writes `done`. `interruptNow()` gives the attempt back to the counter it was counted in (`StageTracker`
    records it). Both kinds of stage share the one `StageTracker`, so one stage runs at a time (T6).
  - **Checks** (Kit, `SuggestionRules`, T10): the title trimmed, a placeholder dropped, cut at a word within 80
    characters; the correspondent within 80 characters and **found in the text** (folded as the search folds words);
    the type within 40 characters and 3 words; at most 3 distinct tags; the date a valid Gregorian date from 1900 to
    next year **found in the text** in one of the forms of `DateForms` (`14.01.2026`, `14.1.26`, `2026-01-14`,
    `14. Januar 2026`, `Jänner`, `14 January 2026`, `January 14, 2026`). A checked answer is kept in the queue's memory,
    keyed by document and text record, until its write saved (T3); after a text record swap the model is asked again.
    The memory (answers and waits) is dropped for a document that left `classify` another way.
  - **Empty fields** (`ClassificationFields`, T2, P2, P7): correspondent, type and tags when none is set; title and
    date only while the document was never edited (`modifiedAt == createdAt`; the date also `documentDate ==
    createdAt`; an empty title always). So a file-name title and the import date are replaced until the first edit,
    and an edit of any field (also the inbox flag, a trash and restore, a repair change) keeps title and date.
  - **The result write** (`writeClassification`, T3): one synchronous call under the write discipline above. A fresh
    context fetches the document and re-checks `classify`, the exact claim, not trashed and the same text record; it
    decides each field's emptiness on that row; it resolves names against the live records it fetches
    (`MetadataMatcher`: an equal normalized name in keeper order, else the longest word prefix either way, a tie none;
    without a match a new correspondent or type is inserted, P1; a tag only when exactly one live tag has the name,
    review N7, and never a new one); it sets only the fields it fills and `done`, without `touch()`, so a later edit is
    still the first; its check reads the document row and every metadata row it found linked or links again
    (`RowState.read`: a linked record must still be live under the same name). On a mismatch it rolls back and the
    next run decides again with the cached answer. The suggested date is stored as the detail's date picker stores a
    day: the time of day of the current `documentDate`, in the current calendar.
  - **Never overwriting an edit** holds on this store: an edit saved before the fetch makes its field non-empty (and
    title and date edited); one saved between the fetch and the check makes the write back off; the residual window
    is the queue's. An edit made on the other device that has not arrived cannot be seen: #31's two-device protocol
    gets a case for it (M3 of #8), which decides whether more than the claims is needed.
  - **Reads:** the step reads the text row by key and the metadata rows, never a file or thumbnail
    (`ProcessingSQLTests`). The known records passed to the classifier are the live ones, most used first, at most 100
    correspondents and types and 150 tags.
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

**Thumbnails and the processing state** (#6, part 4; maintainer decisions P1 and P2). Every row on the iPhone and
the Mac shows its first page's thumbnail at the leading edge (`RowThumbnail`), a fixed 40 × 56 pt, with a neutral
grey placeholder until it is there; it is decorative and hidden from VoiceOver, so a row's sentence is unchanged.
The source loads it (`LibrarySource.loadThumbnail`, `ThumbnailLoader` in Core: the document by key and its
thumbnail by key in a short-lived context, decoded off the main actor at 168 px, the decoded images kept by
`instanceID`, at most 300; `ThumbnailLoaderSQLTests`). A document without a thumbnail is looked for again at each
read of the library (`LibraryModel.revision`), so one that arrives by sync shows. Misses are not remembered: on a
store on disk every save, a local one too, posts `NSPersistentStoreRemoteChange`, so a remembered miss would have to
be forgotten at nearly every read anyway (review N3 of #135). The fixed size keeps the Mac's row
heights (#81): the hidden measuring copy shows the placeholder and loads nothing, and measures the same height. The
processing state is shown only in the detail (`ProcessingStatusBar`, above the PDF or its placeholder): "Text
recognition pending", "Recognising text…" or "Text recognition failed", and for a failed document "Try again"
(`LibraryModel.retryProcessing`, which reads the library again at once); not for a trashed document, which is not
processed until it is restored. Nothing for a processed document; the rows
show no state. The line's text is primary on the window's background, not on a material, and its identifier names
the state (`documentDetail.processing.pending|running|failed`, `documentDetail.processing.retry`).

**Fixtures.** `Dokumentum/Features/Fixtures/` is `#if DEBUG` only, so a Release build contains no sample data
(checked with `strings` on its binary). `FixtureCatalog` has the sample documents, with fixed `id`s and
`instanceID`s (`5EED…`), and `SyntheticPDF` draws their PDFs; no real document is read. Each PDF sample gets its
thumbnail as the importer makes it; the samples are processed except "Medical invoice" (pending), the annual
statement with the long title and "Scanned receipt" (failed; the receipt is not a PDF), for the detail's status
line. `LibrarySmokeTests` audits the failed line over the annual statement's PDF, not over a placeholder, whose
description is a known false positive of the audit in light.
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
no window. On the maintainer's signed, sandboxed build (#1, step 9, 2026-11-11) the window opened after an update
from the old root (`75340a0`) to `LibraryRootView`. The container's `Saved Application State` stayed empty in both
runs, though, so that run did not show whether the scene id overrides a stale state.

**Mac menus (PQ15).** Go: Inbox ⌘1, All Documents ⌘2, Trash ⌘3. Document: Show Info ⌘I. Edit: Find… ⌘F
(the search field, see "The search field"), Move to Trash ⌘⌫. File: Import Documents… ⌘O, Empty Trash… ⌘⇧⌫ (asks first). Each item is disabled when it has
nothing to act on (`@FocusedValue` of the focused window). ⌘⌫ while a text field is edited stays with the
field (`CommandDeleteRouting`), so the field must lose the focus when the user turns to the list: a click on a
document row, the selected one too, and a change of the selection give the list the focus (`DocumentListView`;
without it ⌘⌫ emptied the title instead of trashing the document, review of #74). `MenuCommandsSmokeTests`
drives them through the menu bar's key equivalents.

**Accessibility.** Tests query identifiers (`AccessibilityID`), never localized text. Every sidebar row has
the count as its VoiceOver value ("3 documents"): on the Mac the rows are tagged labels, not
`NavigationLink`s, because a link exposes no value there. Such a label is a button to VoiceOver, so it has an
accessibility action that selects the row, as a click does. Document rows read as one sentence; their thumbnail is
decorative and hidden from VoiceOver
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
semibold weights pass (measured in the plan of #89; `.primary` again in its PR, while in dark it passes). The UI tests therefore measure the text
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
  `loadFileRepresentation` (copied inside the call), else `loadDataRepresentation`. **A lent file that is not
  a regular file is not saved** (#87, the maintainer's decision on P1): when `ShareQueue` refuses it as
  `NotARegularFile` (a symbolic link, a folder, a FIFO, a socket or a device), there is no fallback to the
  data, so the extension never reads a link's target (Files lends a link as a link, for example one unpacked
  from a zip). **Once the lent file was opened, a failure does not fall back either** (#104, the maintainer's
  decision P1 = A): reading it or writing the queue (a full device, `EDQUOT`, `EIO`) throws `CopyFailed`, and
  the attachment is not saved, because the data would go to the same volume and loading it holds the whole
  file in the extension's memory. Only an attachment that lends no file, or a lent file that cannot be opened
  (gone, `ENOENT`, or `EACCES`), falls back to the data (`ShareQueue.fallsBackToData(afterFileError:)`). The
  order is `ShareQueue.saveAttachment`, tested in Kit; `ShareSaver` reaches the data only through it. It never
  decodes an image, so an attachment that offers only an image object is not saved. An attachment that is not
  saved makes the sheet show "This item cannot be saved" with OK. Otherwise it shows "Saving to Dokumentum…"
  and closes on its own. It does not log
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
  150 MB share, #95); the app maps a payload copy-on-write from the descriptor (`MAP_PRIVATE`: a write to it
  never reaches the file), so a large item is not held in memory (#98). The mapping outlives the item's
  removal and keeps its disk space until released; a payload changed or truncated by another process while
  mapped may crash the app or give it bytes that differ from the file at the open, so that the hash, the PDF
  check and the stored bytes may disagree (it needs group write access; the attempt is counted first, so such
  an item ends in `Failed/`), and mapping relies on the group container having no `NSFileProtectionComplete`.
  Inside an item the app goes only through the descriptor of the item's folder, itself opened without
  following a link (`O_DIRECTORY`, `O_NOFOLLOW`): it reads `payload` and `item.json`, and counts an attempt
  with a new file written in full, synced and renamed over `item.json` in that folder (removed again if the
  rename fails). So an item folder swapped for a link is refused, and nothing is read or written through it.
  A linked `item.json` moves the item to `Failed/`, and an `Items/` entry is read only when it is a real
  folder. Not covered, by design: a symbolic link at `ShareQueue/` or `Items/` is followed (both are reached
  by path, our code creates them, and swapping them needs the same group access), so is one among the folders
  above a lent file (`/var` is a link to `/private/var`), and a hard link counts as a regular file. The item's
  name follows `ShareQueue.itemFileName`: the suggested name, else the lent file's, else the share's date and
  time; the type's extension is added only when the name has no PDF or image extension.
- **Signing.** Agents build the extension unsigned like the app; the simulator gets the group from the
  entitlements file. The app group on a device (both App IDs, the profiles) is the maintainer's (#4, M2 and M3).

## Page cleanup engine

Step 4 (#5, part 1, #110) adds the engine in `DokumentumCore/Cleanup`; the cleanup sheet (part 3) and the
scanner (part 2) build on it.

- **An edit** (`PageEdit`) is applied in the photo's displayed orientation (EXIF applied when decoding), in
  this order: the perspective crop to four corners (`PageQuad`, normalised 0…1 from the top left,
  `CIPerspectiveCorrection`), the filter (`original`, `enhanced` = `CIDocumentEnhancer`, `grayscale` =
  saturation 0, `blackAndWhite` = enhanced, grey, `CIColorThresholdOtsu`), then clockwise quarter turns. One
  shared `CIContext` without cached intermediates.
- **Corner detection** (`VisionPageCornerDetector`): `VNDetectDocumentSegmentationRequest`, then
  `VNDetectRectanglesRequest` when the first answer is not accepted. Accepted: confidence at least 0.5, a
  convex quad, at least 10 % of the image. The segmentation request returns the whole image with confidence
  0 when there is no page (macOS). On the iOS simulator it does not work (the whole image with confidence 0,
  or wrong corners with confidence 0.97 for an empty desk, varying between runs, #110), so the simulator
  build uses the rectangle request only (`targetEnvironment(simulator)`). Tests assert accuracy, not which
  request answered; the one test of the segmentation request runs on macOS and is skipped (`Test.cancel` with
  the reason, not a failure) when it reports confidence 0.
- **The edited import** (`DocumentImporter.importEditedImages`): an `EditedImage` is one picked image with
  the pages it keeps (`EditedPage`: frame and edit; a multi-page TIFF can keep a page per frame). Pages are
  decoded, cleaned and drawn one at a time. A photo is decoded at `min(original, 2400 / longer side of the
  corners' bounding box)`, so a cropped page keeps up to 2400 px on its longer side, then scaled to at most
  2400 px. **The duplicate hash is the photo import's:** the original bytes of each image that keeps a page,
  once per image, in order; the edits do not enter it. So the same photos are a duplicate whatever the edits,
  and a TIFF split into frames hashes like `importImages` of the file. An image whose pages were all removed
  leaves the hash.
- **Rendered test pages** (`TestPage` in `DokumentumCoreTestSupport`): an A4 page with a black marker at the
  top left, a red band at the top right and grey text bars, optionally on tinted paper with a shadow gradient,
  and `TestPage.photographed`, the page warped onto a dark desk at known corners (optionally with EXIF
  orientation 6). `TestPixels.rgb` samples a `CGImage`.

## Search

Step 6 (#7). Part 1 (#121) adds the index and its rules in `DokumentumKit/Search`, Foundation only, so
`kit-linux` runs every test of it. Part 2 (#122) adds the indexer that builds and updates it and the
benchmark (`DokumentumCore/Search`); part 3 (#123) adds the search field in the library (see "The search field"
below).

- **Normalisation** (`SearchNormalizer.normalizedWord`): NFKC, then Foundation's case, diacritic and width
  folding with `locale: nil` (the device language never changes a result), then a table for what folding
  leaves alone (æ → ae, œ → oe, ø → o, ł → l, đ → d, þ → th, ß/ẞ → ss), then NFC, so equal words have equal
  bytes. İ, I and i become `i`; the dotless ı stays `ı`. The tests pin the outputs.
- **Words** (`SearchTokenizer`): maximal runs of letters, digits and combining marks; everything else
  separates (hyphen, U+2011, slash, apostrophe, the form feed between pages). "12.03.2024" is three words. A
  hyphen (`-`, U+2010 or a soft hyphen) at a line end joins the word only before a lowercase letter
  ("Steuer-\nbescheid" → `steuerbescheid`, "Kfz-\nSteuer" stays two). The line end may also be a form feed (a
  page end), alone or with one line break before or after it ("Steuer-\fbescheid", "Steuer-\n\fbescheid" and
  "Steuer-\f\nbescheid" → `steuerbescheid`); two line breaks or two form feeds separate. A soft hyphen inside a
  word is removed ("Steuer\u{AD}bescheid" → `steuerbescheid`). Plain ASCII words are only lowercased;
  other words are normalised once per distinct form (`SearchNormalizer.Cache`, kept until `mergeOverflow`).
- **Matching** (P1): every term of a query must match, each in any field. A term matches a word that starts
  with it; from 4 characters (`SearchIndex.infixMinimumLength`) also one that contains it. The 4 counts
  the characters of the word as typed (not bytes: `θην` does not find "Αθήνα"), and it holds for every
  alternative form (`SearchTerm.allowsInfix`), so "Mül" does not infix-match "Schmueller" through `muel`. An
  alternative also needs 4 characters of its own, so "muel" does not infix-match "Formular" through `mul`
  (#132). The trade-off: "muel" also no longer finds "Schmüller" (indexed `schmuller`) by infix; it still finds
  "Schmueller", "Mueller", "Müller" and "Müll", and "Müll"/"muell" infix-match "Schmüller". Transcriptions: the
  index also stores the *a/o/u* form of every word with *ae/oe/ue* (`mueller` → also `muller`; a side effect is
  `steuer` → also `steur`); a query term also tries its *a/o/u* form and, typed with ä/ö/ü, its *ae/oe/ue*
  form. So "Müller", "Mueller" and "muller" find each other in every direction.
- **`SearchIndex`** (a value type): `setMetadata(_:for:)` (title, correspondent, type, tag display paths as
  `SearchFields`; equal fields are skipped and it returns `false`), `setText(_:for:)` (replaces the previous
  text), `remove(_:)`, `mergeOverflow()`, `search(_:)`/`matches(_:)` (a set of `instanceID`s, trashed
  documents included), `statistics`. Inside: postings per token, a forward index per document and field, a
  sorted vocabulary for prefixes, a `\0`-separated vocabulary buffer scanned with `memchr`/`memcmp` for
  infixes, and an unsorted overflow for tokens new since the last merge. The index merges the overflow
  itself when it holds more than `max(2,000, a quarter of the sorted vocabulary)` tokens; the owner calls
  `mergeOverflow()` at the end of each batch of updates. Tokens without postings are dropped at a merge.
- **`LibrarySearch`**: text, filter tokens (`SearchToken`: tag with subtree, correspondent, type, Inbox) and
  scope (`SearchScope`: the sidebar's selection or All Documents). `apply` keeps the list order; the scope
  alone decides trashed or not, and tokens use `LibrarySelection.matchesIgnoringTrash`, so "Trash + Tag:
  Steuer" lists the trashed documents tagged Steuer. A text of punctuation only is no text. `suggestions`
  offers tags, correspondents, types and the Inbox (never in the Trash) whose name has a word starting with
  each term, tags first, at most 8.
- **`DocumentSearching`**: what the library calls (`search`, `state`, and `updates()`, one stream per
  subscriber); the indexer of part 2 conforms, and an FTS5 index would conform unchanged.
- **`SyntheticCorpus`**: a seeded archive (SplitMix64, integer arithmetic only, the same on every platform;
  a test pins its checksum) with the plan's distribution of 1 to 100 pages, 10 % Inbox, 1 % trashed, 40 tags
  on two levels, 60 correspondents, 12 types, and three texts at the 500,000-byte cap. Texts are made on
  demand (`text(of:)`). 5,000 documents are about 37 MB of text, 324,000 tokens and 2.2 million postings.
- **Measured** on the Mac mini (M4), not asserted in any test: building the index over 5,000 synthetic
  documents takes 1.4 s optimised and 7.7 s unoptimised; the slowest of 24 queries × 5 runs takes 2.3 ms
  optimised and 14 ms unoptimised. The device measurement is part 2's benchmark.

### The indexer

- **`SearchIndexer`** (Core) is a plain actor that makes its own `ModelContext`s on the app's container,
  as `ProcessingQueue` does, and only reads. `DokumentumApp` creates one for every store, in-memory ones
  included (`start(storeChanges:)` with the shared `StoreChangeObserver`'s stream, `nil` in memory), and
  every window's `LibraryModel` subscribes to it (`observeSearchIndex()`, `searchIndexState`; the search
  field of part 3 queries it).
- **Build** at launch, in this order: the newest history token; the metadata of every document through
  the light list query (`StoreLibrarySource.read`, no text, no blob), so titles and names are found at
  once; the texts, from the text rows' identifiers, in batches of 1 MB of text, each batch one actor call
  that reads rows by identifier in groups of 25 with a fresh context per group (queries wait for one
  batch at most, and at most 25 rows are in memory); then the history since the step-1 token and the
  metadata again, so nothing saved during the build is missed; then `.ready`. Each batch yields
  `.building(indexed:total:)`.
- **Updates** start after `.ready`; events that come during the build leave one pending event. Each update reads
  the history, the changed text rows and the metadata **off the actor**, in fresh contexts, and then applies them
  in one actor call (#132, N-d), so a query typed while the processing queue writes texts waits only for that
  call: about 2 ms for the metadata compare of 5,000 documents in a Debug build on the Mac (`setMetadata` with equal
  fields, measured for #123), plus tokenising the changed texts. Events:
  `ModelContext.didSave` of any context of the container at once, and the shared observer's debounced
  stream (remote changes the mirroring saves, the end of each CloudKit import). On each event:
  - **texts** through SwiftData's persistent history since the indexer's token (`StoreSearchHistory`):
    a `DocumentText` inserted or updated in `extractedText` or `document` (a relink), or a `Document`
    updated in `text`, is read again by key and its document's text replaced; a deleted text clears it.
    An unlinked text is indexed once its link arrives. The history records another container's saves on
    the same file (as the mirroring writes) and works for in-memory stores;
  - **metadata** by re-reading the list query; `SearchIndex.setMetadata` skips equal fields, so a tag
    rename, a merge, a classification or a trash move re-tokenises only the documents it changed;
    documents that are gone are removed.
- **History errors:** an expired token (`SwiftDataError.historyTokenExpired`) rebuilds. Any other error
  is logged once per code; the first one of a launch rebuilds, later ones keep the index and the token,
  and the next event reads the history again.
- **Rebuild:** a fresh index is built aside through the same steps while the old one answers queries
  (state `.building`), then replaces it in one assignment. Until then both are in memory: about 2 × 66 MB
  for 5,000 documents (the plan review's measurement R-b on the Mac).
- **`updates()`** returns a new stream per call (one per subscriber, newest state only), like
  `StoreChangeObserver.changes()`. It yields after each batch, each applied event and each rebuild.
- **Copies sharing an `instanceID`** follow `RowRecords.oldestFirst`: the text of the copy with the oldest
  `createdAt` is indexed. Known gap: if that copy and its text are deleted, the other copy's text is
  indexed only at the next launch (copies exist only until step 16's dedupe).
- **Memory:** the index of 5,000 synthetic documents (37 MB of text) costs about 66 MB of
  `phys_footprint` on the Mac (R-b); the benchmark reports the figure of the device it runs on.
- **Tests:** `SearchIndexerTests` (build, a later text write, metadata edits, an early text linked later,
  a change during the build, two subscribers, a persistent history error, a query answered while an update's
  history read is held), `SearchIndexerRemoteTests`
  (another container's write with the remote change, an expired history with the rebuild swap) and
  `SearchIndexerSQLTests` (`swift test` only: the metadata read names no large table; an update reads the
  changed text row by key).

### The benchmark

- **`SearchBenchmark`** (Core) opens its own in-memory container (never the app's store), writes a
  `SyntheticCorpus` into it through the real models, builds the index with the real `SearchIndexer`, and
  runs `SearchBenchmark.queries` (30) 5 times each through the library's path: `search`, then
  `LibrarySearch.apply` over the library's snapshot, timed on the main actor from the call to the
  ordered list. The report (text and JSON) has per query the median and the maximum and the hits, the
  overall maximum (**pass: under 200 ms**), the build times, the index's size, and `phys_footprint`
  before and after the build and its delta. The runner and the corpus are in the packages without a
  condition; the app's entry points are under `#if DEBUG || SEARCH_BENCHMARK`.
- `SearchBenchmarkTests` runs it with 300 documents and checks the report and every hit count against
  an index built straight from the corpus. **No time assertion.**
- **Debug app:** the launch argument `-SearchBenchmark <count>` (1…20,000; missing or out of range is
  5,000) opens an empty in-memory store (`SearchBenchmarkArgument`, so no repair, processing or real
  index runs beside it) and shows the benchmark over the library: progress, then the report with
  **Copy**. It logs the summary (`Log.search`) and writes `SearchBenchmark.json` to the app's temporary
  folder. On the Mac also **Debug › Run Search Benchmark** (5,000 documents, on its own store too).
- **In the simulator:**

  ```sh
  xcrun simctl install <device> <DerivedData>/Build/Products/Debug-iphonesimulator/Dokumentum.app
  xcrun simctl launch <device> space.pklnx.Dokumentum -SearchBenchmark 5000
  # when the report shows:
  cat "$(xcrun simctl get_app_container <device> space.pklnx.Dokumentum data)/tmp/SearchBenchmark.json"
  ```
- **On the iPhone (M1 of #7):** a Debug build from Xcode with `-SearchBenchmark 5000` under Edit Scheme ›
  Run › Arguments; wait for the report (writing the corpus plus 20–40 s of indexing are normal in Debug),
  tap Copy and paste it into a comment on #7. Pass: the overall max under 200 ms.
- **Release measurement (T12)**, only if a Debug run misses: locally and uncommitted, (1) add
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS[config=Release] = $(inherited) SEARCH_BENCHMARK` to
  `Config/Project.xcconfig`; (2) Edit Scheme › Run › Info: Build Configuration **Release**, Arguments
  `-SearchBenchmark 5000`; (3) run on the iPhone and copy the report; (4) revert both
  (`git checkout Config/Project.xcconfig`, the scheme back to Debug). If Release misses too, the plan's
  contingency is an FTS5 index behind `DocumentSearching` (T13).
- **M2 of #7** checks on two devices that the mirroring's imports reach the history: a word imported on
  the Mac is found on the iPhone, without relaunching it, once its text was processed.

### The search field

Part 3 (#123), in `DocumentListView` and `LibraryModel`:

- **Field:** `.searchable` on the list column, prompt "Search". On the iPhone it sits in the list's navigation
  bar (`navigationBarDrawer`, always shown); on the Mac in the window's toolbar. The Mac's **Edit › Find… (⌘F)**
  (`LibraryCommands`) puts the focus into it (`LibraryModel.focusSearch`, `.searchFocused`): `.searchable` adds no
  Find item and does not answer ⌘F by itself (measured on macOS 27). `SearchSmokeTests` checks that the menu bar
  has exactly one Find item (by title, in English or German) and that ⌘F focuses the field.
- **Query:** each change of the text runs `DocumentSearching.search` at once, no debounce (T10); each query has a
  generation, and an answer that comes after a newer query started is dropped. Until the answer comes the list
  keeps the previous result. Each `updates()` element of the index runs the active query again. The result goes
  through `LibrarySearch.apply`: the usual rows in the usual order (P4).
- **Scope** (`.searchScopes`, shown while the search is presented): the selected list's name or All Documents;
  none while All Documents is the list. The scope applies only to an active search; an empty field shows the
  selected list. On the Mac the segments carry `search.scope.selection`/`search.scope.all`; the iPhone's scope bar
  is a system segmented control (`scopeBar`) whose segments keep only their titles.
- **Chips** (`SearchToken`, `SearchTokenLabel`): suggested while typing through `.searchSuggestions` with
  `.searchCompletion(token)` ("Tag: Auto › Golf", "Correspondent: …", "Type: …", "Inbox"; not `suggestedTokens`,
  which the Mac does not show). Picking one drops the words typed for it. Chips combine with each other and the
  text; they work in the Trash, which offers no Inbox chip. A chip whose record is gone is dropped at the next
  read.
- **Empty result:** "No Results for “x”" (or "No Results" for chips alone), `search.empty`; the Mac's
  `PlaceholderView`, the iPhone's `ContentUnavailableView`.
- **Indexing line:** "Indexing texts… 12 of 40" (`search.indexing`) over the results while the index is
  `.building` and a search is active (P5). In the primary colour on the list's background; the Mac uses 15 pt
  semibold (`.title3`), because the audit failed the line at 10 pt medium in dark mode ("not high enough unless font
  size is larger") and at 13 pt medium and semibold in light mode, although its pixels measure 14.94:1.
  `SearchSmokeTests` also measures its contrast from its pixels (`assertTextContrast`).
- **Sidebar (P7):** the search stays when another list is chosen on the Mac. On the iPhone it ends when the
  stack goes back to the sidebar (`selection` becomes `nil`).
- **`-UITestHoldSearchIndex YES`** (Debug, in-memory stores only): the index stops after its first text batch and
  stays `.building`, so `SearchSmokeTests` sees and audits the indexing line; the sample texts all fit in that
  batch.
- **Tests:** `LibraryModelSearchTests` (text and scope, chips incl. the Trash, generations, index updates, the
  indexing line, the sidebar) and `SearchSmokeTests` (UISmoke, iPhone and Mac: a word from one text, the scope,
  a chip, ⌘F and a sidebar change on the Mac; audited).

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
