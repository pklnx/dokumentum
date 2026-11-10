#if DEBUG
    import DokumentumCore
    import Foundation
    import SwiftData

    /// `-UITestFailingSaves YES` (Debug builds, in-memory stores only): every save of the info panel's editor
    /// fails and is rolled back, as a store error would. The UI test of the "could not be saved" line uses it
    /// (plan of #3, part 5; maintainer decision on #74). Never with a store on disk.
    enum UITestFailingSaves {
        static let argument = "-UITestFailingSaves"

        struct InjectedFailure: Error {}

        /// Whether this launch asked for failing saves and `container` is in memory.
        static func isRequested(for container: ModelContainer, arguments: [String]) -> Bool {
            arguments.contains(argument) && container.configurations.allSatisfy(\.isStoredInMemoryOnly)
        }

        /// An editor whose saves fail.
        @MainActor
        static func editor(for container: ModelContainer) -> DocumentEditor {
            DocumentEditor(context: container.mainContext, save: { _ in throw InjectedFailure() })
        }
    }
#endif
