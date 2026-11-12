import DokumentumKit
import SwiftUI

/// The app's settings (#8, part 3): the Mac's Settings window (⌘,) and, on the iPhone, a sheet from the sidebar's
/// toolbar (`SettingsButton`). One section so far, "Suggestions".
///
/// The availability note and the footer are primary text in callout medium: secondary text in a grouped form's footer
/// is below 4.5:1 in light mode on the Mac (the same measurement as the sidebar footer, #74), and the Mac audit fails
/// smaller text whatever its contrast.
struct SettingsView: View {
    let model: SuggestionSettings

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) })) {
                    Text(SuggestionSettingsText.toggle)
                }
                .disabled(!model.canChangeSwitch)
                .accessibilityIdentifier(AccessibilityID.settingsSuggestionsSwitch)
                if let note = SuggestionSettingsText.availabilityNote(model.availability) {
                    Label {
                        Text(note)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: SuggestionSettingsText.availabilitySymbol(model.availability))
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.settingsSuggestionsAvailability)
                }
            } header: {
                Text(SuggestionSettingsText.section)
            } footer: {
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
        .formStyle(.grouped)
        // Read again on each appearance: the observation runs only while the view is shown.
        .task {
            model.refresh()
            await model.observeAvailability()
        }
        #if os(macOS)
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
        #endif
        .accessibilityIdentifier(AccessibilityID.settings)
    }
}

#if os(iOS)
    /// The sidebar's toolbar button that opens the settings in a sheet (iPhone). Nothing without the app's settings
    /// model (unit tests that build the sidebar alone).
    struct SettingsButton: View {
        @Environment(SuggestionSettings.self) private var model: SuggestionSettings?
        @State private var isPresented = false

        var body: some View {
            if let model {
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
                        SettingsView(model: model)
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
