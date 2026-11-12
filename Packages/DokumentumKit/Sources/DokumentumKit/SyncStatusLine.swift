import Foundation

/// The one line the sidebar footer shows for a CloudKit store (plan of #31, Approach 1, T1). The app turns each case
/// into its catalog text; a store that does not sync shows its own "Sync off" line instead (`StoreSyncOffReason`).
public enum SyncStatusLine: Hashable, Sendable {
    /// "iCloud storage is full: new documents are not uploaded".
    case storageFull
    /// "iCloud account changed".
    case accountChanged
    /// "No iCloud account: …" for `noAccount`, otherwise "Sync off: <reason>".
    case syncOff(SyncOffReason)
    /// "Checking iCloud…": CloudKit has not answered yet (P3).
    case checking
    /// "Offline: changes sync when the connection is back".
    case offline
    /// "iCloud data was reset: …".
    case reset
    /// "iCloud sync problem: retrying automatically".
    case problem
    /// "iCloud sync on · last synced <relative time>", or "· not synced yet" for `nil`.
    case on(lastSynced: Date?)

    /// The line for `status`, by priority: storage full > account changed > sync off (no account, restricted,
    /// temporarily unavailable, could not determine) > checking > offline > reset > other problem > on.
    public init(_ status: SyncStatus) {
        if status.isStorageFull {
            self = .storageFull
        } else if status.accountChanged {
            self = .accountChanged
        } else if let reason = status.syncOffReason {
            self = .syncOff(reason)
        } else if status.isChecking {
            self = .checking
        } else {
            switch status.lastError {
            case .offline: self = .offline
            case .reset: self = .reset
            // A storage-full failure sets `isStorageFull` and an account failure turns sync off, both above; they
            // are listed here only for the switch.
            case .other, .storageFull, .noAccount, .accountUnavailable: self = .problem
            case nil: self = .on(lastSynced: status.lastSync)
            }
        }
    }
}
