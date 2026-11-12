import DokumentumKit
import Foundation
import SwiftData

#if canImport(Darwin)
    import Darwin
#endif

/// The search's performance measurement (plan of #7, Approach 9, T11): one runner for the tests, the simulator and
/// the device, so each measures exactly the same path.
///
/// It opens **its own in-memory container** (never the app's store), writes a `SyntheticCorpus` into it through the
/// real models, builds the index with the real `SearchIndexer` (timed), and runs `queries` `runs` times each through
/// the path the library uses: `DocumentSearching.search`, then `LibrarySearch.apply` over the library's snapshot,
/// timed from the call to the ordered list on the main actor. The report carries per query the median and the
/// maximum, the overall maximum, hit counts, build times, the index's size and `phys_footprint` before and after
/// the build (N1).
///
/// It lives unconditionally in the package (local packages do not get the app's compilation conditions); only the
/// app's entry points are Debug or `SEARCH_BENCHMARK` only.
public enum SearchBenchmark {
    /// The pass criterion (T11): every run of every query under this.
    public static let limit: Duration = .milliseconds(200)
    public static let defaultCount = 5_000
    public static let defaultRuns = 5

    /// One query of the benchmark: text, filter tokens and where it looks.
    public struct Query: Sendable, Hashable {
        /// A filter token, named as the corpus names it.
        public enum Token: Sendable, Hashable {
            case tag(String)
            case correspondent(String)
            case documentType(String)
            case inbox
        }

        /// The sidebar selection, named as the corpus names it.
        public enum Selection: Sendable, Hashable {
            case all, inbox, trash
            case tag(String)
        }

        public var text: String
        public var tokens: [Token]
        public var scope: SearchScope
        public var selection: Selection

        public init(
            _ text: String, tokens: [Token] = [], scope: SearchScope = .selection, selection: Selection = .all
        ) {
            self.text = text
            self.tokens = tokens
            self.scope = scope
            self.selection = selection
        }

        /// How the report names the query.
        public var label: String {
            var parts = ["\"\(text)\""]
            for token in tokens {
                switch token {
                case .tag(let name): parts.append("tag:\(name)")
                case .correspondent(let name): parts.append("correspondent:\(name)")
                case .documentType(let name): parts.append("type:\(name)")
                case .inbox: parts.append("inbox")
                }
            }
            switch selection {
            case .all: break
            case .inbox: parts.append("in Inbox")
            case .trash: parts.append("in Trash")
            case .tag(let name): parts.append("in tag \(name)")
            }
            if scope == .all { parts.append("scope All") }
            return parts.joined(separator: " ")
        }
    }

    /// The 30 queries: 1-, 2- and 3-letter prefixes, infixes from 4 letters, two and three terms, umlauts and
    /// transcriptions, digits and codes, misses, and five with filter tokens or a scope.
    public static let queries: [Query] = [
        Query("r"), Query("m"), Query("2"),
        Query("st"),
        Query("rec"), Query("grü"), Query("kfz"),
        Query("bescheid"), Query("steuer"), Query("nung"), Query("versicherung"),
        Query("steuer bescheid"), Query("finanzamt münchen"), Query("sehr geehrte damen"),
        Query("müller"), Query("überweisung"), Query("größe"),
        Query("mueller"), Query("ueberweisung"), Query("strasse"),
        Query("2024"), Query("12.03.2024"), Query("abc"),
        Query("xylophon"), Query("zzqqxx"),
        Query("rechnung", tokens: [.tag("Steuer")]),
        Query("", tokens: [.correspondent("Finanzamt München")]),
        Query("betrag", tokens: [.documentType("Bescheid"), .inbox]),
        Query("mahnung", scope: .all, selection: .tag("Auto")),
        Query("zahlung", selection: .trash),
    ]

    /// Where a run is.
    public enum Progress: Sendable, Equatable {
        case writing(written: Int, total: Int)
        case indexing(indexed: Int, total: Int)
        case querying(done: Int, total: Int)
    }

    /// One query's measurement.
    public struct QueryResult: Codable, Sendable, Equatable {
        public var label: String
        /// The rows listed.
        public var hits: Int
        public var milliseconds: [Double]
        public var medianMilliseconds: Double
        public var maxMilliseconds: Double
    }

    /// The report; as text (`text`) and as JSON (`json()`).
    public struct Report: Codable, Sendable, Equatable {
        public var documents: Int
        public var seed: UInt64
        public var runs: Int
        public var device: String
        public var system: String
        public var configuration: String
        /// Whether the runner's container is in memory only (always, by construction).
        public var inMemoryOnly: Bool
        public var corpusTextBytes: Int
        public var writeSeconds: Double
        public var metadataSeconds: Double
        public var textsSeconds: Double
        public var buildSeconds: Double
        public var tokens: Int
        public var postings: Int
        public var indexedDocuments: Int
        public var footprintBeforeBuild: UInt64
        public var footprintAfterBuild: UInt64
        public var footprintDelta: Int64
        public var queries: [QueryResult]
        public var overallMaxMilliseconds: Double
        public var limitMilliseconds: Double
        public var passed: Bool

