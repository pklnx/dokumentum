import DokumentumKit
import DokumentumTestSupport
import Foundation
import Synchronization
import Testing

@testable import DokumentumCore

/// A CloudKit account that answers from a script, one answer per request, in request order (then the last one again).
/// A gated answer waits until the test releases it. `userRecordID()` answers with the ID of the answer whose status
/// was given last: the monitor asks for both in one request, one after the other.
final class StubAccount: AccountStatusProviding {
    struct Answer: Sendable {
        var state: AccountState
        var userRecordID: String?
        var gate: Checkpoint?

        init(_ state: AccountState, _ userRecordID: String?, gate: Checkpoint? = nil) {
            self.state = state
            self.userRecordID = userRecordID
            self.gate = gate
        }
    }

    let asked = TestSignal()
    private let answers: [Answer]
    private let next = Mutex(0)
    private let lastGiven = Mutex(0)

    init(_ answers: [Answer]) {
        precondition(!answers.isEmpty)
        self.answers = answers
    }

    func accountStatus() async -> AccountState {
        let index = next.withLock { index in
            defer { index += 1 }
            return min(index, answers.count - 1)
        }
        asked.fire()
        if let gate = answers[index].gate { await gate.pass() }
        lastGiven.withLock { $0 = index }
        return answers[index].state
    }

    func userRecordID() async -> String? {
        answers[lastGiven.withLock { $0 }].userRecordID
    }
}

/// The monitor of a CloudKit store (plan of #31, Approach 1, T3–T6), without CloudKit: the account comes from a stub,
/// the events and account changes from streams the test feeds.
@MainActor
struct CloudSyncMonitorTests {
    /// A monitor on `account`, with signals for its updates and the continuations of its two streams.
    @MainActor
    final class Harness {
        let account: StubAccount
        let applied = TestSignal()
        let dropped = TestSignal()
        let handled = TestSignal()
        let events: AsyncStream<CloudSyncEvent>.Continuation
        let accountChanges: AsyncStream<Void>.Continuation
        let monitor: CloudSyncMonitor

        init(_ answers: [StubAccount.Answer]) {
            let account = StubAccount(answers)
            self.account = account
            let (eventStream, events) = AsyncStream<CloudSyncEvent>.makeStream()
            let (changeStream, accountChanges) = AsyncStream<Void>.makeStream()
            self.events = events
            self.accountChanges = accountChanges
            let applied = applied
            let dropped = dropped
            let handled = handled
            monitor = CloudSyncMonitor(
                provider: account, events: eventStream, accountChanges: changeStream,
                didUpdate: { update in
                    switch update {
                    case .account(applied: true): applied.fire()
                    case .account(applied: false): dropped.fire()
                    case .event: handled.fire()
                    }
                })
        }

        var line: SyncStatusLine { SyncStatusLine(monitor.status) }

        /// Sends an account-change notification and waits for its answer (`count` answers applied in all).
        func accountChanged(answers count: Int) async {
            accountChanges.yield()
            await applied.wait(for: count)
        }
    }

    private static let start = Date(timeIntervalSince1970: 1000)
    private static let end = Date(timeIntervalSince1970: 2000)

    private func failed(_ code: Int, id: UUID = UUID()) -> CloudSyncEvent {
        CloudSyncEvent(
            identifier: id, kind: .exporting, started: Self.start, ended: Self.end, succeeded: false,
            errorChain: [ErrorLink(domain: CKDomain.name, code: code)])
    }

    // MARK: The account at start

    @Test func itIsCheckingUntilTheFirstAnswer() async {
        let gate = Checkpoint()
        defer { gate.release() }
        let harness = Harness([.init(.available, "A", gate: gate)])
        await gate.reached()
        #expect(harness.line == .checking)
        gate.release()
        await harness.applied.wait()
        #expect(harness.monitor.status.accountState == .available)
        #expect(harness.line == .on(lastSynced: nil))
        #expect(harness.monitor.lastKnownUserRecordID == "A")
    }

    @Test func aSuccessfulEventBeforeTheAnswerShowsOn() async {
        let gate = Checkpoint()
        defer { gate.release() }
        let harness = Harness([.init(.available, "A", gate: gate)])
        await gate.reached()
        harness.events.yield(CloudSyncEvent(kind: .importing, started: Self.start, ended: Self.end, succeeded: true))
        await harness.handled.wait()
        #expect(harness.line == .on(lastSynced: Self.end))
    }

    // MARK: Account changes (Revision 1, B1; Revision 2, B1′)

    @Test func aRealSwitchPassesThroughNoAccountAndIsShownAtTheSignIn() async {
        let harness = Harness([.init(.available, "A"), .init(.noAccount, nil), .init(.available, "B")])
        await harness.applied.wait()
        #expect(harness.line == .on(lastSynced: nil))
        await harness.accountChanged(answers: 2)
        #expect(harness.line == .syncOff(.noAccount))
        #expect(!harness.monitor.status.accountChanged)
        await harness.accountChanged(answers: 3)
        #expect(harness.line == .accountChanged)
        #expect(harness.monitor.lastKnownUserRecordID == "B")
    }

