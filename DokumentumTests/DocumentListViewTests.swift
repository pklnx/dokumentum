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

    /// The Mac list's row layout (#72, #80, #81), hosted in a window as in the library window: the list in the content
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

            // Document 1 is the oldest, so the list shows Document 3, 2, 1 from the top. Each title wraps, so a row is
            // taller than its thumbnail (56 pt, #6 part 4) with and without the tag line, and the tag line changes its
            // height.
            let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
            let documents = (0..<3).map { index in
                let date = start.addingTimeInterval(Double(index) * 60)
                return LibraryDocument(
                    instanceID: UUID(), title: "\(Self.longTitle) \(index + 1)", documentDate: date, createdAt: date,
                    isInbox: arrival == .insertedOnTop || index == 0, tagIDs: tagRemoved ? [tag.instanceID] : [])
            }
            try await show(documents, arrival: arrival, source: source, model: model, window: window)
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

        /// How the list column's width changes (#81).
        enum WidthChange: String, CaseIterable, CustomTestStringConvertible {
            /// 320 → 700 pt: the long title goes from two lines to one.
            case wider
            /// 700 → 270 pt: the long title goes from one line to two.
            case narrower

            var start: CGFloat { self == .wider ? 320 : 700 }
            var end: CGFloat { self == .wider ? 700 : 270 }

            var testDescription: String {
                switch self {
                case .wider: "wider, 320 → 700 pt"
                case .narrower: "narrower, 700 → 270 pt"
                }
            }
        }

        /// A title that wraps at 270 and 320 pt and fits on one line at 700 pt.
        private static let longTitle = "Annual statement of the company pension fund for 2026"

        /// The tag of the width tests' rows: its line makes a row with a one-line title taller than the row's
        /// thumbnail (a fixed 56 pt, #6 part 4), so a title that wraps or unwraps changes the row's height.
        private static let tag = TagRecord(instanceID: UUID(), parentInstanceID: nil, name: "Tax")

        /// A row inserted while the list is shown takes the height its content needs when the list column gets wider
        /// or narrower. Before #81 the table kept the height the row had when it was inserted: wider left a gap
        /// (61 pt for 45 pt of content), narrower cut the title's second line (45 pt for 61 pt).
        @Test(arguments: Arrival.allCases, WidthChange.allCases)
        func rowsInsertedWhileShownFollowTheListWidth(_ arrival: Arrival, _ change: WidthChange) async throws {
            let source = ListSource()
            let model = LibraryModel(source: source)
            let window = try hostedWindow(
                NavigationSplitView {
                    Text(verbatim: "Sidebar")
                } content: {
                    DocumentListView(model: model)
                } detail: {
                    Text(verbatim: "Detail")
                }, width: 1100)
            defer { window.close() }
            let visible = try await TestSupport.waitUntil(
                "the test window is not visible, so the table would measure every row"
            ) { window.occlusionState.contains(.visible) }
            try #require(visible)
            try #require(try await setListWidth(change.start, in: window))

            // The list shows the titles from the top: "Insurance policy renewal", the long one, "Lease".
            source.tags = [Self.tag]
            let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
            let documents = ["Lease", Self.longTitle, "Insurance policy renewal"].enumerated().map { index, title in
                let date = start.addingTimeInterval(Double(index) * 60)
                return LibraryDocument(
                    instanceID: UUID(), title: title, documentDate: date, createdAt: date,
                    isInbox: arrival == .insertedOnTop || index == 0, tagIDs: [Self.tag.instanceID])
            }
            try await show(documents, arrival: arrival, source: source, model: model, window: window)
            // Every row laid out at its real height, and the long title on two lines at the start width when the
            // column gets wider, on one when it gets narrower: otherwise the change below changes no row's height.
            let settled = try await TestSupport.waitUntil("the three rows do not settle at their content's height") {
                let rows = Self.rows(in: window)
                guard rows.count == 3,
                    rows.allSatisfy({ $0.row.frame.height == $0.content.frame.height && $0.content.frame.height > 24 })
                else { return false }
                let heights = rows.map(\.content.frame.height)
                return change == .wider
                    ? heights[1] > heights[0] && heights[1] > heights[2]
                    : heights[1] == heights[0] && heights[1] == heights[2]
            }
            try #require(settled)
            let before = Self.rows(in: window)[1].content.frame.height

            try #require(try await setListWidth(change.end, in: window))
            // The signal that the table took the new width for the long row: its cell has its new height.
            let changed = try await TestSupport.waitUntil("the middle row's cell does not change its height") {
                let rows = Self.rows(in: window)
                guard rows.count == 3 else { return false }
                let after = rows[1].content.frame.height
                return change == .wider ? after < before : after > before
            }
            try #require(changed)

            let fits = try await TestSupport.waitUntil("a row is not as tall as its content") {
                let rows = Self.rows(in: window)
                return rows.count == 3 && rows.allSatisfy { $0.row.frame.height == $0.content.frame.height }
            }
            if !fits {
                let heights = Self.rows(in: window).map { "\($0.row.frame.height)/\($0.content.frame.height)" }
                Issue.record("row/cell heights: \(heights)")
            }
        }

        /// A width change keeps the scroll position, the selection and the info panel: the fix for #81 replaces only
        /// the rows whose height changes, it does not rebuild the list.
        @Test func aWidthChangeKeepsTheScrollPositionAndTheSelection() async throws {
            let source = ListSource()
            let model = LibraryModel(source: source)
            let window = try hostedWindow(
                NavigationSplitView {
                    Text(verbatim: "Sidebar")
                } content: {
                    DocumentListView(model: model)
                } detail: {
                    Text(verbatim: "Detail")
                }, width: 1100)
            defer { window.close() }
            let visible = try await TestSupport.waitUntil(
                "the test window is not visible, so the table would measure every row"
            ) { window.occlusionState.contains(.visible) }
            try #require(visible)
            try #require(try await setListWidth(320, in: window))

            // 60 documents, inserted on top one per update; every third has the long title. Row r shows document
            // index 59 - r, so rows 0, 3, …, 39, … have the long title. Each has the tag line (`tag`).
            source.tags = [Self.tag]
            let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
            for index in 0..<60 {
                let date = start.addingTimeInterval(Double(index) * 60)
                source.documents.append(
                    LibraryDocument(
                        instanceID: UUID(), title: index % 3 == 2 ? Self.longTitle : "Document \(index + 1)",
                        documentDate: date, createdAt: date, isInbox: true, tagIDs: [Self.tag.instanceID]))
                model.reload()
                try await TestSupport.waitUntil("the list does not have \(index + 1) rows") {
                    Self.table(in: window)?.numberOfRows == index + 1
                }
            }

            let selectedRow = 39
            try #require(model.documents[selectedRow].title == Self.longTitle)
            try #require(Self.table(in: window)).scrollRowToVisible(42)
            model.selectedDocumentID = model.documents[selectedRow].instanceID
            model.isInfoPresented = true
            let settled = try await TestSupport.waitUntil("the selected row is not shown at its content's height") {
                guard let table = Self.table(in: window), table.selectedRow == selectedRow,
                    table.rows(in: table.visibleRect).contains(selectedRow)
                else { return false }
                let rows = Self.rows(in: window)
                return !rows.isEmpty
                    && rows.allSatisfy {
                        $0.row.frame.height == $0.content.frame.height && $0.content.frame.height > 24
                    }
            }
            try #require(settled)
            let table = try #require(Self.table(in: window))
            let scrollY = try #require(table.enclosingScrollView).contentView.bounds.origin.y
            let selectedID = model.selectedDocumentID
            let before = try #require(table.view(atColumn: 0, row: selectedRow, makeIfNecessary: false)).frame.height
            try #require(scrollY > 0, "the table is scrolled")

            try #require(try await setListWidth(700, in: window))
            // The signal that the table took the new width: the selected row's long title is on one line.
            let changed = try await TestSupport.waitUntil("the selected row's cell does not change its height") {
                guard let table = Self.table(in: window), table.numberOfRows == 60,
                    let cell = table.view(atColumn: 0, row: selectedRow, makeIfNecessary: false)
                else { return false }
                return cell.frame.height < before
            }
            try #require(changed)
            let fits = try await TestSupport.waitUntil("a shown row is not as tall as its content") {
                let rows = Self.rows(in: window)
                return !rows.isEmpty && rows.allSatisfy { $0.row.frame.height == $0.content.frame.height }
            }
            if !fits {
                let heights = Self.rows(in: window).map { "\($0.row.frame.height)/\($0.content.frame.height)" }
                Issue.record("row/cell heights: \(heights)")
            }

            let after = try #require(Self.table(in: window))
            #expect(after.enclosingScrollView?.contentView.bounds.origin.y == scrollY)
            #expect(after.selectedRow == selectedRow)
            #expect(model.selectedDocumentID == selectedID)
            #expect(model.isInfoPresented)
        }

        /// Many rows inserted on top while the list is shown, all with the long title, take their new height when the
        /// list column gets wider step by step, as a divider drag does. All of them need a new height at the same
        /// step; replaced all in one update, some of them kept their old height (61 pt for 45 pt, measured on #81).
        /// That showed on a busy Mac: on an idle one the rows took their height also when replaced all at once.
        @Test func manyRowsInsertedWhileShownFollowTheListWidth() async throws {
            let source = ListSource()
            let model = LibraryModel(source: source)
            let window = try hostedWindow(
                NavigationSplitView {
                    Text(verbatim: "Sidebar")
                } content: {
                    DocumentListView(model: model)
                } detail: {
                    Text(verbatim: "Detail")
                }, width: 1100, height: 900)
            defer { window.close() }
            let visible = try await TestSupport.waitUntil(
                "the test window is not visible, so the table would measure every row"
            ) { window.occlusionState.contains(.visible) }
            try #require(visible)
            try #require(try await setListWidth(320, in: window))

            // 3000 older documents loaded at once, every third with the long title, so the new rows go in above shown
            // ones. Each has the tag line (`tag`).
            source.tags = [Self.tag]
            let base = 3000
            let older = Date(timeIntervalSinceReferenceDate: 700_000_000)
            source.documents = (0..<base).map { index in
                let date = older.addingTimeInterval(Double(index) * 60)
                return LibraryDocument(
                    instanceID: UUID(), title: index % 3 == 0 ? Self.longTitle : "Document \(index + 1)",
                    documentDate: date, createdAt: date, isInbox: true, tagIDs: [Self.tag.instanceID])
            }
            model.reload()
            try await TestSupport.waitUntil("the list does not have \(base) rows") {
                Self.table(in: window)?.numberOfRows == base
            }
            let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
            for index in 0..<30 {
                let date = start.addingTimeInterval(Double(index) * 60)
                source.documents.append(
                    LibraryDocument(
                        instanceID: UUID(), title: Self.longTitle, documentDate: date, createdAt: date, isInbox: true,
                        tagIDs: [Self.tag.instanceID]))
                model.reload()
                try await TestSupport.waitUntil("the list does not have \(base + index + 1) rows") {
                    Self.table(in: window)?.numberOfRows == base + index + 1
                }
                window.displayIfNeeded()
            }
            // The new rows (all shown rows of a 900 pt window) laid out with the title on two lines.
            let settled = try await TestSupport.waitUntil("the new rows do not settle at their two-line height") {
                let rows = Self.rows(in: window)
                return rows.count > 10 && rows.allSatisfy { $0.row.frame.height == $0.content.frame.height }
                    && rows.prefix(10).allSatisfy { $0.content.frame.height > 50 }
            }
            try #require(settled)
            let before = Self.rows(in: window)[0].content.frame.height

            // A drag: steps of 10 pt, 320 → 700 pt, each laid out and drawn before the next.
            for step in 1...29 {
                try moveDivider(toListWidth: 320 + CGFloat(step) * 10, in: window)
                window.displayIfNeeded()
            }
            try #require(try await setListWidth(610, in: window))
            // The signal that the titles are on one line: the top row's cell is smaller.
            let changed = try await TestSupport.waitUntil("the top row's cell does not change its height") {
                Self.rows(in: window).first.map { $0.content.frame.height < before } ?? false
            }
            try #require(changed)
            let fits = try await TestSupport.waitUntil("a shown row is not as tall as its content") {
                let rows = Self.rows(in: window)
                return rows.count > 10 && rows.allSatisfy { $0.row.frame.height == $0.content.frame.height }
            }
            if !fits {
                let heights = Self.rows(in: window).map { "\($0.row.frame.height)/\($0.content.frame.height)" }
                Issue.record("row/cell heights: \(heights)")
            }
        }

        /// Brings `documents` (oldest first) into the list as `arrival` says.
        private func show(
            _ documents: [LibraryDocument], arrival: Arrival, source: ListSource, model: LibraryModel,
            window: NSWindow
        ) async throws {
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
        }

        // MARK: Hosting

        /// A window on the first screen (the one with the menu bar), in front, so its table lays out as a shown one.
        private func hostedWindow(_ view: some View, width: CGFloat = 900, height: CGFloat = 500) throws -> NSWindow {
            let screen = try #require(NSScreen.screens.first, "the test host has a screen")
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40))
            window.orderFrontRegardless()
            return window
        }

        /// Moves the divider after the list's column so that the list's table is `width` wide, and waits until it is.
        private func setListWidth(_ width: CGFloat, in window: NSWindow) async throws -> Bool {
            try moveDivider(toListWidth: width, in: window)
            return try await TestSupport.waitUntil("the list's table does not get \(width) pt wide") {
                Self.table(in: window).map { abs($0.frame.width - width) < 0.5 } ?? false
            }
        }

        /// Moves the divider after the list's column so that the list's table gets `width` wide.
        private func moveDivider(toListWidth width: CGFloat, in window: NSWindow) throws {
            let table = try #require(Self.table(in: window), "the window shows the list")
            // The split view's column that holds the table, and the split view.
            var column: NSView = table
            while let parent = column.superview, !((parent as? NSSplitView)?.arrangedSubviews.contains(column) ?? false)
            {
                column = parent
            }
            let split = try #require(column.superview as? NSSplitView, "the list is in a split view's column")
            let index = try #require(split.arrangedSubviews.firstIndex(of: column))
            split.setPosition(column.frame.maxX + (width - table.frame.width), ofDividerAt: index)
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

        private static func table(in window: NSWindow) -> NSTableView? {
            window.contentView.flatMap(table(in:))
        }

        private static func table(in view: NSView) -> NSTableView? {
            (view as? NSTableView) ?? view.subviews.lazy.compactMap { table(in: $0) }.first
        }
    }
#endif