        public func json() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(self)
        }

        /// The report for a person: summary first, then one line per query.
        public var text: String {
            func ms(_ value: Double) -> String { String(format: "%.2f ms", value) }
            func mb(_ bytes: Double) -> String { String(format: "%.1f MB", bytes / 1_048_576) }
            var lines = [
                "Search benchmark: \(passed ? "PASS" : "MISS") (overall max \(ms(overallMaxMilliseconds)), limit \(ms(limitMilliseconds)))",
                "Device: \(device), \(system), \(configuration)",
                "Corpus: \(documents) documents, seed \(seed), \(mb(Double(corpusTextBytes))) of text; written in \(String(format: "%.1f s", writeSeconds))",
                "Build: metadata \(String(format: "%.2f s", metadataSeconds)), texts \(String(format: "%.2f s", textsSeconds)), total \(String(format: "%.2f s", buildSeconds))",
                "Index: \(indexedDocuments) documents, \(tokens) tokens, \(postings) postings",
                "phys_footprint: before build \(mb(Double(footprintBeforeBuild))), after \(mb(Double(footprintAfterBuild))), delta \(mb(Double(footprintDelta)))",
                "Queries (\(queries.count) × \(runs) runs, median / max, hits):",
            ]
            for query in queries {
                lines.append(
                    "  \(query.label): \(ms(query.medianMilliseconds)) / \(ms(query.maxMilliseconds)), \(query.hits)")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Runs the benchmark. On the main actor, as the library: the timed path ends with the ordered list here.
    /// - Parameters:
    ///   - configuration: the app's build configuration, for the report.
    ///   - progress: called on the main actor while it runs.
    @MainActor
    public static func run(
        count: Int = defaultCount, seed: UInt64 = 0x00D0_C0DE, runs: Int = defaultRuns,
        configuration: String = defaultConfiguration,
        progress: @escaping @MainActor @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Report {
        let clock = ContinuousClock()
        let container = try ArchiveStore.open(ArchiveStore.configuration(for: .inMemory(seed: false)))
        let corpus = SyntheticCorpus(count: count, seed: seed)
        let writeStart = clock.now
        let textBytes = try await write(corpus, into: container, progress: progress)
        let writeTime = clock.now - writeStart

        let before = physFootprint()
        let indexer = SearchIndexer(container: container)
        defer { indexer.stop() }
        let updates = indexer.updates()
        indexer.start()
        for await state in updates {
            if case .building(let indexed, let total) = state { progress(.indexing(indexed: indexed, total: total)) }
            if state == .ready { break }
        }
        let after = physFootprint()
        let build = await indexer.lastBuild
        let statistics = await indexer.statistics

        let snapshot = try StoreLibrarySource.read(in: container.mainContext)
        let tree = TagTree(snapshot.tags)
        var results: [QueryResult] = []
        for (number, query) in queries.enumerated() {
            let (search, selection) = resolve(query, in: snapshot)
            var times: [Double] = []
            var hits = 0
            for _ in 0..<max(1, runs) {
                let start = clock.now
                let result = search.hasText ? await indexer.search(search.text) : nil
                let rows = search.apply(result, to: snapshot.documents, selection: selection, tree: tree)
                times.append(milliseconds(clock.now - start))
                hits = rows.count
            }
            let sorted = times.sorted()
            results.append(
                QueryResult(
                    label: query.label, hits: hits, milliseconds: times, medianMilliseconds: sorted[sorted.count / 2],
                    maxMilliseconds: sorted.last ?? 0))
            progress(.querying(done: number + 1, total: queries.count))
        }
        let overall = results.map(\.maxMilliseconds).max() ?? 0
        let limitMilliseconds = milliseconds(limit)
        return Report(
            documents: count, seed: seed, runs: max(1, runs), device: deviceModel(),
            system: "\(systemName) \(ProcessInfo.processInfo.operatingSystemVersionString)",
            configuration: configuration,
            inMemoryOnly: container.configurations.allSatisfy(\.isStoredInMemoryOnly), corpusTextBytes: textBytes,
            writeSeconds: seconds(writeTime), metadataSeconds: seconds(build?.metadata ?? .zero),
            textsSeconds: seconds(build?.texts ?? .zero), buildSeconds: seconds(build?.total ?? .zero),
            tokens: statistics.tokens, postings: statistics.postings, indexedDocuments: statistics.documents,
            footprintBeforeBuild: before, footprintAfterBuild: after,
            footprintDelta: Int64(after) - Int64(before), queries: results, overallMaxMilliseconds: overall,
            limitMilliseconds: limitMilliseconds, passed: overall < limitMilliseconds)
    }

    /// The query as the library holds it, with names resolved against the corpus.
    public static func resolve(_ query: Query, in snapshot: LibrarySnapshot) -> (LibrarySearch, LibrarySelection) {
        func tag(_ name: String) -> UUID? {
            snapshot.tags.first { $0.name == name && $0.parentInstanceID == nil }?.instanceID
        }
        let tokens: [SearchToken] = query.tokens.compactMap { token in
            switch token {
            case .tag(let name): tag(name).map(SearchToken.tag)
            case .correspondent(let name):
                snapshot.correspondents.first { $0.name == name }.map { .correspondent($0.instanceID) }
            case .documentType(let name):
                snapshot.documentTypes.first { $0.name == name }.map { .documentType($0.instanceID) }
            case .inbox: .inbox
            }
        }
        let selection: LibrarySelection
        switch query.selection {
        case .all: selection = .all
        case .inbox: selection = .inbox
        case .trash: selection = .trash
        case .tag(let name): selection = tag(name).map(LibrarySelection.tag) ?? .all
        }
        return (LibrarySearch(text: query.text, tokens: tokens, scope: query.scope), selection)
    }

    // MARK: Writing the corpus

    /// How many documents one save writes; a fresh context per chunk keeps memory flat.
    static let chunkSize = 200

    /// Writes `corpus` through the real models, off the main actor. Returns the UTF-8 bytes of text written.
    @concurrent
    static func write(
        _ corpus: SyntheticCorpus, into container: ModelContainer,
        progress: @escaping @MainActor @Sendable (Progress) -> Void
    ) async throws -> Int {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var tags: [UUID: Tag] = [:]
        for record in corpus.tags {
            let tag = Tag(name: record.name)
            tag.instanceID = record.instanceID
            tag.parent = record.parentInstanceID.flatMap { tags[$0] }
            context.insert(tag)
            tags[record.instanceID] = tag
        }
        for reference in corpus.correspondents {
            let record = Correspondent(name: reference.name)
            record.instanceID = reference.instanceID
            context.insert(record)
        }
        for reference in corpus.documentTypes {
            let record = DocumentType(name: reference.name)
            record.instanceID = reference.instanceID
            context.insert(record)
        }
        try context.save()

        var bytes = 0
        for start in stride(from: 0, to: corpus.documents.count, by: chunkSize) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let tags = Dictionary(
                try context.fetch(FetchDescriptor<Tag>()).map { ($0.instanceID, $0) }, uniquingKeysWith: { a, _ in a })
            let correspondents = Dictionary(
                try context.fetch(FetchDescriptor<Correspondent>()).map { ($0.instanceID, $0) },
                uniquingKeysWith: { a, _ in a })
            let types = Dictionary(
                try context.fetch(FetchDescriptor<DocumentType>()).map { ($0.instanceID, $0) },
                uniquingKeysWith: { a, _ in a })
            for item in corpus.documents[start..<min(start + chunkSize, corpus.documents.count)] {
                let document = Document(title: item.title, createdAt: item.createdAt)
                document.instanceID = item.instanceID
                document.documentDate = item.documentDate
                document.isInbox = item.isInbox
                document.deletedAt = item.deletedAt
                document.pageCount = item.pageCount
                document.correspondent = item.correspondent.flatMap { correspondents[$0.instanceID] }
                document.documentType = item.documentType.flatMap { types[$0.instanceID] }
                document.tags = item.tagIDs.compactMap { tags[$0] }
                let text = corpus.text(of: item)
                bytes += text.utf8.count
                let row = DocumentText(documentID: document.id, extractedText: text, createdAt: item.createdAt)
                context.insert(document)
                context.insert(row)
                document.text = row
            }
            try context.save()
            let written = min(start + chunkSize, corpus.documents.count)
            await progress(.writing(written: written, total: corpus.documents.count))
        }
        return bytes
    }

    // MARK: Environment

    /// The configuration this package was built in; the app passes its own.
    public static var defaultConfiguration: String {
        #if DEBUG
            "Debug"
        #else
            "Release"
        #endif
    }

    /// This process's `phys_footprint` in bytes (`task_vm_info`), the figure Xcode's memory gauge and the jetsam
    /// limit use; 0 if it cannot be read.
    public static func physFootprint() -> UInt64 {
        #if canImport(Darwin)
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
                }
            }
            return result == KERN_SUCCESS ? info.phys_footprint : 0
        #else
            return 0
        #endif
    }

    private static var systemName: String {
        #if os(iOS)
            "iOS"
        #elseif os(macOS)
            "macOS"
        #else
            "unknown"
        #endif
    }

    /// The hardware model ("iPhone18,1", "Mac16,10"); in the simulator the simulated model.
    static func deviceModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (Simulator)"
        }
        #if os(macOS)
            let key = "hw.model"
        #else
            let key = "hw.machine"
        #endif
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    static func seconds(_ duration: Duration) -> Double { milliseconds(duration) / 1_000 }
}
