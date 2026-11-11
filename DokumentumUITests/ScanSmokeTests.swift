import XCTest

/// The scanner on an empty in-memory store (#5, part 2, plan test 14): `-UITestScanSynthetic YES` puts "Scan…"
/// into the "+" menu without a camera and hands the import two rendered pages instead. "+" → "Scan…" gives one
/// "Scan …" document in the Inbox, which opens. Part 3 (#112) extends this test with the photo cleanup, which
/// also runs on the Mac; until then the Mac skips it, because the Mac has no "Scan…".
final class ScanSmokeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testScanAndCleanupLandInInbox() throws {
        #if os(macOS)
            throw XCTSkip("The Mac has no “Scan…”; the cleanup half that runs on the Mac comes with #5, part 3 (#112).")
        #else
            let ui = UITestApp()
            ui.launch(.empty, extraArguments: ["-UITestScanSynthetic", "YES"])
            defer { ui.app.terminate() }

            ui.activate("import.menu")
            let scan = ui.element("import.scan")
            XCTAssertTrue(scan.waitForExistence(timeout: 10), "no “Scan…” item")
            ui.attachWindowScreenshot("scan-1-import-menu", to: self)
            scan.tap()

            // The new document opens (PQ1): its PDF, the first scanned page.
            XCTAssertTrue(ui.element("documentDetail.pdf").waitForExistence(timeout: 60), "the scan did not open")
            ui.attachWindowScreenshot("scan-2-page", to: self)
            let back = ui.app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 10), "no back button")
            back.tap()

            // One document in the Inbox, titled "Scan <date, time>" ("Scan" in English and German).
            let rows = ui.app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "documentList.row."))
            let row = rows.matching(NSPredicate(format: "label BEGINSWITH %@", "Scan ")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20), "no “Scan …” row in the Inbox")
            XCTAssertEqual(Set(rows.allElementsBoundByIndex.map(\.identifier)).count, 1, "not one document")
            XCTAssertTrue(ui.element("sidebar.inbox").exists || ui.app.navigationBars.firstMatch.exists)
            ui.attachWindowScreenshot("scan-3-inbox", to: self)
        #endif
    }
}
