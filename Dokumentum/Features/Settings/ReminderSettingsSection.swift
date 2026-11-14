import DokumentumKit
import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// The settings' "Reminders" section (#12, part 3; plan §7; maintainer decisions Q3–Q5), after "Matching": the switch,
/// the lead time and the time of day (this device's, never synced), the permission's status with "Allow
/// Notifications" or, when it was refused, a button to the system's settings (both only while reminders are on), and
/// what a reminder shows (the footnote names "Show Previews"). As the other sections: the texts below it in the footer on the Mac and in a row without a
/// background on the iPhone, primary text in callout medium.
struct ReminderSettingsSection: View {
    let reminders: Reminders
    @Environment(\.openURL) private var openURL

    private var settings: ReminderSettings { reminders.settings.settings }
    private var status: ReminderAuthorizationStatus { reminders.authorization.status }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.isOn }, set: { reminders.settings.setOn($0) })) {
                Text(ReminderSettingsText.toggle)
            }
            .accessibilityIdentifier(AccessibilityID.settingsRemindersSwitch)
            Picker(selection: Binding(get: { settings.leadDays }, set: { reminders.settings.setLeadDays($0) })) {
                ForEach(ReminderSettings.leadDayChoices, id: \.self) { days in
                    Text(ReminderSettingsText.lead(days)).tag(days)
                }
            } label: {
                Text(ReminderSettingsText.leadPicker)
            }
            .disabled(!settings.isOn)
            .accessibilityIdentifier(AccessibilityID.settingsRemindersLead(settings.leadDays))
            DatePicker(selection: time, displayedComponents: .hourAndMinute) {
                Text(ReminderSettingsText.timePicker)
            }
            .disabled(!settings.isOn)
            .accessibilityIdentifier(AccessibilityID.settingsRemindersTime(settings.minuteOfDay))
            // The status and its button only while reminders are on (maintainer decision on review B N4 of #222).
            if reminders.showsPermissionStatus {
                statusLine
            }
        } header: {
            Text(ReminderSettingsText.section)
        } footer: {
            #if os(macOS)
                about
            #endif
        }
        #if os(iOS)
            Section {
                about
                    .listRowBackground(Color.clear)
            }
        #endif
    }

    /// The time picker's date: today at the stored minute, in the current calendar; a new value stores its hour and
    /// minute.
    private var time: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: settings.hour, minute: settings.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                reminders.settings.setMinuteOfDay((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            })
    }

    /// The permission's status, with what the user can do about it: a row of its own for the line, and one for the
    /// button. The line is built as the "Suggestions" availability note, which passes the iPhone audit: a decorative
    /// symbol and the text in a stack that carries the font, the identifier on the text alone. As the row's own text,
    /// and in a stack with the button, the audit reported "Dynamic Type font sizes are unsupported" on the row.
    @ViewBuilder
    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: ReminderSettingsText.statusSymbol(status))
                .accessibilityHidden(true)
            Text(ReminderSettingsText.status(status))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.settingsRemindersStatus(status))
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.primary)
        switch status {
        case .notDetermined:
            Button {
                reminders.allowTapped()
            } label: {
                Text(ReminderSettingsText.allow)
            }
            .accessibilityIdentifier(AccessibilityID.settingsRemindersAllow)
        case .denied:
            Button {
                if let url = Self.systemNotificationSettings { openURL(url) }
            } label: {
                Text(ReminderSettingsText.openSystemSettings)
            }
            .accessibilityIdentifier(AccessibilityID.settingsRemindersOpenSettings)
        case .authorized, .provisional, .ephemeral:
            EmptyView()
        }
    }

    /// What a reminder shows (Q5) and that the settings are per device.
    private var about: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ReminderSettingsText.footnote)
                .accessibilityIdentifier(AccessibilityID.settingsRemindersFootnote)
            Text(ReminderSettingsText.perDevice)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The system's notification settings of the app.
    static var systemNotificationSettings: URL? {
        #if os(macOS)
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        #else
            URL(string: UIApplication.openNotificationSettingsURLString)
        #endif
    }
}
