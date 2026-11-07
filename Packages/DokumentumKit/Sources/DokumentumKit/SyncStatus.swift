import Foundation

/// The answer of `CKContainer.accountStatus()`, without importing CloudKit.
public enum AccountState: Hashable, Sendable, CaseIterable {
    case available
    case noAccount
    case restricted
    case couldNotDetermine
    case temporarilyUnavailable
}

/// Why sync is off.
public enum SyncOffReason: Hashable, Sendable {
    case noAccount
    case restricted
    case couldNotDetermine
    case temporarilyUnavailable
}

/// The kinds of `NSPersistentCloudKitContainer.Event`, without importing Core Data.
public enum SyncEventKind: Hashable, Sendable {
    case setup
    case importing
    case exporting
}

/// One error of an event's chain, as plain values, so that Kit does not import CloudKit.
public struct ErrorLink: Hashable, Sendable {
    public var domain: String
    public var code: Int

    public init(domain: String, code: Int) {
        self.domain = domain
        self.code = code
    }
}

/// What an event's error means for the person using the app.
public enum CloudErrorCategory: Hashable, Sendable {
    case storageFull
    case noAccount
    case offline
    case reset
    case other

    /// `CKError.errorDomain`.
    static let cloudKitDomain = "CKErrorDomain"
    /// `CKError.Code.partialFailure`.
    static let partialFailure = 2
    /// `CKError.Code.quotaExceeded`.
    static let quotaExceeded = 25

    /// `chain` is flattened by the adapter that knows CloudKit: the error itself, then each
    /// `NSUnderlyingErrorKey` and each partial-failure item. Mirroring errors often arrive in
    /// `NSCocoaErrorDomain` with the `CKError` underneath (shape unverified), so the whole chain is
    /// searched. The first CloudKit code found decides, except that a partial failure says nothing by
    /// itself: its items come in no fixed order, so it means storage full when any later link is
    /// `quotaExceeded`, and otherwise the first code after it decides.
    public static func classify(_ chain: [ErrorLink]) -> CloudErrorCategory {
        let codes = chain.filter { $0.domain == cloudKitDomain }.map(\.code)
        guard let first = codes.first else { return .other }
        if first == partialFailure, codes.contains(quotaExceeded) { return .storageFull }
        guard let deciding = codes.first(where: { $0 != partialFailure }) else { return .other }
        switch deciding {
        case quotaExceeded: return .storageFull
        case 9: return .noAccount  // notAuthenticated
        case 3, 4: return .offline  // networkUnavailable, networkFailure
        case 26, 28: return .reset  // zoneNotFound, userDeletedZone
        default: return .other
        }
    }
}

/// What the sync status view shows.
public struct SyncStatus: Hashable, Sendable {
    public var accountState: AccountState = .couldNotDetermine
    /// The end of the last successful import.
    public var lastImport: Date?
    /// The end of the last successful export.
    public var lastExport: Date?
    /// Stays set until a later export succeeds.
    public var isStorageFull = false
    /// The category of the last failed event; a later success of any kind clears it.
    public var lastError: CloudErrorCategory?
    /// Stays set for the rest of the session.
    public var accountChanged = false

    public init() {}

    public var isSyncEnabled: Bool { syncOffReason == nil }

    /// `nil` while sync is on.
    public var syncOffReason: SyncOffReason? {
        switch accountState {
        case .available: nil
        case .noAccount: .noAccount
        case .restricted: .restricted
        case .couldNotDetermine: .couldNotDetermine
        case .temporarilyUnavailable: .temporarilyUnavailable
        }
    }
}

/// What can change the sync status.
public enum SyncStatusInput: Hashable, Sendable {
    case accountStatus(AccountState)
    /// One `NSPersistentCloudKitContainer.Event`: `ended` is `nil` while it runs. `errorChain` is flattened
    /// as `CloudErrorCategory.classify` expects it, and is read only when the event failed.
    case event(kind: SyncEventKind, started: Date, ended: Date?, succeeded: Bool, errorChain: [ErrorLink])
    case accountChanged
}

/// Turns the inputs into a status. Pure, and changes no data.
public enum SyncStatusReducer {
    public static func reduce(_ status: SyncStatus, _ input: SyncStatusInput) -> SyncStatus {
        var status = status
        switch input {
        case .accountStatus(let state):
            status.accountState = state
        case .accountChanged:
            // What was known belongs to the old account: only the fact that it changed stays.
            status.accountChanged = true
            status.lastImport = nil
            status.lastExport = nil
            status.isStorageFull = false
            status.lastError = nil
        case .event(let kind, _, let ended, let succeeded, let errorChain):
            guard let ended else { break }
            if succeeded {
                status.lastError = nil
                switch kind {
                case .setup:
                    break
                case .importing:
                    status.lastImport = later(status.lastImport, ended)
                case .exporting:
                    status.lastExport = later(status.lastExport, ended)
                    status.isStorageFull = false
                }
            } else {
                let category = CloudErrorCategory.classify(errorChain)
                status.lastError = category
                if category == .storageFull { status.isStorageFull = true }
            }
        }
        return status
    }

    private static func later(_ date: Date?, _ other: Date) -> Date {
        date.map { max($0, other) } ?? other
    }
}
