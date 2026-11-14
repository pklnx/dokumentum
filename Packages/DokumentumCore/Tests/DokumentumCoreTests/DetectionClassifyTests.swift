import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import DokumentumCore

/// Detection on the `classify` path (#11, part 2; plan Approach 5; the maintainer's Q3: Apple Intelligence wins):
/// the text write fills nothing detected and stashes the sender on this device; both exits of the classification
/// step apply the classifier first, then fill what is still empty (the date recomputed from the text, the sender
/// from the stash, re-resolved). Stub classifier and stub stages; tests wait for reports.
struct DetectionClassifyTests {
    /// A document this device imported and claimed.
    private func insertPending(_ store: ProcessingStore) throws -> UUID {
        try store.insert(device: deviceA, claimedAt: processingStart)
    }

    /// The classifier's answer without a correspondent and a date.
    static let typeOnly = ClassificationSuggestion(documentType: "Abrechnung")
    /// The classifier's own correspondent and a date it may take: both occur in `answerText` (#8's checks), and
    /// neither is what detection finds there (the date has a cue, `Vertragsbeginn`).
    static let answerName = "Musterstadt Energie AG"
    static let answerText = stadtwerkeLetter.text + "\nIm Auftrag der Musterstadt Energie AG\nVertragsbeginn 14.01.2026"

    // MARK: The classifier wins (Q3)

    /// An answer with a correspondent and a date: detection fills nothing and creates no correspondent
    /// (counter-proof: fill in the text write when it sets `classify`).
    @Test func theClassifiersAnswerWins() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try insertPending(store)
        let classifier = StubClassifier { _ in
            ClassificationSuggestion(
                correspondent: Self.answerName, issueDate: SuggestedDate(day: 14, month: 1, year: 2026))
        }
        let queue = store.classifyingQueue(
            classifier: classifier, stage: LetterStage(stadtwerkeLetter, text: Self.answerText), clock: TestClock())

        let report = await queue.run()

