import DokumentumKit
import Foundation
import SwiftData
import Synchronization

/// The app's one search index (plan of #7, part 2, Approaches 1, 6 and 7): it builds a `SearchIndex` at launch and
/// keeps it up to date, off the main actor. A plain actor that makes its own `ModelContext`s on the app's
/// container, as `ProcessingQueue` does; it only reads.
///
/// **Build** (T8), one step after the other:
/// 1. the newest history token;
/// 2. the metadata of every document through the light list query (`SearchStoreReader.metadata`): from now on
///    titles and names are found;
/// 3. the texts in byte-bounded batches (Revision 1, N3): the text rows' identifiers once, then per batch one
///    actor call that fetches rows by identifier in groups of 25 (a fresh context per group) until 1 MB of text is
///    indexed. Queries interleave between batches and see what is indexed so far; each batch yields
///    `.building(indexed:total:)`;
/// 4. the history since the token of step 1 and the metadata again, so nothing saved during the build is missed;
/// 5. the overflow is merged, and the state is `.ready`.
///
/// **Updates** (T2, T3) start after `.ready` (N4). Events: `ModelContext.didSave` of any context of the container
/// at once, and the elements of `storeChanges` (the app's `StoreChangeObserver`: remote changes and the end of each
/// CloudKit import). A burst leaves one pending event. On each event the indexer applies the history since its
/// token (text inserts, `extractedText` and `document` updates, deletes; each changed row is read again by key)
/// and re-reads the metadata, which the index compares per document (`SearchIndex.setMetadata`).
/// - An expired token (`SwiftDataError.historyTokenExpired`, P-c): a rebuild.
/// - Any other history error (N5): logged once per code; the first one in a launch rebuilds, later ones keep the
///   index and the token, and the next event tries the history again.
///
/// **A rebuild** builds a fresh index aside through the same steps while the old one answers queries (the state is
/// `.building` meanwhile), then replaces it in one assignment. Both are in memory until then (about 2 × 66 MB for
/// 5,000 documents, R-b).
///
/// **Copies sharing an `instanceID`** follow `RowRecords.oldestFirst`: the text of the copy with the oldest
/// `createdAt` is indexed. Known gap (N6): if that copy and its text are deleted, the other copy's text is indexed
/// only at the next launch.
public actor SearchIndexer: DocumentSearching {
    /// Test hooks; empty in the app.
    public struct Hooks: Sendable {
        /// Runs after each text batch of a build or rebuild, with the number of texts indexed so far. A suspension
        /// point where a test holds the build.
        public var afterBatch: (@Sendable (Int) async -> Void)?
        /// Runs before each update reads the history.
        public var beforeHistory: (@Sendable () async -> Void)?

        public init(
            afterBatch: (@Sendable (Int) async -> Void)? = nil, beforeHistory: (@Sendable () async -> Void)? = nil
        ) {
            self.afterBatch = afterBatch
            self.beforeHistory = beforeHistory
        }
    }

    /// How long the steps of the last finished build took (the benchmark reports them).
    public struct BuildReport: Sendable, Equatable {
        /// Steps 1 and 2.
        public var metadata: Duration
        /// Step 3.
        public var texts: Duration
        /// Steps 1 to 5, until `.ready`.
        public var total: Duration
        public var textCount: Int
    }

    /// A batch of text indexing ends after this many UTF-8 bytes of text (Revision 1, N3).
    public static let textBatchBytes = 1_000_000

    public let container: ModelContainer
    private let history: any SearchHistoryReading
    private let batchBytes: Int
    private let hooks: Hooks

    public private(set) var state: SearchIndexState = .building(indexed: 0, total: 0)
    /// The index queries read.
    private var live = Contents()
    /// The index a rebuild fills; `nil` otherwise.
    private var aside: Contents?
    /// Whether this launch already rebuilt for a history error that was not an expiry (N5).
    private var rebuiltForHistoryError = false
    private var loggedHistoryErrors: Set<String> = []

    /// Builds started, the first one included (for tests).
    public private(set) var builds = 0
    public private(set) var lastBuild: BuildReport?

    private let subscribers = Subscribers()
    private let running = Mutex<Running?>(nil)

    /// - Parameters:
    ///   - history: the persistent history; `StoreSearchHistory` on `container` by default.
    ///   - textBatchBytes: where a text batch ends; tests pass a small value to get several batches.
    public init(
        container: ModelContainer, history: (any SearchHistoryReading)? = nil,
        textBatchBytes: Int = SearchIndexer.textBatchBytes, hooks: Hooks = Hooks()
    ) {
        self.container = container
        self.history = history ?? StoreSearchHistory(container: container)
        batchBytes = max(1, textBatchBytes)
        self.hooks = hooks
    }

    // MARK: DocumentSearching

    public func search(_ text: String) -> SearchResult {
        SearchResult(matches: live.index.search(text), state: state)
    }

    /// A new stream per call (Revision 1, B3), keeping the newest state; it yields after every applied event,
    /// build batch and rebuild swap, and ends when its subscriber stops iterating or the indexer stops.
    public nonisolated func updates() -> AsyncStream<SearchIndexState> {
        subscribers.subscribe()
    }

    /// The index's statistics (tokens, postings, documents).
    public var statistics: SearchIndex.Statistics { live.index.statistics }

    // MARK: Running

    /// Starts the build and then follows the container's saves and `storeChanges`. Once only.
    /// - Parameter storeChanges: the debounced changes of the app's `StoreChangeObserver`; `nil` for a store
    ///   nothing else writes (in-memory stores).
    public nonisolated func start(storeChanges: AsyncStream<Void>? = nil) {
        let (events, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let observation = SaveObservation(container: container) { continuation.yield() }
        let forwarding = storeChanges.map { storeChanges in
            Task {
                for await _ in storeChanges { continuation.yield() }
            }
        }
        let task = Task { await self.run(events: events) }
        let previous = running.withLock { running in
            defer { running = Running(observation: observation, forwarding: forwarding, task: task) }
            return running
        }
        precondition(previous == nil, "SearchIndexer.start called twice")
    }

    /// Stops following changes and ends every `updates()` stream. The index keeps answering queries.
    public nonisolated func stop() {
        let current = running.withLock { running in
            defer { running = nil }
            return running
        }
        current?.observation.cancel()
        current?.forwarding?.cancel()
        current?.task.cancel()
        subscribers.finishAll()
    }

    @concurrent
    private nonisolated func run(events: AsyncStream<Void>) async {
        await build(aside: false)
        for await _ in events {
            if Task.isCancelled { return }
            await update()
        }
    }

    // MARK: Build (T8)

    /// Builds the live index (the first build) or a fresh one aside that replaces it at the end (a rebuild, N4).
    @concurrent
    private nonisolated func build(aside: Bool) async {
        let clock = ContinuousClock()
        let start = clock.now
        let ids = await beginBuild(aside: aside)
        let metadataDone = clock.now
        var next = 0
        while next < ids.count {
            if Task.isCancelled { return }
            next = await indexTexts(ids, from: next, aside: aside, publishing: ids.count)
            if let afterBatch = hooks.afterBatch { await afterBatch(next) }
        }
        await finishBuild(
            aside: aside, textCount: ids.count, start: start, metadataDone: metadataDone, textsDone: clock.now)
    }

    /// Steps 1 and 2, and the text identifiers for step 3.
    private func beginBuild(aside: Bool) -> [PersistentIdentifier] {
        builds += 1
        var contents = Contents()
        do {
            contents.token = try history.newestToken()
        } catch {
            logHistoryError(error)
        }
        var ids: [PersistentIdentifier] = []
        do {
            let context = ModelContext(container)
            contents.setMetadata(try SearchStoreReader.metadata(in: context))
            ids = try SearchStoreReader.textIdentifiers(in: context)
        } catch {
            Log.search.error("Search build could not read the store: \(Log.code(of: error), privacy: .public)")
        }
        if aside { self.aside = contents } else { live = contents }
        publish(.building(indexed: 0, total: ids.count))
        return ids
    }

    /// Steps 4 and 5; a rebuild swaps its index in.
    private func finishBuild(
        aside: Bool, textCount: Int, start: ContinuousClock.Instant, metadataDone: ContinuousClock.Instant,
        textsDone: ContinuousClock.Instant
    ) {
        withContents(aside: aside) { contents in
            do {
                try applyHistory(to: &contents)
            } catch {
                // Never a rebuild from inside a build; the next event tries the history again.
                logHistoryError(error)
            }
            readMetadata(into: &contents)
            contents.index.mergeOverflow()
        }
        if aside, let fresh = self.aside {
            live = fresh
            self.aside = nil
        }
        let report = BuildReport(
            metadata: metadataDone - start, texts: textsDone - metadataDone, total: ContinuousClock.now - start,
            textCount: textCount)
        lastBuild = report
        Log.search.notice(
            """
            Search index built: \(report.textCount, privacy: .public) texts, \
            \(self.live.index.statistics.tokens, privacy: .public) tokens in \
            \(report.total.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 2))), privacy: .public)
            """)
        publish(.ready)
    }

    /// Indexes the texts of `ids` from `start` on until `batchBytes` of text are in (at least one group); returns
    /// where the next batch starts. One actor call: queries wait for at most one batch.
    private func indexTexts(
        _ ids: [PersistentIdentifier], from start: Int, aside: Bool, publishing total: Int?
    ) -> Int {
        var next = start
        withContents(aside: aside) { contents in
            var bytes = 0
            while next < ids.count, bytes < batchBytes {
                let group = Array(ids[next..<min(next + SearchStoreReader.groupSize, ids.count)])
                next += group.count
                bytes += upsertTexts(group, into: &contents)
            }
        }
        if let total { publish(.building(indexed: next, total: total)) }
        return next
    }

    /// Reads the text rows of `group` in a fresh context and indexes them; a row that is gone clears its text.
    /// Returns the bytes indexed.
    private func upsertTexts(_ group: [PersistentIdentifier], into contents: inout Contents) -> Int {
        do {
            let rows = try SearchStoreReader.texts(group, in: ModelContext(container))
            var found: Set<PersistentIdentifier> = []
            var bytes = 0
            for row in rows {
                found.insert(row.id)
                bytes += row.text.utf8.count
                contents.upsert(row)
            }
            for id in group where !found.contains(id) { contents.clear(text: id) }
            return bytes
        } catch {
            Log.search.error("Search could not read texts: \(Log.code(of: error), privacy: .public)")
            return 0
        }
    }

    // MARK: Updates (T2, T3)

    @concurrent
    private nonisolated func update() async {
        if let beforeHistory = hooks.beforeHistory { await beforeHistory() }
        switch await applyUpdate() {
        case .applied:
            break
        case .rebuild:
            await build(aside: true)
        }
    }

    private enum UpdateOutcome {
        case applied, rebuild
    }

    /// One event: the history since the token, then the metadata. A rebuild is decided here and run by the caller.
    private func applyUpdate() -> UpdateOutcome {
        do {
            try applyHistory(to: &live)
        } catch let error as SwiftDataError where error == .historyTokenExpired {
            Log.search.notice("Search history expired; rebuilding the index")
            return .rebuild
        } catch {
            logHistoryError(error)
            if !rebuiltForHistoryError {
                rebuiltForHistoryError = true
                Log.search.notice("Search history failed; rebuilding the index once")
                return .rebuild
            }
        }
        readMetadata(into: &live)
        live.index.mergeOverflow()
        publish(.ready)
        return .applied
    }

    /// Applies the text changes since `contents.token` and moves the token on. Throws the history's errors with
    /// the token unchanged.
    private func applyHistory(to contents: inout Contents) throws {
        let (changes, newest) = try history.changes(since: contents.token)
        var upserts: [PersistentIdentifier] = []
        var seen: Set<PersistentIdentifier> = []
        var documents: [PersistentIdentifier] = []
        for change in changes {
            switch change {
            case .upsert(let id):
                if seen.insert(id).inserted { upserts.append(id) }
            case .documentLink(let id):
                documents.append(id)
            case .delete(let id):
                contents.clear(text: id)
            }
        }
        if !documents.isEmpty {
            do {
                for start in stride(from: 0, to: documents.count, by: SearchStoreReader.groupSize) {
                    let group = Array(documents[start..<min(start + SearchStoreReader.groupSize, documents.count)])
                    for id in try SearchStoreReader.linkedTexts(ofDocuments: group, in: ModelContext(container))
                    where seen.insert(id).inserted {
                        upserts.append(id)
                    }
                }
            } catch {
                Log.search.error("Search could not read relinked texts: \(Log.code(of: error), privacy: .public)")
            }
        }
        for start in stride(from: 0, to: upserts.count, by: SearchStoreReader.groupSize) {
            _ = upsertTexts(
                Array(upserts[start..<min(start + SearchStoreReader.groupSize, upserts.count)]), into: &contents)
        }
        if let newest { contents.token = newest }
    }

    private func readMetadata(into contents: inout Contents) {
        do {
            contents.setMetadata(try SearchStoreReader.metadata(in: ModelContext(container)))
        } catch {
            Log.search.error("Search could not read the metadata: \(Log.code(of: error), privacy: .public)")
        }
    }

    // MARK: Helpers

    private func withContents(aside: Bool, _ body: (inout Contents) -> Void) {
        if aside, self.aside != nil {
            body(&self.aside!)
        } else {
            body(&live)
        }
    }

    private func publish(_ state: SearchIndexState) {
        self.state = state
        subscribers.yield(state)
    }

    private func logHistoryError(_ error: any Error) {
        let code = Log.code(of: error)
        guard loggedHistoryErrors.insert(code).inserted else { return }
        Log.search.error("Search history failed: \(code, privacy: .public)")
    }
}

extension SearchIndexer {
    /// An index with what it needs to apply text changes.
    struct Contents {
        struct Owner {
            var createdAt: Date
            var text: PersistentIdentifier
        }

        var index = SearchIndex()
        var token: DefaultHistoryToken?
        /// The document each indexed text row is indexed for.
        var textDocuments: [PersistentIdentifier: UUID] = [:]
        /// The text row whose text is indexed per document, and its copy's `createdAt` (copies sharing an
        /// `instanceID` follow `RowRecords.oldestFirst`).
        var owners: [UUID: Owner] = [:]

        mutating func upsert(_ row: SearchStoreReader.TextRow) {
            if let previous = textDocuments[row.id], previous != row.document?.instanceID { clear(text: row.id) }
            guard let document = row.document else { return }
            if let owner = owners[document.instanceID], owner.text != row.id {
                // Another copy's text: the older copy keeps it.
                guard document.createdAt < owner.createdAt else { return }
                textDocuments[owner.text] = nil
            }
            owners[document.instanceID] = Owner(createdAt: document.createdAt, text: row.id)
            textDocuments[row.id] = document.instanceID
            index.setText(row.text, for: document.instanceID)
        }

        /// Takes back what the text row `id` indexed.
        mutating func clear(text id: PersistentIdentifier) {
            guard let document = textDocuments.removeValue(forKey: id) else { return }
            guard owners[document]?.text == id else { return }
            owners[document] = nil
            if index.contains(document) { index.setText("", for: document) }
        }

        /// The metadata of every document; documents not in `fields` are removed.
        mutating func setMetadata(_ fields: [UUID: SearchFields]) {
            for (id, documentFields) in fields { index.setMetadata(documentFields, for: id) }
            for id in index.documentIDs where fields[id] == nil {
                index.remove(id)
                if let owner = owners.removeValue(forKey: id) { textDocuments[owner.text] = nil }
            }
        }
    }

    /// The streams of `updates()`, one continuation per subscriber.
    final class Subscribers: Sendable {
        private let continuations = Mutex<[UUID: AsyncStream<SearchIndexState>.Continuation]>([:])

        func subscribe() -> AsyncStream<SearchIndexState> {
            let id = UUID()
            let (stream, continuation) = AsyncStream<SearchIndexState>.makeStream(
                bufferingPolicy: .bufferingNewest(1))
            continuation.onTermination = { [weak self] _ in
                self?.continuations.withLock { _ = $0.removeValue(forKey: id) }
            }
            continuations.withLock { $0[id] = continuation }
            return stream
        }

        func yield(_ state: SearchIndexState) {
            for continuation in continuations.withLock({ Array($0.values) }) { continuation.yield(state) }
        }

        func finishAll() {
            let all = continuations.withLock { all in
                defer { all = [:] }
                return Array(all.values)
            }
            for continuation in all { continuation.finish() }
        }
    }

    struct Running: Sendable {
        var observation: SaveObservation
        var forwarding: Task<Void, Never>?
        var task: Task<Void, Never>
    }
}
