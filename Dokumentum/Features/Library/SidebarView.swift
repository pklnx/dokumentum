import DokumentumCore
import DokumentumKit
import SwiftUI

/// The sidebar (PQ2): Library (Inbox, All Documents), then Tags, Correspondents and Document Types,
/// each row with its count, and Trash at the bottom (part 4 of #3).
struct SidebarView: View {
    @Bindable var model: LibraryModel
    /// Where the footer's sync line comes from (#31); no footer for `nil`.
    var syncStatus: SyncStatusSource?

    var body: some View {
        List(selection: $model.selection) {
            Section("Library") {
                row(.inbox, title: Text("Inbox"), symbol: "tray")
                row(.all, title: Text("All Documents"), symbol: "doc.on.doc")
            }
            if !model.tree.roots.isEmpty {
                Section("Tags") {
                    TagTreeRows(model: model)
                }
            }
            if !model.snapshot.correspondents.isEmpty {
                Section("Correspondents") {
                    ForEach(sortedByName(model.snapshot.correspondents), id: \.instanceID) { correspondent in
                        row(
                            .correspondent(correspondent.instanceID), title: Text(verbatim: correspondent.name),
                            symbol: "person")
                    }
                }
            }
            if !model.snapshot.documentTypes.isEmpty {
                Section("Document Types") {
                    ForEach(sortedByName(model.snapshot.documentTypes), id: \.instanceID) { type in
                        row(.documentType(type.instanceID), title: Text(verbatim: type.name), symbol: "doc.text")
                    }
                }
            }
            Section {
                row(.trash, title: Text("Trash"), symbol: "trash")
            }
        }
        // On the list itself, before the footer: an identifier after it would also replace the footer's
        // own (measured on macOS, #44).
        .accessibilityIdentifier(AccessibilityID.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let syncStatus {
                SyncStatusFooter(source: syncStatus)
            }
        }
        #if DEBUG && os(iOS)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    DebugToolbarMenu()
                }
            }
        #endif
        .navigationTitle("Dokumentum")
        #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        #endif
    }

    // On the Mac not a `NavigationLink`, as the tag rows (`TagTreeRows`): a link becomes a button there that
    // exposes the title but not the count to VoiceOver (measured on #46 and #53, also with the value on the link).
    // The tagged label keeps its own value ("3 documents"), and the sidebar's `List(selection:)` selects it the
    // same way. On the iPhone the link stays, for the row's disclosure indicator; it exposes the value.
    // The label is a button to VoiceOver, so it needs the button's action: activating it selects the row, as a
    // click does (the Mac audit's "Action is missing", review of #74, finding 2).
    @ViewBuilder
    private func row(_ selection: LibrarySelection, title: Text, symbol: String) -> some View {
        let label = SidebarRowLabel(title: title, symbol: symbol, count: model.counts.count(for: selection))
        #if os(macOS)
            label
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.selection = selection }
                .accessibilityIdentifier(AccessibilityID.sidebarRow(selection))
                .tag(selection)
        #else
            NavigationLink(value: selection) {
                label
            }
            .accessibilityIdentifier(AccessibilityID.sidebarRow(selection))
        #endif
    }

    private func sortedByName(_ references: [LibraryDocument.Reference]) -> [LibraryDocument.Reference] {
        references.sorted { lhs, rhs in
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.instanceID.uuidString < rhs.instanceID.uuidString
            }
        }
    }
}

/// A sidebar row's content: symbol, name and count. VoiceOver reads "Inbox, 3 documents".
struct SidebarRowLabel: View {
    let title: Text
    let symbol: String
    let count: Int
    var accessibilityTitle: Text?

    var body: some View {
        HStack {
            Label {
                title.lineLimit(1)
            } icon: {
                Image(systemName: symbol)
            }
            Spacer(minLength: 4)
            if count > 0 {
                Text(count, format: .number)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle ?? title)
        .accessibilityValue(Text("\(count) documents"))
    }
}
