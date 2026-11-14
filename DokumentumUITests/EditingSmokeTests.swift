import XCTest

/// Editing in the info panel (plan of #3, part 3) on the sample documents (`-UITestSeed`): the title and the
/// correspondent change, and the list shows the new values after leaving the Inbox and coming back. On the Mac
/// the delete key in the title field only edits the text (a regression of the predecessor,
/// `MacSmokeTests.testDeleteKeyInTheTitleFieldOnlyEditsText`). Then a matching rule is edited from the sidebar and
/// applied from the settings (#10, part 2; plan review N9: in this test, not a suite of its own). The electricity bill's
/// due date is suggested from its text, added, and marked done (#12, part 2b). A second launch shows the line under the
/// title field when its save fails (part 5); these stay in this test, so the smoke suite keeps its count (plan §4).
final class EditingSmokeTests: XCTestCase {
    // The identifiers and fixed IDs of the app (`AccessibilityID`, `FixtureCatalog`); a UI test cannot see the
    // app's code. The titles and names are sample data, the same in every language.
    private static let electricityBill = "documentList.row.5EED0000-0000-4000-8000-000000000001"
    private static let newTitle = "Electricity bill edited"
    private static let newCorrespondent = "Musterbank AG"
    /// Musterbank AG's sidebar row (`FixtureCatalog.musterbank`).
    private static let musterbankRow = "sidebar.correspondent.5EED0002-0000-4000-8000-000000000002"
    /// Typed into the pattern field as a regular expression: not valid, and the field must keep it as typed (N8).
    /// `typeText` bypasses smart punctuation on both platforms (re-review N5, measured on #200: with the field's
    /// settings removed this test still passes), so `MatchingPatternFieldTests` pins the settings themselves.
    private static let invalidPattern = "(\"--"
    /// The rule: "Golf inspection", the one sample without a correspondent, has "Autohaus" in its text.
    private static let rulePattern = "Autohaus"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testEditingAndMatchingRules() {
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

        checkDeadlineSuggestion(ui)
        checkMatchingRules(ui)
        checkATitleThatCannotBeSavedSaysSo(ui)
    }

    /// The matching rules (#10, part 2; plan of #10, Tests 2): "Edit Matching…" on Musterbank AG; a regular expression
    /// that is not valid shows the line under the field and disables Save, and the field keeps what was typed (N8: no
    /// smart quotes or dashes); "Any word" with "Autohaus" is saved and there when the sheet opens again; "Apply
    /// Matching Rules to All Documents…" in the settings, confirmed, changes one document, and Musterbank AG's count
    /// is one higher. Counts are relative to the value read first. The sheet and the settings with the result pass the
    /// accessibility audit.
    @MainActor
    private func checkMatchingRules(_ ui: UITestApp) {
        #if os(iOS)
            goBack(ui)
            XCTAssertTrue(ui.element("sidebar").waitForExistence(timeout: 10), "no sidebar after going back")
        #else
            // The info panel closed: the audit of the sheet covers the window behind it, and the panel's correspondent
            // picker is reported there ("Action is missing", measured on this test's first run), as no other audit
            // sees it open.
            if ui.element("documentInfo.title").exists {
                ui.activate("documentDetail.showInfo")
                XCTAssertTrue(
                    ui.element("documentInfo.title").waitForNonExistence(timeout: 10), "the info panel stayed open")
            }
        #endif
        ui.revealSidebarRow(Self.musterbankRow, missingTowards: .bottom)
        let before = documentCount(Self.musterbankRow, ui)
        XCTAssertNotNil(before, "no count on Musterbank AG's row")

        // A regular expression that is not valid: the line, Save disabled, the field as typed.
        openRuleSheet(ui)
        chooseMode("regex", ui)
        let pattern = ui.element("matching.pattern")
        XCTAssertTrue(pattern.waitForExistence(timeout: 10), "no pattern field")
        focus(pattern)
        pattern.typeText(Self.invalidPattern)
        let error = ui.element("matching.error")
        XCTAssertTrue(error.waitForExistence(timeout: 10), "no line under the field for an invalid expression")
        XCTAssertFalse(ui.element("matching.save").isEnabled, "Save is enabled with an invalid expression")
        XCTAssertEqual(pattern.value as? String, Self.invalidPattern, "the field changed what was typed")
        ui.attachWindowScreenshot("5-matching-invalid", to: self)
        #if os(iOS)
            // The system toolbar button in its glass capsule: accepted in the audit, so measured here (#136).
            ui.assertTextContrast("matching.cancel", in: self)
        #endif
        ui.auditAccessibility("matching-sheet", in: self)

        // Any word, "Autohaus": saved.
        chooseMode("any", ui)
        replaceText(of: pattern, with: Self.rulePattern)
        XCTAssertTrue(error.waitForNonExistence(timeout: 10), "the line stayed for a valid rule")
        let save = ui.element("matching.save")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed, "Save stayed disabled")
        ui.attachWindowScreenshot("6-matching-rule", to: self)
        #if os(iOS)
            ui.assertTextContrast("matching.save", in: self)
        #endif
        ui.activate("matching.save")
        XCTAssertTrue(pattern.waitForNonExistence(timeout: 10), "the sheet stayed open after Save")

