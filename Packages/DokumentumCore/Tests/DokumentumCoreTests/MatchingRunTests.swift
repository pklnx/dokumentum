import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import DokumentumCore

/// "Apply Matching Rules" (plan of #10, §6, T6; P3): which documents it looks at, what it writes, idempotence, the
/// batch's fallback to single writes, cancellation between batches and its report.
struct MatchingRunTests {
    static let text = "Stadtwerke München: Ihre Jahresabrechnung Strom"

    /// Review N7: every document outside the trash with non-empty text, in any state but `unknown`.
    @Test func itAppliesToEveryStateWithTextAndSkipsUnknownTrashedAndTextless() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        try store.insertRule(.tag, "Strom", .any, "Strom")
        var applies: [UUID] = []
        for state in ["done", "classify", "pending", "processing", "failed"] {
            applies.append(try store.insertWithText(Self.text, stateRaw: state))
        }
        let unknown = try store.insertWithText(Self.text, stateRaw: "archived-by-a-newer-build")
        let trashed = try store.insertWithText(Self.text, trashed: true)
        let empty = try store.insertWithText("")
        let noText = try store.insert(stateRaw: "done", text: false)

        let report = try #require(await store.matchingRun().run())

        #expect(report.documents == 5)
        #expect(report.changed == 5)
        #expect(report.saves == 1, "one batch")
        for id in applies { #expect(try store.matched(id).tags == ["Strom"]) }
        for id in [unknown, trashed, empty, noText] { #expect(try store.matched(id).tags.isEmpty) }
        #expect(try store.row(applies[2]).stateRaw == "pending", "the run never writes the state")
    }

    /// T4: an empty correspondent and type are filled, set ones kept, tags added, nothing touched.
    @Test func itFillsOnlyEmptyFieldsAndAddsTags() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        try store.insertRule(.correspondent, "Stadtwerke", .any, "Stadtwerke")
        try store.insertRule(.documentType, "Abrechnung", .any, "Jahresabrechnung")
        try store.insertRule(.tag, "Strom", .any, "Strom")
        let bank = try store.insertMetadata(.correspondent, "Meine Bank")
        let mine = try store.insertMetadata(.tag, "Mein Tag")
        let empty = try store.insertWithText(Self.text)
        let set = try store.insertWithText(Self.text)
        try store.link(set, .correspondent, bank)
        try store.link(set, .tag, mine)

        let report = try #require(await store.matchingRun().run())

        #expect(report.changed == 2)
        #expect(
            try store.matched(empty)
                == MatchedRow(
                    correspondent: "Stadtwerke", documentType: "Abrechnung", tags: ["Strom"],
                    modifiedAt: processingStart))
        #expect(
            try store.matched(set)
                == MatchedRow(
                    correspondent: "Meine Bank", documentType: "Abrechnung", tags: ["Mein Tag", "Strom"],
                    modifiedAt: processingStart))
    }

    /// A second run changes nothing and saves nothing (counter-proof: save even without a change).
    @Test func aSecondRunChangesAndSavesNothing() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        try store.insertRule(.correspondent, "Stadtwerke", .any, "Stadtwerke")
        try store.insertRule(.tag, "Strom", .any, "Strom")
        for _ in 0..<3 { try store.insertWithText(Self.text) }
        let first = try #require(await store.matchingRun(batchSize: 2).run())
        #expect(first.changed == 3)
        #expect(first.saves == 2)

        let saves = SaveCounter(store.container)
        let second = try #require(await store.matchingRun(batchSize: 2).run())

        #expect(second.documents == 3)
        #expect(second.changed == 0)
        #expect(second.saves == 0)
        #expect(saves.count == 0)
    }

    /// An edit saved in a batch's window makes the batch roll back; its documents are written one by one, the edit
    /// stays and the others are saved (counter-proof: drop the fallback). A document whose own write meets another
    /// save again is skipped and counted.
    @Test(arguments: [false, true])
    func aBatchThatMeetsAnEditFallsBackToSingleWrites(editAgain: Bool) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        try store.insertRule(.correspondent, "Stadtwerke", .any, "Stadtwerke")
        try store.insertRule(.tag, "Strom", .any, "Strom")
        let bank = try store.insertMetadata(.correspondent, "Meine Bank")
        let ids = try (0..<3).map { _ in try store.insertWithText(Self.text) }
        let edited = ids[1]
        let edits = Mutex(0)
        let hooks = MatchingRun.Hooks(beforeCheck: { write in
            let count = edits.withLock { count in
                count += 1
                return count
            }
            switch write {
            case .batch where count == 1:
                try store.link(edited, .correspondent, bank)
            case .single where editAgain:
                try store.edit(edited) { document, _ in document.title = "Edited \(count)" }
            default:
                break
            }
        })

        let report = try #require(await store.matchingRun(hooks: hooks).run())

        #expect(try store.matched(edited).correspondent == "Meine Bank", "the edit stays")
        for id in ids where id != edited {
            #expect(
                try store.matched(id)
                    == MatchedRow(
                        correspondent: "Stadtwerke", documentType: nil, tags: ["Strom"], modifiedAt: processingStart))
        }
        if editAgain {
            #expect(report.changed == 2)
            #expect(report.skipped == 1)
            #expect(try store.matched(edited).tags.isEmpty, "skipped: nothing written")
        } else {
            #expect(report.changed == 3)
            #expect(report.skipped == 0)
            #expect(try store.matched(edited).tags == ["Strom"])
        }
        #expect(report.saves == report.changed, "single writes after the rollback")
    }

    /// A cancel between batches leaves the earlier batches saved and the later ones untouched.
    @Test func aCancelBetweenBatchesKeepsTheEarlierBatches() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        try store.insertRule(.tag, "Strom", .any, "Strom")
        let ids = try (0..<3).map { _ in try store.insertWithText(Self.text) }.sorted { $0.uuidString < $1.uuidString }
        let firstBatch = Checkpoint()
        defer { firstBatch.release() }
        let hooks = MatchingRun.Hooks(afterBatch: { done in
            if done == 1 { await firstBatch.pass() }
        })
        let matching = store.matchingRun(batchSize: 1, hooks: hooks)

        let run = Task { await matching.run() }
        await firstBatch.reached()
        run.cancel()
        firstBatch.release()
        let report = try #require(await run.value)

        #expect(report.cancelled)
        #expect(report.changed == 1)
        #expect(try store.matched(ids[0]).tags == ["Strom"])
        #expect(try store.matched(ids[1]).tags.isEmpty)
        #expect(try store.matched(ids[2]).tags.isEmpty)
    }

    /// One run at a time per instance: a second call while one runs returns `nil`.
    @Test func aSecondRunWhileOneRunsIsRefused() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        try store.insertRule(.tag, "Strom", .any, "Strom")
        try store.insertWithText(Self.text)
        let batch = Checkpoint()
        defer { batch.release() }
        // Only the first batch stops: a second run that is not refused then finishes and fails the test, never hangs.
        let stopped = Mutex(false)
        let matching = store.matchingRun(
            hooks: MatchingRun.Hooks(afterBatch: { _ in
                let first = stopped.withLock { stopped in
                    defer { stopped = true }
                    return !stopped
                }
                if first { await batch.pass() }
            }))

        let run = Task { await matching.run() }
        await batch.reached()
        let second = await matching.run()
        batch.release()
        let first = await run.value

        #expect(second == nil)
        #expect(first?.changed == 1)
    }

    /// Invalid and slow rules are reported by name and skipped; a document left without a correspondent because
    /// two matched is counted. The callback budget keeps the slow case bounded without a clock.
    @Test func invalidSlowAndAmbiguousCasesAreReported() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        try store.insertRule(.tag, "Kaputt", .regex, "(abc")
        try store.insertRule(.tag, "Langsam", .regex, "(a+)+$")
        try store.insertRule(.tag, "Strom", .any, "Strom")
        try store.insertRule(.correspondent, "Stadtwerke", .any, "Stadtwerke")
        try store.insertRule(.correspondent, "München", .any, "München")
        let slowText = Self.text + " " + String(repeating: "a", count: 26) + "!"
        let ids = try (0..<2).map { _ in try store.insertWithText(slowText) }

        let report = try #require(await store.matchingRun(budget: .progressCallbacks(1_000)).run())

        #expect(report.invalidRules == ["Kaputt"])
        #expect(report.slowRules == ["Langsam"])
        #expect(report.ambiguous == 2)
        #expect(report.changed == 2)
        for id in ids {
            #expect(try store.matched(id).tags == ["Strom"])
            #expect(try store.matched(id).correspondent == nil)
        }
    }
}
