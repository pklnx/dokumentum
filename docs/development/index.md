# Development

How to work on Dokumentum. Product and architecture: [plan.md](./plan.md).
Workflow, roles and review rules: `CLAUDE.md` and
[pklnx/dev-process](https://github.com/pklnx/dev-process).

This page grows with the steps. It describes what exists now (repository
basics and the Linux checks); the Xcode project, build commands and the test
infrastructure are added by the parts that create them.

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
   Accounts.
2. `gh auth status` is OK.
3. Once per clone, enable the secret-scan hook:

   ```sh
   brew install gitleaks
   git config core.hooksPath .githooks
   ```

## Checks

| Check | Where | What it does |
|---|---|---|
| `lint` | GitHub Actions, `checks.yml` | Python only. Runs the self-tests of the check scripts and validates `.github/labels.json` (`scripts/check-labels.py`). |
| `secret-scan` | GitHub Actions, `secrets.yml` | Installs the pinned gitleaks, runs the scan's self-test (`scripts/secret-scan-test.sh`), then scans the commits the PR adds (`scripts/secret-scan-range.sh` prints the range). |
| Xcode Cloud `PR` | Xcode Cloud | Build and tests; added with the Xcode project. |
| `localization`, `kit-linux` | GitHub Actions, `checks.yml` | Added with the Xcode project and the packages. |

Run the Python checks from the repository root:

```sh
python3 scripts/check-labels.py --self-test
python3 scripts/check-labels.py
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

A cloud session has no Swift. For `DokumentumKit` (from part 2 on) it installs
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
it. The `kit-linux` job (added with the packages) installs the same release
with the same checksum, once per run.
