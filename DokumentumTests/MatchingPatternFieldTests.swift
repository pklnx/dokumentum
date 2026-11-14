import Testing

@testable import Dokumentum

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// The rule sheet's pattern field (#10, part 2; plan review N8, re-review N5): a regular expression is stored as
/// typed, so the field makes no corrections and no substitutions. The UI test types `("--` and checks the value; this
/// test pins the settings themselves, which a simulator's `typeText` may bypass.
@MainActor
struct MatchingPatternFieldTests {
    #if os(iOS)
        /// Counter-proof: drop `smartQuotesType = .no` → the expectation on it fails.
        @Test func theFieldMakesNoCorrectionsOrSubstitutions() {
            let field = MatchingPatternField.makeField()
            #expect(field.autocorrectionType == .no)
            #expect(field.autocapitalizationType == UITextAutocapitalizationType.none)
            #expect(field.spellCheckingType == .no)
            #expect(field.smartQuotesType == .no)
            #expect(field.smartDashesType == .no)
            #expect(field.smartInsertDeleteType == .no)
            #expect(field.adjustsFontForContentSizeCategory, "Dynamic Type")
            #expect(field.accessibilityIdentifier == AccessibilityID.matchingPattern)
        }

        /// The field's font is as large as body text at every text size, scaled once, and monospaced (review of #210,
        /// B1). Counter-proof: scaled again with `UIFontMetrics`, as before the fix → larger than body at XXXL and
        /// AccessibilityXXXL.
        @Test(arguments: [
            UIContentSizeCategory.large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge,
        ])
        func theFontIsBodySizedAtEveryTextSize(size: UIContentSizeCategory) {
            let traits = UITraitCollection(preferredContentSizeCategory: size)
            let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize
            let pattern = MatchingPatternField.patternFont(compatibleWith: traits).pointSize
            #expect(pattern == body, "\(size.rawValue): body is \(body) pt, the pattern field \(pattern) pt")
            let font = MatchingPatternField.patternFont(compatibleWith: traits)
            // SF Mono reports no monospace symbolic trait; its name says it.
            #expect(font.fontName.localizedCaseInsensitiveContains("mono"), "not monospaced: \(font.fontName)")
        }
    #else
        /// The field editor the window gives the field when it starts editing has its substitutions off, whatever the
        /// system's "Use smart quotes and dashes" says. Counter-proof: no override of `becomeFirstResponder` → the
        /// window's field editor keeps the system's settings, which this test turns on first.
        @Test func theFieldEditorMakesNoSubstitutions() throws {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let field = MatchingPatternField.makeField()
            field.frame = NSRect(x: 10, y: 10, width: 280, height: 24)
            window.contentView?.addSubview(field)
            // The window's shared field editor, with every substitution on, as with the system setting on.
            let shared = try #require(window.fieldEditor(true, for: field) as? NSTextView)
            shared.isAutomaticQuoteSubstitutionEnabled = true
            shared.isAutomaticDashSubstitutionEnabled = true
            shared.isAutomaticTextReplacementEnabled = true
            shared.isAutomaticSpellingCorrectionEnabled = true

            #expect(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            #expect(!editor.isAutomaticQuoteSubstitutionEnabled)
            #expect(!editor.isAutomaticDashSubstitutionEnabled)
            #expect(!editor.isAutomaticTextReplacementEnabled)
            #expect(!editor.isAutomaticSpellingCorrectionEnabled)
            #expect(field.accessibilityIdentifier() == AccessibilityID.matchingPattern)
        }
    #endif
}
