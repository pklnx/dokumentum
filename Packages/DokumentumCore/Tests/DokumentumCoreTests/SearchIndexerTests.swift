import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// The search indexer (plan of #7, part 2): the build at launch, updates from local saves through the persistent
/// history and the metadata re-read, the per-subscriber updates, and the history-error rule. Every test waits for
/// the indexer's own `updates()` elements.
@MainActor
struct SearchIndexerTests {
    enum Store: CaseIterable {
        case inMemory, onDisk
    }

    static func container(_ store: Store) throws -> ModelContainer {
        switch store {
        case .inMemory: try TestSupport.makeContainer()
        case .onDisk: try TestSupport.makeContainerOnDisk()
        }
    }

    // MARK: Build

    @Test(arguments: Store.allCases)
    func theBuildFindsTextsAndMetadata(store: Store) async throws {
        let container = try Self.container(store)
        let invoice = try SearchStore.insert(
            title: "Rechnung Strom", text: "Ihr Grundsteuerbescheid für 2024", correspondent: "Stadtwerke",
            tags: ["Haus", "Nebenkosten"], in: container)
        let other = try SearchStore.insert(title: "Brief", text: "Sehr geehrte Damen", in: container)
        let indexer = SearchIndexer(container: container)
        let recorder = StateRecorder(indexer.updates())
        defer {
            recorder.cancel()
            indexer.stop()
        }
        indexer.start()
        await recorder.ready.wait()

        #expect(await indexer.search("bescheid").matches == [invoice])
        #expect(await indexer.search("stadtwerke").matches == [invoice])
        #expect(await indexer.search("nebenkosten").matches == [invoice])
        #expect(await indexer.search("haus nebenkosten").matches == [invoice])
        #expect(await indexer.search("damen").matches == [other])
        #expect(await indexer.search("rechnung damen").matches == [])
        #expect(await indexer.state == .ready)
        #expect(recorder.states.last == .ready)
    }

    // MARK: Updates

    /// A text written in place by another context (the processing queue's result write) is found after the next
    /// element.
    @Test(arguments: Store.allCases)
    func aTextWrittenLaterInAnotherContextIsFound(store: Store) async throws {
        let container = try Self.container(store)
        let document = try SearchStore.insert(title: "Scan", in: container)
        let indexer = SearchIndexer(container: container)
        let recorder = StateRecorder(indexer.updates())
        defer {
            recorder.cancel()
            indexer.stop()
        }
        indexer.start()
        await recorder.ready.wait()
        #expect(await indexer.search("zahnarzt").matches == [])

        try SearchStore.setText("Zahnarztrechnung\u{000C}Seite zwei", of: document, in: container)
        await recorder.ready.wait(for: 2)
        #expect(await indexer.search("zahnarzt").matches == [document])
        #expect(await indexer.search("zwei").matches == [document])
    }

    /// Metadata changes are picked up by the re-read, without history: a title edit, a tag rename, a trash move
    /// (still found, trashed documents are indexed) and a delete.
    @Test func metadataChangesArePickedUp() async throws {
        let container = try TestSupport.makeContainer()
        let document = try SearchStore.insert(title: "Altbau", text: "Mietvertrag", tags: ["Wohnung"], in: container)
        let indexer = SearchIndexer(container: container)
        let recorder = StateRecorder(indexer.updates())
        defer {
            recorder.cancel()
            indexer.stop()
        }
        indexer.start()
        await recorder.ready.wait()
        #expect(await indexer.search("wohnung").matches == [document])

        try SearchStore.edit(document, in: container) { $0.title = "Neubau" }
        await recorder.ready.wait(for: 2)
        #expect(await indexer.search("neubau").matches == [document])
        #expect(await indexer.search("altbau").matches == [])

        let context = ModelContext(container)
        let tag = try #require(try context.fetch(FetchDescriptor<DokumentumCore.Tag>()).first)
        tag.name = "Immobilie"
        try context.save()
        await recorder.ready.wait(for: 3)
        #expect(await indexer.search("immobilie").matches == [document])
        #expect(await indexer.search("wohnung").matches == [])

        try SearchStore.edit(document, in: container) { $0.deletedAt = Date() }
        await recorder.ready.wait(for: 4)
        #expect(await indexer.search("mietvertrag").matches == [document])

        let deleting = ModelContext(container)
        deleting.delete(try SearchStore.document(document, in: deleting))
        try deleting.save()
        await recorder.ready.wait(for: 5)
        #expect(await indexer.search("mietvertrag").matches == [])
        #expect(await indexer.search("neubau").matches == [])
        #expect(await indexer.statistics.documents == 0)
    }

    /// A text that arrives before its document stays out of the index until it is linked; the link is a history
    /// update of `DocumentText.document` (P-a).
    @Test(arguments: Store.allCases)
    func anEarlyTextIsFoundOnceItIsLinked(store: Store) async throws {
        let container = try Self.container(store)
        let documentID = UUID()
        let early = ModelContext(container)
        early.insert(DocumentText(documentID: documentID, extractedText: "Frühankunft"))
        try early.save()
        let indexer = SearchIndexer(container: container)
        let recorder = StateRecorder(indexer.updates())
        defer {
            recorder.cancel()
            indexer.stop()
        }
        indexer.start()
        await recorder.ready.wait()
        #expect(await indexer.search("fruhankunft").matches == [])

        let linking = ModelContext(container)
        let document = Document(id: documentID, title: "Spät")
        linking.insert(document)
        let text = try #require(try linking.fetch(FetchDescriptor<DocumentText>()).first)
        document.text = text
        try linking.save()
        await recorder.ready.wait(for: 2)
        #expect(await indexer.search("fruhankunft").matches == [document.instanceID])
    }

