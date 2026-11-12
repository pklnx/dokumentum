#if DEBUG
    import DokumentumCore
    import Foundation
    import SwiftData

    /// `-UITestHoldSearchIndex YES` (Debug builds only, in-memory stores only; #7, part 3): the search index stops
    /// after its first text batch and stays `.building`, so a UI test sees the "Indexing texts…" line under the
    /// search field and audits it. The sample texts all fit in that first batch, so every search still finds them.
    enum UITestHoldSearchIndex {
        static let argument = "-UITestHoldSearchIndex"

        static func isRequested(for container: ModelContainer, arguments: [String]) -> Bool {
            arguments.contains(argument) && container.configurations.allSatisfy(\.isStoredInMemoryOnly)
        }

        /// The indexer's hooks for this launch: none unless requested.
        static func hooks(for container: ModelContainer, arguments: [String]) -> SearchIndexer.Hooks {
            guard isRequested(for: container, arguments: arguments) else { return SearchIndexer.Hooks() }
            return SearchIndexer.Hooks(afterBatch: { _ in
                // Never resumed: the build holds here until the app quits.
                for await _ in held.stream {}
            })
        }

        /// A stream that never yields or ends; its continuation is kept so it is never finished.
        private static let held = AsyncStream.makeStream(of: Void.self)
    }
#endif
