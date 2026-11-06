import DokumentumTestSupport
import Foundation
import Testing

/// The test waits are scaled by `DOKUMENTUM_TEST_TIMEOUT_SCALE`.
struct TestSupportTests {
    @Test func timeoutScaleComesFromTheEnvironment() {
        #expect(TestSupport.timeoutScale(from: ["DOKUMENTUM_TEST_TIMEOUT_SCALE": "5"]) == 5)
        #expect(TestSupport.timeoutScale(from: ["DOKUMENTUM_TEST_TIMEOUT_SCALE": "2.5"]) == 2.5)
    }

    @Test(arguments: [
        [:], ["DOKUMENTUM_TEST_TIMEOUT_SCALE": ""], ["DOKUMENTUM_TEST_TIMEOUT_SCALE": "fast"],
        ["DOKUMENTUM_TEST_TIMEOUT_SCALE": "0"], ["DOKUMENTUM_TEST_TIMEOUT_SCALE": "-3"],
        ["DOKUMENTUM_TEST_TIMEOUT_SCALE": "inf"], ["DOKUMENTUM_TEST_TIMEOUT_SCALE": "nan"],
    ])
    func missingOrInvalidScaleIsOne(environment: [String: String]) {
        #expect(TestSupport.timeoutScale(from: environment) == 1)
    }

    @Test func scaledMultipliesTheTimeout() {
        #expect(TestSupport.scaled(.seconds(10), by: 5) == .seconds(50))
        #expect(TestSupport.scaled(.seconds(10), by: 2.5) == .seconds(25))
        #expect(TestSupport.scaled(.seconds(10), by: 1) == .seconds(10))
        #expect(TestSupport.scaled(.zero, by: 5) == .zero)
    }

    /// The scale of this run reaches the waits: only `scaled(_:)` is the one the tests use.
    @Test func scaledUsesTheScaleOfThisRun() {
        #expect(TestSupport.scaled(.seconds(10)) == TestSupport.scaled(.seconds(10), by: TestSupport.timeoutScale))
        #expect(TestSupport.timeoutScale == TestSupport.timeoutScale(from: ProcessInfo.processInfo.environment))
    }

    /// The safety net counts rounds of its interval, scaled, and at least one.
    @Test func roundsCoverTheScaledTimeout() {
        #expect(
            TestSupport.rounds(.seconds(1), interval: .milliseconds(50))
                == Int((20 * TestSupport.timeoutScale).rounded(.up)))
        #expect(TestSupport.rounds(.zero, interval: .milliseconds(50)) == 1)
    }
}
