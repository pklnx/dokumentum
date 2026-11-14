# Sync across devices

How Dokumentum's data behaves between the iPhone and the Mac, how the Debug **Sync lab** works, and the two-device
protocol that measures it (#2, part 4; #31, part 2). The model, the store, the repair and the processing queue are in
[index.md](./index.md), "Data model and sync"; the product rules in [plan.md](./plan.md), section 3.2.

The results table at the end is filled from the maintainer's runs, with the build SHA and the date. Until a case has
run, everything this page says about CloudKit's behaviour across devices is the expectation, not a measurement.

## Accounts and environments

Maintainer decisions of 2026-11-02 (#2), with the MacBook Air (M5) in place of the MacBook Pro (#1, PR #107) and the
account-change check moved to the simulator (#31, P4).

| Use | Devices | iCloud account | CloudKit environment |
|---|---|---|---|
| The two-device protocol (runs 1 and 2 below): "two devices sync" and the conflict tests | iPhone 18 Pro and MacBook Air, Xcode development builds of the PR head | the maintainer's own, the same on both (CloudKit syncs only within one account) | Development: Production data is never touched |
| Account change and sign-out (U3) | iOS simulator on the MacBook Air | the Dev Apple Account (never the maintainer's own) | Development |
| TestFlight, from step 8 | the maintainer's iPhone and Mac | the maintainer's own | Production (real data) |

- Development builds talk to CloudKit **Development** (`aps-environment` development), TestFlight builds to
  **Production**. After the protocol, no development build goes onto the maintainer's devices again: it would replace
  the TestFlight app and open its Production-backed store (#2, P3).
- The protocol writes **synthetic documents only** (#2, P2). The documents already in Development from #1 step 9 and
  #4 M1 (2026-11-11) stay and take part (R0); the Sync lab never writes to them directly.
- No TestFlight build of Dokumentum is installed on either device during the protocol.
- **Classification is switched back on before any sitting ends** (step Z). The Sync lab's **Classify on this device**
  writes #8's per-device setting `classification.enabled` into the app's defaults, the same setting as the app's own
  switch "Suggest metadata with Apple Intelligence" (Settings › Suggestions, #8 part 3, #139). Debug and Release
  builds share the bundle ID (`space.pklnx.Dokumentum`), so a TestFlight build installed on the same device later
  reads the value the development build left. The TestFlight app has the switch in its settings, so a switch left
  off can be turned on there, but nothing in that app says that the protocol turned it off: classification would
  stay silently off until someone looks. Z therefore stays part of every sitting.

## What the status shows

The sidebar footer's line and the "iCloud Sync" detail are described in [index.md](./index.md), "The sync status"
(#31, part 1). For the protocol:
- **"Checking iCloud…"** until CloudKit answers the account question or the first sync event ends.
- **"iCloud account changed"** means a CloudKit user (`userRecordID`) that differs from the last one seen **while the
  app ran**. A switch while the app was not running is not shown as a change: the previous user is kept in memory
  only.
- **"Last synced"** is the later of the last successful import and export event. It needs
  `NSPersistentCloudKitContainer.eventChangedNotification` under SwiftData; step 0 of run 1 checks that it is posted.
- The detail view shows a problem's CloudKit code ("CKError 25"), so a screenshot is enough for a diagnosis.

## Known behaviour

What the code does across devices by design, and what the protocol measures. Each item names the case that checks
it.

- **Nothing is deleted automatically.** Tombstones (merged tags, correspondents and types) and orphans (a file,
  thumbnail or text without its document) stay, hidden and counted by the repair, until #32 decides what happens to
  orphans. Documents sharing an `id` (from two devices) stay until step 16's dedupe. The Sync lab shows the counts.
- **A document can arrive before its file, thumbnail or text.** Records arrive in any order: the library shows
  "Still downloading" while the file is missing, and processing waits for the file data and the text record (S1
  records the order).
- **Two texts for one document** can arise when two devices create one before syncing; the second stays unlinked and
  is counted (`documentsWithTwoTexts`), never deleted. K1–K3 and R1 check that the processing queue does not cause
  one.
- **A revived tombstone**: the repair revives a merged tag, correspondent or type when the chain's end is gone after a
  completed import (C5, C6 observe the merges).
- **Residual windows.** The repair and the processing queue re-read a row before they save (I6, T6), but a save on
  the **other device** that has not arrived yet cannot be seen. Whether CloudKit then merges per field or writes the
  whole record, and by edit time or by export order, is what C1, C2, L1–L3 and (run 2) M1/M2 measure.
- **Double processing after an offline takeover** (K3): a device that was offline and processes its own claim while
  the other one took it over produces the same document twice; the result write's exact-claim check drops one result
  on each device, and the last export wins. Recorded: whose text and file remain, and whether the two OCR texts
  differed.
- **The re-queue flag is per device** (`processingRequeue.textV1`, never synced; R). A device whose pass ran before
  CloudKit delivered step 3's documents never re-queues them; only the other device's pass can (N-e of #6). R0 records
  both flags before run 1.
- **Search after a remote import** (Q): the index follows the store's history; a text that arrives through CloudKit
  is found once its record arrived (no relaunch). A miss shows its cause in the Sync lab's "Search index" line (the
  last history error code).
- **Dates are compared at millisecond precision.** CloudKit stores dates in milliseconds, while the writing device
  keeps its full value, so "Export state" writes whole milliseconds. A difference that remains at 1 ms (if CloudKit
  truncates instead of rounding) is recorded in the results, not hidden.
- **The trash across devices** (moved here from index.md, #3 T7). `DocumentTrash` is the only code outside the Sync lab
  that deletes a `Document`. Moving to the trash and restoring set or clear `deletedAt` and `touch()` the document;
  nothing else changes, so a restored document keeps its inbox state and metadata. Empty Trash deletes only the
  documents its confirmation counted, after reading them again in a context of its own: one restored or trashed
  meanwhile stays. A document's linked PDF, thumbnail and text go with it by the model's cascade; tags,
  correspondents and types stay. **A PDF or its text that is not linked to its document at that moment is not
  deleted** (it can still be arriving by sync, or arrive after the delete): it stays as a hidden orphan that the
  repair counts, until #32. T-A–T-C check it across devices.

## The Sync lab

Debug builds only (`Dokumentum/Features/SyncLab/`; `scripts/check-project.py` checks that every file there is one
`#if DEBUG` block, and a Release build contains none of it). Open it on the **Mac** from the menu **Debug › Sync
Lab…** (a window of its own), on the **iPhone** from the sidebar's ladybug menu, **Sync Lab** (a sheet). Its texts are
English and are not translated.

On a store on disk the lab's first write of a launch asks first ("Write to the synced store?"). Everything it writes
goes through the app's own code (the importer, the editor, the trash), except five Debug writes:
1. **Legacy document**: a document as step 3 left it (`done`, no text, no thumbnail), for R.
2. **Delete directly** (no trash), for S3.
3. **Write large text** (N MB into a `done` document's text, past the 500,000-byte cap), for C7.
4. **Reset re-queue flag** (this device's per-device flag, not synced), for R.
5. **Move tag** under another tag, for C6 (the app has no tag editing yet).

Writes 2, 3 and 5 and the lab's **Empty lab trash** accept **only lab records**: documents whose original file name
starts with `SyncLab-`, tags whose name does. Everything the lab creates gets that prefix (tags, correspondents and
types too, so "Stadtwerke" becomes "SyncLab-Stadtwerke"); nothing else in the store can be deleted or overwritten by
it. Edits through the editor and the trash (title, date, tags, move to the trash, restore) are offered on every row,
as in the app.

Two **device settings** (never synced) change only with a store on disk, after the same question: the re-queue flag
(write 4) and **Classify on this device**, #8's per-device switch `classification.enabled` (on unless set). It is
the same setting as the app's switch "Suggest metadata with Apple Intelligence" (Settings › Suggestions; on the Mac
⌘, , on the iPhone the gear in the sidebar): the lab writes the suite the app's settings and the processing queue
use, the app's settings show the lab's change when they open, and the lab's line "Classification" follows a change
made there. With an in-memory store both are disabled.

Sections:
- **This device:** the short device ID, the store that opened, the takeover interval in effect (120 s with
  `-ProcessingTakeoverSeconds 120`, else 21600 s), the re-queue flag, the processing scheduler (held, paused,
  running or idle, and the last run's counts), the repair's last counts (orphans, two files/thumbnails/texts, `id`
  duplicates, tombstones) with **Run repair now**, the search index (state, counts, last history error), the raw sync
  status, the CloudKit user (short) and the **event log** (kind, start, end, ok or the error codes; newest first).
  **Classify on this device** turns #8's classification on or off on this device (the line "Classification" shows
  it); with it off, processing ends in `done` without suggestions.
  **Hold processing on this device** stops processing on this device until it is turned off or the app quits: an
  import still writes its claim, file and text record, but nothing is processed. It writes no data; scene changes
  and background tasks do not end it; on the iPhone an import while held asks for no background "Processing
  documents" task.
- **Create:** a *text document* (N pages of real text, with tags, a correspondent and a type by name), a *scan-like
  document* (N rendered page images, imported as a scan: Vision OCR and the text layer run), a *large file* (about
  20 MB of noise images) and a *legacy document*. Each gets a fresh **unique word** (`syncw` and 6 letters, shown with
  **Copy**) on every page, for the search cases. **Letter page** (text and scan-like documents, off by default) makes
  page 1 read like a letter (sender, date, amount) for M1/M2 only; without it no page offers the classifier a
  correspondent, type or date.
- **Documents:** every document, trashed ones included: title, state, claim (this device, another device's short ID,
  or none, with its age), text source, pages, file size. Tap a row for its actions: **Read text, file and
  thumbnail** (length, hash prefix, text layer yes/no), set title, date, inbox, tags, correspondent, type, move to
  the trash or restore; for lab documents also **Write large text** and **Delete directly**. **Empty lab trash** at
  the top deletes the trashed **lab** documents through the app's trash code; other trashed documents stay (the
  message names how many).
- **Metadata:** create a tag, correspondent or type; move a lab tag under another (or to the top level).
- **Search probe:** searches the app's index as the library's search field does, with the hits' titles.
- **Export state:** the dump, with **Copy dump** and **Share dump**. Its first line is `dump sha256=… dates=…`: two
  devices agree when these are equal. **Dates** chooses how dates become whole milliseconds: *round to nearest ms*
  (the default) or *truncate to ms*; both devices must use the same (step 0 decides which). The next seven lines give
  one hash per entity (Document, DocumentFile, DocumentThumbnail, DocumentText, Tag, Correspondent, DocumentType), so
  a difference is found per entity. Records follow, every field of the schema, dates in milliseconds, files,
  thumbnails and texts as length and SHA-256 only. The last section (this device's ID, re-queue flag, failure
  counters, claim sightings) is not in any hash.
- **CloudKit schema:** **Initialize CloudKit schema** (only with the CloudKit store) creates every record type in
  Development, for a look in the CloudKit Console.

## Running the protocol

### Before run 1 (P7)
1. The iPhone is registered for development and has the app group in its profile (#1 steps 3 and 9, #4 M2/M3 for the
   iPhone). The Mac passed on 2026-11-11.
2. Both devices signed in to the maintainer's own iCloud account; iCloud Drive need not be on.
3. On the MacBook Air: check out the part-2 PR head (`gh pr checkout <number>`), note its SHA
   (`git rev-parse --short HEAD`) for the results table, open `Dokumentum.xcodeproj`, scheme **Dokumentum**,
   configuration Debug (Xcode's Run uses it).
4. Run once on **My Mac** and once on the **iPhone** (by cable, so Airplane mode later does not cut Xcode off; after
   the first install the iPhone app can also be started from the home screen).
5. For K1–K3 only, the Mac needs the takeover argument: **Product › Scheme › Edit Scheme… › Run › Arguments**, add
   `-ProcessingTakeoverSeconds 120`. It is read at launch only: every relaunch of the Mac in K1–K3 goes through
   Xcode's Run, or from Terminal:
   `open -n <path to Dokumentum.app> --args -ProcessingTakeoverSeconds 120 -ApplePersistenceIgnoreState YES`.
   A launch from the Dock does not carry it. Check "Takeover interval: 120 s" in the Sync lab before each K case.
   No other case needs it.

### How each case is recorded
- **A** is the Mac, **B** the iPhone, unless a case says otherwise. **Offline** means Airplane mode on the iPhone and
  Wi-Fi off on the Mac.
- **Before and after** each case: on both devices wait until the Sync lab's event log shows no event `running`, then
  **Export state** on both and compare the first line. If the hashes still differ after 5 minutes, note it and copy
  both dumps (Copy dump) into the results comment; the entity lines show where they differ.
- Times come from the event log. Record per case: expected, what A showed, what B showed, the two dump hashes (first
  12 characters), and anything unexpected (a screenshot of the "iCloud Sync" detail if the footer shows a problem).
- The protocol can stop between cases and continue another day; record which case was last. **Every stop, planned
  or early, first runs step Z** (classification on, both devices); the next sitting turns it off again on both, as
  in R0, before its first case.

## Run 1 (merge gate of #31 part 2; about 3 hours, in two or three sittings)

Order: **R0, 0, S1–S3, U1, Q** (DW1), then **C1–C6, T, K, L, R, C7** (DW2; C7 last because a stalled upload could
hold up the cases after it), then **M1, M2**, then **U2, U3**, and last **Z** (classification on, both devices).
The classifier (#8 parts 1 and 2, #146 and #150) is in
this build, so the cases of run 2 join run 1 (P5 of #31); they are described under "Run 2" below and belong to #8's
Done-when, not to DW2.

**Classification stays off until M1.** #8's classifier fills the title, date, correspondent, type and tags of a
document nobody has edited yet. In the other cases it would write fields the case does not expect (L1–L3 measure the
text layer against an edit, not a classification). So in R0 both devices turn **Classify on this device** off, and
only M1/M2 turn it on, on A alone. Only M1/M2 use **Letter page**. Step Z turns it on again on both, at the end and
at every stop (see "Accounts and environments" for why).

**R0 first, before anything else on a fresh launch:** open the Sync lab on both devices and, before creating
anything, write down for each:
- "Re-queue flag" (set or not set). The launch's pass runs before the lab opens, so this normally reads "set".
- The "Last run" line, in particular `requeued N`: what this launch's pass re-queued. A later run replaces the line,
  so read it first. Records that sync imported before the lab opened may already have started such a later run, so
  the line can show `requeued 0` although the launch's pass re-queued documents; the expectation below (documents
  end `done` with text) decides, not this line alone.
- Then turn **Classify on this device** off on both (answer the question with **Write**). The line "Classification"
  reads `off`.
- Let both apps run with the store loaded. Expected: every document a step-3 build imported before this run (the
  Mac's documents of 2026-11-11, if any) ends `done` with text on both devices. If neither device re-queued them
  (`requeued 0` on both, and the documents stay without text), record that as the N-e case occurring for real.

**0, preflight**
1. Both apps start; the footer leaves "Checking iCloud…" within a minute.
2. The Sync lab's event log shows setup, import and export events. If it stays empty, the notification is not posted
   under SwiftData: record it ("last synced" cannot work then; a follow-up).
3. The Mac syncs at all (a text document created on the Mac appears on the iPhone). If not, and the Console shows a
   network denial, the sandboxed Mac needs `com.apple.security.network.client`: record it, run step Z and stop; that
   is a follow-up change with its own review.
4. **Dates in the dump.** Once that document is `done` on both, **Export state** on both (Dates: *round to nearest
   ms*) and compare the first lines.
   - Equal: keep *round to nearest ms* for the whole run.
   - Not equal: **Copy dump** on both and compare that document's date lines (`createdAt`, `modifiedAt`,
     `documentDate`, `processingClaimedAt`). If they differ by exactly 1 ms and nothing else differs, CloudKit
     truncates: switch **Dates** to *truncate to ms* on both and export again. If the first lines are now equal, use
     *truncate to ms* for the whole run and note it in the results. If they still differ, or other lines differ,
     record it, paste both dumps into the results comment and continue: the cases are then compared by the entity
     lines that do not carry dates (the session compares the pasted dumps).
5. Optional: **Initialize CloudKit schema** on one device and a look at the CloudKit Console (Development).

**S1–S3, documents and metadata (DW1)**
- **S1:** A creates a *text document* with 3 pages, tags "Rot, Blau", correspondent "Stadtwerke" and type
  "Rechnung". On B: record when it appears, whether "Still downloading" showed, and in which order the file,
  thumbnail and text arrived (the row's "Read text, file and thumbnail" shows which exist). Expected: equal dumps
  once both are `done`.
- **S2:** B changes the title and removes one tag. A shows the change. Equal dumps.
- **S3:** B uses **Delete directly** on the S1 document. A no longer lists it, and its file, thumbnail and text are
  gone (A's repair line: no new orphans). Equal dumps.

**U1, status:** after S1 both footers show "iCloud sync on · last synced …"; the "iCloud Sync" detail's download and
upload times move with each step.

**Q, search after a remote import (#7 M2, #123 N-b).** Use the library's search field (the Sync lab's probe gives the
same answer and the index state).
- **Q1:** A creates a text document; copy its word W1. Once B's Sync lab shows it `done` with text, B (not relaunched)
  finds W1 within a minute.
- **Q2:** A (not relaunched) finds W1: the local history path on a mirrored store.
- **Q3:** A creates a *scan-like document* (2 pages); its word is found on A and on B without a relaunch once both show
  it `done` with `vision`.
- **Q4:** B adds a new word W2 to that document's title; A finds W2 without a relaunch.
- A miss: record the "Search index" line (state and last history error) of the device that missed.

**C1–C6, conflicts (DW2)** (each on a fresh text document both devices show `done`; C7 comes after R):
- **C1, different fields offline:** both offline. A changes the title; B changes the date and the inbox flag. Both
  online. Expected: A's title and B's date and inbox flag on both.
- **C2, same field offline:** both offline. A sets the title "A", then B sets "B" (later by the clock). A online
  first, then B. Then the same with B online first. Record which title wins each time: by edit time or by export
  order.
- **C3, to-many:** both offline; A adds tag "X3", B adds tag "Y3" to the same document. Both online. Expected: both tags
  (record if one is lost).
- **C4, delete against edit:** both offline; A deletes the document directly, B changes its title. Both online.
  Record the result on both (gone, or back with B's title).
- **C5, same-name metadata:** both offline; both create the correspondent "Kanzlei C5" (Metadata section) and
  assign it to different documents. The name must be new: no earlier case may have created it, because creating a
  name that exists returns the existing record, and then there is nothing to merge. Both online, then **Run repair
  now** on both. Expected: one live "SyncLab-Kanzlei C5" with both documents on both devices, the other a tombstone
  (repair line: tombstones +1 on both); equal dumps.
- **C6, concurrent tag moves:** create tags "X6" and "Y6" on A, wait until B has them. Both offline; A moves X6 under
  Y6, B moves Y6 under X6. Both online, **Run repair now** on both. Expected: no cycle, the same tag at the top on both;
  equal dumps.

**T-A–T-C, the trash across devices (#3)**
- **T-A:** A moves a document to the trash; B shows it in the trash. B restores it; A shows it back.
- **T-B:** A empties the trash with the Sync lab's **Empty lab trash** (Documents section; it deletes only lab
  documents, so nothing else in the trash is lost); B no longer has the document or its file.
- **T-C:** B offline restores a trashed document; meanwhile A empties the trash, again with **Empty lab trash**; B
  online. Record the result on both.
- The app's own Empty Trash (Trash list) would also delete every other document in the trash; it is not used in the
  protocol.

**K1–K3, claims across devices (#4 M4).** The Mac (A) runs with `-ProcessingTakeoverSeconds 120`; check it first.
- **K1:** B turns on **Hold processing on this device** and creates a *scan-like document* with 5 pages. Once A's
  Sync lab lists it with B's claim, close B from the app switcher (the hold ends with it). After 2 minutes A shows
  A's claim, processes it (it ends `done` with `vision` and a layered file) and B, when reopened, shows the same.
  Expected: repair line `two texts 0` on both; equal dumps. Turn the hold on **before** the import: a "Processing
  documents" task asked for before the hold, or a hold turned on while such a task runs, makes no progress until the
  system ends it (harmless; it shows as a stalled progress line on the iPhone).
- **K2:** as K1 with 20 pages, but B is reopened (without the hold) while A is still processing. Expected: one text
  record, equal dumps, one device's result on both. Record B's "Last run" line (did B start a stage before A's claim
  arrived, and was its result dropped: "dropped 1").
- **K3, double processing:** B (no hold) creates a scan-like document online, goes offline at once and is closed. A
  takes over after 2 minutes and finishes. B is reopened, still offline, and processes it with its own claim. Then B
  online. Expected: `done` on both, one text record, equal dumps; record whose text and file remain and whether the
  two texts differed (text hash on each device before B went online).

**L1–L3, text layer against a metadata edit** (scan-like documents without the letter page; classification off on
both, so A's processing writes only the text, the layered file, `pageCount`, `fileSize`, `textSource` and the state,
never the title, date or metadata)
- **L1:** A turns on the hold and creates a scan-like document. Once B shows it (`pending`, A's claim), B goes
  offline. A turns the hold off and processes (A shows `done`, `vision`, layered). B, offline, changes title, date and
  a tag. B online. Expected on both: B's title, date and tag; A's file, text, pages, file size, `vision`, `done`.
- **L2, the other export order:** A creates with the hold on. Once B shows it, A goes offline. B changes the title
  (online). A turns the hold off and processes offline. A online. Same expectation; if B's title is lost, CloudKit
  exported A's whole `Document` record, not its changed fields: record it.
- **L3:** as L1, but B moves the document to the trash while offline. Expected: in the trash on both, with A's file
  and text kept.

**R1–R2, re-queue across devices (#6)**
- **R1:** A creates 3 *legacy documents*. Once B shows them, press **Reset re-queue flag** on both and relaunch both
  within a few seconds. Expected: all three `done` with text on both; equal dumps; `two texts 0`. Record which device
  processed each (the claim) and whether any was processed twice.
- **R2:** B offline. A creates 3 legacy documents. B resets its flag and is relaunched (still offline; its pass runs
  on a store without them). B online. A resets its flag and is relaunched. Expected: A re-queues and processes all
  three; B never claims them; text on both.

**C7, size (last of DW2)**
- On a `done` lab document, **Write large text** with 2 MB; separately, create a *large file*. Record whether both
  arrive on the other device (text length and file hash in "Read text, file and thumbnail"), how long they took, and
  any failed event codes. The result decides whether the 500,000-byte text cap can be lifted (a follow-up issue, not
  this part).
- **Recovery before M1:** wait until neither event log shows an event `running` (at most 15 minutes). Then change a
  title on A and check that B shows it, and the other way round. If an export keeps failing (the same failed event
  repeating), use **Delete directly** on the two C7 documents on the device that wrote them, wait for the event log
  to settle and check both directions again. Record what was needed. If sync still does not recover, record it, run
  step Z and stop the run here: M1/M2 and U2/U3 then run in another sitting.

**U2, U3, the status under failure (last)**
- **U2:** A offline; change a title on A. Record what A's footer shows (the mirroring may just wait without an error).
- **U3** (P4 of #31: in the **iOS simulator on the MacBook Air, signed in to the Dev account**, never the maintainer's
  own; the iOS simulator runtime must be installed there first; the app running the whole time):
  1. Sign out of the Apple Account in the simulator's Settings: the footer shows "No iCloud account: documents stay on
     this device".
  2. Sign in again to the same Dev account: the footer shows "iCloud sync on".
  3. Sign out, then sign in to a **second** test account: the footer shows "iCloud account changed". This needs a
     second Apple Account that is not the maintainer's own; without one, step 3 is recorded as not run.
  4. Record what happened to the local documents after each step (kept, removed, re-downloaded).

**Z, classification on, both devices (closing step; also at every stop)**
- On the Mac and on the iPhone: open the Sync lab, turn **Classify on this device** on (answer the question with
  **Write**) and check that the line "Classification" reads `on`. Instead of the lab's toggle, the app's own switch
  works too: Settings › Suggestions, "Suggest metadata with Apple Intelligence" on (on the Mac ⌘, , on the iPhone the
  gear in the sidebar); the lab's line then reads `on` as well. Record it in the results row Z, for both devices.
- Run it at the end of run 1 and before every stop: at the end of a sitting, after step 0 stops (entitlement), after
  C7's recovery fails, when M1/M2 are stopped or skipped, and before closing the apps for any other reason (for
  example the end of the day). **After a crash** of either app, relaunch both apps and run Z before anything else;
  the run continues afterwards as a later sitting does. A later sitting turns it off again on both before its first
  case.
- The line "Classification" reads the stored setting again every second, so it also shows a change made in the
  app's settings.

## Run 2 (M1, M2; about 30 minutes, run within run 1 on this build)

Classification against an edit on the other device (#8 M3, its review N1, Done-when item 3). It needs a build in
which the processing queue classifies, which is #8 part 2 (#150); with #8 part 1 alone no document is ever
classified. Both are on `main` and in the part-2 PR head, so M1 and M2 run within run 1, after R and before U2/U3 (P5
of #31); if they are skipped there, run step Z anyway, and M1/M2 run before the first TestFlight build. No takeover,
so no launch argument.
That A classified shows in A's Sync lab: "Last run" reads `classified 1` right after that run, and the document's row
gains the suggested correspondent or type. If the row stays without suggestions (the on-device model unavailable on
A), record that, stop the case (also M2 if M1 stopped), turn the switch on again on B as below, and continue with
U2/U3; step Z still closes the run.

**Before M1:** on A only, turn **Classify on this device** on (the line reads `on`); B stays off, so B never
classifies. After M2, turn it on again on B too, so both devices are back at the default.

- **M1:** A turns on the hold and creates a *text document* with **Letter page** on (its first page reads like a
  letter: "Stadtwerke Musterstadt", a date, an amount). Once B shows it, B goes offline and changes the title. A turns
  the hold off; A extracts the text, classifies it (empty fields filled) and exports. B online. Expected: B's title on
  both; A's other suggestions (correspondent, type, date, tags) kept.
- **M2, the reverse export order** (the loss case of N1): A creates with the hold on (again with **Letter page**).
  Once B shows it, A goes offline. B changes the title (exported). A turns the hold off and classifies offline, not
  having seen the edit, and fills the title. A online. Expected: B's title on both. If A's suggested title wins on
  both, "never overwrites an edit" does not hold across devices: the coordinator's follow-up for #8 applies (a synced
  per-field marker in schema V2); record it here and on #8.

## Results

Filled from the runs. One row per case; the dump columns hold the first 12 characters of each device's `dump sha256`.

| Case | Build SHA | Date | Expected | A (Mac) | B (iPhone) | Dump A | Dump B | Notes |
|---|---|---|---|---|---|---|---|---|
| R0 | | | | | | | | |
| 0 | | | | | | | | |
| S1 | | | | | | | | |
| S2 | | | | | | | | |
| S3 | | | | | | | | |
| U1 | | | | | | | | |
| Q1–Q4 | | | | | | | | |
| C1 | | | | | | | | |
| C2 | | | | | | | | |
| C3 | | | | | | | | |
| C4 | | | | | | | | |
| C5 | | | | | | | | |
| C6 | | | | | | | | |
| T-A | | | | | | | | |
| T-B | | | | | | | | |
| T-C | | | | | | | | |
| K1 | | | | | | | | |
| K2 | | | | | | | | |
| K3 | | | | | | | | |
| L1 | | | | | | | | |
| L2 | | | | | | | | |
| L3 | | | | | | | | |
| R1 | | | | | | | | |
| R2 | | | | | | | | |
| C7 | | | | | | | | |
| M1 | | | | | | | | |
| M2 | | | | | | | | |
| U2 | | | | | | | | |
| U3 | | | | | | | | |
| Z (classification on, both) | | | | | | | | |

Where each result goes besides this table: K onto #4 (M4), R onto #6, Q onto #7, M onto #8, T-A–T-C onto #3; DW1 and
DW2 onto #2 through #31's part-2 PR.
