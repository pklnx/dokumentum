import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

// The classification tests' tools (#8, part 1): a stub classifier, documents waiting for classification with a
// text, and a queue with the stub. The model never runs in these tests.

/// A synthetic bill (the plan's P-b), long enough for the model (50 non-whitespace characters).
let billText = """
    Stadtwerke München GmbH · Emmy-Noether-Straße 2 · 80992 München
    Jahresabrechnung Strom 2025
    München, 14.01.2026
    Sehr geehrte Frau Muster, anbei erhalten Sie Ihre Jahresabrechnung für Strom.
    """

/// What the stub answers for the bill: every field.
let billSuggestion = ClassificationSuggestion(
    title: "Jahresabrechnung Strom", correspondent: "Stadtwerke München GmbH", documentType: "Abrechnung",
    tags: ["Strom"], issueDate: SuggestedDate(day: 14, month: 1, year: 2026))

/// A classifier that answers without a model: `answer(call)` for its `call`-th request (from 1). Counts its calls,
/// records the text and the known records it was asked with, and stops each call at `checkpoint` when set (it then
/// ignores its cancellation, like a framework call, until released).
final class StubClassifier: DocumentClassifying {
    private let state: Mutex<ClassifierAvailability>
    private let calls = Mutex<[(text: String, known: KnownMetadata)]>([])
    private let answer: @Sendable (Int) throws -> ClassificationSuggestion
    let checkpoint: Checkpoint?
    /// Fires when a call returns or throws.
    let answered = TestSignal()

    init(
        availability: ClassifierAvailability = .available, checkpoint: Checkpoint? = nil,
        answer: @escaping @Sendable (Int) throws -> ClassificationSuggestion = { _ in billSuggestion }
    ) {
        state = Mutex(availability)
        self.checkpoint = checkpoint
        self.answer = answer
    }

    var availability: ClassifierAvailability {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    var count: Int { calls.withLock { $0.count } }
    var requests: [(text: String, known: KnownMetadata)] { calls.withLock { $0 } }

    func classify(text: String, known: KnownMetadata) async throws -> ClassificationSuggestion {
        let call = calls.withLock {
            $0.append((text, known))
            return $0.count
        }
        defer { answered.fire() }
        if let checkpoint { await checkpoint.pass() }
        return try answer(call)
    }
}

/// A stage that returns `text` as the document's one page, without a PDF render.
func textStage(_ text: String = billText) -> ClosureStage {
    ClosureStage { _, progress in
        progress(1, 1)
        return ProcessingResult(pageCount: 1, text: ExtractedText(pages: [text], source: .pdfText))
    }
}

/// A document's classification fields, as the tests compare them.
struct ClassifiedRow: Equatable {
    var title: String
    var documentDate: Date
    var modifiedAt: Date
    var correspondent: String?
    var documentType: String?
    var tags: [String]
    var stateRaw: String
}

extension ProcessingStore {
    /// A queue with a classifier. The classification counter and settings default to the failure counter's suite.
    func classifyingQueue(
        _ device: String = deviceA, classifier: StubClassifier, failures: ProcessingFailures? = nil,
        classificationFailures: ProcessingFailures? = nil, stage: any ProcessingStage = textStage(),
        clock: TestClock, watchdog: ManualDebounce = ManualDebounce(), hooks: ProcessingQueue.Hooks = .init()
    ) -> ProcessingQueue {
        ProcessingQueue(
            container: container, deviceID: device, failures: failures ?? self.failures(device), stage: stage,
            classifier: classifier, classificationFailures: classificationFailures, calendar: testCalendar,
            matchingBudget: testMatchingBudget, watchdogSleep: watchdog.sleep, now: clock.function, hooks: hooks)
    }

    /// A document as the text step leaves it for classification: `classify`, `text` in its text record, claimed by
    /// `device` at `claimedAt`, never edited.
    @discardableResult
    func insertClassify(
        title: String = "Scan 2027-04-20", text: String = billText, created: Date = processingStart,
        device: String = deviceA, claimedAt: Date? = processingStart
    ) throws -> UUID {
        let id = try insert(
            title: title, created: created, stateRaw: "classify", device: device, claimedAt: claimedAt,
            textSource: .pdfText)
        try edit(id) { document, _ in document.text?.extractedText = text }
        return id
    }

