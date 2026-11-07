import DokumentumKit
import SwiftUI

/// The sidebar's tag tree: a flat list of rows indented by depth, with a chevron button on each tag
/// that has nested tags, on the Mac and on the iPhone (PQ3). A `DisclosureGroup` is not used: on iOS
/// its label toggles the group instead of selecting the tag (the predecessor's `TagTreeRow`). The
/// chevrons on the iPhone are new; the predecessor had none there.
struct TagTreeRows: View {
    let model: LibraryModel

    var body: some View {
        ForEach(model.tree.visibleRows(expanded: model.expandedTags)) { row in
            TagTreeRow(model: model, row: row)
        }
    }
}

private struct TagTreeRow: View {
    let model: LibraryModel
    let row: TagTree.Row

    private var id: UUID { row.tag.instanceID }
    private var isExpanded: Bool { model.expandedTags.contains(id) }
    private var path: String { model.tree.displayPath(of: id) }

    // On the Mac not a `NavigationLink`: a link makes the whole row one accessibility element there,
    // and the chevron inside it can no longer be reached. The row is tagged instead, which the
    // sidebar's `List(selection:)` selects the same way. On the iPhone the link stays, for the row's
    // disclosure indicator like the other sidebar rows; the chevron is a plain button that takes only
    // its own taps (checked by `LibrarySmokeTests`).
    var body: some View {
        #if os(macOS)
        content
            .tag(LibrarySelection.tag(id))
        #else
        NavigationLink(value: LibrarySelection.tag(id)) {
            content
        }
        #endif
    }

    private var content: some View {
        HStack(spacing: 2) {
            chevron
            SidebarRowLabel(
                title: Text(verbatim: row.tag.name), symbol: "tag", count: model.counts.count(for: .tag(id)),
                accessibilityTitle: Text(verbatim: path)
            )
            .accessibilityActions {
                if row.hasChildren {
                    Button(isExpanded ? "Collapse" : "Expand") { toggle() }
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(AccessibilityID.sidebarRow(.tag(id)))
        }
        .padding(.leading, CGFloat(row.depth) * 14)
    }

    /// Expands or collapses the nested tags. An empty space of the same width on tags without nested
    /// tags, so the names line up.
    @ViewBuilder
    private var chevron: some View {
        if row.hasChildren {
            Button {
                withAnimation { toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            // Plain: the button takes only its own taps, not the row's selection, and keeps no accent
            // tint on a selected row.
            .buttonStyle(.plain)
            .accessibilityLabel(
                isExpanded ? Text("Collapse \(row.tag.name)") : Text("Expand \(row.tag.name)"))
            .accessibilityValue(isExpanded ? Text("expanded") : Text("collapsed"))
            .accessibilityIdentifier(AccessibilityID.tagDisclosure(id))
        } else {
            Color.clear
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        }
    }

    private func toggle() {
        model.toggleExpanded(id)
    }
}
