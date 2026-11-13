#if os(iOS)
    import BackgroundTasks
    import DokumentumCore
    import Foundation
    import Synchronization

    /// A submission `SystemBackgroundTasks` refused before it reached `BGTaskScheduler` (#194).
    enum BackgroundTaskSubmissionError: Error, Equatable {
        /// No launch handler is registered for exactly this identifier in this process. The SDK would raise an
        /// Objective-C exception (`NSInternalInconsistencyException`, "No launch handler registered for task with
        /// identifier …"), which no `catch` can handle.
        case notRegistered(String)
    }

    /// `BGTaskScheduler` for `BackgroundProcessing` (plan of #6, part 5; #194). Launch handlers run on the main queue;
    /// the SDK calls an expiration handler on any thread, and this one runs it on the main actor at once
    /// (synchronously), so the attempt is given back before the system suspends the app. Requests are submitted off
    /// the main thread, as the SDK asks.
    ///
    /// The identifiers it registered successfully form one process-wide set, the authority on what is registered with
    /// the real SDK in this process (`BackgroundTaskRegistry` only tracks what `register()` asked for at launch). Both
    /// guards consult only this set, by the exact identifier, never by a prefix (the SDK's own lookup is exact):
    /// - a second registration of an identifier returns `false` without calling the SDK, which would kill the app;
    /// - a submission of an identifier without a registration throws `notRegistered` before calling the SDK, which
    ///   would raise an exception.
    ///
    /// Registration and submission are tested on the simulator (`SystemBackgroundTasksTests`); the tasks themselves
    /// cannot run there (maintainer step M5 of #6, the device check of #194).
    @MainActor
    final class SystemBackgroundTasks: BackgroundTaskScheduling {
        /// The identifiers registered with `BGTaskScheduler` in this process.
        nonisolated private static let registered = Mutex<Set<String>>([])

        /// Whether `identifier` (exactly) was registered with `BGTaskScheduler` in this process.
        nonisolated static func isRegistered(_ identifier: String) -> Bool {
            registered.withLock { $0.contains(identifier) }
        }

        func register(
            _ identifier: String, launchHandler: @escaping @MainActor (any BackgroundTaskHandle) -> Void
        ) -> Bool {
            Self.registered.withLock { registered in
                guard !registered.contains(identifier) else { return false }
                let accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) {
                    task in
                    MainActor.assumeIsolated { launchHandler(SystemBackgroundTask(task)) }
                }
                if accepted { registered.insert(identifier) }
                return accepted
            }
        }

        @concurrent
        nonisolated func submitContinued(identifier: String, title: String, subtitle: String) async throws {
            guard Self.isRegistered(identifier) else { throw BackgroundTaskSubmissionError.notRegistered(identifier) }
            let request = Self.continuedRequest(identifier: identifier, title: title, subtitle: subtitle)
            try await BGTaskScheduler.shared.submitTaskRequest(request)
        }

        @concurrent
        nonisolated func submitProcessing(identifier: String) async throws {
            guard Self.isRegistered(identifier) else { throw BackgroundTaskSubmissionError.notRegistered(identifier) }
            try await BGTaskScheduler.shared.submitTaskRequest(Self.processingRequest(identifier: identifier))
        }

        /// Continued processing that starts now or not at all (`.fail`, T13), with the default resources: the GPU
        /// needs another entitlement.
        nonisolated static func continuedRequest(
            identifier: String, title: String, subtitle: String
        ) -> BGContinuedProcessingTaskRequest {
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            request.strategy = .fail
            return request
        }

        /// The processing task needs neither external power nor the network (T13).
        nonisolated static func processingRequest(identifier: String) -> BGProcessingTaskRequest {
            let request = BGProcessingTaskRequest(identifier: identifier)
            request.requiresExternalPower = false
            request.requiresNetworkConnectivity = false
            return request
        }
    }

    /// One task the system started.
    @MainActor
    final class SystemBackgroundTask: BackgroundTaskHandle {
        private let task: BGTask

        init(_ task: BGTask) {
            self.task = task
        }

        /// The SDK does not name the handler's queue. On the main thread the handler runs at once; elsewhere this
        /// waits with `DispatchQueue.main.sync` until the main actor ran it, so the attempt is given back before the
        /// handler returns and the system suspends the app (an async hop could run after the suspension). It cannot
        /// deadlock: the main thread never waits synchronously for the queue the SDK runs this on, and nothing in the
        /// app blocks the main thread on BackgroundTasks (review N2 of #129). A main thread busy with a long job
        /// delays the refund until that job ends (M5).
        func onExpiration(_ handler: @escaping @MainActor @Sendable () -> Void) {
            task.expirationHandler = {
                if Thread.isMainThread {
                    MainActor.assumeIsolated { handler() }
                } else {
                    DispatchQueue.main.sync { MainActor.assumeIsolated { handler() } }
                }
            }
        }

        func report(completed: Int, total: Int, title: String, subtitle: String) {
            guard let continued = task as? BGContinuedProcessingTask else { return }
            continued.progress.totalUnitCount = Int64(total)
            continued.progress.completedUnitCount = Int64(completed)
            continued.updateTitle(title, subtitle: subtitle)
        }

        func complete(success: Bool) {
            task.setTaskCompleted(success: success)
        }
    }
#endif
