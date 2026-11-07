import XCTest

/// Launches the app for a UI test and finds its elements by accessibility identifier, never by
/// localized text.
@MainActor
struct UITestApp {
    let app = XCUIApplication()

    /// The store a UI test launches with; both are in memory and never saved.
    enum Store {
        /// `-UITestSeed`: the sample documents, with the catalog's fixed `instanceID`s.
        case samples
        /// `-UITestEmptyStore`: an empty archive.
        case empty
        /// `-UITestLocalStore <name>`: a new, empty local store on disk in the app's temporary directory,
        /// never the archive's path.
        case localOnDisk(name: String)
    }

    /// `-UITestSeed`: the sample library in an in-memory store (the predecessor's argument; `-UITestEmptyStore`
    /// for an empty one). `-ApplePersistenceIgnoreState YES`: the development VM keeps stale window
    /// state for the app's bundle ID, under which a build with a different root view type opens no
    /// window (plan of #3, T5).
    ///
    /// Every argument comes as a `-key value` pair. A bare `-UITestSeed` takes the next argument as its
    /// value, so in `-UITestSeed -ApplePersistenceIgnoreState YES` the `YES` is left over, macOS opens it
    /// as a document, and SwiftUI then opens no window at all (measured on macOS 27, #43).
    static func launchArguments(_ store: Store) -> [String] {
        let storeArguments =
            switch store {
            case .samples: ["-UITestSeed", "YES"]
            case .empty: ["-UITestEmptyStore", "YES"]
            case .localOnDisk(let name): ["-UITestLocalStore", name]
            }
        return storeArguments + ["-ApplePersistenceIgnoreState", "YES"]
    }

    /// The language of this run: `TEST_RUNNER_DOKUMENTUM_UI_LANGUAGE=de` on the `xcodebuild` command
    /// line gives the German screenshots. Empty: the system's language.
    static var language: String? {
        ProcessInfo.processInfo.environment["DOKUMENTUM_UI_LANGUAGE"].flatMap { $0.isEmpty ? nil : $0 }
    }

    func launch(_ store: Store = .samples) {
        var arguments = Self.launchArguments(store)
        if let language = Self.language {
            arguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language]
        }
        app.launchArguments = arguments
        app.launch()
    }

    /// The first element with this identifier: an identifier on a sidebar row can match more than one
    /// element (measured on iOS in the plan of #3).
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Taps on iOS, clicks on macOS.
    func activate(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = element(identifier)
        XCTAssertTrue(element.waitForExistence(timeout: 20), "\(identifier) did not appear", file: file, line: line)
        #if os(macOS)
            element.click()
        #else
            element.tap()
        #endif
    }

    /// A screenshot of the app's window only, kept with the result. Never `XCUIScreen.main`: on the
    /// Mac that is the whole desktop, with other apps' windows.
    func attachWindowScreenshot(_ name: String, to testCase: XCTestCase) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = [name, Self.language].compactMap { $0 }.joined(separator: "-")
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }
}
