import DokumentumCore
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization

/// One subscriber of `SearchIndexer.updates()`: records every state and signals each element and each `.ready`,
/// so a test waits for the indexer's next element instead of for time.
@MainActor
final class StateRecorder {
    private(set) var states: [SearchIndexState] = []
    /// Fires once per element.
    let elements = TestSignal()
    /// Fires once per `.ready` element.
    let ready = TestSignal()
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<SearchIndexState>) {
        task = Task { @MainActor [weak self] in
            for await state in stream {
                guard let self else { return }
                self.states.append(state)
                self.elements.fire()
                if state == .ready { self.ready.fire() }
            }
        }
    }

    func cancel() { task?.cancel() }
}

/// Writes for the indexer's tests, each in a fresh context of its own and saved at once, as another part of the
/// app (an import, the processing queue's result write, an edit) would.
enum SearchStore {
    /// A document with a linked text, as the import creates it.
    @discardableResult
    static func insert(
        title: String, text: String = "", correspondent: String? = nil, tags: [String] = [],
        createdAt: Date = Date(), in container: ModelContainer
    ) throws -> UUID {
        let context = ModelContext(container)
        let document = Document(title: title, createdAt: createdAt)
        context.insert(document)
        if let correspondent {
            let record = Correspondent(name: correspondent)
            context.insert(record)
            document.correspondent = record
        }
        var parent: DokumentumCore.Tag?
        var linked: [DokumentumCore.Tag] = []
        for name in tags {
            let tag = DokumentumCore.Tag(name: name)
            context.insert(tag)
            tag.parent = parent
            parent = tag
            linked.append(tag)
        }
        document.tags = linked
        let row = DocumentText(documentID: document.id, extractedText: text)
        context.insert(row)
        document.text = row
        try context.save()
        return document.instanceID
    }

    static func document(_ instanceID: UUID, in context: ModelContext) throws -> Document {
        let documents = try context.fetch(
            FetchDescriptor<Document>(predicate: #Predicate { $0.instanceID == instanceID }))
        guard let document = documents.first else { throw Missing() }
        return document
    }

    /// Writes the text in place in one save, as the processing queue's result write does.
    static func setText(_ text: String, of instanceID: UUID, in container: ModelContainer) throws {
        let context = ModelContext(container)
        let document = try document(instanceID, in: context)
        guard let row = document.text else { throw Missing() }
        row.extractedText = text
        try context.save()
    }

    static func edit(_ instanceID: UUID, in container: ModelContainer, _ change: (Document) -> Void) throws {
        let context = ModelContext(container)
        change(try document(instanceID, in: context))
        try context.save()
    }

    struct Missing: Error {}
}

/// A history that fails with an error other than an expiry on every read of changes (N5).
final class FailingHistory: SearchHistoryReading {
    private let calls = Mutex(0)

    var changeReads: Int { calls.withLock { $0 } }

    func newestToken() throws -> DefaultHistoryToken? { nil }

    func changes(since token: DefaultHistoryToken?) throws -> (changes: [TextChange], newest: DefaultHistoryToken?) {
        calls.withLock { $0 += 1 }
        throw NSError(domain: "SearchIndexerTests", code: 7)
    }
}

/// A switch a hook reads: off until the test turns it on.
final class Armed: Sendable {
    private let value = Mutex(false)

    var isOn: Bool { value.withLock { $0 } }

    func turnOn() { value.withLock { $0 = true } }
}
