import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import Testing

/// The benchmark's runner on a 300-document corpus (plan of #7, Approach 9): the shape of its report and that its
/// results are those of the index itself. No time assertion: a time bound in CI would be a wait on the clock in
/// disguise; the measurement is the device run (M1).
@MainActor
struct SearchBenchmarkTests {
    @Test func theRunnerMeasuresEveryQueryOnItsOwnInMemoryStore() async throws {
        let count = 300
        var phases: [SearchBenchmark.Progress] = []
        let report = try await SearchBenchmark.run(count: count) { phases.append($0) }

        #expect(report.inMemoryOnly)
        #expect(report.documents == count)
        #expect(report.indexedDocuments == count)
        #expect(report.queries.count == 30)
        #expect(SearchBenchmark.queries.count == 30)
        #expect(report.queries.allSatisfy { $0.milliseconds.count == SearchBenchmark.defaultRuns })
        #expect(report.overallMaxMilliseconds == report.queries.map(\.maxMilliseconds).max())
        #expect(report.tokens > 0 && report.postings > 0)
        #expect(report.footprintAfterBuild > 0 && report.footprintBeforeBuild > 0)
        #expect(phases.contains(.writing(written: count, total: count)))
        #expect(phases.contains(.querying(done: 30, total: 30)))

        // Every hit count equals what the index built straight from the corpus finds, filtered the same way.
        let corpus = SyntheticCorpus(count: count)
        var index = SearchIndex()
        let snapshot = corpus.snapshot
        let tree = TagTree(snapshot.tags)
        for document in corpus.documents {
            index.setMetadata(SearchFields(document.libraryDocument, tree: tree), for: document.instanceID)
            index.setText(corpus.text(of: document), for: document.instanceID)
        }
        index.mergeOverflow()
        for (query, result) in zip(SearchBenchmark.queries, report.queries) {
            let (search, selection) = SearchBenchmark.resolve(query, in: snapshot)
            let matches = search.hasText ? SearchResult(matches: index.search(search.text), state: .ready) : nil
            let expected = search.apply(matches, to: snapshot.documents, selection: selection, tree: tree)
            #expect(result.hits == expected.count, "\(query.label)")
            #expect(result.label == query.label)
        }
        let hits = Dictionary(uniqueKeysWithValues: report.queries.map { ($0.label, $0.hits) })
        #expect(hits["\"xylophon\""] == 0)
        #expect(hits["\"zzqqxx\""] == 0)
        #expect((hits["\"steuer\""] ?? 0) > 0)
        #expect((hits["\"mueller\""] ?? 0) == hits["\"müller\""])
        #expect((hits["\"\" correspondent:Finanzamt München"] ?? 0) > 0)

        let decoded = try JSONDecoder().decode(SearchBenchmark.Report.self, from: report.json())
        #expect(decoded == report)
        #expect(report.text.contains("phys_footprint"))
    }
}
