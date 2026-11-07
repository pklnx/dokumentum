import DokumentumKit
import Foundation
import Testing

private let cloudKit = "CKErrorDomain"
private let cocoa = "NSCocoaErrorDomain"
private let start = Date(timeIntervalSince1970: 1000)
private let end = Date(timeIntervalSince1970: 2000)
private let later = Date(timeIntervalSince1970: 3000)

private func link(_ code: Int, _ domain: String = cloudKit) -> ErrorLink {
    ErrorLink(domain: domain, code: code)
}

private func ended(
    _ kind: SyncEventKind,
    at date: Date = end,
    succeeded: Bool = true,
    error: [ErrorLink] = []
) -> SyncStatusInput {
    .event(kind: kind, started: start, ended: date, succeeded: succeeded, errorChain: error)
}

private func status(after inputs: SyncStatusInput...) -> SyncStatus {
    inputs.reduce(SyncStatus(), SyncStatusReducer.reduce)
}

struct SyncStatusTests {
    // MARK: Classification

    @Test(arguments: [
        (25, CloudErrorCategory.storageFull),
        (9, .noAccount),
        (3, .offline),
        (4, .offline),
        (26, .reset),
        (28, .reset),
        (1, .other),
        (2, .other),
        (7, .other),
    ])
    func aCloudKitCodeHasItsCategory(code: Int, category: CloudErrorCategory) {
        #expect(CloudErrorCategory.classify([link(code)]) == category)
    }

    @Test func storageFullIsFoundUnderACocoaError() {
        #expect(CloudErrorCategory.classify([link(134400, cocoa), link(25)]) == .storageFull)
    }

    @Test func storageFullIsFoundInAPartialFailure() {
        #expect(CloudErrorCategory.classify([link(2), link(22), link(25)]) == .storageFull)
    }

    @Test func storageFullIsFoundInAPartialFailureUnderACocoaError() {
        #expect(CloudErrorCategory.classify([link(134400, cocoa), link(2), link(4), link(25)]) == .storageFull)
    }

    @Test func aPartialFailureWithoutStorageFullTakesItsFirstCode() {
        #expect(CloudErrorCategory.classify([link(2), link(4), link(26)]) == .offline)
    }

    @Test func theFirstCloudKitCodeDecides() {
        #expect(CloudErrorCategory.classify([link(134400, cocoa), link(9), link(25)]) == .noAccount)
        #expect(CloudErrorCategory.classify([link(9), link(2), link(25)]) == .noAccount)
    }

    @Test func otherDomainsSayNothing() {
        #expect(CloudErrorCategory.classify([link(25, cocoa), link(9, "NSURLErrorDomain")]) == .other)
        #expect(CloudErrorCategory.classify([]) == .other)
    }

    // MARK: Reducer

    @Test func aRunningEventChangesNothing() {
        let running = SyncStatusInput.event(
            kind: .importing,
            started: start,
            ended: nil,
            succeeded: false,
            errorChain: [link(25)]
        )
        #expect(status(after: running) == SyncStatus())
    }

    @Test func aSuccessfulImportSetsTheLastImport() {
        let result = status(after: ended(.importing))
        #expect(result.lastImport == end)
        #expect(result.lastExport == nil)
    }

    @Test func aSuccessfulExportSetsTheLastExport() {
        let result = status(after: ended(.exporting))
        #expect(result.lastExport == end)
        #expect(result.lastImport == nil)
    }

    @Test func anEventArrivingLateDoesNotMoveTheDateBack() {
        let result = status(after: ended(.importing, at: later), ended(.importing, at: end))
        #expect(result.lastImport == later)
    }

    @Test func aFailureLeavesTheDatesAlone() {
        let result = status(after: ended(.importing), ended(.importing, at: later, succeeded: false))
        #expect(result.lastImport == end)
        #expect(result.lastError == .other)
    }

    @Test func aFailureWith25SetsStorageFull() {
        let result = status(after: ended(.exporting, succeeded: false, error: [link(25)]))
        #expect(result.isStorageFull)
        #expect(result.lastError == .storageFull)
    }

    @Test func aLaterExportClearsStorageFull() {
        let result = status(
            after: ended(.exporting, succeeded: false, error: [link(25)]),
            ended(.exporting, at: later)
        )
        #expect(!result.isStorageFull)
        #expect(result.lastError == nil)
    }

    @Test func storageFullStaysUntilAnExportSucceeds() {
        let full = ended(.exporting, succeeded: false, error: [link(25)])
        let afterImport = status(after: full, ended(.importing, at: later))
        #expect(afterImport.isStorageFull)
        #expect(afterImport.lastError == nil)
        let afterOffline = status(after: full, ended(.exporting, at: later, succeeded: false, error: [link(3)]))
        #expect(afterOffline.isStorageFull)
        #expect(afterOffline.lastError == .offline)
        #expect(status(after: full, ended(.setup, at: later)).isStorageFull)
    }

    @Test func aSuccessClearsTheLastError() {
        let result = status(after: ended(.importing, succeeded: false, error: [link(4)]), ended(.importing, at: later))
        #expect(result.lastError == nil)
    }

    @Test func aSuccessfulSetupSetsNoDate() {
        let result = status(after: ended(.setup))
        #expect(result.lastImport == nil)
        #expect(result.lastExport == nil)
    }

    @Test func anAccountChangeIsShownAndForgetsTheOldAccount() {
        let result = status(
            after: ended(.importing),
            ended(.exporting),
            ended(.exporting, at: later, succeeded: false, error: [link(25)]),
            .accountChanged
        )
        #expect(result.accountChanged)
        #expect(result.lastImport == nil)
        #expect(result.lastExport == nil)
        #expect(!result.isStorageFull)
        #expect(result.lastError == nil)
    }

    @Test func anAccountChangeStaysAfterLaterEvents() {
        let result = status(after: .accountChanged, ended(.importing), .accountStatus(.available))
        #expect(result.accountChanged)
    }

    @Test(arguments: [
        (AccountState.noAccount, SyncOffReason.noAccount),
        (.restricted, .restricted),
        (.couldNotDetermine, .couldNotDetermine),
        (.temporarilyUnavailable, .temporarilyUnavailable),
    ])
    func syncIsOffWithItsReason(state: AccountState, reason: SyncOffReason) {
        let result = status(after: .accountStatus(.available), .accountStatus(state))
        #expect(result.accountState == state)
        #expect(!result.isSyncEnabled)
        #expect(result.syncOffReason == reason)
    }

    @Test func syncIsOnWithAnAccount() {
        let result = status(after: .accountStatus(.noAccount), .accountStatus(.available))
        #expect(result.accountState == .available)
        #expect(result.isSyncEnabled)
        #expect(result.syncOffReason == nil)
    }

    @Test func syncIsOffUntilTheAccountIsKnown() {
        #expect(SyncStatus().syncOffReason == .couldNotDetermine)
    }
}
