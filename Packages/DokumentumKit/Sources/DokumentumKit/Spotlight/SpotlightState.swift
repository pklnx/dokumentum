import Foundation
import Synchronization

/// What this device has given Spotlight (#13, plan §3, T3, T4): per device and never synced. Written only after a batch
/// ended successfully (and before a full pass's first batch, as a reset), so its fingerprints list exactly what
/// Spotlight has.
public struct SpotlightState: Codable, Sendable, Equatable {
    /// Where the persistent history was read up to, as the store's encoded `DefaultHistoryToken`.
    public enum HistoryPosition: Codable, Sendable, Hashable {
        /// The start of the history: the store had no transaction yet.
        case start
        case token(Data)
    }

    /// New with every full pass; part of every client state written in it.
    public var generation: UUID
    /// Which store the items came from (`ArchiveStore.opened` and the store's URL): another store means a full pass.
    public var storeIdentity: String
    public var formatVersion: Int
    /// The locale the descriptions were written in.
    public var localeIdentifier: String
    /// The client state of the last batch this device wrote; `nil` after a `deleteAll`.
    public var clientState: Data?
    /// How many batches this generation wrote; part of the next client state.
    public var batchCount: Int
    /// The history read up to; `nil` while a full pass is pending (and in a damaged state, which starts a full pass).
    public var history: HistoryPosition?
    /// The history position taken before a running full pass read the metadata (`T`); set while it is pending.
    public var pendingFullPass: HistoryPosition?
    /// The items Spotlight has: `instanceID` (uppercase string) → fingerprint.
    public var fingerprints: [String: String]

    public init(
        generation: UUID = UUID(), storeIdentity: String, formatVersion: Int, localeIdentifier: String,
        clientState: Data? = nil, batchCount: Int = 0, history: HistoryPosition? = nil,
        pendingFullPass: HistoryPosition? = nil, fingerprints: [String: String] = [:]
    ) {
        self.generation = generation
        self.storeIdentity = storeIdentity
        self.formatVersion = formatVersion
        self.localeIdentifier = localeIdentifier
        self.clientState = clientState
        self.batchCount = batchCount
        self.history = history
        self.pendingFullPass = pendingFullPass
        self.fingerprints = fingerprints
    }

    /// The client state of this generation's next batch.
    public var nextClientState: Data { Data("\(generation.uuidString)/\(batchCount + 1)".utf8) }
}

/// Where the state lives: `SpotlightStateFile` (Core) for the system index, `InMemorySpotlightStateStore` otherwise.
public protocol SpotlightStateStoring: Sendable {
    /// `nil` when there is none (or it cannot be decoded: a full pass writes it again). Throws when it cannot be read.
    func load() throws -> SpotlightState?
    func save(_ state: SpotlightState) throws
    /// Removes the state; nothing to remove is no error.
    func remove() throws
}

/// The state in memory, for every launch that uses `InMemorySpotlightIndex`. `hook` runs before every save and
/// removal and can fail it (tests).
public final class InMemorySpotlightStateStore: SpotlightStateStoring {
    public enum Operation: Sendable, Equatable {
        case save(SpotlightState)
        case remove
    }

    private struct Contents {
        var state: SpotlightState?
        var saves = 0
        var removals = 0
        var hook: (@Sendable (Operation) throws -> Void)?
    }

    private let contents: Mutex<Contents>

    public init(_ state: SpotlightState? = nil, hook: (@Sendable (Operation) throws -> Void)? = nil) {
        contents = Mutex(Contents(state: state, hook: hook))
    }

    public var state: SpotlightState? { contents.withLock { $0.state } }
    /// Successful saves.
    public var saves: Int { contents.withLock { $0.saves } }
    /// Successful removals.
    public var removals: Int { contents.withLock { $0.removals } }

    public func setHook(_ hook: (@Sendable (Operation) throws -> Void)?) { contents.withLock { $0.hook = hook } }

    public func load() throws -> SpotlightState? { contents.withLock { $0.state } }

    public func save(_ state: SpotlightState) throws {
        try contents.withLock { contents in
            try contents.hook?(.save(state))
            contents.state = state
            contents.saves += 1
        }
    }

    public func remove() throws {
        try contents.withLock { contents in
            try contents.hook?(.remove)
            contents.state = nil
            contents.removals += 1
        }
    }
}
