import XCTest

/// The search field on the sample documents (`-UITestSeed`; #7, part 3): a word from one document's text, the scope
/// switch, a filter chip, and on the Mac Edit › Find… (⌘F) and a sidebar change that keeps the search (P7). The index
/// is held after its first text batch (`-UITestHoldSearchIndex`), which holds every sample text, so the "Indexing
/// texts…" line shows and is audited.
final class SearchSmokeTests: XCTestCase {
    // The identifiers and fixed IDs of the app (`AccessibilityID`, `FixtureCatalog`); a UI test cannot see the
    // app's code.
    private static func documentRow(_ number: Int) -> String {
        "documentList.row." + String(format: "5EED0000-0000-4000-8000-%012d", number)
    }

    private static func tagID(_ number: Int) -> String { String(format: "5EED0001-0000-4000-8000-%012d", number) }

    /// Electricity bill (Inbox), Car insurance (Auto, not in the Inbox), Golf inspection (Auto › Golf, not in the
    /// Inbox; its text alone has the word "Autohaus").
    private static let electricityBill = 1
    private static let carInsurance = 7
    private static let golfInspection = 8
    private static let auto = 3
    private static let golf = 4

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchScopeAndChip() {
        let ui = UITestApp()
        ui.launch(extraArguments: ["-UITestHoldSearchIndex", "YES"])
        defer { ui.app.terminate() }
        XCTAssertTrue(ui.element("documentList").waitForExistence(timeout: 60), "no document list after the launch")
        XCTAssertTrue(ui.element(Self.documentRow(Self.electricityBill)).waitForExistence(timeout: 10))
        let field = ui.app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search field")

        #if os(macOS)
            // One Find item in the whole menu bar (ours, Edit › Find…; the system adds none), and ⌘F puts the focus
            // into the field (P7, plan review N8).
            let findTitles = ["Find", "Find…", "Suchen", "Suchen …"]
            let findItems = ui.app.menuBars.menuItems.matching(NSPredicate(format: "title IN %@", findTitles))
            XCTAssertEqual(findItems.count, 1, "not exactly one Find item in the menu bar")
            ui.app.typeKey("f", modifierFlags: .command)
            let focused = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
            XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 10), .completed, "⌘F did not focus the search field")
        #else
            field.tap()
        #endif

        // A word only the Golf inspection's text has; the Inbox does not list it.
        field.typeText("autohaus")
        XCTAssertTrue(ui.element("search.empty").waitForExistence(timeout: 10), "no “No Results” in the Inbox")
        XCTAssertFalse(ui.element(Self.documentRow(Self.golfInspection)).exists)
        XCTAssertFalse(ui.element(Self.documentRow(Self.electricityBill)).exists)
        XCTAssertTrue(ui.element("search.indexing").exists, "no “Indexing texts…” line")
        ui.attachWindowScreenshot("search-1-no-results", to: self)

        // The scope All Documents finds it, and only it.
        selectScope(all: true, in: ui)
        XCTAssertTrue(
            ui.element(Self.documentRow(Self.golfInspection)).waitForExistence(timeout: 10),
            "All Documents did not find the text")
        XCTAssertFalse(ui.element(Self.documentRow(Self.electricityBill)).exists)
        ui.attachWindowScreenshot("search-2-all-documents", to: self)
        ui.auditAccessibility("search", in: self)

        // Cleared: no search, so the selected list (the Inbox) again; the scope applies only to a search.
        clear(field)
        XCTAssertTrue(
            ui.element(Self.documentRow(Self.electricityBill)).waitForExistence(timeout: 10), "clearing kept a filter")
        XCTAssertFalse(ui.element(Self.documentRow(Self.golfInspection)).exists, "clearing left All Documents")

        // A chip from the suggestions, with the scope still All Documents: Tag Auto › Golf.
        field.typeText("golf")
        ui.activate("search.token.tag." + Self.tagID(Self.golf))
        XCTAssertTrue(
            ui.element(Self.documentRow(Self.electricityBill)).waitForNonExistence(timeout: 10),
            "the chip did not filter")
        XCTAssertTrue(ui.element(Self.documentRow(Self.golfInspection)).exists)
        XCTAssertFalse(ui.element(Self.documentRow(Self.carInsurance)).exists)
        ui.attachWindowScreenshot("search-3-chip", to: self)

        #if os(macOS)
            // Back to the selected list (the Inbox): nothing has the chip there. Another sidebar list keeps the search
            // and its chip (P7): Auto lists the Golf inspection, not the car insurance.
            selectScope(all: false, in: ui)
            XCTAssertTrue(ui.element("search.empty").waitForExistence(timeout: 10), "the chip found Inbox documents")
            ui.activate("sidebar.tag." + Self.tagID(Self.auto))
            XCTAssertTrue(
                ui.element(Self.documentRow(Self.golfInspection)).waitForExistence(timeout: 10),
                "the search did not stay with the new list")
            XCTAssertFalse(ui.element(Self.documentRow(Self.carInsurance)).exists, "the chip was dropped")
            ui.attachWindowScreenshot("search-4-other-list", to: self)
        #endif
    }

    /// Picks a segment of the scope switch: the selected list or All Documents. On the Mac each segment has its
    /// identifier (`search.scope.*`); the iPhone's scope bar is a system segmented control (`scopeBar`) whose segments
    /// keep only their titles, so they are picked by position.
    @MainActor
    private func selectScope(all: Bool, in ui: UITestApp) {
        #if os(macOS)
            ui.activate(all ? "search.scope.all" : "search.scope.selection")
        #else
            let segment = ui.element("scopeBar").buttons.element(boundBy: all ? 1 : 0)
            XCTAssertTrue(segment.waitForExistence(timeout: 10), "no scope switch")
            segment.tap()
        #endif
    }

    /// Empties the field: select all and delete on the Mac; on the iPhone the one word is selected with a double tap.
    @MainActor
    private func clear(_ field: XCUIElement) {
        #if os(macOS)
            field.click()
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(.delete, modifierFlags: [])
        #else
            field.doubleTap()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        #endif
    }
}
