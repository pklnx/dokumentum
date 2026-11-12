#if DEBUG
    import DokumentumCore
    import SwiftData
    import SwiftUI

    // The debug command "Add Sample Documents" (plan of #3, part 2): the Mac's Debug menu and a toolbar
    // menu in the iPhone's sidebar. Debug builds only; its texts are English and `verbatim`, outside the
    // catalog.

    /// Asks to add the sample documents to the window's store. Equal to every other: the action of a
    /// window never changes, so a new closure must not invalidate the views that read it.
    struct AddSampleDocumentsAction: Equatable {
        let run: @MainActor () -> Void

        @MainActor func callAsFunction() { run() }

        static func == (lhs: Self, rhs: Self) -> Bool { true }
    }

    extension EnvironmentValues {
        /// `nil` outside a library window.
        @Entry var addSampleDocuments: AddSampleDocumentsAction?
    }

    extension FocusedValues {
        /// The focused window's `addSampleDocuments`, for the Mac's Debug menu.
        @Entry var addSampleDocuments: AddSampleDocumentsAction?
    }

    /// Offers the command to the window's views and menus. A store that syncs gets a confirmation first: a
    /// Debug build talks to CloudKit Development only, and the data is synthetic (#2, P2).
    struct SampleDocumentsCommand: ViewModifier {
        @Environment(\.modelContext) private var context
        @State private var isConfirming = false

        /// Whether the store syncs, so the command asks first.
        let asksFirst: Bool

        func body(content: Content) -> some View {
            content
                .environment(\.addSampleDocuments, AddSampleDocumentsAction(run: request))
                .focusedSceneValue(\.addSampleDocuments, AddSampleDocumentsAction(run: request))
                .confirmationDialog(
                    Text(verbatim: "Add sample documents to the synced store?"), isPresented: $isConfirming
                ) {
                    Button(action: add) { Text(verbatim: "Add Sample Documents") }
                    Button(role: .cancel) {
                    } label: {
                        Text(verbatim: "Cancel")
                    }
                } message: {
                    Text(
                        verbatim:
                            "They sync to CloudKit Development with this device's iCloud account. The data is synthetic."
                    )
                }
        }

        private func request() {
            if asksFirst { isConfirming = true } else { add() }
        }

        private func add() {
            do {
                let added = try FixtureSeeder.addSampleDocuments(to: context)
                Log.store.notice("Added \(added, privacy: .public) sample documents")
            } catch {
                Log.store.error("Could not add the sample documents: \(Log.code(of: error), privacy: .public)")
            }
        }
    }

    /// The iPhone sidebar's toolbar menu.
    struct DebugToolbarMenu: View {
        @Environment(\.addSampleDocuments) private var addSampleDocuments

        var body: some View {
            Menu {
                Button {
                    addSampleDocuments?()
                } label: {
                    Text(verbatim: "Add Sample Documents")
                }
                .accessibilityIdentifier(AccessibilityID.debugAddSampleDocuments)
                .disabled(addSampleDocuments == nil)
            } label: {
                Label {
                    Text(verbatim: "Debug")
                } icon: {
                    Image(systemName: "ladybug")
                }
            }
            .accessibilityIdentifier(AccessibilityID.debugMenu)
        }
    }

    /// The Mac's Debug menu.
    struct DebugCommands: Commands {
        @FocusedValue(\.addSampleDocuments) private var addSampleDocuments
        @FocusedValue(\.runSearchBenchmark) private var runSearchBenchmark

        var body: some Commands {
            CommandMenu(Text(verbatim: "Debug")) {
                Button {
                    addSampleDocuments?()
                } label: {
                    Text(verbatim: "Add Sample Documents")
                }
                .disabled(addSampleDocuments == nil)
                // The search benchmark (#7, part 2) on its own in-memory store, never the window's.
                Button {
                    runSearchBenchmark?()
                } label: {
                    Text(verbatim: "Run Search Benchmark")
                }
                .disabled(runSearchBenchmark == nil)
            }
        }
    }
#endif
