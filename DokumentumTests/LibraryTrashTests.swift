import DokumentumCore
import DokumentumKit
import Foundation
import SwiftData
import Testing

@testable import Dokumentum

#if os(macOS)
    import AppKit
#endif

/// The window's trash actions on the sample store (plan of #3, part 4): what the list, the counts and the
/// selection do after a move, a restore and Empty Trash, and that Empty Trash deletes only what its
/// confirmation counted. In-memory stores only.
@MainActor
struct LibraryTrashTests {
    private typealias Fixtures = FixtureCatalog

    /// The sample library in a store, as a `-UITestSeed` launch has it.
    private func makeLibrary() throws -> (model: LibraryModel, trash: LibraryTrash, container: ModelContainer) {
        let container = try makeInMemoryContainer()
        try FixtureSeeder.write(into: container.mainContext, instanceIDs: .fixed)
        let model = LibraryModel(source: StoreLibrarySource(container: container))
        return (model, LibraryTrash(model: model), container)
    }

    private func ids(_ documents: [LibraryDocument]) -> [UUID] { documents.map(\.instanceID) }

    @Test func movingTheOpenDocumentRemovesItFromTheListAndDeselectsIt() throws {
        let (model, trash, _) = try makeLibrary()
        let electricity = Fixtures.documentID(1)
        model.selectedDocumentID = electricity
        #expect(trash.openDocument?.instanceID == electricity)
        #expect(model.counts.count(for: .trash) == 0)

        trash.moveToTrash(electricity)

        #expect(!ids(model.documents).contains(electricity), "still in the Inbox")
        #expect(model.selectedDocumentID == nil, "the open document stays selected")
        #expect(trash.openDocument == nil)
        #expect(model.counts.count(for: .inbox) == 4)
        #expect(model.counts.count(for: .all) == 8)
        #expect(model.counts.count(for: .trash) == 1)
        #expect(
            model.counts.count(for: .tag(Fixtures.tax.instanceID)) == 2, "the trashed document still counts for Tax")
        model.selection = .trash
        #expect(ids(model.documents) == [electricity])
        #expect(model.documents.first?.deletedAt != nil)
    }

    @Test func restoringBringsTheDocumentBackWithItsInboxStateAndMetadata() throws {
        let (model, trash, _) = try makeLibrary()
        let before = try #require(model.snapshot.documents.first { $0.instanceID == Fixtures.documentID(3) })
        #expect(before.isInbox == false)
        trash.moveToTrash(before.instanceID)
        model.selection = .trash
        model.selectedDocumentID = before.instanceID
        #expect(trash.openDocument?.isTrashed == true)

        trash.restore(before.instanceID)

        #expect(model.documents.isEmpty, "still in the trash")
        #expect(model.selectedDocumentID == nil, "the restored document stays open in the trash")
        let after = try #require(model.snapshot.documents.first { $0.instanceID == before.instanceID })
        #expect(after == before, "every listed value is as it was, the inbox state included")
        model.selection = .tag(Fixtures.tax.instanceID)
        #expect(ids(model.documents).contains(before.instanceID))
        #expect(model.counts.count(for: .trash) == 0)
    }

    @Test func emptyTrashDeletesWhatTheConfirmationCountedAndNothingElse() throws {
        let (model, trash, container) = try makeLibrary()
        let first = Fixtures.documentID(1)
        let second = Fixtures.documentID(4)
        let later = Fixtures.documentID(7)
        trash.moveToTrash(first)
        trash.moveToTrash(second)

        trash.requestEmptyTrash()
        #expect(trash.isConfirmingEmptyTrash)
        #expect(trash.pendingEmptyTrash == [first, second])
        // Trashed while the confirmation is open: not part of what it counted.
        trash.moveToTrash(later)
        trash.confirmEmptyTrash()

        #expect(!trash.isConfirmingEmptyTrash)
        #expect(model.counts.count(for: .trash) == 1)
        #expect(model.counts.count(for: .all) == 6)
        model.selection = .trash
        #expect(ids(model.documents) == [later])
        let stored = try ModelContext(container).fetch(FetchDescriptor<Document>()).map(\.instanceID)
        #expect(Set(stored) == Set((1...9).map(Fixtures.documentID)).subtracting([first, second]))
        #expect(
            try ModelContext(container).fetchCount(FetchDescriptor<DocumentFile>()) == 6,
            "8 samples have a file; 2 of them are gone")
    }

    @Test func cancellingTheConfirmationDeletesNothing() throws {
        let (model, trash, container) = try makeLibrary()
        trash.moveToTrash(Fixtures.documentID(1))
        trash.requestEmptyTrash()
        #expect(trash.isConfirmingEmptyTrash)

        trash.isConfirmingEmptyTrash = false
        trash.confirmEmptyTrash()

        #expect(trash.pendingEmptyTrash == nil)
        #expect(model.counts.count(for: .trash) == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Document>()) == 9)
    }

    @Test func anEmptyTrashAsksNothing() throws {
        let (_, trash, _) = try makeLibrary()
        trash.requestEmptyTrash()
        #expect(!trash.isConfirmingEmptyTrash)
        #expect(trash.trashCount == 0)
    }

    @Test func aSourceThatCannotWriteOffersNoTrash() {
        let model = LibraryModel(source: FixtureLibrarySource())
        let trash = LibraryTrash(model: model)
        #expect(!trash.isAvailable)
        trash.moveToTrash(Fixtures.documentID(1))
        trash.requestEmptyTrash()
        #expect(!trash.isConfirmingEmptyTrash)
        #expect(model.counts.count(for: .inbox) == 5)
    }

    /// A full swipe trashes only on the iPhone; on the Mac the swipe reveals the button, which a click trashes (#70).
    @Test func aFullSwipeTrashesOnlyOnTheIPhone() {
        #if os(macOS)
            #expect(!TrashRowActions.allowsFullSwipe)
        #else
            #expect(TrashRowActions.allowsFullSwipe)
        #endif
    }

    #if os(macOS)
        // MARK: ⌘⌫ in a text field

        private func keyDown() throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                    context: nil, characters: "\u{8}", charactersIgnoringModifiers: "\u{8}", isARepeat: false,
                    keyCode: 51))
        }

        private func mouseDown() throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }

        @Test func commandDeleteFromTheKeyboardGoesToTheEditedText() throws {
            let textView = NSTextView()
            textView.isEditable = true
            #expect(CommandDeleteRouting.editingTextView(firstResponder: textView, event: try keyDown()) === textView)
        }

        @Test func commandDeleteTrashesWhenNoTextIsEdited() throws {
            let readOnly = NSTextView()
            readOnly.isEditable = false
            #expect(CommandDeleteRouting.editingTextView(firstResponder: readOnly, event: try keyDown()) == nil)
            #expect(CommandDeleteRouting.editingTextView(firstResponder: NSView(), event: try keyDown()) == nil)
            #expect(CommandDeleteRouting.editingTextView(firstResponder: nil, event: try keyDown()) == nil)
            // A click on the menu item is a request to trash, also while a text field has the focus.
            let textView = NSTextView()
            textView.isEditable = true
            #expect(CommandDeleteRouting.editingTextView(firstResponder: textView, event: try mouseDown()) == nil)
            #expect(CommandDeleteRouting.editingTextView(firstResponder: textView, event: nil) == nil)
        }

        @Test func theHandedBackKeyDeletesToTheStartOfTheLine() {
            let textView = NSTextView()
            textView.isEditable = true
            textView.string = "Electricity bill October"
            textView.setSelectedRange(NSRange(location: 16, length: 0))

            CommandDeleteRouting.deleteToBeginningOfLine(in: textView)

            #expect(textView.string == " October")
        }
    #endif
}
