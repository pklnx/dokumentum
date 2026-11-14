import Foundation

/// A Spotlight index in memory (#13, plan §5): what every test, every `-UITest*` launch and every in-memory store uses,
/// so none of them reaches the system's index. It follows `SpotlightIndexing`'s rules and records every call.
///
/// A batch's `index` and `delete` are staged and applied together with the client state at `endBatch`; a mismatch, a
/// new `beginBatch` or `deleteAll` drops the staged batch. Outside a batch, `index` and `delete` apply at once.
///
/// **Hooks** for tests: `hook` runs before every call except `isAvailable()`, after the call is recorded. It can hold
/// the call (`await checkpoint.pass()`) or fail it (`throw`). `dropAll()` drops everything as the system can, and
/// `setAvailable(false)` reports a device without indexing.
public actor InMemorySpotlightIndex: SpotlightIndexing {
    public enum Operation: String, Sendable, Hashable {
        case lastClientState, beginBatch, index, delete, deleteAll, endBatch
    }

    /// One recorded call.
    public enum Call: Sendable, Hashable {
        case lastClientState
        case beginBatch
        case index([String])
        case delete([String])
        case deleteAll
        case endBatch(expected: Data?, new: Data)

        public var operation: Operation {
            switch self {
            case .lastClientState: .lastClientState
            case .beginBatch: .beginBatch
            case .index: .index
            case .delete: .delete
            case .deleteAll: .deleteAll
            case .endBatch: .endBatch
            }
        }
    }

    public typealias Hook = @Sendable (Call) async throws -> Void

    private struct Batch {
        var upserts: [String: SpotlightItem] = [:]
        var deletes: Set<String> = []
        /// In call order, so an upsert after a delete of the same identifier wins.
        var order: [(identifier: String, isDelete: Bool)] = []
    }

    /// The items Spotlight has, by identifier.
    public private(set) var items: [String: SpotlightItem] = [:]
    public private(set) var clientState: Data?
    public private(set) var calls: [Call] = []
    private var available: Bool
    private var hook: Hook?
    private var batch: Batch?

    public init(isAvailable: Bool = true, hook: Hook? = nil) {
        available = isAvailable
        self.hook = hook
    }

    // MARK: Test controls

    public func setHook(_ hook: Hook?) { self.hook = hook }

    public func setAvailable(_ available: Bool) { self.available = available }

    /// Drops every item and the client state, as the system does under storage pressure or after a reinstall.
    public func dropAll() {
        items = [:]
        clientState = nil
        batch = nil
    }

    /// Forgets the recorded calls.
    public func clearCalls() { calls = [] }

    /// The identifiers of every item `index` was called with, in call order (repeats included).
    public var indexedIdentifiers: [String] {
        calls.flatMap { call -> [String] in
            if case .index(let identifiers) = call { return identifiers }
            return []
        }
    }

    /// The identifiers of every `delete` call, in call order.
    public var deletedIdentifiers: [String] {
        calls.flatMap { call -> [String] in
            if case .delete(let identifiers) = call { return identifiers }
            return []
        }
    }

    /// How often `operation` was called.
    public func count(of operation: Operation) -> Int { calls.filter { $0.operation == operation }.count }

    // MARK: SpotlightIndexing

    public func isAvailable() -> Bool { available }

    public func lastClientState() async throws -> Data? {
        try await record(.lastClientState)
        return clientState
    }

    public func beginBatch() async throws {
        try await record(.beginBatch)
        batch = Batch()
    }

    public func index(_ items: [SpotlightItem]) async throws {
        try await record(.index(items.map(\.identifier)))
        if var batch {
            for item in items {
                batch.upserts[item.identifier] = item
                batch.order.append((item.identifier, false))
            }
            self.batch = batch
        } else {
            for item in items { self.items[item.identifier] = item }
        }
    }

    public func delete(identifiers: [String]) async throws {
        try await record(.delete(identifiers))
        if var batch {
            for identifier in identifiers {
                batch.deletes.insert(identifier)
                batch.order.append((identifier, true))
            }
            self.batch = batch
        } else {
            for identifier in identifiers { items[identifier] = nil }
        }
    }

    public func deleteAll() async throws {
        try await record(.deleteAll)
        items = [:]
        clientState = nil
        batch = nil
    }

    public func endBatch(expected: Data?, new: Data) async throws {
        try await record(.endBatch(expected: expected, new: new))
        guard let batch else { throw SpotlightIndexError.noBatch }
        self.batch = nil
        guard expected == clientState else { throw SpotlightIndexError.mismatchedClientState }
        for (identifier, isDelete) in batch.order {
            items[identifier] = isDelete ? nil : batch.upserts[identifier]
        }
        clientState = new
    }

    private func record(_ call: Call) async throws {
        calls.append(call)
        if let hook { try await hook(call) }
    }
}
