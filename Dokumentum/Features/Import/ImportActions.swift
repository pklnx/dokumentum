import SwiftUI

/// Opens the window's files picker, its Photos picker or the document camera. Equal to every other: a
/// window's actions never change, so a new closure must not invalidate the views and menus that read it.
struct ImportActions: Equatable {
    let pickFiles: @MainActor () -> Void
    let pickPhotos: @MainActor () -> Void
    /// Opens the document camera; `nil` where there is none (the Mac, a device VisionKit does not support).
    let scan: (@MainActor () -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
    /// `nil` outside a library window.
    @Entry var importActions: ImportActions?
}

extension FocusedValues {
    /// The focused window's import actions, for File › Import Documents… (⌘O).
    @Entry var importActions: ImportActions?
}

/// The "+" menu in the list's toolbar, on both devices (PQ7): "Scan…" first where there is a document camera
/// (#5, part 2, P4), then "Files…" and "Photos…".
struct ImportToolbarMenu: View {
    @Environment(\.importActions) private var actions

    var body: some View {
        Menu {
            if let scan = actions?.scan {
                Button {
                    scan()
                } label: {
                    Label("Scan…", systemImage: "doc.viewfinder")
                }
                .accessibilityIdentifier(AccessibilityID.importScan)
            }
            Button {
                actions?.pickFiles()
            } label: {
                Label("Files…", systemImage: "folder")
            }
            .accessibilityIdentifier(AccessibilityID.importFiles)
            .disabled(actions == nil)
            Button {
                actions?.pickPhotos()
            } label: {
                Label("Photos…", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier(AccessibilityID.importPhotos)
            .disabled(actions == nil)
        } label: {
            Label("Import", systemImage: "plus")
        }
        .accessibilityIdentifier(AccessibilityID.importMenu)
    }
}

#if os(macOS)
    /// File › Import Documents… (⌘O), after New Window, for the focused window (PQ7). Disabled without one.
    struct ImportCommands: Commands {
        @FocusedValue(\.importActions) private var actions

        var body: some Commands {
            CommandGroup(after: .newItem) {
                Button("Import Documents…") { actions?.pickFiles() }
                    .keyboardShortcut("o")
                    .disabled(actions == nil)
            }
        }
    }
#endif
