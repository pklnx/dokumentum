import Foundation

/// Why the sidebar's footer says "Sync off" (plan of #3, part 2; the "Sync off: <reason>" text is #2's P1).
/// It is derived from the store the app opened, never from a guess about the iCloud account: a CloudKit store
/// shows no line here, and #31's sync status replaces this later. Kit's `SyncOffReason` is the other half: the
/// account's state behind a CloudKit store, which #31 shows.
public enum StoreSyncOffReason: String, Sendable, CaseIterable {
    /// A build without the CloudKit entitlement (the unsigned Mac build): a local store.
    case noICloudAccess
    /// An in-memory store (`-UITestSeed`, `-UITestEmptyStore`): nothing is saved.
    case sampleData
    /// The build can sync, but the CloudKit store could not be opened, so the same file opened as a local
    /// store.
    case cloudKitStoreFailed
    /// The archive's file could not be opened at all, so the separate fallback store opened (`localFallback`).
    case archiveFailed

    /// The reason for the store that opened for `choice`; `nil` for a CloudKit store.
    public static func reason(choice: StoreChoice, opened: ArchiveStore.OpenedStore) -> StoreSyncOffReason? {
        switch opened {
        case .cloudKit: nil
        case .inMemory, .sampleData: .sampleData
        case .local: choice == .cloudKit ? .cloudKitStoreFailed : .noICloudAccess
        case .localFallback: .archiveFailed
        }
    }
}

/// What the library window needs to know about the store of this launch: the footer's reason and whether the
/// debug command asks before it writes. Decided from the launch's choice and the store that opened, in one
/// place the tests cover, so no call site passes a flag of its own.
public struct LaunchStore: Hashable, Sendable {
    public let choice: StoreChoice
    public let opened: ArchiveStore.OpenedStore

    public init(choice: StoreChoice, opened: ArchiveStore.OpenedStore) {
        self.choice = choice
        self.opened = opened
    }

    /// The footer's "Sync off" reason; `nil` for a CloudKit store.
    public var syncOffReason: StoreSyncOffReason? { StoreSyncOffReason.reason(choice: choice, opened: opened) }

    /// Whether "Add Sample Documents" asks first: for every store on disk, whatever opened. A CloudKit choice
    /// that fell back to `.local` still writes into the synced archive's file, and a local store is the
    /// person's real archive too. Only the in-memory stores of UI tests and screenshots are written without
    /// asking.
    public var asksBeforeAddingSampleDocuments: Bool { choice.isOnDisk }
}
