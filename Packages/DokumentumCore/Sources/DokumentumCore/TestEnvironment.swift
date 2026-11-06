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

    /// Whether this run stays away from real data. Today that is a unit test run; step 1 adds the app
    /// launched by a UI test, which has none of the variables above and needs a launch argument.
    public static var isIsolated: Bool { isRunningTests }
}