        // Opened again: the rule is there.
        openRuleSheet(ui)
        let reopened = ui.element("matching.pattern")
        XCTAssertTrue(reopened.waitForExistence(timeout: 10), "no pattern field")
        XCTAssertEqual(reopened.value as? String, Self.rulePattern, "the pattern was not saved")
        XCTAssertTrue(reopened.isEnabled, "the mode was not saved: the field is disabled for no rule")
        ui.activate("matching.cancel")
        XCTAssertTrue(reopened.waitForNonExistence(timeout: 10), "the sheet stayed open after Cancel")

        // Applied to all documents from the settings.
        openSettings(ui)
        let apply = ui.element("settings.matching.apply")
        XCTAssertTrue(apply.waitForExistence(timeout: 10), "no Apply in the settings")
        #if os(iOS)
            // Scrolled only when it is out of view (a large text size): a scrolled form cuts the texts at its top,
            // which the audit reports as clipped.
            for _ in 0..<4 where !apply.isHittable {
                ui.element("settings").swipeUp(velocity: .slow)
            }
        #endif
        ui.activate("settings.matching.apply")
        ui.activate("settings.matching.confirm")
        let result = ui.element("settings.matching.result")
        XCTAssertTrue(result.waitForExistence(timeout: 60), "no result after applying the rules")
        let resultText = (result.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? result.label
        XCTAssertTrue(resultText.hasPrefix("1 "), "the result is not one document changed: \(resultText)")
        attachSettingsScreenshot("7-matching-applied", ui)
        ui.auditAccessibility("matching-settings", in: self)
        #if os(iOS)
            ui.activate("settings.done")
            XCTAssertTrue(ui.element("sidebar").waitForExistence(timeout: 10), "the settings stayed open")
        #else
            ui.app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(result.waitForNonExistence(timeout: 10), "the Settings window stayed open")
        #endif

        if let before {
            ui.revealSidebarRow(Self.musterbankRow, missingTowards: .bottom)
            let row = ui.element(Self.musterbankRow)
            let counted = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value BEGINSWITH %@", "\(before + 1) "), object: row)
            XCTAssertEqual(
                XCTWaiter.wait(for: [counted], timeout: 20), .completed,
                "Musterbank AG's count is not \(before + 1): \(String(describing: row.value))")
        }
        ui.attachWindowScreenshot("8-matching-count", to: self)
    }

