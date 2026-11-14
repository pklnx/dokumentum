import DokumentumKit
import SwiftUI

/// The open document's deadline in the detail (#12, part 2a; plan §8), under the processing line: for an open deadline
/// one line, "Due 16 Nov 2026 · Pay · Due in 2 days", with "Mark as Done" and "Edit…" (which opens the info panel and its
/// "Deadline" section). Nothing for a done deadline, for none, and for a document in the trash, which is not edited.
/// Part 2b adds the suggestion found in the text to this bar.
///
/// As the processing line: primary text on the window's own background, not on a material (the audit fails text on
/// `.bar` whatever its contrast, #74); the line is one VoiceOver element, each button another. Overdue has its own
/// symbol and the word "Overdue", never colour alone. When the line does not fit beside the buttons, they go under it.
struct DeadlineBar: View {
    @Bindable var model: LibraryModel

    var body: some View {
        if let document = model.selectedDocument, !document.isTrashed, let deadline = document.openDeadline {
            let status = DeadlineStatus(deadline, today: model.today)
            VStack(spacing: 0) {
                // The buttons next to the line while it fits on one line beside them, under it otherwise (a narrow
                // window, the iPhone, large text sizes).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        line(deadline, status: status)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 8)
                        buttons(document)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        line(deadline, status: status)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        buttons(document)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }
            .background(.background)
        }
    }

    private func line(_ deadline: DocumentDeadline, status: DeadlineStatus) -> some View {
        Label {
            Text(verbatim: DeadlineText.line(deadline, status: status))
        } icon: {
            Image(systemName: DeadlineText.symbol(status))
                .foregroundStyle(status.isOverdue ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: DeadlineText.spoken(deadline, status: status)))
        .accessibilityIdentifier(AccessibilityID.detailDeadline(status))
    }

    @ViewBuilder
    private func buttons(_ document: LibraryDocument) -> some View {
        if model.canEdit {
            HStack(spacing: 8) {
                button("Mark as Done", identifier: AccessibilityID.detailDeadlineMarkDone) {
                    model.edit(.deadlineDone(true), of: document.instanceID)
                }
                button("Edit…", identifier: AccessibilityID.detailDeadlineEdit) {
                    model.isInfoPresented = true
                }
            }
        }
    }

    private func button(
        _ title: LocalizedStringKey, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            #if os(iOS)
                // As "Try again": a bordered button with a primary label, which has the contrast the plain button's
                // system blue lacks on white.
                .buttonStyle(.bordered)
                .tint(.primary)
            #endif
            .accessibilityIdentifier(identifier)
    }
}