    /// A change saved while the build is held after its first batch is in the index at `.ready` (step 4 replays
    /// the history from the token of step 1). Queries during the build answer from what is indexed so far: the
    /// metadata of every document, and `.building`.
    @Test func aChangeDuringTheBuildIsInTheIndexAtReady() async throws {
        let container = try TestSupport.makeContainerOnDisk()
        var documents: [UUID] = []
        for number in 0..<30 {
            documents.append(
                try SearchStore.insert(title: "Akte \(number)", text: "kennung\(number)x", in: container))
        }
        let held = Checkpoint()
        let indexer = SearchIndexer(
            container: container, textBatchBytes: 1, hooks: .init(afterBatch: { _ in await held.pass() }))
        let recorder = StateRecorder(indexer.updates())
        defer {
            held.release()
            recorder.cancel()
            indexer.stop()
        }
        indexer.start()
        await held.reached()

        let during = await indexer.search("akte")
        #expect(during.matches.count == 30)
        #expect(during.state == .building(indexed: SearchStoreReaderGroup.size, total: 30))
        var indexed: UUID?
        for (number, document) in documents.enumerated()
        where await indexer.search("kennung\(number)x").matches == [document] {
            indexed = document
            break
        }
        let edited = try #require(indexed, "no text of the first batch is indexed")
        try SearchStore.setText("Nachtrag geändert", of: edited, in: container)
        held.release()

        await recorder.ready.wait()
        #expect(await indexer.search("nachtrag").matches == [edited])
        #expect(await indexer.search("akte").matches.count == 30)
        for (number, document) in documents.enumerated() where document != edited {
            #expect(await indexer.search("kennung\(number)x").matches == [document])
        }
    }

    // MARK: Subscribers (Revision 1, B3)

    @Test func everySubscriberSeesEveryElement() async throws {
        let container = try TestSupport.makeContainer()
        let document = try SearchStore.insert(title: "Beleg", in: container)
        let indexer = SearchIndexer(container: container)
        let first = StateRecorder(indexer.updates())
        let second = StateRecorder(indexer.updates())
        defer {
            first.cancel()
            second.cancel()
            indexer.stop()
        }
        indexer.start()
        await first.ready.wait()
        await second.ready.wait()

        try SearchStore.setText("Tankquittung", of: document, in: container)
        await first.ready.wait(for: 2)
        await second.ready.wait(for: 2)
        #expect(await indexer.search("tankquittung").matches == [document])
    }

    /// An update reads the history, the changed texts and the metadata off the actor (#132, N-d): a query typed while
    /// an update reads is answered at once, not after the reads.
    @Test func aQueryDoesNotWaitForAnUpdatesReads() async throws {
        let container = try TestSupport.makeContainer()
        let document = try SearchStore.insert(title: "Stromrechnung", text: "Zählerstand", in: container)
        let armed = Armed()
        let reading = Checkpoint()
        // The reads run on a queue of their own, so the stop in the history read holds no thread of the pool (#164).
        var hooks = SearchIndexer.Hooks()
        hooks.executor = TestSupport.OwnThreadExecutor(name: "SearchIndexer reads")
        let indexer = SearchIndexer(
            container: container, history: BlockingHistory(container: container, armed: armed, checkpoint: reading),
            hooks: hooks)
        let recorder = StateRecorder(indexer.updates())
        defer {
            reading.release()
            recorder.cancel()
            indexer.stop()
        }
        indexer.start()
        await recorder.ready.wait()

        armed.turnOn()
        try SearchStore.setText("Abschlag", of: document, in: container)
        await reading.reached()
        // The update now holds inside its history read.
        let answered = TestSignal()
        let query = Task {
            let result = await indexer.search("stromrechnung")
            answered.fire()
            return result
        }
        let wasAnswered = await answered.wait(timeout: .seconds(10), "the query waited for the update's reads")
        reading.release()
        #expect(wasAnswered)
        #expect(await query.value.matches == [document])

        await recorder.ready.wait(for: 2)
        #expect(await indexer.search("abschlag").matches == [document])
        #expect(await indexer.search("zählerstand").matches == [])
    }

    // MARK: History errors (N5)

    /// A history error that is no expiry rebuilds once per launch; later events keep the index and retry the
    /// history without rebuilding.
    @Test func aPersistentHistoryErrorRebuildsAtMostOnce() async throws {
        let container = try TestSupport.makeContainer()
        let document = try SearchStore.insert(title: "Vertrag", text: "Erstfassung", in: container)
        let history = FailingHistory()
        let indexer = SearchIndexer(container: container, history: history)
        let recorder = StateRecorder(indexer.updates())
        defer {
            recorder.cancel()
            indexer.stop()
        }
        indexer.start()
        await recorder.ready.wait()
        #expect(await indexer.builds == 1)

        for round in 1...3 {
            try SearchStore.edit(document, in: container) { $0.title = "Vertrag \(round)" }
            await recorder.ready.wait(for: 1 + round)
            #expect(await indexer.search("vertrag \(round)").matches == [document])
        }
        #expect(await indexer.builds == 2)
        // The build's and the rebuild's step 4, and one read per event.
        #expect(history.changeReads == 5)
        #expect(await indexer.search("erstfassung").matches == [document])
    }
}

/// The group size the build reads text rows in, as the tests see it.
enum SearchStoreReaderGroup {
    static let size = 25
}
