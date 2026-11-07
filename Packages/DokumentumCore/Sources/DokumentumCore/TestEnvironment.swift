import Foundation

/// Detects a test run. The app's unit tests are hosted by the app, so the app starts with them; in
/// that case it must not touch real documents or real settings.
public enum TestEnvironment {
    public static let isRunningTests = isRunningTests(
        environment: ProcessInfo.processInfo.environment,
        processName: ProcessInfo.processInfo.processName)

    /// `xcodebuild` sets the variables, in the app host too. `swift test` sets none of them, so its two
    /// runners are known by name.
    public static func isRunningTests(environment: [String: String], processName: String) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || processName == "swiftpm-testing-helper" || processName == "xctest"
    }

    /// Whether this run stays away from real data: a unit test run, or the app launched by a UI test with
    /// an in-memory store (`-UITestSeed` or `-UITestEmptyStore`, DEBUG builds only), which has none of the
    /// variables above.
    public static let isIsolated = isIsolated(
        isRunningTests: isRunningTests, arguments: ProcessInfo.processInfo.arguments)

    public static func isIsolated(isRunningTests: Bool, arguments: [String]) -> Bool {
        isRunningTests || StoreChoice.isUITestLaunch(arguments: arguments)
    }
}
