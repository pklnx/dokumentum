import XCTest

/// The import on an empty in-memory store (plan of #4, part 2): `-UITestImportSynthetic` imports three
/// generated PDFs through the window's import controller, the third with the first one's bytes. The Inbox
/// lists two documents and the notice names the skipped duplicate. Then the "+" menu and its files picker,
/// for the evidence screenshots; the picker is cancelled.
final class ImportSmokeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testImportLandsInInboxAndSkipsADuplicate() {
        let ui = UITestApp()
        ui.launch(.empty, extraArguments: ["-UITestImportSynthetic", "YES"])
        defer { ui.app.terminate() }

        // The notice names the skipped file and the document that has its bytes (file names are not
        // translated, so this holds in every language).
        let notice = ui.app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Rechnung Kopie.pdf", "Rechnung Kopie.pdf")
        ).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 60), "no notice names the duplicate")
        let text = [notice.label, notice.value as? String ?? ""].joined(separator: " ")
        XCTAssertTrue(text.contains("Rechnung Stadtwerke"), "the notice does not name the existing document: \(text)")
        ui.attachWindowScreenshot("3-duplicate-notice", to: self)
        // The OK button by its identifier; an alert may not pass the identifier on, then its only button.
        let ok = ui.element("import.notice.ok")
        let button = ok.waitForExistence(timeout: 5) ? ok : ui.app.alerts.buttons.firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no OK button on the notice")
        #if os(macOS)
            button.click()
        #else
            button.tap()
        #endif
        XCTAssertTrue(
            notice.waitForNonExistence(timeout: 10), "the notice stayed after OK")

        // Two documents in the Inbox: the duplicate added none.
        let rows = ui.app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "documentList.row."))
        let twoRows = XCTNSPredicateExpectation(
            predicate: NSPredicate { query, _ in
                guard let query = query as? XCUIElementQuery else { return false }
                return Set(query.allElementsBoundByIndex.map(\.identifier)).count == 2
            }, object: rows)
        XCTAssertEqual(XCTWaiter.wait(for: [twoRows], timeout: 30), .completed, "the Inbox does not list two documents")
        XCTAssertEqual(Set(rows.allElementsBoundByIndex.map(\.identifier)).count, 2)
        ui.attachWindowScreenshot("4-result", to: self)

        // The "+" menu and the files picker it opens (evidence only; cancelled).
        ui.activate("import.menu")
        let files = ui.element("import.files")
        XCTAssertTrue(files.waitForExistence(timeout: 10), "no “Files…” item")
        ui.attachWindowScreenshot("1-import-menu", to: self)
        #if os(macOS)
            files.click()
            let panel = ui.app.sheets.firstMatch
            if panel.waitForExistence(timeout: 20) {
                ui.attachWindowScreenshot("2-open-panel", to: self)
                ui.app.typeKey(.escape, modifierFlags: [])
                XCTAssertTrue(panel.waitForNonExistence(timeout: 10), "the open panel stayed open")
            } else {
                XCTFail("no open panel")
            }
        #else
            files.tap()
            // The document picker runs in another process; the window screenshot shows what it can of it.
            let cancel = ui.app.buttons["Cancel"]
            _ = cancel.waitForExistence(timeout: 20)
            ui.attachWindowScreenshot("2-files-picker", to: self)
        #endif
    }
}
