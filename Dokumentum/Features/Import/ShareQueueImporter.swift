#if os(iOS)
    import DokumentumCore
    import DokumentumKit
    import Foundation
    import Observation
    import UniformTypeIdentifiers

    /// Imports what the share extension left in the app group's queue (plan of #4, part 4). iOS only: the Mac
    /// has no app group and no share extension.
    ///
    /// - **When:** at launch and on every `scenePhase == .active` (`DokumentumApp`). A launch produces `.active`
    ///   too, so **one run at a time**: a request during a run queues exactly one more run, however many arrive
    ///   (#56's `RepairScheduler`). No item is attempted twice by overlapping runs.
    /// - **How:** oldest item first, through the app's one `DocumentImporter` (so after any window's own imports),
    ///   with the item's type (a PDF as `.file`, an image always as `.image`) and its name as data
    ///   (`ShareQueue.fileName(fromShared:)`). Before it imports an item, the run counts an attempt in the item.
    /// - **Removal:** an item is removed only after its document was saved, or after the importer reported it as
    ///   a duplicate. A failure keeps it for the next run; its third failure moves it to `Failed/`, which nothing
    ///   empties (PQ6). A crash between the save and the removal imports the item again next time, which the
    ///   duplicate check turns into a duplicate, and then it is removed: no second document.
    /// - **What the user sees:** no selection, nothing opened (PQ12); the Inbox lists the new documents. A run
    ///   with duplicates or with items moved to `Failed/` leaves a report, which the window shows as the usual
    ///   notice (PQ4). Failures that are tried again are not reported yet, so a notice names each such item once.
    /// - **Where:** the group container from `containerURL(forSecurityApplicationGroupIdentifier:)`. Without one
    ///   (no entitlement) the importer is off. A run that stays away from real data (`TestEnvironment.isIsolated`:
    ///   unit tests in the app host, UI tests' in-memory stores; and every `-UITestLocalStore` launch) refuses the
    ///   real group container
    ///   (`ArchiveStore.isLiveStorePath`), as the store does; tests pass a temporary folder.
    @MainActor @Observable
    final class ShareQueueImporter {
        /// The work of one run, off the main actor.
        let runner: ShareQueueRunner

        /// The reports to show, oldest first; `takeReports()` hands them to the window.
        private(set) var reports: [ImportReport] = []
        /// Whether a request arrived during the run that is going on, so one more run follows it.
        private(set) var isQueued = false
        /// How many runs ended. For tests.
        private(set) var completedRuns = 0
        /// Called after each run with its report. For tests, which wait for it instead of polling.
        @ObservationIgnored var didFinishRun: (@MainActor (ImportReport) -> Void)?

        @ObservationIgnored private var running: Task<Void, Never>?

        init(runner: ShareQueueRunner) {
            self.runner = runner
        }

        /// The app's importer on the app group's queue, or `nil` when there is no group container or the run
        /// must not touch it (`queue(groupContainer:isIsolated:)`).
        static func forApp(importer: any DocumentImporting) -> ShareQueueImporter? {
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: ShareQueue.appGroupIdentifier)
            let isolated = isIsolatedLaunch(
                isIsolated: TestEnvironment.isIsolated, arguments: ProcessInfo.processInfo.arguments)
            guard let queue = queue(groupContainer: container, isIsolated: isolated) else {
                return nil
            }
            return ShareQueueImporter(runner: ShareQueueRunner(queue: queue, importer: importer))
        }

        /// The queue in `groupContainer`, or `nil`: without a container (no app group entitlement), and in a run
        /// that stays away from real data when the folder is where real data lives (`isLiveStorePath`: the app
        /// group). Tests pass a temporary folder.
        nonisolated static func queue(groupContainer: URL?, isIsolated: Bool) -> ShareQueue? {
            guard let groupContainer else {
                Log.importing.error("No app group container; the share queue is not imported")
                return nil
            }
            if isIsolated && ArchiveStore.isLiveStorePath(groupContainer) {
                Log.importing.notice("An isolated run leaves the app group's share queue alone")
                return nil
            }
            return ShareQueue(groupContainer: groupContainer)
        }

        /// Whether this launch must leave the real queue alone: a run that stays away from real data
        /// (`TestEnvironment.isIsolated`), and also a UI test's launch with a local store on disk
        /// (`-UITestLocalStore`, DEBUG), which is not isolated for the store but must not take the device's shared
        /// items into its throwaway store (review of #85, B-N1).
        nonisolated static func isIsolatedLaunch(isIsolated: Bool, arguments: [String]) -> Bool {
            #if DEBUG
                if arguments.contains(UITestLocalStore.argument) { return true }
            #endif
            return isIsolated
        }

        /// Runs now, or once more after the run that is going on.
        func requestRun() {
            guard running == nil else {
                isQueued = true
                return
            }
            running = Task { [weak self] in await self?.drain() }
        }

        /// The reports not shown yet, oldest first; they are handed over once.
        func takeReports() -> [ImportReport] {
            defer { reports = [] }
            return reports
        }

        private func drain() async {
            repeat {
                isQueued = false
                let report = await runner.run()
                completedRuns += 1
                if report.notice(.app) != nil { reports.append(report) }
                didFinishRun?(report)
            } while isQueued
            running = nil
        }
    }

    /// One pass over the queue (see `ShareQueueImporter`). Nonisolated: the payloads are read and the queue's
    /// files written off the main actor.
    struct ShareQueueRunner: Sendable {
        let queue: ShareQueue
        let importer: any DocumentImporting
        let now: @Sendable () -> Date
        /// Tests only: runs before the item's import, after its attempt was counted.
        let willImport: (@Sendable (ShareQueueItem) async -> Void)?
        /// Tests only: asked after a save or a duplicate, before the item is removed; `false` skips the removal,
        /// as a crash at that point would (the crash case).
        let shouldRemove: (@Sendable (ShareQueueItem) async -> Bool)?

        init(
            queue: ShareQueue, importer: any DocumentImporting, now: @escaping @Sendable () -> Date = { Date() },
            willImport: (@Sendable (ShareQueueItem) async -> Void)? = nil,
            shouldRemove: (@Sendable (ShareQueueItem) async -> Bool)? = nil
        ) {
            self.queue = queue
            self.importer = importer
            self.now = now
            self.willImport = willImport
            self.shouldRemove = shouldRemove
        }

        /// Imports every item, oldest first, and returns the run's report: one entry per item imported, skipped
        /// as a duplicate, or moved to `Failed/`. Items kept for another attempt are not in it.
        @concurrent
        func run() async -> ImportReport {
            var report = ImportReport()
            let stale = queue.removeStaleIncoming(now: now())
            let scan = queue.scan()
            if stale > 0 || !scan.movedToFailed.isEmpty || !scan.newerVersion.isEmpty {
                Log.importing.notice(
                    """
                    Share queue: \(stale, privacy: .public) unfinished items removed, \
                    \(scan.movedToFailed.count, privacy: .public) unreadable moved to Failed, \
                    \(scan.newerVersion.count, privacy: .public) of a newer version left
                    """)
            }
            for item in scan.items {
                if let entry = await importItem(item) { report.add(fileName: entry.fileName, outcome: entry.outcome) }
            }
            Log.importing.notice(
                """
                Share queue run: \(scan.items.count, privacy: .public) items, \
                \(report.imported.count, privacy: .public) imported, \
                \(report.duplicates.count, privacy: .public) duplicates, \
                \(report.failures.count, privacy: .public) moved to Failed
                """)
            return report
        }

        /// One item: its entry in the report, or `nil` when it stays for another attempt.
        private func importItem(_ item: ShareQueueItem) async -> ImportReport.Entry? {
            let fileName = item.fileName
            // A crash during an earlier attempt can leave an item with no attempt left.
            if item.hasNoAttemptsLeft {
                return moveToFailed(item, outcome: .failed(.couldNotRead))
            }
            let attempted: ShareQueueItem
            do {
                attempted = try queue.recordAttempt(item)
            } catch {
                Log.importing.error("Share queue: attempt not recorded: \(Log.code(of: error), privacy: .public)")
                return nil
            }
            if let willImport { await willImport(attempted) }
            let outcome: ImportOutcome
            do {
                // Only a regular file: a link is never followed out of the queue (review of #85). Mapped, not
                // copied (#98): the attempt above is counted first, so a payload that crashes the read is bounded.
                let data = try queue.payload(of: attempted)
                outcome = await importer.importFile(
                    data: data, fileName: fileName, contentType: UTType(attempted.info.typeIdentifier),
                    source: .file)
            } catch {
                Log.importing.error("Share queue: payload not read: \(Log.code(of: error), privacy: .public)")
                outcome = .failed(.couldNotRead)
            }
            switch outcome {
            case .imported, .duplicate:
                // Saved, or already in the archive: only now the item may go.
                if let shouldRemove, !(await shouldRemove(attempted)) { return nil }
                do {
                    try queue.remove(attempted.id)
                } catch {
                    Log.importing.error("Share queue: item not removed: \(Log.code(of: error), privacy: .public)")
                }
                return ImportReport.Entry(fileName: fileName, outcome: outcome)
            case .failed:
                guard attempted.hasNoAttemptsLeft else { return nil }
                return moveToFailed(attempted, outcome: outcome)
            }
        }

        private func moveToFailed(_ item: ShareQueueItem, outcome: ImportOutcome) -> ImportReport.Entry? {
            do {
                try queue.moveToFailed(item.id)
            } catch {
                Log.importing.error("Share queue: item not moved to Failed: \(Log.code(of: error), privacy: .public)")
                return nil
            }
            Log.importing.notice(
                "Share queue: an item moved to Failed after \(item.info.attempts, privacy: .public) attempts")
            return ImportReport.Entry(fileName: item.fileName, outcome: outcome)
        }
    }
#endif
