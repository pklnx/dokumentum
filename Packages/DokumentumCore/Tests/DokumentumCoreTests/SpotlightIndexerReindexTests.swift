import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// Full re-indexing (#13, part 1; plan §3 steps 1 and 4, T4, B1): every trigger from a fully indexed state of 250
/// documents (three batches), and what a failure or a quit in the middle of a full pass leaves: never a document left
/// out for good.
struct SpotlightIndexerReindexTests {
    static let count = 250

    /// 250 documents on a store on disk (the expired-history trigger deletes history), fully indexed.
    struct Indexed {
        let store: TemporaryStore
        let harness: SpotlightHarness
        let ids: [UUID]
        let state: SpotlightState

        init(index: InMemorySpotlightIndex = InMemorySpotlightIndex()) async throws {
            store = try TemporaryStore()
            harness = try SpotlightHarness(container: store.container, index: index)
            ids = try SpotlightStore.insert(count: SpotlightIndexerReindexTests.count, in: store.container)
            let report = await harness.indexer().runPass()
            #expect(report.full == .noState)
            #expect(report.pushed == SpotlightIndexerReindexTests.count)
            let batches = await harness.index.calls.compactMap { call -> Int? in
                if case .index(let ids) = call { ids.count } else { nil }
            }
            #expect(batches == [100, 100, 50])
            state = try #require(harness.state.state)
            #expect(state.fingerprints.count == SpotlightIndexerReindexTests.count)
            #expect(state.pendingFullPass == nil && state.history != nil)
            await harness.index.clearCalls()
        }

        func remove() { store.remove() }
    }

    enum Trigger: String, CaseIterable, Sendable {
        case systemDrop, storeIdentity, formatVersion, locale, expiredHistory, reindexAll, settingTurnedOn
    }

    /// Prepares `trigger` and returns the next launch's indexer (or the same one, for a request).
    static func arm(_ trigger: Trigger, on indexed: Indexed, hooks: SpotlightIndexer.Hooks = .init()) async throws
        -> SpotlightIndexer
    {
        let harness = indexed.harness
        switch trigger {
        case .systemDrop:
            await harness.index.dropAll()
            return harness.indexer(hooks: hooks)
        case .storeIdentity:
            return harness.indexer(
                SpotlightHarness.configuration(storeIdentity: "local fallback|Other.store"), hooks: hooks)
        case .formatVersion:
            return harness.indexer(
                SpotlightHarness.configuration(formatVersion: SpotlightItem.formatVersion + 1), hooks: hooks)
        case .locale:
            return harness.indexer(SpotlightHarness.configuration(locale: "de_DE"), hooks: hooks)
        case .expiredHistory:
            try SpotlightStore.setText("nach dem Token", of: indexed.ids[0], in: indexed.store.container)
            let context = ModelContext(indexed.store.container)
            let newest = try #require(
                try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()).last?.token)
            try context.deleteHistory(
                HistoryDescriptor<DefaultHistoryTransaction>(predicate: #Predicate { $0.token <= newest }))
            return harness.indexer(hooks: hooks)
        case .reindexAll:
            let indexer = harness.indexer(hooks: hooks)
            await indexer.reindexAll()
            return indexer
        case .settingTurnedOn:
            let indexer = harness.indexer(hooks: hooks)
            await indexer.setEnabled(false)
            await indexer.runPass()
            await harness.index.clearCalls()
            await indexer.setEnabled(true)
            return indexer
        }
    }

    static func reason(of trigger: Trigger) -> SpotlightIndexer.FullReason {
        switch trigger {
        case .systemDrop: .clientStateMismatch
        case .storeIdentity: .storeIdentity
        case .formatVersion: .formatVersion
        case .locale: .locale
        case .expiredHistory: .history
        case .reindexAll: .requested
        // Off removed the state: on starts from no state.
        case .settingTurnedOn: .noState
        }
    }

