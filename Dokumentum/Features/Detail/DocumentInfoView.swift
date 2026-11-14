import DokumentumCore
import DokumentumKit
import SwiftUI

/// The open document's info panel (plan of #3, part 3; PQ6): an inspector, a trailing column on the Mac and a
/// sheet on the iPhone. Every edit saves at once through `LibraryModel.edit`, the title and the deadline's label on
/// Return or when the field loses focus. Choosing and creating metadata by name only (PQ7). The "Deadline" section
/// (#12, part 2a) adds, changes, completes and removes the document's one deadline. A trashed document is shown, not
/// edited.
struct DocumentInfoView: View {
    let model: LibraryModel

    var body: some View {
        #if os(iOS)
            // A sheet on the iPhone: its own bar with "Done".
            NavigationStack {
                content
                    .navigationTitle("Info")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.isInfoPresented = false }
                                .accessibilityIdentifier(AccessibilityID.infoDone)
                        }
                    }
            }
        #else
            content
                .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
        #endif
    }

    private var content: some View {
        Group {
            if let document = model.selectedDocument {
                DocumentInfoForm(model: model, document: document)
            } else {
                // Shown only while the panel closes: it closes with the selection (`LibraryModel.selectedDocumentID`,
                // `LibraryEditingTests.theInfoPanelClosesWhenTheSelectionClears`), and Show Info is disabled without
                // a document. So no UI test visits it (plan of #89, T3).
                #if os(macOS)
                    PlaceholderView(title: "No document selected", systemImage: "doc.text.magnifyingglass")
                #else
                    ContentUnavailableView("No document selected", systemImage: "doc.text.magnifyingglass")
                #endif
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.info)
    }
}

/// A correspondent or type choice in a picker.
private enum MetadataChoice: Hashable {
    case none
    case record(UUID)
    /// "New…": asks for a name.
    case new
}

private struct DocumentInfoForm: View {
    let model: LibraryModel
    let document: LibraryDocument

    /// The title as typed; saved on Return, when the field loses focus, when the selection moves on or when the
    /// panel closes, and only if the user changed it (`TitleDraft`).
    @State private var titleDraft = TitleDraft()
    @FocusState private var titleFocused: Bool
    /// The deadline's label as typed (#12, part 2a), with the same rules as the title: saved on Return, when the field
    /// loses focus, when the selection moves on or when the panel closes, and only if the user changed it.
    @State private var labelDraft = TitleDraft()
    @FocusState private var labelFocused: Bool
    /// The kind of record "New…" asks a name for.
    @State private var newKind: MetadataKind?
    @State private var newName = ""

