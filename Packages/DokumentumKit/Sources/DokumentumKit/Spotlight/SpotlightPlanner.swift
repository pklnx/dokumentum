import Foundation

/// What one pass gives Spotlight (#13, plan §3, step 2): pure, so `kit-linux` tests it.
public struct SpotlightPlan: Sendable, Equatable {
    /// Documents to push, by `instanceID`, in a stable order (by the identifier's string).
    public var upserts: [UUID]
    /// Items to remove, in the same order.
    public var deletes: [UUID]

    public init(upserts: [UUID] = [], deletes: [UUID] = []) {
        self.upserts = upserts
        self.deletes = deletes
    }

    public var isEmpty: Bool { upserts.isEmpty && deletes.isEmpty }
}

public enum SpotlightPlanner {
    /// The diff of one pass.
    /// - Parameters:
    ///   - live: the fingerprint of every document that is not in the trash (copies collapsed).
    ///   - indexed: the fingerprints of the items Spotlight has (the state).
    ///   - changed: documents whose text or thumbnail changed (the history): pushed when live, whatever their
    ///     fingerprint.
    ///   - requested: identifiers the system or the app asked about (`reindexSearchableItems`, a stale result): pushed
    ///     when live, deleted otherwise, even without a fingerprint.
    /// - Returns: upserts for new, changed, history-named and requested live documents; deletes for fingerprints with no
    ///   live document (gone, trashed, now a copy's) and for requested identifiers that are not live.
    public static func plan(
        live: [UUID: String], indexed: [UUID: String], changed: Set<UUID> = [], requested: Set<UUID> = []
    ) -> SpotlightPlan {
        var upserts: Set<UUID> = []
        for (id, fingerprint) in live where indexed[id] != fingerprint { upserts.insert(id) }
        for id in changed.union(requested) where live[id] != nil { upserts.insert(id) }
        var deletes = Set(indexed.keys.filter { live[$0] == nil })
        for id in requested where live[id] == nil { deletes.insert(id) }
        return SpotlightPlan(upserts: sorted(upserts), deletes: sorted(deletes))
    }

    /// `ids` in batches of at most `size`, in order.
    public static func deleteBatches(_ ids: [UUID], size: Int = SpotlightLimits.deleteBatch) -> [[UUID]] {
        let size = max(1, size)
        return stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
    }

    /// `items` in batches, in order (`SpotlightBatcher`).
    public static func batches(
        _ items: [SpotlightItem], maxItems: Int = SpotlightLimits.batchItems,
        maxTextBytes: Int = SpotlightLimits.batchTextBytes
    ) -> [[SpotlightItem]] {
        var batcher = SpotlightBatcher(maxItems: maxItems, maxTextBytes: maxTextBytes)
        var batches = items.compactMap { batcher.add($0) }
        if let last = batcher.finish() { batches.append(last) }
        return batches
    }

    private static func sorted(_ ids: Set<UUID>) -> [UUID] { ids.sorted { $0.uuidString < $1.uuidString } }
}

/// Collects items into batches of at most `maxItems` items and `maxTextBytes` bytes of `textContent`; an item larger
/// than `maxTextBytes` on its own is a batch of one.
public struct SpotlightBatcher: Sendable {
    public let maxItems: Int
    public let maxTextBytes: Int
    private var current: [SpotlightItem] = []
    private var bytes = 0

    public init(maxItems: Int = SpotlightLimits.batchItems, maxTextBytes: Int = SpotlightLimits.batchTextBytes) {
        self.maxItems = max(1, maxItems)
        self.maxTextBytes = max(1, maxTextBytes)
    }

    public var isEmpty: Bool { current.isEmpty }

    /// Adds `item`; returns the batch it closed when it does not fit into the current one (it then starts the next).
    public mutating func add(_ item: SpotlightItem) -> [SpotlightItem]? {
        let size = item.textContent.utf8.count
        var closed: [SpotlightItem]?
        if !current.isEmpty, current.count >= maxItems || bytes + size > maxTextBytes {
            closed = current
            current = []
            bytes = 0
        }
        current.append(item)
        bytes += size
        return closed
    }

    /// The last, unfinished batch; `nil` when it is empty.
    public mutating func finish() -> [SpotlightItem]? {
        guard !current.isEmpty else { return nil }
        defer {
            current = []
            bytes = 0
        }
        return current
    }
}
