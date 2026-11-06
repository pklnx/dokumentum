import XCTest

/// The real app starts and shows its root view, on iOS and on macOS.
final class LaunchSmokeTests: XCTestCase {
    /// `DokumentumApp.rootIdentifier`; a UI test cannot see the app's code.
    private let rootIdentifier = "dokumentum.root"

    @MainActor
    func testTheAppLaunchesAndShowsItsRootView() {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(
            app.descendants(matching: .any)[rootIdentifier].waitForExistence(timeout: 60),
            "The root view did not appear")
    }
}
