import Foundation

/// Which notification center a launch uses (#12, part 3; plan §7, N10, N2). Decided at launch together with the
/// settings suite and the scheduled set `S`, so a run either touches all of this device's real reminder state or none
/// of it:
/// - **in memory** whenever tests run (`TestEnvironment.isRunningTests`), whenever any launch argument starts with
///   `-UITest` (`-UITestLocalStore` included, which `StoreChoice.isUITestLaunch` does not cover), and whenever the store
///   is in memory (a `-SearchBenchmark` launch). The app then uses `InMemoryNotificationCenter`, a settings suite of its
///   own and an `S` in memory, all emptied at every such launch: with "fired" meaning "in `S` and no longer pending",
///   a stale `S` would read as fired;
/// - **system** otherwise: the system's center, this device's settings and `S` in a file excluded from backup
///   (`ScheduledSetFile`).
///
/// So no test reaches `UNUserNotificationCenter`, shows a permission prompt, or writes this device's reminder state.
public enum NotificationCenterChoice: Sendable, Equatable {
    case inMemory
    case system

    /// Every UI-test argument starts with it.
    public static let uiTestArgumentPrefix = "-UITest"

    /// The choice of a launch. The prefix rule holds in every build, not only in Debug: a launch with such an argument
    /// never needs the real center.
    public static func decide(isRunningTests: Bool, arguments: [String], storeIsOnDisk: Bool)
        -> NotificationCenterChoice
    {
        if isRunningTests || !storeIsOnDisk || isUITestLaunch(arguments: arguments) { return .inMemory }
        return .system
    }

    /// Whether any argument is a UI-test argument.
    public static func isUITestLaunch(arguments: [String]) -> Bool {
        arguments.contains { $0.hasPrefix(uiTestArgumentPrefix) }
    }

    /// This launch's choice.
    public static func current(storeIsOnDisk: Bool) -> NotificationCenterChoice {
        decide(
            isRunningTests: TestEnvironment.isRunningTests, arguments: ProcessInfo.processInfo.arguments,
            storeIsOnDisk: storeIsOnDisk)
    }
}
