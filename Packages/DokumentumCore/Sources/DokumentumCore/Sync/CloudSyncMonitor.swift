import DokumentumKit
import Foundation
import Observation

/// The sync status of a CloudKit store (plan of #31, Approach 1): it feeds Kit's `SyncStatusReducer` from the
/// mirroring's events and from the account, and keeps the last events for the Sync lab. It changes no data.
///
/// - **Events:** every `NSPersistentCloudKitContainer` event, mapped on the posting thread (`CloudSyncEvents`) and
///   handled here in posting order.
/// - **The account:** `accountStatus()` and `userRecordID()` at start, after each account-change notification, when
///   the scene becomes active (`sceneBecameActive()`), and after an event failed with `notAuthenticated` (9) or
///   `accountTemporarilyUnavailable` (36). Every request has a generation; an answer to an older request than the
///   newest is dropped, so a slow first answer cannot overwrite a later one.
/// - **An account change** is a change of the CloudKit user: a non-nil `userRecordID` that differs from the last non-nil
///   one seen in this process. A `nil` answer never replaces it, so a real switch, which passes through "no account"
///   (A → nil → B), is shown at the sign-in, and A → nil → A is no change. Sign-out and the first sign-in are left to
///   the account status. The ID is kept in memory only: a switch while the app does not run is not shown as a change.
@MainActor
@Observable
public final class CloudSyncMonitor {
    /// What the monitor did, for tests to wait on.
    public enum Update: Hashable, Sendable {
        /// An account answer arrived; `applied` is `false` when a newer request made it stale.
        case account(applied: Bool)
        /// An event was handled.
        case event
    }

    /// How many events the log keeps (T6).
    public static let eventLogLimit = 50

    /// The status the footer and the detail view show.
    public private(set) var status = SyncStatus()
    /// The last `eventLogLimit` events, oldest first; an event's end replaces its start. In memory only.
    public private(set) var events: [CloudSyncEvent] = []
    /// The CloudKit user's record name of the last answer that had one, for the Sync lab.
    public private(set) var lastKnownUserRecordID: String?

    @ObservationIgnored private let provider: any AccountStatusProviding
    @ObservationIgnored private var requestedGeneration = 0
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let didUpdate: (Update) -> Void

    /// The monitor for the store this launch opened, started; `nil` for every store that does not sync, and then
    /// `makeProvider` is not called, so no CloudKit object exists (T3).
    public static func forStore(
        _ opened: ArchiveStore.OpenedStore,
        makeProvider: () -> any AccountStatusProviding,
        center: NotificationCenter = .default,
        accountChangeNotifications: [Notification.Name] = CloudKitAccountStatus.accountChangeNotifications,
        didUpdate: @escaping (Update) -> Void = { _ in }
    ) -> CloudSyncMonitor? {
        guard opened == .cloudKit else { return nil }
        return CloudSyncMonitor(
            provider: makeProvider(),
            events: CloudSyncEvents.stream(center: center),
            accountChanges: NotificationStream.make(names: accountChangeNotifications, center: center) { _ in () },
            didUpdate: didUpdate)
    }

    /// Starts at once: asks for the account and follows both streams until it is released.
    public init(
        provider: any AccountStatusProviding,
        events: AsyncStream<CloudSyncEvent>,
        accountChanges: AsyncStream<Void>,
        didUpdate: @escaping (Update) -> Void = { _ in }
    ) {
        self.provider = provider
        self.didUpdate = didUpdate
        tasks.append(
            Task { [weak self] in
                for await event in events { self?.receive(event) }
            })
        tasks.append(
            Task { [weak self] in
                for await _ in accountChanges { self?.refreshAccount() }
            })
        refreshAccount()
    }

    isolated deinit {
        for task in tasks { task.cancel() }
    }

    /// The scene became active: the account may have changed while the app was in the background.
    public func sceneBecameActive() {
        refreshAccount()
    }

    /// Asks for the account status and the user record ID, as one request with a new generation.
    public func refreshAccount() {
        requestedGeneration += 1
        let generation = requestedGeneration
        let provider = provider
        // Not kept: a request ends with its answer, and an answer after the monitor is gone goes nowhere.
        Task { [weak self] in
            let state = await provider.accountStatus()
            let userRecordID = await provider.userRecordID()
            self?.answer(generation: generation, state: state, userRecordID: userRecordID)
        }
    }

    private func answer(generation: Int, state: AccountState, userRecordID: String?) {
        guard generation == requestedGeneration else {
            didUpdate(.account(applied: false))
            return
        }
        if let userRecordID {
            if let last = lastKnownUserRecordID, last != userRecordID {
                Log.sync.notice("iCloud account changed")
                status = SyncStatusReducer.reduce(status, .accountChanged)
            }
            lastKnownUserRecordID = userRecordID
        }
        if status.accountState != state {
            Log.sync.notice("Account state: \(String(describing: state), privacy: .public)")
        }
        status = SyncStatusReducer.reduce(status, .accountStatus(state))
        didUpdate(.account(applied: true))
    }

    /// Handles one event, in posting order.
    public func receive(_ event: CloudSyncEvent) {
        if let index = events.firstIndex(where: { $0.identifier == event.identifier }) {
            events[index] = event
        } else {
            events.append(event)
            if events.count > Self.eventLogLimit { events.removeFirst(events.count - Self.eventLogLimit) }
        }
        status = SyncStatusReducer.reduce(status, event.input)
        if event.ended != nil, !event.succeeded {
            let category = CloudErrorCategory.classify(event.errorChain)
            let codes = event.errorChain.map { "\($0.domain) \($0.code)" }.joined(separator: ", ")
            Log.sync.error(
                "Sync event failed: \(String(describing: event.kind), privacy: .public), \(codes, privacy: .public)")
            if category == .noAccount || category == .accountUnavailable { refreshAccount() }
        }
        didUpdate(.event)
    }
}
