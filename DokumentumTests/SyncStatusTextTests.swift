import DokumentumCore
import DokumentumKit
import Foundation
import Testing

@testable import Dokumentum

/// An account that answers at once and always the same.
private struct FixedAccount: AccountStatusProviding {
    func accountStatus() async -> AccountState { .available }
    func userRecordID() async -> String? { "A" }
}

private let english = Locale(identifier: "en")
private let german = Locale(identifier: "de")
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let fiveMinutesAgo = now.addingTimeInterval(-300)

private func rendered(_ resource: LocalizedStringResource, _ locale: Locale) -> String {
    var resource = resource
    resource.locale = locale
    return String(localized: resource)
}

/// The sidebar footer's words and where its line comes from (plan of #31, P1, P2, T5, T7).
@MainActor
struct SyncStatusTextTests {
    /// Every line, in English and German. The English of #2's P1 texts ("No iCloud account: …", "iCloud storage is
    /// full: …", "iCloud account changed", "Sync off: <reason>", "iCloud sync on · last synced …") is unchanged.
    @Test func everyLineHasItsEnglishAndGermanText() {
        #if os(macOS)
            let settings = ("System Settings", "Systemeinstellungen")
        #else
            let settings = ("Settings", "Einstellungen")
        #endif
        let expected: [(SyncStatusLine, String, String)] = [
            (
                .storageFull, "iCloud storage is full: new documents are not uploaded",
                "iCloud-Speicher ist voll: neue Dokumente werden nicht hochgeladen"
            ),
            (.accountChanged, "iCloud account changed", "iCloud-Account gewechselt"),
            (
                .syncOff(.noAccount), "No iCloud account: documents stay on this device",
                "Kein iCloud-Account: Dokumente bleiben auf diesem Gerät"
            ),
            (
                .syncOff(.restricted), "Sync off: iCloud is restricted on this device",
                "Sync aus: iCloud ist auf diesem Gerät eingeschränkt"
            ),
            (
                .syncOff(.couldNotDetermine), "Sync off: the iCloud account could not be checked",
                "Sync aus: der iCloud-Account konnte nicht geprüft werden"
            ),
            (
                .syncOff(.temporarilyUnavailable),
                "Sync off: iCloud is temporarily unavailable; check your Apple Account in \(settings.0)",
                "Sync aus: iCloud ist vorübergehend nicht verfügbar; prüfe deinen Apple Account in den "
                    + settings.1
            ),
            (.checking, "Checking iCloud…", "iCloud wird geprüft …"),
            (
                .offline, "Offline: changes sync when the connection is back",
                "Offline: Änderungen werden synchronisiert, sobald eine Verbindung besteht"
            ),
            (
                .reset, "iCloud data was reset: documents on this device are uploaded again",
                "iCloud-Daten wurden zurückgesetzt: Dokumente auf diesem Gerät werden neu hochgeladen"
            ),
            (
                .problem, "iCloud sync problem: retrying automatically",
                "Problem beim iCloud-Sync: wird automatisch wiederholt"
            ),
            (
                .on(lastSynced: fiveMinutesAgo), "iCloud sync on · last synced 5 minutes ago",
                "iCloud-Sync an · zuletzt synchronisiert vor 5 Minuten"
            ),
            (.on(lastSynced: nil), "iCloud sync on · not synced yet", "iCloud-Sync an · noch nicht synchronisiert"),
        ]
        var kinds = Set<String>()
        for (line, englishText, germanText) in expected {
            kinds.insert(Self.kind(of: line))
            #expect(rendered(SyncStatusText.line(line, now: now, locale: english), english) == englishText)
            #expect(rendered(SyncStatusText.line(line, now: now, locale: german), german) == germanText)
        }
        #expect(kinds.count == Self.kindCount, "a line has no expected text")
    }

    /// The cases of `SyncStatusLine`, with each reason of `syncOff` its own; a new case does not compile here.
    private static func kind(of line: SyncStatusLine) -> String {
        switch line {
        case .storageFull: "storageFull"
        case .accountChanged: "accountChanged"
        case .syncOff(let reason): "syncOff.\(reason)"
        case .checking: "checking"
        case .offline: "offline"
        case .reset: "reset"
        case .problem: "problem"
        case .on(let date): date == nil ? "on.never" : "on"
        }
    }

    /// 6 cases besides `syncOff` and `on`, 4 reasons, `on` with and without a date.
    private static let kindCount = 6 + 4 + 2

