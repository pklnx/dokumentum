import DokumentumCore
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import SwiftUI
import Synchronization
import Testing

@testable import Dokumentum

#if os(iOS)
    import BackgroundTasks
#endif

/// The processing queue's background tasks on iOS (plan of #6, part 5, T13, N4, P3), with a fake `BGTaskScheduler`
/// and a stub runner: a user's import asks for continued processing, a CloudKit insertion never does, each identifier
/// is registered once, progress counts documents, the drain completes, the expiry pauses (the attempt is given back)
/// and fails, and the background asks for one processing task. The logic is platform-independent, so it runs on the
/// Mac too; the real tasks are maintainer step M5.
@MainActor
struct BackgroundProcessingTests {
    /// A task the fake system started.
    final class FakeTask: BackgroundTaskHandle {
        let identifier: String
        private var expiration: (@MainActor @Sendable () -> Void)?
        private(set) var reports: [(completed: Int, total: Int, title: String, subtitle: String)] = []
        private(set) var completions: [Bool] = []
        let completed = TestSignal()

        init(identifier: String) {
            self.identifier = identifier
        }

        func onExpiration(_ handler: @escaping @MainActor @Sendable () -> Void) {
            expiration = handler
        }

        func report(completed: Int, total: Int, title: String, subtitle: String) {
            reports.append((completed, total, title, subtitle))
        }

        func complete(success: Bool) {
            completions.append(success)
            completed.fire()
        }

        /// The system ends the task early.
        func expire() {
            expiration?()
        }
    }

    /// `BGTaskScheduler` as the tests need it: records registrations and requests, and starts tasks on demand.
    final class FakeTasks: BackgroundTaskScheduling {
        private(set) var registrations: [String] = []
        private var handlers: [String: @MainActor (any BackgroundTaskHandle) -> Void] = [:]
        private(set) var continuedRequests: [(identifier: String, title: String, subtitle: String)] = []
        private(set) var processingRequests: [String] = []
        /// Whether a continued request fails (`.fail`: the system cannot start it now).
        var refusesContinued = false

        func register(
            _ identifier: String, launchHandler: @escaping @MainActor (any BackgroundTaskHandle) -> Void
        ) -> Bool {
            registrations.append(identifier)
            handlers[identifier] = launchHandler
            return true
        }

        func submitContinued(identifier: String, title: String, subtitle: String) async throws {
            continuedRequests.append((identifier, title, subtitle))
            if refusesContinued { throw CocoaError(.featureUnsupported) }
        }

        func submitProcessing(identifier: String) async throws {
            processingRequests.append(identifier)
        }

        /// Starts a task as the system would, through the handler registered for `registeredIdentifier`.
        func launch(_ registeredIdentifier: String, as identifier: String? = nil) -> FakeTask {
            let task = FakeTask(identifier: identifier ?? registeredIdentifier)
            handlers[registeredIdentifier]?(task)
            return task
        }
    }

    /// A runner that counts runs and interruptions; with a gate, each run waits until the test releases it.
    final class StubRunner: ProcessingRunning {
        let started = TestSignal()
        let interrupts = TestSignal()
        let gate: Checkpoint?

        init(gate: Checkpoint? = nil) {
            self.gate = gate
        }

        func run() async -> ProcessingReport {
            started.fire()
            if let gate { await gate.pass() }
            return ProcessingReport()
        }

        func interruptNow() {
            interrupts.fire()
        }
    }

    /// The open-document count the test sets: all open documents, and the open ones of the user's.
    final class OpenCount {
        var all = 0
        var ofTracked = 0
        /// What the application's state says (`UIApplication.applicationState != .background` in the app).
        var applicationInForeground = true
    }

    private struct Setup {
        let background: BackgroundProcessing
        let tasks: FakeTasks
        let scheduler: ProcessingScheduler
        let runs: TestSignal
        let open: OpenCount
        let submits: TestSignal
    }

