import SwiftUI

/// The Mac's "Go" menu: Inbox (⌘1), All Documents (⌘2), Trash (⌘3) and Deadlines (⌘4, #12 part 2a: after Trash, so the
/// shortcuts stay in order; its place goes to the maintainer's string check), "Document": Show Info (⌘I), and Edit ›
/// Find… (⌘F), which puts the focus into the search field (#7, part 3, P7), for the focused window (PQ15). `.searchable`
/// in the toolbar adds no Find item and does not answer ⌘F by itself (measured on macOS 27 for #123: the Edit menu had
/// no Find item, and ⌘F left the field without focus). The trash's commands are in `TrashCommands`, import's in `ImportCommands`. Each item is
/// disabled when it has nothing to act on: Go without a library window, Show Info without an open document.
struct LibraryCommands: Commands {
    @FocusedValue(\.libraryModel) private var model

    var body: some Commands {
        CommandMenu("Go") {
            Button("Inbox") { model?.selection = .inbox }
                .keyboardShortcut("1")
                .disabled(model == nil)
            Button("All Documents") { model?.selection = .all }
                .keyboardShortcut("2")
                .disabled(model == nil)
            Button("Trash") { model?.selection = .trash }
                .keyboardShortcut("3")
                .disabled(model == nil)
            Button("Deadlines") { model?.selection = .upcoming }
                .keyboardShortcut("4")
                .disabled(model == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { model?.focusSearch() }
                .keyboardShortcut("f")
                .disabled(model == nil)
        }
        CommandMenu("Document") {
            Button {
                model?.isInfoPresented.toggle()
            } label: {
                model?.isInfoPresented == true ? Text("Hide Info") : Text("Show Info")
            }
            .keyboardShortcut("i")
            .disabled(model?.selectedDocument == nil)
        }
    }
}
