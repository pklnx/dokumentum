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
    /// `accountTemporarilyUnavailable` (36): the account needs attention in Settings (plan of #31, T2).
    case accountUnavailable
    case offline
    case reset
    case other

    /// `CKError.errorDomain`.
    public static let cloudKitDomain = "CKErrorDomain"
    /// `CKError.Code.partialFailure`.
    public static let partialFailure = 2
    /// `CKError.Code.networkUnavailable`, `CKError.Code.networkFailure`.
    public static let networkUnavailable = 3
    public static let networkFailure = 4
    /// `CKError.Code.notAuthenticated`.
    public static let notAuthenticated = 9
    /// `CKError.Code.quotaExceeded`.
    public static let quotaExceeded = 25
    /// `CKError.Code.zoneNotFound`, `CKError.Code.userDeletedZone`.
    public static let zoneNotFound = 26
    public static let userDeletedZone = 28
    /// `CKError.Code.accountTemporarilyUnavailable`.
    public static let accountTemporarilyUnavailable = 36

    /// `chain` is flattened by the adapter that knows CloudKit: the error itself, then each
    /// `NSUnderlyingErrorKey` and each partial-failure item. Mirroring errors often arrive in
    /// `NSCocoaErrorDomain` with the `CKError` underneath (shape unverified), so the whole chain is
    /// searched. The first CloudKit code found decides, except that a partial failure says nothing by
    /// itself: its items come in no fixed order, so it means storage full when any later link is
    /// `quotaExceeded`, and otherwise the first code after it decides.
    public static func classify(_ chain: [ErrorLink]) -> CloudErrorCategory {
        decide(chain).category
    }

    /// The category and the CloudKit code that decided it (`nil` when no CloudKit code did), for the detail
    /// view's "CKError 25".
    public static func decide(_ chain: [ErrorLink]) -> (category: CloudErrorCategory, code: Int?) {
        let codes = chain.filter { $0.domain == cloudKitDomain }.map(\.code)
        guard let first = codes.first else { return (.other, nil) }
        if first == partialFailure, codes.contains(quotaExceeded) { return (.storageFull, quotaExceeded) }
        guard let deciding = codes.first(where: { $0 != partialFailure }) else { return (.other, first) }
        let category: CloudErrorCategory =
            switch deciding {
            case quotaExceeded: .storageFull
            case notAuthenticated: .noAccount
            case accountTemporarilyUnavailable: .accountUnavailable
            case networkUnavailable, networkFailure: .offline
            case zoneNotFound, userDeletedZone: .reset
            default: .other
            }
        return (category, deciding)
    }
}

/// What the sync status view shows.
public struct SyncStatus: Hashable, Sendable {
    /// `nil` until CloudKit answered for the first time ("not known yet", plan of #31, T1): a launch must not
    /// show "Sync off" while the answer is on its way.
    public var accountState: AccountState?
    /// The end of the last successful import.
    public var lastImport: Date?
    /// The end of the last successful export.
    public var lastExport: Date?
    /// Stays set until a later export succeeds.
    public var isStorageFull = false
    /// The category of the last failed event; a later success of any kind clears it.
    public var lastError: CloudErrorCategory?
    /// The CloudKit code behind `lastError`, when one decided it.
    public var lastErrorCode: Int?
    /// Stays set for the rest of the session.
    public var accountChanged = false
    /// Whether any event has ended: with an account answer, it ends "Checking iCloud…" (P3).
    public var hasEndedEvent = false

    public init() {}

    public var isSyncEnabled: Bool { syncOffReason == nil }

    /// `nil` while sync is on or the account is not known yet. A failed event that says the account is gone
    /// (`noAccount`, `accountUnavailable`) turns sync off with that reason until the account is asked again and
    /// answers otherwise, also while the last answer still says `available` (plan of #31, Revision 1, note 1).
    public var syncOffReason: SyncOffReason? {
        switch accountState {
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .couldNotDetermine: return .couldNotDetermine
        case .temporarilyUnavailable: return .temporarilyUnavailable
        case .available, nil: break
        }
        switch lastError {
        case .noAccount: return .noAccount
        case .accountUnavailable: return .temporarilyUnavailable
        default: return nil
        }
    }

    /// Whether CloudKit has said nothing yet: no account answer and no ended event (P3).
    public var isChecking: Bool { accountState == nil && !hasEndedEvent }

    /// The later of the last successful import and export.
    public var lastSync: Date? {
        switch (lastImport, lastExport) {
        case (let imported?, let exported?): max(imported, exported)
        case (let imported?, nil): imported
        case (nil, let exported?): exported
        case (nil, nil): nil
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
            // The new answer decides the account: an account error of an earlier event no longer stands
            // (Revision 1, note 1).
            if status.lastError == .noAccount || status.lastError == .accountUnavailable {
                status.lastError = nil
                status.lastErrorCode = nil
            }
        case .accountChanged:
            // What was known belongs to the old account: only the fact that it changed stays.
            status.accountChanged = true
            status.lastImport = nil
            status.lastExport = nil
            status.isStorageFull = false
            status.lastError = nil
            status.lastErrorCode = nil
        case .event(let kind, _, let ended, let succeeded, let errorChain):
            guard let ended else { break }
            status.hasEndedEvent = true
            if succeeded {
                status.lastError = nil
                status.lastErrorCode = nil
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
                let (category, code) = CloudErrorCategory.decide(errorChain)
                status.lastError = category
                status.lastErrorCode = code
                if category == .storageFull { status.isStorageFull = true }
            }
        }
        return status
    }

    private static func later(_ date: Date?, _ other: Date) -> Date {
        date.map { max($0, other) } ?? other
    }
}
