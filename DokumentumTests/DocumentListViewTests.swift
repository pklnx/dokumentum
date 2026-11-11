#if os(macOS)
    import AppKit
    import DokumentumKit
    import DokumentumTestSupport
    import Foundation
    import SwiftUI
    import Testing

    @testable import Dokumentum

    /// A source whose documents the test sets; the test reloads the model itself.
    @MainActor
    private final class ListSource: LibrarySource {
        var documents: [LibraryDocument] = []
        var tags: [TagRecord] = []
        let changes = AsyncStream<Void> { _ in }

        func snapshot() -> LibrarySnapshot { LibrarySnapshot(documents: documents, tags: tags) }

        nonisolated func loadPDF(instanceID: UUID) async -> PDFLoadState { .noDocument }
    }

    /// The Mac list's row layout (#72, #80), hosted in a window as in the library window: the list in the content
    /// column of a `NavigationSplitView`. The tests need a visible window, and they run one at a time: another test's
    /// window in front of theirs could occlude it.
    @MainActor @Suite(.serialized)
    struct DocumentListViewTests {
        /// Rows inserted above the shown ones, as an import does (newest first), are as tall as their title and date
        /// line. Before #72 the table kept them at its estimated row height, so the date line was cut off.
        ///
        /// Only a window on a visible screen shows it: in an occluded window the table measures every row.
        @Test func rowsInsertedAboveShownOnesAreAsTallAsTheirContent() async throws {
            let source = ListSource()
            let model = LibraryModel(source: source)
            let window = try hostedWindow(
                NavigationSplitView {
                    Text(verbatim: "Sidebar")
                } content: {
                    DocumentListView(model: model)
                } detail: {
                    Text(verbatim: "Detail")
                })
            defer { window.close() }
            let visible = try await TestSupport.waitUntil(
                "the test window is not visible, so the table would measure every row"
            ) { window.occlusionState.contains(.visible) }
            try #require(visible)

            let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
            for index in 0..<3 {
                let date = start.addingTimeInterval(Double(index) * 60)
                source.documents.append(
                    LibraryDocument(
                        instanceID: UUID(), title: "Document \(index + 1)", documentDate: date, createdAt: date,
                        isInbox: true))
                model.reload()
                // Each insert in its own update, as each import's save is: the newest row goes on top.
                try await TestSupport.waitUntil("the list does not show \(index + 1) rows") {
                    Self.rows(in: window).count == index + 1
                }
            }

            let fits = try await TestSupport.waitUntil("a row is shorter than its content") {
                let rows = Self.rows(in: window)
                return rows.count == 3 && rows.allSatisfy { $0.row.frame.height >= $0.content.frame.height }
            }
            if !fits {
                let heights = Self.rows(in: window).map { "\($0.row.frame.height)/\($0.content.frame.height)" }
                Issue.record("row/content heights: \(heights)")
            }
        }

        /// How the rows came into the list while it was shown.
        enum Arrival: String, CaseIterable, CustomTestStringConvertible {
            /// One per update, each above the shown ones, as an import does (newest first).
            case insertedOnTop
            /// Inbox (the oldest document) → All Documents: the two newer documents appear above it.
            case sidebarSwitch

            var testDescription: String {
                switch self {
                case .insertedOnTop: "inserted on top"
                case .sidebarSwitch: "sidebar switch"
                }
            }
        }

        /// A row inserted while the list is shown grows when a tag is added to it, so the tag line is not cut. Before #80
        /// the table kept the height the row had when it was inserted (45 pt for 63 pt of content).
        @Test(arguments: Arrival.allCases)
        func rowsInsertedWhileShownGrowWithTheirContent(_ arrival: Arrival) async throws {
            try await checkTheMiddleRowFollowsItsContent(arrival: arrival, tagRemoved: false)
        }

        /// A row inserted on top while the list is shown shrinks when its tag is removed, so no gap is left. Before #80
        /// the table kept the height the row had when it was inserted (63 pt for 45 pt of content).
        ///
        /// Only rows inserted on top: rows that a sidebar switch brings in shrank correctly before #80 too (measured in
        /// the PR for #80), so that case would pass without the fix.
        @Test func rowsInsertedWhileShownShrinkWithTheirContent() async throws {
            try await checkTheMiddleRowFollowsItsContent(arrival: .insertedOnTop, tagRemoved: true)
        }

        /// Shows three documents that arrive as `arrival` says, then adds a tag to the middle one or removes its tag,
        /// and requires every row to be exactly as tall as its content afterwards.
        private func checkTheMiddleRowFollowsItsContent(arrival: Arrival, tagRemoved: Bool) async throws {
            let tag = TagRecord(instanceID: UUID(), parentInstanceID: nil, name: "Tax")
            let source = ListSource()
            source.tags = [tag]
            let model = LibraryModel(source: source)
            let window = try hostedWindow(
                NavigationSplitView {
                    Text(verbatim: "Sidebar")
                } content: {
                    DocumentListView(model: model)
                } detail: {
                    Text(verbatim: "Detail")
                })
            defer { window.close() }
            let visible = try await TestSupport.waitUntil(
                "the test window is not visible, so the table would measure every row"
            ) { window.occlusionState.contains(.visible) }
            try #require(visible)

            // Document 1 is the oldest, so the list shows Document 3, 2, 1 from the top.
            let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
            let documents = (0..<3).map { index in
                let date = start.addingTimeInterval(Double(index) * 60)
                return LibraryDocument(
                    instanceID: UUID(), title: "Document \(index + 1)", documentDate: date, createdAt: date,
                    isInbox: arrival == .insertedOnTop || index == 0, tagIDs: tagRemoved ? [tag.instanceID] : [])
            }
            switch arrival {
            case .insertedOnTop:
                for (index, document) in documents.enumerated() {
                    source.documents.append(document)
                    model.reload()
                    // Each insert in its own update, as each import's save is: the newest row goes on top.
                    try await TestSupport.waitUntil("the list does not show \(index + 1) rows") {
                        Self.rows(in: window).count == index + 1
                    }
                }
            case .sidebarSwitch:
                source.documents = documents
                model.reload()
                try await TestSupport.waitUntil("the Inbox does not show its one row") {
                    Self.rows(in: window).count == 1
                }
                model.selection = .all
            }
            // Every row laid out at its real height: a cell not laid out yet reads as the 24 pt estimate, and noting
            // that height would make the wait for the change below pass on the layout instead of on the change.
            let settled = try await TestSupport.waitUntil("the three rows do not settle at their content's height") {
                let rows = Self.rows(in: window)
                return rows.count == 3
                    && rows.allSatisfy { row, content in
                        row.frame.height == content.frame.height && content.frame.height > 24
                    }
            }
            try #require(settled)
            let before = Self.rows(in: window)[1].content.frame.height

            source.documents[1].tagIDs = tagRemoved ? [] : [tag.instanceID]
            model.reload()
            // The signal that the change arrived: the middle row's content has its new height.
            let changed = try await TestSupport.waitUntil("the middle row's content does not change its height") {
                let rows = Self.rows(in: window)
                guard rows.count == 3 else { return false }
                let after = rows[1].content.frame.height
                return tagRemoved ? after < before : after > before
            }
            try #require(changed)

            let fits = try await TestSupport.waitUntil("a row is not as tall as its content") {
                let rows = Self.rows(in: window)
                return rows.count == 3 && rows.allSatisfy { $0.row.frame.height == $0.content.frame.height }
            }
            if !fits {
                let heights = Self.rows(in: window).map { "\($0.row.frame.height)/\($0.content.frame.height)" }
                Issue.record("row/content heights: \(heights)")
            }
        }

        // MARK: Hosting

        /// A window on the first screen (the one with the menu bar), in front, so its table lays out as a shown one.
        private func hostedWindow(_ view: some View) throws -> NSWindow {
            let screen = try #require(NSScreen.screens.first, "the test host has a screen")
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40))
            window.orderFrontRegardless()
            return window
        }

        /// Each shown row of the list's table and its content (the SwiftUI cell), top to bottom.
        private static func rows(in window: NSWindow) -> [(row: NSTableRowView, content: NSView)] {
            guard let table = window.contentView.flatMap(table(in:)) else { return [] }
            return (0..<table.numberOfRows).compactMap { index in
                guard let row = table.rowView(atRow: index, makeIfNecessary: false),
                    let content = table.view(atColumn: 0, row: index, makeIfNecessary: false)
                else { return nil }
                return (row, content)
            }
        }

        private static func table(in view: NSView) -> NSTableView? {
            (view as? NSTableView) ?? view.subviews.lazy.compactMap { table(in: $0) }.first
        }
    }
#endif