    /// A scheduler that is not started (nothing runs until the test asks) and the background work over it, with
    /// its identifiers registered in a registry of the test's own.
    private func makeSetup(
        runner: StubRunner, container: ModelContainer? = nil, insertions: AsyncStream<Void>? = nil
    ) throws -> Setup {
        let container = try container ?? makeInMemoryContainer()
        let observer = StoreChangeObserver(
            container: container, center: NotificationCenter(), sleep: ManualDebounce().sleep)
        let scheduler = ProcessingScheduler(
            runner: runner, observer: observer, insertions: insertions ?? AsyncStream { _ in },
            sleep: ManualDebounce().sleep)
        let runs = TestSignal()
        scheduler.didFinishRun = { _ in runs.fire() }
        let tasks = FakeTasks()
        let open = OpenCount()
        let background = BackgroundProcessing(
            scheduler: scheduler, tasks: tasks,
            openDocuments: { instanceIDs in instanceIDs == nil ? open.all : open.ofTracked },
            applicationIsInForeground: { open.applicationInForeground }, registry: BackgroundTaskRegistry())
        background.register()
        let submits = TestSignal()
        background.didSubmit = { _, _ in submits.fire() }
        return Setup(
            background: background, tasks: tasks, scheduler: scheduler, runs: runs, open: open, submits: submits)
    }

    /// Starts the continued task the user's import asked for.
    private func launchContinued(_ setup: Setup) -> FakeTask {
        let identifier = setup.tasks.continuedRequests.last?.identifier
        return setup.tasks.launch(BackgroundTaskIdentifier.continued, as: identifier)
    }

    // MARK: - Identifiers and registration

    @Test func theIdentifiersDoNotOverlap() {
        #expect(BackgroundTaskIdentifier.continued == "space.pklnx.Dokumentum.continued.*")
        #expect(BackgroundTaskIdentifier.processing == "space.pklnx.Dokumentum.backgroundProcessing")
        #expect(!BackgroundTaskIdentifier.processing.hasPrefix(BackgroundTaskIdentifier.continuedPrefix))
        #expect(BackgroundTaskIdentifier.continued.hasPrefix(BackgroundTaskIdentifier.continuedPrefix))
        #expect(Set(BackgroundTaskIdentifier.all).count == 2)
    }

    /// The SDK kills an app that registers an identifier twice: a second `register()`, also of a second instance in
    /// the same process, registers nothing.
    @Test func eachIdentifierIsRegisteredOnce() throws {
        let container = try makeInMemoryContainer()
        let observer = StoreChangeObserver(
            container: container, center: NotificationCenter(), sleep: ManualDebounce().sleep)
        let scheduler = ProcessingScheduler(
            runner: StubRunner(), observer: observer, insertions: AsyncStream { _ in }, sleep: ManualDebounce().sleep)
        let tasks = FakeTasks()
        let registry = BackgroundTaskRegistry()
        let first = BackgroundProcessing(
            scheduler: scheduler, tasks: tasks, openDocuments: { _ in 0 }, applicationIsInForeground: { true },
            registry: registry)
        first.register()
        first.register()
        let second = BackgroundProcessing(
            scheduler: scheduler, tasks: tasks, openDocuments: { _ in 0 }, applicationIsInForeground: { true },
            registry: registry)
        second.register()

        #expect(tasks.registrations == BackgroundTaskIdentifier.all)
    }

    #if os(iOS)
        /// The app's Info.plist permits exactly the identifiers the app registers, and the processing mode.
        @Test func theInfoPlistPermitsTheRegisteredIdentifiers() throws {
            let info = try #require(Bundle.main.infoDictionary)
            let permitted = info["BGTaskSchedulerPermittedIdentifiers"] as? [String]
            #expect(permitted == BackgroundTaskIdentifier.all)
            let modes = info["UIBackgroundModes"] as? [String] ?? []
            #expect(modes.contains("processing"))
        }

