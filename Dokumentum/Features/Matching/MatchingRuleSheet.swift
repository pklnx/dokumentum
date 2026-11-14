import DokumentumCore
import DokumentumKit
import SwiftUI

/// The rule sheet (plan of #10, §8; #200), from a sidebar row's "Edit Matching…": the record's name as the title, the
/// mode picker with the five names, the pattern field (`MatchingPatternField`), a line under the field for a problem,
/// and the mode's explanation; Cancel and Save. A record with copies sharing its `instanceID`, or one that is gone,
/// shows that state instead of the editor.
///
/// The error line and the explanation are primary text in callout medium, as the settings' notes: the Mac audit fails
/// regular-weight and secondary text in light whatever its contrast (#89, #139). The explanation is in the section's
/// footer on the Mac and a row without a background on the iPhone, as `SettingsView` does (#139).
struct MatchingRuleSheet: View {
    @Bindable var draft: MatchingRuleDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                switch draft.state {
                case .editing:
                    editor
                case .copies:
                    note(MatchingRuleText.copies(draft.target.name), identifier: AccessibilityID.matchingCopies)
                case .gone:
                    note(MatchingRuleText.gone, identifier: AccessibilityID.matchingGone)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(verbatim: draft.target.name))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.matchingCancel)
                }
                if draft.state == .editing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if draft.save() { dismiss() }
                        }
                        .disabled(!draft.canSave)
                        .accessibilityIdentifier(AccessibilityID.matchingSave)
                    }
                }
            }
        }
        #if os(macOS)
            .frame(width: 480)
            .fixedSize(horizontal: false, vertical: true)
        #endif
        .accessibilityIdentifier(AccessibilityID.matchingSheet)
    }

    @ViewBuilder
    private var editor: some View {
        Section {
            Picker(selection: $draft.mode) {
                ForEach(draft.modeOptions, id: \.self) { mode in
                    Text(MatchingRuleText.name(mode))
                        .tag(mode)
                        .accessibilityIdentifier(AccessibilityID.matchingMode(mode))
                }
            } label: {
                Text(MatchingRuleText.match)
            }
            #if os(macOS)
                // Radio buttons, not a pop-up: the Mac audit reports a SwiftUI pop-up picker as "Action is missing"
                // (measured on this sheet, as on `cleanup.filter`, #112), and the five names are read at a glance.
                .pickerStyle(.radioGroup)
            #endif
            .accessibilityIdentifier(AccessibilityID.matchingMode)
            #if os(macOS)
                LabeledContent {
                    MatchingPatternField(text: $draft.pattern, isEnabled: draft.isPatternEnabled)
                } label: {
                    Text(MatchingRuleText.pattern)
                }
            #else
                MatchingPatternField(text: $draft.pattern, isEnabled: draft.isPatternEnabled)
            #endif
            if let line = problemLine {
                // The symbol is decoration, hidden from VoiceOver; the identifier is on the text alone.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(line)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(AccessibilityID.matchingError)
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
            }
        } footer: {
            #if os(macOS)
                explanation
            #endif
        }
        #if os(iOS)
            Section {
                explanation
                    .listRowBackground(Color.clear)
            }
        #endif
    }

    /// The line under the field: the check's or the probe's problem, or a failed save.
    private var problemLine: LocalizedStringResource? {
        if let problem = draft.shownProblem { return MatchingRuleText.problem(problem) }
        return draft.saveFailed ? MatchingRuleText.notSaved : nil
    }

    private var explanation: some View {
        Text(MatchingRuleText.explanation(draft.mode))
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(AccessibilityID.matchingExplanation)
    }

    private func note(_ text: LocalizedStringResource, identifier: String) -> some View {
        Section {
            Text(text)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        }
    }
}