    /// Each trigger: `deleteAll` once, every live document pushed, a new generation.
    @Test(arguments: Trigger.allCases)
    func aTriggerReindexesEverything(trigger: Trigger) async throws {
        let indexed = try await Indexed()
        defer { indexed.remove() }
        let indexer = try await Self.arm(trigger, on: indexed)
        let report = await indexer.runPass()
        #expect(report.outcome == .done)
        #expect(report.full == Self.reason(of: trigger))
        #expect(await indexed.harness.index.count(of: .deleteAll) == 1)
        #expect(Set(await indexed.harness.pushed()) == Set(indexed.ids))
        #expect(Set(await indexed.harness.items().keys) == Set(indexed.ids))
        let state = try #require(indexed.harness.state.state)
        #expect(state.generation != indexed.state.generation)
        #expect(state.fingerprints.count == Self.count)
        #expect(state.pendingFullPass == nil && state.history != nil)
        if trigger == .locale {
            #expect(try #require(await indexed.harness.items()[indexed.ids[0]]).contentDescription.contains("."))
        }
        if trigger == .expiredHistory {
            #expect(try #require(await indexed.harness.items()[indexed.ids[0]]).textContent == "nach dem Token")
        }
    }

    /// An untouched state and index: nothing to do, no `deleteAll`.
    @Test func noTriggerNoFullPass() async throws {
        let indexed = try await Indexed()
        defer { indexed.remove() }
        let report = await indexed.harness.indexer().runPass()
        #expect(report.full == nil)
        #expect(await indexed.harness.index.calls == [.lastClientState])
    }

    /// B1: `deleteAll` succeeded and batch 1 fails. The state has the new generation and no fingerprints, so the next
    /// event pushes every live document.
    @Test(arguments: [Trigger.formatVersion, .reindexAll])
    func batchOneFailsAndTheNextEventPushesEverything(trigger: Trigger) async throws {
        let failing = HookSwitch()
        let indexed = try await Indexed(index: InMemorySpotlightIndex(hook: failing.hook))
        defer { indexed.remove() }
        let indexer = try await Self.arm(trigger, on: indexed)
        failing.fail([.endBatch])
        let failed = await indexer.runPass()
        #expect(failed.outcome == .failed)
        #expect(await indexed.harness.items().isEmpty, "deleteAll ran, batch 1 did not end")
        let reset = try #require(indexed.harness.state.state)
        #expect(reset.generation != indexed.state.generation)
        #expect(reset.fingerprints.isEmpty)
        #expect(reset.pendingFullPass != nil)
        #expect(reset.clientState == nil)

        failing.clear()
        await indexed.harness.index.clearCalls()
        let next = await indexer.runPass()
        #expect(next.outcome == .done)
        #expect(next.resumed)
        #expect(Set(await indexed.harness.pushed()) == Set(indexed.ids))
        #expect(Set(await indexed.harness.items().keys) == Set(indexed.ids))
        #expect(indexed.harness.state.state?.fingerprints.count == Self.count)
    }

