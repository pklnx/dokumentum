import DokumentumKit
import SwiftUI

/// The Deadlines list's one-line notice (#12, part 3; plan §7, Q4): while the list shows open deadlines, reminders are
/// on and the system has not been asked yet, "Allow notifications so this Mac can remind you of these deadlines." with
/// "Allow Notifications". The Mac usually gets its deadlines by sync, so this tap is how it asks. Nothing without the
/// app's reminders (unit tests that build the list alone).
struct DeadlineReminderNotice: View {
    let model: LibraryModel
    @Environment(Reminders.self) private var reminders: Reminders?

    var body: some View {
        if let reminders, model.selection == .upcoming, !model.documents.isEmpty, reminders.offersPermission {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(ReminderSettingsText.notice)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(AccessibilityID.deadlinesReminderNotice)
                Button {
                    reminders.allowTapped()
                } label: {
                    Text(ReminderSettingsText.allow)
                }
                .accessibilityIdentifier(AccessibilityID.deadlinesReminderAllow)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.background)
        }
    }
}
