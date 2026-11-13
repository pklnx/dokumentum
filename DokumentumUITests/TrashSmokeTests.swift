import XCTest

/// The trash on the sample documents (`-UITestSeed`, in memory; plan of #3, part 4): a document moves into the
/// trash and back, and Empty Trash asks first and deletes only the trash's documents.
final class TrashSmokeTests: XCTestCase {
    // The identifiers and fixed IDs of the app (`AccessibilityID`, `FixtureCatalog`); a UI test cannot see the
    // app's code.
    private static func documentRow(_ number: Int) -> String {
        "documentList.row." + String(format: "5EED0000-0000-4000-8000-%012d", number)
    }

    /// Electricity bill and Medical invoice (Inbox), Account statement (not in the Inbox).
    private static let electricityBill = 1
    private static let medicalInvoice = 2
    private static let accountStatement = 4

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testMoveToTrashAndRestore() {
        let ui = UITestApp()
        ui.launch()
        defer { ui.app.terminate() }
        XCTAssertTrue(ui.element("documentList").waitForExistence(timeout: 60), "no document list after the launch")
        let row = ui.element(Self.documentRow(Self.electricityBill))
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(ui.element("import.menu").exists, "no Import menu in the Inbox")
        goToSidebar(ui)
        XCTAssertTrue(waitForCount(0, of: "sidebar.trash", in: ui), "the trash is not empty at the start")
        openSidebarRow("sidebar.inbox", ui)

        moveToTrash(Self.electricityBill, ui)
        waitForDisappearance(of: row, "the document stayed in the Inbox")
        ui.attachWindowScreenshot("1-moved-to-trash", to: self)

        goToSidebar(ui)
        XCTAssertTrue(waitForCount(1, of: "sidebar.trash", in: ui), "the Trash count did not go up")
        openSidebarRow("sidebar.trash", ui)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the document is not in the trash")
        // The trash's toolbar has only Empty Trash, no Import (#70).
        XCTAssertTrue(ui.element("trash.empty").waitForExistence(timeout: 10), "no Empty Trash in the trash")
        XCTAssertFalse(ui.element("import.menu").exists, "the trash offers Import")
        ui.attachWindowScreenshot("2-trash", to: self)

        // A trashed document's detail is read only and offers Restore.
        ui.activate(Self.documentRow(Self.electricityBill))
        XCTAssertTrue(ui.element("documentDetail.trashed").waitForExistence(timeout: 20), "no trash bar")
        XCTAssertTrue(ui.element("documentDetail.pdf").waitForExistence(timeout: 20), "the PDF did not appear")
        ui.attachWindowScreenshot("3-trashed-detail", to: self)
        ui.activate("documentDetail.restore")

        // Back in the Inbox; the trash is empty again.
        XCTAssertTrue(ui.element("documentList.empty").waitForExistence(timeout: 20), "the trash is not empty")
        goToSidebar(ui)
        XCTAssertTrue(waitForCount(0, of: "sidebar.trash", in: ui), "the Trash count did not go down")
        openSidebarRow("sidebar.inbox", ui)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the restored document is not back in the Inbox")
        ui.attachWindowScreenshot("4-restored", to: self)
    }

