import XCTest

/// The Mac's selected rows keep their text readable (#9, P4; plan of #9, part 2b). The system derives the document
/// list's selection colour from the accent and draws white text on it, so the contrast is measured from the rows' own
/// screenshots, never the screen's. With the brand's tint as the Mac accent, white on the list's selection reached only
/// 3.76:1 in dark (#9671d1, measured on #184), so the Mac keeps the user's system accent (P4's fallback,
/// `Config/Project.xcconfig`). The sidebar's selection is grey on macOS 27, whatever the accent. Run it in both
/// appearances (`TEST_RUNNER_DOKUMENTUM_UI_APPEARANCE=light|dark` in the environment of `xcodebuild`).
final class SelectionContrastSmokeTests: XCTestCase {
    // The identifiers and fixed IDs of the app (`AccessibilityID`, `FixtureCatalog`); sample data only.
    private static func documentRow(_ number: Int) -> String {
        "documentList.row." + String(format: "5EED0000-0000-4000-8000-%012d", number)
    }

    /// Account statement: not in the Inbox, so only All Documents lists it.
    private static let accountStatement = 4

    override func setUp() {
        continueAfterFailure = false
    }

    #if os(macOS)
        @MainActor
        func testSelectedRowsKeepTheirTextReadable() {
            let ui = UITestApp()
            ui.launch()
            defer { ui.app.terminate() }
            XCTAssertTrue(
                ui.element("documentList").waitForExistence(timeout: 60), "no document list after the launch")

            // A click in the sidebar selects All Documents and leaves the sidebar focused: its selection is the
            // emphasized one.
            ui.activate("sidebar.all")
            XCTAssertTrue(
                ui.element(Self.documentRow(Self.accountStatement)).waitForExistence(timeout: 10),
                "All Documents was not selected")
            measureSelection("sidebar.all", screenshotOf: "sidebar", ui: ui)

            // A click on a row moves the focus to the list: now its selection is the emphasized one.
            ui.activate(Self.documentRow(Self.accountStatement))
            XCTAssertTrue(ui.element("documentDetail.pdf").waitForExistence(timeout: 20), "the PDF did not appear")
            measureSelection(Self.documentRow(Self.accountStatement), screenshotOf: "documentList", ui: ui)
        }

        /// Attaches the column's screenshot and asserts the selected row's text contrast (white on the list's
        /// selection reaches 3.76:1 in dark with the brand's tint as the Mac accent, measured on #184).
        @MainActor
        private func measureSelection(_ identifier: String, screenshotOf column: String, ui: UITestApp) {
            let attachment = XCTAttachment(screenshot: ui.element(column).screenshot())
            attachment.name = UITestApp.attachmentName("selection-" + column)
            attachment.lifetime = .keepAlways
            add(attachment)
            ui.assertTextContrast(identifier, in: self)
        }
    #endif
}