        #expect(report.toClassify == 1)
        #expect(report.classified == 1)
        #expect(report.detectedCorrespondents == 0)
        #expect(report.detectedDates == 0)
        let row = try store.detected(id)
        #expect(row.correspondent == Self.answerName)
        #expect(row.documentDate == billDate)
        #expect(try store.correspondents() == [Self.answerName], "no detected correspondent created")
        #expect(queue.detectionStash.documents.isEmpty, "the entry went with the write")
    }

    /// An answer without a correspondent: the stash fills it, and a known record is linked through the hint.
    @Test func anAnswerWithoutACorrespondentTakesTheStashedOneThroughTheHint() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try insertPending(store)
        let known = try store.insertMetadata(.correspondent, "Stadtwerke Musterstadt")
        let classifier = StubClassifier { _ in Self.typeOnly }
        let queue = store.classifyingQueue(
            classifier: classifier, stage: LetterStage(stadtwerkeLetter), clock: TestClock())

        let report = await queue.run()

        #expect(report.classified == 1)
        #expect(report.detectedCorrespondents == 1)
        #expect(report.createdCorrespondents == 0)
        #expect(report.detectedDates == 1)
        let row = try store.detected(id)
        #expect(row.correspondentID == known)
        #expect(row.documentDate == letterDate)
        #expect(row.modifiedAt == processingStart, "no touch()")
        #expect(try store.classified(id).documentType == "Abrechnung", "the classifier's own fields too")
    }

    /// An answer without a date: the date recomputed from the text fills it; the classifier's correspondent stays.
    @Test func anAnswerWithoutADateTakesTheRecomputedDate() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try insertPending(store)
        let classifier = StubClassifier { _ in ClassificationSuggestion(correspondent: Self.answerName) }

        let report = await store.classifyingQueue(
            classifier: classifier, stage: LetterStage(stadtwerkeLetter, text: Self.answerText), clock: TestClock()
        ).run()

        #expect(report.detectedDates == 1)
        #expect(report.detectedCorrespondents == 0)
        let row = try store.detected(id)
        #expect(row.correspondent == Self.answerName)
        #expect(row.documentDate == letterDate)
    }

    /// The text write on the `classify` path fills nothing detected: the document waits for the model in
    /// `classify` with its fields empty, and the sender is in this device's stash.
    @Test func theTextWriteOnTheClassifyPathOnlyStashes() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try insertPending(store)
        let classifier = StubClassifier(availability: .notReady)
        let queue = store.classifyingQueue(
            classifier: classifier, stage: LetterStage(stadtwerkeLetter), clock: TestClock())

        let report = await queue.run()

        #expect(report.toClassify == 1)
        #expect(report.detectedCorrespondents == 0)
        #expect(report.detectedDates == 0)
        let row = try store.detected(id)
        #expect(row.stateRaw == "classify")
        #expect(row.correspondent == nil)
        #expect(row.documentDate == processingStart)
        #expect(try store.correspondents().isEmpty)
        let entry = try #require(queue.detectionStash.entry(for: id))
        #expect(entry.sender == .name(stadtwerkeName))
        let text = try ProcessingStore.fetch(id, in: ModelContext(store.container))?.text?.instanceID
        #expect(entry.text == text)
    }

    // MARK: Both exits

    /// Every exit without an answer still fills detection (counter-proof: skip detection in `finish`).
    @Test(arguments: ExitCase.allCases)
    func everyExitWithoutAnAnswerFillsDetection(case exit: ExitCase) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let failures = store.failures(deviceA)
        let counter = store.failures(deviceA)
        let id = try insertPending(store)
        struct Broken: Error {}
        let classifier = StubClassifier(availability: exit.startsNotReady ? .notReady : .available) { _ in
            switch exit {
            case .declined: throw ClassificationFailure.declined(.refusal)
            case .gaveUp: throw Broken()
            default: return billSuggestion
            }
        }
        let stage = LetterStage(stadtwerkeLetter, text: exit == .shortText ? "Datum: 13.11.2026" : nil)
        let queue = store.classifyingQueue(
            classifier: classifier, failures: failures, classificationFailures: counter, stage: stage, clock: clock)

        var report = await queue.run()
        switch exit {
        case .declined, .shortText:
            break
        case .switchOff:
            ClassificationSettings(defaultsSuite: failures.defaultsSuite).isEnabled = false
            report = await queue.run()
        case .unavailable:
            classifier.availability = .unavailable(.deviceNotEligible)
            report = await queue.run()
        case .notReadyAtTheClaimsEnd:
            clock.advance(by: ProcessingClaimRules.takeoverInterval + 1)
            report = await queue.run()
        case .gaveUp:
            clock.advance(by: 60)
            _ = await queue.run()
            clock.advance(by: 10 * 60)
            report = await queue.run()
        }

        #expect(report.done == 1, "\(exit)")
        #expect(report.detectedCorrespondents == 1)
        #expect(report.createdCorrespondents == 1)
        #expect(report.detectedDates == 1)
        let row = try store.detected(id)
        #expect(row.stateRaw == "done")
        #expect(row.correspondent == stadtwerkeName)
        #expect(row.documentDate == letterDate)
        #expect(row.modifiedAt == processingStart)
        #expect(queue.detectionStash.entry(for: id) == nil, "the entry went with the write")
    }

    enum ExitCase: String, CaseIterable, CustomTestStringConvertible {
        case declined, shortText, switchOff, unavailable, notReadyAtTheClaimsEnd, gaveUp
        var testDescription: String { rawValue }
        var startsNotReady: Bool { [.switchOff, .unavailable, .notReadyAtTheClaimsEnd].contains(self) }
    }

    // MARK: The stash: relaunch, takeover, a swapped text, N-r1

    /// A relaunch (a new queue on the same defaults) still finds the stash.
    @Test func aRelaunchStillUsesTheStash() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let failures = store.failures(deviceA)
        let id = try insertPending(store)
        let waiting = StubClassifier(availability: .notReady)
        _ = await store.classifyingQueue(
            classifier: waiting, failures: failures, stage: LetterStage(stadtwerkeLetter), clock: clock
        ).run()
        #expect(try store.detected(id).stateRaw == "classify")

        let relaunched = store.classifyingQueue(
            classifier: StubClassifier { _ in Self.typeOnly }, failures: failures, stage: LetterStage(finanzamtLetter),
            clock: clock)
        let report = await relaunched.run()

        #expect(report.classified == 1)
        #expect(try store.detected(id).correspondent == stadtwerkeName)
    }

    /// Another device takes the document over in `classify`: it has no stash, so it fills the date and not the
    /// sender, and logs `detection.noStash` (counter-proof: stash the date instead of recomputing it).
    @Test func anotherDeviceFillsTheDateOnly() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insertPending(store)
        _ = await store.classifyingQueue(
            classifier: StubClassifier(availability: .notReady), stage: LetterStage(stadtwerkeLetter), clock: clock
        ).run()
        #expect(try store.detected(id).stateRaw == "classify")

        clock.advance(by: ProcessingClaimRules.takeoverInterval + hour)
        let other = store.classifyingQueue(
            deviceB, classifier: StubClassifier { _ in Self.typeOnly }, stage: LetterStage(stadtwerkeLetter),
            clock: clock)
        let report = await other.run()

        #expect(report.classified == 1)
        #expect(report.detectedDates == 1)
        #expect(report.detectedCorrespondents == 0)
        let row = try store.detected(id)
        #expect(row.correspondent == nil)
        #expect(row.documentDate == letterDate)
        #expect(try store.correspondents().isEmpty)
    }

    /// A stash entry found with another text record is ignored: the date comes from the current text.
    @Test func aSwappedTextRecordIgnoresTheStash() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let failures = store.failures(deviceA)
        let id = try insertPending(store)
        let classifier = StubClassifier(availability: .notReady) { _ in Self.typeOnly }
        let queue = store.classifyingQueue(
            classifier: classifier, failures: failures, stage: LetterStage(stadtwerkeLetter), clock: clock)
        _ = await queue.run()
        #expect(queue.detectionStash.entry(for: id) != nil)

        try store.swapText(
            of: id, to: "Bescheid vom 02.11.2026 über die Grundsteuer der Gemeinde Musterstadt für das Jahr")
        classifier.availability = .available
        let report = await queue.run()

        #expect(report.classified == 1)
        #expect(report.detectedCorrespondents == 0)
        let row = try store.detected(id)
        #expect(row.correspondent == nil)
        #expect(
            row.documentDate
                == ClassificationFields.storedDate(
                    SuggestedDate(day: 2, month: 11, year: 2026), keepingTimeOf: processingStart,
                    calendar: testCalendar))
    }

    /// N-r1: a text write on the `classify` path that backed off left a stash entry; the next text write's other
    /// sender replaces it (counter-proof: write the stash only when no entry exists).
    @Test func theNextTextWriteReplacesAStashEntryOfAWriteThatBackedOff() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insertPending(store)
        // An edit that empties no field: the title only, without `touch()`.
        let hooks = editOnce(.result) { try store.edit(id) { document, _ in document.title = "Umbenannt" } }
        let classifier = StubClassifier { _ in Self.typeOnly }
        let queue = store.classifyingQueue(
            classifier: classifier, stage: LetterStage(stadtwerkeLetter, finanzamtLetter), clock: clock, hooks: hooks)

        let first = await queue.run()
        #expect(first.backedOff == 1)
        #expect(queue.detectionStash.entry(for: id)?.sender == .name(stadtwerkeName), "written before the save")

        clock.advance(by: 60)
        let next = await queue.run()

        #expect(next.classified == 1)
        #expect(try store.detected(id).correspondent == finanzamtName)
        #expect(try store.correspondents() == [finanzamtName])
    }

    /// A user's edit between the text write and the classification write: nothing detected is filled.
    @Test func aUsersEditBetweenTheWritesKeepsTheUsersValues() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let mine = try store.insertMetadata(.correspondent, "Meine Wahl")
        let id = try insertPending(store)
        let edited = processingStart.addingTimeInterval(30)
        let classifier = StubClassifier { _ in
            // The user edits while the model works.
            try store.edit(id) { document, context in
                document.correspondent = try context.fetch(
                    FetchDescriptor<Correspondent>(predicate: #Predicate { $0.instanceID == mine })
                ).first
                document.touch(edited)
            }
            return Self.typeOnly
        }

        let report = await store.classifyingQueue(
            classifier: classifier, stage: LetterStage(stadtwerkeLetter), clock: TestClock()
        ).run()

        #expect(report.classified == 1)
        #expect(report.detectedCorrespondents == 0)
        #expect(report.detectedDates == 0)
        let row = try store.detected(id)
        #expect(row.correspondentID == mine)
        #expect(row.documentDate == processingStart)
        #expect(try store.correspondents() == ["Meine Wahl"])
    }

    /// The hinted record renamed before the classification write: the name is resolved again (a new record, as
    /// the renamed one no longer has it), never the renamed record under its new name.
    @Test func aHintedCorrespondentRenamedMeanwhileIsResolvedByName() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insertPending(store)
        let known = try store.insertMetadata(.correspondent, "Stadtwerke Musterstadt")
        let classifier = StubClassifier(availability: .notReady) { _ in Self.typeOnly }
        let queue = store.classifyingQueue(classifier: classifier, stage: LetterStage(stadtwerkeLetter), clock: clock)
        _ = await queue.run()
        #expect(queue.detectionStash.entry(for: id)?.sender == .existing(id: known, name: "Stadtwerke Musterstadt"))

        try store.renameMetadata(.correspondent, known, to: "Gaswerke Musterstadt")
        classifier.availability = .available
        let report = await queue.run()

        #expect(report.createdCorrespondents == 1)
        let row = try store.detected(id)
        #expect(row.correspondent == "Stadtwerke Musterstadt")
        #expect(row.correspondentID != known)
    }

    /// Review A B1 of #209: the hinted record renamed by the user in the classification write's window. Detection's
    /// link is in that write's check (`fill.related` merged), so the write backs off and the rename stays; the next
    /// run resolves the name again (counter-proof: drop the merge, and the write saves over the rename).
    @Test func aHintedCorrespondentRenamedInTheClassificationWindowBacksOff() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insertPending(store)
        let known = try store.insertMetadata(.correspondent, "Stadtwerke Musterstadt")
        let hooks = editOnce(.classification) {
            try store.renameMetadata(.correspondent, known, to: "Gaswerke Musterstadt")
        }
        let queue = store.classifyingQueue(
            classifier: StubClassifier { _ in Self.typeOnly }, stage: LetterStage(stadtwerkeLetter), clock: clock,
            hooks: hooks)

        let first = await queue.run()

        #expect(first.backedOff == 1)
        #expect(first.classified == 0)
        #expect(try store.correspondentRecords().first { $0.id == known }?.name == "Gaswerke Musterstadt")
        #expect(try store.detected(id).correspondent == nil)

        clock.advance(by: 60)
        let second = await queue.run()

        #expect(second.classified == 1)
        #expect(try store.detected(id).correspondentID != known)
        #expect(try store.correspondentRecords().first { $0.id == known }?.name == "Gaswerke Musterstadt")
    }

    // MARK: Pruning

    /// The entry goes when the document is gone, with the failure counters.
    @Test func theStashIsPrunedWhenTheDocumentIsGone() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insertPending(store)
        let queue = store.classifyingQueue(
            classifier: StubClassifier(availability: .notReady), stage: LetterStage(stadtwerkeLetter), clock: clock)
        _ = await queue.run()
        #expect(queue.detectionStash.documents == [id])

        try store.delete(id)
        _ = await queue.run()

        #expect(queue.detectionStash.documents.isEmpty)
    }

    /// The entry goes when another device finished the document (`done`).
    @Test func theStashIsPrunedWhenTheDocumentIsDoneElsewhere() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insertPending(store)
        let queue = store.classifyingQueue(
            classifier: StubClassifier(availability: .notReady), stage: LetterStage(stadtwerkeLetter), clock: clock)
        _ = await queue.run()
        #expect(queue.detectionStash.documents == [id])

        try store.edit(id) { document, _ in document.processingState = .done }
        _ = await queue.run()

        #expect(queue.detectionStash.documents.isEmpty)
    }
}