    @MainActor
    func testEmptyTrashAsksFirst() {
        let ui = UITestApp()
        ui.launch()
        defer { ui.app.terminate() }
        XCTAssertTrue(ui.element("documentList").waitForExistence(timeout: 60), "no document list after the launch")
        XCTAssertTrue(ui.element(Self.documentRow(Self.electricityBill)).waitForExistence(timeout: 10))
        moveToTrash(Self.electricityBill, ui)
        waitForDisappearance(of: ui.element(Self.documentRow(Self.electricityBill)), "not moved")
        #if os(iOS)
            // The open document's menu trashes it, and the stack goes back to the list (#70).
            ui.activate(Self.documentRow(Self.medicalInvoice))
            XCTAssertTrue(ui.element("documentDetail.menu").waitForExistence(timeout: 20), "no menu on the document")
            ui.activate("documentDetail.menu")
            XCTAssertTrue(
                ui.element("documentDetail.moveToTrash").waitForExistence(timeout: 10), "no Move to Trash in the menu")
            ui.attachWindowScreenshot("5a-detail-menu", to: self)
            ui.activate("documentDetail.moveToTrash")
            XCTAssertTrue(ui.element("documentList").waitForExistence(timeout: 20), "not back on the list")
            XCTAssertFalse(ui.element("documentDetail.menu").exists, "the trashed document stayed open")
        #else
            moveToTrash(Self.medicalInvoice, ui)
        #endif
        waitForDisappearance(of: ui.element(Self.documentRow(Self.medicalInvoice)), "not moved")

        goToSidebar(ui)
        openSidebarRow("sidebar.trash", ui)
        XCTAssertTrue(ui.element(Self.documentRow(Self.electricityBill)).waitForExistence(timeout: 10))
        XCTAssertTrue(ui.element(Self.documentRow(Self.medicalInvoice)).exists)

        // Cancel keeps everything.
        ui.activate("trash.empty")
        XCTAssertTrue(ui.element("trash.empty.confirm").waitForExistence(timeout: 10), "Empty Trash did not ask")
        ui.attachWindowScreenshot("5-empty-trash-asks", to: self)
        ui.activate("trash.empty.cancel")
        waitForDisappearance(of: ui.element("trash.empty.confirm"), "the confirmation stayed open")
        XCTAssertTrue(ui.element(Self.documentRow(Self.electricityBill)).exists, "cancel deleted a document")
        XCTAssertTrue(ui.element(Self.documentRow(Self.medicalInvoice)).exists, "cancel deleted a document")

        // Confirm empties the trash.
        ui.activate("trash.empty")
        ui.activate("trash.empty.confirm")
        XCTAssertTrue(ui.element("documentList.empty").waitForExistence(timeout: 20), "the trash is not empty")
        XCTAssertFalse(ui.element(Self.documentRow(Self.electricityBill)).exists)
        ui.attachWindowScreenshot("6-trash-emptied", to: self)

        // The other documents remain.
        goToSidebar(ui)
        XCTAssertTrue(waitForCount(0, of: "sidebar.trash", in: ui), "the Trash count did not go to 0")
        openSidebarRow("sidebar.all", ui)
        XCTAssertTrue(
            ui.element(Self.documentRow(Self.accountStatement)).waitForExistence(timeout: 10), "a document is gone")
        XCTAssertFalse(ui.element(Self.documentRow(Self.electricityBill)).exists, "a deleted document is listed")
        XCTAssertFalse(ui.element(Self.documentRow(Self.medicalInvoice)).exists, "a deleted document is listed")
        ui.attachWindowScreenshot("7-others-remain", to: self)
    }

    /// The iPhone swipes the row; the Mac uses the row's context menu.
    @MainActor
    private func moveToTrash(_ number: Int, _ ui: UITestApp) {
        let row = ui.element(Self.documentRow(number))
        XCTAssertTrue(row.waitForExistence(timeout: 10), "row \(number) is not listed")
        #if os(iOS)
            row.swipeLeft()
            ui.activate("documentList.swipe.moveToTrash")
        #else
            row.rightClick()
            ui.activate("documentList.moveToTrash")
        #endif
    }

    /// The sidebar: on the iPhone back from the list, on the Mac always shown.
    @MainActor
    private func goToSidebar(_ ui: UITestApp) {
        #if os(iOS)
            if !ui.element("sidebar").exists {
                let back = ui.app.navigationBars.buttons.element(boundBy: 0)
                XCTAssertTrue(back.waitForExistence(timeout: 10), "no back button")
                back.tap()
            }
            XCTAssertTrue(ui.element("sidebar").waitForExistence(timeout: 10), "no sidebar after going back")
        #endif
    }

    /// Scrolls the sidebar row into full view (`UITestApp.revealSidebarRow`): on the iPhone the list creates Trash, its
    /// last row, only once it is scrolled into view, and Inbox and All Documents leave the view when it is.
    @MainActor
    private func revealSidebarRow(_ identifier: String, _ ui: UITestApp) {
        ui.revealSidebarRow(identifier, missingTowards: identifier == "sidebar.trash" ? .bottom : .top)
    }

    /// Selects a sidebar row, scrolled into view first; on the iPhone that opens its list.
    @MainActor
    private func openSidebarRow(_ identifier: String, _ ui: UITestApp) {
        revealSidebarRow(identifier, ui)
        #if os(iOS)
            // A tap on a list that still moves after a swipe only stops it (measured on iOS 27.0, #46): a second
            // tap, at most, selects the row.
            for _ in 0..<2 where !ui.element("documentList").exists {
                ui.activate(identifier)
                _ = ui.element("documentList").waitForExistence(timeout: 5)
            }
            XCTAssertTrue(ui.element("documentList").waitForExistence(timeout: 10), "\(identifier) opened no list")
        #else
            ui.activate(identifier)
        #endif
    }

    /// Waits until the sidebar row's VoiceOver value ("3 documents", "1 Dokument") starts with `count`. On both
    /// devices since the Mac's sidebar rows are no longer links, which exposed no value there (#47).
    @MainActor
    private func waitForCount(_ count: Int, of identifier: String, in ui: UITestApp) -> Bool {
        revealSidebarRow(identifier, ui)
        let element = ui.element(identifier)
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement, element.exists else { return false }
            return (element.value as? String)?.hasPrefix("\(count) ") == true
        }
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 20) == .completed
    }

    @MainActor
    private func waitForDisappearance(of element: XCUIElement, _ message: String) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 20), .completed, message)
    }
}
