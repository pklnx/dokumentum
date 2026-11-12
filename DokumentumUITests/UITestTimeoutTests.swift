import XCTest

/// The UI tests' timeout scale (`UITestApp.timeoutScale`, #136), the same rule as `TestSupport.timeoutScale`. No app
/// is launched.
final class UITestTimeoutTests: XCTestCase {
    @MainActor
    func testTheScaleComesFromTheEnvironment() {
        XCTAssertEqual(UITestApp.timeoutScale(from: ["DOKUMENTUM_TEST_TIMEOUT_SCALE": "3"]), 3)
        XCTAssertEqual(UITestApp.timeoutScale(from: ["DOKUMENTUM_TEST_TIMEOUT_SCALE": "2.5"]), 2.5)
    }

    @MainActor
    func testAMissingOrInvalidScaleIsOne() {
        let environments: [[String: String]] = [
            [:], ["DOKUMENTUM_TEST_TIMEOUT_SCALE": ""], ["DOKUMENTUM_TEST_TIMEOUT_SCALE": "fast"],
            ["DOKUMENTUM_TEST_TIMEOUT_SCALE": "0"], ["DOKUMENTUM_TEST_TIMEOUT_SCALE": "-3"],
            ["DOKUMENTUM_TEST_TIMEOUT_SCALE": "inf"], ["DOKUMENTUM_TEST_TIMEOUT_SCALE": "nan"],
        ]
        for environment in environments {
            XCTAssertEqual(UITestApp.timeoutScale(from: environment), 1, "\(environment)")
        }
    }

    @MainActor
    func testATimeoutIsScaledByThisRunsScale() {
        XCTAssertEqual(UITestApp.timeout(30), 30 * UITestApp.timeoutScale)
        XCTAssertEqual(
            UITestApp.timeoutScale, UITestApp.timeoutScale(from: ProcessInfo.processInfo.environment))
    }
}
