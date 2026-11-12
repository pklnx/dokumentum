import DokumentumCore
import DokumentumKit
import DokumentumTestSupport
import Foundation
import Synchronization
import Testing

@testable import Dokumentum

/// Every window's library follows the app's one search index (plan of #7, part 2, B3): each model subscribes on
/// its own and sees every state the index publishes.
@MainActor
struct LibraryModelSearchIndexTests {
    /// A searcher whose states the test publishes, one stream per subscriber like the indexer's.
    final class StubSearcher: DocumentSearching {
        private struct State {
            var current = SearchIndexState.building(indexed: 0, total: 0)
            var continuations: [UUID: AsyncStream<SearchIndexState>.Continuation] = [:]
        }

        private let storage = Mutex(State())
        let subscribed = TestSignal()

        func search(_ text: String) async -> SearchResult { SearchResult(matches: [], state: await state) }

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

    @Test func everyWindowsModelFollowsTheIndex() async throws {
        let searcher = StubSearcher()
        let first = LibraryModel(source: FixtureLibrarySource(), searcher: searcher)
        let second = LibraryModel(source: FixtureLibrarySource(), searcher: searcher)
        let firstTask = Task { await first.observeSearchIndex() }
        let secondTask = Task { await second.observeSearchIndex() }
        defer {
            firstTask.cancel()
            secondTask.cancel()
        }
        await searcher.subscribed.wait(for: 2)
        try await TestSupport.waitUntil { first.searchIndexState != nil && second.searchIndexState != nil }

        searcher.publish(.building(indexed: 3, total: 10))
        try await TestSupport.waitUntil {
            first.searchIndexState == .building(indexed: 3, total: 10)
                && second.searchIndexState == .building(indexed: 3, total: 10)
        }
        searcher.publish(.ready)
        try await TestSupport.waitUntil { first.searchIndexState == .ready && second.searchIndexState == .ready }
    }

    @Test func aModelWithoutSearcherHasNoIndexState() async {
        let model = LibraryModel(source: FixtureLibrarySource())
        await model.observeSearchIndex()
        #expect(model.searchIndexState == nil)
    }
}
