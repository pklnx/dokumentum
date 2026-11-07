import XCTest

/// The import on an empty in-memory store (plan of #4, parts 2 and 3): `-UITestImportSynthetic` imports two
/// generated PDFs, a generated portrait photo and the first PDF's bytes again through the window's import
/// controller. The Inbox lists three documents, the notice names the skipped duplicate, and the photo opens
/// as a PDF page. Then the "+" menu with "Files…" and "Photos…", and on the Mac its open panel (cancelled),
/// on the iPhone the Photos picker, for the evidence screenshots.
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

        // Three documents in the Inbox: the duplicate added none.
        let rows = ui.app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "documentList.row."))
        let threeRows = XCTNSPredicateExpectation(
            predicate: NSPredicate { query, _ in
                guard let query = query as? XCUIElementQuery else { return false }
                return Set(query.allElementsBoundByIndex.map(\.identifier)).count == 3
            }, object: rows)
        XCTAssertEqual(
            XCTWaiter.wait(for: [threeRows], timeout: 30), .completed, "the Inbox does not list three documents")
        XCTAssertEqual(Set(rows.allElementsBoundByIndex.map(\.identifier)).count, 3)
        ui.attachWindowScreenshot("4-result", to: self)

        // The photo (part 3): its PDF page, upright and portrait (the evidence screenshot shows it).
        let photo = rows.matching(NSPredicate(format: "label CONTAINS %@", "Kassenbon Bäckerei")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10), "no row for the imported photo")
        #if os(macOS)
            photo.click()
        #else
            photo.tap()
        #endif
        XCTAssertTrue(ui.element("documentDetail.pdf").waitForExistence(timeout: 20), "the photo's PDF did not appear")
        ui.attachWindowScreenshot("5-photo-page", to: self)
        #if os(iOS)
            let back = ui.app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 10), "no back button")
            back.tap()
        #endif

        // The "+" menu with "Files…" and "Photos…".
        ui.activate("import.menu")
        let files = ui.element("import.files")
        XCTAssertTrue(files.waitForExistence(timeout: 10), "no “Files…” item")
        let photos = ui.element("import.photos")
        XCTAssertTrue(photos.waitForExistence(timeout: 10), "no “Photos…” item")
        ui.attachWindowScreenshot("1-import-menu", to: self)
        #if os(macOS)
            // The open panel opens and closes again. No screenshot of it, nor is the Photos picker opened: both
            // show the Mac's own files and photo library (maintainer decision on #4, 2026-11-07).
            files.click()
            let panel = ui.app.sheets.firstMatch
            XCTAssertTrue(panel.waitForExistence(timeout: 20), "no open panel")
            ui.app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(panel.waitForNonExistence(timeout: 10), "the open panel stayed open")
        #else
            // The Photos picker runs in another process, but its elements are in the app's tree. On the simulator it
            // shows the simulator's sample photos. Two of them, picked in reverse order, become one document that
            // opens (PQ1, PQ5).
            photos.tap()
            let samplePhotos = ui.app.images.matching(identifier: "PXGGridLayout-Info")
            XCTAssertTrue(samplePhotos.firstMatch.waitForExistence(timeout: 60), "the Photos picker shows no photos")
            ui.attachWindowScreenshot("2-photos-picker", to: self)
            samplePhotos.element(boundBy: 1).tap()
            samplePhotos.element(boundBy: 0).tap()
            ui.attachWindowScreenshot("6-photos-picked", to: self)
            let add = ui.app.buttons.matching(
                NSPredicate(format: "label IN %@", ["Done", "Add", "Fertig", "Hinzufügen"])
            ).firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 10), "no Done button in the Photos picker")
            add.tap()
            XCTAssertTrue(
                ui.element("documentDetail.pdf").waitForExistence(timeout: 60), "the photos did not open as a document")
            ui.attachWindowScreenshot("7-photos-document", to: self)
        #endif
    }
}
