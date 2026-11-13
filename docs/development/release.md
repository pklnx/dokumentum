# Releases

How a Dokumentum build gets to TestFlight: the gates, versions and tags, the maintainer's steps M0–M8, the soak
test, the CloudKit Production deploy, the clean slate on both devices, the device checklist, and what may go on
GitHub. Source: the plan of #9 (Revision 1, [comment 6840561086](https://github.com/pklnx/dokumentum/issues/9#issuecomment-6840561086))
and the maintainer decisions of 2026-11-13 ([comment 6846051325](https://github.com/pklnx/dokumentum/issues/9#issuecomment-6846051325)):
P2 (manual upload from the MacBook Air), P8 (internal testing only), P10 (two or three generated test documents in
Production), P11 (a 7-day soak with exit criteria).

**Who does what.** Deploying the CloudKit schema to Production, signing, archiving, tagging, TestFlight uploads and
App Store Connect are the maintainer's (CLAUDE.md). Agents build unsigned, run the gates, compare the schema export
and post results. They never sign, archive, tag, upload or open the CloudKit Console or App Store Connect, and never
pass `-allowProvisioningUpdates`. Tagging and every upload need the maintainer's explicit OK (M5; pklnx/dev-process
`decisions.md`, Never 4).

## Real data on GitHub

The repository is public. The rule:

> Once Production holds real documents, nothing from them goes on GitHub (the repository is public): no screenshots,
> titles, file names, dumps, logs or crash logs with document content. Checklist results are posted as pass or fail,
> naming only the test documents. Crash reports are summarized (exception type, crashed thread), never pasted.

- The soak and the two-device protocol use synthetic documents only (#2, P5) in CloudKit Development. Their logs,
  dump hashes and repair counts may go on the issue.
- From the first TestFlight install (M8) Production holds the maintainer's real documents. From then on only the
  P10 test documents may be named, and only pass or fail, versions, SHAs, `codesign` output, the privacy report and
  the schema export (it holds the schema only, no records) go on GitHub.
- A screenshot for a bug report is taken with the test documents only, or not at all. Logs are summarized.

## Order of the first release

```
maintainer M0 switch off Xcode Cloud PR/Main: done 2026-11-13
           M1 protocol runs 1 and 2 on #155 → #155 merges (a C7 change of extractedText merges now, with its reset)
           dry run: initialize → export → compare, no deploy (right after #155 merges, or on soak day 1)
           M2 soak: 7 days, Development, synthetic documents (starts once #155 is on main)
           M3 initialize → export → compare → schema to Production (cannot be undone)
agent      part 4 (#185): production-versions.txt lists V1 and V2, MARKETING_VERSION YY.MM.1
gate       release.yml at the release commit (+ local UISmoke while #173 is open)
maintainer M4 App Store Connect record · M5 OK · M6 archive, validate, tag, upload
           M7 clean slate · M8 install from TestFlight + device checklist
```

Later releases skip M0–M4 and M7: a version PR (see "Versions and tags"), the gate, M5, M6, M8's checklist. A model
change after the first deploy is a new schema version with its own Production deploy (M3's steps, without the soak unless the
plan of that change asks for one).

## Gates before a TestFlight build

A build is archived only from the **release commit**: a commit on `main` at which all of the following passed.

1. Every PR of the release is merged, and the required checks of `main` are green at that commit.
2. `.github/workflows/release.yml`, started by hand on that commit (Actions › Release › Run workflow, on `main` or
   on a branch whose head is the release commit). Both jobs, `release-ios` and `release-macos`, are green:
   - the full `Default` test plan;
   - the `UISmoke` test plan;
   - **Release build, unsigned**: the Release configuration, which TestFlight ships, compiled for a device
     (`generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO`) and for the Mac (`generic/platform=macOS`, the unsigned
     path `Config/Unsigned.xcconfig`). The tests build Debug only, so this is the one place CI compiles Release. It
     runs even when a test step failed, so each run shows whether Release compiles.
3. **While #173 is open** UISmoke does not pass on the hosted runners. Then the gate is `release.yml`'s `Default` and
   Release build steps, plus UISmoke run locally on the Mac mini at the release commit, by an agent in its own
   worktree, under the shared `xcodebuild` lock:
   ```sh
   XCODE_XCCONFIG_FILE=Config/Unsigned.xcconfig xcodebuild -scheme Dokumentum -testPlan UISmoke -destination 'platform=macOS' test
   XCODE_XCCONFIG_FILE=Config/Unsigned.xcconfig xcodebuild -scheme Dokumentum -testPlan UISmoke -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' test
   ```
   A red hosted UISmoke is never a reason to skip UISmoke.

**On the issue:** the release commit's SHA, the `release.yml` run URL with each job's and step's result, and (while
#173 is open) the local UISmoke results with the SHA they ran on.

**The gate runs again at every new release commit**, including a commit that only bumps the version (T2): a fix PR
or a version PR makes a new commit, and nothing is archived from a commit the gate has not passed.

## Versions and tags

- `MARKETING_VERSION` in `Config/Project.xcconfig` is `YY.MM.N`: the year and month of the release (month without a
  leading zero) and `N`, counted from 1 within that month, for example `26.11.1`. `CURRENT_PROJECT_VERSION` stays
  `1`. Part 4 (#185) sets the first version and the check of the format.
- **Every TestFlight upload gets a new version.** A later upload, and a retry after a refused validation or upload,
  needs a one-line version PR (`N+1`, or `.1` of a new month); then the gate runs again at its merge commit, and M5
  asks again.
- **The release commit** is the commit at which the gate passed: part 4's merge commit for the first release, or a
  later fix or version commit. Its `MARKETING_VERSION` is the version that is archived and tagged.
- **Validate before tagging.** The tag `vYY.MM.N` goes on the release commit only after both archives passed
  Organizer's "Validate App" (M6 step 3). A tag is never moved or deleted. If an upload is refused after the tag
  exists, that version is used up: fix, version PR `N+1`, gate, M5, M6.
- The tag names the commit the archives were built from: `git rev-parse vYY.MM.N^{commit}` equals the release
  commit, and the clean clone of M6 was checked out at that SHA.

## Maintainer steps M0–M8

Each step ends with what to post on the tracking issue (#9 for v1), under "Real data on GitHub".

### M0. Xcode Cloud (before 6 December): done 2026-11-13

The quota resets on 6 December. Uploads are manual (P2), and GitHub Actions runs the PR checks, so Xcode Cloud's
workflows would spend the quota on checks that already run elsewhere.

- [x] App Store Connect › Xcode Cloud › Manage Workflows: the workflows `PR` and `Main` are disabled (2026-11-13).
- [x] Posted on #9.

### M1. Two-device protocol, runs 1 and 2

- [ ] Run 1 and run 2 on #155's head, as `sync.md` (#155) describes. Prerequisites: #1 steps 3 and 9 for the iPhone,
      #4 M2/M3.
- [ ] Post the results on #31; #155 merges after them.
- [ ] **If case C7 shows that `DocumentText.extractedText` must become an external-storage `Data` field**: V1 changes
      in place (allowed before Production, #2's plan). **The same change is made identically in
      `DokumentumSchemaV2`** (and every later version not yet in Production), with both snapshots, so the V1 → V2 stage
      stays lightweight (#10, part 1a). CloudKit cannot change the type of the existing STRING field
      `CD_extractedText`, so this needs a reset, in this order:
  1. [ ] the change merges right after M1;
  2. [ ] CloudKit Console › `iCloud.space.pklnx.Dokumentum` › Development › "Reset Development Environment";
  3. [ ] the clean slate on both devices ("Clean slate", for a development build);
  4. [ ] the changed development build is installed on both devices;
  5. [ ] only then M2 starts. The soak runs once, on the final schema.
- [ ] Then the dry run of M3's export and comparison ("Production deploy", "Dry run"), right after #155 merges or on
      soak day 1.
- [ ] **The first open of a V1 store by a V2 build** (#10, part 1a), on each device whose Development store was
      written by a build from before V2: after the V2 build's first launch, the library shows the same documents and
      metadata as before, and the sidebar footer does not say "Sync off". No automated test covers a CloudKit-mirrored
      store; a failed open would fall back to a local store ("Sync off"), with no data lost. It needs no run of its
      own: it is an item of the M1 results or of soak day 1's log, whichever first runs a V2 build.

### M2. Soak test

- [ ] The protocol in "Soak protocol" below, until its exit criteria are met.
- [ ] Post a short log comment each day (template below) and the result.

### M3. Schema to Production

- [ ] The steps in "Production deploy" below. Post the export, the comparison and the deploy date.

### M4. App Store Connect record

The record "Dokumentum" exists since 2026-10-28, primary language German (#1, comment 6475318222; P12, P13 decided).

- [ ] Both platforms, iOS and macOS, are on the record for the bundle ID `space.pklnx.Dokumentum`; add macOS if only
      iOS is there.
- [ ] Note the bundle ID and the SKU.
- [ ] Category: Productivity (P7).
- [ ] TestFlight › Internal Testing: a group with the maintainer's own Apple Account (P8). Internal testing needs no
      App Privacy label, no privacy policy and no beta review. External testing waits for step 17.
- [ ] Only if the record were missing: Apps › "+" › New App, iOS and macOS, name "Dokumentum", primary language
      German, bundle ID `space.pklnx.Dokumentum`, SKU `dokumentum`.
- [ ] Post: platforms, bundle ID, SKU, category, the internal group exists.

### M5. The OK

The coordinator asks for the explicit OK and names:
- the version `YY.MM.N`;
- the release commit (SHA);
- the gate results (see "Gates").

- [ ] The maintainer answers on the issue or in the session; the coordinator notes the OK on the issue.

### M6. Archive, validate, tag, upload

On the MacBook Air, signed in to Xcode with the maintainer's Apple Account, from a clean clone at the release commit:

1. [ ] The clone, in a new folder for this version (never a folder an earlier release used):
   ```sh
   git clone https://github.com/pklnx/dokumentum.git ~/dokumentum-release-YY.MM.N
   cd ~/dokumentum-release-YY.MM.N
   git checkout --detach <release commit SHA>
   git rev-parse HEAD   # must print the release commit
   git status --porcelain   # must print nothing
   ```
   No `Config/Local.xcconfig` exists in a fresh clone, so the build uses the committed signing settings.
2. [ ] Archive both platforms (`YY.MM.N` is the version at that commit):
   ```sh
   xcodebuild -scheme Dokumentum -configuration Release -destination 'generic/platform=iOS' \
     -archivePath ~/Library/Developer/Xcode/Archives/Dokumentum-iOS-YY.MM.N.xcarchive archive
   xcodebuild -scheme Dokumentum -configuration Release -destination 'generic/platform=macOS' \
     -archivePath ~/Library/Developer/Xcode/Archives/Dokumentum-macOS-YY.MM.N.xcarchive archive
   ```
   If `xcodebuild` reports a missing provisioning profile, archive the same scheme in Xcode instead (Product ›
   Archive, once per destination "Any iOS Device" and "Any Mac"); `-allowProvisioningUpdates` is the maintainer's
   to decide, never an agent's.
3. [ ] Organizer (Window › Organizer) › each archive › "Validate App". Both must pass.
4. [ ] Only once both validated, tag the release commit and push the tag:
   ```sh
   git tag -a vYY.MM.N -m "Dokumentum YY.MM.N" <release commit SHA>
   git rev-parse 'vYY.MM.N^{commit}'   # must print the release commit
   git push origin vYY.MM.N
   ```
5. [ ] Organizer › each archive › "Distribute App" › "TestFlight Internal Only", for both archives.
6. [ ] Post on the issue:
   - the validation and upload results;
   - `codesign -dv ~/Library/Developer/Xcode/Archives/Dokumentum-macOS-YY.MM.N.xcarchive/Products/Applications/Dokumentum.app`,
     which shows `flags=0x10000(runtime)` (hardened runtime, P1);
   - Xcode's privacy report (Organizer › the archive › "Generate Privacy Report").

   Entitlements are checked on the installed app (device checklist item 11), not on the archive: with automatic
   signing an archive is normally signed for development and re-signed at distribution.

If a validation or upload is refused: post the message (it holds no document data), then a fix PR if needed, a
version PR `N+1`, the gate, M5 and M6 again.

### M7. Clean slate before the first install

See "Clean slate" below. Post: done on both devices, and the `mdfind` output with the home folder written as `~`
(not `/Users/<name>`).

### M8. Install and device checklist

- [ ] Install from TestFlight on the iPhone 18 Pro and the MacBook Air.
- [ ] Run the "Device checklist" below and post the results as pass or fail, item by item.

## Soak protocol (M2)

**Setup.**
- #155 is on `main`; a C7 change and its reset are done (M1).
- Xcode development builds of current `main` (Debug, so the Sync lab exists) run on the iPhone 18 Pro and the
  MacBook Air, with the maintainer's own Apple Account, in CloudKit Development.
- Synthetic documents only (#2, P5): Sync lab documents (prefix `SyncLab-`), the sample documents, generated PDFs,
  and scans of printed test pages. Never a real document.

**Daily**, about 10 minutes, for 7 days; both devices are used on at least 5 of them:
- [ ] import 2–3 documents on alternating devices (scan, share, ⌘O, photo);
- [ ] edit metadata on the other device;
- [ ] one rename or merge of a tag, correspondent or type;
- [ ] one search, and one move to the trash and restore;
- [ ] every second day, an offline edit (Airplane mode on the iPhone or Wi-Fi off on the Mac, edit, reconnect);
- [ ] once in the week, let the Mac sleep with work pending;
- [ ] once in the week, leave the iPhone unopened for a day (the 6-hour claim takeover).

**At each day's end**, with both devices quiet (no event `running` in the Sync lab's event log): Sync lab › Export
state on both, then record:
- whether the first lines' `dump sha256` are equal, or, if not, whether they are equal after 5 minutes;
- the repair counts on each device (orphans, two files, thumbnails or texts, `id` duplicates, tombstones);
- the sidebar footer's line on each device;
- any crash (summarized: exception type, crashed thread).

**Log comment** on the issue, once a day:

```
Soak day <n>/7, <date>. Build: <short SHA of main> on both devices.
Used: iPhone yes/no, Mac yes/no.
Done: <imports and how>, <edits>, <rename/merge>, search yes/no, trash+restore yes/no,
      offline edit yes/no, Mac asleep with work pending yes/no, iPhone unopened yes/no.
Dump at day's end: Mac <first 12 of dump sha256>, iPhone <first 12>; equal: yes / after 5 min / no.
Repair (Mac / iPhone): orphans <a>/<b>, two files/thumbnails/texts <a>/<b>, id duplicates <a>/<b>, tombstones <a>/<b>.
Footer: Mac "<line>", iPhone "<line>".
Crashes: none / <exception type, crashed thread>.
Defects: none / #<issue>.
```

**New builds during the soak** are fine for merges that touch neither the model nor sync (T1). From the start of the
soak until part 4 merges, the coordinator holds every PR labelled `schema`, touching any `schema-v<N>.txt` or
`DokumentumSchemaV<N>` (the latest is V2, #10 part 1a), or adding a version. A schema change, or a Development reset
in M3, restarts the soak from day 1.

**Exit criteria** (P11), all of them, then M3:
- 7 days;
- equal dump hashes at every day's end;
- no lost edit, no duplicate, no document stuck in processing after both devices were open, no crash;
- orphan counts not growing.

A defect is fixed by a PR; after the fix is installed on both devices, the soak needs at least 3 more clean days
(and 7 days in all).

## Production deploy (M3)

"Deploy Schema Changes…" copies **the whole Development schema** (every record type, field and index) to
Production. It cannot be undone, and Production can never drop a field or change its type. So the Development schema
is compared field by field with the frozen snapshot first.

Do steps 1–5 in one sitting: export right before the deploy, and run no other build against Development between
step 1 and the deploy (step 5). If a script PR or a decision interrupts the sitting, export and compare again before
deploying.

**Dry run** (once, right after #155 merges, or on soak day 1). Steps 1–3 below with the development build of `main`
at that time, posted on the issue, then stop: no deploy, and no reset of its own. It checks the script against the
first real export early. A difference in the script's own table or language gets its script PR now, not at M3; a
stray field is classified as in "Classifying a failed comparison" (a reset decided then costs at most the soak's
first day). M3 itself still exports and compares again after the soak.

1. [ ] **The build.** On the MacBook Air, run from Xcode a Debug build (the Sync lab exists only in Debug) of `main`
   at a commit whose latest snapshot `Packages/DokumentumCore/Tests/DokumentumCoreTests/Schema/schema-v<N>.txt` (V2
   since #10, part 1a; `DokumentumSchemaV<N>`, which the Sync lab initializes) is the one part 4 freezes: no schema
   PR has merged since the soak started (T1). It is development-signed, so it talks to CloudKit
   Development. Then Sync lab › "Initialize CloudKit schema". Post the commit SHA.
2. [ ] **The export.** Either way:
   - CloudKit Console › `iCloud.space.pklnx.Dokumentum` › Development › Schema › export; or
   - in Terminal. Once: create a management token in the CloudKit Console and run
     `xcrun cktool save-token --type management`, which asks for it at a hidden prompt and keeps it in the keychain
     (never as an argument, never on GitHub). Then:
     ```sh
     xcrun cktool export-schema --team-id 88GY2V9C2A --container-id iCloud.space.pklnx.Dokumentum \
       --environment development --output-file dokumentum-development.ckdb
     ```

   Post the file on the issue. GitHub does not accept a `.ckdb` attachment: paste it as text in a collapsed block
   (`<details>`, the export inside a code block), or rename it to `dokumentum-development.txt` and attach that. It
   holds the schema only, no records.
3. [ ] **The comparison.** An agent saves the posted export and runs, from the repository root at the commit of step
   1:
   ```sh
   python3 scripts/check-cloudkit-schema.py dokumentum-development.ckdb
   ```
   Without `--snapshot` it compares with the latest `schema-v<N>.txt`, the version the build of step 1 initialized.
   It posts the whole output: every record type field by field (`ok`, `implicit`, `system`, `EXTRA`, `WRONG TYPE`,
   `MISSING`), the indexes, the implicit `NUMBER` fields, the roles and the grants, and the last line, `CLEAN` or
   `NOT CLEAN`. Clean means:
   - the record types are exactly `Users`, `CD_<Entity>` for the seven entities, and `CDMR`;
   - every field is an attribute or to-one relationship of the latest version with its type, a system field
     (`___…`), `CD_entityName`, a `CDMR` field, or the `CD_<attribute>_ckAsset` field (ASSET) of a string or binary
     attribute. Apple, "Reading CloudKit Records for Core Data": every variable-length attribute (String, Binary Data)
     gets that field, so V1 has 14 of them (12 strings, 2 binaries) and V2 20 (its six rule fields are strings); a
     `uuid`, `date`, `int64` or `bool` attribute never has one;
   - an `int64` or `bool` field may be `NUMBER` (or `NUMBER PREFERRED AS INT64`): that is how CloudKit Development
     types a numeric field that a save created before the schema initializer ran (Apple, "Integrating a Text-Based
     Schema into Your Workflow"). It is listed as `implicit`, not as a problem. A `NUMBER` field anywhere else is a
     stray field or a wrong type;
   - nothing of the latest version is missing, and nothing in the file is unknown.
4. **If not clean, classify every problem first**, before any reset ("Classifying a failed comparison" below).
5. [ ] **If clean:** CloudKit Console › Development › "Deploy Schema Changes…" to Production. **This cannot be
   undone.** Post the date. Part 4 (#185) then lists every deployed version in `production-versions.txt` (`1` and
   `2` once V2 is in the build: the migration test keeps a real V1 store, so V1 stays frozen too).
6. **If a stray field or a wrong field type remains** (an extra record type or field, for example from an earlier
   draft or a branch run on a device, or a field of the snapshot with another type) and the maintainer decided on the reset: **do not
   deploy.** Instead:
   1. [ ] CloudKit Console › Development › "Reset Development Environment". It deletes all Development records and
      the schema, the soak's and the protocol's data included.
   2. [ ] The clean slate on both devices ("Clean slate", for a development build), so that no local store re-uploads
      records under the old schema.
   3. [ ] Install the current development build again on both devices, and repeat steps 1–3.
   4. [ ] Restart the soak from day 1 (M2), then M3 again.

**Classifying a failed comparison.** An agent sorts each problem of a `NOT CLEAN` result into one of two kinds and
posts the classification with its evidence. Nothing is reset before that.
- **The script's own table or language** (the mirroring or CloudKit produces something the script does not know):
  an unknown statement, type or qualifier from the CloudKit Schema Language; a field that the mirroring documents
  or produces on every record type of its kind (as the `_ckAsset` fields are); a `CDMR` or system field the script
  does not list. Evidence: Apple's documentation, or the same field after a fresh "Initialize CloudKit schema".
  Fix: a script PR (reviewed like any PR), then the comparison runs again on the same export. No reset.
- **A stray field or a wrong field type**: a record type or field that no attribute or relationship of the snapshot
  and no documented mirroring rule explains (left from an earlier model draft or a branch build run on a device), or a
  field of the snapshot with another type than the table gives. Fix: a reset (step 6). It deletes the soak's data and restarts the soak, so
  **the maintainer decides it**, on the agent's classification and recommendation.
- If a problem fits neither kind, the agent says so and asks the maintainer; there is no deploy and no reset until
  it is decided.

**The reset rule.** Every "Reset Development Environment" (C7 in M1, or step 6 here) is followed by the clean slate
on both devices and a fresh install of the development build, and restarts the soak from day 1. A reset without the
clean slate lets the old local stores upload their records again and re-create the old fields.

## Clean slate

**Why.** A development build's store holds Development-mirrored synthetic documents. A TestFlight build has the same
bundle ID (`space.pklnx.Dokumentum`), so it would open that store and upload them into Production, the maintainer's
real archive. The per-device settings (classification switch, re-queue flag) live in the same container.

**When.** Before the first TestFlight install (M7), and after every Development reset (M1, M3), where a development
build is installed again afterwards. After M7, #2's P3 holds: no development build goes onto these two devices again.

**iPhone**
- [ ] Delete the Dokumentum app (touch and hold the icon › Remove App › Delete App). Its container, its app group
      container and its defaults go with it.

**Mac**
1. [ ] Quit Dokumentum (⌘Q).
2. [ ] List every copy of the app that Spotlight knows:
   ```sh
   mdfind "kMDItemCFBundleIdentifier == 'space.pklnx.Dokumentum'"
   ```
   - Development builds under `~/Library/Developer/Xcode/DerivedData/Dokumentum-…/`: move each `Dokumentum-…`
     folder to the Trash in Finder (Go › Go to Folder… `~/Library/Developer/Xcode/DerivedData`).
   - Any other copy that is not an Xcode archive: move it to the Trash.
   - **Xcode archives** under `~/Library/Developer/Xcode/Archives/` may stay; they are needed to symbolicate crash
     reports. Spotlight indexes them, so their `Products/Applications/Dokumentum.app` is an expected hit. An archived
     app is development-signed: **never launch it**, and never open it from Spotlight. To keep it out of the list,
     move the archives off the Mac instead.
3. [ ] Finder › Go › Go to Folder… `~/Library/Containers/space.pklnx.Dokumentum` › move the folder to the Trash, then
      empty the Trash. (Terminal cannot remove another app's container without extra privacy permissions.)
4. [ ] For M7: install from TestFlight, then run `mdfind` again. It lists `/Applications/Dokumentum.app` and,
      if they stayed, the archived apps under `~/Library/Developer/Xcode/Archives/`. Nothing else.

## Device checklist (M8)

Run on the TestFlight build. Test documents: two or three generated, non-sensitive PDFs or scans of printed test
pages (P10), named so that they are recognisable (for example `Testdokument 1`). Post each item as pass or fail.

**Both devices**
1. [ ] Dokumentum is installed from TestFlight, and TestFlight shows `YY.MM.N (1)`.
2. [ ] On first launch the library is empty: nothing from Development appears (the clean slate worked).
3. [ ] The sync line in the sidebar footer shows sync on, with no error.
4. [ ] Settings › Suggestions: "Suggest metadata with Apple Intelligence" is on (on the Mac ⌘,; on the iPhone the
       gear in the sidebar).
5. [ ] The icon and both accent roles (tint and fill) look right in light and dark mode (P3, P4).

**iPhone**

6. [ ] Scan a test page: it lands in the inbox with text and a thumbnail, and gets suggestions if Apple Intelligence
       is available.
7. [ ] Share a test PDF from Files through the share extension: it is imported on the next activation of the app.
8. [ ] Import a photo of a test page from the library.
9. [ ] Lock the phone during processing: processing resumes.

**Mac**

10. [ ] Import a test PDF with ⌘O, and one with drag and drop.
11. [ ] In Terminal:
    - `codesign -dv /Applications/Dokumentum.app` shows `runtime` in its flags (P1);
    - `codesign -d --entitlements :- /Applications/Dokumentum.app` shows the App Sandbox, the CloudKit container
      `iCloud.space.pklnx.Dokumentum`, `com.apple.developer.aps-environment` set to `production`, and no
      `get-task-allow`.

**Across the devices (Production)**

12. [ ] A test document imported on the iPhone appears on the Mac with its file, thumbnail and text, and the other way
        round. A title or tag edit on one device appears on the other. Search on the other device finds the text.
        Moving to the trash on one device moves it on the other, and restoring works the same way.
13. [ ] An edit made on the iPhone in Airplane mode arrives on the Mac after reconnecting.
14. [ ] The test documents are moved to the trash and the trash is emptied on one device; they are gone on both.
15. [ ] No crash:
    - Mac: no `Dokumentum` report in `~/Library/Logs/DiagnosticReports`;
    - iPhone: no `Dokumentum` entry under Settings › Privacy & Security › Analytics & Improvements › Analytics Data;
    - none in TestFlight's crash feedback.

## What goes on the issue

| Step | Post |
|---|---|
| Gate | release commit SHA, `release.yml` run URL and results per job and step, local UISmoke results while #173 is open |
| M0 | done, date (done 2026-11-13) |
| M1 | protocol results (on #31); a C7 change and its reset, if any |
| Dry run | build SHA, the export, the comparison output and the classification of any problem |
| M2 | one log comment per day (template above), then the result against the exit criteria |
| M3 | build SHA, the export (as text or `.txt`), the comparison output, the deploy date or the reset |
| M4 | platforms, bundle ID, SKU, category, internal group |
| M5 | the OK, with version, release commit and gate results |
| M6 | validation and upload results, the tag, `codesign -dv` of the archived Mac app, the privacy report |
| M7 | done on both devices, `mdfind` output with `~` for the home folder |
| M8 | device checklist items 1–15, pass or fail |

Everything under "Real data on GitHub": from M8 on, only the test documents are named, and crashes are summarized.
