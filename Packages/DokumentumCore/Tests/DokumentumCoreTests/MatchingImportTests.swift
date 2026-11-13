import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import DokumentumCore

/// The rules in the text result write (plan of #10, §3, §4, §4a, N6): evaluated before the write on a snapshot of the
/// live rules, applied to the row the write fetched, the linked metadata rows in its check. The stage is a stub that
/// returns the bill's text.
struct MatchingImportTests {
    /// A document this device imported and claimed: its text write is the run's only write.
    private func insertPending(_ store: ProcessingStore) throws -> UUID {
        try store.insert(device: deviceA, claimedAt: processingStart)
    }

    @Test func aMatchingRuleSetsTheCorrespondentAndTypeAndAddsTagsWithoutTouching() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insertPending(store)
        let before = try store.matched(id)
        try store.insertRule(.correspondent, "Stadtwerke", .any, "Stadtwerke Telekom")
        try store.insertRule(.documentType, "Abrechnung", .exact, "Jahresabrechnung Strom")
        try store.insertRule(.tag, "Strom", .all, "Strom München")
        try store.insertRule(.tag, "Energie", .regex, "stadtwerke\\s+m(ü|ue)nchen")
        try store.insertRule(.tag, "Gas", .any, "Erdgas")
        try store.insertMetadata(.tag, "Ohne Regel")

        let report = await store.queue(deviceA, stage: textStage(), clock: clock).run()

