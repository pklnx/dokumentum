import Foundation

/// A Spotlight index as the engine uses it (#13, plan §5), in plain values: `InMemorySpotlightIndex` for every test,
/// every `-UITest*` launch and every in-memory store, part 2's `SystemSpotlightIndex` (the only `import CoreSpotlight`)
/// otherwise (`SpotlightIndexChoice`).
///
/// The rules follow `CSSearchableIndex`'s header:
/// - `index` and `delete` between `beginBatch()` and `endBatch(expected:new:)` are one batch, committed with its client
///   state; `deleteAll()` is not part of a batch;
/// - `endBatch` fails with `SpotlightIndexError.mismatchedClientState` when `expected` is not the stored client state;
/// - `deleteAll()` removes every item of the app and resets the client state to `nil`;
/// - the system may drop everything on its own (storage pressure, a reinstall), the client state included.
public protocol SpotlightIndexing: Sendable {
    /// `false` on a device that does not support indexing: the engine then makes no call at all.
    func isAvailable() async -> Bool
    /// The client state the last successful batch wrote; `nil` after `deleteAll` or a drop by the system.
    func lastClientState() async throws -> Data?
    func beginBatch() async throws
    /// Adds or replaces items by identifier.
    func index(_ items: [SpotlightItem]) async throws
    func delete(identifiers: [String]) async throws
    func deleteAll() async throws
    /// Ends the batch and stores `new` as the client state, only if the stored one is `expected`.
    func endBatch(expected: Data?, new: Data) async throws
}

public enum SpotlightIndexError: Error, Equatable, Sendable {
    /// `endBatch`'s `expected` was not the stored client state (`CSIndexErrorCodeMismatchedClientState`).
    case mismatchedClientState
    /// A call outside its order (an `endBatch` with no batch).
    case noBatch
}
