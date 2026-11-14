import XCTest

/// The Mac's menu commands on the sample documents (`-UITestSeed`, in memory; plan of #3, part 5, PQ15): Go
/// (⌘1-⌘3, and ⌘4 for Deadlines, #12 part 2a), Document › Show Info (⌘I), Edit › Move to Trash (⌘⌫) and File › Empty Trash… (⌘⇧⌫), through the real
/// menu bar's key equivalents. It includes reviewer B's ⌘⌫ probe of #67 (#70): ⌘⌫ in the title field edits only
/// the text.
final class MenuCommandsSmokeTests: XCTestCase {
    // The identifiers and fixed IDs of the app (`AccessibilityID`, `FixtureCatalog`); a UI test cannot see the
    // app's code. Sample data, the same in every language.
    private static func documentRow(_ number: Int) -> String {
        "documentList.row." + String(format: "5EED0000-0000-4000-8000-%012d", number)
    }

    /// Account statement: not in the Inbox, so only All Documents lists it.
    private static let accountStatement = 4
    /// Medical invoice: an overdue deadline, so Deadlines lists it; the electricity bill (1) has none.
    private static let medicalInvoice = 2

    override func setUp() {
        continueAfterFailure = false
    }

    #if os(macOS)
        @MainActor
        func testMenuCommandsOnMac() {
            let ui = UITestApp()
            ui.launch()
            defer { ui.app.terminate() }
            XCTAssertTrue(
                ui.element("documentList").waitForExistence(timeout: 60), "no document list after the launch")
            let row = ui.element(Self.documentRow(Self.accountStatement))
            XCTAssertFalse(row.exists, "the start list is not the Inbox")

            // ⌘2: All Documents.
            ui.app.typeKey("2", modifierFlags: .command)
            XCTAssertTrue(row.waitForExistence(timeout: 10), "⌘2 did not list all documents")
            ui.activate(Self.documentRow(Self.accountStatement))
            XCTAssertTrue(ui.element("documentDetail.pdf").waitForExistence(timeout: 20), "the PDF did not appear")
            ui.attachWindowScreenshot("1-all-documents", to: self)

            // ⌘I: the info panel. ⌘⌫ in its title field deletes the text before the cursor, and nothing else.
            ui.app.typeKey("i", modifierFlags: .command)
            let title = ui.element("documentInfo.title")
            XCTAssertTrue(title.waitForExistence(timeout: 20), "⌘I opened no info panel")
            let storedTitle = title.value as? String ?? ""
            XCTAssertFalse(storedTitle.isEmpty, "the title field is empty")
            title.click()
            title.typeKey(.rightArrow, modifierFlags: .command)
            title.typeKey(.delete, modifierFlags: .command)
            let emptied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == ''"), object: title)
            XCTAssertEqual(
                XCTWaiter.wait(for: [emptied], timeout: 10), .completed,
                "⌘⌫ did not edit the title: \(String(describing: title.value))")
            XCTAssertTrue(row.exists, "⌘⌫ in the title field trashed the document")
            XCTAssertTrue(ui.element("documentDetail.pdf").exists, "⌘⌫ in the title field closed the document")
            ui.attachWindowScreenshot("2-title-field-command-delete", to: self)
            // The stored title again, saved with Return: the field's edit leaves the data as it was.
            title.typeText(storedTitle + "\r")
            XCTAssertEqual(title.value as? String, storedTitle)

            // ⌘⌫ with the focus in the list: the open document goes to the trash, and the info panel closes.
            ui.activate(Self.documentRow(Self.accountStatement))
            ui.app.typeKey(.delete, modifierFlags: .command)
            XCTAssertTrue(row.waitForNonExistence(timeout: 20), "⌘⌫ did not trash the document")
            XCTAssertTrue(title.waitForNonExistence(timeout: 10), "the info panel stayed open")

            // ⌘3: the Trash, which lists it.
            ui.app.typeKey("3", modifierFlags: .command)
            XCTAssertTrue(row.waitForExistence(timeout: 10), "⌘3 did not show the document in the trash")
            XCTAssertTrue(ui.element("trash.empty").exists, "⌘3 did not open the trash")
            ui.attachWindowScreenshot("3-trash", to: self)

            // ⌘⇧⌫ asks first; Cancel keeps the document.
            ui.app.typeKey(.delete, modifierFlags: [.command, .shift])
            XCTAssertTrue(ui.element("trash.empty.confirm").waitForExistence(timeout: 10), "⌘⇧⌫ did not ask")
            ui.attachWindowScreenshot("4-empty-trash-asks", to: self)
            ui.activate("trash.empty.cancel")
            XCTAssertTrue(
                ui.element("trash.empty.confirm").waitForNonExistence(timeout: 10), "the confirmation stayed open")
            XCTAssertTrue(row.exists, "Cancel deleted the document")

            // ⌘1: back to the Inbox, without it.
            ui.app.typeKey("1", modifierFlags: .command)
            XCTAssertTrue(
                ui.element(Self.documentRow(1)).waitForExistence(timeout: 10), "⌘1 did not show the Inbox")
            XCTAssertFalse(row.exists)

            // ⌘4: Deadlines, with the medical invoice and without the electricity bill; the trashed account statement
            // is not there either.
            ui.app.typeKey("4", modifierFlags: .command)
            XCTAssertTrue(
                ui.element(Self.documentRow(1)).waitForNonExistence(timeout: 10), "⌘4 did not leave the Inbox")
            XCTAssertTrue(
                ui.element(Self.documentRow(Self.medicalInvoice)).waitForExistence(timeout: 10),
                "⌘4 did not show Deadlines")
            XCTAssertFalse(row.exists, "a trashed document in Deadlines")
            ui.attachWindowScreenshot("5-deadlines", to: self)
        }
    #endif
}
