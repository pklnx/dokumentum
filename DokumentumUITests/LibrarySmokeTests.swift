import XCTest

/// The library on the sample documents (`-UITestSeed`): the sidebar filters, the tag tree expands,
/// and the detail shows a PDF or why there is none. Rows show their first page's thumbnail, and the detail of a
/// document whose text recognition failed says so and offers "Try again" (#6, part 4). The sidebar footer's sync line
/// opens "iCloud Sync" (#31, with an injected status). On the iPhone the split view is a navigation stack, on the Mac
/// three columns.
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
    /// Scanned receipt (Inbox, a file that is not a PDF, so no thumbnail; its text recognition failed).
    private static let scannedReceipt = 9
    /// The annual statement with the long title (Inbox, a PDF whose text recognition failed).
    private static let annualStatement = 6

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
        #if os(macOS)
            assertMacListElements(ui)
        #endif
        assertRowsShowThumbnails(ui)

        #if os(iOS)
            // The iPhone opens on the Inbox list; back to the sidebar.
            goBack(ui)
            XCTAssertTrue(ui.element("sidebar").waitForExistence(timeout: 10), "no sidebar after going back")
            ui.attachWindowScreenshot("2-sidebar", to: self)
        #endif
        // Every sidebar row tells VoiceOver its count (#47, from the reviews of #53), and the app's own elements
        // pass the system's accessibility audit (plan of #3, part 5).
        assertEverySidebarRowHasACount(ui)
        ui.auditAccessibility("sidebar", in: self)

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
        ui.auditAccessibility("pdf", in: self)

        #if os(iOS)
            goBack(ui)
        #endif

        // A document without a file says it is still downloading.
        ui.activate(Self.documentRow(Self.waterBill))
        XCTAssertTrue(
            ui.element("documentDetail.stillDownloading").waitForExistence(timeout: 20), "no “Still downloading”")
        XCTAssertFalse(ui.element("documentDetail.pdf").exists)
        ui.attachWindowScreenshot("6-still-downloading", to: self)
        #if os(macOS)
            // The placeholder's title and description are primary and reach 4.5:1 (#82 P1, #89), measured from
            // their own pixels: the audit fails regular-weight text in light whatever its colour (plan of #89).
            ui.assertTextContrast("documentDetail.stillDownloading", in: self)
            ui.assertTextContrast("documentDetail.stillDownloading.description", in: self)

            // A file that is not a PDF says it cannot be shown (#89). The Inbox does not list the water bill, so
            // the selection clears first.
            ui.activate("sidebar.inbox")
            ui.activate(Self.documentRow(Self.scannedReceipt))
            XCTAssertTrue(
                ui.element("documentDetail.unreadable").waitForExistence(timeout: 20), "no “This PDF cannot be shown”")
            XCTAssertFalse(ui.element("documentDetail.pdf").exists)
            ui.attachWindowScreenshot("7-unreadable", to: self)
            ui.assertTextContrast("documentDetail.unreadable", in: self)
            ui.assertTextContrast("documentDetail.unreadable.description", in: self)
        #else
            // The annual statement is in the Inbox: back to the sidebar first.
            goBack(ui)
            goBack(ui)
            ui.activate("sidebar.inbox")
        #endif
        ui.activate(Self.documentRow(Self.annualStatement))
        XCTAssertTrue(ui.element("documentDetail.pdf").waitForExistence(timeout: 20), "the PDF did not appear")
        assertFailedProcessingCanBeTriedAgain(ui)
        ui.app.terminate()

        // The sync status line of a CloudKit store, injected (`-UITestSyncStatus`, #31 T7): a problem and "on".
        assertSyncStatusFooter(status: "storageFull", showsCode: true)
        assertSyncStatusFooter(status: "on", showsCode: false)
    }

    /// With `-UITestSyncStatus <status>` the sidebar footer shows the CloudKit store's line (`sidebar.syncStatus`, not
    /// the in-memory store's "Sync off"), primary text on the bar that reaches 4.5:1 on the Mac (light and dark through
    /// `TEST_RUNNER_DOKUMENTUM_UI_APPEARANCE`), and activating it opens "iCloud Sync" (a popover on the Mac, a sheet on
    /// the iPhone) with the line and, for a problem, its CloudKit code.
    @MainActor
    private func assertSyncStatusFooter(
        status: String, showsCode: Bool, file: StaticString = #filePath, line: UInt = #line
    ) {
        let ui = UITestApp()
        ui.launch(extraArguments: ["-UITestSyncStatus", status])
        defer { ui.app.terminate() }
        XCTAssertTrue(
            ui.element("documentList").waitForExistence(timeout: 60), "no document list after the launch", file: file,
            line: line)
        #if os(iOS)
            goBack(ui)
        #endif
        let footer = ui.element("sidebar.syncStatus")
        XCTAssertTrue(footer.waitForExistence(timeout: 20), "no sync status line", file: file, line: line)
        XCTAssertFalse(
            ui.element("sidebar.syncOff").exists, "the store's line instead of the status", file: file, line: line)
        ui.attachWindowScreenshot("10-sync-status-\(status)", to: self)
        #if os(macOS)
            ui.assertTextContrast("sidebar.syncStatus", in: self, file: file, line: line)
        #endif
        ui.activate("sidebar.syncStatus", file: file, line: line)
        XCTAssertTrue(
            ui.element("syncStatus.detail.line").waitForExistence(timeout: 20), "“iCloud Sync” did not open",
            file: file,
            line: line)
        XCTAssertEqual(
            ui.element("syncStatus.detail.code").exists, showsCode, "the CloudKit code", file: file, line: line)
        if showsCode {
            // A static text reads its text as the label on the iPhone and as the value on the Mac.
            let code = ui.element("syncStatus.detail.code")
            XCTAssertTrue(
                [code.label, code.value as? String ?? ""].contains("CKError 25"), "the code: \(code.label)", file: file,
                line: line)
        }
        ui.attachWindowScreenshot("11-sync-detail-\(status)", to: self)
        #if os(iOS)
            ui.activate("syncStatus.detail.done", file: file, line: line)
        #else
            ui.app.typeKey(.escape, modifierFlags: [])
        #endif
        XCTAssertTrue(
            footer.waitForExistence(timeout: 10), "the sidebar did not come back", file: file, line: line)
    }

    /// The annual statement is open: above its PDF the detail says that text recognition failed, with "Try again"
    /// (#6, P2), and passes the audit (over the PDF: the placeholders' descriptions are a known false positive in light,
    /// see `assertTextContrast`); "Try again" sets it back to pending (the UI test's in-memory store runs no queue, so
    /// it stays there), and the button goes. On the Mac the line's text reaches 4.5:1 in light and dark, measured from
    /// its own pixels.
    @MainActor
    private func assertFailedProcessingCanBeTriedAgain(
        _ ui: UITestApp, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(
            ui.element("documentDetail.processing.failed").waitForExistence(timeout: 20),
            "no “Text recognition failed”", file: file, line: line)
        XCTAssertTrue(ui.element("documentDetail.processing.retry").exists, "no “Try again”", file: file, line: line)
        ui.attachWindowScreenshot("8-processing-failed", to: self)
        #if os(macOS)
            ui.assertTextContrast("documentDetail.processing.failed", in: self, file: file, line: line)
        #endif
        ui.auditAccessibility("processing-failed", in: self, file: file, line: line)

        ui.activate("documentDetail.processing.retry", file: file, line: line)
        XCTAssertTrue(
            ui.element("documentDetail.processing.pending").waitForExistence(timeout: 20),
            "“Try again” did not set the document back to pending", file: file, line: line)
        XCTAssertFalse(ui.element("documentDetail.processing.failed").exists, file: file, line: line)
        XCTAssertFalse(ui.element("documentDetail.processing.retry").exists, file: file, line: line)
        ui.attachWindowScreenshot("9-processing-pending", to: self)
    }

    /// The Inbox's rows show their first page's thumbnail at the leading edge (#6, P1); the Scanned receipt has none
    /// (its file is not a PDF) and shows the placeholder. The thumbnail is hidden from VoiceOver, so it is compared
    /// in the rows' own pixels: the leading 72 × 60 pt of a row with a thumbnail differ from a row with the placeholder
    /// in at least a quarter of the thumbnail's area (a white page on the grey placeholder, in light and dark). With
    /// both showing the placeholder they are the same.
    @MainActor
    private func assertRowsShowThumbnails(_ ui: UITestApp, file: StaticString = #filePath, line: UInt = #line) {
        let withThumbnail = ui.element(Self.documentRow(Self.electricityBill))
        let placeholder = ui.element(Self.documentRow(Self.scannedReceipt))
        XCTAssertTrue(placeholder.waitForExistence(timeout: 10), "no Scanned receipt row", file: file, line: line)
        // The thumbnail is loaded off the main actor after the row appears: its pixels are the signal.
        var differing = 0
        var minimum = 0
        let deadline = Date().addingTimeInterval(20)
        repeat {
            guard
                let measured = UITestApp.leadingBandDifference(
                    withThumbnail.screenshot(), placeholder.screenshot(), width: 72, height: 60,
                    pointWidths: (withThumbnail.frame.width, placeholder.frame.width))
            else {
                XCTFail("the rows' screenshots could not be measured", file: file, line: line)
                return
            }
            (differing, minimum) = (measured.differing, measured.thumbnailArea / 4)
        } while differing < minimum && Date() < deadline
        let summary = "THUMBNAIL rows 1 vs 9: \(differing) px differ, \(minimum) needed"
        print(summary)
        let attachment = XCTAttachment(string: summary)
        attachment.name = UITestApp.attachmentName("thumbnail-rows")
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThanOrEqual(differing, minimum, "the row shows no thumbnail", file: file, line: line)
    }

    /// Every sidebar row (Library, tags, correspondents, types, Trash) has a VoiceOver value that starts with
    /// its count ("3 documents", "1 Dokument"). On the iPhone the list creates its lower rows only once they are
    /// scrolled into view, so it scrolls down to Trash (bounded) and back.
    @MainActor
    private func assertEverySidebarRowHasACount(_ ui: UITestApp, file: StaticString = #filePath, line: UInt = #line) {
        var values: [String: String] = [:]
        func collect() {
            guard let snapshot = try? ui.element("sidebar").snapshot() else { return }
            var pending = [snapshot]
            while let element = pending.popLast() {
                pending += element.children
                let identifier = element.identifier
                guard identifier.hasPrefix("sidebar."), !identifier.hasPrefix("sidebar.tagDisclosure."),
                    identifier != "sidebar.syncOff"
                else { continue }
                // An identifier can match more than one element on iOS; one of them carries the value.
                if let value = element.value as? String, value.first?.isNumber == true {
                    values[identifier] = value
                } else if values[identifier] == nil {
                    values[identifier] = ""
                }
            }
        }
        collect()
        #if os(iOS)
            for _ in 0..<5 where values["sidebar.trash"] == nil {
                ui.element("sidebar").swipeUp(velocity: .slow)
                collect()
            }
        #endif
        for prefix in [
            "sidebar.inbox", "sidebar.all", "sidebar.tag.", "sidebar.correspondent.", "sidebar.documentType.",
            "sidebar.trash",
        ] {
            XCTAssertTrue(
                values.keys.contains { $0.hasPrefix(prefix) }, "no sidebar row \(prefix)", file: file, line: line)
        }
        for (identifier, value) in values.sorted(by: { $0.key < $1.key }) {
            XCTAssertFalse(value.isEmpty, "\(identifier) has no count for VoiceOver", file: file, line: line)
        }
        #if os(iOS)
            // Back up to the tags, which the test uses next.
            let auto = ui.element(Self.tagDisclosure(Self.auto))
            for _ in 0..<5 where !(auto.exists && auto.isHittable) {
                ui.element("sidebar").swipeDown(velocity: .slow)
            }
        #endif
    }

    #if os(macOS)
        /// What the Mac audit checks, asserted without it, because the audit is not fully stable (review of #74,
        /// 5849597239; plan of #82): the list has a name, a document row is a button that reads its sentence, and
        /// "No document selected" is the title alone, without its symbol.
        @MainActor
        private func assertMacListElements(_ ui: UITestApp, file: StaticString = #filePath, line: UInt = #line) {
            let list = ui.element("documentList")
            XCTAssertFalse(list.label.isEmpty, "the document list has no label", file: file, line: line)

            let row = ui.element(Self.documentRow(Self.electricityBill))
            XCTAssertEqual(row.elementType, .button, "a document row is no button", file: file, line: line)
            XCTAssertTrue(
                row.label.hasPrefix("Electricity bill October, ") && row.label.contains("Stadtwerke Musterstadt"),
                "a document row does not read its sentence: \(row.label)", file: file, line: line)

            let noSelection = ui.element("documentDetail.noSelection")
            XCTAssertTrue(
                noSelection.waitForExistence(timeout: 10), "no “No document selected”", file: file, line: line)
            // The title is one line of text; with the symbol the element was 89 pt high.
            XCTAssertLessThan(
                noSelection.frame.height, 40, "“No document selected” is more than its title: \(noSelection.frame)",
                file: file, line: line)
        }
    #endif

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