    private var isEditable: Bool { model.canEdit && !document.isTrashed }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $titleDraft.text, prompt: Text("Untitled document"))
                    .focused($titleFocused)
                    .onSubmit(commitTitle)
                    .accessibilityIdentifier(AccessibilityID.infoTitle)
                // The save failed and was rolled back (maintainer decision on #74): one line, no alert. The text
                // keeps the primary colour, which has the contrast red footnote text lacks; only the icon is red.
                if model.titleSaveFailure == document.instanceID {
                    Label {
                        Text("The title could not be saved.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)
                    }
                    .font(.footnote)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.infoTitleNotSaved)
                }
                DatePicker("Date", selection: dateBinding, displayedComponents: .date)
                    .accessibilityIdentifier(AccessibilityID.infoDate)
                Toggle("In Inbox", isOn: inboxBinding)
                    .accessibilityIdentifier(AccessibilityID.infoInbox)
            }
            Section {
                metadataPicker(
                    "Correspondent", kind: .correspondent, current: document.correspondent,
                    records: model.snapshot.correspondents, identifier: AccessibilityID.infoCorrespondent,
                    change: { .correspondent($0) })
                metadataPicker(
                    "Document Type", kind: .documentType, current: document.documentType,
                    records: model.snapshot.documentTypes, identifier: AccessibilityID.infoDocumentType,
                    change: { .documentType($0) })
            }
            deadlineSection
            Section("Tags") {
                ForEach(model.tagChoices, id: \.instanceID) { choice in
                    tagRow(choice.instanceID, path: choice.path)
                }
                Button("New Tag…") { askForName(.tag) }
                    .accessibilityIdentifier(AccessibilityID.infoNewTag)
            }
        }
        .formStyle(.grouped)
        .disabled(!isEditable)
        .onChange(of: document.instanceID, initial: true) { _, _ in
            // The selection moved on: a changed draft is saved to its own document first.
            commitTitle()
            titleDraft.show(document.instanceID, title: document.title)
        }
        .onChange(of: document.title) { _, title in
            titleDraft.titleChanged(to: title)
        }
        .onChange(of: document.instanceID, initial: true) { _, _ in
            commitLabel()
            labelDraft.show(document.instanceID, title: document.deadline?.label ?? "")
        }
        .onChange(of: document.deadline?.label ?? "") { _, label in
            labelDraft.titleChanged(to: label)
        }
        .onChange(of: labelFocused) { _, focused in
            if !focused { commitLabel() }
        }
        .onChange(of: titleDraft.text) { _, _ in
            // Typing ends the "could not be saved" line; showing the stored title again (text equals base) does not.
            if titleDraft.isChanged { model.titleEditStarted() }
        }
        .onChange(of: titleFocused) { _, focused in
            if !focused { commitTitle() }
        }
        .onDisappear {
            commitTitle()
            commitLabel()
        }
        .alert(newKindTitle, isPresented: isAskingForName) {
            TextField("Name", text: $newName)
                .accessibilityIdentifier(AccessibilityID.infoNewName)
            Button("Add") {
                if let newKind { model.assignMetadata(newKind, named: newName, to: document.instanceID) }
            }
            .disabled(MetadataName.normalized(newName).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Title

    /// Saves the draft to its document if the user changed it; a draft that was not saved shows the stored title.
    private func commitTitle() {
        model.commitTitle(&titleDraft)
    }

    // MARK: Deadline

    /// "Add Deadline" without a deadline: the suggestion the detail offers (its day and kind, #12 part 2b), else 7 days
    /// after today; with one, its day (a date-only picker, four-digit years), its label, "Completed" and "Remove
    /// Deadline", which also dismisses the day when it is the text's suggestion (review N9). A done deadline stays here
    /// with "Completed" on, so it can be opened again.
    @ViewBuilder
    private var deadlineSection: some View {
        Section("Deadline") {
            if let deadline = document.deadline {
                DatePicker(
                    "Due Date", selection: deadlineDayBinding(deadline), in: DeadlineText.pickerRange,
                    displayedComponents: .date
                )
                .accessibilityIdentifier(AccessibilityID.infoDeadlineDate)
                TextField("Label", text: $labelDraft.text, prompt: Text("Optional"))
                    .focused($labelFocused)
                    .onSubmit(commitLabel)
                    .accessibilityIdentifier(AccessibilityID.infoDeadlineLabel)
                Toggle("Completed", isOn: deadlineDoneBinding)
                    .accessibilityIdentifier(AccessibilityID.infoDeadlineDone)
                Button("Remove Deadline") {
                    model.removeDeadline(of: document.instanceID)
                }
                .accessibilityIdentifier(AccessibilityID.infoDeadlineRemove)
            } else {
                Button("Add Deadline") {
                    model.addDeadline(to: document.instanceID)
                }
                .accessibilityIdentifier(AccessibilityID.infoDeadlineAdd)
            }
        }
    }

    /// A day-only edit (review N1 of #219): it keeps the stored label; the label draft is saved on its own.
    private func deadlineDayBinding(_ deadline: DocumentDeadline) -> Binding<Date> {
        Binding(
            get: { DeadlineText.date(of: deadline.day) },
            set: { date in
                guard let day = DeadlineText.day(of: date) else { return }
                model.edit(.deadlineDay(day), of: document.instanceID)
            })
    }

    private var deadlineDoneBinding: Binding<Bool> {
        Binding(
            get: { document.deadline?.isDone ?? false },
            set: { model.edit(.deadlineDone($0), of: document.instanceID) })
    }

    /// Saves the label draft to its own document's deadline if the user changed it, as a label-only edit
    /// (`LibraryModel.commitDeadlineLabel`).
    private func commitLabel() {
        model.commitDeadlineLabel(&labelDraft)
    }

    // MARK: Date and inbox

    private var dateBinding: Binding<Date> {
        Binding(
            get: { document.documentDate },
            set: { model.edit(.documentDate($0), of: document.instanceID) })
    }

    private var inboxBinding: Binding<Bool> {
        Binding(
            get: { document.isInbox },
            set: { model.edit(.inbox($0), of: document.instanceID) })
    }

    // MARK: Correspondent and type

    private func metadataPicker(
        _ title: LocalizedStringKey, kind: MetadataKind, current: LibraryDocument.Reference?,
        records: [LibraryDocument.Reference], identifier: String, change: @escaping (UUID?) -> DocumentEditor.Change
    ) -> some View {
        let sorted = records.sorted { lhs, rhs in
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.instanceID.uuidString < rhs.instanceID.uuidString
            }
        }
        // A reference the sidebar does not list (a tombstone whose chain ends nowhere) still shows its name.
        let unlisted = current.flatMap { current in records.contains(current) ? nil : current }
        let selection = Binding<MetadataChoice>(
            get: { current.map { .record($0.instanceID) } ?? .none },
            set: { choice in
                switch choice {
                case .none: model.edit(change(nil), of: document.instanceID)
                case .record(let id): model.edit(change(id), of: document.instanceID)
                case .new: askForName(kind)
                }
            })
        return Picker(title, selection: selection) {
            Text("None").tag(MetadataChoice.none)
            if let unlisted {
                Text(verbatim: unlisted.name).tag(MetadataChoice.record(unlisted.instanceID))
            }
            ForEach(sorted, id: \.instanceID) { record in
                Text(verbatim: record.name).tag(MetadataChoice.record(record.instanceID))
            }
            Divider()
            Text("New…").tag(MetadataChoice.new)
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Tags

    private func tagRow(_ instanceID: UUID, path: String) -> some View {
        let checked = document.tagIDs.contains(instanceID)
        return Button {
            model.edit(.tag(instanceID, !checked), of: document.instanceID)
        } label: {
            HStack {
                Text(verbatim: path)
                    .foregroundStyle(.primary)
                Spacer()
                if checked {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(checked ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.infoTag(instanceID))
    }

    // MARK: New metadata

    private func askForName(_ kind: MetadataKind) {
        newName = ""
        newKind = kind
    }

    private var isAskingForName: Binding<Bool> {
        Binding(get: { newKind != nil }, set: { if !$0 { newKind = nil } })
    }

    private var newKindTitle: Text {
        switch newKind {
        case .correspondent: Text("New Correspondent")
        case .documentType: Text("New Document Type")
        case .tag, nil: Text("New Tag")
        }
    }
}

/// The info panel's title field: the text, the document it belongs to, and the title it started from.
///
/// Only a draft the user changed is saved. An untouched draft can be older than the store (a rename from the
/// other device that the library has not read yet), and saving it would revert that rename (review A of #57).
/// An untouched draft follows the document's title when the library reads a new one; a changed draft is kept.
struct TitleDraft: Equatable {
    /// The document the draft belongs to: a changed draft is saved to it even when the selection has moved on.
    private(set) var document: UUID?
    /// What the field shows and the user types.
    var text = ""
    /// The title the draft started from, or the one last saved from it.
    private(set) var base = ""

    /// The panel shows `document`: the draft starts from its title.
    mutating func show(_ document: UUID, title: String) {
        self.document = document
        text = title
        base = title
    }

    /// Whether the user changed the text since the draft started or was last saved.
    var isChanged: Bool { text != base }

    /// The library read a new title for the document: an untouched draft follows it.
    mutating func titleChanged(to title: String) {
        guard text == base else { return }
        text = title
        base = title
    }

    /// The title to save and its document, if the user changed the draft; the draft then counts as saved.
    /// `LibraryModel.commitTitle` starts it again from the stored title when the edit is not saved.
    mutating func commit() -> (document: UUID, title: String)? {
        guard let document, text != base else { return nil }
        base = text
        return (document, text)
    }
}
