#if DEBUG
    import DokumentumKit
    import Foundation

    /// `-UITestSyncStatus <case>` (Debug builds only; plan of #31, T7): the sidebar footer shows the status of `<case>`
    /// in place of the store's own line, so a UI test and the screenshots of P2 can show states that real CloudKit
    /// cannot produce in a test. Nothing else reads it: no monitor and no data change. An unknown case is ignored.
    enum UITestSyncStatus {
        static let argument = "-UITestSyncStatus"

        /// The cases, by the name the argument takes.
        enum Case: String, CaseIterable {
            case checking, on, notSyncedYet, storageFull, accountChanged, noAccount, restricted, couldNotDetermine
            case temporarilyUnavailable, accountUnavailableFailure, offline, reset, problem
        }

        /// The injected status of this launch, `nil` without the argument or with an unknown case. `now` dates the
        /// last sync five minutes back.
        static func status(arguments: [String], now: Date = Date()) -> SyncStatus? {
            guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1),
                let name = Case(rawValue: arguments[index + 1])
            else { return nil }
            return status(name, now: now)
        }

        static func status(_ name: Case, now: Date) -> SyncStatus {
            let synced = now.addingTimeInterval(-300)
            var status = SyncStatus()
            status.accountState = .available
            status.hasEndedEvent = true
            status.lastImport = synced
            status.lastExport = synced.addingTimeInterval(-60)
            func failed(_ category: CloudErrorCategory, _ code: Int) {
                status.lastError = category
                status.lastErrorCode = code
            }
            switch name {
            case .checking:
                status = SyncStatus()
            case .on:
                break
            case .notSyncedYet:
                status.lastImport = nil
                status.lastExport = nil
            case .storageFull:
                status.isStorageFull = true
                failed(.storageFull, CloudErrorCategory.quotaExceeded)
            case .accountChanged:
                status = SyncStatus()
                status.accountState = .available
                status.accountChanged = true
            case .noAccount: status.accountState = .noAccount
            case .restricted: status.accountState = .restricted
            case .couldNotDetermine: status.accountState = .couldNotDetermine
            case .temporarilyUnavailable: status.accountState = .temporarilyUnavailable
            case .accountUnavailableFailure:
                failed(.accountUnavailable, CloudErrorCategory.accountTemporarilyUnavailable)
            case .offline: failed(.offline, CloudErrorCategory.networkUnavailable)
            case .reset: failed(.reset, CloudErrorCategory.zoneNotFound)
            case .problem: failed(.other, 15)
            }
            return status
        }
    }
#endif
