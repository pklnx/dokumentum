#if DEBUG
    import SwiftUI

    // Where the Sync lab opens (plan of #31, Approach 3): on the Mac from Debug › Sync Lab… in a window of its own
    // (`DokumentumApp`), on the iPhone from the sidebar's debug toolbar menu as a sheet. Debug builds only.

    /// The Mac's Sync lab window.
    enum SyncLabWindow {
        static let id = "syncLab"
    }

    /// Opens the Sync lab sheet: an action equal to every other, as `AddSampleDocumentsAction`.
    struct ShowSyncLabAction: Equatable {
        let run: @MainActor () -> Void

        @MainActor func callAsFunction() { run() }

        static func == (lhs: Self, rhs: Self) -> Bool { true }
    }

    extension EnvironmentValues {
        /// `nil` outside a library window, and without a lab.
        @Entry var showSyncLab: ShowSyncLabAction?
    }

    /// Offers the lab sheet to the window's views (the iPhone's debug toolbar menu). The lab comes from the
    /// environment (`DokumentumApp`).
    struct SyncLabPresenter: ViewModifier {
        @Environment(SyncLab.self) private var lab: SyncLab?
        @State private var isPresented = false

        func body(content: Content) -> some View {
            content
                .environment(\.showSyncLab, lab == nil ? nil : ShowSyncLabAction { isPresented = true })
                .sheet(isPresented: $isPresented) {
                    if let lab { SyncLabView(lab: lab) }
                }
        }
    }
#endif
