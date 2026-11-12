import CloudKit
import DokumentumKit
import Foundation

/// The two questions the sync status asks CloudKit about the account (plan of #31, T3, T4). Tests use a stub; the app
/// uses `CloudKitAccountStatus`, which is created only for a CloudKit store.
public protocol AccountStatusProviding: Sendable {
    /// `CKContainer.accountStatus()`; an error answers `couldNotDetermine`.
    func accountStatus() async -> AccountState
    /// The record name of `CKContainer.userRecordID()`: who the CloudKit user is. `nil` without an account or when
    /// it could not be read.
    func userRecordID() async -> String?
}

/// The CloudKit container of the archive, behind `AccountStatusProviding`. Never created for a store that does not
/// sync: `CKContainer(identifier:)` traps in a build without the entitlement (the unsigned Mac build).
public struct CloudKitAccountStatus: AccountStatusProviding {
    public static let containerIdentifier = "iCloud.space.pklnx.Dokumentum"

    /// The notifications after which the account is asked again: CloudKit's account change, and the iCloud identity
    /// change (sign-in, sign-out). The identity token itself is not read: it is the iCloud Drive identity, which these
    /// builds do not have (plan of #31, Revision 1, B1).
    public static let accountChangeNotifications: [Notification.Name] = [
        .CKAccountChanged, .NSUbiquityIdentityDidChange,
    ]

    private let container: CKContainer

    public init() {
        container = CKContainer(identifier: Self.containerIdentifier)
    }

    public func accountStatus() async -> AccountState {
        do {
            return Self.state(of: try await container.accountStatus())
        } catch {
            Log.sync.error("Account status failed: \(Log.code(of: error), privacy: .public)")
            return .couldNotDetermine
        }
    }

    public func userRecordID() async -> String? {
        do {
            return try await container.userRecordID().recordName
        } catch {
            // Without an account this is `notAuthenticated` (9): expected, and the status says so.
            Log.sync.notice("User record ID not read: \(Log.code(of: error), privacy: .public)")
            return nil
        }
    }

    public static func state(of status: CKAccountStatus) -> AccountState {
        switch status {
        case .available: .available
        case .noAccount: .noAccount
        case .restricted: .restricted
        case .temporarilyUnavailable: .temporarilyUnavailable
        case .couldNotDetermine: .couldNotDetermine
        @unknown default: .couldNotDetermine
        }
    }
}