        /// Continued processing starts now or not at all (`.fail`) and asks for no GPU; the processing task needs
        /// neither power nor the network.
        @Test func theRequestsAreTheReviewedOnes() {
            let continued = SystemBackgroundTasks.continuedRequest(
                identifier: BackgroundTaskIdentifier.continuedPrefix + "x", title: "T", subtitle: "S")
            #expect(continued.strategy == .fail)
            #expect(continued.requiredResources == [])
            #expect(continued.identifier == "space.pklnx.Dokumentum.continued.x")
            let processing = SystemBackgroundTasks.processingRequest(identifier: BackgroundTaskIdentifier.processing)
            #expect(!processing.requiresExternalPower)
            #expect(!processing.requiresNetworkConnectivity)
        }
    #endif

    // MARK: - Continued processing (N4, P3)

    /// A completed user import of files asks for one continued-processing task under `continued.`; a second
    /// import while it is asked for adds its document instead of asking again. Duplicates and failures ask for
    /// nothing.
    @Test func aUserImportAsksForOneContinuedTask() async throws {
        let setup = try makeSetup(runner: StubRunner())
        let (a, b) = (UUID(), UUID())
        let stub = StubImporter([
            "a.pdf": .imported(instanceID: a), "b.pdf": .imported(instanceID: b),
            "dup.pdf": .duplicate(of: UUID(), title: "", isTrashed: false),
        ])
        let background = setup.background
        let importer = BackgroundImportNotifying(base: stub) { background.userImported($0) }
        let library = LibraryModel(source: EmptySource())
        let controller = ImportController(importer: importer, reader: StubReader(), library: library)

        await controller.importFiles([ImportControllerTests.url("dup.pdf"), ImportControllerTests.url("bad.pdf")])
        #expect(setup.tasks.continuedRequests.isEmpty, "a duplicate or a failure asked for a task")

        await controller.importFiles([ImportControllerTests.url("a.pdf"), ImportControllerTests.url("b.pdf")])
        await setup.submits.wait(for: 1, "no continued request was submitted")

        #expect(setup.tasks.continuedRequests.count == 1)
        let request = try #require(setup.tasks.continuedRequests.first)
        #expect(request.identifier.hasPrefix(BackgroundTaskIdentifier.continuedPrefix))
        #expect(request.identifier.count > BackgroundTaskIdentifier.continuedPrefix.count)
        #expect(request.title == String(localized: "Processing documents"))
        #expect(setup.background.tracked == [a, b])
        #expect(setup.tasks.processingRequests.isEmpty)
    }

    /// Photos picked in the app go through the same importer.
    @Test func importedPhotosAskForAContinuedTask() async throws {
        let setup = try makeSetup(runner: StubRunner())
        let id = UUID()
        let stub = StubImporter(images: ImageImportResult(outcome: .imported(instanceID: id)))
        let background = setup.background
        let importer = BackgroundImportNotifying(base: stub) { background.userImported($0) }
        let controller = ImportController(
            importer: importer, reader: StubReader(), library: LibraryModel(source: EmptySource()))

        await controller.importPhotos([StubPhoto(data: Data([1]))])
        await setup.submits.wait(for: 1, "no continued request was submitted")

        #expect(setup.tasks.continuedRequests.count == 1)
        #expect(setup.background.tracked == [id])
    }

    /// A scan saved in the app (#5, part 2) goes through the same importer and asks for continued processing (P3:
    /// an import or scan started on this iPhone).
    @Test func aSavedScanAsksForAContinuedTask() async throws {
        let setup = try makeSetup(runner: StubRunner())
        let id = UUID()
        let stub = StubImporter(images: ImageImportResult(outcome: .imported(instanceID: id)))
        let background = setup.background
        let importer = BackgroundImportNotifying(base: stub) { background.userImported($0) }
        let controller = ImportController(
            importer: importer, reader: StubReader(), library: LibraryModel(source: EmptySource()))

        await controller.importScan(ScanImportTests.scan(1))
        await setup.submits.wait(for: 1, "no continued request was submitted")

        #expect(stub.imageImports.first?.source == .scan)
        #expect(setup.tasks.continuedRequests.count == 1)
        #expect(setup.background.tracked == [id])
    }

