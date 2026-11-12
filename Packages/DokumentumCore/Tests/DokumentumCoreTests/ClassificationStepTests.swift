import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import DokumentumCore

/// The classification step of the processing queue (#8, part 1) with a stub classifier: the text step hands on to
/// it, it fills only empty fields, its write never overwrites an edit on this store, and every row of its outcome
/// table. Tests wait for reports, checkpoints and signals.
struct ClassificationStepTests {
    // MARK: The text step hands on (T7, P9)

    /// T7: the text result write sets `classify`, and the same run classifies the document next.
    @Test func theTextAndThenTheClassificationRunInOneRun() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(title: "Scan 2027-04-20", device: deviceA, claimedAt: processingStart)
        try store.insertMetadata(.tag, "Strom")
        let classifier = StubClassifier()
        let queue = store.classifyingQueue(classifier: classifier, clock: clock)

        let report = await queue.run()

        #expect(report.toClassify == 1)
        #expect(report.classified == 1)
        #expect(report.done == 1, "one document marked done, by the classification write")
        #expect(classifier.count == 1)
        #expect(classifier.requests.first?.text == billText, "the text the text step wrote")
        #expect(classifier.requests.first?.known.tags == ["Strom"])
        let row = try store.classified(id)
        #expect(
            row
                == ClassifiedRow(
                    title: "Jahresabrechnung Strom", documentDate: billDate, modifiedAt: processingStart,
                    correspondent: "Stadtwerke München GmbH", documentType: "Abrechnung", tags: ["Strom"],
                    stateRaw: "done"))
        #expect(await queue.run().saves == 0, "a classified document is never classified again")
        #expect(classifier.count == 1)
    }

    /// P9: a document created before this device's first run with a classifier is not classified; the text write
    /// sets `done` as before. One created at the cut-off or later is.
    @Test func documentsImportedBeforeTheStepAreNotClassified() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let failures = store.failures(deviceA)
        // The cut-off was recorded by an earlier run at `processingStart`.
        ClassificationSettings(defaultsSuite: failures.defaultsSuite).recordSince(processingStart)
        clock.advance(by: hour)
        let before = try store.insert(
            title: "Before", created: processingStart.addingTimeInterval(-1), device: deviceA, claimedAt: clock.now)
        let at = try store.insert(title: "At", created: processingStart, device: deviceA, claimedAt: clock.now)
        let classifier = StubClassifier()
        let queue = store.classifyingQueue(classifier: classifier, failures: failures, clock: clock)

        let report = await queue.run()

        #expect(report.toClassify == 1)
        #expect(report.done == 2)
        #expect(classifier.count == 1)
        #expect(try store.classified(before).title == "Before", "not classified")
        #expect(try store.classified(before).stateRaw == "done")
        #expect(try store.classified(at).title == "Jahresabrechnung Strom")
        #expect(ClassificationSettings(defaultsSuite: failures.defaultsSuite).since == processingStart, "never moved")
    }

    /// The first run with a classifier records the cut-off: a document still waiting for its text then, created
    /// before, finishes in `done`.
    @Test func theFirstRunRecordsTheCutOff() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let failures = store.failures(deviceA)
        let waiting = try store.insert(created: processingStart.addingTimeInterval(-hour), device: deviceA)
        let classifier = StubClassifier()

        let report = await store.classifyingQueue(classifier: classifier, failures: failures, clock: clock).run()

        #expect(ClassificationSettings(defaultsSuite: failures.defaultsSuite).since == processingStart)
        #expect(report.toClassify == 0)
        #expect(classifier.count == 0)
        #expect(try store.classified(waiting).stateRaw == "done")
    }

    /// Without a classifier (the app before part 2), the switch off, or the model unavailable here, the text write
    /// sets `done` directly.
    @Test(arguments: TextWriteCase.allCases)
    func theTextWriteSetsDoneWhenTheStepDoesNotRun(case: TextWriteCase) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let failures = store.failures(deviceA)
        let id = try store.insert(device: deviceA, claimedAt: processingStart)
        let classifier = StubClassifier(
            availability: `case` == .unavailable ? .unavailable(.deviceNotEligible) : .available)
        if `case` == .switchOff { ClassificationSettings(defaultsSuite: failures.defaultsSuite).isEnabled = false }
        let queue =
            `case` == .noClassifier
            ? ProcessingQueue(
                container: store.container, deviceID: deviceA, failures: failures, stage: textStage(),
                now: clock.function)
            : store.classifyingQueue(classifier: classifier, failures: failures, clock: clock)

        let report = await queue.run()

        #expect(report.toClassify == 0)
        #expect(report.done == 1)
        #expect(report.saves == 1, "no extra save")
        #expect(classifier.count == 0)
        #expect(try store.classified(id).stateRaw == "done")
        #expect(try store.classified(id).title == "Document")
    }

    enum TextWriteCase: String, CaseIterable, CustomTestStringConvertible {
        case noClassifier, switchOff, unavailable
        var testDescription: String { rawValue }
    }

    /// A model that is not ready yet still sets `classify`: the step waits for it.
    @Test func aModelThatIsNotReadyStillSetsClassify() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceA, claimedAt: processingStart)
        let classifier = StubClassifier(availability: .notReady)

        let report = await store.classifyingQueue(classifier: classifier, clock: clock).run()

        #expect(report.toClassify == 1)
        #expect(report.waiting == 1)
        #expect(try store.classified(id).stateRaw == "classify")
    }

    // MARK: Only empty fields (T2, P2, P7)

    /// One user edit before the step (through `DocumentEditor`, which touches the document): the edited field stays,
    /// title and date stay because the document was edited, and the other empty fields are filled.
    @MainActor
    @Test(arguments: UserEdit.allCases)
    func aFieldTheUserSetIsKept(edit: UserEdit) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        let strom = try store.insertMetadata(.tag, "Strom")
        let mine = try store.insertMetadata(.tag, "Mein Tag")
        let correspondent = try store.insertMetadata(.correspondent, "Meine Bank")
        let type = try store.insertMetadata(.documentType, "Brief")
        _ = strom
        let editor = DocumentEditor(
            context: ModelContext(store.container), now: { processingStart.addingTimeInterval(60) })
        let userDate = processingStart.addingTimeInterval(-30 * 86_400)
        switch edit {
        case .title: try editor.apply(.title("Mein Titel"), to: id)
        case .date: try editor.apply(.documentDate(userDate), to: id)
        case .correspondent: try editor.apply(.correspondent(correspondent), to: id)
        case .type: try editor.apply(.documentType(type), to: id)
        case .tags: try editor.apply(.tag(mine, true), to: id)
        case .inbox: try editor.apply(.inbox(false), to: id)
        }

        let report = await store.classifyingQueue(classifier: StubClassifier(), clock: clock).run()

        #expect(report.classified == 1)
        let row = try store.classified(id)
        #expect(row.stateRaw == "done")
        #expect(row.modifiedAt == processingStart.addingTimeInterval(60), "the write does not touch")
        #expect(row.title == (edit == .title ? "Mein Titel" : "Scan 2027-04-20"), "an edited document keeps its title")
        #expect(row.documentDate == (edit == .date ? userDate : processingStart), "and its date")
        #expect(row.correspondent == (edit == .correspondent ? "Meine Bank" : "Stadtwerke München GmbH"))
        #expect(row.documentType == (edit == .type ? "Brief" : "Abrechnung"))
        #expect(row.tags == (edit == .tags ? ["Mein Tag"] : ["Strom"]))
    }

    enum UserEdit: String, CaseIterable, CustomTestStringConvertible {
        case title, date, correspondent, type, tags, inbox
        var testDescription: String { rawValue }
    }

    /// P7: a document imported from a file keeps its file name as title until classified, and the file-name title
    /// and the import date are replaced while it was never edited.
    @Test func aFileNameTitleAndTheImportDateAreReplacedWhileNeverEdited() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify(title: "IMG_2041")

        _ = await store.classifyingQueue(classifier: StubClassifier(), clock: clock).run()

        let row = try store.classified(id)
        #expect(row.title == "Jahresabrechnung Strom")
        #expect(row.documentDate == billDate)
        #expect(row.modifiedAt == processingStart)
    }

    // MARK: Never overwriting an edit on this store (Done-when item 3, N1)

    /// The user edits the correspondent while the model runs: through `DocumentEditor` (this device) or saved by
    /// another context (an edit of the other device arriving by sync, with its own `modifiedAt`). The write fetches
    /// afterwards and keeps it; the fields still empty are filled.
    @MainActor
    @Test(arguments: [false, true])
    func anEditDuringTheModelCallIsKept(fromOtherDevice: Bool) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        try store.insertMetadata(.tag, "Strom")
        let call = Checkpoint()
        defer { call.release() }
        let classifier = StubClassifier(checkpoint: call)
        let queue = store.classifyingQueue(classifier: classifier, clock: clock)

        let run = Task { await queue.run() }
        await call.reached()
        if fromOtherDevice {
            try store.edit(id) { document, context in
                let record = Correspondent(name: "Vom iPhone", createdAt: processingStart)
                context.insert(record)
                document.correspondent = record
                document.touch(processingStart.addingTimeInterval(5))
            }
        } else {
            let editor = DocumentEditor(
                context: ModelContext(store.container), now: { processingStart.addingTimeInterval(5) })
            let record = try editor.createMetadata(kind: .correspondent, name: "Vom iPhone")
            try editor.apply(.correspondent(record), to: id)
        }
        call.release()
        let report = await run.value

        #expect(report.classified == 1)
        let row = try store.classified(id)
        #expect(row.correspondent == "Vom iPhone", "the edit stays")
        #expect(row.title == "Scan 2027-04-20", "edited: the title is the user's")
        #expect(row.documentDate == processingStart)
        #expect(row.documentType == "Abrechnung", "empty fields are filled")
        #expect(row.tags == ["Strom"])
        #expect(try store.correspondents() == ["Vom iPhone"], "no correspondent created for the suggestion")
    }

    /// An edit saved in the write's window (between its fetch and its check): the write backs off and writes
    /// nothing; the next run decides the fields again, keeps the edit, fills the rest, and does not ask the model
    /// again (the cache, T3).
    @Test func anEditInTheWritesWindowStaysAndTheNextRunUsesTheCachedAnswer() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        try store.insertMetadata(.tag, "Strom")
        let edited = Mutex(false)
        let hooks = ProcessingQueue.Hooks(beforeCheck: { kind in
            guard kind == .classification, !edited.withLock({ $0 }) else { return }
            edited.withLock { $0 = true }
            try store.edit(id) { document, _ in
                document.title = "Mein Titel"
                document.touch(processingStart.addingTimeInterval(5))
            }
        })
        let classifier = StubClassifier()
        let queue = store.classifyingQueue(classifier: classifier, clock: clock, hooks: hooks)

        let first = await queue.run()

        #expect(first.backedOff == 1)
        #expect(first.saves == 0)
        let afterEdit = try store.classified(id)
        #expect(afterEdit.title == "Mein Titel")
        #expect(afterEdit.stateRaw == "classify")
        #expect(afterEdit.correspondent == nil, "nothing written")
        #expect(try store.correspondents().isEmpty, "the inserted correspondent was rolled back")

        let next = await queue.run()

        #expect(next.classified == 1)
        #expect(classifier.count == 1, "the model must not be asked again: the cached answer is written")
        let row = try store.classified(id)
        #expect(row.title == "Mein Titel")
        #expect(row.documentDate == processingStart, "edited: the date stays")
        #expect(row.correspondent == "Stadtwerke München GmbH")
        #expect(row.documentType == "Abrechnung")
        #expect(row.tags == ["Strom"])
        #expect(row.stateRaw == "done")
    }

    /// A record the write links, renamed in the write's window by another save (review A B1 of #146): the write
    /// backs off, and **the rename stays stored**. Without the record's row in the check, the write's stale copy of
    /// that row would be saved back whole and undo the rename (#56). One case per kind the write links.
    @Test(arguments: [MetadataKind.correspondent, .documentType, .tag])
    func aRenameOfALinkedRecordInTheWindowBacksOffAndTheRenameStays(kind: MetadataKind) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        let name =
            switch kind {
            case .correspondent: "Stadtwerke München"
            case .documentType: "Abrechnung"
            case .tag: "Strom"
            }
        let known = try store.insertMetadata(kind, name)
        let renamed = Mutex(false)
        let hooks = ProcessingQueue.Hooks(beforeCheck: { write in
            guard write == .classification, !renamed.withLock({ $0 }) else { return }
            renamed.withLock { $0 = true }
            try store.renameMetadata(kind, known, to: "Umbenannt")
        })

        let first = await store.classifyingQueue(classifier: StubClassifier(), clock: clock, hooks: hooks).run()

        #expect(first.backedOff == 1)
        #expect(first.saves == 0)
        #expect(try store.metadataName(kind, known) == "Umbenannt", "the rename was written over")
        let row = try store.classified(id)
        #expect(row.stateRaw == "classify")
        #expect(row.correspondent == nil && row.documentType == nil && row.tags.isEmpty)
    }

    // MARK: Outcomes (T4)

    /// Refusal, guardrail and language end in `done` with nothing filled, no counter, never asked again.
    @Test(arguments: [
        ClassificationFailure.DeclineReason.refusal, .guardrailViolation, .unsupportedLanguage,
    ])
    func aDeclineEndsInDoneWithNothingFilled(reason: ClassificationFailure.DeclineReason) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        let counter = store.failures(deviceA)
        let classifier = StubClassifier { _ in throw ClassificationFailure.declined(reason) }
        let queue = store.classifyingQueue(classifier: classifier, classificationFailures: counter, clock: clock)

        let report = await queue.run()

        #expect(report.declined == 1)
        #expect(report.done == 1)
        #expect(report.failures == 0)
        #expect(counter.count(for: id) == 0, "cleared")
        let row = try store.classified(id)
        #expect(row.stateRaw == "done")
        #expect(row.title == "Scan 2027-04-20")
        #expect(row.correspondent == nil && row.documentType == nil && row.tags.isEmpty)
        _ = await queue.run()
        #expect(classifier.count == 1, "never retried")
    }

    /// The model not ready: no attempt and no model call; the report wakes the scheduler at this device's claim
    /// expiry (N4). Once the model is ready, the next run classifies.
    @Test func aModelThatIsNotReadyWaitsWithoutAnAttemptAndClassifiesOnceReady() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        let counter = store.failures(deviceA)
        let classifier = StubClassifier(availability: .notReady)
        let queue = store.classifyingQueue(classifier: classifier, classificationFailures: counter, clock: clock)

        let report = await queue.run()

        #expect(report.waiting == 1)
        #expect(report.saves == 0)
        #expect(report.nextClaimEnd == processingStart.addingTimeInterval(ProcessingClaimRules.takeoverInterval))
        #expect(report.nextWake == report.nextClaimEnd)
        #expect(classifier.count == 0)
        #expect(counter.count(for: id) == 0, "no attempt")
        #expect(try store.classified(id).stateRaw == "classify")

        classifier.availability = .available
        clock.advance(by: hour)
        #expect(await queue.run().classified == 1)
        #expect(try store.classified(id).stateRaw == "done")
    }

    /// N4: once this device's own claim is 6 hours old, the wait ends in `done`, and the claim is not renewed first
    /// (the rules alone would renew a stale own claim, and the wait would renew itself for ever).
    @Test func theWaitForTheModelEndsWhenTheOwnClaimIsStaleWithoutRenewingIt() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        let classifier = StubClassifier(availability: .notReady)
        let queue = store.classifyingQueue(classifier: classifier, clock: clock)
        #expect(await queue.run().waiting == 1)

        clock.advance(by: ProcessingClaimRules.takeoverInterval - 1)
        #expect(await queue.run().waiting == 1, "one second before the claim is stale")
        clock.advance(by: 1)
        let report = await queue.run()

        #expect(report.classificationSkipped == 1)
        #expect(report.saves == 1, "one write: done, no claim renewal")
        let row = try store.row(id)
        #expect(row.stateRaw == "done")
        #expect(row.claimedAt == processingStart, "the claim was not renewed")
        #expect(classifier.count == 0)
    }

    /// Without an own claim (none, or another device's expired one), the wait first claims the document, so its
    /// six hours run on this device's clock.
    @Test func aWaitWithoutAnOwnClaimClaimsFirst() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify(device: deviceB, claimedAt: processingStart.addingTimeInterval(-7 * hour))
        let queue = store.classifyingQueue(classifier: StubClassifier(availability: .notReady), clock: clock)

        let report = await queue.run()

        #expect(report.waiting == 1)
        #expect(report.saves == 1)
        #expect(report.nextClaimEnd == processingStart.addingTimeInterval(ProcessingClaimRules.takeoverInterval))
        let row = try store.row(id)
        #expect(row.deviceID == deviceA)
        #expect(row.claimedAt == processingStart)
        #expect(row.stateRaw == "classify", "the claim write keeps the state")
    }

    /// Unavailable on this device, the switch off, or a text too short: `done` without a model call or an attempt.
    @Test(arguments: SkipCase.allCases)
    func aSkipEndsInDoneWithoutAModelCall(case: SkipCase) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let failures = store.failures(deviceA)
        let short = String(repeating: "a ", count: 49) + "\n\u{0C}"  // 49 non-whitespace characters
        let id = try store.insertClassify(text: `case` == .shortText ? short : billText)
        let availability: ClassifierAvailability =
            switch `case` {
            case .notEligible: .unavailable(.deviceNotEligible)
            case .notEnabled: .unavailable(.appleIntelligenceNotEnabled)
            default: .available
            }
        let classifier = StubClassifier(availability: availability)
        if `case` == .switchOff { ClassificationSettings(defaultsSuite: failures.defaultsSuite).isEnabled = false }

        let report = await store.classifyingQueue(classifier: classifier, failures: failures, clock: clock).run()

        #expect(report.classificationSkipped == 1)
        #expect(report.done == 1)
        #expect(classifier.count == 0)
        #expect(try store.classified(id).stateRaw == "done")
        #expect(try store.classified(id).title == "Scan 2027-04-20")
    }

    enum SkipCase: String, CaseIterable, CustomTestStringConvertible {
        case notEligible, notEnabled, switchOff, shortText
        var testDescription: String { rawValue }
    }

    /// 50 non-whitespace characters are enough.
    @Test func fiftyCharactersAreEnough() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insertClassify(text: String(repeating: "ab ", count: 25))
        let classifier = StubClassifier { _ in ClassificationSuggestion(documentType: "Notiz") }

        _ = await store.classifyingQueue(classifier: classifier, clock: TestClock()).run()

        #expect(classifier.count == 1)
        #expect(try store.classified(id).documentType == "Notiz")
    }

    /// Other errors count, with the backoff of the text step; the third writes `done`, never `failed`. The text
    /// step's counter is not touched (T5).
    @Test func threeFailuresEndInDoneNotFailed() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        let failures = store.failures(deviceA)
        let counter = store.failures(deviceA)
        struct Broken: Error {}
        let classifier = StubClassifier { _ in throw Broken() }
        let queue = store.classifyingQueue(
            classifier: classifier, failures: failures, classificationFailures: counter, clock: clock)

        let first = await queue.run()
        #expect(first.failures == 1)
        #expect(first.nextRetry == processingStart.addingTimeInterval(60))
        #expect(await queue.run().waiting == 1, "the backoff")
        clock.advance(by: 60)
        #expect(await queue.run().failures == 1)
        clock.advance(by: 10 * 60)
        let third = await queue.run()

        #expect(third.classificationSkipped == 1)
        #expect(third.failed == 0)
        #expect(classifier.count == 3)
        #expect(try store.classified(id).stateRaw == "done")
        #expect(failures.count(for: id) == 0, "the text counter is separate")
        #expect(failures.documents.isEmpty)
    }

    /// Rate limited: the attempt is given back and no request is made before the reset date.
    @Test func aRateLimitGivesTheAttemptBackAndWaitsForItsReset() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        let counter = store.failures(deviceA)
        let reset = processingStart.addingTimeInterval(120)
        let classifier = StubClassifier { call in
            if call == 1 { throw ClassificationFailure.rateLimited(until: reset) }
            return billSuggestion
        }
        let queue = store.classifyingQueue(classifier: classifier, classificationFailures: counter, clock: clock)

        let first = await queue.run()
        #expect(first.waiting == 1)
        #expect(first.failures == 0)
        #expect(first.nextRetry == reset)
        #expect(counter.count(for: id) == 0, "given back")
        clock.advance(by: 119)
        #expect(await queue.run().waiting == 1)
        #expect(classifier.count == 1, "no request before the reset")
        clock.advance(by: 1)
        #expect(await queue.run().classified == 1)
    }

    /// A rate limit without a reset date waits 15 minutes.
    @Test func aRateLimitWithoutAResetWaitsFifteenMinutes() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        try store.insertClassify()
        let classifier = StubClassifier { _ in throw ClassificationFailure.rateLimited(until: nil) }
        let report = await store.classifyingQueue(classifier: classifier, clock: TestClock()).run()
        #expect(report.nextRetry == processingStart.addingTimeInterval(15 * 60))
    }

    /// `interruptNow()` during the request: the attempt is given back, nothing is written, the late answer is
    /// dropped, and the next run classifies.
    @Test func anInterruptionGivesTheAttemptBackAndDropsTheLateAnswer() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        let counter = store.failures(deviceA)
        let call = Checkpoint()
        defer { call.release() }
        let first = StubClassifier(checkpoint: call)
        let queue = store.classifyingQueue(classifier: first, classificationFailures: counter, clock: clock)

        let run = Task { await queue.run() }
        await call.reached()
        #expect(counter.count(for: id) == 1, "counted before the call")
        queue.interruptNow()
        #expect(counter.count(for: id) == 0, "given back when interruptNow() returns")
        #expect(await run.value.interrupted == 1)
        call.release()
        await first.answered.wait(for: 1)
        #expect(try store.classified(id).stateRaw == "classify", "the late answer was written")

        #expect(await queue.run().classified == 1)
        #expect(try store.classified(id).stateRaw == "done")
    }

    /// The stall watchdog (T11): a request without an answer for the timeout is cancelled and counted.
    @Test func theWatchdogCountsARequestThatDoesNotAnswer() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        let counter = store.failures(deviceA)
        let call = Checkpoint()
        defer { call.release() }
        let watchdog = ManualDebounce()
        let classifier = StubClassifier(checkpoint: call)
        let queue = store.classifyingQueue(
            classifier: classifier, classificationFailures: counter, clock: clock, watchdog: watchdog)

        let run = Task { await queue.run() }
        await call.reached()
        await watchdog.waitForStarts(1)
        watchdog.fire()
        let report = await run.value

        #expect(report.timedOut == 1)
        #expect(report.failures == 1)
        #expect(counter.count(for: id) == 1)
        #expect(try store.classified(id).stateRaw == "classify")
    }

    /// T6: one stage at a time across both kinds. An interrupted classification request that has not returned
    /// blocks the next run's text stage until it returns.
    @Test func aTextStageWaitsForAnInterruptedClassification() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        try store.insertClassify()
        let call = Checkpoint()
        defer { call.release() }
        let classifier = StubClassifier(checkpoint: call)
        let waits = TestSignal()
        let texts = Mutex(0)
        let stage = ClosureStage { _, progress in
            texts.withLock { $0 += 1 }
            progress(1, 1)
            return ProcessingResult(pageCount: 1, text: ExtractedText(pages: [billText], source: .pdfText))
        }
        let queue = store.classifyingQueue(
            classifier: classifier, stage: stage, clock: clock, hooks: .init(waitsForStage: { waits.fire() }))

        let first = Task { await queue.run() }
        await call.reached()
        queue.interruptNow()
        #expect(await first.value.interrupted == 1)
        // Older than the waiting document, so the next run starts with its text stage.
        let pending = try store.insert(
            title: "New", created: processingStart.addingTimeInterval(-1), device: deviceA, claimedAt: processingStart)

        let second = Task { await queue.run() }
        await waits.wait(for: 1, "the text stage did not wait for the interrupted classification")
        #expect(texts.withLock { $0 } == 0, "a text stage started while the classification ran")
        call.release()
        let report = await second.value
        // The new document is older than this device's cut-off (P9), so its text write sets `done`.
        #expect(report.classified == 1)
        #expect(report.done == 2)
        #expect(texts.withLock { $0 } == 1)
        #expect(try store.classified(pending).stateRaw == "done")
    }

    /// T6 the other way round: an interrupted text stage that has not returned blocks the next run's classification
    /// request until it returns.
    @Test func aClassificationWaitsForAnInterruptedTextStage() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        try store.insert(device: deviceA, claimedAt: processingStart)
        let page = Checkpoint()
        defer { page.release() }
        let texts = Mutex(0)
        let stage = ClosureStage { _, progress in
            let call = texts.withLock {
                $0 += 1
                return $0
            }
            // The first call ignores its cancellation until released, like a framework call.
            if call == 1 { await page.pass() }
            progress(1, 1)
            return ProcessingResult(pageCount: 1, text: ExtractedText(pages: [billText], source: .pdfText))
        }
        let classifier = StubClassifier()
        let waits = TestSignal()
        let queue = store.classifyingQueue(
            classifier: classifier, stage: stage, clock: clock, hooks: .init(waitsForStage: { waits.fire() }))

        let first = Task { await queue.run() }
        await page.reached()
        queue.interruptNow()
        #expect(await first.value.interrupted == 1)
        // Older than the interrupted document, so the next run starts with its classification.
        let waiting = try store.insertClassify(created: processingStart.addingTimeInterval(-1))

        let second = Task { await queue.run() }
        await waits.wait(for: 1, "the classification did not wait for the interrupted text stage")
        #expect(classifier.count == 0, "a classification request started while the text stage ran")
        page.release()
        let report = await second.value
        #expect(report.classified >= 1)
        #expect(try store.classified(waiting).stateRaw == "done")
    }

    // MARK: Claims

    /// Another device's fresh claim on a document in `classify` is waited for; an expired one is taken over.
    @Test func anotherDevicesClaimIsWaitedForAndTakenOverOnceExpired() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify(device: deviceB, claimedAt: processingStart)
        let classifier = StubClassifier()
        let queue = store.classifyingQueue(classifier: classifier, clock: clock)

        let waiting = await queue.run()
        #expect(waiting.waiting == 1)
        #expect(waiting.nextExpiry == processingStart.addingTimeInterval(ProcessingClaimRules.takeoverInterval))
        #expect(classifier.count == 0)

        clock.advance(by: ProcessingClaimRules.takeoverInterval)
        let report = await queue.run()
        #expect(report.classified == 1)
        #expect(report.saves == 2, "the takeover, then the result")
        #expect(try store.row(id).deviceID == deviceA)
    }

    /// A document trashed while the model runs: the result is dropped, nothing written.
    @Test func aDocumentTrashedDuringTheCallIsDropped() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        let call = Checkpoint()
        defer { call.release() }
        let queue = store.classifyingQueue(classifier: StubClassifier(checkpoint: call), clock: clock)

        let run = Task { await queue.run() }
        await call.reached()
        try store.edit(id) { document, _ in document.deletedAt = processingStart }
        call.release()
        let report = await run.value

        #expect(report.dropped == 1)
        #expect(report.saves == 0)
        let row = try store.classified(id)
        #expect(row.stateRaw == "classify")
        #expect(row.correspondent == nil)
    }

    /// A state of a newer build is never touched, also with a classifier.
    @Test func aStateOfANewerBuildIsSkipped() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insert(stateRaw: "suggest-v2", device: deviceA, claimedAt: processingStart)
        let classifier = StubClassifier()
        let report = await store.classifyingQueue(classifier: classifier, clock: TestClock()).run()
        #expect(report.skipped == 1)
        #expect(report.saves == 0)
        #expect(try store.row(id).stateRaw == "suggest-v2")
    }

    /// N3: the classification counter goes when its document is `done`.
    @Test func theClassificationCounterIsForgottenWhenTheDocumentIsDone() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        let counter = store.failures(deviceA)
        struct Broken: Error {}
        let queue = store.classifyingQueue(
            classifier: StubClassifier { _ in throw Broken() }, classificationFailures: counter, clock: clock)
        _ = await queue.run()
        #expect(counter.count(for: id) == 1)

        try store.edit(id) { document, _ in document.processingState = .done }
        _ = await queue.run()

        #expect(counter.documents.isEmpty)
    }

    // MARK: Metadata (P1, T10, N7)

    @Test func anExistingCorrespondentAndTypeAreLinkedByNameOrPrefix() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        try store.insertMetadata(.correspondent, "Stadtwerke München")
        try store.insertMetadata(.documentType, "abrechnung")
        let id = try store.insertClassify()

        _ = await store.classifyingQueue(classifier: StubClassifier(), clock: TestClock()).run()

        let row = try store.classified(id)
        #expect(row.correspondent == "Stadtwerke München", "the suggestion's longer name matched by prefix")
        #expect(row.documentType == "abrechnung", "equal name")
        #expect(try store.correspondents() == ["Stadtwerke München"], "none created")
        #expect(try store.documentTypes() == ["abrechnung"])
    }

    /// A new correspondent is created once; the next document's suggestion links it.
    @Test func aNewCorrespondentIsCreatedOnce() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let first = try store.insertClassify()
        let second = try store.insertClassify(created: processingStart.addingTimeInterval(1))

        _ = await store.classifyingQueue(classifier: StubClassifier(), clock: TestClock()).run()

        #expect(try store.correspondents() == ["Stadtwerke München GmbH"])
        #expect(try store.documentTypes() == ["Abrechnung"])
        #expect(try store.classified(first).correspondent == "Stadtwerke München GmbH")
        #expect(try store.classified(second).correspondent == "Stadtwerke München GmbH")
    }

    /// A tombstone is never linked: the suggestion creates a live record instead.
    @Test func aTombstoneIsNeverLinked() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        try store.insertMetadata(.correspondent, "Stadtwerke München GmbH", mergedInto: UUID())
        try store.insertMetadata(.tag, "Strom", mergedInto: UUID())
        let id = try store.insertClassify()

        _ = await store.classifyingQueue(classifier: StubClassifier(), clock: TestClock()).run()

        let document = try #require(try ProcessingStore.fetch(id, in: ModelContext(store.container)))
        #expect(document.correspondent?.isLive == true)
        #expect(document.tags?.isEmpty == true, "the only \"Strom\" is a tombstone")
        #expect(try store.tagCount() == 1, "no tag created")
    }

    /// Tags only from live tags: an unknown one is not created, an ambiguous name (two live tags, N7) links none.
    @Test func tagsComeOnlyFromOneLiveTagOfThatName() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        try store.insertMetadata(.tag, "Strom")
        try store.insertMetadata(.tag, "Steuer")
        try store.insertMetadata(.tag, "steuer")
        let id = try store.insertClassify()
        let classifier = StubClassifier { _ in ClassificationSuggestion(tags: ["Strom", "Steuer", "Erfunden"]) }

        _ = await store.classifyingQueue(classifier: classifier, clock: TestClock()).run()

        #expect(try store.classified(id).tags == ["Strom"])
        #expect(try store.tagCount() == 3)
    }

    /// The checks run before the write: an invented correspondent and a date the text does not say are dropped.
    @Test func anInventedCorrespondentAndDateAreNotWritten() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insertClassify()
        let classifier = StubClassifier { _ in
            ClassificationSuggestion(
                title: "Abrechnung", correspondent: "Unklar Versicherung AG",
                issueDate: SuggestedDate(day: 1, month: 1, year: 1900))
        }

        _ = await store.classifyingQueue(classifier: classifier, clock: TestClock()).run()

        let row = try store.classified(id)
        #expect(row.title == "Abrechnung")
        #expect(row.correspondent == nil)
        #expect(row.documentDate == processingStart)
        #expect(try store.correspondents().isEmpty)
    }

    // MARK: Fix round 1 of #146

    /// Review B1: a request that throws `notReady` while the availability says `available` (assets gone mid-request).
    /// Within the claim's 6 hours the model is asked at most once per `notReadyRetry`; at the claim's end the document
    /// is finished without another request, and the claim is not renewed.
    @Test func aThrownNotReadyWaitsAndEndsWithTheClaim() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        let counter = store.failures(deviceA)
        let classifier = StubClassifier { _ in throw ClassificationFailure.notReady }
        let queue = store.classifyingQueue(classifier: classifier, classificationFailures: counter, clock: clock)
        let claimEnd = processingStart.addingTimeInterval(ProcessingClaimRules.takeoverInterval)

        let first = await queue.run()
        #expect(first.waiting == 1)
        #expect(first.nextClaimEnd == claimEnd)
        #expect(first.nextRetry == processingStart.addingTimeInterval(ClassificationLimits.notReadyRetry))
        #expect(counter.count(for: id) == 0, "no attempt")
        _ = await queue.run()
        _ = await queue.run()
        #expect(classifier.count == 1, "asked again before the retry time")

        clock.advance(by: ClassificationLimits.notReadyRetry)
        #expect(await queue.run().waiting == 1)
        #expect(classifier.count == 2, "asked again after the retry time")

        clock.advance(by: ProcessingClaimRules.takeoverInterval - ClassificationLimits.notReadyRetry)
        let last = await queue.run()
        #expect(last.classificationSkipped == 1)
        #expect(classifier.count == 2, "the wait ends without another request")
        let row = try store.row(id)
        #expect(row.stateRaw == "done")
        #expect(row.claimedAt == processingStart, "the claim was not renewed")
    }

    /// Review B1, without the queue's memory (a relaunch): the stale own claim is renewed before the request, and
    /// the thrown `notReady` is decided on the claim as it was before that renewal, so the wait ends.
    @Test func aThrownNotReadyOnAStaleOwnClaimEndsTheWaitAfterTheRenewal() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        clock.advance(by: ProcessingClaimRules.takeoverInterval)
        let classifier = StubClassifier { _ in throw ClassificationFailure.notReady }

        let report = await store.classifyingQueue(classifier: classifier, clock: clock).run()

        #expect(classifier.count == 1)
        #expect(report.classificationSkipped == 1)
        #expect(report.saves == 2, "the renewal, then done")
        #expect(try store.row(id).stateRaw == "done")
    }

    /// A thrown `notReady` on a fresh own claim (not renewed by this run) waits until that claim's end, without a
    /// write.
    @Test func aThrownNotReadyOnAFreshClaimWaitsForThatClaim() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        try store.insertClassify(claimedAt: processingStart.addingTimeInterval(-hour))
        let classifier = StubClassifier { _ in throw ClassificationFailure.notReady }

        let report = await store.classifyingQueue(classifier: classifier, clock: clock).run()

        #expect(report.saves == 0)
        #expect(
            report.nextClaimEnd
                == processingStart.addingTimeInterval(ProcessingClaimRules.takeoverInterval - hour))
    }

    /// Review B N-1: a rate limit whose reset date has passed still pauses for the minimum, so the wake is never in
    /// the past and the next run does not ask again at once.
    @Test func aRateLimitWithAPastResetPausesForTheMinimum() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        try store.insertClassify()
        let classifier = StubClassifier { call in
            if call == 1 { throw ClassificationFailure.rateLimited(until: processingStart.addingTimeInterval(-60)) }
            return billSuggestion
        }
        let queue = store.classifyingQueue(classifier: classifier, clock: clock)

        let first = await queue.run()
        #expect(first.nextRetry == processingStart.addingTimeInterval(ClassificationLimits.minimumRateLimitPause))
        #expect(await queue.run().waiting == 1)
        #expect(classifier.count == 1, "asked again during the pause")
        clock.advance(by: ClassificationLimits.minimumRateLimitPause)
        #expect(await queue.run().classified == 1)
    }

    /// Review B N-2 (T5): the queue's default classification counter is the text counter's suite under its own key,
    /// so a classification failure never counts as a text failure.
    @Test func theDefaultClassificationCounterIsSeparateFromTheTextCounter() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        let failures = store.failures(deviceA)
        struct Broken: Error {}
        let queue = store.classifyingQueue(
            classifier: StubClassifier { _ in throw Broken() }, failures: failures, clock: clock)

        #expect(await queue.run().failures == 1)

        #expect(failures.count(for: id) == 0, "counted in the text counter")
        let classification = ProcessingFailures(
            defaultsSuite: failures.defaultsSuite, key: ProcessingFailures.classificationDefaultsKey)
        #expect(classification.count(for: id) == 1)
        #expect(ProcessingFailures.classificationDefaultsKey != ProcessingFailures.defaultsKey)
    }

    /// Review A N-a, B N-3: a text record swapped during the request drops the answer; nothing is written.
    @Test func aTextRecordSwappedDuringTheCallDropsTheAnswer() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        let call = Checkpoint()
        defer { call.release() }
        let queue = store.classifyingQueue(classifier: StubClassifier(checkpoint: call), clock: clock)

        let run = Task { await queue.run() }
        await call.reached()
        try store.swapText(of: id, to: "Ein ganz anderes Schreiben ohne Absender und ohne Datum, lang genug dafür.")
        call.release()
        let report = await run.value

        #expect(report.dropped == 1)
        #expect(report.saves == 0)
        let row = try store.classified(id)
        #expect(row.stateRaw == "classify")
        #expect(row.correspondent == nil)
    }

    /// Review B N-3: a cached answer belongs to its text record. After a swap, the next run asks the model again
    /// with the new text instead of writing the old answer.
    @Test func aCachedAnswerIsNotUsedForAnotherTextRecord() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        let edited = Mutex(false)
        let hooks = ProcessingQueue.Hooks(beforeCheck: { write in
            guard write == .classification, !edited.withLock({ $0 }) else { return }
            edited.withLock { $0 = true }
            try store.edit(id) { document, _ in document.isInbox = false }
        })
        let classifier = StubClassifier { call in
            call == 1 ? billSuggestion : ClassificationSuggestion(documentType: "Brief")
        }
        let queue = store.classifyingQueue(classifier: classifier, clock: clock, hooks: hooks)
        #expect(await queue.run().backedOff == 1, "the answer is cached")
        let other = "Ein ganz anderes Schreiben ohne Absender und ohne Datum, lang genug dafür."
        try store.swapText(of: id, to: other)

        let next = await queue.run()

        #expect(next.classified == 1)
        #expect(classifier.count == 2)
        #expect(classifier.requests.last?.text == other)
        let row = try store.classified(id)
        #expect(row.documentType == "Brief")
        #expect(row.correspondent == nil, "the old text's answer was written")
    }

    /// Review A N-b, B N-4: a decline whose `done` write meets another save is not asked again; the next run
    /// finishes the document from the cached decline.
    @Test func aDeclineIsNotAskedAgainAfterItsWriteMetAnotherSave() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        let edited = Mutex(false)
        let hooks = ProcessingQueue.Hooks(beforeCheck: { write in
            guard write == .classification, !edited.withLock({ $0 }) else { return }
            edited.withLock { $0 = true }
            try store.edit(id) { document, _ in document.isInbox = false }
        })
        let classifier = StubClassifier { _ in throw ClassificationFailure.declined(.refusal) }
        let queue = store.classifyingQueue(classifier: classifier, clock: clock, hooks: hooks)

        let first = await queue.run()
        #expect(first.backedOff == 1)
        #expect(first.declined == 0)
        let next = await queue.run()

        #expect(next.declined == 1)
        #expect(classifier.count == 1, "the decline was asked again")
        #expect(try store.classified(id).stateRaw == "done")
    }

    /// Review B N-5: what the queue keeps in memory for a document goes when the document leaves `classify` another
    /// way (here another save finishes it).
    @Test func theMemoryOfADocumentThatLeftClassifyIsDropped() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        let edited = Mutex(false)
        let hooks = ProcessingQueue.Hooks(beforeCheck: { write in
            guard write == .classification, !edited.withLock({ $0 }) else { return }
            edited.withLock { $0 = true }
            try store.edit(id) { document, _ in document.isInbox = false }
        })
        let queue = store.classifyingQueue(classifier: StubClassifier(), clock: clock, hooks: hooks)
        #expect(await queue.run().backedOff == 1)
        #expect(await queue.classificationMemory == [id])

        try store.edit(id) { document, _ in document.processingState = .done }
        _ = await queue.run()

        #expect(await queue.classificationMemory.isEmpty)
    }
}
