import DokumentumKit
import DokumentumTestSupport
import Foundation
import Synchronization
import Testing

@testable import Dokumentum

/// The search in the library (#7, part 3): the text narrows the selected list or All Documents (P2), chips filter
/// (P3), the list order stays (P4), the newest query wins (T10), and an index update runs the active query again.
/// Each query is awaited through the model's `searchTask`; nothing waits for time.
@MainActor
struct LibraryModelSearchTests {
    private typealias Fixtures = FixtureCatalog

    /// A searcher whose answers the test sets per text; a query for a text with a gate stops there until the test
    /// releases it. One `updates()` stream per subscriber, like the indexer's.
    final class SearchStub: DocumentSearching {
        private struct State {
            var results: [String: Set<UUID>] = [:]
            var gates: [String: Checkpoint] = [:]
            var current = SearchIndexState.ready
            var continuations: [UUID: AsyncStream<SearchIndexState>.Continuation] = [:]
        }

        private let storage = Mutex(State())
        /// Fires once per query.
        let searched = TestSignal()
        /// Fires once per subscription.
        let subscribed = TestSignal()

        init(_ results: [String: Set<UUID>] = [:]) {
            storage.withLock { $0.results = results }
        }

        func answer(_ text: String, with matches: Set<UUID>) {
            storage.withLock { $0.results[text] = matches }
        }

        func gate(_ text: String) -> Checkpoint {
            let gate = Checkpoint()
            storage.withLock { $0.gates[text] = gate }
            return gate
        }

        func search(_ text: String) async -> SearchResult {
            searched.fire()
            await storage.withLock({ $0.gates[text] })?.pass()
            return storage.withLock { SearchResult(matches: $0.results[text] ?? [], state: $0.current) }
        }

        var state: SearchIndexState {
            get async { storage.withLock { $0.current } }
        }

        nonisolated func updates() -> AsyncStream<SearchIndexState> {
            let (stream, continuation) = AsyncStream<SearchIndexState>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                self?.storage.withLock { _ = $0.continuations.removeValue(forKey: id) }
            }
            storage.withLock { $0.continuations[id] = continuation }
            subscribed.fire()
            return stream
        }

