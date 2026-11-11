import DokumentumCore
import DokumentumTestSupport
import Foundation
import SwiftData
import SwiftUI
import Testing

@testable import Dokumentum

#if os(macOS)
    import AppKit
#endif

/// The processing queue and the app's lifecycle (#97 point 4, plan of #6, part 1): the background pauses on iOS,
/// becoming active resumes, and quitting the Mac app pauses. A stub runner counts runs and interruptions.
@MainActor
struct ProcessingLifecycleTests {
    final class StubRunner: ProcessingRunning {
        let started = TestSignal()
        let interrupts = TestSignal()

        func run() async -> ProcessingReport {
            started.fire()
            return ProcessingReport()
        }

        func interruptNow() {
            interrupts.fire()
        }
    }

    /// A scheduler that is not started: nothing runs until the test asks.
    private func makeScheduler(_ runner: StubRunner) throws -> (ProcessingScheduler, runs: TestSignal) {
        let container = try makeInMemoryContainer()
        let observer = StoreChangeObserver(
            container: container, center: NotificationCenter(), sleep: ManualDebounce().sleep)
        let (insertions, _) = AsyncStream<Void>.makeStream()
        let scheduler = ProcessingScheduler(
            runner: runner, observer: observer, insertions: insertions, sleep: ManualDebounce().sleep)
        let runs = TestSignal()
        scheduler.didFinishRun = { _ in runs.fire() }
        return (scheduler, runs)
    }

    @Test func theBackgroundPausesOnTheIPhoneAndActiveResumes() async throws {
        let runner = StubRunner()
        let (scheduler, runs) = try makeScheduler(runner)
        defer { scheduler.stop() }

        ProcessingLifecycle.scenePhaseChanged(to: .inactive, scheduler: scheduler)
        #expect(!scheduler.isPaused, "inactive is not the background")
        ProcessingLifecycle.scenePhaseChanged(to: .background, scheduler: scheduler)
        #if os(iOS)
            #expect(scheduler.isPaused)
            #expect(runner.interrupts.count == 1, "the attempt was not given back")
            scheduler.requestRun()
            #expect(!scheduler.isRunning, "a run started in the background")
        #else
            #expect(!scheduler.isPaused, "the Mac keeps processing in the background")
            #expect(runner.interrupts.count == 0)
        #endif

        ProcessingLifecycle.scenePhaseChanged(to: .active, scheduler: scheduler)
        #expect(!scheduler.isPaused)
        await runs.wait(for: 1, "becoming active did not run the queue")
        #expect(runner.started.count == 1)
    }

    #if os(macOS)
        @Test func quittingTheMacAppPauses() async throws {
            let runner = StubRunner()
            let (scheduler, _) = try makeScheduler(runner)
            defer { scheduler.stop() }
            let center = NotificationCenter()
            let token = ProcessingLifecycle.pauseWhenTerminating(scheduler, center: center)
            defer { center.removeObserver(token) }

            center.post(name: NSApplication.willTerminateNotification, object: nil)

            #expect(scheduler.isPaused)
            #expect(runner.interrupts.count == 1, "quitting did not give the attempt back")
        }
    #endif
}
