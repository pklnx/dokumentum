#if DEBUG
    import Testing

    @testable import Dokumentum

    /// The Debug-only `-ProcessingTakeoverSeconds` (plan of #4, part 5, M4).
    struct ProcessingTakeoverArgumentTests {
        @Test func aPositiveNumberOfSecondsIsTaken() {
            #expect(ProcessingTakeoverArgument.seconds(arguments: ["app", "-ProcessingTakeoverSeconds", "120"]) == 120)
            #expect(ProcessingTakeoverArgument.seconds(arguments: ["-ProcessingTakeoverSeconds", "0.5"]) == 0.5)
        }

        @Test func anythingElseKeepsSixHours() {
            for arguments in [
                [], ["app"], ["-ProcessingTakeoverSeconds"], ["-ProcessingTakeoverSeconds", "0"],
                ["-ProcessingTakeoverSeconds", "-5"], ["-ProcessingTakeoverSeconds", "YES"],
                ["-ProcessingTakeoverSeconds", "inf"], ["-OtherArgument", "120"],
            ] {
                #expect(ProcessingTakeoverArgument.seconds(arguments: arguments) == nil, "\(arguments)")
            }
        }
    }
#endif
