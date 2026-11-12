import XCTest

/// The scanner and the photo cleanup on an empty in-memory store (#5, parts 2 and 3, plan tests 14 and 18).
/// `-UITestScanSynthetic YES` puts "Scan…" into the "+" menu without a camera and hands the import two rendered
/// pages instead: "+" → "Scan…" gives one "Scan …" document in the Inbox, which opens (iPhone only; the Mac has no
/// "Scan…"). `-UITestCleanupSynthetic YES` makes "Photos…" open the cleanup with two rendered photos instead of the
/// Photos picker: the sheet shows two pages with handles, page 1 is turned (its page becomes landscape), page 2 is
/// removed, and Save gives one "Photo …" document, which opens (both devices).
final class ScanSmokeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testScanAndCleanupLandInInbox() throws {
        let ui = UITestApp()
        ui.launch(.empty, extraArguments: ["-UITestScanSynthetic", "YES", "-UITestCleanupSynthetic", "YES"])
        defer { ui.app.terminate() }
        let rows = ui.app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "documentList.row."))

        #if os(iOS)
            ui.activate("import.menu")
            let scan = ui.element("import.scan")
            XCTAssertTrue(scan.waitForExistence(timeout: 10), "no “Scan…” item")
            ui.attachWindowScreenshot("scan-1-import-menu", to: self)
            scan.tap()

            // The new document opens (PQ1): its PDF, the first scanned page.
            XCTAssertTrue(ui.element("documentDetail.pdf").waitForExistence(timeout: 60), "the scan did not open")
            ui.attachWindowScreenshot("scan-2-page", to: self)
            goBack(ui)

            // One document in the Inbox, titled "Scan <date, time>" ("Scan" in English and German).
            let row = rows.matching(NSPredicate(format: "label BEGINSWITH %@", "Scan ")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20), "no “Scan …” row in the Inbox")
            XCTAssertEqual(Set(rows.allElementsBoundByIndex.map(\.identifier)).count, 1, "not one document")
            XCTAssertTrue(ui.element("documentList").exists, "the row is not in the document list")
            ui.attachWindowScreenshot("scan-3-inbox", to: self)
        #endif

        // The cleanup: two pages with handles.
        ui.activate("import.menu")
        let photos = ui.element("import.photos")
        XCTAssertTrue(photos.waitForExistence(timeout: 10), "no “Photos…” item")
        click(photos)
        let page = ui.element("cleanup.page")
        XCTAssertTrue(page.waitForExistence(timeout: 30), "the cleanup did not open")
        XCTAssertTrue(ui.element("cleanup.thumbnail.0").waitForExistence(timeout: 10), "no first page")
        XCTAssertTrue(ui.element("cleanup.thumbnail.1").exists, "no second page")
        XCTAssertFalse(ui.element("cleanup.thumbnail.2").exists, "more than two pages")
        for corner in ["topLeft", "topRight", "bottomRight", "bottomLeft"] {
            XCTAssertTrue(ui.element("cleanup.corner.\(corner)").exists, "no \(corner) handle")
        }
        XCTAssertGreaterThan(page.frame.height, page.frame.width, "page 1 is not portrait before the turn")
        ui.attachWindowScreenshot("cleanup-1-sheet", to: self)
        // The Filter menu's VoiceOver name, "Filter" in English and German (#136): the iPhone's menu button has it as
        // its label, the Mac's AppKit menu button as its title (its label stays empty there, so the audit lists it so).
        let filter = ui.element("cleanup.filter")
        #if os(macOS)
            XCTAssertEqual(filter.title, "Filter", "the Filter menu has no VoiceOver name")
        #else
            XCTAssertEqual(filter.label, "Filter", "the Filter menu has no VoiceOver name")
            // The toolbar's system buttons, whose "Contrast failed" the audit's accepted issues let pass (#136):
            // their measured text contrast is the check instead.
            ui.assertTextContrast("cleanup.cancel", in: self)
            ui.assertTextContrast("cleanup.save", in: self)
        #endif
        // The sheet's audit on both devices (review 5867292360, #136).
        ui.auditAccessibility("cleanup", in: self)

        // Page 1 turned a quarter: the page shows landscape. The page's frame comes from the app's accessibility
        // tree, which can lag behind the screen on a busy simulator (the turned page was on screen in a failed run
        // with a fixed 10 s, review 5867813357), so the wait is the suite's 30 s, scaled (#136).
        click(ui.element("cleanup.rotate"))
        let landscape = XCTNSPredicateExpectation(
            predicate: NSPredicate { element, _ in
                guard let element = element as? XCUIElement, element.exists else { return false }
                return element.frame.width > element.frame.height
            }, object: page)
        XCTAssertEqual(
            XCTWaiter.wait(for: [landscape], timeout: UITestApp.timeout(30)), .completed, "page 1 did not turn")
        ui.attachWindowScreenshot("cleanup-2-rotated", to: self)

        // Page 2 removed.
        click(ui.element("cleanup.thumbnail.1"))
        click(ui.element("cleanup.remove"))
        XCTAssertTrue(ui.element("cleanup.thumbnail.1").waitForNonExistence(timeout: 10), "page 2 was not removed")
        XCTAssertTrue(ui.element("cleanup.thumbnail.0").exists, "page 1 went too")
        ui.attachWindowScreenshot("cleanup-3-one-page", to: self)

        // Save: the sheet closes and the new document opens (PQ1), titled "Photo …" ("Foto …" in German).
        click(ui.element("cleanup.save"))
        XCTAssertTrue(page.waitForNonExistence(timeout: 20), "the cleanup stayed open")
        XCTAssertTrue(ui.element("documentDetail.pdf").waitForExistence(timeout: 60), "the photo did not open")
        ui.attachWindowScreenshot("cleanup-4-document", to: self)
        #if os(iOS)
            goBack(ui)
        #endif
        let photo = rows.matching(
            NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Photo ", "Foto ")
        ).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 20), "no “Photo …” row in the Inbox")
        #if os(iOS)
            let expected = 2
        #else
            let expected = 1
        #endif
        XCTAssertEqual(Set(rows.allElementsBoundByIndex.map(\.identifier)).count, expected, "not one new document")
        ui.attachWindowScreenshot("cleanup-5-inbox", to: self)
    }

    /// Taps on iOS, clicks on macOS.
    @MainActor
    private func click(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) did not appear", file: file, line: line)
        #if os(macOS)
            element.click()
        #else
            element.tap()
        #endif
    }

    #if os(iOS)
        @MainActor
        private func goBack(_ ui: UITestApp) {
            let back = ui.app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 10), "no back button")
            back.tap()
        }
    #endif
}
