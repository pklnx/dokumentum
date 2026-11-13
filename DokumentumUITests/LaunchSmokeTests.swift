import XCTest

/// The real app starts on a local store on disk and shows its root view, on iOS and on macOS. The store
/// is a new one in the app's temporary directory (`-UITestLocalStore`), never the archive's path.
///
/// Detection (#11, part 2) on the same launch, where the processing queue runs: `-UITestImportLetter` imports a
/// synthetic letter as a text PDF, and `-UITestClassifierAvailability deviceNotEligible` makes it the `done` path,
/// where only detection fills fields. The letter's info shows the detected correspondent and date. It extends this
/// test, so the suite keeps its count (plan §4); the `classify` path is covered by the queue tests (N10).
final class LaunchSmokeTests: XCTestCase {
    /// `DokumentumApp.rootIdentifier`; a UI test cannot see the app's code.
    private let rootIdentifier = "dokumentum.root"
    /// What detection finds on `din-a-stadtwerke` (`SyntheticLetters`): sample data, the same in every language.
    private static let letter = "din-a-stadtwerke"
    private static let sender = "Stadtwerke Musterstadt GmbH"

    @MainActor
    func testTheAppLaunchesAndShowsItsRootView() {
        let launched = UITestApp()
        launched.launch(
            .localOnDisk(name: "LaunchSmoke"),
            extraArguments: [
                "-UITestImportLetter", Self.letter, "-UITestClassifierAvailability", "deviceNotEligible",
            ])
        defer { quit(launched.app) }
        XCTAssertTrue(launched.element(rootIdentifier).waitForExistence(timeout: 60), "The root view did not appear")
        #if os(macOS)
            // The unsigned Mac build has no CloudKit entitlement: "Sync off: this build has no iCloud access".
            XCTAssertTrue(launched.element("sidebar.syncOff").waitForExistence(timeout: 10), "no “Sync off” line")
            launched.attachWindowScreenshot("1-local-store-sync-off", to: self)
        #endif
        showsTheDetectedSenderAndDate(launched)
    }

    /// The imported letter's info: the correspondent and the date that detection filled.
    @MainActor
    private func showsTheDetectedSenderAndDate(_ ui: UITestApp) {
        let row = ui.app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "documentList.row.")
        ).firstMatch
        // An import of one file opens it on the iPhone; on the Mac the list shows its row.
        let showInfo = ui.element("documentDetail.showInfo")
        let imported = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in row.exists || showInfo.exists }, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [imported], timeout: UITestApp.timeout(60)), .completed, "the letter was not imported")
        if !showInfo.exists {
            #if os(macOS)
                row.click()
            #else
                row.tap()
            #endif
        }
        ui.activate("documentDetail.showInfo")
        let correspondent = ui.element("documentInfo.correspondent")
        XCTAssertTrue(correspondent.waitForExistence(timeout: 20), "no info")
        let detected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", Self.sender, Self.sender),
            object: correspondent)
        XCTAssertEqual(
            XCTWaiter.wait(for: [detected], timeout: UITestApp.timeout(120)), .completed,
            "no detected correspondent: \(correspondent.label) \(String(describing: correspondent.value))")
        // 13.11.2026. The Mac's date picker gives its value as a date's description in UTC
        // ("Unsafe value, description '2026-11-12 23:20:19 +0000'"), read back in this machine's time zone, as the
        // app shows it; the iPhone's as text in the app's format (the day, the month as a number or a name, the year).
        let date = ui.element("documentInfo.date")
        XCTAssertTrue(date.waitForExistence(timeout: 10), "no date")
        let shown = ([date] + date.descendants(matching: .any).allElementsBoundByIndex).map {
            [$0.label, $0.value as? String ?? ""].joined(separator: " ")
        }.joined(separator: " ")
        if let match = shown.firstMatch(of: /\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}/) {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            let value = parser.date(from: String(match.output))
            let day = value.map { Calendar.current.dateComponents([.year, .month, .day], from: $0) }
            XCTAssertEqual(day, DateComponents(year: 2026, month: 11, day: 13), "not the detected date: \(shown)")
        } else {
            XCTAssertTrue(shown.contains("13") && shown.contains("2026"), "not the detected date: \(shown)")
        }
        ui.attachWindowScreenshot("2-detected-sender-and-date", to: self)
    }

    /// Ends the launch. On the Mac a normal quit (⌘Q), so the app removes its `-UITestLocalStore` folder in
    /// `willTerminate`; `terminate()` ends it without that notification (measured on #53). On the iPhone the
    /// folder is in the app's own container and is removed at its next launch.
    @MainActor
    private func quit(_ app: XCUIApplication) {
        #if os(macOS)
            app.activate()
            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 30), "the app did not quit")
        #else
            app.terminate()
        #endif
    }
}
