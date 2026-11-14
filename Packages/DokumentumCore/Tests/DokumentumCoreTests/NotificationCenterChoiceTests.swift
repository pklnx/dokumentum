import DokumentumCore
import DokumentumKit
import Foundation
import Testing

/// Which notification center a launch uses (#12, part 3; plan §7, N10, N2; D7): in memory for every test run, every
/// `-UITest*` launch (`-UITestLocalStore` included) and every in-memory store; the system's only otherwise. These run
/// under `swift test`, before any app launch.
struct NotificationCenterChoiceTests {
    /// Every UI-test argument the app knows, and two that do not exist yet: the prefix decides, not a list.
    static let uiTestArguments = [
        "-UITestSeed", "-UITestEmptyStore", "-UITestLocalStore", "-UITestImportLetter", "-UITestToday",
        "-UITestNotifications", "-UITestImportSynthetic", "-UITestScanSynthetic", "-UITestCleanupSynthetic",
        "-UITestClassifierAvailability", "-UITestSyncStatus", "-UITestHoldSearchIndex", "-UITestFailingSaves",
        "-UITestAppearance", "-UITestSomethingLater",
    ]

    @Test func aTestRunAlwaysGetsTheInMemoryCenter() {
        #expect(NotificationCenterChoice.decide(isRunningTests: true, arguments: [], storeIsOnDisk: true) == .inMemory)
        #expect(NotificationCenterChoice.decide(isRunningTests: true, arguments: [], storeIsOnDisk: false) == .inMemory)
    }

    /// This very run: `swift test` is a test run.
    @Test func thisRunGetsTheInMemoryCenter() {
        #expect(TestEnvironment.isRunningTests)
        #expect(NotificationCenterChoice.current(storeIsOnDisk: true) == .inMemory)
    }

    @Test(arguments: uiTestArguments)
    func everyUITestLaunchGetsTheInMemoryCenter(argument: String) {
        let arguments = ["/Applications/Dokumentum.app/Contents/MacOS/Dokumentum", argument, "YES"]
        #expect(
            NotificationCenterChoice.decide(isRunningTests: false, arguments: arguments, storeIsOnDisk: true)
                == .inMemory)
    }

    /// `-UITestLocalStore` opens a store on disk and is no UI-test launch for `StoreChoice`; the prefix rule still
    /// picks the in-memory center (review N10).
    @Test func aLocalStoreUITestLaunchIsNoStoreUITestLaunchButGetsTheInMemoryCenter() {
        let arguments = ["-UITestLocalStore", "LaunchSmoke", "-ApplePersistenceIgnoreState", "YES"]
        #expect(!StoreChoice.isUITestLaunch(arguments: arguments))
        #expect(
            NotificationCenterChoice.decide(isRunningTests: false, arguments: arguments, storeIsOnDisk: true)
                == .inMemory)
    }

    @Test func anInMemoryStoreGetsTheInMemoryCenter() {
        #expect(
            NotificationCenterChoice.decide(
                isRunningTests: false, arguments: ["-SearchBenchmark", "YES"], storeIsOnDisk: false)
                == .inMemory)
    }

    /// Only a real launch on a store on disk without any UI-test argument gets the system's center.
    @Test func otherwiseTheSystemCenter() {
        #expect(NotificationCenterChoice.decide(isRunningTests: false, arguments: [], storeIsOnDisk: true) == .system)
        #expect(
            NotificationCenterChoice.decide(
                isRunningTests: false, arguments: ["-AppleLanguages", "(de)", "-NSDocumentRevisionsDebugMode", "YES"],
                storeIsOnDisk: true) == .system)
        #expect(
            NotificationCenterChoice.decide(isRunningTests: false, arguments: ["UITestSeed"], storeIsOnDisk: true)
                == .system, "not an argument with the prefix")
    }

    /// The in-memory center never needs UI: without `-UITestNotifications` it answers `notDetermined`, and a request
    /// answers `denied`.
    @Test func theInMemoryCenterAnswersWithoutUI() async {
        let center = InMemoryNotificationCenter()
        #expect(await center.authorizationStatus() == .notDetermined)
        #expect(await center.requestAuthorization() == .denied)
        #expect(await center.authorizationStatus() == .denied)
        #expect(await center.authorizationRequests == 1)
    }
}
