#if DEBUG || SEARCH_BENCHMARK
    import DokumentumCore
    import SwiftUI

    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    // The search benchmark's screen (plan of #7, part 2, Approach 9): Debug builds, or a Release build with
    // `SEARCH_BENCHMARK` (T12). Its texts are English and `verbatim`, outside the catalog, like the other debug UI.

    /// Runs the benchmark once and shows its progress, then the report with a Copy button. It also logs the summary
    /// (`Log.search`, numbers only) and writes the JSON to the app's temporary folder (`SearchBenchmark.json`).
    struct SearchBenchmarkView: View {
        static let reportFileName = "SearchBenchmark.json"

        let count: Int
        @State private var progress: SearchBenchmark.Progress?
        @State private var report: SearchBenchmark.Report?
        @State private var failure: String?
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(verbatim: "Search Benchmark").font(.headline)
                    Spacer()
                    if let report {
                        Button {
                            Self.copy(report.text)
                        } label: {
                            Text(verbatim: "Copy")
                        }
                        .accessibilityIdentifier("searchBenchmark.copy")
                    }
                    Button {
                        dismiss()
                    } label: {
                        Text(verbatim: "Close")
                    }
                }
                if let report {
                    ScrollView {
                        Text(verbatim: report.text)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("searchBenchmark.report")
                    }
                } else if let failure {
                    Text(verbatim: "Failed: \(failure)")
                } else {
                    ProgressView()
                    Text(verbatim: Self.describe(progress, count: count))
                        .font(.footnote)
                        .accessibilityIdentifier("searchBenchmark.progress")
                }
                Spacer(minLength: 0)
            }
            .padding()
            #if os(macOS)
                .frame(minWidth: 640, minHeight: 520)
            #endif
            .task { await run() }
        }

        private func run() async {
            guard report == nil else { return }
            do {
                let report = try await SearchBenchmark.run(
                    count: count, configuration: SearchBenchmarkArgument.configuration
                ) { progress = $0 }
                self.report = report
                Self.log(report)
                Self.write(report)
            } catch {
                failure = Log.code(of: error)
                Log.search.error("Search benchmark failed: \(Log.code(of: error), privacy: .public)")
            }
        }

        static func describe(_ progress: SearchBenchmark.Progress?, count: Int) -> String {
            switch progress {
            case nil: "Preparing \(count) synthetic documents…"
            case .writing(let written, let total): "Writing documents… \(written) of \(total)"
            case .indexing(let indexed, let total): "Indexing texts… \(indexed) of \(total)"
            case .querying(let done, let total): "Running queries… \(done) of \(total)"
            }
        }

        private static func log(_ report: SearchBenchmark.Report) {
            Log.search.notice(
                """
                Search benchmark \(report.passed ? "pass" : "miss", privacy: .public): \
                \(report.documents, privacy: .public) documents, overall max \
                \(report.overallMaxMilliseconds, privacy: .public) ms, build \(report.buildSeconds, privacy: .public) s, \
                footprint delta \(report.footprintDelta, privacy: .public) bytes, \
                \(report.device, privacy: .public), \(report.configuration, privacy: .public)
                """)
        }

        /// The JSON for the simulator run: `xcrun simctl get_app_container booted <bundle id> data`, then
        /// `tmp/SearchBenchmark.json`.
        private static func write(_ report: SearchBenchmark.Report) {
            do {
                let url = FileManager.default.temporaryDirectory.appending(path: reportFileName)
                try report.json().write(to: url, options: .atomic)
            } catch {
                Log.search.error("Could not write the benchmark report: \(Log.code(of: error), privacy: .public)")
            }
        }

        private static func copy(_ text: String) {
            #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            #else
                UIPasteboard.general.string = text
            #endif
        }
    }

    /// Opens the benchmark: an action equal to every other, as `AddSampleDocumentsAction`.
    struct RunSearchBenchmarkAction: Equatable {
        let run: @MainActor () -> Void

        @MainActor func callAsFunction() { run() }

        static func == (lhs: Self, rhs: Self) -> Bool { true }
    }

    extension FocusedValues {
        /// The focused window's benchmark, for the Mac's Debug menu.
        @Entry var runSearchBenchmark: RunSearchBenchmarkAction?
    }

    /// Shows the benchmark over the library window: at launch with `-SearchBenchmark <count>`, and on the Mac from
    /// Debug › Run Search Benchmark (5,000 documents).
    struct SearchBenchmarkPresenter: ViewModifier {
        @State private var count: Int? = SearchBenchmarkArgument.count(arguments: ProcessInfo.processInfo.arguments)

        func body(content: Content) -> some View {
            content
                .focusedSceneValue(
                    \.runSearchBenchmark, RunSearchBenchmarkAction { count = SearchBenchmark.defaultCount }
                )
                .sheet(isPresented: Binding(get: { count != nil }, set: { if !$0 { count = nil } })) {
                    if let count { SearchBenchmarkView(count: count) }
                }
        }
    }
#endif