    /// A `Document` that another context inserts (a CloudKit import from the other device) runs the queue but never
    /// asks for continued processing (N4, P3).
    @Test func aCloudKitInsertionAsksForNoTask() async throws {
        let container = try makeInMemoryContainer()
        let insertions = ProcessingScheduler.documentInsertions(of: container)
        let setup = try makeSetup(runner: StubRunner(), container: container, insertions: insertions)
        defer { setup.scheduler.stop() }
        setup.scheduler.start()
        await setup.runs.wait(for: 1, "the launch run did not end")

        let context = ModelContext(container)
        context.insert(Document(title: "From the other device"))
        try context.save()
        await setup.runs.wait(for: 2, "the insertion did not run the queue")

        #expect(setup.tasks.continuedRequests.isEmpty, "an insertion asked for continued processing")
        #expect(setup.background.tracked.isEmpty)
        #expect(!setup.background.isContinuedRequested)
    }

    /// The progress counts the user's documents that are no longer open; the drain completes the task with
    /// success.
    @Test func progressCountsDocumentsAndTheDrainCompletes() async throws {
        let gate = Checkpoint()
        defer { gate.release() }
        let runner = StubRunner(gate: gate)
        let setup = try makeSetup(runner: runner)
        defer { setup.scheduler.stop() }
        setup.open.ofTracked = 3
        setup.background.userImported([UUID(), UUID(), UUID()])
        await setup.submits.wait(for: 1)
        #expect(setup.tasks.continuedRequests.first?.subtitle == BackgroundProcessing.texts(completed: 0, total: 3).1)

        let task = launchContinued(setup)
        #expect(setup.background.holdsWork)
        await gate.reached()
        #expect(task.reports.last?.completed == 0)
        #expect(task.reports.last?.total == 3)

        setup.open.ofTracked = 2
        setup.background.storeChanged()
        #expect(task.reports.last?.completed == 1)
        #expect(task.reports.last?.subtitle == BackgroundProcessing.texts(completed: 1, total: 3).subtitle)
        #expect(task.completions.isEmpty, "the task completed during the run")

        setup.open.ofTracked = 0
        gate.release()
        await task.completed.wait(for: 1, "the drain did not complete the task")
        #expect(task.completions == [true])
        #expect(task.reports.last?.completed == 3)
        #expect(!setup.background.holdsWork)
        #expect(setup.background.tracked.isEmpty)
        #expect(!setup.scheduler.isPaused, "the foreground keeps processing")
        #expect(runner.interrupts.count == 0)
    }

    /// A drain while one of the user's documents still waits (its backoff, another device's claim) ends the task
    /// without success instead of reporting "done" at "2 of 3" (review N3 of #129).
    @Test func aDrainWithAUserDocumentStillOpenEndsWithoutSuccess() async throws {
        let setup = try makeSetup(runner: StubRunner())
        defer { setup.scheduler.stop() }
        setup.open.ofTracked = 1
        setup.background.userImported([UUID(), UUID(), UUID()])
        await setup.submits.wait(for: 1)

        let task = launchContinued(setup)
        await task.completed.wait(for: 1, "the drain did not end the task")
        #expect(task.completions == [false])
        #expect(task.reports.last?.completed == 2)
        #expect(!setup.background.holdsWork)
    }

    // MARK: - A launch in the background (review B1 of #129)

