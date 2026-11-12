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
            // All Documents says "No documents" (#89). The placeholder keeps its identifier and its text is in its
            // value (the label is empty), so the test waits until the value is no longer the Inbox's.
            let empty = ui.element("documentList.empty")
            let inboxEmpty = empty.value as? String ?? ""
            XCTAssertFalse(inboxEmpty.isEmpty, "“Inbox empty” has no value")
            ui.activate("sidebar.all")
            let noDocuments = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND value != %@", inboxEmpty), object: empty)
            XCTAssertEqual(
                XCTWaiter.wait(for: [noDocuments], timeout: 10), .completed,
                "All Documents does not say “No documents”")
            ui.attachWindowScreenshot("1b-no-documents", to: self)
            ui.assertTextContrast("documentList.empty", in: self)
            ui.activate("sidebar.inbox")
            let inboxAgain = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND value == %@", inboxEmpty), object: empty)
            XCTAssertEqual(XCTWaiter.wait(for: [inboxAgain], timeout: 10), .completed, "the Inbox is not shown again")
        #endif

        #if os(macOS)
            // In front again first: a system dialog can take the key focus, and the item stays disabled
            // without a focused window (review B of #53).
            ui.app.activate()
            let menu = ui.app.menuBars.menuBarItems["Debug"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10), "no Debug menu")
            menu.click()
            let item = ui.app.menuBars.menuItems["Add Sample Documents"]
            XCTAssertTrue(item.waitForExistence(timeout: 10), "no “Add Sample Documents” item")
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: item)
            XCTAssertEqual(
                XCTWaiter.wait(for: [enabled], timeout: 10), .completed, "“Add Sample Documents” stayed disabled")
            item.click()
        #else
            ui.activate("debug.menu")
            ui.activate("debug.addSampleDocuments")
        #endif

        #if os(iOS)
            ui.activate("sidebar.inbox")
        #endif
        // The Inbox lists the samples that are in it, each once. The accessibility tree fills the rows over
        // several passes, so the test waits until all of them are there (review B of #53).
        let rows = ui.app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "documentList.row."))
        let allRows = XCTNSPredicateExpectation(
            predicate: NSPredicate { query, _ in
                guard let query = query as? XCUIElementQuery else { return false }
                return Set(query.allElementsBoundByIndex.map(\.identifier)).count == Self.inboxSamples
            }, object: rows)
        XCTAssertEqual(
            XCTWaiter.wait(for: [allRows], timeout: 30), .completed,
            "the Inbox did not list \(Self.inboxSamples) samples")
        XCTAssertEqual(Set(rows.allElementsBoundByIndex.map(\.identifier)).count, Self.inboxSamples)
        XCTAssertFalse(ui.element("documentList.empty").exists, "the list still says it is empty")
        ui.attachWindowScreenshot("2-samples-added", to: self)

        // The Sync lab (#31, part 2) opens from the same debug menu: a window on the Mac, a sheet on the iPhone.
        #if os(macOS)
            ui.app.activate()
            XCTAssertTrue(menu.waitForExistence(timeout: 10), "no Debug menu")
            menu.click()
            let lab = ui.app.menuBars.menuItems["Sync Lab…"]
            XCTAssertTrue(lab.waitForExistence(timeout: 10), "no “Sync Lab…” item")
            lab.click()
        #else
            // Back from the Inbox to the sidebar, whose toolbar has the menu.
            ui.app.navigationBars.buttons.element(boundBy: 0).tap()
            ui.activate("debug.menu")
            ui.activate("debug.syncLab")
        #endif
        XCTAssertTrue(ui.element("syncLab.root").waitForExistence(timeout: 20), "the Sync lab did not open")
        ui.attachWindowScreenshot("3-sync-lab", to: self)
    }
}
