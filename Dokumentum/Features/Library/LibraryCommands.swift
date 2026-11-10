import SwiftUI

/// The Mac's "Go" menu: Inbox (⌘1), All Documents (⌘2) and Trash (⌘3), and "Document": Show Info (⌘I), for the
/// focused window (PQ15). The trash's commands are in `TrashCommands`, import's in `ImportCommands`. Each item is
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
