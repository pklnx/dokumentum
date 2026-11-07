import XCTest

/// The library on the sample documents (`-UITestSeed`): the sidebar filters, the tag tree expands,
/// and the detail shows a PDF or why there is none. On the iPhone the split view is a navigation
/// stack, on the Mac three columns.
final class LibrarySmokeTests: XCTestCase {
    // The identifiers and fixed IDs of the app (`AccessibilityID`, `FixtureCatalog`); a UI test
    // cannot see the app's code.
    private static func documentRow(_ number: Int) -> String {
        "documentList.row." + String(format: "5EED0000-0000-4000-8000-%012d", number)
    }

    private static func tagRow(_ number: Int) -> String {
        "sidebar.tag." + String(format: "5EED0001-0000-4000-8000-%012d", number)
    }

    private static func tagDisclosure(_ number: Int) -> String {
        "sidebar.tagDisclosure." + String(format: "5EED0001-0000-4000-8000-%012d", number)
    }

    private static let tax = 1
    private static let auto = 3
    private static let golf = 4
    /// Electricity bill (Tax, Inbox, a PDF), Medical invoice (Tax, Inbox), Water bill (Tax, no file),
    /// Account statement (no tag), Car insurance (Auto, not in the Inbox).
    private static let electricityBill = 1
    private static let medicalInvoice = 2
    private static let waterBill = 3
    private static let accountStatement = 4
    private static let carInsurance = 7

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSidebarFiltersAndOpensAPDF() {
        let ui = UITestApp()
        ui.launch()
        defer { ui.app.terminate() }
        XCTAssertTrue(ui.element("documentList").waitForExistence(timeout: 60), "no document list after the launch")
        XCTAssertTrue(ui.element(Self.documentRow(Self.electricityBill)).waitForExistence(timeout: 10))
        // The app opens on the Inbox (PQ1).
        XCTAssertFalse(ui.element(Self.documentRow(Self.accountStatement)).exists, "the start list is not the Inbox")
        ui.attachWindowScreenshot("1-inbox", to: self)

        #if os(iOS)
            // The iPhone opens on the Inbox list; back to the sidebar.
            goBack(ui)
            XCTAssertTrue(ui.element("sidebar").waitForExistence(timeout: 10), "no sidebar after going back")
            ui.attachWindowScreenshot("2-sidebar", to: self)
        #endif

        // A chevron expands the tag's nested tags and does not select the tag.
        XCTAssertFalse(ui.element(Self.tagRow(Self.golf)).exists, "Golf is shown before Auto is expanded")
        ui.activate(Self.tagDisclosure(Self.auto))
        XCTAssertTrue(ui.element(Self.tagRow(Self.golf)).waitForExistence(timeout: 10), "Golf did not appear")
        #if os(iOS)
            XCTAssertTrue(ui.element("sidebar").exists, "the chevron left the sidebar")
            XCTAssertFalse(ui.element(Self.documentRow(Self.carInsurance)).exists, "the chevron selected Auto")
            XCTAssertFalse(ui.element("documentList").exists, "the chevron opened a list")
        #else
            XCTAssertTrue(ui.element(Self.documentRow(Self.electricityBill)).exists, "the chevron changed the list")
            XCTAssertFalse(ui.element(Self.documentRow(Self.carInsurance)).exists, "the chevron selected Auto")
        #endif
        ui.attachWindowScreenshot("3-tags-expanded", to: self)

        // Tax lists only its documents.
        ui.activate(Self.tagRow(Self.tax))
        XCTAssertTrue(ui.element(Self.documentRow(Self.waterBill)).waitForExistence(timeout: 10), "Tax not shown")
        XCTAssertTrue(ui.element(Self.documentRow(Self.electricityBill)).exists)
        XCTAssertTrue(ui.element(Self.documentRow(Self.medicalInvoice)).exists)
        XCTAssertFalse(ui.element(Self.documentRow(Self.accountStatement)).exists, "a document without Tax")
        XCTAssertFalse(ui.element(Self.documentRow(Self.carInsurance)).exists, "a document without Tax")
        ui.attachWindowScreenshot("4-tag-tax", to: self)

        // A document with a file shows its PDF.
        ui.activate(Self.documentRow(Self.electricityBill))
        XCTAssertTrue(ui.element("documentDetail.pdf").waitForExistence(timeout: 20), "the PDF did not appear")
        ui.attachWindowScreenshot("5-pdf", to: self)

        #if os(iOS)
            goBack(ui)
        #endif

        // A document without a file says it is still downloading.
        ui.activate(Self.documentRow(Self.waterBill))
        XCTAssertTrue(
            ui.element("documentDetail.stillDownloading").waitForExistence(timeout: 20), "no “Still downloading”")
        XCTAssertFalse(ui.element("documentDetail.pdf").exists)
        ui.attachWindowScreenshot("6-still-downloading", to: self)
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
