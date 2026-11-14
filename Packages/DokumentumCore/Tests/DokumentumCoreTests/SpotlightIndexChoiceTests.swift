import DokumentumCore
import Foundation
import Testing

/// Which Spotlight index a launch uses (#13, plan §5, T7; D5): in memory for every test run, every `-UITest*` launch
/// (`-UITestLocalStore` included) and every in-memory store; the system's only otherwise. These run under `swift test`,
/// before any app launch.
struct SpotlightIndexChoiceTests {
    /// Every UI-test argument the app knows, and one that does not exist yet: the prefix decides, not a list.
    static let uiTestArguments = [
        "-UITestSeed", "-UITestEmptyStore", "-UITestLocalStore", "-UITestImportLetter", "-UITestToday",
        "-UITestNotifications", "-UITestImportSynthetic", "-UITestScanSynthetic", "-UITestCleanupSynthetic",
        "-UITestClassifierAvailability", "-UITestSyncStatus", "-UITestHoldSearchIndex", "-UITestFailingSaves",
        "-UITestAppearance", "-UITestOpenDocument", "-UITestSomethingLater",
    ]

    @Test func aTestRunAlwaysGetsTheInMemoryIndex() {
        #expect(SpotlightIndexChoice.decide(isRunningTests: true, arguments: [], storeIsOnDisk: true) == .inMemory)
        #expect(SpotlightIndexChoice.decide(isRunningTests: true, arguments: [], storeIsOnDisk: false) == .inMemory)
    }

    /// This very run: `swift test` (and the app host under `xcodebuild`) is a test run.
    @Test func thisRunGetsTheInMemoryIndex() {
        #expect(TestEnvironment.isRunningTests)
        #expect(SpotlightIndexChoice.current(storeIsOnDisk: true) == .inMemory)
    }

    @Test(arguments: uiTestArguments)
    func everyUITestLaunchGetsTheInMemoryIndex(argument: String) {
        let arguments = ["/Applications/Dokumentum.app/Contents/MacOS/Dokumentum", argument, "YES"]
        #expect(
            SpotlightIndexChoice.decide(isRunningTests: false, arguments: arguments, storeIsOnDisk: true) == .inMemory)
    }

    /// `-UITestLocalStore` opens a store on disk and is no UI-test launch for `StoreChoice`; the prefix rule still
    /// picks the in-memory index. The rule has no `#if DEBUG`: this call is what a Release build makes too.
    @Test func aLocalStoreUITestLaunchIsNoStoreUITestLaunchButGetsTheInMemoryIndex() {
        let arguments = ["-UITestLocalStore", "LaunchSmoke", "-ApplePersistenceIgnoreState", "YES"]
        #expect(!StoreChoice.isUITestLaunch(arguments: arguments))
        #expect(
            SpotlightIndexChoice.decide(isRunningTests: false, arguments: arguments, storeIsOnDisk: true) == .inMemory)
    }

    @Test func anInMemoryStoreGetsTheInMemoryIndex() {
        #expect(
            SpotlightIndexChoice.decide(
                isRunningTests: false, arguments: ["-SearchBenchmark", "5000"], storeIsOnDisk: false)
                == .inMemory)
    }

    /// Only a real launch on a store on disk without any UI-test argument gets the system's index.
    @Test func otherwiseTheSystemIndex() {
        #expect(SpotlightIndexChoice.decide(isRunningTests: false, arguments: [], storeIsOnDisk: true) == .system)
        #expect(
            SpotlightIndexChoice.decide(
                isRunningTests: false, arguments: ["-AppleLanguages", "(de)", "-NSDocumentRevisionsDebugMode", "YES"],
                storeIsOnDisk: true) == .system)
        #expect(
            SpotlightIndexChoice.decide(isRunningTests: false, arguments: ["UITestSeed"], storeIsOnDisk: true)
                == .system, "not an argument with the prefix")
    }
}
