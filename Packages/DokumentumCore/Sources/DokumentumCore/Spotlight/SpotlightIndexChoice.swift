import Foundation

/// Which Spotlight index a launch uses (#13, plan §5, T7, T8). Decided at launch together with the settings suite and
/// the state, so a run either touches all of this device's Spotlight state or none of it:
/// - **in memory** whenever tests run (`TestEnvironment.isRunningTests`), whenever any launch argument starts with
///   `-UITest` (`-UITestLocalStore` included, which is on disk and which `StoreChoice.isUITestLaunch` does not cover),
///   and whenever the store is in memory (a `-SearchBenchmark` launch). The app then uses `InMemorySpotlightIndex`,
///   a settings suite of its own and the state in memory;
/// - **system** otherwise: the system's index, this device's settings and `SpotlightStateFile`.
///
/// So no test, no `-UITest*` launch and no in-memory launch reaches `CSSearchableIndex`. The rule repeats
/// `NotificationCenterChoice`'s (#12, part 3) in a type of its own, so the two do not depend on each other (T8), and it
/// holds in every build, not only in Debug.
public enum SpotlightIndexChoice: Sendable, Equatable {
    case inMemory
    case system

    /// Every UI-test argument starts with it.
    public static let uiTestArgumentPrefix = "-UITest"

    /// The choice of a launch.
    public static func decide(isRunningTests: Bool, arguments: [String], storeIsOnDisk: Bool) -> SpotlightIndexChoice {
        if isRunningTests || !storeIsOnDisk || isUITestLaunch(arguments: arguments) { return .inMemory }
        return .system
    }

    /// Whether any argument is a UI-test argument.
    public static func isUITestLaunch(arguments: [String]) -> Bool {
        arguments.contains { $0.hasPrefix(uiTestArgumentPrefix) }
    }

    /// This launch's choice.
    public static func current(storeIsOnDisk: Bool) -> SpotlightIndexChoice {
        decide(
            isRunningTests: TestEnvironment.isRunningTests, arguments: ProcessInfo.processInfo.arguments,
            storeIsOnDisk: storeIsOnDisk)
    }
}
