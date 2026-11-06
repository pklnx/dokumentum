# Development

How to work on Dokumentum. Product and architecture: [plan.md](./plan.md).
Workflow, roles and review rules: `CLAUDE.md` and
[pklnx/dev-process](https://github.com/pklnx/dev-process).

This page grows with the steps. It describes what exists now: repository
basics, the Xcode project, the packages, the test infrastructure and the checks.

## Where work runs

| Where | Used for |
|---|---|
| The maintainer's MacBook Pro: a macOS VM or a separate macOS user (local Claude Code session, `gh` available) | Implementation: Xcode, simulators, `xcodebuild`, `swift test` for the packages. The primary evidence for app code. |
| Cloud session (Linux, no Xcode) | Planning, plan reviews, and everything that runs on Linux: the scripts below, workflows, docs, and (once the packages exist) `swift test` and `swift format lint` for `DokumentumKit`. |
| Xcode Cloud | The PR check for build and app tests (workflows `PR` and `Main`), later TestFlight. Configured by the maintainer in Xcode and App Store Connect. |
| GitHub Actions, `ubuntu-24.04` | The checks below. |

## Setup on the development machine (VM or separate macOS user)

1. macOS 27 (on the host and, if used, in the VM), Xcode 27.x installed and selected
   (`xcode-select -p`), the developer Apple Account added in Xcode, Settings,
   Accounts. Selecting Xcode with `xcode-select -s` needs `sudo`; without it, set
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
macOS, iPhone only), `DokumentumTests` (Swift Testing, hosted by the app) and
`DokumentumUITests`. Two local packages live in `Packages/`.

- **Folders are synchronized** (`objectVersion = 77`, `PBXFileSystemSynchronizedRootGroup`):
  adding a file to `Dokumentum/`, `DokumentumTests/` or `DokumentumUITests/` does not change
  `project.pbxproj`.
- **Settings live in `Config/Project.xcconfig`**, the project's base configuration. A setting in the
  `.pbxproj` overrides it unseen, so `scripts/check-project.py` fails `lint` when the project or a
  target sets a key from that file. Xcode's capability editor writes such settings: strip them
  afterwards. Personal overrides go into `Config/Local.xcconfig` (not in git).
- **Each package is a folder reference in the project**, not an
  `XCLocalSwiftPackageReference`. With the latter `xcodebuild` builds the package but silently drops
  its tests from a test plan and still reports success. `check-project.py` guards this.
- **Builds are signed ad hoc** until part 3 (`CODE_SIGN_IDENTITY = -`, no team), which needs no
  identity or provisioning profile on the simulator and on this Mac.

## Build and test

From the repository root (`-derivedDataPath build` keeps a build in the ignored `build/` folder):

```sh
# Test plan Default: DokumentumTests, DokumentumKitTests, DokumentumTestSupportTests, DokumentumCoreTests
xcodebuild -scheme Dokumentum -destination 'platform=macOS' test
xcodebuild -scheme Dokumentum -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' test

# Test plan UISmoke: DokumentumUITests
xcodebuild -scheme Dokumentum -testPlan UISmoke -destination 'platform=macOS' test
xcodebuild -scheme Dokumentum -testPlan UISmoke -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' test

# The packages alone, without a simulator
swift test --package-path Packages/DokumentumKit
swift test --package-path Packages/DokumentumCore

# Formatting: the same command as `kit-linux`
swift format lint --strict --recursive --configuration .swift-format Dokumentum*/ Packages/
```

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
`Packages/*/Tests` and `DokumentumTestSupport`. A use that is justified stays when it says why, on its
line or in the comment lines directly above it: `// allow-wait: <reason>`. Waits of XCTest with a
condition (`waitForExistence`) are fine: UI tests use them.

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
`WaitingTests.aBlockedActorHoldsItsSafetyNet` checks it.

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

## Checks

| Check | Where | What it does |
|---|---|---|
| `lint` | GitHub Actions, `checks.yml` | Python only. Runs the self-tests of the check scripts, validates `.github/labels.json` (`scripts/check-labels.py`) and the project's invariants (`scripts/check-project.py`), and flags tests that wait for time (`scripts/check-test-waits.py`). |
| `localization` | GitHub Actions, `checks.yml` | `scripts/check-localization.py --catalog`: every entry of `Dokumentum/Localizable.xcstrings` has a finished German translation (a plural `one` and `other`), and none is stale. |
| `kit-linux` | GitHub Actions, `checks.yml` | The only job with the Swift toolchain (`.github/actions/install-swift`, pinned with a SHA-256, one download per run): `swift format lint --strict` with the committed `.swift-format`, then the `DokumentumKit` tests, which include `DokumentumTestSupportTests`. |
| `secret-scan` | GitHub Actions, `secrets.yml` | Installs the pinned gitleaks, runs the scan's self-test (`scripts/secret-scan-test.sh`), then scans the commits the PR adds (`scripts/secret-scan-range.sh` prints the range). |
| Xcode Cloud `PR` | Xcode Cloud | Build and tests, see below. Not onboarded yet. |

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
