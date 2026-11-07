import Foundation
import Testing

@testable import Dokumentum

/// The info panel's title draft (`TitleDraft`, review A of #57): only a draft the user changed is saved, so an
/// untouched draft that is older than the store never reverts a rename from the other device.
struct TitleDraftTests {
    private let a = UUID()
    private let b = UUID()

    /// The other device renamed the document, and the library has not read it yet: moving on or closing the
    /// panel without typing saves nothing.
    @Test func anUntouchedDraftIsNeverSaved() {
        var draft = TitleDraft()
        #expect(draft.commit() == nil, "nothing shown yet")
        draft.show(a, title: "Electricity bill October")
        #expect(draft.commit() == nil)
        draft.show(b, title: "Medical invoice")
        #expect(draft.commit() == nil)
    }

    /// A stored title with whitespace around it is not rewritten trimmed just because the panel showed it.
    @Test func anUntouchedTitleWithWhitespaceIsNotSaved() {
        var draft = TitleDraft()
        draft.show(a, title: "  Strom ")
        #expect(draft.commit() == nil)
    }

    /// When the library reads a new title, an untouched draft follows it and still saves nothing.
    @Test func anUntouchedDraftFollowsANewTitle() {
        var draft = TitleDraft()
        draft.show(a, title: "Electricity bill October")
        draft.titleChanged(to: "Renamed on the iPhone")
        #expect(draft.text == "Renamed on the iPhone")
        #expect(draft.commit() == nil)
    }

    /// A typed draft is saved once, to the document it was typed for, even after the selection moved on.
    @Test func aTypedDraftIsSavedOnceToItsOwnDocument() throws {
        var draft = TitleDraft()
        draft.show(a, title: "Old")
        draft.text = "New"
        let first = draft.commit()
        let commit = try #require(first)
        #expect(commit.document == a)
        #expect(commit.title == "New")
        #expect(draft.commit() == nil, "saved twice")

        draft.text = "Newer"
        // The view saves before it shows the next document.
        let second = draft.commit()
        let moved = try #require(second)
        #expect(moved.document == a)
        draft.show(b, title: "Other")
        #expect(draft.commit() == nil)
    }

    /// While the user is typing, a title read from the library does not replace the typed text.
    @Test func aTypedDraftIsKeptWhenANewTitleArrives() throws {
        var draft = TitleDraft()
        draft.show(a, title: "Old")
        draft.text = "Mine"
        draft.titleChanged(to: "Theirs")
        #expect(draft.text == "Mine")
        let commit = draft.commit()
        #expect(commit?.title == "Mine")
    }

    /// After a save, the library's stored (trimmed) title replaces the saved draft.
    @Test func aSavedDraftFollowsTheStoredTitle() {
        var draft = TitleDraft()
        draft.show(a, title: "Old")
        draft.text = "New "
        _ = draft.commit()
        draft.titleChanged(to: "New")
        #expect(draft.text == "New")
        #expect(draft.commit() == nil)
    }
}
