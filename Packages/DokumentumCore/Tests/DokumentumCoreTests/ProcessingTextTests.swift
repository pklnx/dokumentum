import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import DokumentumCore

/// The queue's result write with the text (#6, part 2): `extractedText`, `textSource`, `pageCount` and `done` in one
/// save, the check of the text row before it, and the UTF-8 cap. The stage uses a stub recogniser.
struct ProcessingTextTests {
    static let textLine = "Rechnung Nummer 2026-0042"

    @Test func theResultWriteSetsTheTextItsSourceThePageCountAndDoneInOneSave() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let scan = try store.insert(
            device: deviceA, claimedAt: clock.now, pdf: TestPDF.makeImageOnly(pages: [["a"], ["b"], ["c"]]))
        let born = try store.insert(
            title: "Born digital", device: deviceA, claimedAt: clock.now,
            pdf: TestPDF.make(contents: [.text(Self.textLine)]))

        let report = await store.queue(deviceA, clock: clock).run()

        #expect(report.done == 2)
        #expect(report.saves == 2, "own fresh claims: one result write each")
        #expect(try store.row(scan).stateRaw == "done")
        #expect(try store.row(scan).pageCount == 3)
        let scanText = try store.text(of: scan)
        #expect(scanText.source == .vision)
        #expect(scanText.text == "Recognised 1\u{0C}Recognised 2\u{0C}Recognised 3")
        let bornText = try store.text(of: born)
        #expect(bornText.source == .pdfText)
        #expect(bornText.text == Self.textLine)
        #expect(try store.row(born).pageCount == 1)
    }

    /// A blank scan is `.vision` with an empty text, never `.none` again.
    @Test func aBlankScanIsDoneWithAnEmptyTextFromVision() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceA, claimedAt: clock.now, pdf: TestPDF.make(contents: [.blank]))
        let stage = DocumentStage(recognizer: StubRecognizer { _ in [] })

        #expect(await store.queue(deviceA, stage: stage, clock: clock).run().done == 1)

        let text = try store.text(of: id)
        #expect(text.source == .vision)
        #expect(text.text == "")
    }

    /// An edit of the text row saved between the write's fetch and its check makes the write back off; the edit
    /// stays, and the next run completes the document.
    @Test func anEditOfTheTextRowInTheWindowBacksOffAndTheNextRunCompletes() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceA, claimedAt: clock.now)
        let edited = Mutex(false)
        let hooks = ProcessingQueue.Hooks(beforeCheck: { kind in
            guard kind == .result, !edited.withLock({ $0 }) else { return }
            edited.withLock { $0 = true }
            // Only the text row changes: the document row stays as the write read it.
            let context = ModelContext(store.container)
            let text = try #require(try ProcessingStore.fetch(id, in: context)?.text)
            text.extractedText = "Another writer"
            try context.save()
        })
        let stage = DocumentStage(recognizer: StubRecognizer { _ in ["Recognised"] })
        let queue = store.queue(deviceA, stage: stage, clock: clock, hooks: hooks)

        let first = await queue.run()

        #expect(first.backedOff == 1)
        #expect(first.saves == 0)
        #expect(try store.text(of: id).text == "Another writer")
        #expect(try store.text(of: id).source == TextSource.none)
        #expect(try store.row(id).stateRaw == "pending")

        let next = await queue.run()
        #expect(next.done == 1)
        #expect(try store.text(of: id).text == "Recognised\u{0C}Recognised")
        #expect(try store.text(of: id).source == .vision)
    }

    /// T7, N6: a text over 500,000 UTF-8 bytes is stored cut at the last page boundary below it, and counted.
    @Test func aTextOverTheCapIsStoredCutAtAPageBoundary() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceA, claimedAt: clock.now, pages: 3)
        let page = String(repeating: "ä", count: 100_000)  // 200,000 bytes
        let stage = DocumentStage(recognizer: StubRecognizer { _ in [page] })

        let report = await store.queue(deviceA, stage: stage, clock: clock).run()

        #expect(report.done == 1)
        #expect(report.textsCapped == 1)
        let stored = try #require(try store.text(of: id).text)
        #expect(stored == page + "\u{0C}" + page)
        #expect(stored.utf8.count <= ExtractedText.byteLimit)
    }

    /// A stage without text (a test's) leaves the text record and `textSource` alone.
    @Test func aResultWithoutTextLeavesTheTextAlone() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceA, claimedAt: clock.now)
        let stage = ClosureStage { _, progress in
            progress(1, 1)
            return ProcessingResult(pageCount: 2)
        }

        #expect(await store.queue(deviceA, stage: stage, clock: clock).run().done == 1)

        #expect(try store.text(of: id).source == TextSource.none)
        #expect(try store.text(of: id).text == "")
    }
}
