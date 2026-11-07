import Foundation

/// Why the sidebar's footer says "Sync off" (plan of #3, part 2; the "Sync off: <reason>" text is #2's P1).
/// It is derived from the store the app opened, never from a guess about the iCloud account: a CloudKit store
/// shows no line here, and #31's sync status replaces this later.
public enum SyncOffReason: String, Sendable, CaseIterable {
    /// A build without the CloudKit entitlement (the unsigned Mac build): a local store.
    case noICloudAccess
    /// An in-memory store (`-UITestSeed`, `-UITestEmptyStore`): nothing is saved.
    case sampleData
    /// The build can sync, but the CloudKit store could not be opened, so a local store opened instead.
    case cloudKitStoreFailed

    /// The reason for the store that opened for `choice`; `nil` for a CloudKit store.
    public static func reason(choice: StoreChoice, opened: ArchiveStore.OpenedStore) -> SyncOffReason? {
        switch opened {
        case .cloudKit: nil
        case .inMemory, .sampleData: .sampleData
        case .local, .localFallback: choice == .cloudKit ? .cloudKitStoreFailed : .noICloudAccess
        }
    }
}
