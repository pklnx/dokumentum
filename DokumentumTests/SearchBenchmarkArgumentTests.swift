#if DEBUG
    import DokumentumCore
    import Testing

    @testable import Dokumentum

    /// The Debug-only `-SearchBenchmark <count>` (plan of #7, part 2): which launches run the benchmark, how many
    /// documents, and that such a launch takes an empty in-memory store whatever the launch would open.
    struct SearchBenchmarkArgumentTests {
        @Test func aCountInRangeIsTaken() {
            #expect(SearchBenchmarkArgument.count(arguments: ["app", "-SearchBenchmark", "5000"]) == 5_000)
            #expect(SearchBenchmarkArgument.count(arguments: ["-SearchBenchmark", "1"]) == 1)
            #expect(SearchBenchmarkArgument.count(arguments: ["-SearchBenchmark", "20000"]) == 20_000)
        }

        @Test func aMissingOrOutOfRangeCountIsTheDefault() {
            for arguments in [
                ["-SearchBenchmark"], ["-SearchBenchmark", "0"], ["-SearchBenchmark", "20001"],
                ["-SearchBenchmark", "-5"], ["-SearchBenchmark", "YES"], ["-SearchBenchmark", "-UITestSeed"],
            ] {
                #expect(SearchBenchmarkArgument.count(arguments: arguments) == 5_000, "\(arguments)")
            }
        }

        @Test func withoutTheArgumentThereIsNoBenchmark() {
            for arguments in [[], ["app"], ["-OtherArgument", "5000"], ["-UITestSeed", "YES"]] {
                #expect(SearchBenchmarkArgument.count(arguments: arguments) == nil, "\(arguments)")
            }
        }

        @Test(arguments: [StoreChoice.cloudKit, .local, .inMemory(seed: true), .inMemory(seed: false)])
        func aBenchmarkLaunchTakesAnEmptyInMemoryStore(choice: StoreChoice) {
            #expect(
                SearchBenchmarkArgument.storeChoice(choice, arguments: ["app", "-SearchBenchmark", "5000"])
                    == .inMemory(seed: false))
            #expect(SearchBenchmarkArgument.storeChoice(choice, arguments: ["app"]) == choice)
        }
    }
#endif