    /// B1: batch 1 succeeds and the app quits (the indexer stops at the hook after batch 1's state write). The next
    /// launch resumes the pending pass and pushes exactly the documents batch 1 did not; then Spotlight holds every live
    /// document and the history position is the pass's `T`.
    @Test(arguments: [Trigger.formatVersion, .reindexAll])
    func aQuitAfterBatchOneResumesWithTheRest(trigger: Trigger) async throws {
        let indexed = try await Indexed()
        defer { indexed.remove() }
        let afterBatchOne = Checkpoint()
        defer { afterBatchOne.release() }
        let hooks = SpotlightIndexer.Hooks(afterStateWrite: { state in
            if state.pendingFullPass != nil, state.batchCount == 1 { await afterBatchOne.pass() }
        })
        let quitting = try await Self.arm(trigger, on: indexed, hooks: hooks)
        let t = try #require(try StoreSearchHistory(container: indexed.store.container).newestToken())
        let run = Task { await quitting.runPass() }
        await afterBatchOne.reached()
        run.cancel()
        afterBatchOne.release()
        let quit = await run.value
        #expect(quit.outcome == .stopped)
        let firstBatch = Set(await indexed.harness.pushed())
        #expect(firstBatch.count == 100)
        #expect(Set(indexed.harness.fingerprinted()) == firstBatch)

        await indexed.harness.index.clearCalls()
        let next = await indexed.harness.indexer(
            trigger == .formatVersion
                ? SpotlightHarness.configuration(formatVersion: SpotlightItem.formatVersion + 1)
                : SpotlightHarness.configuration()
        ).runPass()
        #expect(next.resumed)
        #expect(next.full == nil)
        #expect(await indexed.harness.index.count(of: .deleteAll) == 0)
        let rest = await indexed.harness.pushed()
        #expect(rest.count == Self.count - 100)
        #expect(Set(rest) == Set(indexed.ids).subtracting(firstBatch))
        #expect(Set(await indexed.harness.items().keys) == Set(indexed.ids))
        let state = try #require(indexed.harness.state.state)
        #expect(state.pendingFullPass == nil)
        guard case .token(let data)? = state.history else {
            Issue.record("no history token: \(String(describing: state.history))")
            return
        }
        #expect(try JSONDecoder().decode(DefaultHistoryToken.self, from: data) == t)
    }

    /// B1: the reset write before batch 1 fails. No batch is pushed, and the next event starts a full pass again.
    @Test func aFailedResetWritePushesNoBatchAndStartsOver() async throws {
        let indexed = try await Indexed()
        defer { indexed.remove() }
        indexed.harness.state.setHook { operation in
            if case .save(let state) = operation, state.pendingFullPass != nil, state.fingerprints.isEmpty {
                throw SpotlightTestFailure()
            }
        }
        let bumped = SpotlightHarness.configuration(formatVersion: SpotlightItem.formatVersion + 1)
        let failed = await indexed.harness.indexer(bumped).runPass()
        #expect(failed.outcome == .failed)
        #expect(await indexed.harness.index.calls == [.lastClientState, .deleteAll])
        #expect(indexed.harness.state.state == indexed.state)

        indexed.harness.state.setHook(nil)
        await indexed.harness.index.clearCalls()
        let next = await indexed.harness.indexer(bumped).runPass()
        #expect(next.full == .clientStateMismatch, "the file still names the old client state; the index has none")
        #expect(Set(await indexed.harness.items().keys) == Set(indexed.ids))
    }

    /// After a system drop (client state `nil`), the first batch passes `nil` as `expected`, not anything from the
    /// file, and succeeds; each following batch passes the previous batch's new state.
    @Test func afterASystemDropTheFirstBatchExpectsNil() async throws {
        let indexed = try await Indexed()
        defer { indexed.remove() }
        await indexed.harness.index.dropAll()
        let report = await indexed.harness.indexer().runPass()
        #expect(report.outcome == .done)
        let ends = await indexed.harness.index.calls.compactMap { call -> (Data?, Data)? in
            if case .endBatch(let expected, let new) = call { (expected, new) } else { nil }
        }
        #expect(ends.count == 3)
        #expect(ends.first?.0 == nil)
        for (previous, next) in zip(ends, ends.dropFirst()) { #expect(next.0 == previous.1) }
        #expect(await indexed.harness.index.clientState == ends.last?.1)
        #expect(indexed.harness.state.state?.clientState == ends.last?.1)
    }

    /// From no state at all (a first launch): a full pass.
    @Test func noStateIsAFullPass() async throws {
        let harness = try SpotlightHarness()
        let ids = try SpotlightStore.insert(count: 3, in: harness.container)
        let report = await harness.indexer().runPass()
        #expect(report.full == .noState)
        #expect(await harness.index.count(of: .deleteAll) == 1)
        #expect(Set(await harness.items().keys) == Set(ids))
    }
}
