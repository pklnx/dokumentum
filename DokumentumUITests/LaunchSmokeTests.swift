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
        defer { launched.app.terminate() }
        XCTAssertTrue(launched.element(rootIdentifier).waitForExistence(timeout: 60), "The root view did not appear")
        #if os(macOS)
            // The unsigned Mac build has no CloudKit entitlement: "Sync off: this build has no iCloud access".
            XCTAssertTrue(launched.element("sidebar.syncOff").waitForExistence(timeout: 10), "no “Sync off” line")
            launched.attachWindowScreenshot("1-local-store-sync-off", to: self)
        #endif
    }
}