    /// The system launched the terminated app for the processing task: no scene phase arrives. The expiry gives the
    /// attempt back and the queue stays paused, so no attempt runs into the suspension.
    @Test func anExpiryInABackgroundLaunchStaysPaused() async throws {
        let gate = Checkpoint()
        defer { gate.release() }
        let runner = StubRunner(gate: gate)
        let setup = try makeSetup(runner: runner)
        defer { setup.scheduler.stop() }
        setup.open.all = 1
        setup.open.applicationInForeground = false

        let task = setup.tasks.launch(BackgroundTaskIdentifier.processing)
        await gate.reached()
        task.expire()
        #expect(runner.interrupts.count == 1)
        #expect(task.completions == [false])
        #expect(setup.scheduler.isPaused, "after the expiry in a background launch the queue runs on unpaused")
        await setup.submits.wait(for: 1, "the processing task was not asked for again")
        #expect(setup.tasks.processingRequests == [BackgroundTaskIdentifier.processing])
    }

    /// The same launch: when the runs drain, the task completes and the queue is paused again.
    @Test func aDrainInABackgroundLaunchPauses() async throws {
        let setup = try makeSetup(runner: StubRunner())
        defer { setup.scheduler.stop() }
        setup.open.applicationInForeground = false

        let task = setup.tasks.launch(BackgroundTaskIdentifier.processing)
        await task.completed.wait(for: 1, "the drain did not complete the processing task")
        #expect(task.completions == [true])
        #expect(setup.scheduler.isPaused, "after the drain in a background launch the queue stays unpaused")
        #expect(setup.tasks.processingRequests.isEmpty, "nothing is open")
    }

