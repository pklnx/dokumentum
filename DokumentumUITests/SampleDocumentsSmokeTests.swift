import XCTest

/// The debug command "Add Sample Documents" on an empty in-memory store (`-UITestEmptyStore`): the
/// library starts empty, says that sync is off, and the command fills the Inbox (plan of #3, part 2).
final class SampleDocumentsSmokeTests: XCTestCase {
    /// The samples in the Inbox (`FixtureCatalog`); a UI test cannot see the app's code.
    private static let inboxSamples = 5

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testDebugCommandAddsSampleDocuments() {
        let ui = UITestApp()
        ui.launch(.empty)
        defer { ui.app.terminate() }
        XCTAssertTrue(ui.element("documentList").waitForExistence(timeout: 60), "no document list after the launch")
        XCTAssertTrue(ui.element("documentList.empty").waitForExistence(timeout: 10), "the empty store is not empty")

        #if os(iOS)
            let back = ui.app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 10), "no back button")
            back.tap()
            XCTAssertTrue(ui.element("sidebar").waitForExistence(timeout: 10), "no sidebar after going back")
        #endif
        XCTAssertTrue(ui.element("sidebar.syncOff").waitForExistence(timeout: 10), "no “Sync off” line")
        ui.attachWindowScreenshot("1-empty-sync-off", to: self)

        #if os(macOS)
            let menu = ui.app.menuBars.menuBarItems["Debug"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10), "no Debug menu")
            menu.click()
            let item = ui.app.menuBars.menuItems["Add Sample Documents"]
            XCTAssertTrue(item.waitForExistence(timeout: 10), "no “Add Sample Documents” item")
            item.click()
        #else
            ui.activate("debug.menu")
            ui.activate("debug.addSampleDocuments")
        #endif

        #if os(iOS)
            ui.activate("sidebar.inbox")
        #endif
        // The Inbox lists the samples that are in it, each once.
        let rows = ui.app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "documentList.row."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "no sample document in the list")
        XCTAssertEqual(Set(rows.allElementsBoundByIndex.map(\.identifier)).count, Self.inboxSamples)
        XCTAssertFalse(ui.element("documentList.empty").exists, "the list still says it is empty")
        ui.attachWindowScreenshot("2-samples-added", to: self)
    }
}
