import DokumentumCore
import Foundation
import Observation
import SwiftData

/// "Apply Matching Rules to All Documents…" in the settings (plan of #10, §9; maintainer's P3): the confirmation, the
/// run with its progress and Cancel, and the result. The app holds one, so the Mac's Settings window and the iPhone's
/// settings sheet show the same run; `MatchingRun` itself runs one at a time per instance.
///
/// The run is `MatchingRun.run` off the main actor; its progress arrives through a stream and is shown on the main
/// actor in order. Cancel cancels the run's task: `MatchingRun` stops between batches and reports what it saved.
@MainActor @Observable
final class MatchingRunModel {
    /// One run: reports progress to its argument, returns the report (`nil` when a run is going on already).
    typealias Run =
        @Sendable (_ progress: @escaping @Sendable (MatchingRun.Progress) -> Void) async -> MatchingRun.Report?

    enum Phase: Equatable {
        /// Nothing has run since the app started.
        case idle
        /// Running; the progress after the newest batch, `nil` before the first.
        case running(MatchingRun.Progress?)
        /// The last run's report.
        case finished(MatchingRun.Report)
    }

    private(set) var phase = Phase.idle
    /// Whether the confirmation is shown.
    var isConfirming = false
    /// The running run's task, for tests: they await its `value`.
    private(set) var task: Task<Void, Never>?
    private let run: Run

    init(run: @escaping Run) {
        self.run = run
    }

    /// The app's model on its container.
    convenience init(container: ModelContainer) {
        let matchingRun = MatchingRun(container: container)
        self.init { progress in await matchingRun.run(progress: progress) }
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// The button: asks first (P3).
    func requestApply() {
        guard !isRunning else { return }
        isConfirming = true
    }

    /// The confirmation's "Apply": starts the run.
    func confirm() {
        isConfirming = false
        guard !isRunning else { return }
        phase = .running(nil)
        let run = run
        task = Task { [weak self] in
            let (updates, continuation) = AsyncStream.makeStream(
                of: MatchingRun.Progress.self, bufferingPolicy: .bufferingNewest(1))
            let shown = Task { [weak self] in
                for await progress in updates {
                    guard let self, case .running = self.phase else { continue }
                    self.phase = .running(progress)
                }
            }
            let report = await run { continuation.yield($0) }
            continuation.finish()
            await shown.value
            guard let self else { return }
            if let report {
                self.phase = .finished(report)
            } else {
                // Another run of the same `MatchingRun` was going on: nothing ran here.
                self.phase = .idle
            }
            self.task = nil
        }
    }

    /// Stops the run after its current batch.
    func cancel() {
        task?.cancel()
    }
}