    /// One document: "0 of 1 document", never "1 documents"; the German texts are the catalog's (P3).
    @Test func theTextsOfTheSystemProgress() throws {
        #expect(BackgroundProcessing.texts(completed: 0, total: 1).subtitle == String(localized: "\(0) of 1 document"))
        #expect(
            BackgroundProcessing.texts(completed: 2, total: 5).subtitle == String(localized: "\(2) of \(5) documents"))
        let path = try #require(Bundle.main.path(forResource: "de", ofType: "lproj"), "no German localization")
        let german = try #require(Bundle(path: path))
        func de(_ key: String) -> String { german.localizedString(forKey: key, value: "missing", table: nil) }
        #expect(de("Processing documents") == "Dokumente werden verarbeitet")
        #expect(String(format: de("%lld of 1 document"), 0) == "0 von 1 Dokument")
        #expect(String(format: de("%lld of %lld documents"), 3, 12) == "3 von 12 Dokumenten")
    }

    /// With the continued task holding the work, the background does not pause; its expiry pauses (the attempt is
    /// given back), completes with failure and asks for the processing task.
    @Test func theExpiryPausesGivesTheAttemptBackAndFails() async throws {
        let gate = Checkpoint()
        defer { gate.release() }
        let runner = StubRunner(gate: gate)
        let setup = try makeSetup(runner: runner)
        defer { setup.scheduler.stop() }
        setup.open.all = 1
        setup.open.ofTracked = 1
        setup.background.userImported([UUID()])
        await setup.submits.wait(for: 1)
        let task = launchContinued(setup)
        await gate.reached()

        setup.background.scenePhaseChanged(to: .background)
        #expect(!setup.scheduler.isPaused, "the background paused while the continued task holds the work")
        #expect(runner.interrupts.count == 0)

        task.expire()
        #expect(runner.interrupts.count == 1, "the expiry did not give the attempt back")
        #expect(setup.scheduler.isPaused)
        #expect(task.completions == [false])
        #expect(!setup.background.holdsWork)
        await setup.submits.wait(for: 2, "the processing task was not asked for")
        #expect(setup.tasks.processingRequests == [BackgroundTaskIdentifier.processing])
        gate.release()
        await setup.runs.wait(for: 1)
        #expect(task.completions == [false], "the drain completed an expired task")
    }

    /// An expiry in the foreground (the user stopped it) gives the attempt back and the queue goes on at once.
    @Test func anExpiryInTheForegroundResumes() async throws {
        let gate = Checkpoint()
        defer { gate.release() }
        let runner = StubRunner(gate: gate)
        let setup = try makeSetup(runner: runner)
        defer { setup.scheduler.stop() }
        setup.background.userImported([UUID()])
        await setup.submits.wait(for: 1)
        let task = launchContinued(setup)
        await gate.reached()

        task.expire()
        #expect(runner.interrupts.count == 1)
        #expect(task.completions == [false])
        #expect(!setup.scheduler.isPaused)
        #expect(setup.tasks.processingRequests.isEmpty)
    }

    /// When the system cannot start continued processing now (`.fail`), nothing waits for it: the next import asks
    /// again.
    @Test func aRefusedContinuedRequestIsAskedForAgainLater() async throws {
        let setup = try makeSetup(runner: StubRunner())
        setup.tasks.refusesContinued = true
        setup.background.userImported([UUID()])
        await setup.submits.wait(for: 1)
        #expect(!setup.background.isContinuedRequested)
        #expect(setup.background.tracked.isEmpty)

        setup.tasks.refusesContinued = false
        setup.background.userImported([UUID()])
        await setup.submits.wait(for: 2)
        #expect(setup.tasks.continuedRequests.count == 2)
    }

    // MARK: - Processing task

    /// Going to the background with open documents and no task pauses (part 1) and asks for one processing task;
    /// when it runs, the scheduler resumes, and the drain completes it and pauses again.
    @Test func theBackgroundWithOpenDocumentsAsksForOneProcessingTask() async throws {
        let runner = StubRunner()
        let setup = try makeSetup(runner: runner)
        defer { setup.scheduler.stop() }
        setup.open.all = 2

        setup.background.scenePhaseChanged(to: .background)
        #expect(setup.scheduler.isPaused)
        #expect(runner.interrupts.count == 1)
        await setup.submits.wait(for: 1, "the processing task was not asked for")
        #expect(setup.tasks.processingRequests == [BackgroundTaskIdentifier.processing])
        #expect(setup.tasks.continuedRequests.isEmpty)

        let task = setup.tasks.launch(BackgroundTaskIdentifier.processing)
        #expect(!setup.scheduler.isPaused, "the processing task did not resume the queue")
        await task.completed.wait(for: 1, "the drain did not complete the processing task")
        #expect(task.completions == [true])
        #expect(task.reports.isEmpty, "the processing task shows no progress")
        #expect(setup.scheduler.isPaused, "the background without a task did not pause again")
    }

    /// No open documents: the background pauses and asks for nothing.
    @Test func theBackgroundWithNothingOpenAsksForNothing() async throws {
        let runner = StubRunner()
        let setup = try makeSetup(runner: runner)
        setup.background.scenePhaseChanged(to: .background)
        #expect(setup.scheduler.isPaused)
        setup.background.scenePhaseChanged(to: .active)
        #expect(!setup.scheduler.isPaused)
        await setup.runs.wait(for: 1, "becoming active did not run the queue")
        #expect(setup.tasks.processingRequests.isEmpty)
        #expect(setup.submits.count == 0)
    }

    /// `ProcessingLifecycle` hands the scene's phases to the background work when there is one.
    @Test func theLifecycleHandsThePhaseToTheBackgroundWork() async throws {
        let runner = StubRunner()
        let setup = try makeSetup(runner: runner)
        ProcessingLifecycle.scenePhaseChanged(
            to: .background, scheduler: setup.scheduler, background: setup.background)
        #expect(!setup.background.isInForeground)
        #expect(setup.scheduler.isPaused)
        ProcessingLifecycle.scenePhaseChanged(to: .active, scheduler: setup.scheduler, background: setup.background)
        #expect(setup.background.isInForeground)
        #expect(!setup.scheduler.isPaused)
    }
}

/// A library with no documents.
@MainActor
private final class EmptySource: LibrarySource {
    let changes = AsyncStream<Void> { _ in }

    func snapshot() -> LibrarySnapshot { LibrarySnapshot(documents: []) }

    nonisolated func loadPDF(instanceID: UUID) async -> PDFLoadState { .noDocument }
}
