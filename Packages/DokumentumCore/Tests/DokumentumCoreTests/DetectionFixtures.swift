import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

// The detection tests' tools (#11, part 2): stages that return a synthetic letter's text and layout, a queue that
// stores dates in the tests' calendar, and the values the letters give.

/// DIN 5008 form A with a return-address line: `Stadtwerke Musterstadt GmbH`, 13.11.2026, to `Max Mustermann`.
let stadtwerkeLetter = SyntheticLetters.letter("din-a-stadtwerke")!
/// The authority letter: `Finanzamt Musterstadt`, 13.11.2026, to `Max Mustermann`.
let finanzamtLetter = SyntheticLetters.letter("finanzamt")!
let stadtwerkeName = "Stadtwerke Musterstadt GmbH"
let finanzamtName = "Finanzamt Musterstadt"
let letterRecipient = "Max Mustermann"

/// 13.11.2026, the letters' date, as the queue stores it for a document created at `processingStart`.
let letterDate = ClassificationFields.storedDate(
    SuggestedDate(day: 13, month: 11, year: 2026), keepingTimeOf: processingStart, calendar: testCalendar)!

/// A stage that returns, for its `call`-th run (from 1), `letters[call - 1]` (the last one for later calls) as one
/// text page with its layout, as `DocumentStage` returns a text PDF; `text` replaces the letter's text when given.
final class LetterStage: ProcessingStage {
    private let calls = Mutex(0)
    let letters: [SyntheticLetter]
    let text: String?

    init(_ letters: SyntheticLetter..., text: String? = nil) {
        self.letters = letters
        self.text = text
    }

    var count: Int { calls.withLock { $0 } }

    func process(pdfData: Data, progress: @escaping ProcessingProgress) async throws -> ProcessingResult {
        let call = calls.withLock {
            $0 += 1
            return $0
        }
        let letter = letters[min(call, letters.count) - 1]
        progress(1, 1)
        return ProcessingResult(
            pageCount: 1, text: ExtractedText(pages: [text ?? letter.text], source: .pdfText),
            firstPageLayout: letter.layout)
    }
}

/// A document's detection fields, as the tests compare them.
struct DetectedRow: Equatable {
    var correspondent: String?
    var correspondentID: UUID?
    var documentDate: Date
    var modifiedAt: Date
    var stateRaw: String
}

extension ProcessingStore {
    /// A queue without a classifier (the `done` path) that stores dates in `testCalendar`.
    func detectingQueue(
        _ device: String = deviceA, failures: ProcessingFailures? = nil, stage: any ProcessingStage,
        clock: TestClock, hooks: ProcessingQueue.Hooks = .init()
    ) -> ProcessingQueue {
        ProcessingQueue(
            container: container, deviceID: device, failures: failures ?? self.failures(device), stage: stage,
            calendar: testCalendar, matchingBudget: testMatchingBudget, watchdogSleep: ManualDebounce().sleep,
            now: clock.function, hooks: hooks)
    }

    func detected(_ id: UUID) throws -> DetectedRow {
        let document = try #require(try Self.fetch(id, in: ModelContext(container)))
        return DetectedRow(
            correspondent: document.correspondent?.name, correspondentID: document.correspondent?.instanceID,
            documentDate: document.documentDate, modifiedAt: document.modifiedAt,
            stateRaw: document.processingStateRaw)
    }

    /// The live and merged correspondents' names, sorted.
    func correspondentRecords() throws -> [(name: String, id: UUID, isLive: Bool)] {
        try ModelContext(container).fetch(FetchDescriptor<Correspondent>()).map {
            ($0.name, $0.instanceID, $0.mergedIntoID == nil)
        }.sorted { $0.name < $1.name }
    }

    /// Deletes the document row: a document gone.
    func delete(_ id: UUID) throws {
        let context = ModelContext(container)
        for document in try context.fetch(FetchDescriptor<Document>(predicate: #Predicate { $0.instanceID == id })) {
            context.delete(document)
        }
        try context.save()
    }
}

/// A hook that runs `edit` once, in the first write of `kind`.
func editOnce(
    _ kind: ProcessingQueue.Write, _ edit: @escaping @Sendable () throws -> Void
) -> ProcessingQueue.Hooks {
    let done = Mutex(false)
    return ProcessingQueue.Hooks(beforeCheck: { write in
        guard write == kind, !done.withLock({ $0 }) else { return }
        done.withLock { $0 = true }
        try edit()
    })
}
