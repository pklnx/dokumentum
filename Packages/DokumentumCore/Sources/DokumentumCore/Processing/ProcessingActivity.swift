import Foundation

/// Keeps the system from slowing the app down while the processing queue runs (#130): on the Mac, App Nap would
/// otherwise throttle a run whose window is hidden or covered. `ProcessingScheduler` begins it at the start of each
/// drain (the run and the runs queued during it) and ends it when the drain ends, also after `pause()`.
@MainActor
public protocol ProcessingActivityHolding: AnyObject {
    /// Begins the activity; a second `begin()` without an `end()` does nothing.
    func begin()
    /// Ends the activity; does nothing when none was begun or it already ended.
    func end()
}

/// The holder where nothing needs to be held: iOS (its background tasks, #117, cover the runs) and tests.
@MainActor
public final class NoProcessingActivity: ProcessingActivityHolding {
    public init() {}
    public func begin() {}
    public func end() {}
}

#if os(macOS)
    /// The Mac's holder: a `ProcessInfo` activity with `.userInitiatedAllowingIdleSystemSleep`, which keeps App Nap
    /// off for the run but never keeps an idle Mac awake.
    @MainActor
    public final class SystemProcessingActivity: ProcessingActivityHolding {
        /// The token of the activity that is going on; cleared by `end()`, so a second `end()` is a no-op.
        private var token: (any NSObjectProtocol)?

        public init() {}

        /// Whether an activity is going on. For tests.
        public var isActive: Bool { token != nil }

        public func begin() {
            guard token == nil else { return }
            token = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Processing documents")
        }

        public func end() {
            guard let token else { return }
            self.token = nil
            ProcessInfo.processInfo.endActivity(token)
        }
    }
#endif