    /// The due-date suggestion (#12, part 2b; plan Tests 2b): the electricity bill's text says "Zahlbar bis" 14 days after
    /// the run's `-UITestToday`, and the detail's bar offers that day (its identifier names the day, so no localized text
    /// is read) with "Add Deadline" and "Dismiss". The bar passes the audit over the PDF. "Add Deadline" turns it into
    /// the deadline (the bar then shows it, due in 14 days); the bill is in Deadlines, and "Mark as Done" takes it out.
    /// Ends in the Inbox (on the Mac with the bill open), as the steps after it expect.
    @MainActor
    private func checkDeadlineSuggestion(_ ui: UITestApp) {
        #if os(macOS)
            // The info panel closed first: the audit covers the whole window, and the panel's correspondent picker is
            // reported there ("Action is missing", as in `checkMatchingRules`).
            if ui.element("documentInfo.title").exists {
                ui.activate("documentDetail.showInfo")
                XCTAssertTrue(
                    ui.element("documentInfo.title").waitForNonExistence(timeout: 10), "the info panel stayed open")
            }
        #endif
        ui.activate(Self.electricityBill)
        XCTAssertTrue(ui.element("documentDetail.pdf").waitForExistence(timeout: 20), "the PDF did not appear")
        let day = UITestApp.day(daysAfterToday: 14)
        let suggestion = ui.element("documentDetail.deadlineSuggestion.\(day)")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 20), "no suggestion for \(day)")
        XCTAssertTrue(ui.element("documentDetail.deadlineSuggestion.dismiss").exists, "no “Dismiss”")
        XCTAssertFalse(ui.element("documentDetail.deadline.upcoming").exists, "a deadline before it was added")
        ui.attachWindowScreenshot("9-deadline-suggestion", to: self)
        #if os(macOS)
            ui.assertTextContrast("documentDetail.deadlineSuggestion.\(day)", in: self)
        #endif
        ui.auditAccessibility("deadline-suggestion", in: self)

        ui.activate("documentDetail.deadlineSuggestion.add")
        XCTAssertTrue(
            ui.element("documentDetail.deadline.upcoming").waitForExistence(timeout: 20),
            "the deadline bar did not appear")
        XCTAssertTrue(suggestion.waitForNonExistence(timeout: 10), "the suggestion stayed after Add")
        ui.attachWindowScreenshot("10-deadline-added", to: self)

        // In Deadlines; "Mark as Done" takes it out.
        #if os(iOS)
            goBack(ui)
            goBack(ui)
            XCTAssertTrue(ui.element("sidebar").waitForExistence(timeout: 10), "no sidebar after going back")
        #endif
        ui.revealSidebarRow("sidebar.deadlines")
        ui.activate("sidebar.deadlines")
        let row = ui.element(Self.electricityBill)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the added deadline is not in Deadlines")
        ui.activate(Self.electricityBill)
        ui.activate("documentDetail.deadline.markDone")
        XCTAssertTrue(row.waitForNonExistence(timeout: 20), "the done deadline stayed in Deadlines")
        #if os(iOS)
            // The detail closes with the selection; back from the list (once more if it stayed).
            for _ in 0..<2 where !ui.element("sidebar").exists {
                goBack(ui)
                _ = ui.element("sidebar").waitForExistence(timeout: 5)
            }
            XCTAssertTrue(ui.element("sidebar").waitForExistence(timeout: 10), "no sidebar after going back")
        #endif
        ui.revealSidebarRow("sidebar.inbox")
        ui.activate("sidebar.inbox")
        XCTAssertTrue(ui.element(Self.electricityBill).waitForExistence(timeout: 10), "the bill left the Inbox")
        #if os(macOS)
            // Open again, as before this step: the matching sheet's audit covers the window behind it, and "No document
            // selected" there is a known false positive of the audit in light (#89).
            ui.activate(Self.electricityBill)
            XCTAssertTrue(ui.element("documentDetail.pdf").waitForExistence(timeout: 20), "the PDF did not appear")
        #endif
    }

    /// The number a sidebar row's VoiceOver value starts with ("5 documents", "5 Dokumente").
    @MainActor
    private func documentCount(_ identifier: String, _ ui: UITestApp) -> Int? {
        let row = ui.element(identifier)
        guard row.waitForExistence(timeout: 10), let value = row.value as? String else { return nil }
        return Int(value.prefix { $0.isNumber })
    }

    /// "Edit Matching…" from Musterbank AG's context menu: a right click on the Mac, a long press on the iPhone.
    @MainActor
    private func openRuleSheet(_ ui: UITestApp) {
        ui.revealSidebarRow(Self.musterbankRow, missingTowards: .bottom)
        let row = ui.element(Self.musterbankRow)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no Musterbank AG row")
        #if os(macOS)
            row.rightClick()
        #else
            row.press(forDuration: 1.2)
        #endif
        ui.activate("matching.edit")
        XCTAssertTrue(ui.element("matching.mode").waitForExistence(timeout: 10), "the rule sheet did not open")
    }

    /// Picks a mode in the sheet's picker by the option's identifier (`matching.mode.<mode>`): on the Mac a radio
    /// button, on the iPhone an item of the picker's menu.
    @MainActor
    private func chooseMode(_ mode: String, _ ui: UITestApp) {
        #if os(iOS)
            ui.activate("matching.mode")
        #endif
        let option = ui.element("matching.mode.\(mode)")
        guard option.waitForExistence(timeout: 10) else {
            let tree = XCTAttachment(string: ui.app.debugDescription)
            tree.name = "tree-no-mode-\(mode)"
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("no option matching.mode.\(mode)")
            return
        }
        #if os(macOS)
            option.click()
        #else
            option.tap()
        #endif
    }

    @MainActor
    private func focus(_ field: XCUIElement) {
        #if os(macOS)
            field.click()
        #else
            field.tap()
        #endif
    }

    /// Replaces a text field's whole text.
    @MainActor
    private func replaceText(of field: XCUIElement, with text: String) {
        focus(field)
        #if os(macOS)
            field.typeKey("a", modifierFlags: .command)
            field.typeText(text)
        #else
            let length = (field.value as? String)?.count ?? 0
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length + 5) + text)
        #endif
    }

    /// The settings: the iPhone's sheet from the sidebar's toolbar, the Mac's Settings window (⌘,). On the Mac a
    /// document is opened first: the audit covers the library window behind the Settings window too, and its "No
    /// document selected" is a known false positive in light (#89).
    @MainActor
    private func openSettings(_ ui: UITestApp) {
        #if os(iOS)
            ui.activate("settings.open")
        #else
            ui.activate(Self.electricityBill)
            XCTAssertTrue(ui.element("documentDetail.pdf").waitForExistence(timeout: 20), "the PDF did not appear")
            ui.app.typeKey(",", modifierFlags: .command)
        #endif
        XCTAssertTrue(ui.element("settings").waitForExistence(timeout: 20), "the settings did not open")
    }

    /// The settings' own pixels: on the Mac the Settings window is not the library's, so the view's screenshot.
    @MainActor
    private func attachSettingsScreenshot(_ name: String, _ ui: UITestApp) {
        #if os(macOS)
            let attachment = XCTAttachment(screenshot: ui.element("settings").screenshot())
            attachment.name = UITestApp.attachmentName(name)
            attachment.lifetime = .keepAlways
            add(attachment)
        #else
            ui.attachWindowScreenshot(name, to: self)
        #endif
    }

    /// A title whose save fails (`-UITestFailingSaves YES`: every save of the editor fails and is rolled back) says
    /// so under the field, the field shows the stored title again, and typing ends the line (maintainer decision on
    /// #74). Launches the app again, with the sample documents as they were.
    @MainActor
    private func checkATitleThatCannotBeSavedSaysSo(_ ui: UITestApp) {
        ui.launch(extraArguments: ["-UITestFailingSaves", "YES"])
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
