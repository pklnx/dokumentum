import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import DokumentumCore

/// A failed read of text rows does not lose the change with the history token (#132, N-c): the rows go into a
/// retry set and are read again with the next history read, a failing group is read again id by id, the build's
/// failed groups are read again in its step 4, and a failed read of relinked texts is retried the same way. The
/// reads fail through the `readTexts` and `readLinkedTexts` hooks.
@MainActor
struct SearchIndexerRetryTests {
    /// The text written while its read fails is found after the next event, which changes no text.
    @Test(arguments: SearchIndexerTests.Store.allCases)
    func aFailedTextReadIsReadAgainOnTheNextEvent(store: SearchIndexerTests.Store) async throws {
        let container = try SearchIndexerTests.container(store)
        let document = try SearchStore.insert(title: "Vertrag", text: "Erstfassung", in: container)
        let row = try FailingReads.textRow(of: document, in: container)
        let reads = FailingReads()
        let indexer = SearchIndexer(container: container, hooks: reads.textHooks())
        let recorder = StateRecorder(indexer.updates())
        defer {
            recorder.cancel()
            indexer.stop()
        }
        indexer.start()
        await recorder.ready.wait()

        reads.fail([row])
        try SearchStore.setText("Zweitfassung", of: document, in: container)
        await recorder.ready.wait(for: 2)
        #expect(await indexer.search("zweitfassung").matches == [])
        #expect(await indexer.search("erstfassung").matches == [document], "a failed read keeps what is indexed")

        reads.heal()
        try SearchStore.edit(document, in: container) { $0.title = "Vertrag neu" }
        await recorder.ready.wait(for: 3)
        #expect(await indexer.search("zweitfassung").matches == [document])
        #expect(await indexer.search("erstfassung").matches == [])
    }

    /// One row that keeps failing does not keep its group's other rows out: the failed group is read again id by
    /// id, and later events read only the failing row, once each.
    @Test func aFailingRowDoesNotHoldItsGroup() async throws {
        let container = try TestSupport.makeContainer()
        let anchor = try SearchStore.insert(title: "Anker", in: container)
        let buoy = try SearchStore.insert(title: "Boje", in: container)
        let anchorRow = try FailingReads.textRow(of: anchor, in: container)
        let buoyRow = try FailingReads.textRow(of: buoy, in: container)
        let reads = FailingReads()
        let indexer = SearchIndexer(container: container, hooks: reads.textHooks())
        let recorder = StateRecorder(indexer.updates())
        defer {
            recorder.cancel()
            indexer.stop()
        }
        indexer.start()
        await recorder.ready.wait()

        reads.fail([anchorRow])
        let readsBefore = reads.reads.count
        let writing = ModelContext(container)
        try SearchStore.document(anchor, in: writing).text?.extractedText = "Ankerkette"
        try SearchStore.document(buoy, in: writing).text?.extractedText = "Bojenleine"
        try writing.save()
        await recorder.ready.wait(for: 2)
        #expect(await indexer.search("bojenleine").matches == [buoy])
        #expect(await indexer.search("ankerkette").matches == [])
        let event = Array(reads.reads.dropFirst(readsBefore))
        #expect(Set(event.first ?? []) == [anchorRow, buoyRow], "\(event)")
        #expect(Set(event.dropFirst()) == [[anchorRow], [buoyRow]], "\(event)")

        let readsAfterFallback = reads.reads.count
        try SearchStore.edit(buoy, in: container) { $0.title = "Boje neu" }
        await recorder.ready.wait(for: 3)
        #expect(Array(reads.reads.dropFirst(readsAfterFallback)) == [[anchorRow]], "only the failing row, once")
        #expect(await indexer.search("ankerkette").matches == [])

        reads.heal()
        try SearchStore.edit(buoy, in: container) { $0.title = "Boje alt" }
        await recorder.ready.wait(for: 4)
        #expect(await indexer.search("ankerkette").matches == [anchor])
        #expect(await indexer.search("bojenleine").matches == [buoy])

        let readsAfterRetry = reads.reads.count
        try SearchStore.edit(buoy, in: container) { $0.title = "Boje" }
        await recorder.ready.wait(for: 5)
        #expect(Array(reads.reads.dropFirst(readsAfterRetry)) == [], "a row read once leaves the retry set")
    }