    @Test func signingOutAndBackInToTheSameAccountIsNoChange() async {
        let harness = Harness([.init(.available, "A"), .init(.noAccount, nil), .init(.available, "A")])
        await harness.applied.wait()
        await harness.accountChanged(answers: 2)
        #expect(harness.line == .syncOff(.noAccount))
        await harness.accountChanged(answers: 3)
        #expect(!harness.monitor.status.accountChanged)
        #expect(harness.line == .on(lastSynced: nil))
    }

    @Test func signingOutShowsNoAccountAndNotAChange() async {
        let harness = Harness([.init(.available, "A"), .init(.noAccount, nil)])
        await harness.applied.wait()
        await harness.accountChanged(answers: 2)
        #expect(harness.line == .syncOff(.noAccount))
        #expect(!harness.monitor.status.accountChanged)
        #expect(harness.monitor.lastKnownUserRecordID == "A")
    }

    @Test func theFirstSignInShowsOn() async {
        let harness = Harness([.init(.noAccount, nil), .init(.available, "A")])
        await harness.applied.wait()
        #expect(harness.line == .syncOff(.noAccount))
        await harness.accountChanged(answers: 2)
        #expect(harness.line == .on(lastSynced: nil))
        #expect(!harness.monitor.status.accountChanged)
    }

    @Test func aDirectSwitchIsAChange() async {
        let harness = Harness([.init(.available, "A"), .init(.available, "B")])
        await harness.applied.wait()
        await harness.accountChanged(answers: 2)
        #expect(harness.line == .accountChanged)
    }

    // MARK: When it asks

    @Test func anAnswerToAnOlderRequestIsDropped() async {
        let gate = Checkpoint()
        defer { gate.release() }
        let harness = Harness([.init(.noAccount, nil, gate: gate), .init(.available, "A")])
        await gate.reached()
        harness.monitor.sceneBecameActive()
        await harness.applied.wait()
        #expect(harness.line == .on(lastSynced: nil))
        gate.release()
        await harness.dropped.wait()
        #expect(harness.applied.count == 1)
        #expect(harness.line == .on(lastSynced: nil))
        #expect(harness.monitor.status.accountState == .available)
    }

    @Test func theSceneBecomingActiveAsksAgain() async {
        let harness = Harness([.init(.available, "A"), .init(.restricted, "A")])
        await harness.applied.wait()
        harness.monitor.sceneBecameActive()
        await harness.applied.wait(for: 2)
        #expect(harness.account.asked.count == 2)
        #expect(harness.line == .syncOff(.restricted))
    }

    @Test(arguments: [(9, SyncOffReason.noAccount), (36, .temporarilyUnavailable)])
    func anAccountFailureAsksAgain(code: Int, reason: SyncOffReason) async {
        let gate = Checkpoint()
        defer { gate.release() }
        let harness = Harness([.init(.available, "A"), .init(.available, "A", gate: gate)])
        await harness.applied.wait()
        harness.events.yield(failed(code))
        await harness.handled.wait()
        // Until the answer arrives, the failure decides.
        #expect(harness.line == .syncOff(reason))
        await harness.account.asked.wait(for: 2)
        gate.release()
        await harness.applied.wait(for: 2)
        #expect(harness.line == .on(lastSynced: nil))
    }

    @Test func anOfflineFailureDoesNotAskAgainBeforeTheNextTrigger() async {
        let harness = Harness([.init(.available, "A")])
        await harness.applied.wait()
        harness.events.yield(failed(4))
        await harness.handled.wait()
        harness.monitor.sceneBecameActive()
        await harness.applied.wait(for: 2)
        // The scene's request is the second, so the failure made none.
        #expect(harness.account.asked.count == 2)
        #expect(harness.line == .offline)
    }

    // MARK: Events

    @Test func aRunningEventChangesNothingAndItsEndReplacesItInTheLog() async {
        let harness = Harness([.init(.available, "A")])
        await harness.applied.wait()
        let before = harness.monitor.status
        let id = UUID()
        harness.events.yield(
            CloudSyncEvent(identifier: id, kind: .exporting, started: Self.start, ended: nil, succeeded: false))
        await harness.handled.wait()
        #expect(harness.monitor.status == before)
        #expect(harness.monitor.events.count == 1)
        harness.events.yield(failed(25, id: id))
        await harness.handled.wait(for: 2)
        #expect(harness.monitor.events.count == 1)
        #expect(harness.monitor.events.first?.ended == Self.end)
        #expect(harness.monitor.status.lastError == .storageFull)
        #expect(harness.line == .storageFull)
    }