        func publish(_ new: SearchIndexState) {
            let continuations = storage.withLock { state in
                state.current = new
                return Array(state.continuations.values)
            }
            for continuation in continuations { continuation.yield(new) }
        }
    }

    /// A source with a snapshot the test can change and announce.
    final class MutableSource: LibrarySource {
        private let current: Mutex<LibrarySnapshot>
        let changes: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init(_ snapshot: LibrarySnapshot) {
            current = Mutex(snapshot)
            (changes, continuation) = AsyncStream.makeStream()
        }

        @MainActor func snapshot() -> LibrarySnapshot { current.withLock { $0 } }

        func set(_ snapshot: LibrarySnapshot) { current.withLock { $0 = snapshot } }

        func loadPDF(instanceID: UUID) async -> PDFLoadState { .noDocument }
    }

    private static func id(_ number: Int) -> UUID { Fixtures.documentID(number) }

    private static func ids(_ documents: [LibraryDocument]) -> [UUID] { documents.map(\.instanceID) }

    /// Sets the text and waits for its query's answer.
    private static func type(_ text: String, into model: LibraryModel) async {
        model.search.text = text
        await model.searchTask?.value
    }

    // MARK: Text and scope

    @Test func theTextNarrowsTheSelectedListInListOrder() async {
        // Electricity bill (Inbox), Account statement (not), Scanned receipt (Inbox), Medical invoice (Inbox).
        let stub = SearchStub(["bill": [Self.id(9), Self.id(1), Self.id(4), Self.id(2)]])
        let model = LibraryModel(source: FixtureLibrarySource(), searcher: stub)
        #expect(model.selection == .inbox)

        await Self.type("bill", into: model)
        // The Inbox only, newest document date first, whatever order the index answered in.
        #expect(Self.ids(model.documents) == [Self.id(1), Self.id(2), Self.id(9)])
        #expect(model.isSearchActive)
    }

    @Test func theScopeAllDocumentsSearchesEveryList() async {
        let stub = SearchStub(["bill": [Self.id(1), Self.id(4), Self.id(8)]])
        let model = LibraryModel(source: FixtureLibrarySource(), searcher: stub)
        await Self.type("bill", into: model)
        #expect(Self.ids(model.documents) == [Self.id(1)])

        // The scope needs no new query.
        model.search.scope = .all
        #expect(Self.ids(model.documents) == [Self.id(1), Self.id(4), Self.id(8)])
        #expect(stub.searched.count == 1)
    }

    @Test func clearingTheTextRestoresTheList() async {
        let stub = SearchStub(["bill": [Self.id(1)]])
        let model = LibraryModel(source: FixtureLibrarySource(), searcher: stub)
        let inbox = model.documents
        await Self.type("bill", into: model)
        #expect(Self.ids(model.documents) == [Self.id(1)])

        await Self.type("", into: model)
        #expect(model.documents == inbox)
        #expect(model.searchResult == nil)
        #expect(!model.isSearchActive)
        // Spaces and punctuation are no text either: the list stays, and nothing is asked.
        await Self.type(" - ", into: model)
        #expect(model.documents == inbox)
        #expect(stub.searched.count == 1)
    }

    @Test func aSelectedDocumentOutsideTheResultsIsDeselected() async {
        let stub = SearchStub(["bill": [Self.id(1)]])
        let model = LibraryModel(source: FixtureLibrarySource(), searcher: stub)
        model.selectedDocumentID = Self.id(2)
        await Self.type("bill", into: model)
        #expect(model.selectedDocumentID == nil)
    }

    // MARK: Chips (P3)

    @Test func chipsFilterWithoutAQueryAndCombine() {
        let stub = SearchStub()
        let model = LibraryModel(source: FixtureLibrarySource(), searcher: stub)
        model.search.tokens = [.tag(Fixtures.tax.instanceID)]
        // Inbox and Tax: Electricity bill, Medical invoice.
        #expect(Self.ids(model.documents) == [Self.id(1), Self.id(2)])
        model.search.scope = .all
        #expect(Self.ids(model.documents) == [Self.id(1), Self.id(2), Self.id(3)])
        // Tax and Stadtwerke.
        model.search.tokens.append(.correspondent(Fixtures.stadtwerke.instanceID))
        #expect(Self.ids(model.documents) == [Self.id(1), Self.id(3)])
        // A tag chip takes the tags below it: Auto lists the Golf inspection (Auto › Golf).
        model.search.tokens = [.tag(Fixtures.auto.instanceID), .documentType(Fixtures.invoice.instanceID)]
        #expect(Self.ids(model.documents) == [Self.id(8)])
        // The Inbox chip in All Documents.
        model.search.tokens = [.inbox, .correspondent(Fixtures.musterbank.instanceID)]
        #expect(Self.ids(model.documents) == [Self.id(5), Self.id(6)])
        #expect(stub.searched.count == 0)
    }

    @Test func chipsAndTextCombine() async {
        let stub = SearchStub(["statement": [Self.id(4), Self.id(6)]])
        let model = LibraryModel(source: FixtureLibrarySource(), searcher: stub)
        model.search.scope = .all
        model.search.tokens = [.tag(Fixtures.important.instanceID)]
        await Self.type("statement", into: model)
        #expect(Self.ids(model.documents) == [Self.id(6)])
    }

    /// Picking a suggestion drops the words typed for it, as the iPhone's field does by itself.
    @Test func pickingAChipDropsTheWordsTypedForIt() async {
        let stub = SearchStub(["tax": [Self.id(1), Self.id(2), Self.id(3)]])
        let model = LibraryModel(source: FixtureLibrarySource(), searcher: stub)
        await Self.type("tax", into: model)
        #expect(model.searchSuggestions.first == .tag(Fixtures.tax.instanceID))

        model.search.tokens.append(.tag(Fixtures.tax.instanceID))
        await model.searchTask?.value
        #expect(model.search.text == "")
        #expect(model.search.tokens == [.tag(Fixtures.tax.instanceID)])
        #expect(Self.ids(model.documents) == [Self.id(1), Self.id(2)])
    }

    /// Revision 1, B2: in the Trash a tag chip lists the trashed documents with that tag; the scope alone decides
    /// trashed or not, and the Trash offers no Inbox chip.
    @Test func aChipInTheTrashListsTrashedDocuments() async {
        let trashedID = UUID()
        var snapshot = Fixtures.snapshot
        snapshot.documents.append(
            LibraryDocument(
                instanceID: trashedID, title: "Old tax return", documentDate: Date(timeIntervalSince1970: 0),
                createdAt: Date(timeIntervalSince1970: 0), isInbox: true, deletedAt: Date(timeIntervalSince1970: 1),
                tagIDs: [Fixtures.tax.instanceID]))
        let stub = SearchStub()
        let model = LibraryModel(source: MutableSource(snapshot), searcher: stub)
        model.selection = .trash
        model.search.tokens = [.tag(Fixtures.tax.instanceID)]
        #expect(Self.ids(model.documents) == [trashedID])
        model.search.tokens = [.correspondent(Fixtures.stadtwerke.instanceID)]
        #expect(model.documents.isEmpty)

        model.search.tokens = []
        // The first letters of the Inbox's name in the language of the run.
        await Self.type(String(String(localized: "Inbox").prefix(3)), into: model)
        #expect(!model.searchSuggestions.contains(.inbox))
        model.selection = .all
        #expect(model.searchSuggestions.contains(.inbox))

        await Self.type("", into: model)
        model.search.tokens = [.tag(Fixtures.tax.instanceID)]
        #expect(!model.documents.contains { $0.instanceID == trashedID })
    }

    @Test func aChipWhoseRecordIsGoneIsDropped() async {
        let source = MutableSource(Fixtures.snapshot)
        let model = LibraryModel(source: source, searcher: SearchStub())
        model.search.scope = .all
        model.search.tokens = [.tag(Fixtures.golf.instanceID), .inbox]
        var snapshot = Fixtures.snapshot
        snapshot.tags.removeAll { $0.instanceID == Fixtures.golf.instanceID }
        source.set(snapshot)
        model.reload()
        #expect(model.search.tokens == [.inbox])
    }

    // MARK: Generations (T10) and index updates

    /// An older query that answers after a newer one does not replace the newer result.
    @Test func aStaleResultIsDropped() async {
        let stub = SearchStub(["b": [Self.id(1), Self.id(2)], "bi": [Self.id(1)]])
        let held = stub.gate("b")
        defer { held.release() }
        let model = LibraryModel(source: FixtureLibrarySource(), searcher: stub)

        model.search.text = "b"
        let first = model.searchTask
        await held.reached()
        await Self.type("bi", into: model)
        #expect(Self.ids(model.documents) == [Self.id(1)])

        held.release()
        await first?.value
        #expect(Self.ids(model.documents) == [Self.id(1)])
        #expect(model.search.text == "bi")
    }

    /// An index update (a text processed, a build batch in) runs the active query again.
    @Test func anIndexUpdateRunsTheActiveQueryAgain() async {
        let stub = SearchStub(["golf": [Self.id(8)]])
        let model = LibraryModel(source: FixtureLibrarySource(), searcher: stub)
        model.selection = .all
        let observing = Task { await model.observeSearchIndex() }
        defer { observing.cancel() }
        await stub.subscribed.wait()
        await Self.type("golf", into: model)
        #expect(Self.ids(model.documents) == [Self.id(8)])

        stub.answer("golf", with: [Self.id(8), Self.id(3)])
        stub.publish(.ready)
        await stub.searched.wait(for: 2)
        await model.searchTask?.value
        #expect(Self.ids(model.documents) == [Self.id(3), Self.id(8)])
    }

    @Test func theIndexingLineShowsWhileTextsAreIndexedAndASearchIsActive() async throws {
        let stub = SearchStub()
        stub.publish(.building(indexed: 2, total: 9))
        let model = LibraryModel(source: FixtureLibrarySource(), searcher: stub)
        let observing = Task { await model.observeSearchIndex() }
        defer { observing.cancel() }
        await stub.subscribed.wait()
        try await TestSupport.waitUntil { model.searchIndexState != nil }
        #expect(model.indexingProgress == nil)

        await Self.type("bill", into: model)
        #expect(model.indexingProgress?.indexed == 2)
        #expect(model.indexingProgress?.total == 9)
        stub.publish(.ready)
        try await TestSupport.waitUntil { model.searchIndexState == .ready }
        #expect(model.indexingProgress == nil)
    }

    // MARK: Sidebar (P7)

    /// The search stays when another list is chosen and applies to it. On the iPhone, going back to the sidebar
    /// (selection `nil`) ends it.
    @Test func theSearchStaysWhenTheSelectionChanges() async {
        let stub = SearchStub(["bill": [Self.id(1), Self.id(3), Self.id(4)]])
        let model = LibraryModel(source: FixtureLibrarySource(), searcher: stub)
        await Self.type("bill", into: model)
        #expect(Self.ids(model.documents) == [Self.id(1)])

        model.selection = .tag(Fixtures.tax.instanceID)
        #expect(model.search.text == "bill")
        #expect(Self.ids(model.documents) == [Self.id(1), Self.id(3)])

        model.selection = nil
        #if os(iOS)
            #expect(model.search == LibrarySearch())
        #else
            #expect(model.search.text == "bill")
        #endif
    }
}
