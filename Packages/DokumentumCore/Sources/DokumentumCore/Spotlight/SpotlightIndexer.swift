import DokumentumKit
import Foundation
import SwiftData
import Synchronization

/// Keeps this device's Spotlight index in step with the store (#13, plan §3, T3, T4). An actor on the app's container
/// that only reads the store, with fresh contexts and no `await` while a context is in use; one pass runs at a time and
/// one more waits (events are coalesced, as `SearchIndexer`'s).
///
/// **A pass:**
/// 1. **Check.** Nothing when the index is unavailable. With the setting off: `deleteAll`, then the state is removed,
///    only while there is a state (so later saves make no call). Otherwise the state and `lastClientState()`; a **full
///    pass** when there is no state, the fetched client state is not the one the state recorded (the system dropped the
///    index, a reinstall, a restored backup, a lost state write), the store identity, the item format or the locale
///    changed, the history position is missing or expired, or the system or the setting asked (`reindexAll()`,
///    `setEnabled(true)`). A pending full pass is resumed.
/// 2. **Diff** (`SpotlightPlanner`): upserts for new and changed fingerprints and for the documents the persistent
///    history names (texts, thumbnails, relinks: `StoreSearchHistory.spotlightChanges`); deletes for fingerprints with
///    no live document (gone, trashed, now a copy's).
/// 3. **Batches** of up to 100 items or 4 MB of text and of 500 deletes, each `beginBatch`, `index` or `delete`,
///    `endBatch(expected:new:)`. `expected` is what `lastClientState()` returned at the pass's start (`nil` after a
///    `deleteAll`), then each written batch's new state, never anything from the file (B1). **The state is written only
///    after a batch ended successfully**, with that batch's fingerprints and client state; a failed batch leaves it as
///    it was, so the next event pushes it again. A batch that is begun and then left (a failed `index` or `delete`, a
///    stop) is abandoned (`abandonBatch()`), never left open for the next `beginBatch`. A mismatch makes the next pass
///    a full one. The history position moves on only once every change it named is in a written batch.
/// 4. **Full pass (B1):** the newest history position `T` before the metadata read; `deleteAll`; **before batch 1** a
///    reset state (a new generation, no fingerprints, no history, `pendingFullPass = T`, client state `nil`); every live
///    document in batches; then `history = T` and an incremental pass from `T`. A failure or a quit at any point leaves
///    a state whose fingerprints are exactly what Spotlight has, so the next pass resumes or starts again.
///
/// **Events:** the launch (`start`), `ModelContext.didSave` of any context of the container, the elements of
/// `storeChanges` (the app's `StoreChangeObserver`: remote changes, CloudKit import ends), `setEnabled(_:)`,
/// `reindexAll()`, `refresh(identifiers:)` (the system's re-index of some items, a stale result opened) and
/// `requestPass()` (a scene activation on iOS).
public actor SpotlightIndexer {
    public struct Configuration: Sendable {
        /// Which store the items come from (`storeIdentity(opened:url:)`).
        public var storeIdentity: String
        /// The locale of the descriptions; a change is a full pass.
        public var locale: Locale
        /// "Untitled document", localized.
        public var untitledTitle: String
        /// `SpotlightItem.formatVersion`; a test passes another to bump it.
        public var formatVersion: Int

        public init(
            storeIdentity: String, locale: Locale = .current, untitledTitle: String,
            formatVersion: Int = SpotlightItem.formatVersion
        ) {
            self.storeIdentity = storeIdentity
            self.locale = locale
            self.untitledTitle = untitledTitle
            self.formatVersion = formatVersion
        }

        /// The identity of the store the app opened: what `ArchiveStore.opened` says and the file, so the local fallback
        /// and the archive never mix their items.
        public static func storeIdentity(opened: ArchiveStore.OpenedStore, url: URL?) -> String {
            "\(opened.rawValue)|\(url?.standardizedFileURL.path(percentEncoded: false) ?? "")"
        }
    }

    /// Why a pass started over.
    public enum FullReason: String, Sendable, Equatable {
        case noState, clientStateMismatch, storeIdentity, formatVersion, locale, history, requested
    }

    /// What one pass did (for tests and the log).
    public struct PassReport: Sendable, Equatable {
        public enum Outcome: String, Sendable, Equatable {
            /// Everything planned is in Spotlight and in the state.
            case done
            /// A call, a read or a write failed; the state is as the last written batch left it.
            case failed
            /// The setting was turned off or the indexer stopped during the pass: nothing more was written.
            case stopped
            /// The index is not available: no call at all.
            case unavailable
            /// The setting is off.
            case disabled
        }

        public var outcome: Outcome = .done
        /// Set when this pass started a full pass (and wrote its reset).
        public var full: FullReason?
        /// A pending full pass was resumed.
        public var resumed = false
        public var pushed = 0
        public var deleted = 0
    }

    /// Test hooks; empty in the app.
    public struct Hooks: Sendable {
        /// Runs after every successful write of the state (a batch's, a reset, the history position), with what was
        /// written; a test holds here and stops the indexer, as a quit.
        public var afterStateWrite: (@Sendable (SpotlightState) async -> Void)?
        /// Runs at the end of every pass.
        public var afterPass: (@Sendable (PassReport) async -> Void)?

        public init(
            afterStateWrite: (@Sendable (SpotlightState) async -> Void)? = nil,
            afterPass: (@Sendable (PassReport) async -> Void)? = nil
        ) {
            self.afterStateWrite = afterStateWrite
            self.afterPass = afterPass
        }
    }

    public let container: ModelContainer
    private let index: any SpotlightIndexing
    private let stateStore: any SpotlightStateStoring
    private let settings: any SpotlightSettingStoring
    private let configuration: Configuration
    private let history: StoreSearchHistory
    private let hooks: Hooks

    /// The reports of every pass, in order (for tests).
    public private(set) var reports: [PassReport] = []
    /// Bumped by the setting: a running pass that sees another value stops without writing.
    private var epoch = 0
    /// The system or the setting asked for a full pass, or a batch failed with a mismatch.
    private var fullRequested = false
    /// Identifiers to push or delete in the next pass (`refresh(identifiers:)`).
    private var requested: Set<UUID> = []
    private let running = Mutex<Running?>(nil)

    public init(
        container: ModelContainer, index: any SpotlightIndexing, state: any SpotlightStateStoring,
        settings: any SpotlightSettingStoring, configuration: Configuration, hooks: Hooks = Hooks()
    ) {
        self.container = container
        self.index = index
        stateStore = state
        self.settings = settings
        self.configuration = configuration
        history = StoreSearchHistory(container: container)
        self.hooks = hooks
    }

    // MARK: Events

    /// Runs a pass now (the launch) and after every event. Once only.
    /// - Parameter storeChanges: the debounced changes of the app's `StoreChangeObserver`; `nil` for a store nothing
    ///   else writes (in-memory stores).
    public nonisolated func start(storeChanges: AsyncStream<Void>? = nil) {
        let (events, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let observation = SaveObservation(container: container) { continuation.yield() }
        let forwarding = storeChanges.map { storeChanges in
            Task {
                for await _ in storeChanges { continuation.yield() }
            }
        }
        continuation.yield()
        let task = Task { await self.run(events: events) }
        let previous = running.withLock { running in
            defer {
                running = Running(
                    observation: observation, forwarding: forwarding, task: task, continuation: continuation)
            }
            return running
        }
        precondition(previous == nil, "SpotlightIndexer.start called twice")
    }

    /// Stops following events; a running pass stops before its next write.
    public nonisolated func stop() {
        let current = running.withLock { running in
            defer { running = nil }
            return running
        }
        current?.observation.cancel()
        current?.forwarding?.cancel()
        current?.continuation.finish()
        current?.task.cancel()
    }

    /// One more pass (a scene activation on iOS: a batch that failed while the iPhone was locked is pushed again).
    public nonisolated func requestPass() {
        _ = running.withLock { $0?.continuation.yield() }
    }

    /// The setting: stored, a running pass stops without writing, and the next pass removes everything (off) or runs a
    /// full pass (on).
    public func setEnabled(_ enabled: Bool) {
        settings.setEnabled(enabled)
        epoch += 1
        if enabled { fullRequested = true }
        requestPass()
    }

    /// The system asked for everything again (`CSSearchableIndexDelegate`).
    public func reindexAll() {
        fullRequested = true
        requestPass()
    }

    /// The system asked for some items again, or a result was opened whose document may be gone: each is pushed when
    /// its document is live and deleted otherwise.
    public func refresh(identifiers: Set<UUID>) {
        requested.formUnion(identifiers)
        requestPass()
    }

    private func run(events: AsyncStream<Void>) async {
        for await _ in events {
            if Task.isCancelled { return }
            await runPass()
        }
    }

    // MARK: A pass

    /// One pass, as every event runs it. Tests call it directly (`@testable`) when they need no event.
    /// Internal (#226 review, N2): only `start`'s loop runs passes in the app, one at a time, so two passes never
    /// interleave at their `await`s with stale copies of the state.
    @discardableResult
    func runPass() async -> PassReport {
        var report = PassReport()
        await pass(epoch: epoch, report: &report)
        reports.append(report)
        let kind = report.full.map { "full (\($0.rawValue))" } ?? (report.resumed ? "resumed" : "incremental")
        Log.spotlight.notice(
            """
            Spotlight pass \(kind, privacy: .public): \(report.outcome.rawValue, privacy: .public), \
            \(report.pushed, privacy: .public) pushed, \(report.deleted, privacy: .public) deleted
            """)
        if let afterPass = hooks.afterPass { await afterPass(report) }
        return report
    }

    private func pass(epoch: Int, report: inout PassReport) async {
        guard await index.isAvailable() else {
            report.outcome = .unavailable
            return
        }
        guard settings.isEnabled else {
            await removeEverything(report: &report)
            return
        }
        let stored: SpotlightState?
        let fetched: Data?
        do {
            stored = try stateStore.load()
        } catch {
            return fail("read the state", error, &report)
        }
        do {
            fetched = try await index.lastClientState()
        } catch {
            return fail("read the client state", error, &report)
        }
        guard !isStopped(epoch) else {
            report.outcome = .stopped
            return
        }
        guard let stored, fullReason(stored: stored, fetched: fetched) == nil else {
            let reason = stored.flatMap { fullReason(stored: $0, fetched: fetched) } ?? .noState
            await fullPass(reason, epoch: epoch, report: &report)
            return
        }
        var state = stored
        var expected = fetched
        if state.pendingFullPass != nil {
            report.resumed = true
            guard await finishFullPass(&state, expected: &expected, epoch: epoch, report: &report) else { return }
        }
        await incrementalPass(&state, expected: &expected, epoch: epoch, report: &report)
    }

    private func fullReason(stored: SpotlightState, fetched: Data?) -> FullReason? {
        if fetched != stored.clientState { return .clientStateMismatch }
        if stored.storeIdentity != configuration.storeIdentity { return .storeIdentity }
        if stored.formatVersion != configuration.formatVersion { return .formatVersion }
        if stored.localeIdentifier != configuration.locale.identifier { return .locale }
        if fullRequested { return .requested }
        if stored.history == nil, stored.pendingFullPass == nil { return .history }
        return nil
    }

    /// Step 4: `T`, `deleteAll`, the reset before batch 1, every live document, then the history from `T`.
    private func fullPass(_ reason: FullReason, epoch: Int, report: inout PassReport) async {
        let start: SpotlightState.HistoryPosition
        do {
            start = try position(of: history.newestToken())
        } catch {
            return fail("read the history token", error, &report)
        }
        do {
            try await index.deleteAll()
        } catch {
            return fail("delete all items", error, &report)
        }
        guard !isStopped(epoch) else {
            report.outcome = .stopped
            return
        }
        var state = SpotlightState(
            storeIdentity: configuration.storeIdentity, formatVersion: configuration.formatVersion,
            localeIdentifier: configuration.locale.identifier, clientState: nil, batchCount: 0, history: nil,
            pendingFullPass: start, fingerprints: [:])
        do {
            try await write(state)
        } catch {
            return fail("write the reset state", error, &report)
        }
        fullRequested = false
        report.full = reason
        var expected: Data? = nil
        guard await finishFullPass(&state, expected: &expected, epoch: epoch, report: &report) else { return }
        await incrementalPass(&state, expected: &expected, epoch: epoch, report: &report)
    }

    /// Pushes every live document that has no fingerprint of its own yet (and removes what is no longer live), then
    /// records `T` as the history position. `false` when the pass ended early.
    private func finishFullPass(
        _ state: inout SpotlightState, expected: inout Data?, epoch: Int, report: inout PassReport
    ) async -> Bool {
        guard let start = state.pendingFullPass else { return true }
        let live: [UUID: SpotlightDocument]
        do {
            live = try SpotlightStoreReader.documents(in: ModelContext(container))
        } catch {
            fail("read the metadata", error, &report)
            return false
        }
        let plan = SpotlightPlanner.plan(live: fingerprints(of: live), indexed: indexed(state))
        guard await push(plan, live: live, state: &state, expected: &expected, epoch: epoch, report: &report) else {
            return false
        }
        var next = state
        next.history = start
        next.pendingFullPass = nil
        do {
            try await write(next)
        } catch {
            fail("write the history position", error, &report)
            return false
        }
        state = next
        return !isStopped(epoch, report: &report)
    }

    /// Steps 1–3 from the state's history position.
    private func incrementalPass(
        _ state: inout SpotlightState, expected: inout Data?, epoch: Int, report: inout PassReport
    ) async {
        guard let position = state.history else { return }
        var changed: Set<UUID> = []
        var newest: DefaultHistoryToken?
        var historyRead = true
        do {
            let read = try history.spotlightChanges(since: token(of: position))
            newest = read.newest
            changed = try SpotlightStoreReader.documentIDs(for: read.changes, in: ModelContext(container))
        } catch let error as SwiftDataError where error == .historyTokenExpired {
            Log.spotlight.notice("Spotlight history expired; indexing everything again")
            await fullPass(.history, epoch: epoch, report: &report)
            return
        } catch is PositionError {
            await fullPass(.history, epoch: epoch, report: &report)
            return
        } catch {
            // The metadata diff still runs; the position stays, so the next event reads the history again.
            Log.spotlight.error("Spotlight could not read the history: \(Log.code(of: error), privacy: .public)")
            historyRead = false
        }
        let live: [UUID: SpotlightDocument]
        do {
            live = try SpotlightStoreReader.documents(in: ModelContext(container))
        } catch {
            return fail("read the metadata", error, &report)
        }
        let asked = requested
        let plan = SpotlightPlanner.plan(
            live: fingerprints(of: live), indexed: indexed(state), changed: changed, requested: asked)
        guard await push(plan, live: live, state: &state, expected: &expected, epoch: epoch, report: &report) else {
            return
        }
        requested.subtract(asked)
        guard historyRead, let newest else { return }
        var next = state
        do {
            next.history = .token(try JSONEncoder().encode(newest))
            guard next.history != state.history else { return }
            try await write(next)
        } catch {
            return fail("write the history position", error, &report)
        }
        state = next
    }

    // MARK: Batches

    /// The deletes, then the upserts, in batches; `false` when the pass ended early (a failure, a stop).
    private func push(
        _ plan: SpotlightPlan, live: [UUID: SpotlightDocument], state: inout SpotlightState, expected: inout Data?,
        epoch: Int, report: inout PassReport
    ) async -> Bool {
        for group in SpotlightPlanner.deleteBatches(plan.deletes) {
            guard
                await commit(
                    deletes: group, items: [], live: live, state: &state, expected: &expected, epoch: epoch,
                    report: &report)
            else { return false }
        }
        let strings = SpotlightItem.Strings(untitledTitle: configuration.untitledTitle, locale: configuration.locale)
        var batcher = SpotlightBatcher()
        for start in stride(from: 0, to: plan.upserts.count, by: SpotlightStoreReader.groupSize) {
            guard !isStopped(epoch, report: &report) else { return false }
            let group = Array(plan.upserts[start..<min(start + SpotlightStoreReader.groupSize, plan.upserts.count)])
            let contents: [UUID: SpotlightStoreReader.Contents]
            do {
                contents = try SpotlightStoreReader.contents(of: group, in: ModelContext(container))
            } catch {
                fail("read texts and thumbnails", error, &report)
                return false
            }
            for id in group {
                // Gone since the metadata read: the next pass deletes it.
                guard let document = live[id], let content = contents[id] else { continue }
                let item = SpotlightItem(document, text: content.text, thumbnail: content.thumbnail, strings: strings)
                guard let closed = batcher.add(item) else { continue }
                guard
                    await commit(
                        deletes: [], items: closed, live: live, state: &state, expected: &expected, epoch: epoch,
                        report: &report)
                else { return false }
            }
        }
        if let last = batcher.finish() {
            return await commit(
                deletes: [], items: last, live: live, state: &state, expected: &expected, epoch: epoch,
                report: &report)
        }
        return true
    }

    /// One batch: begin, delete or index, end with `expected`, then the state with this batch's fingerprints and client
    /// state. Nothing is written when a call fails or the pass is stopped before the end.
    private func commit(
        deletes: [UUID], items: [SpotlightItem], live: [UUID: SpotlightDocument], state: inout SpotlightState,
        expected: inout Data?, epoch: Int, report: inout PassReport
    ) async -> Bool {
        guard !isStopped(epoch, report: &report) else { return false }
        let new = state.nextClientState
        let what = deletes.isEmpty ? "push a batch" : "delete a batch"
        do {
            try await index.beginBatch()
        } catch {
            fail(what, error, &report)
            return false
        }
        // From here on the batch is open: every way out before `endBatch` abandons it, so the next `beginBatch` never
        // meets an open batch (the header's rule) and no later `endBatch` can commit what this one staged.
        do {
            if !deletes.isEmpty { try await index.delete(identifiers: deletes.map(\.uuidString)) }
            if !items.isEmpty { try await index.index(items) }
        } catch {
            await index.abandonBatch()
            fail(what, error, &report)
            return false
        }
        guard !isStopped(epoch, report: &report) else {
            await index.abandonBatch()
            return false
        }
        do {
            try await index.endBatch(expected: expected, new: new)
        } catch {
            // A failed `endBatch` has ended the batch.
            if error as? SpotlightIndexError == .mismatchedClientState { fullRequested = true }
            fail(what, error, &report)
            return false
        }
        expected = new
        var next = state
        next.clientState = new
        next.batchCount += 1
        for id in deletes { next.fingerprints[id.uuidString] = nil }
        for item in items {
            guard let id = UUID(uuidString: item.identifier), let document = live[id] else { continue }
            next.fingerprints[item.identifier] = SpotlightFingerprint.of(
                document, formatVersion: configuration.formatVersion)
        }
        do {
            try await write(next)
        } catch {
            // Spotlight has the batch, the file does not: the next check sees a mismatch and starts over.
            fail("write the state", error, &report)
            return false
        }
        state = next
        report.pushed += items.count
        report.deleted += deletes.count
        return true
    }

    // MARK: The setting off

    /// `deleteAll`, then the state removed: only while there is a state (or it cannot be read), so later saves make no
    /// call. A failed delete keeps the state, so the next pass, at the latest the next launch, deletes again.
    private func removeEverything(report: inout PassReport) async {
        report.outcome = .disabled
        let hasState: Bool
        do {
            hasState = try stateStore.load() != nil
        } catch {
            hasState = true
        }
        guard hasState else { return }
        do {
            try await index.deleteAll()
            try stateStore.remove()
        } catch {
            fail("remove everything", error, &report)
            report.outcome = .failed
            return
        }
        Log.spotlight.notice("Spotlight items removed: the setting is off")
    }

    // MARK: Helpers

    private func write(_ state: SpotlightState) async throws {
        try stateStore.save(state)
        if let afterStateWrite = hooks.afterStateWrite { await afterStateWrite(state) }
    }

    private func isStopped(_ epoch: Int) -> Bool { Task.isCancelled || epoch != self.epoch }

    private func isStopped(_ epoch: Int, report: inout PassReport) -> Bool {
        guard isStopped(epoch) else { return false }
        report.outcome = .stopped
        return true
    }

    private func fail(_ what: String, _ error: any Error, _ report: inout PassReport) {
        report.outcome = .failed
        Log.spotlight.error("Spotlight could not \(what, privacy: .public): \(Log.code(of: error), privacy: .public)")
    }

    private func fingerprints(of live: [UUID: SpotlightDocument]) -> [UUID: String] {
        live.mapValues { SpotlightFingerprint.of($0, formatVersion: configuration.formatVersion) }
    }

    private func indexed(_ state: SpotlightState) -> [UUID: String] {
        var result: [UUID: String] = [:]
        for (key, value) in state.fingerprints {
            if let id = UUID(uuidString: key) { result[id] = value }
        }
        return result
    }

    private struct PositionError: Error {}

    private func position(of token: DefaultHistoryToken?) throws -> SpotlightState.HistoryPosition {
        guard let token else { return .start }
        return .token(try JSONEncoder().encode(token))
    }

    private func token(of position: SpotlightState.HistoryPosition) throws -> DefaultHistoryToken? {
        switch position {
        case .start: return nil
        case .token(let data):
            guard let token = try? JSONDecoder().decode(DefaultHistoryToken.self, from: data) else {
                throw PositionError()
            }
            return token
        }
    }

    struct Running: Sendable {
        var observation: SaveObservation
        var forwarding: Task<Void, Never>?
        var task: Task<Void, Never>
        var continuation: AsyncStream<Void>.Continuation
    }
}
