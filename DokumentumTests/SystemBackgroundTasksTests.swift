#if os(iOS)
    import DokumentumCore
    import DokumentumKit
    import DokumentumTestSupport
    import Foundation
    import Testing

    @testable import Dokumentum

    /// The real `BGTaskScheduler` on the simulator (#194). The simulator cannot run the tasks, but it checks
    /// registration and submission as the device does: `register` refuses the wildcard itself and anything the
    /// Info.plist does not permit, a submission without a handler under exactly its identifier raises
    /// `NSInternalInconsistencyException` (the device crash of #194), and a second registration kills the process.
    /// The tests run hosted in `Dokumentum.app`, so its Info.plist applies; the test host opens an in-memory store and
    /// registers nothing at launch.
    ///
    /// Every identifier is a fresh `continuedPrefix + UUID`. No test registers the processing task with the real SDK:
    /// `aProcessingSubmissionWithoutRegistrationThrows` needs it unregistered, and a second registration in the
    /// process would kill it.
    @MainActor
    struct SystemBackgroundTasksTests {
        /// What `didSubmit` reported.
        final class Submission {
            var identifier: String?
            var accepted: Bool?
        }

        /// The real `BackgroundProcessing` over the real `SystemBackgroundTasks` and a scheduler with a stub runner
        /// that is not started. `register()` is not called: launch registrations are not under test here.
        private func makeBackground(
            open: Int = 0, inForeground: Bool = true
        ) throws -> (BackgroundProcessing, ProcessingScheduler, Submission, TestSignal) {
            let container = try makeInMemoryContainer()
            let observer = StoreChangeObserver(
                container: container, center: NotificationCenter(), sleep: ManualDebounce().sleep)
            let scheduler = ProcessingScheduler(
                runner: BackgroundProcessingTests.StubRunner(), observer: observer, insertions: AsyncStream { _ in },
                sleep: ManualDebounce().sleep)
            let background = BackgroundProcessing(
                scheduler: scheduler, tasks: SystemBackgroundTasks(), openDocuments: { _ in open },
                applicationIsInForeground: { inForeground }, registry: BackgroundTaskRegistry())
            let submission = Submission()
            let submitted = TestSignal()
            background.didSubmit = { identifier, accepted in
                submission.identifier = identifier
                submission.accepted = accepted
                submitted.fire()
            }
            return (background, scheduler, submission, submitted)
        }

        /// C1: a user's import registers an identifier the real scheduler accepts and submits it without the
        /// exception of #194. Whether the simulator accepts the submission is not asserted (it answers
        /// `BGTaskSchedulerErrorDomain` 1 today).
        @Test func aUserImportRegistersAPermittedIdentifierAndDoesNotCrash() async throws {
            let (background, scheduler, submission, submitted) = try makeBackground()
            defer { scheduler.stop() }
            background.userImported([UUID()])
            await submitted.wait(for: 1, "the import's submission did not end")

            let identifier = try #require(submission.identifier)
            #expect(identifier.hasPrefix(BackgroundTaskIdentifier.continuedPrefix))
            #expect(identifier.count > BackgroundTaskIdentifier.continuedPrefix.count)
            #expect(
                SystemBackgroundTasks.isRegistered(identifier),
                "the real scheduler did not register the identifier the import built: \(identifier)")
        }

        /// C2: a continued submission for an identifier nobody registered throws instead of reaching the SDK.
        @Test func aContinuedSubmissionWithoutRegistrationThrows() async {
            let identifier = BackgroundTaskIdentifier.continuedPrefix + UUID().uuidString
            #expect(!SystemBackgroundTasks.isRegistered(identifier))
            await #expect(throws: BackgroundTaskSubmissionError.notRegistered(identifier)) {
                try await SystemBackgroundTasks().submitContinued(identifier: identifier, title: "T", subtitle: "S")
            }
        }

        /// C3: without a registration of the processing task, going to the background with an open document
        /// submits nothing to the SDK: the submission is refused, and the work waits.
        @Test func aProcessingSubmissionWithoutRegistrationThrows() async throws {
            try #require(
                !SystemBackgroundTasks.isRegistered(BackgroundTaskIdentifier.processing),
                "the processing task is registered in this process, so this test would prove nothing")
            let (background, scheduler, submission, submitted) = try makeBackground(open: 1, inForeground: false)
            defer { scheduler.stop() }
            background.scenePhaseChanged(to: .background)
            await submitted.wait(for: 1, "the processing submission did not end")

            #expect(submission.identifier == BackgroundTaskIdentifier.processing)
            #expect(submission.accepted == false)
            await #expect(throws: BackgroundTaskSubmissionError.notRegistered(BackgroundTaskIdentifier.processing)) {
                try await SystemBackgroundTasks().submitProcessing(identifier: BackgroundTaskIdentifier.processing)
            }
        }

        /// C4: a second registration of the same identifier is refused instead of killing the process.
        @Test func aSecondRegistrationIsRefused() {
            let tasks = SystemBackgroundTasks()
            let identifier = BackgroundTaskIdentifier.continuedPrefix + UUID().uuidString
            #expect(tasks.register(identifier) { _ in })
            #expect(SystemBackgroundTasks.isRegistered(identifier))
            #expect(!tasks.register(identifier) { _ in }, "the second registration was accepted")
        }
    }
#endif
