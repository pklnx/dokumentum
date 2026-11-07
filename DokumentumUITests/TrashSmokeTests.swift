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
        goToSidebar(ui)
        XCTAssertTrue(waitForCount(0, of: "sidebar.trash", in: ui), "the trash is not empty at the start")
        ui.activate("sidebar.inbox")

        moveToTrash(Self.electricityBill, ui)
        waitForDisappearance(of: row, "the document stayed in the Inbox")
        ui.attachWindowScreenshot("1-moved-to-trash", to: self)

        goToSidebar(ui)
        XCTAssertTrue(waitForCount(1, of: "sidebar.trash", in: ui), "the Trash count did not go up")
        ui.activate("sidebar.trash")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the document is not in the trash")
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
        ui.activate("sidebar.inbox")
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
        moveToTrash(Self.medicalInvoice, ui)
        waitForDisappearance(of: ui.element(Self.documentRow(Self.medicalInvoice)), "not moved")

        goToSidebar(ui)
        ui.activate("sidebar.trash")
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
        ui.activate("sidebar.all")
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

    /// Waits until the sidebar row's VoiceOver value ("3 documents", "1 Dokument") starts with `count`. iOS only:
    /// on the Mac the row's button exposes its title but no value (measured on #46, also with the value set on the
    /// link itself), so there the test checks the Trash list's rows instead; `LibraryTrashTests` checks the counts.
    @MainActor
    private func waitForCount(_ count: Int, of identifier: String, in ui: UITestApp) -> Bool {
        #if os(macOS)
            return true
        #else
            let element = ui.element(identifier)
            let predicate = NSPredicate { object, _ in
                guard let element = object as? XCUIElement, element.exists else { return false }
                return (element.value as? String)?.hasPrefix("\(count) ") == true
            }
            return XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 20) == .completed
        #endif
    }

    @MainActor
    private func waitForDisappearance(of element: XCUIElement, _ message: String) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 20), .completed, message)
    }
}
