#if DEBUG || SEARCH_BENCHMARK
    import DokumentumCore
    import Foundation

    /// `-SearchBenchmark <count>` (Debug builds, or a Release build with `SEARCH_BENCHMARK`, plan of #7, T12): the
    /// app shows the search benchmark for `count` synthetic documents instead of the library, on an empty in-memory
    /// store, so no repair, processing or real index of the archive runs beside it. The runner writes its corpus
    /// into a container of its own (`SearchBenchmark`).
    enum SearchBenchmarkArgument {
        static let argument = "-SearchBenchmark"
        static let counts = 1...20_000

        /// The documents `arguments` ask for: the number after the argument when it is in `counts`, the default
        /// (5,000) when the value is missing or out of range; `nil` without the argument.
        static func count(arguments: [String]) -> Int? {
            guard let index = arguments.firstIndex(of: argument) else { return nil }
            guard index + 1 < arguments.count, let count = Int(arguments[index + 1]), counts.contains(count) else {
                return SearchBenchmark.defaultCount
            }
            return count
        }

        /// The launch's store: an empty in-memory one for a benchmark launch, `choice` otherwise.
        static func storeChoice(_ choice: StoreChoice, arguments: [String]) -> StoreChoice {
            count(arguments: arguments) == nil ? choice : .inMemory(seed: false)
        }

        /// The app's build configuration, for the report.
        static var configuration: String {
            #if DEBUG
                "Debug"
            #else
                "Release (SEARCH_BENCHMARK)"
            #endif
        }
    }
#endif
