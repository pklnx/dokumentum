#if os(iOS)
    import BackgroundTasks
    import DokumentumCore
    import Foundation

    /// `BGTaskScheduler` for `BackgroundProcessing` (plan of #6, part 5). Launch handlers run on the main queue; the
    /// SDK calls an expiration handler on any thread, and this one runs it on the main actor at once (synchronously),
    /// so the attempt is given back before the system suspends the app. Requests are submitted off the main thread,
    /// as the SDK asks. Not covered by tests: the simulator cannot run background tasks (maintainer step M5).
    @MainActor
    final class SystemBackgroundTasks: BackgroundTaskScheduling {
        func register(
            _ identifier: String, launchHandler: @escaping @MainActor (any BackgroundTaskHandle) -> Void
        ) -> Bool {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                MainActor.assumeIsolated { launchHandler(SystemBackgroundTask(task)) }
            }
        }

        @concurrent
        nonisolated func submitContinued(identifier: String, title: String, subtitle: String) async throws {
            let request = Self.continuedRequest(identifier: identifier, title: title, subtitle: subtitle)
            try await BGTaskScheduler.shared.submitTaskRequest(request)
        }

        @concurrent
        nonisolated func submitProcessing(identifier: String) async throws {
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
