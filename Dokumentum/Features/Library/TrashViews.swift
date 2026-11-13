import DokumentumCore
import DokumentumKit
import SwiftUI

// The trash in the library window (plan of #3, part 4): row actions, the Empty Trash button and its
// confirmation, and the bar over a trashed document's detail.

extension AccessibilityID {
    /// A row's "Move to Trash" and "Restore": in the context menu, and as swipe actions on the iPhone.
    static let rowMoveToTrash = "documentList.moveToTrash"
    static let rowRestore = "documentList.restore"
    static let rowSwipeMoveToTrash = "documentList.swipe.moveToTrash"
    static let rowSwipeRestore = "documentList.swipe.restore"

    /// The open document's menu on the iPhone, and its "Move to Trash".
    static let detailMenu = "documentDetail.menu"
    static let detailMoveToTrash = "documentDetail.moveToTrash"

    /// The trash list's toolbar button and the buttons of its confirmation.
    static let emptyTrash = "trash.empty"
    static let emptyTrashConfirm = "trash.empty.confirm"
    static let emptyTrashCancel = "trash.empty.cancel"

    /// The bar over a trashed document's detail, and its "Restore".
    static let detailTrashed = "documentDetail.trashed"
    static let detailRestore = "documentDetail.restore"
}

extension FocusedValues {
    /// The trash of the focused window, for the menu commands.
    @Entry var libraryTrash: LibraryTrash?
}

/// A row's trash actions: "Move to Trash", or "Restore" for a trashed document. In the context menu on both
/// devices, as a swipe action (a full swipe on the iPhone only), and as an accessibility action (PQ8: no
/// confirmation, it can be restored).
struct TrashRowActions: ViewModifier {
    @Environment(LibraryTrash.self) private var trash: LibraryTrash?
    let document: LibraryDocument

    func body(content: Content) -> some View {
        if let trash, trash.isAvailable {
            content
                .contextMenu {
                    button(
                        trash,
                        identifier: document.isTrashed ? AccessibilityID.rowRestore : AccessibilityID.rowMoveToTrash)
                }
                // A full swipe trashes only on the iPhone. On the Mac a trackpad swipe reveals the button and a click
                // trashes: a full swipe there is too easily made by accident (#70).
                .swipeActions(edge: .trailing, allowsFullSwipe: Self.allowsFullSwipe) {
                    button(
                        trash,
                        identifier: document.isTrashed
                            ? AccessibilityID.rowSwipeRestore : AccessibilityID.rowSwipeMoveToTrash
                    )
                    // White sits on the colour here, so the accent's fill role (#9, P4), not the tint.
                    .tint(document.isTrashed ? Color(.accentFill) : .red)
                }
                // The same action for VoiceOver and other assistive technologies, named as the button (plan of
                // #3, part 5): the row reads as one element (`DocumentRow`), so the swipe is no gesture they offer.
                .accessibilityActions {
                    if document.isTrashed {
                        Button("Restore") { trash.restore(document.instanceID) }
                    } else {
                        Button("Move to Trash") { trash.moveToTrash(document.instanceID) }
                    }
                }
        } else {
            content
        }
    }

    #if os(macOS)
        static let allowsFullSwipe = false
    #else
        static let allowsFullSwipe = true
    #endif

    private func button(_ trash: LibraryTrash, identifier: String) -> some View {
        Group {
            if document.isTrashed {
                Button {
                    trash.restore(document.instanceID)
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button(role: .destructive) {
                    trash.moveToTrash(document.instanceID)
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
        }
        .accessibilityIdentifier(identifier)
    }
}

/// The trash list's "Empty Trash…" button; disabled while the trash is empty.
struct EmptyTrashButton: View {
    @Environment(LibraryTrash.self) private var trash: LibraryTrash?

    var body: some View {
        if let trash, trash.isAvailable {
            Button {
                trash.requestEmptyTrash()
            } label: {
                Label("Empty Trash…", systemImage: "trash.slash")
            }
            .disabled(trash.trashCount == 0)
            .accessibilityIdentifier(AccessibilityID.emptyTrash)
        }
    }
}

/// Asks before Empty Trash deletes for good (PQ9), in an alert: the count the confirmation shows is the set it deletes.
struct EmptyTrashConfirmation: ViewModifier {
    @Bindable var trash: LibraryTrash

    func body(content: Content) -> some View {
        content
            // An alert, not a confirmation dialog: on the iPhone a dialog showed no Cancel button (measured on
            // iOS 27.0, #46), and an alert is the usual form for a delete that cannot be undone.
            .alert(
                Text("Permanently delete \(trash.pendingEmptyTrash?.count ?? 0) documents?"),
                isPresented: $trash.isConfirmingEmptyTrash
            ) {
                Button(role: .destructive) {
                    trash.confirmEmptyTrash()
                } label: {
                    Text("Empty Trash")
                }
                .accessibilityIdentifier(AccessibilityID.emptyTrashConfirm)
                // The system's label for a cancel button: no catalog entry of its own.
                Button(role: .cancel) {}
                    .accessibilityIdentifier(AccessibilityID.emptyTrashCancel)
            } message: {
                Text("This cannot be undone.")
            }
    }
}

/// The open document's menu in the iPhone's detail bar: "Move to Trash" (#70). The document leaves the shown
/// list, `LibraryModel` deselects it, and the stack goes back to the list. Not on a trashed document, whose bar
/// offers Restore, and not on the Mac, which has Edit › Move to Trash (⌘⌫) and the row's context menu.
struct DocumentDetailMenu: View {
    @Environment(LibraryTrash.self) private var trash: LibraryTrash?

    var body: some View {
        if let trash, trash.isAvailable, let document = trash.openDocument, !document.isTrashed {
            Menu {
                Button(role: .destructive) {
                    trash.moveToTrash(document.instanceID)
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .accessibilityIdentifier(AccessibilityID.detailMoveToTrash)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier(AccessibilityID.detailMenu)
        }
    }
}

/// Over the detail of a trashed document: it is in the trash, read only, and can be restored (PQ10).
struct TrashedDocumentBar: View {
    let trash: LibraryTrash

    var body: some View {
        if let document = trash.openDocument, let deletedAt = document.deletedAt {
            HStack(spacing: 12) {
                Label {
                    Text("In the Trash since \(deletedAt.formatted(date: .abbreviated, time: .omitted))")
                } icon: {
                    Image(systemName: "trash")
                }
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if trash.isAvailable {
                    Button("Restore") {
                        trash.restore(document.instanceID)
                    }
                    .accessibilityIdentifier(AccessibilityID.detailRestore)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.detailTrashed)
        }
    }
}
