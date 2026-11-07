import XCTest

/// The real app starts on a local store on disk and shows its root view, on iOS and on macOS. The store
/// is a new one in the app's temporary directory (`-UITestLocalStore`), never the archive's path.
final class LaunchSmokeTests: XCTestCase {
    /// `DokumentumApp.rootIdentifier`; a UI test cannot see the app's code.
    private let rootIdentifier = "dokumentum.root"

    @MainActor
    func testTheAppLaunchesAndShowsItsRootView() {
        let launched = UITestApp()
        launched.launch(.localOnDisk(name: "LaunchSmoke"))
        defer { quit(launched.app) }
        XCTAssertTrue(launched.element(rootIdentifier).waitForExistence(timeout: 60), "The root view did not appear")
        #if os(macOS)
            // The unsigned Mac build has no CloudKit entitlement: "Sync off: this build has no iCloud access".
            XCTAssertTrue(launched.element("sidebar.syncOff").waitForExistence(timeout: 10), "no “Sync off” line")
            launched.attachWindowScreenshot("1-local-store-sync-off", to: self)
        #endif
    }

    /// Ends the launch. On the Mac a normal quit (⌘Q), so the app removes its `-UITestLocalStore` folder in
    /// `willTerminate`; `terminate()` ends it without that notification (measured on #53). On the iPhone the
    /// folder is in the app's own container and is removed at its next launch.
    @MainActor
    private func quit(_ app: XCUIApplication) {
        #if os(macOS)
            app.activate()
            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 30), "the app did not quit")
        #else
            app.terminate()
        #endif
    }
}