        #expect(report.done == 1)
        #expect(report.rulesApplied == 1)
        #expect(report.saves == 1, "the rules are in the text write, no save of their own")
        let row = try store.matched(id)
        #expect(row.correspondent == "Stadtwerke")
        #expect(row.documentType == "Abrechnung")
        #expect(row.tags == ["Energie", "Strom"])
        #expect(row.modifiedAt == before.modifiedAt, "no touch()")
        #expect(try store.text(of: id).text == billText)
    }

    /// A correspondent the user set while the stage ran is kept, and the rule's tag is added to the user's tags
    /// (counter-proof: drop the emptiness check).
    @Test func aCorrespondentTheUserSetWhileTheStageRanIsKeptAndTheTagIsAdded() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insertPending(store)
        try store.insertRule(.correspondent, "Stadtwerke", .any, "Stadtwerke")
        try store.insertRule(.tag, "Strom", .any, "Strom")
        let bank = try store.insertMetadata(.correspondent, "Meine Bank")
        let mine = try store.insertMetadata(.tag, "Mein Tag")
        let running = Checkpoint()
        defer { running.release() }
        let stage = ClosureStage { _, progress in
            await running.pass()
            progress(1, 1)
            return ProcessingResult(pageCount: 1, text: ExtractedText(pages: [billText], source: .pdfText))
        }
        let queue = store.queue(deviceA, stage: stage, clock: clock)

        let run = Task { await queue.run() }
        await running.reached()
        try store.link(id, .correspondent, bank)
        try store.link(id, .tag, mine)
        running.release()
        let report = await run.value

        #expect(report.done == 1)
        #expect(report.rulesApplied == 1)
        let row = try store.matched(id)
        #expect(row.correspondent == "Meine Bank")
        #expect(row.tags == ["Mein Tag", "Strom"])
    }

    /// T10: a tombstone's rule is not applied, also when it is the only one that matches.
    @Test func aTombstonesRuleIsNotApplied() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insertPending(store)
        let keeper = try store.insertMetadata(.correspondent, "Stadtwerke")
        try store.insertRule(.correspondent, "Stadtwerke alt", .any, "Stadtwerke", mergedInto: keeper)
        let tagKeeper = try store.insertMetadata(.tag, "Strom")
        try store.insertRule(.tag, "Strom alt", .any, "Strom", mergedInto: tagKeeper)

        let report = await store.queue(deviceA, stage: textStage(), clock: clock).run()

        #expect(report.done == 1)
        #expect(report.rulesApplied == 0)
        let row = try store.matched(id)
        #expect(row.correspondent == nil)
        #expect(row.tags.isEmpty)
    }

    /// T8: an invalid regular expression (as sync can bring one) is skipped; the other rules apply.
    @Test func anInvalidRuleIsSkippedWhileTheOthersApply() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insertPending(store)
        try store.insertRule(.correspondent, "Kaputt", .regex, "(Stadtwerke")
        try store.insertRule(.tag, "Kaputt", .regex, "[z-a]")
        try store.insertRule(.tag, "Strom", .any, "Strom")

        let report = await store.queue(deviceA, stage: textStage(), clock: clock).run()

        #expect(report.done == 1)
        let row = try store.matched(id)
        #expect(row.correspondent == nil)
        #expect(row.tags == ["Strom"])
    }

    /// P2: two matching correspondents leave the field empty and are counted; the type still applies.
    @Test func twoMatchingCorrespondentsLeaveTheFieldEmpty() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insertPending(store)
        try store.insertRule(.correspondent, "Stadtwerke", .any, "Stadtwerke")
        try store.insertRule(.correspondent, "München", .any, "München")
        try store.insertRule(.documentType, "Abrechnung", .any, "Jahresabrechnung")

        let report = await store.queue(deviceA, stage: textStage(), clock: clock).run()

        #expect(report.rulesAmbiguous == 1)
        #expect(report.rulesApplied == 1)
        let row = try store.matched(id)
        #expect(row.correspondent == nil)
        #expect(row.documentType == "Abrechnung")
    }

    /// N6: a rule whose pattern alone is edited between the snapshot and the write is evaluated again in the write,
    /// on the fetched rules; the set of rule records is the same (counter-proofs: apply the snapshot's outcome
    /// without comparing; compare only the rules' ids; review A N1, review B N4 of #205).
    @Test(arguments: [false, true])
    func aRulePatternEditedBetweenTheSnapshotAndTheWriteIsEvaluatedAgain(toMatch: Bool) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insertPending(store)
        let correspondent = try store.insertRule(.correspondent, "Stadtwerke", .any, toMatch ? "Telekom" : "Stadtwerke")
        let tag = try store.insertRule(.tag, "Strom", .any, toMatch ? "Gas" : "Strom")
        let hooks = ProcessingQueue.Hooks(afterRules: {
            try? store.setRule(.correspondent, correspondent, .any, toMatch ? "Stadtwerke" : "Telekom")
            try? store.setRule(.tag, tag, .any, toMatch ? "Strom" : "Gas")
        })

        let report = await store.queue(deviceA, stage: textStage(), clock: clock, hooks: hooks).run()

        #expect(report.done == 1)
        let row = try store.matched(id)
        #expect(row.correspondent == (toMatch ? "Stadtwerke" : nil), "decided on the edited pattern")
        #expect(row.tags == (toMatch ? ["Strom"] : []))
    }

    /// N6: a rule removed between the snapshot and the write no longer applies.
    @Test func aRuleRemovedBetweenTheSnapshotAndTheWriteNoLongerApplies() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insertPending(store)
        let tag = try store.insertRule(.tag, "Strom", .any, "Strom")
        let hooks = ProcessingQueue.Hooks(afterRules: { try? store.setRule(.tag, tag, .none, "") })

        let report = await store.queue(deviceA, stage: textStage(), clock: clock, hooks: hooks).run()

        #expect(report.done == 1)
        #expect(try store.matched(id).tags.isEmpty)
    }

    /// Review A of #205, B1: copies of a rule record sharing an `instanceID` (a merge's loser and its live copy, or two
    /// live copies) never make the text write back off for ever: a record with copies is no rule and never linked, so
    /// the check never has to meet one of them (counter-proofs: the live copy first in keeper order, as before; the
    /// first copy read, which a fetch does not return in a stable order).
    @Test(arguments: [false, true])
    func aCopiedRuleRecordDoesNotKeepTheTextWriteFromLanding(tombstoneFirst: Bool) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try insertPending(store)
        try store.insertCopiedCorrespondent(tombstoneFirst: tombstoneFirst)
        let queue = store.queue(deviceA, stage: textStage(), clock: TestClock())

        let first = await queue.run()
        let second = await queue.run()

        #expect(first.done == 1)
        #expect(first.backedOff == 0)
        #expect(second.done == 0, "nothing left to do")
        #expect(try store.text(of: id).text == billText)
        #expect(try store.matched(id).correspondent == nil, "a record with copies is no rule")
    }

    /// §5: the rule's correspondent stays when the classifier suggests another, and the classifier still fills the
    /// title, because the rules never touch the document (counter-proof: `touch()` in the fill).
    @Test func theClassifierKeepsTheRulesCorrespondentAndFillsTheTitle() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(title: "Scan 2027-04-20", device: deviceA, claimedAt: processingStart)
        try store.insertRule(.correspondent, "Musterwerke", .any, "Stadtwerke")
        let classifier = StubClassifier()

        let report = await store.classifyingQueue(classifier: classifier, clock: clock).run()

        #expect(report.classified == 1)
        let row = try store.classified(id)
        #expect(row.correspondent == "Musterwerke")
        #expect(row.title == "Jahresabrechnung Strom")
        #expect(row.documentType == "Abrechnung")
    }

    // MARK: Windows (`Hooks.beforeCheck`)

    /// A user's correspondent saved in the write's window makes it back off; the next run keeps the edit and adds
    /// the rule's tag.
    @Test func aUserEditInTheWindowMakesTheWriteBackOff() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insertPending(store)
        try store.insertRule(.correspondent, "Stadtwerke", .any, "Stadtwerke")
        try store.insertRule(.tag, "Strom", .any, "Strom")
        let bank = try store.insertMetadata(.correspondent, "Meine Bank")
        let hooks = ProcessingQueue.Hooks(
            beforeCheck: once({ $0 == ProcessingQueue.Write.result }) { try store.link(id, .correspondent, bank) })
        let queue = store.queue(deviceA, stage: textStage(), clock: clock, hooks: hooks)

        let first = await queue.run()

        #expect(first.backedOff == 1)
        #expect(first.saves == 0)
        #expect(
            try store.matched(id)
                == MatchedRow(correspondent: "Meine Bank", documentType: nil, tags: [], modifiedAt: processingStart))

        let next = await queue.run()

        #expect(next.done == 1)
        #expect(try store.matched(id).correspondent == "Meine Bank")
        #expect(try store.matched(id).tags == ["Strom"])
    }

    /// A rule edit of the record the write links, saved in its window, makes it back off; the next run decides on
    /// the edited rule (counter-proof: leave the linked metadata rows out of the check). Asked by both reviews of #203.
    @Test func aRuleEditInTheWindowMakesTheWriteBackOff() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insertPending(store)
        let correspondent = try store.insertRule(.correspondent, "Stadtwerke", .any, "Stadtwerke")
        let hooks = ProcessingQueue.Hooks(
            beforeCheck: once({ $0 == ProcessingQueue.Write.result }) {
                try store.setRule(.correspondent, correspondent, .any, "Telekom")
            })
        let queue = store.queue(deviceA, stage: textStage(), clock: clock, hooks: hooks)

        let first = await queue.run()

        #expect(first.backedOff == 1)
        #expect(first.saves == 0)
        #expect(try store.matched(id).correspondent == nil)
        #expect(try store.text(of: id).text == "", "nothing of the write was saved")

        let next = await queue.run()

        #expect(next.done == 1)
        #expect(next.rulesApplied == 0)
        #expect(try store.matched(id).correspondent == nil, "the edited rule does not match")
    }
}
