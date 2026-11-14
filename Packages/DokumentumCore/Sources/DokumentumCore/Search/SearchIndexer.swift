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
/// CloudKit import). A burst leaves one pending event. On each event the indexer reads the history since its
/// token (text inserts, `extractedText` and `document` updates, deletes; each changed row is read again by key)
/// and the metadata **off the actor** (#132, N-d: queries typed while the processing queue writes texts do not
/// wait for these reads), then applies both in one actor call: the changed texts, and the metadata, which the index
/// compares per document (`SearchIndex.setMetadata`).
/// - An expired token (`SwiftDataError.historyTokenExpired`, P-c): a rebuild.
/// - Any other history error (N5): logged once per code; the first one in a launch rebuilds, later ones keep the
///   index and the token, and the next event tries the history again.
///
/// **A failed read of text rows** (#132, N-c) does not hold the token back (re-reading the whole history would
/// repeat every other change): the rows whose read failed go into a retry set (`Contents.retry`) and are read
/// again with the next history read, by key, before the new changes. A group of 25 whose read fails is read again
/// id by id, so only the rows that really fail stay in the set; a row leaves it when it is read, when it is gone
/// or when it is deleted. The documents whose relinked text could not be read are kept the same way. Each error
/// code is logged once. A row that keeps failing costs one failed read per event and nothing else (no read
/// triggers an event); with no further event the retry waits, as the history does. The build records its failed
/// groups the same way, so its step 4 already reads them again; a rebuild starts with an empty set.
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
        /// Runs after an update read the history, the changed texts and the metadata, off the actor, before it
        /// applies them.
        public var afterUpdateRead: (@Sendable () async -> Void)?
        /// Reads the text rows of one group in place of `SearchStoreReader.texts` (#132, N-c: a test fails reads).
        var readTexts: (@Sendable ([PersistentIdentifier], ModelContext) throws -> [SearchStoreReader.TextRow])?
        /// Reads the text rows that documents link now in place of `SearchStoreReader.linkedTexts`.
        var readLinkedTexts: (@Sendable ([PersistentIdentifier], ModelContext) throws -> [PersistentIdentifier])?
        /// Where the work off the actor runs (the build's and the updates' reads) in place of the cooperative pool:
        /// a test that stops a read in a synchronous hook then holds a thread of its own, not one of the pool's
        /// (#164).
        var executor: (any TaskExecutor)?

        public init(
            afterBatch: (@Sendable (Int) async -> Void)? = nil, beforeHistory: (@Sendable () async -> Void)? = nil,
            afterUpdateRead: (@Sendable () async -> Void)? = nil
        ) {
            self.afterBatch = afterBatch
            self.beforeHistory = beforeHistory
            self.afterUpdateRead = afterUpdateRead
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
    private let reads: StoreReads
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
    /// The code ("domain code", `Log.code(of:)`) of the last history error of this launch, an expiry included, or
    /// `nil` (T11 of #31: the Sync lab shows why a search missed). Read only; it changes nothing.
    public private(set) var lastHistoryErrorCode: String?

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
        reads = StoreReads(container: container, readTexts: hooks.readTexts, readLinkedTexts: hooks.readLinkedTexts)
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
        let task = Task(executorPreference: hooks.executor) { await self.run(events: events) }
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
            switch Self.readTextChanges(since: contents.token, retry: contents.retry, history: history, reads: reads) {
            case .changes(let changes):
                apply(changes, to: &contents)
            case .expired(let code), .failed(let code):
                // Never a rebuild from inside a build; the next event tries the history again.
                logHistoryError(code: code)
            }
            if let metadata = Self.readMetadata(container: container) { contents.setMetadata(metadata) }
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
        apply(reads.texts(group), to: &contents)
    }

    /// Indexes the rows read for one group; a row that is gone clears its text. A row whose read failed keeps what
    /// is indexed and goes into the retry set (#132, N-c); the others leave it. Returns the bytes indexed.
    @discardableResult
    private func apply(_ group: TextGroup, to contents: inout Contents) -> Int {
        var found: Set<PersistentIdentifier> = []
        var bytes = 0
        for row in group.rows {
            found.insert(row.id)
            bytes += row.text.utf8.count
            contents.upsert(row)
        }
        for id in group.ids where !found.contains(id) && !group.failed.contains(id) { contents.clear(text: id) }
        contents.retry.texts.subtract(group.ids)
        contents.retry.texts.formUnion(group.failed)
        return bytes
    }

    // MARK: Updates (T2, T3)

    /// One event: the reads off the actor (#132, N-d), then one actor call that applies them. A rebuild is decided
    /// there and run here.
    @concurrent
    private nonisolated func update() async {
        if let beforeHistory = hooks.beforeHistory { await beforeHistory() }
        let (token, retry) = await readStart()
        let read = UpdateRead(
            history: Self.readTextChanges(since: token, retry: retry, history: history, reads: reads),
            metadata: Self.readMetadata(container: container))
        if let afterUpdateRead = hooks.afterUpdateRead { await afterUpdateRead() }
        switch await applyUpdate(read, readSince: token) {
        case .applied:
            break
        case .rebuild:
            await build(aside: true)
        }
    }

    private enum UpdateOutcome {
        case applied, rebuild
    }

    /// Applies what one update read. Only one update runs at a time (`run`), so the token is still the one the
    /// read started from; if it is not (a rebuild swapped the index meanwhile), the read is dropped and the next
    /// event reads again from the new token.
    private func readStart() -> (DefaultHistoryToken?, Retry) { (live.token, live.retry) }

    private func applyUpdate(_ read: UpdateRead, readSince token: DefaultHistoryToken?) -> UpdateOutcome {
        guard live.token == token else { return .applied }
        switch read.history {
        case .changes(let changes):
            apply(changes, to: &live)
        case .expired(let code):
            lastHistoryErrorCode = code
            Log.search.notice("Search history expired; rebuilding the index")
            return .rebuild
        case .failed(let code):
            logHistoryError(code: code)
            if !rebuiltForHistoryError {
                rebuiltForHistoryError = true
                Log.search.notice("Search history failed; rebuilding the index once")
                return .rebuild
            }
        }
        if let metadata = read.metadata { live.setMetadata(metadata) }
        live.index.mergeOverflow()
        publish(.ready)
        return .applied
    }

    /// Applies text changes read since `contents.token` and moves the token on.
    private func apply(_ changes: TextChanges, to contents: inout Contents) {
        for id in changes.deletes {
            contents.clear(text: id)
            contents.retry.texts.remove(id)
        }
        contents.retry.documents.subtract(changes.relinkTried)
        contents.retry.documents.formUnion(changes.relinkFailed)
        for group in changes.groups { apply(group, to: &contents) }
        if let newest = changes.newest { contents.token = newest }
    }

    // MARK: Reads (nonisolated: each in fresh contexts of its own)

    /// The text changes since `token` and the text rows they name, read in fresh contexts, with the rows and
    /// documents of `retry` first (#132, N-c); rows deleted since `token` are not read. History errors are returned
    /// with nothing read; the caller logs them.
    private nonisolated static func readTextChanges(
        since token: DefaultHistoryToken?, retry: Retry, history: any SearchHistoryReading, reads: StoreReads
    ) -> HistoryRead {
        let changes: [TextChange]
        let newest: DefaultHistoryToken?
        do {
            (changes, newest) = try history.changes(since: token)
        } catch let error as SwiftDataError where error == .historyTokenExpired {
            return .expired(code: Log.code(of: error))
        } catch {
            return .failed(code: Log.code(of: error))
        }
        var upserts: [PersistentIdentifier] = []
        var seen: Set<PersistentIdentifier> = []
        for id in retry.texts where seen.insert(id).inserted { upserts.append(id) }
        var documents = Array(retry.documents)
        var seenDocuments = retry.documents
        var deletes: [PersistentIdentifier] = []
        for change in changes {
            switch change {
            case .upsert(let id):
                if seen.insert(id).inserted { upserts.append(id) }
            case .documentLink(let id):
                if seenDocuments.insert(id).inserted { documents.append(id) }
            case .delete(let id):
                deletes.append(id)
            }
        }
        let relinked = reads.linkedTexts(ofDocuments: documents)
        for id in relinked.texts where seen.insert(id).inserted { upserts.append(id) }
        // A deleted row is not read: the delete clears it and takes it out of the retry set (#132, N-c).
        let deleted = Set(deletes)
        upserts.removeAll { deleted.contains($0) }
        let groups = stride(from: 0, to: upserts.count, by: SearchStoreReader.groupSize).map { start in
            reads.texts(Array(upserts[start..<min(start + SearchStoreReader.groupSize, upserts.count)]))
        }
        return .changes(
            TextChanges(
                deletes: deletes, groups: groups, relinkTried: documents, relinkFailed: relinked.failed,
                newest: newest))
    }

    /// The metadata of every document, read in a fresh context; `nil` when the read failed (logged).
    private nonisolated static func readMetadata(container: ModelContainer) -> [UUID: SearchFields]? {
        do {
            return try SearchStoreReader.metadata(in: ModelContext(container))
        } catch {
            Log.search.error("Search could not read the metadata: \(Log.code(of: error), privacy: .public)")
            return nil
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
        logHistoryError(code: Log.code(of: error))
    }

    private func logHistoryError(code: String) {
        lastHistoryErrorCode = code
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
        /// What a failed read left to read again (#132, N-c); a rebuild starts without it, as it reads everything.
        var retry = Retry()

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

    /// What one update read off the actor (#132, N-d).
    struct UpdateRead: Sendable {
        var history: HistoryRead
        /// `nil` when the read failed (logged).
        var metadata: [UUID: SearchFields]?
    }

    /// The history since a token and the text rows it names, or why there is none.
    enum HistoryRead: Sendable {
        case changes(TextChanges)
        /// `SwiftDataError.historyTokenExpired`: a rebuild.
        case expired(code: String)
        /// Any other history error (N5), by its code.
        case failed(code: String)
    }

    /// The text changes since a token, with their rows read.
    struct TextChanges: Sendable {
        var deletes: [PersistentIdentifier]
        var groups: [TextGroup]
        /// The documents whose linked text was read, retried ones included.
        var relinkTried: [PersistentIdentifier]
        /// Those of them whose read failed.
        var relinkFailed: Set<PersistentIdentifier>
        var newest: DefaultHistoryToken?
    }

    /// The rows of one group of text identifiers; `failed` holds the ids whose read failed.
    struct TextGroup: Sendable {
        var ids: [PersistentIdentifier]
        var rows: [SearchStoreReader.TextRow]
        var failed: Set<PersistentIdentifier> = []
    }

    /// Text rows and documents whose read failed, read again with the next history read (#132, N-c).
    struct Retry: Sendable {
        var texts: Set<PersistentIdentifier> = []
        var documents: Set<PersistentIdentifier> = []
    }

    /// The reads of text rows and of the texts documents link, each in a fresh context (#132, N-c): a group whose
    /// read fails is read again id by id, so one failing row does not keep its neighbours out; each error code is
    /// logged once.
    final class StoreReads: Sendable {
        private enum Failure: String {
            case texts, relinkedTexts
        }

        private let container: ModelContainer
        private let readTexts: @Sendable ([PersistentIdentifier], ModelContext) throws -> [SearchStoreReader.TextRow]
        private let readLinkedTexts: @Sendable ([PersistentIdentifier], ModelContext) throws -> [PersistentIdentifier]
        private let loggedErrors = Mutex<Set<String>>([])

        init(
            container: ModelContainer,
            readTexts: (@Sendable ([PersistentIdentifier], ModelContext) throws -> [SearchStoreReader.TextRow])?,
            readLinkedTexts: (@Sendable ([PersistentIdentifier], ModelContext) throws -> [PersistentIdentifier])?
        ) {
            self.container = container
            self.readTexts = readTexts ?? { try SearchStoreReader.texts($0, in: $1) }
            self.readLinkedTexts = readLinkedTexts ?? { try SearchStoreReader.linkedTexts(ofDocuments: $0, in: $1) }
        }

        /// The text rows of `ids` (at most one group).
        func texts(_ ids: [PersistentIdentifier]) -> TextGroup {
            do {
                return TextGroup(ids: ids, rows: try readTexts(ids, ModelContext(container)))
            } catch {
                log(.texts, error)
            }
            var group = TextGroup(ids: ids, rows: [])
            guard ids.count > 1 else {
                group.failed = Set(ids)
                return group
            }
            for id in ids {
                do {
                    group.rows += try readTexts([id], ModelContext(container))
                } catch {
                    log(.texts, error)
                    group.failed.insert(id)
                }
            }
            return group
        }

        /// The text rows that `documents` link now, read in groups, and the documents whose read failed.
        func linkedTexts(ofDocuments documents: [PersistentIdentifier]) -> (
            texts: [PersistentIdentifier], failed: Set<PersistentIdentifier>
        ) {
            var texts: [PersistentIdentifier] = []
            var failed: Set<PersistentIdentifier> = []
            for start in stride(from: 0, to: documents.count, by: SearchStoreReader.groupSize) {
                let group = Array(documents[start..<min(start + SearchStoreReader.groupSize, documents.count)])
                do {
                    texts += try readLinkedTexts(group, ModelContext(container))
                    continue
                } catch {
                    log(.relinkedTexts, error)
                }
                guard group.count > 1 else {
                    failed.formUnion(group)
                    continue
                }
                for id in group {
                    do {
                        texts += try readLinkedTexts([id], ModelContext(container))
                    } catch {
                        log(.relinkedTexts, error)
                        failed.insert(id)
                    }
                }
            }
            return (texts, failed)
        }

        private func log(_ failure: Failure, _ error: any Error) {
            let code = Log.code(of: error)
            guard loggedErrors.withLock({ $0.insert("\(failure.rawValue) \(code)").inserted }) else { return }
            switch failure {
            case .texts:
                Log.search.error("Search could not read texts: \(code, privacy: .public)")
            case .relinkedTexts:
                Log.search.error("Search could not read relinked texts: \(code, privacy: .public)")
            }
        }
    }

    struct Running: Sendable {
        var observation: SaveObservation
        var forwarding: Task<Void, Never>?
        var task: Task<Void, Never>
    }
}