    func classified(_ id: UUID) throws -> ClassifiedRow {
        let document = try #require(try Self.fetch(id, in: ModelContext(container)))
        return ClassifiedRow(
            title: document.title, documentDate: document.documentDate, modifiedAt: document.modifiedAt,
            correspondent: document.correspondent?.name, documentType: document.documentType?.name,
            tags: (document.tags ?? []).map(\.name).sorted(), stateRaw: document.processingStateRaw)
    }

    /// Inserts a live tag, correspondent or type (or a tombstone with `mergedInto`).
    @discardableResult
    func insertMetadata(_ kind: MetadataKind, _ name: String, mergedInto: UUID? = nil) throws -> UUID {
        let context = ModelContext(container)
        let id: UUID
        switch kind {
        case .tag:
            let record = DokumentumCore.Tag(name: name, createdAt: processingStart.addingTimeInterval(-hour))
            record.mergedIntoID = mergedInto
            context.insert(record)
            id = record.instanceID
        case .correspondent:
            let record = Correspondent(name: name, createdAt: processingStart.addingTimeInterval(-hour))
            record.mergedIntoID = mergedInto
            context.insert(record)
            id = record.instanceID
        case .documentType:
            let record = DocumentType(name: name, createdAt: processingStart.addingTimeInterval(-hour))
            record.mergedIntoID = mergedInto
            context.insert(record)
            id = record.instanceID
        }
        try context.save()
        return id
    }

    /// Renames a tag, correspondent or type in a context of its own: another save.
    func renameMetadata(_ kind: MetadataKind, _ id: UUID, to name: String) throws {
        let context = ModelContext(container)
        switch kind {
        case .tag:
            let record = try #require(
                try context.fetch(FetchDescriptor<DokumentumCore.Tag>(predicate: #Predicate { $0.instanceID == id }))
                    .first)
            record.name = name
        case .correspondent:
            let record = try #require(
                try context.fetch(FetchDescriptor<Correspondent>(predicate: #Predicate { $0.instanceID == id })).first)
            record.name = name
        case .documentType:
            let record = try #require(
                try context.fetch(FetchDescriptor<DocumentType>(predicate: #Predicate { $0.instanceID == id })).first)
            record.name = name
        }
        try context.save()
    }

    /// The stored name of a tag, correspondent or type.
    func metadataName(_ kind: MetadataKind, _ id: UUID) throws -> String? {
        let context = ModelContext(container)
        switch kind {
        case .tag:
            return try context.fetch(FetchDescriptor<DokumentumCore.Tag>(predicate: #Predicate { $0.instanceID == id }))
                .first?.name
        case .correspondent:
            return try context.fetch(FetchDescriptor<Correspondent>(predicate: #Predicate { $0.instanceID == id }))
                .first?.name
        case .documentType:
            return try context.fetch(FetchDescriptor<DocumentType>(predicate: #Predicate { $0.instanceID == id }))
                .first?.name
        }
    }

    /// Links a new text record to the document in another context (a swapped text record), with `text`.
    func swapText(of id: UUID, to text: String) throws {
        try edit(id) { document, context in
            let record = DocumentText(documentID: document.id, extractedText: text, createdAt: processingStart)
            context.insert(record)
            document.text = record
        }
    }

    func correspondents() throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<Correspondent>()).map(\.name).sorted()
    }

    func documentTypes() throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<DocumentType>()).map(\.name).sorted()
    }

    func tagCount() throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<DokumentumCore.Tag>())
    }
}

/// The calendar the tests store dates in.
let testCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
    return calendar
}()

/// The bill's date as the queue stores it for a document created at `processingStart`.
let billDate = ClassificationFields.storedDate(
    SuggestedDate(day: 14, month: 1, year: 2026), keepingTimeOf: processingStart, calendar: testCalendar)!
