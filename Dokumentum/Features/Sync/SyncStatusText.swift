import DokumentumCore
import DokumentumKit
import Foundation

/// The words of the sync status (plan of #31, P2): every line of the footer and every value of the detail view, from
/// the catalog. #2's P1 texts keep their English.
enum SyncStatusText {
    /// The footer's line for a CloudKit store. `now` and `locale` make the relative time of "last synced".
    static func line(_ line: SyncStatusLine, now: Date, locale: Locale) -> LocalizedStringResource {
        switch line {
        case .storageFull: "iCloud storage is full: new documents are not uploaded"
        case .accountChanged: "iCloud account changed"
        case .syncOff(let reason):
            if let words = self.reason(reason) {
                "Sync off: \(words)"
            } else {
                "No iCloud account: documents stay on this device"
            }
        case .checking: "Checking iCloud…"
        case .offline: "Offline: changes sync when the connection is back"
        case .reset: "iCloud data was reset: documents on this device are uploaded again"
        case .problem: "iCloud sync problem: retrying automatically"
        case .on(let lastSynced?): "iCloud sync on · last synced \(relative(lastSynced, now: now, locale: locale))"
        case .on(nil): "iCloud sync on · not synced yet"
        }
    }

    /// The footer's line for a store that does not sync (#2's P1 "Sync off: <reason>", reasons PQ13 of #3).
    static func storeLine(_ reason: StoreSyncOffReason) -> LocalizedStringResource {
        "Sync off: \(storeReason(reason))"
    }

    /// The reason's words in "Sync off: <reason>" for a store that does not sync.
    static func storeReason(_ reason: StoreSyncOffReason) -> LocalizedStringResource {
        switch reason {
        case .noICloudAccess: "this build has no iCloud access"
        case .sampleData: "sample data, not saved"
        case .cloudKitStoreFailed: "the iCloud store could not be opened"
        case .archiveFailed: "the archive could not be opened"
        }
    }

    /// The reason's words in "Sync off: <reason>" for the account behind a CloudKit store; `nil` for `noAccount`,
    /// which has a line of its own (P1).
    static func reason(_ reason: SyncOffReason) -> LocalizedStringResource? {
        switch reason {
        case .noAccount: nil
        case .restricted: "iCloud is restricted on this device"
        case .couldNotDetermine: "the iCloud account could not be checked"
        #if os(macOS)
            case .temporarilyUnavailable:
                "iCloud is temporarily unavailable; check your Apple Account in System Settings"
        #else
            case .temporarilyUnavailable: "iCloud is temporarily unavailable; check your Apple Account in Settings"
        #endif
        }
    }

    /// The detail view's "Account" value; `nil` is "not known yet".
    static func account(_ state: AccountState?) -> LocalizedStringResource {
        switch state {
        case nil: "Checking…"
        case .available: "Available"
        case .noAccount: "No account"
        case .restricted: "Restricted"
        case .couldNotDetermine: "Could not be checked"
        case .temporarilyUnavailable: "Temporarily unavailable"
        }
    }

    /// "5 minutes ago", "vor 5 Minuten": relative to `now`, in `locale`.
    static func relative(_ date: Date, now: Date, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        // A sync less than a minute ago reads as "now", not as seconds that the footer would not refresh.
        if abs(now.timeIntervalSince(date)) < 60 { return formatter.localizedString(fromTimeInterval: 0) }
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// The CloudKit code of a problem, such as "CKError 25", so that a screenshot is enough for a diagnosis. Not
    /// translated: it is the code's name.
    static func code(_ code: Int) -> String {
        "CKError \(code)"
    }
}
