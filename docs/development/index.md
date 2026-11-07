# Development

How to work on Dokumentum. Product and architecture: [plan.md](./plan.md).
Workflow, roles and review rules: `CLAUDE.md` and
[pklnx/dev-process](https://github.com/pklnx/dev-process).

This page grows with the steps. It describes what exists now: repository
basics, the Xcode project, the packages, the test infrastructure and the checks.

## Where work runs

| Where | Used for |
|---|---|
| A macOS VM on the maintainer's MacBook Pro (local Claude Code session, `gh` available) | Implementation: Xcode, simulators, `xcodebuild`, `swift test` for the packages. The primary evidence for app code, except for signing and entitlements: it has no signing identity and builds unsigned, see "Build and test". |
| The MacBook Pro itself, with the maintainer's Apple Account | Signed builds and runs on the iPhone and the Mac: the only place that exercises the macOS entitlements and the sandbox. None has run yet: the signed output and the device check are deferred to before signed or iCloud work relies on them ([plan.md](./plan.md), section 4). |
| Cloud session (Linux, no Xcode) | Planning, plan reviews, and everything that runs on Linux: the scripts below, workflows, docs, and (once the packages exist) `swift test` and `swift format lint` for `DokumentumKit`. |
| Xcode Cloud | The PR check for build and app tests (workflows `PR` and `Main`), later TestFlight. Configured by the maintainer in Xcode and App Store Connect. |
| GitHub Actions, `ubuntu-24.04` | The checks below. |

## Setup in the development VM

1. macOS 27 (on the host and in the VM), Xcode 27.x installed and selected
   (`xcode-select -p`), the developer Apple Account added in Xcode, Settings,
   Accounts. That account has no signing access: the team is enrolled as an
   individual, so only the Account Holder gets Certificates, Identifiers & Profiles.
   Selecting Xcode with `xcode-select -s` needs `sudo`; without it, set
   `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (in
   `~/.zprofile` for login shells).
2. `gh auth status` is OK.
3. Once per clone, enable the secret-scan hook:

   ```sh
   brew install gitleaks
   git config core.hooksPath .githooks
   ```

## The project

`Dokumentum.xcodeproj` has one multiplatform app target (`Dokumentum`: iOS and native
macOS, iPhone only), the share extension `DokumentumShare` (iOS only, a placeholder until
step 3, embedded through platform filters), `DokumentumTests` (Swift Testing, hosted by the
app) and `DokumentumUITests`. Two local packages live in `Packages/`.

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
- **Signing is automatic with the committed team.** Signed builds run on the maintainer's machine. The
  VM and Xcode Cloud's test workflows build macOS without team and entitlements, see "The unsigned
  path".

## Build and test

From the repository root (`-derivedDataPath build` keeps a build in the ignored `build/` folder). These
are the VM's commands. A machine with a signing identity leaves out the `XCODE_XCCONFIG_FILE` prefix.

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
does not apply, and the flag stays barred in the VM. The fix for a forgotten prefix is the prefix.
`Config/Unsigned.xcconfig` makes the macOS build ad hoc, without a team and without entitlements. It
sets only macOS-conditioned keys, so the simulator keeps the real team and keys, which a build shows in
its `*-Simulated.xcent` files. The project does not reference the file: it reaches a build only through
this variable, or through Xcode Cloud's copy (see "Xcode Cloud").

**What this leaves untested.** macOS tests in the VM and in Xcode Cloud run without the entitlements and
outside the sandbox, with no iCloud or push keys. Only the maintainer's signed build exercises them. A
macOS test passing here says nothing about behaviour that depends on them.

- Use the variable as a prefix on a command run from the repository root, and do not export it in a
  profile. Its path is resolved against the current directory. Exported, it would break every build from
  another directory and on every commit without the file.
- A wrong path fails a build loudly (exit 65, `Unable to open file ... referenced by
  XCODE_XCCONFIG_FILE`), but `-showBuildSettings` exits 0 and silently shows the override absent. Do not
  take its output as proof that the override applies.
- A device build (`generic/platform=iOS`) has no ad hoc form: it needs `CODE_SIGNING_ALLOWED=NO`, as
  above. Nothing in the VM ever creates a certificate, a profile or a device registration, or passes
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
| Without it (the VM's unsigned macOS build) | the same file, local only |

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
from tests or the VM).

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
pass's commit is overwritten in that row. Measured on the VM (`swift test` debug build, from the check's start
to the pass's `didSave`, 3,000 documents in two correspondents' halves): about 0.06 s for a merge moving 300
documents, and 0.24 to 0.40 s for one moving 1,500, with one to five tags per document, depending on the data
and the VM's load (review A measured 0.40 s). It grows with the rows the pass writes, never with the archive.
A document's file, thumbnail and text links are part of its row (by identifier, without loading the blob), so a
link another save makes in the window is seen. The external-storage data of a relinked blob is not compared.
Also not re-checked: records inserted in the window. A revived tombstone whose chain end arrives just then, or a
document that newly points at a merge's loser, is left for the next run, which merges or re-points it; nothing
is lost, but the keeper can differ from the one another device chose until both converge.

Repair tests seed a `RepairSnapshot` into a store on disk (`RepairStoreFixtures.swift`) and check
`RepairInvariants` and that the store ends where the planner's simulation ends (`CheckedRepair`).

## Logging

Every logger comes from `Log` (`DokumentumCore`): categories `store`, `sync`, `repair`, subsystem
`space.pklnx.Dokumentum`. Counts, enum states and error domain and code are `.public`; names, titles, paths,
text and `localizedDescription` are `.private`. App code never prints, and a crash message is a fixed text.
`scripts/check-logging.py` enforces this in the app, the share extension and the packages' library code.

## Checks

| Check | Where | What it does |
|---|---|---|
| `lint` | GitHub Actions, `checks.yml` | Python only. Runs the self-tests of the check scripts, validates `.github/labels.json` (`scripts/check-labels.py`) and the project's invariants (`scripts/check-project.py`), flags tests that wait for time (`scripts/check-test-waits.py`), checks the logging rules (`scripts/check-logging.py`) and that the schema snapshots are additive and meet the CloudKit rules (`scripts/check-schema-snapshots.py --base`, with the full history checked out). |
| `localization` | GitHub Actions, `checks.yml` | `scripts/check-localization.py --catalog`: every entry of `Dokumentum/Localizable.xcstrings` has a finished German translation (a plural `one` and `other`), and none is stale. |
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

`--catalog` only reads the catalog. `python3 scripts/check-localization.py <derived data path>` also
finds strings the code uses that never reached the catalog: `xcodebuild` does not add them, only
Xcode's IDE does. Run it after a build with `-derivedDataPath <derived data path>`.

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