    @Test func theStoresOwnLineIsUnchanged() {
        #expect(rendered(SyncStatusText.storeLine(.sampleData), english) == "Sync off: sample data, not saved")
        #expect(
            rendered(SyncStatusText.storeLine(.sampleData), german)
                == "Sync aus: Beispieldaten, nicht gespeichert")
    }

    @Test func eachAccountStateHasItsText() {
        let expected: [(AccountState?, String, String)] = [
            (nil, "Checking…", "Wird geprüft …"),
            (.available, "Available", "Verfügbar"),
            (.noAccount, "No account", "Kein Account"),
            (.restricted, "Restricted", "Eingeschränkt"),
            (.couldNotDetermine, "Could not be checked", "Konnte nicht geprüft werden"),
            (.temporarilyUnavailable, "Temporarily unavailable", "Vorübergehend nicht verfügbar"),
        ]
        #expect(expected.count == AccountState.allCases.count + 1)
        for (state, englishText, germanText) in expected {
            #expect(rendered(SyncStatusText.account(state), english) == englishText)
            #expect(rendered(SyncStatusText.account(state), german) == germanText)
        }
    }

    @Test func theDetailsLabelsHaveGerman() {
        let expected: [(LocalizedStringResource, String)] = [
            ("iCloud Sync", "iCloud-Sync"), ("Account", "Account"), ("Last download", "Letzter Download"),
            ("Last upload", "Letzter Upload"), ("Never", "Noch nie"), ("Done", "Fertig"),
        ]
        for (resource, germanText) in expected {
            #expect(rendered(resource, german) == germanText)
        }
    }

    @Test func aSyncLessThanAMinuteAgoIsNow() {
        #expect(SyncStatusText.relative(now.addingTimeInterval(-20), now: now, locale: english) == "now")
        #expect(SyncStatusText.relative(now.addingTimeInterval(-20), now: now, locale: german) == "jetzt")
        #expect(SyncStatusText.relative(now.addingTimeInterval(-3600), now: now, locale: english) == "1 hour ago")
    }

    // MARK: The source (T5)

    private func monitor() -> CloudSyncMonitor {
        CloudSyncMonitor(
            provider: FixedAccount(), events: AsyncStream { $0.finish() }, accountChanges: AsyncStream { $0.finish() })
    }

    @Test func aStoreThatDoesNotSyncShowsItsOwnLine() {
        let launch = LaunchStore(choice: .inMemory(seed: true), opened: .sampleData)
        let source = SyncStatusSource.forLaunch(launch, monitor: nil)
        #expect(source?.content == .store(.sampleData))
        #expect(source?.content.accessibilityIdentifier == "sidebar.syncOff")
        #expect(source?.status == nil)
    }

    @Test func aCloudKitStoreShowsTheMonitorsLine() {
        let launch = LaunchStore(choice: .cloudKit, opened: .cloudKit)
        let monitor = monitor()
        let source = SyncStatusSource.forLaunch(launch, monitor: monitor)
        #expect(source?.content == .status(.checking))
        #expect(source?.content.accessibilityIdentifier == "sidebar.syncStatus")
        monitor.receive(
            CloudSyncEvent(
                kind: .exporting, started: fiveMinutesAgo, ended: now, succeeded: false,
                errorChain: [ErrorLink(domain: "CKErrorDomain", code: 25)]))
        #expect(source?.content == .status(.storageFull))
        #expect(SyncStatusSource.forLaunch(launch, monitor: nil) == nil)
    }

    @Test func anInjectedStatusWinsOverTheStore() {
        let launch = LaunchStore(choice: .inMemory(seed: true), opened: .sampleData)
        var status = SyncStatus()
        status.isStorageFull = true
        #expect(SyncStatusSource.forLaunch(launch, monitor: nil, injected: status)?.content == .status(.storageFull))
    }

    // MARK: The detail's CloudKit code

    @Test func theDetailShowsTheCodeOfTheProblem() {
        func code(_ line: SyncStatusLine, _ change: (inout SyncStatus) -> Void) -> Int? {
            var status = SyncStatus()
            change(&status)
            return SyncStatusDetailView.problemCode(content: .status(line), status: status)
        }
        #expect(code(.storageFull) { $0.isStorageFull = true } == 25)
        #expect(code(.offline) { $0.lastErrorCode = 4 } == 4)
        #expect(code(.problem) { $0.lastErrorCode = 15 } == 15)
        #expect(
            code(.syncOff(.temporarilyUnavailable)) {
                $0.accountState = .available
                $0.lastErrorCode = 36
            } == 36)
        // A line the account decided has no code, even with an older failure.
        #expect(
            code(.syncOff(.restricted)) {
                $0.accountState = .restricted
                $0.lastErrorCode = 4
            } == nil)
        #expect(code(.on(lastSynced: nil)) { $0.lastErrorCode = 4 } == nil)
        #expect(SyncStatusDetailView.problemCode(content: .store(.sampleData), status: nil) == nil)
    }

    // MARK: -UITestSyncStatus (T7)

    @Test func everyInjectedCaseShowsItsLine() {
        let expected: [UITestSyncStatus.Case: SyncStatusLine] = [
            .checking: .checking, .on: .on(lastSynced: now.addingTimeInterval(-300)),
            .notSyncedYet: .on(lastSynced: nil), .storageFull: .storageFull, .accountChanged: .accountChanged,
            .noAccount: .syncOff(.noAccount), .restricted: .syncOff(.restricted),
            .couldNotDetermine: .syncOff(.couldNotDetermine),
            .temporarilyUnavailable: .syncOff(.temporarilyUnavailable),
            .accountUnavailableFailure: .syncOff(.temporarilyUnavailable), .offline: .offline, .reset: .reset,
            .problem: .problem,
        ]
        #expect(Set(expected.keys) == Set(UITestSyncStatus.Case.allCases))
        for (name, line) in expected {
            let status = UITestSyncStatus.status(arguments: ["-UITestSyncStatus", name.rawValue], now: now)
            #expect(status.map(SyncStatusLine.init) == line, "\(name)")
        }
    }

    @Test func anUnknownOrMissingCaseInjectsNothing() {
        #expect(UITestSyncStatus.status(arguments: ["-UITestSyncStatus", "full"]) == nil)
        #expect(UITestSyncStatus.status(arguments: ["-UITestSyncStatus"]) == nil)
        #expect(UITestSyncStatus.status(arguments: ["-UITestSeed", "YES"]) == nil)
    }
}
