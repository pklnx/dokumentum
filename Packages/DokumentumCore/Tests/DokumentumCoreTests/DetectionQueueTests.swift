import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import DokumentumCore

/// Detection in the text result write, the `done` path (#11, part 2; plan Approach 4, Tests part 2): no classifier,
/// so detection fills the empty correspondent and date in the text write itself, never over a user's value or a
/// rule's, never with `touch()`, and its check backs off on an edit in the window. Stub stages return a letter's
/// text and layout; one case runs the real stage on a rendered letter.
struct DetectionQueueTests {
    private func insertPending(_ store: ProcessingStore) throws -> UUID {
        try store.insert(device: deviceA, claimedAt: processingStart)
    }

    @Test func theTextWriteFillsAnEmptyCorrespondentAndDateWithoutTouching() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try insertPending(store)
        try store.insertMetadata(.correspondent, letterRecipient)

        let report = await store.detectingQueue(stage: LetterStage(stadtwerkeLetter), clock: TestClock()).run()

        #expect(report.done == 1)
        #expect(report.saves == 1, "in the text write, no save of its own")
        #expect(report.detectedCorrespondents == 1)
        #expect(report.createdCorrespondents == 1)
        #expect(report.detectedDates == 1)
        let row = try store.detected(id)
        #expect(row.correspondent == stadtwerkeName)
        #expect(row.documentDate == letterDate)
        #expect(row.modifiedAt == processingStart, "no touch()")
        #expect(row.stateRaw == "done")
        #expect(try store.correspondents() == [letterRecipient, stadtwerkeName], "never the recipient")
    }

    /// End to end: the real stage reads a rendered text PDF, its layout and text give the sender and the date.
    @Test func theRealStageOnARenderedLetterFillsBoth() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insert(
            device: deviceA, claimedAt: processingStart, pdf: TestLetter.textPDF(finanzamtLetter))
        try store.insertMetadata(.correspondent, letterRecipient)

        let report = await store.detectingQueue(
            stage: DocumentStage(recognizer: StubRecognizer()), clock: TestClock()
        ).run()

        #expect(report.done == 1)
        let row = try store.detected(id)
        #expect(row.correspondent == finanzamtName)
        #expect(row.documentDate == letterDate)
    }

    /// A correspondent the user set before the write is kept; the date is still filled (counter-proof: drop the
    /// correspondent's emptiness check).
    @Test func aCorrespondentTheUserSetIsKept() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try insertPending(store)
        let mine = try store.insertMetadata(.correspondent, "Meine Wahl")
        try store.edit(id) { document, context in
            document.correspondent = try context.fetch(
                FetchDescriptor<Correspondent>(predicate: #Predicate { $0.instanceID == mine })
            ).first
        }

        let report = await store.detectingQueue(stage: LetterStage(stadtwerkeLetter), clock: TestClock()).run()

        #expect(report.detectedCorrespondents == 0)
        #expect(report.detectedDates == 1)
        let row = try store.detected(id)
        #expect(row.correspondent == "Meine Wahl")
        #expect(row.documentDate == letterDate)
        #expect(try store.correspondents() == ["Meine Wahl"], "nothing created")
    }

    /// After any edit the date counts as the user's (#8's rule): it is kept, the correspondent is still filled.
    @Test func aDateAfterAnyEditIsKept() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try insertPending(store)
        let edited = processingStart.addingTimeInterval(60)
        try store.edit(id) { document, _ in document.touch(edited) }

        let report = await store.detectingQueue(stage: LetterStage(stadtwerkeLetter), clock: TestClock()).run()

        #expect(report.detectedDates == 0)
        let row = try store.detected(id)
        #expect(row.documentDate == processingStart)
        #expect(row.modifiedAt == edited)
        #expect(row.correspondent == stadtwerkeName)
    }

    /// An edit saved in the write's window makes it back off; the next run decides again on the edited row.
    @Test func anEditInTheWindowBacksOffAndTheNextRunDecidesAgain() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insertPending(store)
        let edited = processingStart.addingTimeInterval(5)
        let hooks = editOnce(.result) {
            try store.edit(id) { document, _ in
                document.title = "Mein Titel"
                document.touch(edited)
            }
        }
        let queue = store.detectingQueue(stage: LetterStage(stadtwerkeLetter), clock: clock, hooks: hooks)

        let first = await queue.run()

        #expect(first.backedOff == 1)
        #expect(first.detectedCorrespondents == 0)
        #expect(try store.detected(id).correspondent == nil, "nothing written")
        #expect(try store.correspondents().isEmpty, "the new correspondent was rolled back")

        clock.advance(by: 60)
        let next = await queue.run()

        #expect(next.done == 1)
        let row = try store.detected(id)
        #expect(row.correspondent == stadtwerkeName)
        #expect(row.documentDate == processingStart, "edited meanwhile: the date is the user's")
        #expect(row.modifiedAt == edited)
    }

    /// A linked correspondent renamed in the window makes the write back off: its row is in the check
    /// (counter-proof: link without adding the related row).
    @Test func aLinkedCorrespondentRenamedInTheWindowBacksTheWriteOff() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insertPending(store)
        let known = try store.insertMetadata(.correspondent, "Stadtwerke Musterstadt")
        let hooks = editOnce(.result) { try store.renameMetadata(.correspondent, known, to: "Stadtwerke Alt") }
        let queue = store.detectingQueue(stage: LetterStage(stadtwerkeLetter), clock: clock, hooks: hooks)

        let first = await queue.run()

        #expect(first.backedOff == 1)
        #expect(try store.detected(id).correspondent == nil)

        clock.advance(by: 60)
        let next = await queue.run()

        #expect(next.done == 1)
        // `Stadtwerke Alt` is not on the letter: the return-address line's name, resolved by word prefix to none.
        #expect(try store.detected(id).correspondent == stadtwerkeName)
    }

    /// A known correspondent on the letter is linked, not created again.
    @Test func aKnownCorrespondentIsLinked() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try insertPending(store)
        let known = try store.insertMetadata(.correspondent, "Stadtwerke Musterstadt")

        let report = await store.detectingQueue(stage: LetterStage(stadtwerkeLetter), clock: TestClock()).run()

        #expect(report.detectedCorrespondents == 1)
        #expect(report.createdCorrespondents == 0)
        #expect(try store.detected(id).correspondentID == known)
        #expect(try store.correspondents() == ["Stadtwerke Musterstadt"])
    }

    /// Two documents of one new sender in one run share one new correspondent: the second write fetches the first's.
    @Test func aNewSenderIsCreatedOnceForTwoDocuments() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let first = try insertPending(store)
        let second = try store.insert(
            created: processingStart.addingTimeInterval(1), device: deviceA, claimedAt: processingStart)

        let report = await store.detectingQueue(stage: LetterStage(stadtwerkeLetter), clock: TestClock()).run()

        #expect(report.done == 2)
        #expect(report.detectedCorrespondents == 2)
        #expect(report.createdCorrespondents == 1)
        #expect(try store.correspondents() == [stadtwerkeName])
        #expect(try store.detected(first).correspondentID == store.detected(second).correspondentID)
    }

    /// A tombstone is never linked: a new live record is created instead.
    @Test func aTombstoneIsNeverLinked() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try insertPending(store)
        let keeper = try store.insertMetadata(.correspondent, "Ganz Andere AG")
        let tombstone = try store.insertMetadata(.correspondent, stadtwerkeName, mergedInto: keeper)

        let report = await store.detectingQueue(stage: LetterStage(stadtwerkeLetter), clock: TestClock()).run()

        #expect(report.createdCorrespondents == 1)
        let row = try store.detected(id)
        #expect(row.correspondent == stadtwerkeName)
        #expect(row.correspondentID != tombstone)
        #expect(row.correspondentID != keeper)
    }

    /// A re-run (Try again after a failure) changes nothing detected: both fields are no longer empty, so the fill
    /// neither detects nor links (N6).
    @Test func aReRunChangesNothing() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insertPending(store)
        let queue = store.detectingQueue(stage: LetterStage(stadtwerkeLetter, finanzamtLetter), clock: clock)
        #expect(await queue.run().detectedCorrespondents == 1)
        let filled = try store.detected(id)
        try store.edit(id) { document, _ in document.processingState = .failed }

        #expect(await queue.retry(id) == .queued)
        let again = await queue.run()

        #expect(again.done == 1)
        #expect(again.detectedCorrespondents == 0)
        #expect(again.detectedDates == 0)
        let row = try store.detected(id)
        #expect(row.correspondent == filled.correspondent, "the second letter's sender is not taken")
        #expect(row.documentDate == filled.documentDate)
        #expect(try store.correspondents() == [stadtwerkeName])
    }

    /// A rule's correspondent is kept (rules first, #10); an ambiguous rule match leaves the field to detection.
    @Test func aRulesCorrespondentIsKeptAndAnAmbiguousOneLeavesTheFieldToDetection() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let ruled = try insertPending(store)
        try store.insertRule(.correspondent, "Regel GmbH", .any, "Jahresabrechnung")

        let report = await store.detectingQueue(stage: LetterStage(stadtwerkeLetter), clock: TestClock()).run()

        #expect(report.rulesApplied == 1)
        #expect(report.detectedCorrespondents == 0)
        #expect(try store.detected(ruled).correspondent == "Regel GmbH")
        #expect(try store.detected(ruled).documentDate == letterDate, "the date is not a rule's")

        let ambiguous = try store.insert(
            created: processingStart.addingTimeInterval(1), device: deviceA, claimedAt: processingStart)
        try store.insertRule(.correspondent, "Zweite Regel GmbH", .any, "Jahresabrechnung")
        let next = await store.detectingQueue(stage: LetterStage(stadtwerkeLetter), clock: TestClock()).run()

        #expect(next.rulesAmbiguous == 1)
        #expect(next.detectedCorrespondents == 1)
        #expect(try store.detected(ambiguous).correspondent == stadtwerkeName)
    }

    /// Without a layout (a stage that gives none) only the date is detected, and no metadata is needed.
    @Test func withoutALayoutOnlyTheDateIsFilled() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try insertPending(store)

        let report = await store.detectingQueue(stage: textStage(stadtwerkeLetter.text), clock: TestClock()).run()

        #expect(report.detectedDates == 1)
        #expect(report.detectedCorrespondents == 0)
        #expect(try store.detected(id).correspondent == nil)
        #expect(try store.detected(id).documentDate == letterDate)
    }
}
