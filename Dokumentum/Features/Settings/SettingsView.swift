import DokumentumKit
import SwiftUI

/// The app's settings (#8, part 3): the Mac's Settings window (⌘,) and, on the iPhone, a sheet from the sidebar's
/// toolbar (`SettingsButton`). Three sections: "Suggestions", "Matching" (#10, part 2, `MatchingSettingsSection`) and
/// "Reminders" (#12, part 3, `ReminderSettingsSection`).
///
/// Below the switch and its availability note come what suggestions do, the privacy statement and the per-device
/// consequence (`about`): on the Mac in the section's footer, on the iPhone in a row without a background below the
/// section. The note and these texts are primary text in callout medium: secondary text in a grouped form's footer is
/// below 4.5:1 in light mode on the Mac (the same measurement as the sidebar footer, #74), and the Mac audit fails
/// smaller text whatever its contrast.
struct SettingsView: View {
    let model: SuggestionSettings
    /// The app's one "Apply Matching Rules" run.
    let matching: MatchingRunModel
    /// The app's reminders; `nil` shows no "Reminders" section (unit tests that build the settings alone).
    var reminders: Reminders?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) })) {
                    Text(SuggestionSettingsText.toggle)
                }
                .disabled(!model.canChangeSwitch)
                .accessibilityIdentifier(AccessibilityID.settingsSuggestionsSwitch)
                if let note = SuggestionSettingsText.availabilityNote(model.availability) {
                    // The symbol is decoration, hidden from VoiceOver; the identifier is on the text alone, like
                    // `PlaceholderView`: as one combined element with the hourglass, the Mac audit failed the note in
                    // light at a measured 14.13:1.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: SuggestionSettingsText.availabilitySymbol(model.availability))
                            .accessibilityHidden(true)
                        Text(note)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(AccessibilityID.settingsSuggestionsAvailability)
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                }
            } header: {
                Text(SuggestionSettingsText.section)
            } footer: {
                #if os(macOS)
                    about
                #endif
            }
            #if os(iOS)
                // On the iPhone the same texts are a row without a background, below the section: in the section's
                // footer the audit reported "Dynamic Type font sizes are partially unsupported" on them (#139), while
                // the availability note, a row in the same font, passes.
                Section {
                    about
                        .listRowBackground(Color.clear)
                }
            #endif
            MatchingSettingsSection(model: matching)
            if let reminders {
                ReminderSettingsSection(reminders: reminders)
            }
        }
        .formStyle(.grouped)
        .modifier(MatchingRunConfirmation(model: matching))
        // Read again on each appearance: the observation runs only while the view is shown.
        .task {
            model.refresh()
            // The permission may have changed in the system's settings meanwhile; reading it never asks.
            if let reminders { await reminders.authorization.refresh() }
            await model.observeAvailability()
        }
        #if os(macOS)
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
        #endif
        .accessibilityIdentifier(AccessibilityID.settings)
    }

    /// What suggestions do, the privacy statement (P6) and the per-device consequence (N8).
    private var about: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SuggestionSettingsText.explanation)
            Text(SuggestionSettingsText.privacy)
                .accessibilityIdentifier(AccessibilityID.settingsSuggestionsPrivacy)
            Text(SuggestionSettingsText.perDevice)
        }
        // Callout, not footnote: the Mac audit reported "Contrast failed" on the footnote at 14.94:1
        // (measured from its pixels), and passes the callout medium of the note above.
        .font(.callout.weight(.medium))
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#if os(iOS)
    /// The sidebar's toolbar button that opens the settings in a sheet (iPhone). Nothing without the app's settings
    /// model (unit tests that build the sidebar alone).
    struct SettingsButton: View {
        @Environment(SuggestionSettings.self) private var model: SuggestionSettings?
        @Environment(MatchingRunModel.self) private var matching: MatchingRunModel?
        @Environment(Reminders.self) private var reminders: Reminders?
        @State private var isPresented = false

        var body: some View {
            if let model, let matching {
                Button {
                    isPresented = true
                } label: {
                    Label {
                        Text("Settings")
                    } icon: {
                        Image(systemName: "gear")
                    }
                }
                .accessibilityIdentifier(AccessibilityID.settingsOpen)
                .sheet(isPresented: $isPresented) {
                    NavigationStack {
                        SettingsView(model: model, matching: matching, reminders: reminders)
                            .navigationTitle(Text("Settings"))
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { isPresented = false }
                                        .accessibilityIdentifier(AccessibilityID.settingsDone)
                                }
                            }
                    }
                }
            }
        }
    }
#endif
