import DokumentumKit
import DokumentumTestSupport
import Foundation
import Testing

/// The in-memory index follows the header's rules (#13, plan §5): a batch is committed with its client state, a
/// mismatch fails it and changes nothing, `deleteAll` resets the client state, and the hooks fail, hold and drop.
struct InMemorySpotlightIndexTests {
    static func item(_ name: String) -> SpotlightItem {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        return SpotlightItem(
            identifier: name, title: name, contentCreationDate: date, addedDate: date, contentModificationDate: date)
    }

    @Test func aBatchIsCommittedWithItsClientState() async throws {
        let index = InMemorySpotlightIndex()
        try await index.beginBatch()
        try await index.index([Self.item("a"), Self.item("b")])
        #expect(await index.items.isEmpty, "staged until the batch ends")
        try await index.endBatch(expected: nil, new: Data("1".utf8))
        #expect(await Set(index.items.keys) == ["a", "b"])
        #expect(try await index.lastClientState() == Data("1".utf8))

        try await index.beginBatch()
        try await index.delete(identifiers: ["a"])
        try await index.index([Self.item("c")])
        try await index.endBatch(expected: Data("1".utf8), new: Data("2".utf8))
        #expect(await Set(index.items.keys) == ["b", "c"])
        #expect(await index.clientState == Data("2".utf8))
    }

    /// `expected` is not the stored state: the batch fails, and neither its items nor its state are kept.
    @Test func aMismatchFailsTheBatchAndChangesNothing() async throws {
        let index = InMemorySpotlightIndex()
        try await index.beginBatch()
        try await index.index([Self.item("a")])
        await #expect(throws: SpotlightIndexError.mismatchedClientState) {
            try await index.endBatch(expected: Data("other".utf8), new: Data("1".utf8))
        }
        #expect(await index.items.isEmpty)
        #expect(await index.clientState == nil)
    }

    @Test func deleteAllRemovesEverythingAndResetsTheClientState() async throws {
        let index = InMemorySpotlightIndex()
        try await index.beginBatch()
        try await index.index([Self.item("a")])
        try await index.endBatch(expected: nil, new: Data("1".utf8))
        try await index.deleteAll()
        #expect(await index.items.isEmpty)
        #expect(try await index.lastClientState() == nil)
        #expect(await index.count(of: .deleteAll) == 1)
    }

    @Test func theDropHookRemovesItemsAndClientState() async throws {
        let index = InMemorySpotlightIndex()
        try await index.index([Self.item("a")])
        try await index.beginBatch()
        try await index.endBatch(expected: nil, new: Data("1".utf8))
        await index.dropAll()
        #expect(await index.items.isEmpty)
        #expect(await index.clientState == nil)
        #expect(await !index.calls.contains(.deleteAll), "the system dropped them, the app called nothing")
    }

    struct Failure: Error {}

    /// The hook fails a call (recorded, without effect) and holds one until the test releases it.
    @Test func theHookFailsAndHoldsCalls() async throws {
        let held = Checkpoint()
        defer { held.release() }
        let index = InMemorySpotlightIndex(hook: { call in
            if call.operation == .delete { throw Failure() }
            if call.operation == .index { await held.pass() }
        })
        await #expect(throws: Failure.self) { try await index.delete(identifiers: ["a"]) }
        #expect(await index.calls == [.delete(["a"])])

        let indexing = Task { try await index.index([Self.item("b")]) }
        await held.reached()
        #expect(await index.items.isEmpty, "held before its effect")
        held.release()
        try await indexing.value
        #expect(await index.items["b"] != nil)
    }

    @Test func anUnavailableIndexSaysSo() async {
        let index = InMemorySpotlightIndex(isAvailable: false)
        #expect(await !index.isAvailable())
        #expect(await index.calls.isEmpty, "isAvailable is no recorded call")
        await index.setAvailable(true)
        #expect(await index.isAvailable())
    }

    @Test func theStateStoreKeepsTheStateAndFailsThroughItsHook() throws {
        let store = InMemorySpotlightStateStore()
        #expect(try store.load() == nil)
        let state = SpotlightState(storeIdentity: "local", formatVersion: 1, localeIdentifier: "de_DE")
        try store.save(state)
        #expect(try store.load() == state)
        store.setHook { operation in
            if case .save = operation { throw Failure() }
        }
        #expect(throws: Failure.self) {
            try store.save(SpotlightState(storeIdentity: "x", formatVersion: 1, localeIdentifier: ""))
        }
        #expect(try store.load() == state)
        try store.remove()
        #expect(try store.load() == nil)
        #expect(store.saves == 1)
        #expect(store.removals == 1)
    }

    /// The client state names the generation and the batch, so two generations never share one.
    @Test func theNextClientStateNamesGenerationAndBatch() {
        var state = SpotlightState(storeIdentity: "local", formatVersion: 1, localeIdentifier: "de_DE")
        let first = state.nextClientState
        state.batchCount += 1
        #expect(state.nextClientState != first)
        #expect(String(decoding: first, as: UTF8.self) == "\(state.generation.uuidString)/1")
        let other = SpotlightState(storeIdentity: "local", formatVersion: 1, localeIdentifier: "de_DE")
        #expect(other.nextClientState != first)
    }
}
