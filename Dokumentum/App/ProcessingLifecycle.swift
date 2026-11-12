import DokumentumCore
import Foundation
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// The processing queue and the app's lifecycle (#97 point 4, plan of #6, part 1). A known interruption gives the
/// running attempt back at once (`ProcessingScheduler.pause()`, synchronous), so it never counts as a failure:
/// - **iOS:** the scene going to the background pauses, before the system suspends the app; a later kill of the
///   suspended app (swiping it away) then leaves nothing counted. Becoming active resumes and runs the queue.
///   With `BackgroundProcessing` (iOS, plan of #6, part 5), a background task that holds the work keeps it going
///   instead, and the processing task is asked for what is left.
/// - **macOS:** the app keeps processing while it runs, in the background too; quitting
///   (`NSApplication.willTerminateNotification`) pauses. Becoming active resumes like any trigger.
///
/// A crash, an out-of-memory kill or a power loss during a stage is not known here and still counts.
@MainActor
enum ProcessingLifecycle {
    /// What a change of the app's scene phase does to the processing queue.
    static func scenePhaseChanged(
        to phase: ScenePhase, scheduler: ProcessingScheduler?, background: BackgroundProcessing? = nil
    ) {
        if let background {
            background.scenePhaseChanged(to: phase)
            return
        }
        switch phase {
        case .active:
            scheduler?.resume()
        case .background:
            #if os(iOS)
                scheduler?.pause()
            #endif
        default:
            break
        }
    }

    #if os(macOS)
        /// Pauses `scheduler` when the app quits. The observer and the scheduler live as long as the app; tests remove
        /// the observer with the token.
        @discardableResult
        static func pauseWhenTerminating(
            _ scheduler: ProcessingScheduler, center: NotificationCenter = .default
        ) -> any NSObjectProtocol {
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { scheduler.pause() }
            }
        }
    #endif
}
