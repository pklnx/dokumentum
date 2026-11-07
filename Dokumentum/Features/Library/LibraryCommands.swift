import SwiftUI

/// The Mac's "Go" menu: Inbox (⌘1) and All Documents (⌘2) for the focused window. Later parts of #3
/// add their commands where their actions are (PQ15).
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
        }
    }
}