    /// A group whose read fails during the build is read again in the build's step 4.
    @Test func aFailedReadDuringTheBuildIsReadAgainBeforeReady() async throws {
        let container = try TestSupport.makeContainer()
        let document = try SearchStore.insert(title: "Akte", text: "Baustein", in: container)
        let row = try FailingReads.textRow(of: document, in: container)
        let reads = FailingReads()
        reads.fail([row])
        var hooks = reads.textHooks()
        hooks.afterBatch = { _ in reads.heal() }
        let indexer = SearchIndexer(container: container, hooks: hooks)
        let recorder = StateRecorder(indexer.updates())
        defer {
            recorder.cancel()
            indexer.stop()
        }
        indexer.start()
        await recorder.ready.wait()

        #expect(await indexer.search("baustein").matches == [document])
        #expect(reads.reads == [[row], [row]], "the batch's failed read, then step 4")
    }

    /// A document whose relinked text cannot be read is read again on the next event. The history here reports
    /// only the document's side of the link, so the relink read is the only way to the text.
    @Test func aFailedRelinkReadIsReadAgainOnTheNextEvent() async throws {
        let container = try TestSupport.makeContainer()
        let setup = ModelContext(container)
        let document = Document(title: "Spät")
        setup.insert(document)
        setup.insert(DocumentText(documentID: document.id, extractedText: "Frühankunft"))
        try setup.save()
        let documentRow = document.persistentModelID
        let reads = FailingReads()
        var hooks = SearchIndexer.Hooks()
        hooks.readLinkedTexts = { ids, context in
            try reads.check(ids)
            return try SearchStoreReader.linkedTexts(ofDocuments: ids, in: context)
        }
        let indexer = SearchIndexer(
            container: container, history: DocumentSideHistory(container: container), hooks: hooks)
        let recorder = StateRecorder(indexer.updates())
        defer {
            recorder.cancel()
            indexer.stop()
        }
        indexer.start()
        await recorder.ready.wait()

        reads.fail([documentRow])
        let linking = ModelContext(container)
        let text = try #require(try linking.fetch(FetchDescriptor<DocumentText>()).first)
        try SearchStore.document(document.instanceID, in: linking).text = text
        try linking.save()
        await recorder.ready.wait(for: 2)
        #expect(reads.reads.contains([documentRow]), "the link was not reported through the document")
        #expect(await indexer.search("fruhankunft").matches == [])

        reads.heal()
        try SearchStore.edit(document.instanceID, in: container) { $0.title = "Spät neu" }
        await recorder.ready.wait(for: 3)
        #expect(await indexer.search("fruhankunft").matches == [document.instanceID])
    }
}

/// Reads that fail while their identifiers include one of the failing ones; records the identifiers of every read.
final class FailingReads: Sendable {
    private struct State {
        var failing: Set<PersistentIdentifier> = []
        var reads: [[PersistentIdentifier]] = []
    }

    struct Failed: Error {}

    private let state = Mutex(State())

    var reads: [[PersistentIdentifier]] { state.withLock { $0.reads } }

    func fail(_ ids: Set<PersistentIdentifier>) { state.withLock { $0.failing = ids } }

    func heal() { state.withLock { $0.failing = [] } }

    func check(_ ids: [PersistentIdentifier]) throws {
        let fails = state.withLock { state in
            state.reads.append(ids)
            return !state.failing.isDisjoint(with: ids)
        }
        if fails { throw Failed() }
    }

    /// Hooks whose text-row reads go through `check`.
    func textHooks() -> SearchIndexer.Hooks {
        var hooks = SearchIndexer.Hooks()
        hooks.readTexts = { [self] ids, context in
            try check(ids)
            return try SearchStoreReader.texts(ids, in: context)
        }
        return hooks
    }

    static func textRow(of instanceID: UUID, in container: ModelContainer) throws -> PersistentIdentifier {
        let context = ModelContext(container)
        guard let row = try SearchStore.document(instanceID, in: context).text else { throw SearchStore.Missing() }
        return row.persistentModelID
    }
}

/// The store's history without the text rows' side of a change, so a link reaches the indexer only as a
/// `Document` update of `text`.
final class DocumentSideHistory: SearchHistoryReading {
    private let base: StoreSearchHistory

    init(container: ModelContainer) {
        base = StoreSearchHistory(container: container)
    }

    func newestToken() throws -> DefaultHistoryToken? { try base.newestToken() }

    func changes(since token: DefaultHistoryToken?) throws -> (changes: [TextChange], newest: DefaultHistoryToken?) {
        let (changes, newest) = try base.changes(since: token)
        return (changes.filter { if case .upsert = $0 { false } else { true } }, newest)
    }
}
