import DokumentumCore
import DokumentumKit
import SwiftUI

/// The sidebar (PQ2): Library (Inbox, All Documents), then Tags, Correspondents and Document Types,
/// each row with its count. Trash joins at the bottom in part 4 of #3.
struct SidebarView: View {
    @Bindable var model: LibraryModel
    /// The footer's "Sync off" reason; no footer for `nil`.
    var syncOff: StoreSyncOffReason?

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
        }
        // On the list itself, before the footer: an identifier after it would also replace the footer's
        // own (measured on macOS, #44).
        .accessibilityIdentifier(AccessibilityID.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let syncOff {
                SyncOffLine(reason: syncOff)
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

    private func row(_ selection: LibrarySelection, title: Text, symbol: String) -> some View {
        NavigationLink(value: selection) {
            SidebarRowLabel(title: title, symbol: symbol, count: model.counts.count(for: selection))
        }
        .accessibilityIdentifier(AccessibilityID.sidebarRow(selection))
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

/// The sidebar footer while the store does not sync (#2's P1 text "Sync off: <reason>"; reasons PQ13).
/// A CloudKit store shows nothing here until #31's sync status takes this place.
struct SyncOffLine: View {
    let reason: StoreSyncOffReason

    var body: some View {
        Label {
            Text("Sync off: \(reasonText)")
        } icon: {
            Image(systemName: "icloud.slash")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.syncOffLine)
    }

    private var reasonText: Text {
        switch reason {
        case .noICloudAccess: Text("this build has no iCloud access")
        case .sampleData: Text("sample data, not saved")
        case .cloudKitStoreFailed: Text("the iCloud store could not be opened")
        }
    }
}
