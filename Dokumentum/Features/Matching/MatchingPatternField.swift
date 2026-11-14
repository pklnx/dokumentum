import SwiftUI

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// The rule sheet's pattern field (plan of #10, §8, N8): no autocorrection, no auto-capitalisation, no smart quotes
/// and no smart dashes, so a regular expression is stored exactly as typed (`("--` stays `("--`). SwiftUI's
/// `TextField` offers modifiers for the first two only, so the field is the platform's own text field, set up by
/// `makeField()`: on the iPhone a `UITextField` with its text input traits, on the Mac an `NSTextField` whose field
/// editor gets its substitutions turned off when it starts editing (`PatternTextField`). Monospaced; on the iPhone
/// it follows Dynamic Type (body).
#if os(iOS)
    struct MatchingPatternField: UIViewRepresentable {
        @Binding var text: String
        var isEnabled: Bool

        /// A configured field, for the sheet and for the unit test of its settings.
        static func makeField() -> UITextField {
            let field = UITextField()
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
            field.smartQuotesType = .no
            field.smartDashesType = .no
            field.smartInsertDeleteType = .no
            field.inlinePredictionType = .no
            field.keyboardType = .asciiCapable
            field.returnKeyType = .done
            field.clearButtonMode = .whileEditing
            let size = UIFont.preferredFont(forTextStyle: .body).pointSize
            field.font = UIFontMetrics(forTextStyle: .body).scaledFont(
                for: .monospacedSystemFont(ofSize: size, weight: .regular))
            field.adjustsFontForContentSizeCategory = true
            field.placeholder = String(localized: MatchingRuleText.pattern)
            field.accessibilityLabel = String(localized: MatchingRuleText.pattern)
            field.accessibilityIdentifier = AccessibilityID.matchingPattern
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return field
        }

        func makeUIView(context: Context) -> UITextField {
            let field = Self.makeField()
            field.delegate = context.coordinator
            field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
            return field
        }

        func updateUIView(_ field: UITextField, context: Context) {
            context.coordinator.text = $text
            if field.text != text { field.text = text }
            field.isEnabled = isEnabled
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView field: UITextField, context: Context) -> CGSize? {
            CGSize(width: proposal.width ?? field.intrinsicContentSize.width, height: field.intrinsicContentSize.height)
        }

        func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

        final class Coordinator: NSObject, UITextFieldDelegate {
            var text: Binding<String>

            init(text: Binding<String>) { self.text = text }

            @objc func changed(_ field: UITextField) {
                text.wrappedValue = field.text ?? ""
            }

            func textFieldShouldReturn(_ field: UITextField) -> Bool {
                field.resignFirstResponder()
                return true
            }
        }
    }
#else
    struct MatchingPatternField: NSViewRepresentable {
        @Binding var text: String
        var isEnabled: Bool

        /// A configured field, for the sheet and for the unit test of its settings.
        static func makeField() -> PatternTextField {
            let field = PatternTextField()
            field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.isAutomaticTextCompletionEnabled = false
            field.usesSingleLineMode = true
            field.lineBreakMode = .byClipping
            field.cell?.isScrollable = true
            field.setAccessibilityLabel(String(localized: MatchingRuleText.pattern))
            field.setAccessibilityIdentifier(AccessibilityID.matchingPattern)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return field
        }

        func makeNSView(context: Context) -> PatternTextField {
            let field = Self.makeField()
            field.delegate = context.coordinator
            return field
        }

        func updateNSView(_ field: PatternTextField, context: Context) {
            context.coordinator.text = $text
            if field.stringValue != text { field.stringValue = text }
            field.isEnabled = isEnabled
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView field: PatternTextField, context: Context) -> CGSize? {
            CGSize(width: proposal.width ?? 240, height: field.intrinsicContentSize.height)
        }

        func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

        final class Coordinator: NSObject, NSTextFieldDelegate {
            var text: Binding<String>

            init(text: Binding<String>) { self.text = text }

            func controlTextDidChange(_ notification: Notification) {
                guard let field = notification.object as? NSTextField else { return }
                text.wrappedValue = field.stringValue
            }
        }
    }

    /// A text field whose field editor makes no substitutions while it edits: the window's shared field editor
    /// follows the system's "Use smart quotes and dashes" and text replacements otherwise.
    final class PatternTextField: NSTextField {
        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became, let editor = currentEditor() as? NSTextView {
                Self.turnOffSubstitutions(of: editor)
            }
            return became
        }

        static func turnOffSubstitutions(of editor: NSTextView) {
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.isAutomaticTextCompletionEnabled = false
        }
    }
#endif
