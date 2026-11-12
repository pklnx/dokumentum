import DokumentumKit
import Foundation
import Testing

private let cloudKit = "CKErrorDomain"
private let start = Date(timeIntervalSince1970: 1000)
private let end = Date(timeIntervalSince1970: 2000)
private let later = Date(timeIntervalSince1970: 3000)

private func failed(_ code: Int, kind: SyncEventKind = .exporting, at date: Date = end) -> SyncStatusInput {
    .event(
        kind: kind, started: start, ended: date, succeeded: false,
        errorChain: [ErrorLink(domain: cloudKit, code: code)])
}

private func succeeded(_ kind: SyncEventKind, at date: Date = end) -> SyncStatusInput {
    .event(kind: kind, started: start, ended: date, succeeded: true, errorChain: [])
}

private func line(after inputs: SyncStatusInput...) -> SyncStatusLine {
    SyncStatusLine(inputs.reduce(SyncStatus(), SyncStatusReducer.reduce))
}

/// The footer's one line (plan of #31, T1): each priority pair, "checking", the two edges of Revision 1, note 1, and
/// every reachable combination of the status' fields against the priority list.
struct SyncStatusLineTests {
    // MARK: Checking (P3)

    @Test func aFreshStatusIsChecking() {
        #expect(SyncStatusLine(SyncStatus()) == .checking)
    }

    @Test func theFirstAccountAnswerEndsChecking() {
        #expect(line(after: .accountStatus(.available)) == .on(lastSynced: nil))
        #expect(line(after: .accountStatus(.noAccount)) == .syncOff(.noAccount))
    }

    /// Revision 1, note 1 (b): a successful event before any account answer shows "on".
    @Test func aSuccessfulEventWithoutAnAccountAnswerShowsOn() {
        #expect(line(after: succeeded(.importing)) == .on(lastSynced: end))
        #expect(line(after: succeeded(.setup)) == .on(lastSynced: nil))
    }

    @Test func aFailedEventWithoutAnAccountAnswerShowsItsProblem() {
        #expect(line(after: failed(3)) == .offline)
    }

    // MARK: The edges of Revision 1, note 1 (a)

    @Test func anAccountFailureWhileTheStateSaysAvailableShowsSyncOff() {
        #expect(line(after: .accountStatus(.available), failed(9)) == .syncOff(.noAccount))
        #expect(line(after: .accountStatus(.available), failed(36)) == .syncOff(.temporarilyUnavailable))
        // The answer then decides.
        #expect(line(after: .accountStatus(.available), failed(36), .accountStatus(.available)) == .on(lastSynced: nil))
        #expect(line(after: .accountStatus(.available), failed(9), .accountStatus(.noAccount)) == .syncOff(.noAccount))
    }

    // MARK: Priority pairs

    @Test func storageFullBeatsAccountChanged() {
        #expect(line(after: failed(25), .accountChanged, failed(25)) == .storageFull)
    }

    @Test func accountChangedBeatsSyncOff() {
        #expect(line(after: .accountChanged, .accountStatus(.noAccount)) == .accountChanged)
    }

    @Test func storageFullBeatsSyncOff() {
        #expect(line(after: failed(25), .accountStatus(.restricted)) == .storageFull)
    }

    @Test(arguments: [
        (AccountState.noAccount, SyncOffReason.noAccount),
        (.restricted, .restricted),
        (.couldNotDetermine, .couldNotDetermine),
        (.temporarilyUnavailable, .temporarilyUnavailable),
    ])
    func syncOffBeatsOfflineResetAndProblem(state: AccountState, reason: SyncOffReason) {
        for code in [3, 26, 7] {
            #expect(line(after: .accountStatus(state), failed(code)) == .syncOff(reason), "\(code)")
        }
    }

    @Test func offlineBeatsOn() {
        #expect(line(after: succeeded(.importing), .accountStatus(.available), failed(4, at: later)) == .offline)
    }

    @Test func resetAndProblem() {
        #expect(line(after: .accountStatus(.available), failed(28)) == .reset)
        #expect(line(after: .accountStatus(.available), failed(15)) == .problem)
    }

    @Test func aSuccessAfterAProblemShowsOn() {
        #expect(
            line(after: .accountStatus(.available), failed(4), succeeded(.exporting, at: later))
                == .on(lastSynced: later))
    }

    @Test func onShowsTheLaterOfImportAndExport() {
        #expect(
            line(after: .accountStatus(.available), succeeded(.importing, at: later), succeeded(.exporting))
                == .on(lastSynced: later))
        #expect(
            line(after: .accountStatus(.available), succeeded(.importing), succeeded(.exporting, at: later))
                == .on(lastSynced: later))
    }

    // MARK: Every combination

    /// The priority list, written as a table of rules in order, against every combination of the fields the line
    /// reads.
    @Test func everyCombinationFollowsThePriority() {
        let states: [AccountState?] = [nil] + AccountState.allCases
        let errors: [CloudErrorCategory?] = [
            nil, .storageFull, .noAccount, .accountUnavailable, .offline, .reset, .other,
        ]
        var checked = 0
        for state in states {
            for full in [false, true] {
                for changed in [false, true] {
                    for error in errors {
                        for synced in [nil, end] as [Date?] {
                            for ended in [false, true] {
                                var status = SyncStatus()
                                status.accountState = state
                                status.isStorageFull = full
                                status.accountChanged = changed
                                status.lastError = error
                                status.lastImport = synced
                                status.hasEndedEvent = ended || error != nil || synced != nil
                                #expect(
                                    SyncStatusLine(status) == expected(status),
                                    "\(String(describing: state)) \(full) \(changed) \(String(describing: error))")
                                checked += 1
                            }
                        }
                    }
                }
            }
        }
        #expect(checked == 6 * 2 * 2 * 7 * 2 * 2)
    }

    private func expected(_ status: SyncStatus) -> SyncStatusLine {
        let accountReason: [AccountState: SyncOffReason] = [
            .noAccount: .noAccount, .restricted: .restricted, .couldNotDetermine: .couldNotDetermine,
            .temporarilyUnavailable: .temporarilyUnavailable,
        ]
        let rules: [(Bool, () -> SyncStatusLine)] = [
            (status.isStorageFull, { .storageFull }),
            (status.accountChanged, { .accountChanged }),
            (
                status.accountState.flatMap { accountReason[$0] } != nil,
                {
                    .syncOff(accountReason[status.accountState!]!)
                }
            ),
            (status.lastError == .noAccount, { .syncOff(.noAccount) }),
            (status.lastError == .accountUnavailable, { .syncOff(.temporarilyUnavailable) }),
            (status.accountState == nil && !status.hasEndedEvent, { .checking }),
            (status.lastError == .offline, { .offline }),
            (status.lastError == .reset, { .reset }),
            (status.lastError != nil, { .problem }),
        ]
        return rules.first { $0.0 }?.1() ?? .on(lastSynced: status.lastSync)
    }

}
