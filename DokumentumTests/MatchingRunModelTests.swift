import DokumentumCore
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import Dokumentum

/// "Apply Matching Rules to All Documents…" (#10, part 2; plan §9, maintainer's P3): it asks first, shows the progress,
/// can be cancelled, and shows a result built from the run's report. In-memory stores only.
@MainActor
struct MatchingRunModelTests {
    private nonisolated static func report(changed: Int, cancelled: Bool = false) -> MatchingRun.Report {
        var report = MatchingRun.Report()
        report.documents = 120
        report.changed = changed
        report.cancelled = cancelled
        return report
    }

    /// Nothing runs before the confirmation; then the progress shows, a second request is ignored while it runs, and
    /// the report is the result. Counter-proof: start the run in `requestApply` → the phase is not `idle` after it.
    @Test func itAsksFirstThenShowsTheProgressAndTheResult() async throws {
        let reached = Checkpoint()
        defer { reached.release() }
        let runs = TestSignal()
        let model = MatchingRunModel { progress in
            runs.fire()
            progress(MatchingRun.Progress(done: 50, total: 120))
            await reached.pass()
            progress(MatchingRun.Progress(done: 120, total: 120))
            return Self.report(changed: 3)
        }

        model.requestApply()
        #expect(model.isConfirming)
        #expect(model.phase == .idle, "it ran before the confirmation")
        model.confirm()
        #expect(!model.isConfirming)
        #expect(model.isRunning)
        await reached.reached()
        try await TestSupport.waitUntil("no progress shown") {
            model.phase == .running(MatchingRun.Progress(done: 50, total: 120))
        }
        model.requestApply()
        #expect(!model.isConfirming, "a second run offered while one runs")
        let task = try #require(model.task)
        reached.release()
        await task.value
        #expect(model.phase == .finished(Self.report(changed: 3)))
        #expect(runs.count == 1)
    }

    /// Cancel cancels the run's task; the run stops between batches and reports it (`MatchingRun`), and the result
    /// says so. Counter-proof: `cancel()` does nothing → the run sees no cancellation and the report is not cancelled.
    @Test func cancelStopsTheRun() async throws {
        let reached = Checkpoint()
        defer { reached.release() }
        let model = MatchingRunModel { _ in
            await reached.pass()
            return Self.report(changed: 1, cancelled: Task.isCancelled)
        }
        model.requestApply()
        model.confirm()
        await reached.reached()
        let task = try #require(model.task)
        model.cancel()
        reached.release()
        await task.value
        #expect(model.phase == .finished(Self.report(changed: 1, cancelled: true)))

        var english = MatchingRuleText.result(Self.report(changed: 1, cancelled: true))
        for index in english.indices { english[index].locale = Locale(identifier: "en_US") }
        #expect(
            english.map { String(localized: $0) } == [
                "Stopped before every document was checked.", "1 document changed.",
            ])
    }

    /// The real run on the sample library: a rule "Autohaus" on Musterbank AG fills the one document without a
    /// correspondent whose text has the word ("Golf inspection"), and the library shows Musterbank AG on one more
    /// document. The documents that have a correspondent keep it (P3). Counter-proof: the model's run not awaited
    /// (no report) → the phase stays `running`.
    @Test func theRulesApplyToTheSampleLibrary() async throws {
        let container = try makeInMemoryContainer()
        FixtureSeeder.seedForUITests(container.mainContext)
        let musterbank = FixtureCatalog.musterbank.instanceID
        #expect(
            try MatchingRuleEditor(context: container.mainContext).save(
                .correspondent, musterbank, mode: .any, pattern: "Autohaus") == .saved)
        let library = LibraryModel(source: StoreLibrarySource(container: container))
        let before = library.counts.count(for: .correspondent(musterbank))
        // A generous budget: no test runs a rule against the real 100 ms (`index.md`, "Matching rules").
        let run = MatchingRun(container: container, budget: .clock(.seconds(10)))
        let model = MatchingRunModel { progress in await run.run(progress: progress) }

        model.requestApply()
        model.confirm()
        let task = try #require(model.task)
        await task.value

        guard case .finished(let report) = model.phase else {
            Issue.record("no result: \(model.phase)")
            return
        }
        #expect(report.changed == 1)
        #expect(report.ambiguous == 0 && report.invalidRules.isEmpty && !report.cancelled)
        library.reload()
        #expect(library.counts.count(for: .correspondent(musterbank)) == before + 1)
        library.selection = .all
        let golf = library.documents.first { $0.instanceID == FixtureCatalog.documentID(8) }
        #expect(golf?.correspondent?.instanceID == musterbank)
        let bill = library.documents.first { $0.instanceID == FixtureCatalog.documentID(1) }
        #expect(bill?.correspondent == FixtureCatalog.stadtwerke, "a correspondent was replaced")
    }

    /// The result line names what the report holds: skipped rules (not valid, too slow, copies), ambiguous and skipped
    /// documents (plan, Tests 2). Counter-proof: leave the invalid rules out → the list differs.
    @Test func theResultNamesSkippedRulesAndAmbiguousDocuments() {
        var report = MatchingRun.Report()
        report.documents = 40
        report.changed = 0
        report.ambiguous = 2
        report.skipped = 1
        report.invalidRules = ["Bank", "Strom"]
        report.slowRules = ["Telekom"]
        report.copiedRules = 1
        var lines = MatchingRuleText.result(report)
        for index in lines.indices { lines[index].locale = Locale(identifier: "en_US") }
        #expect(
            lines.map { String(localized: $0) } == [
                "No document was changed.",
                "2 documents matched several correspondents or document types; that field stays empty.",
                "1 document changed meanwhile and was skipped. Apply the rules again.",
                "Not applied, not valid: Bank and Strom",
                "Too slow on some documents: Telekom",
                "1 rule is not applied because its item exists twice in the archive.",
            ])

        var failed = MatchingRun.Report()
        failed.failed = true
        failed.changed = 5
        var failedLines = MatchingRuleText.result(failed)
        for index in failedLines.indices { failedLines[index].locale = Locale(identifier: "en_US") }
        #expect(
            failedLines.map { String(localized: $0) } == [
                "The rules could not be applied to every document.", "5 documents changed.",
            ])
    }
}
