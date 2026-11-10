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
        let changes = AsyncStream<Void> { _ in }

        func snapshot() -> LibrarySnapshot { LibrarySnapshot(documents: documents) }

        nonisolated func loadPDF(instanceID: UUID) async -> PDFLoadState { .noDocument }
    }

    /// The Mac list's row layout (#72), hosted in a window as in the library window: the list in the content column
    /// of a `NavigationSplitView`.
    @MainActor
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
                Self.rows(in: window).allSatisfy { $0.row.frame.height >= $0.content.frame.height }
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