    @Test func theLogKeepsTheLast50() async {
        let harness = Harness([.init(.available, "A")])
        await harness.applied.wait()
        let ids = (0..<60).map { _ in UUID() }
        for id in ids {
            harness.events.yield(
                CloudSyncEvent(identifier: id, kind: .importing, started: Self.start, ended: Self.end, succeeded: true))
        }
        await harness.handled.wait(for: 60)
        #expect(harness.monitor.events.map(\.identifier) == Array(ids.suffix(50)))
    }

    // MARK: The store and the notifications (T3)

    @Test(arguments: [
        ArchiveStore.OpenedStore.inMemory, .sampleData, .local, .localFallback,
    ])
    func aStoreThatDoesNotSyncNeverCreatesTheProvider(store: ArchiveStore.OpenedStore) {
        let created = TestSignal()
        let monitor = CloudSyncMonitor.forStore(
            store,
            makeProvider: {
                created.fire()
                return StubAccount([.init(.available, "A")])
            })
        #expect(monitor == nil)
        #expect(created.count == 0)
    }

    @Test func aCloudKitStoreAsksAtStartAndAfterEachNotification() async {
        let center = NotificationCenter()
        let names = [Notification.Name("test.accountChanged"), Notification.Name("test.identityChanged")]
        let account = StubAccount([.init(.available, "A")])
        let monitor = CloudSyncMonitor.forStore(
            .cloudKit, makeProvider: { account }, center: center, accountChangeNotifications: names)
        #expect(monitor != nil)
        await account.asked.wait()
        center.post(name: names[0], object: nil)
        await account.asked.wait(for: 2)
        center.post(name: names[1], object: nil)
        await account.asked.wait(for: 3)
        withExtendedLifetime(monitor) {}
    }

    @Test func theAppNamesBothAccountNotifications() {
        #expect(
            Set(CloudKitAccountStatus.accountChangeNotifications.map(\.rawValue))
                == ["CKAccountChangedNotification", "NSUbiquityIdentityDidChangeNotification"])
    }
}

/// The error chain as `CloudErrorCategory.classify` expects it (plan of #31, Approach 1).
struct CloudSyncEventsTests {
    private func ck(_ code: Int, _ userInfo: [String: Any] = [:]) -> NSError {
        NSError(domain: CKDomain.name, code: code, userInfo: userInfo)
    }

    @Test func storageFullDirectly() {
        let chain = CloudSyncEvents.errorChain(of: ck(25))
        #expect(chain == [ErrorLink(domain: CKDomain.name, code: 25)])
        #expect(CloudErrorCategory.classify(chain) == .storageFull)
    }

    @Test func storageFullInAPartialFailure() {
        let error = ck(2, [CloudSyncEvents.partialErrorsKey: ["record-1": ck(22), "record-2": ck(25)]])
        let chain = CloudSyncEvents.errorChain(of: error)
        #expect(chain.map(\.code) == [2, 22, 25])
        #expect(CloudErrorCategory.classify(chain) == .storageFull)
    }

    @Test func storageFullUnderACocoaError() {
        let error = NSError(
            domain: NSCocoaErrorDomain, code: 134400,
            userInfo: [NSUnderlyingErrorKey: ck(2, [CloudSyncEvents.partialErrorsKey: ["record": ck(25)]])])
        let chain = CloudSyncEvents.errorChain(of: error)
        #expect(chain.map(\.code) == [134400, 2, 25])
        #expect(CloudErrorCategory.classify(chain) == .storageFull)
    }

    @Test func code36UnderACocoaError() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 134400, userInfo: [NSUnderlyingErrorKey: ck(36)])
        #expect(CloudErrorCategory.classify(CloudSyncEvents.errorChain(of: error)) == .accountUnavailable)
    }

    /// An error that names itself as its underlying error.
    final class LoopingError: NSError, @unchecked Sendable {
        override var userInfo: [String: Any] { [NSUnderlyingErrorKey: self] }
    }

    @Test func aChainThatRefersToItselfEnds() {
        let error = LoopingError(domain: CKDomain.name, code: 4)
        #expect(CloudSyncEvents.errorChain(of: error) == [ErrorLink(domain: CKDomain.name, code: 4)])
    }

    @Test func aDeepChainStopsAtTheLimit() {
        var error = ck(25)
        for _ in 0..<20 {
            error = NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [NSUnderlyingErrorKey: error])
        }
        #expect(CloudSyncEvents.errorChain(of: error).count == CloudSyncEvents.maximumDepth)
    }

    @Test func aNotificationWithoutAnEventIsIgnored() {
        let notification = Notification(
            name: Notification.Name("NSPersistentCloudKitContainerEventChangedNotification"))
        #expect(CloudSyncEvents.event(of: notification) == nil)
    }
}

/// The CloudKit domain as the tests spell it; `CloudErrorCodesTests` pins it against the SDK.
enum CKDomain {
    static let name = "CKErrorDomain"
}
