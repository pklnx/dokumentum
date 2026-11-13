import DokumentumCore
import DokumentumKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The task identifiers of the background work (plan of #6, T13 and N4; #194). They do not overlap: the continued
/// tasks' wildcard covers only identifiers under `continued.`, never the processing task's. `Config/Info-iOS.plist`
/// permits exactly `permitted` (`BGTaskSchedulerPermittedIdentifiers`; `scripts/check-project.py` pins the list).
enum BackgroundTaskIdentifier {
    /// The prefix of every continued-processing task. Each request registers and submits its own identifier,
    /// `continuedPrefix` followed by a new UUID, just before its submission (#194).
    static let continuedPrefix = "space.pklnx.Dokumentum.continued."
    /// The wildcard the Info.plist permits for continued processing (wildcard notation of the SDK). It is never
    /// registered or submitted itself: the SDK refuses to register it, and a submission looks the handler up by the
    /// exact identifier (#194).
    static let continued = continuedPrefix + "*"
    /// The one processing task for what is left when the app goes to the background.
    static let processing = "space.pklnx.Dokumentum.backgroundProcessing"

    /// Exactly the Info.plist's `BGTaskSchedulerPermittedIdentifiers`.
    static let permitted = [continued, processing]
    /// What `BackgroundProcessing.register()` registers at launch: only the processing task. The SDK exempts
    /// continued-processing registrations from the launch deadline, and each continued request registers its own.
    static let registeredAtLaunch = [processing]
}

/// The launch identifiers `BackgroundProcessing.register()` has already asked for in this process (`process`), so a
/// second instance asks for none again; tests pass their own. Nothing else consults it: what is registered with the
/// real SDK is `SystemBackgroundTasks`' own set, which alone guards submissions and second registrations.
@MainActor
final class BackgroundTaskRegistry {
    /// The one registry of the process.
    static let process = BackgroundTaskRegistry()

    fileprivate(set) var registered: Set<String> = []
}

/// A background task the system started (`BGContinuedProcessingTask`, `BGProcessingTask`); a fake in tests.
@MainActor
protocol BackgroundTaskHandle: AnyObject {
    /// Called on the main actor when the system ends the task before it completed.
    func onExpiration(_ handler: @escaping @MainActor @Sendable () -> Void)
    /// The progress the system shows (continued processing; the processing task shows none).
    func report(completed: Int, total: Int, title: String, subtitle: String)
    /// Tells the system the task is over.
    func complete(success: Bool)
}

/// `BGTaskScheduler` behind a protocol, so app tests use a fake (`SystemBackgroundTasks` on iOS).
@MainActor
protocol BackgroundTaskScheduling: AnyObject {
    /// Registers `launchHandler` for exactly `identifier`; `false` when the system refuses (not permitted, the
    /// wildcard itself, or already registered).
    func register(_ identifier: String, launchHandler: @escaping @MainActor (any BackgroundTaskHandle) -> Void) -> Bool
    /// Submits a continued-processing request with the strategy `.fail`: it throws when the system cannot start the
    /// task now.
    func submitContinued(identifier: String, title: String, subtitle: String) async throws
    /// Submits the processing request (no external power, no network); it replaces one not yet run.
    func submitProcessing(identifier: String) async throws
}

/// The background work of the processing queue on iOS (plan of #6, part 5, T13, N4, P3). It only calls the
/// scheduler (`resume()`, `pause()`); the queue and its rules do not know about it.
///
/// - **Continued processing** (`BGContinuedProcessingTask`, strategy `.fail`): asked for only when a **user's**
///   import on this device completed (`userImported`: files, photos, the share queue, #5's scans, all through the
///   app's importer, `BackgroundImportNotifying`). A document that arrives through CloudKit never starts one (P3).
///   While it runs, the system shows "Processing documents" and how many of the user's documents are done
///   (progress, required by the SDK), updated after each store change and at the end. When the runs drain, it
///   completes with success. If the system cannot start it now, the work waits for the next foreground run or the
///   processing task.
/// - **Processing task** (`BGProcessingTask`): when the app goes to the background with open documents and no task
///   holds the work, the scheduler is paused (part 1) and one processing request is submitted; when the system runs
///   it, the scheduler resumes until the runs drain.
/// - **Expiry:** the scheduler is paused, which gives the running attempt back (`interruptNow()`, part 1), and the
///   task completes with failure. In the foreground the queue goes on at once.
/// - **Registration (#194):** launch registers only the processing task. Each continued request registers its own
///   `continued.<UUID>` just before it is submitted, and is submitted only when that registration succeeded. Each
///   identifier is registered once per process: the SDK kills an app that registers one twice.
/// - **The Sync lab's hold** (#31, T14; Debug builds): while the scheduler is held (`ProcessingScheduler.isHeld`), an
///   import asks for no continued processing, so no "Processing documents" progress shows that could not move, and a
///   processing task that starts completes at once instead of waiting for a drain that cannot come.
@MainActor
final class BackgroundProcessing {
    private let scheduler: ProcessingScheduler
    private let tasks: any BackgroundTaskScheduling
    /// How many of the given documents (all, for `nil`) are still open (`OpenDocuments.count`).
    private let openDocuments: @MainActor (Set<UUID>?) -> Int

    /// The identifiers registered in this process, across instances: a second registration would kill the app.
    private let registry: BackgroundTaskRegistry

    /// The user's documents of the continued task that is asked for or running.
    private(set) var tracked: Set<UUID> = []
    /// The identifier of the continued request that was registered and submitted and has not started or failed yet.
    private var requestedContinued: String?
    /// Whether a continued request was submitted and has not started or failed yet.
    var isContinuedRequested: Bool { requestedContinued != nil }
    /// The running continued-processing task, and its identifier (for the log).
    private var continued: (any BackgroundTaskHandle)?
    private var continuedIdentifier = ""
    /// The running processing task.
    private var processing: (any BackgroundTaskHandle)?
    /// Whether the application itself is in the foreground (`UIApplication.applicationState != .background` in the
    /// app). Asked, not assumed: the system launches a terminated app for the processing task in the background, and
    /// then no scene phase change arrives (review B1 of #129).
    private let applicationIsInForeground: @MainActor () -> Bool
    /// The last scene phase `ProcessingLifecycle` handed over, if any.
    private var scenePhase: ScenePhase?

    /// Whether the app is in the foreground: the last scene phase is not `.background` and the application is not in
    /// the background. Before any scene phase arrived (a launch in the background), only the application counts.
    var isInForeground: Bool {
        if scenePhase == .background { return false }
        return applicationIsInForeground()
    }

    /// Whether a background task holds the work, so going to the background does not pause.
    var holdsWork: Bool { continued != nil || processing != nil }

    /// Called after each submission attempt with its identifier and whether it was accepted. For tests, which
    /// wait for it instead of polling.
    var didSubmit: (@MainActor (String, Bool) -> Void)?

    init(
        scheduler: ProcessingScheduler, tasks: any BackgroundTaskScheduling,
        openDocuments: @escaping @MainActor (Set<UUID>?) -> Int,
        applicationIsInForeground: @escaping @MainActor () -> Bool, registry: BackgroundTaskRegistry = .process
    ) {
        self.applicationIsInForeground = applicationIsInForeground
        self.scheduler = scheduler
        self.tasks = tasks
        self.openDocuments = openDocuments
        self.registry = registry
        scheduler.didDrain = { [weak self] in self?.drained() }
    }

    /// Registers the processing task's launch handler, once per process. Call before the app finishes launching.
    /// Continued requests register their own identifiers in `userImported`.
    func register() {
        for identifier in BackgroundTaskIdentifier.registeredAtLaunch
        where registry.registered.insert(identifier).inserted {
            let accepted = tasks.register(identifier) { [weak self] task in self?.processingStarted(task) }
            if !accepted {
                Log.processing.error("Background task not registered: \(identifier, privacy: .public)")
            }
        }
    }

    /// A user's import on this device completed with these new documents: asks for a continued-processing task,
    /// or adds them to the one asked for or running.
    func userImported(_ instanceIDs: [UUID]) {
        guard !instanceIDs.isEmpty else { return }
        // A held scheduler processes nothing until the hold ends (the Sync lab, #31 T14): no progress to show.
        guard !scheduler.isHeld else { return }
        tracked.formUnion(instanceIDs)
        if continued != nil {
            reportProgress()
            return
        }
        guard !isContinuedRequested else { return }
        // After every guard: a new identifier per request, registered just before its submission (#194). The SDK
        // looks the handler up by the exact identifier and raises an exception for one without a handler.
        let identifier = BackgroundTaskIdentifier.continuedPrefix + UUID().uuidString
        let accepted = tasks.register(identifier) { [weak self] task in
            self?.continuedStarted(task, identifier: identifier)
        }
        guard accepted else {
            // Nothing is submitted; the foreground runs or the processing task do the work, the next import asks
            // again with a new identifier.
            Log.processing.error("Background task not registered: \(identifier, privacy: .public)")
            tracked = []
            didSubmit?(identifier, false)
            return
        }
        requestedContinued = identifier
        let (title, subtitle) = Self.texts(completed: 0, total: tracked.count)
        let tasks = tasks
        Task {
            do {
                try await tasks.submitContinued(identifier: identifier, title: title, subtitle: subtitle)
                Log.processing.notice("Continued processing requested: \(identifier, privacy: .public)")
                didSubmit?(identifier, true)
            } catch {
                // `.fail`: the system cannot start it now. The foreground runs or the processing task do the work.
                Log.processing.notice("Continued processing not started: \(Log.code(of: error), privacy: .public)")
                if continued == nil {
                    requestedContinued = nil
                    tracked = []
                }
                didSubmit?(identifier, false)
            }
        }
    }

    /// The scene's phase changed (`ProcessingLifecycle`).
    func scenePhaseChanged(to phase: ScenePhase) {
        scenePhase = phase
        switch phase {
        case .active:
            scheduler.resume()
        case .background:
            // A background task keeps the work going; otherwise the running attempt is given back before the
            // system suspends the app (part 1), and the processing task does the rest later.
            guard !holdsWork else { return }
            scheduler.pause()
            requestProcessingIfOpen()
        default:
            break
        }
    }

    /// The store changed: a result write may have finished one of the user's documents.
    func storeChanged() {
        reportProgress()
    }

    /// Updates the progress after each of `changes` (the app's debounced store changes). Lives as long as the app.
    func followStoreChanges(_ changes: AsyncStream<Void>) {
        Task { [weak self] in
            for await _ in changes { self?.storeChanged() }
        }
    }

    // MARK: - Tasks

    /// The system started the continued task registered as `identifier`. A launch of a request that is no longer
    /// asked for (an earlier one that failed, #194 T2) completes at once and changes nothing, so two continued tasks
    /// never interleave.
    private func continuedStarted(_ task: any BackgroundTaskHandle, identifier: String) {
        guard identifier == requestedContinued else {
            Log.processing.notice("Continued processing launch ignored: \(identifier, privacy: .public)")
            task.complete(success: false)
            return
        }
        Log.processing.notice("Continued processing started: \(identifier, privacy: .public)")
        requestedContinued = nil
        continued = task
        continuedIdentifier = identifier
        task.onExpiration { [weak self, weak task] in
            guard let self, let task else { return }
            self.expired(task)
        }
        reportProgress()
        // Runs the queue: once more after a run that is going on, so the task always sees the runs drain.
        scheduler.resume()
    }

    private func processingStarted(_ task: any BackgroundTaskHandle) {
        // A held scheduler never drains (the Sync lab, #31 T14): the task ends at once, and the scheduler stays as
        // it was (paused in the background).
        guard !scheduler.isHeld else {
            task.complete(success: false)
            return
        }
        processing = task
        task.onExpiration { [weak self, weak task] in
            guard let self, let task else { return }
            self.expired(task)
        }
        scheduler.resume()
    }

    /// The runs ended and none follows: every running task completes. The continued task succeeds when none of the
    /// user's documents is open any more. One that still waits (its backoff, another device's claim, its file data)
    /// ends it without success instead of keeping it: such a wait can last hours (a claim waits up to 6 h), the system
    /// expires a task whose progress stands still, and the processing task or the next foreground run does the rest
    /// (review N3 of #129).
    private func drained() {
        reportProgress()
        if let continued {
            let success = openDocuments(tracked) == 0
            self.continued = nil
            tracked = []
            Log.processing.notice(
                "Continued processing ended: \(self.continuedIdentifier, privacy: .public) success=\(success)")
            continued.complete(success: success)
        }
        if let processing {
            self.processing = nil
            processing.complete(success: true)
        }
        holdBackgroundWorkIfNeeded()
    }

    /// The system ended `task` early: the attempt is given back, the task fails.
    private func expired(_ task: any BackgroundTaskHandle) {
        if task === continued {
            Log.processing.notice("Continued processing expired: \(self.continuedIdentifier, privacy: .public)")
            continued = nil
            tracked = []
        } else if task === processing {
            processing = nil
        } else {
            return
        }
        // The refund is synchronous, before the system suspends the app (part 1).
        scheduler.pause()
        task.complete(success: false)
        if isInForeground || holdsWork {
            scheduler.resume()
        } else {
            requestProcessingIfOpen()
        }
    }

    /// In the background with no task left, the scheduler is paused as part 1 does, and the processing task is
    /// asked for what is left.
    private func holdBackgroundWorkIfNeeded() {
        guard !isInForeground, !holdsWork else { return }
        scheduler.pause()
        requestProcessingIfOpen()
    }

    private func requestProcessingIfOpen() {
        guard openDocuments(nil) > 0 else { return }
        let identifier = BackgroundTaskIdentifier.processing
        let tasks = tasks
        Task {
            do {
                try await tasks.submitProcessing(identifier: identifier)
                didSubmit?(identifier, true)
            } catch {
                Log.processing.notice("Processing task not submitted: \(Log.code(of: error), privacy: .public)")
                didSubmit?(identifier, false)
            }
        }
    }

    private func reportProgress() {
        guard let continued, !tracked.isEmpty else { return }
        let total = tracked.count
        let completed = max(0, total - openDocuments(tracked))
        let (title, subtitle) = Self.texts(completed: completed, total: total)
        continued.report(completed: completed, total: total, title: title, subtitle: subtitle)
    }

    /// The system progress's texts (P3): "Processing documents", "3 of 12 documents".
    static func texts(completed: Int, total: Int) -> (title: String, subtitle: String) {
        let title = String(localized: "Processing documents")
        let subtitle =
            total == 1
            ? String(localized: "\(completed) of 1 document")
            : String(localized: "\(completed) of \(total) documents")
        return (title, subtitle)
    }
}

/// The app's importer, telling `BackgroundProcessing` about each new document (N4): every user import on this
/// device goes through it (the windows' files and photos, the share queue, #5's scans), and nothing else does, so a
/// document from CloudKit never starts a continued-processing task.
struct BackgroundImportNotifying: DocumentImporting {
    let base: any DocumentImporting
    let imported: @MainActor @Sendable ([UUID]) -> Void

    func importFile(data: Data, fileName: String, contentType: UTType?, source: DocumentSource) async
        -> ImportOutcome
    {
        let outcome = await base.importFile(data: data, fileName: fileName, contentType: contentType, source: source)
        await notify(outcome)
        return outcome
    }

    func importImages(_ items: [Data], fileName: String, title: String?, source: DocumentSource) async
        -> ImageImportResult
    {
        let result = await base.importImages(items, fileName: fileName, title: title, source: source)
        await notify(result.outcome)
        return result
    }

    func importEditedImages(_ items: [EditedImage], title: String, source: DocumentSource) async
        -> ImageImportResult
    {
        let result = await base.importEditedImages(items, title: title, source: source)
        await notify(result.outcome)
        return result
    }

    private func notify(_ outcome: ImportOutcome) async {
        guard case .imported(let instanceID) = outcome else { return }
        await imported([instanceID])
    }
}
