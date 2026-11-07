import XCTest

/// Editing in the info panel (plan of #3, part 3) on the sample documents (`-UITestSeed`): the title and the
/// correspondent change, and the list shows the new values after leaving the Inbox and coming back. On the Mac
/// the delete key in the title field only edits the text (a regression of the predecessor,
/// `MacSmokeTests.testDeleteKeyInTheTitleFieldOnlyEditsText`).
final class EditingSmokeTests: XCTestCase {
    // The identifiers and fixed IDs of the app (`AccessibilityID`, `FixtureCatalog`); a UI test cannot see the
    // app's code. The titles and names are sample data, the same in every language.
    private static let electricityBill = "documentList.row.5EED0000-0000-4000-8000-000000000001"
    private static let newTitle = "Electricity bill edited"
    private static let newCorrespondent = "Musterbank AG"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testEditTitleAndCorrespondent() {
        let ui = UITestApp()
        ui.launch()
        defer { ui.app.terminate() }
        XCTAssertTrue(ui.element("documentList").waitForExistence(timeout: 60), "no document list after the launch")
        ui.activate(Self.electricityBill)
        XCTAssertTrue(ui.element("documentDetail.pdf").waitForExistence(timeout: 20), "the PDF did not appear")
        let showInfo = ui.element("documentDetail.showInfo")
        XCTAssertTrue(showInfo.waitForExistence(timeout: 20), "no Show Info button")
        let closedLabel = showInfo.label
        ui.activate("documentDetail.showInfo")
        let title = ui.element("documentInfo.title")
        XCTAssertTrue(title.waitForExistence(timeout: 20), "no info panel")
        // The button now hides the panel and says so, also to VoiceOver ("Hide Info").
        let relabelled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", closedLabel), object: showInfo)
        XCTAssertEqual(
            XCTWaiter.wait(for: [relabelled], timeout: 10), .completed, "the button still says \(closedLabel)")
        ui.attachWindowScreenshot("1-info", to: self)

        // The title: replaced, saved with Return.
        #if os(macOS)
            title.click()
            title.typeKey("a", modifierFlags: .command)
            title.typeText(Self.newTitle + "\r")
            // ⌫ in the field deletes a character and nothing else: the document stays open and listed. Return
            // leaves the whole text selected, so the cursor goes to the end first.
            title.typeKey(.rightArrow, modifierFlags: [])
            title.typeText("X")
            title.typeKey(.delete, modifierFlags: [])
            XCTAssertEqual(title.value as? String, Self.newTitle, "⌫ did not only edit the text")
            XCTAssertTrue(ui.element("documentDetail.pdf").exists, "⌫ closed the document")
            XCTAssertTrue(ui.element(Self.electricityBill).exists, "⌫ removed the document from the list")
        #else
            title.tap()
            let length = (title.value as? String)?.count ?? 0
            title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length + 5))
            title.typeText(Self.newTitle + "\n")
        #endif

        // The correspondent: another existing one.
        ui.activate("documentInfo.correspondent")
        #if os(macOS)
            let choice = ui.app.menuItems[Self.newCorrespondent]
            XCTAssertTrue(choice.waitForExistence(timeout: 10), "no \(Self.newCorrespondent) in the picker")
            choice.click()
        #else
            let choice = ui.app.buttons[Self.newCorrespondent]
            XCTAssertTrue(choice.waitForExistence(timeout: 10), "no \(Self.newCorrespondent) in the picker")
            choice.tap()
        #endif
        let picked = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value CONTAINS %@ OR label CONTAINS %@", Self.newCorrespondent, Self.newCorrespondent),
            object: ui.element("documentInfo.correspondent"))
        XCTAssertEqual(XCTWaiter.wait(for: [picked], timeout: 10), .completed, "the picker does not show the choice")
        ui.attachWindowScreenshot("2-info-edited", to: self)

        // To All Documents and back to the Inbox: the row shows both new values.
        #if os(iOS)
            ui.activate("documentInfo.done")
            // The sheet's own bar must be gone before the back button is looked up.
            XCTAssertTrue(ui.element("documentInfo").waitForNonExistence(timeout: 10), "the info sheet stayed open")
            goBack(ui)
            XCTAssertTrue(ui.element("documentList").waitForExistence(timeout: 10), "no list after going back")
            goBack(ui)
            XCTAssertTrue(ui.element("sidebar").waitForExistence(timeout: 10), "no sidebar after going back")
        #endif
        ui.activate("sidebar.all")
        XCTAssertTrue(ui.element(Self.electricityBill).waitForExistence(timeout: 10), "not in All Documents")
        #if os(iOS)
            goBack(ui)
        #endif
        ui.activate("sidebar.inbox")
        let row = ui.element(Self.electricityBill)
        let updated = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@", Self.newTitle, Self.newCorrespondent),
            object: row)
        XCTAssertEqual(
            XCTWaiter.wait(for: [updated], timeout: 20), .completed,
            "the row does not show the new values: \(row.label)")
        XCTAssertFalse(row.label.contains("Stadtwerke Musterstadt"), "the row still shows the old correspondent")
        ui.attachWindowScreenshot("3-row-updated", to: self)
    }

    /// A title whose save fails (`-UITestFailingSaves YES`: every save of the editor fails and is rolled back) says
    /// so under the field, the field shows the stored title again, and typing ends the line (maintainer decision on
    /// #74).
    @MainActor
    func testATitleThatCannotBeSavedSaysSo() {
        let ui = UITestApp()
        ui.launch(extraArguments: ["-UITestFailingSaves", "YES"])
        defer { ui.app.terminate() }
        XCTAssertTrue(ui.element("documentList").waitForExistence(timeout: 60), "no document list after the launch")
        ui.activate(Self.electricityBill)
        XCTAssertTrue(ui.element("documentDetail.pdf").waitForExistence(timeout: 20), "the PDF did not appear")
        ui.activate("documentDetail.showInfo")
        let title = ui.element("documentInfo.title")
        XCTAssertTrue(title.waitForExistence(timeout: 20), "no info panel")
        let storedTitle = title.value as? String ?? ""
        let notSaved = ui.element("documentInfo.titleNotSaved")
        XCTAssertFalse(notSaved.exists, "the line shows before any edit")

        #if os(macOS)
            title.click()
            title.typeKey("a", modifierFlags: .command)
            title.typeText(Self.newTitle + "\r")
        #else
            title.tap()
            let length = (title.value as? String)?.count ?? 0
            title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length + 5))
            title.typeText(Self.newTitle + "\n")
        #endif
        XCTAssertTrue(notSaved.waitForExistence(timeout: 10), "no “could not be saved” line")
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", storedTitle), object: title)
        XCTAssertEqual(
            XCTWaiter.wait(for: [restored], timeout: 10), .completed,
            "the field does not show the stored title: \(String(describing: title.value))")
        ui.attachWindowScreenshot("4-title-not-saved", to: self)

        // Typing again ends the line.
        #if os(macOS)
            title.click()
        #else
            title.tap()
        #endif
        title.typeText("X")
        XCTAssertTrue(notSaved.waitForNonExistence(timeout: 10), "the line stayed while typing")
    }

    #if os(iOS)
        /// The navigation bar's back button.
        @MainActor
        private func goBack(_ ui: UITestApp) {
            let back = ui.app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 10), "no back button")
            back.tap()
        }
    #endif
}
