import DokumentumKit
import SwiftUI

/// The open document's deadline in the detail (#12, part 2a; plan §8), under the processing line: for an open deadline
/// one line, "Due 16 Nov 2026 · Pay · Due in 2 days", with "Mark as Done" and "Edit…" (which opens the info panel and its
/// "Deadline" section). Nothing for a done deadline and for a document in the trash, which is not edited.
///
/// **The suggestion** (#12, part 2b; plan §5, maintainer decision Q2): without a deadline, the due date found in the
/// text (`LibraryModel.deadlineSuggestion`), "Found in the text: Payment due 28 Nov 2026", with "Add Deadline" (sets it,
/// with the kind as its label) and "Dismiss" (dismissed up to that day, synced). Nothing is set without the user.
///
/// As the processing line: primary text on the window's own background, not on a material (the audit fails text on
/// `.bar` whatever its contrast, #74); the line is one VoiceOver element, each button another. Overdue has its own
/// symbol and the word "Overdue", never colour alone. When the line does not fit beside the buttons, they go under it.
struct DeadlineBar: View {
    @Bindable var model: LibraryModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The deadline the bar shows for `document`: its open deadline, unless it is in the trash (its edits are refused
    /// there, so "Mark as Done" must not show; review N5 of #219). `nil`: no bar.
    static func shownDeadline(of document: LibraryDocument?) -> DocumentDeadline? {
        guard let document, !document.isTrashed else { return nil }
        return document.openDeadline
    }

    var body: some View {
        if let document = model.selectedDocument, let deadline = Self.shownDeadline(of: document) {
            let status = DeadlineStatus(deadline, today: model.today)
            bar(line: line(deadline, status: status)) {
                markDoneButton(document)
                editButton
            }
        } else if model.canEdit, let document = model.selectedDocument, let suggestion = model.deadlineSuggestion {
            bar(line: suggestionLine(suggestion)) {
                addSuggestionButton(suggestion, of: document)
                dismissSuggestionButton(suggestion, of: document)
            }
        }
    }

    /// The bar around one line and its buttons: the buttons next to the line while it fits on one line beside them,
    /// under it otherwise (a narrow window, the iPhone, large text sizes).
    private func bar<Line: View, Buttons: View>(line: Line, @ViewBuilder buttons: @escaping () -> Buttons) -> some View
    {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    line
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    buttonRow(buttons)
                }
                VStack(alignment: .leading, spacing: 8) {
                    line
                        .frame(maxWidth: .infinity, alignment: .leading)
                    buttonRow(buttons)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
        }
        .background(.background)
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
        // `.combine`, as the processing line: with `.ignore` the Mac audit found no role on it ("Unknown role"). The label
        // then reads the long date ("16 November 2026") in place of the line's short one.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: DeadlineText.spoken(deadline, status: status)))
        .accessibilityIdentifier(AccessibilityID.detailDeadline(status))
    }

    /// The suggestion's line: what the text says, with a symbol of text found in the page. One VoiceOver element with the
    /// long date; the identifier names the day (`yyyy-MM-dd`).
    private func suggestionLine(_ suggestion: DueDateCandidate) -> some View {
        Label {
            Text(verbatim: DeadlineText.suggestion(suggestion))
        } icon: {
            Image(systemName: "text.viewfinder")
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: DeadlineText.suggestion(suggestion, long: true)))
        .accessibilityIdentifier(AccessibilityID.detailDeadlineSuggestion(suggestion.day))
    }

    /// Side by side up to the default text size, one under the other from xLarge on (#219 fix round 1): "Als erledigt
    /// markieren" and "Bearbeiten …" side by side were clipped at larger sizes on the iPhone (the audit's "Text
    /// clipped"), and a row held at its full width with `fixedSize` kept its text from growing ("Dynamic Type font
    /// sizes are partially unsupported"). The labels wrap when one alone is wider than the bar. Only for a source that
    /// takes edits.
    @ViewBuilder
    private func buttonRow<Buttons: View>(_ buttons: () -> Buttons) -> some View {
        if model.canEdit {
            let layout =
                dynamicTypeSize >= .xLarge
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                buttons()
            }
        }
    }

    /// Sets the suggested day as the deadline, with the kind's name as its label (a user action, Q2).
    private func addSuggestionButton(_ suggestion: DueDateCandidate, of document: LibraryDocument) -> some View {
        button("Add Deadline", identifier: AccessibilityID.detailDeadlineSuggestionAdd) {
            model.addSuggestedDeadline(suggestion, to: document.instanceID)
        }
    }

    /// Dismisses suggestions up to the suggested day; a later one in the text is offered next.
    private func dismissSuggestionButton(_ suggestion: DueDateCandidate, of document: LibraryDocument) -> some View {
        button("Dismiss", identifier: AccessibilityID.detailDeadlineSuggestionDismiss) {
            Task { await model.dismissDeadlineSuggestion(suggestion, of: document.instanceID) }
        }
    }

    private func markDoneButton(_ document: LibraryDocument) -> some View {
        button("Mark as Done", identifier: AccessibilityID.detailDeadlineMarkDone) {
            model.edit(.deadlineDone(true), of: document.instanceID)
        }
    }

    private var editButton: some View {
        button("Edit…", identifier: AccessibilityID.detailDeadlineEdit) {
            model.isInfoPresented = true
        }
    }

    private func button(
        _ title: LocalizedStringKey, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // The label may wrap and grow in height: a bordered button holds its text to one line otherwise, and the
            // iPhone audit reported "Text clipped" on "Als erledigt markieren" at larger text sizes (#219 fix round 1).
            Text(title)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        #if os(iOS)
            // As "Try again": a bordered button with a primary label, which has the contrast the plain button's
            // system blue lacks on white.
            .buttonStyle(.bordered)
            .tint(.primary)
        #endif
        .accessibilityIdentifier(identifier)
    }
}
