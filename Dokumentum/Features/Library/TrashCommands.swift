#if os(macOS)
    import AppKit
    import DokumentumKit
    import SwiftUI

    /// The Mac's trash commands (plan of #3, part 4; PQ15): Edit › Move to Trash (⌘⌫) for the open document, and
    /// File › Empty Trash… (⌘⇧⌫), which asks first. Each is disabled when it has nothing to act on.
    struct TrashCommands: Commands {
        @FocusedValue(\.libraryTrash) private var trash

        /// The open document, unless it is in the trash already.
        private var movableDocument: LibraryDocument? {
            guard let trash, trash.isAvailable, let document = trash.openDocument, !document.isTrashed else {
                return nil
            }
            return document
        }

        var body: some Commands {
            CommandGroup(after: .pasteboard) {
                Button("Move to Trash") {
                    // ⌘⌫ deletes to the start of the line in a text field (part 3's title field): a menu
                    // shortcut would take the key from it and trash the document instead.
                    if let textView = CommandDeleteRouting.editingTextView(
                        firstResponder: NSApp.keyWindow?.firstResponder, event: NSApp.currentEvent)
                    {
                        CommandDeleteRouting.deleteToBeginningOfLine(in: textView)
                        return
                    }
                    guard let trash, let document = movableDocument else { return }
                    trash.moveToTrash(document.instanceID)
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(movableDocument == nil)
            }
            CommandGroup(after: .saveItem) {
                Button("Empty Trash…") { trash?.requestEmptyTrash() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(!(trash?.isAvailable ?? false) || (trash?.trashCount ?? 0) == 0)
            }
        }
    }

    /// Keeps ⌘⌫ with the text field that has the keyboard focus. AppKit offers a key equivalent to the menu
    /// before the focused text view sees it as a key press, so the menu item's action hands the key back.
    @MainActor enum CommandDeleteRouting {
        /// The editable text view (a text field's field editor, or a text editor) that should get ⌘⌫, when the
        /// command came from the keyboard; `nil` for a menu click or when no text has the focus.
        static func editingTextView(firstResponder: NSResponder?, event: NSEvent?) -> NSTextView? {
            guard let event, event.type == .keyDown,
                let textView = firstResponder as? NSTextView, textView.isEditable
            else { return nil }
            return textView
        }

        /// What ⌘⌫ does in a text view: delete from the insertion point to the start of the line.
        static func deleteToBeginningOfLine(in textView: NSTextView) {
            textView.doCommand(by: #selector(NSStandardKeyBindingResponding.deleteToBeginningOfLine(_:)))
        }
    }
#endif
