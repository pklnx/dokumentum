import DokumentumKit
import Foundation
import Testing

struct LibrarySearchTests {
    private static func id(_ prefix: Int, _ number: Int) -> UUID {
        UUID(uuidString: String(format: "%08d-0000-4000-8000-%012d", prefix, number))!
    }

    // Tags: Steuer › 2024, Auto.
    static let steuer = id(1, 1)
    static let year = id(1, 2)
    static let auto = id(1, 3)
    static let tags = [
        TagRecord(instanceID: steuer, parentInstanceID: nil, name: "Steuer"),
        TagRecord(instanceID: year, parentInstanceID: steuer, name: "2024"),
        TagRecord(instanceID: auto, parentInstanceID: nil, name: "Auto"),
    ]
    static let tree = TagTree(tags)
    static let finanzamt = LibraryDocument.Reference(instanceID: id(2, 1), name: "Finanzamt München")
    static let stadtwerke = LibraryDocument.Reference(instanceID: id(2, 2), name: "Stadtwerke")
    static let steuerberater = LibraryDocument.Reference(instanceID: id(2, 3), name: "Steuerberater Huber")
    static let bescheid = LibraryDocument.Reference(instanceID: id(3, 1), name: "Bescheid")
    static let rechnung = LibraryDocument.Reference(instanceID: id(3, 2), name: "Rechnung")

    private static func document(
        _ number: Int, inbox: Bool = false, trashed: Bool = false, tags: Set<UUID> = [],
        correspondent: LibraryDocument.Reference? = nil, type: LibraryDocument.Reference? = nil
    ) -> LibraryDocument {
        LibraryDocument(
            instanceID: id(9, number), title: "Document \(number)",
            documentDate: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(number) * 86_400),
            createdAt: .distantPast, isInbox: inbox,
            deletedAt: trashed ? Date(timeIntervalSinceReferenceDate: 900_000_000) : nil,
            correspondent: correspondent, documentType: type, tagIDs: tags)
    }

    static let documents = [
        document(1, inbox: true, tags: [year], correspondent: finanzamt, type: bescheid),
        document(2, tags: [steuer], correspondent: stadtwerke, type: rechnung),
        document(3, tags: [auto], correspondent: finanzamt),
        document(4, inbox: true, correspondent: stadtwerke, type: rechnung),
        document(5, trashed: true, tags: [year], correspondent: finanzamt, type: bescheid),
        document(6, trashed: true, tags: [auto]),
    ]
    static let snapshot = LibrarySnapshot(
        documents: documents, tags: tags, correspondents: [finanzamt, stadtwerke, steuerberater],
        documentTypes: [bescheid, rechnung])

    private func numbers(_ documents: [LibraryDocument]) -> [Int] {
        documents.map { Int($0.instanceID.uuidString.suffix(12))! }
    }

    private func result(_ numbers: [Int]) -> SearchResult {
        SearchResult(matches: Set(numbers.map { Self.id(9, $0) }), state: .ready)
    }

    private func apply(_ search: LibrarySearch, _ result: SearchResult?, in selection: LibrarySelection) -> [Int] {
        numbers(search.apply(result, to: Self.documents, selection: selection, tree: Self.tree))
    }

    // MARK: Scope and trash (Revision 1, B2)

    @Test func trashScopeWithATagTokenFindsTheTrashedTaggedDocument() {
        let search = LibrarySearch(tokens: [.tag(Self.steuer)])
        #expect(apply(search, nil, in: .trash) == [5])
        #expect(apply(search, nil, in: .all) == [2, 1])
        #expect(apply(LibrarySearch(tokens: [.tag(Self.steuer)], scope: .all), nil, in: .trash) == [2, 1])
    }

    @Test func theScopeAloneDecidesTrashedOrNot() {
        let search = LibrarySearch(text: "x")
        let all = result([1, 2, 3, 4, 5, 6])
        #expect(apply(search, all, in: .trash) == [6, 5])
        #expect(apply(search, all, in: .all) == [4, 3, 2, 1])
        #expect(apply(search, all, in: .inbox) == [4, 1])
        #expect(apply(search, all, in: .tag(Self.auto)) == [3])
        #expect(apply(LibrarySearch(text: "x", scope: .all), all, in: .trash) == [4, 3, 2, 1])
    }

    @Test func scopeSelectionVersusAll() {
        let hits = result([1, 2, 3])
        #expect(apply(LibrarySearch(text: "x"), hits, in: .correspondent(Self.finanzamt.instanceID)) == [3, 1])
        #expect(
            apply(LibrarySearch(text: "x", scope: .all), hits, in: .correspondent(Self.finanzamt.instanceID)) == [
                3, 2, 1,
            ])
        #expect(LibrarySearch(scope: .all).scopeSelection(for: .inbox) == .all)
        #expect(LibrarySearch().scopeSelection(for: .inbox) == .inbox)
    }

    // MARK: Tokens

    @Test func aTagTokenIncludesTheSubtree() {
        #expect(apply(LibrarySearch(tokens: [.tag(Self.steuer)]), nil, in: .all) == [2, 1])
        #expect(apply(LibrarySearch(tokens: [.tag(Self.year)]), nil, in: .all) == [1])
    }

    @Test func tokensAreAndedWithEachOtherAndTheText() {
        let tokens: [SearchToken] = [
            .correspondent(Self.stadtwerke.instanceID), .documentType(Self.rechnung.instanceID),
        ]
        #expect(apply(LibrarySearch(tokens: tokens), nil, in: .all) == [4, 2])
        #expect(apply(LibrarySearch(tokens: tokens + [.inbox]), nil, in: .all) == [4])
        #expect(apply(LibrarySearch(tokens: tokens + [.tag(Self.steuer)]), nil, in: .all) == [2])
        #expect(apply(LibrarySearch(text: "strom", tokens: tokens), result([2, 3]), in: .all) == [2])
    }

    @Test func anEmptyTextWithTokensIsAPureFilter() {
        let search = LibrarySearch(text: "  ", tokens: [.inbox])
        #expect(!search.hasText)
        #expect(search.isActive)
        #expect(apply(search, result([]), in: .all) == [4, 1])
    }

    @Test func noTextAndNoTokensIsNoSearch() {
        let search = LibrarySearch(text: " - ", scope: .all)
        #expect(!search.isActive)
        #expect(apply(search, result([]), in: .trash) == [6, 5])
    }

    @Test func aTextWithoutAResultYetListsNothing() {
        #expect(apply(LibrarySearch(text: "steuer"), nil, in: .all) == [])
    }

    @Test func resultsKeepTheListOrder() {
        #expect(apply(LibrarySearch(text: "x"), result([1, 4, 2]), in: .all) == [4, 2, 1])
    }

    // MARK: Suggestions

    private func suggestions(_ text: String, tokens: [SearchToken] = [], in selection: LibrarySelection = .all)
        -> [SearchToken]
    {
        LibrarySearch(text: text, tokens: tokens).suggestions(
            in: Self.snapshot, tree: Self.tree, selection: selection, inboxName: "Inbox")
    }

    @Test func suggestionsMatchTheStartOfAnyWordTagsFirst() {
        #expect(
            suggestions("steu") == [.tag(Self.steuer), .tag(Self.year), .correspondent(Self.steuerberater.instanceID)])
        #expect(suggestions("2024") == [.tag(Self.year)])
        #expect(suggestions("münchen") == [.correspondent(Self.finanzamt.instanceID)])
        #expect(suggestions("MUNCH") == [.correspondent(Self.finanzamt.instanceID)])
        #expect(suggestions("rech") == [.documentType(Self.rechnung.instanceID)])
        #expect(suggestions("in") == [.inbox])
        #expect(suggestions("") == [])
        #expect(suggestions("uer") == [])
    }

    @Test func chosenTokensAreNotSuggestedAgain() {
        #expect(
            suggestions("steu", tokens: [.tag(Self.steuer)]) == [
                .tag(Self.year), .correspondent(Self.steuerberater.instanceID),
            ])
    }

    @Test func theInboxIsNotSuggestedInTheTrash() {
        #expect(suggestions("in", in: .trash) == [])
        #expect(
            LibrarySearch(text: "in", scope: .all).suggestions(
                in: Self.snapshot, tree: Self.tree, selection: .trash, inboxName: "Inbox") == [.inbox])
    }

    @Test func atMostEightSuggestions() {
        let many = (0..<20).map { TagRecord(instanceID: Self.id(4, $0), parentInstanceID: nil, name: "Konto \($0)") }
        let snapshot = LibrarySnapshot(tags: many)
        let found = LibrarySearch(text: "konto").suggestions(
            in: snapshot, tree: TagTree(many), selection: .all, inboxName: "Inbox")
        #expect(found.count == LibrarySearch.suggestionLimit)
        #expect(found.first == .tag(Self.id(4, 0)))
    }

    // MARK: matchesIgnoringTrash

    @Test func matchesIgnoringTrashKeepsEveryRuleButTheTrashGuard() {
        let trashed = Self.documents[4]
        #expect(!LibrarySelection.tag(Self.steuer).matches(trashed, in: Self.tree))
        #expect(LibrarySelection.tag(Self.steuer).matchesIgnoringTrash(trashed, in: Self.tree))
        #expect(LibrarySelection.correspondent(Self.finanzamt.instanceID).matchesIgnoringTrash(trashed, in: Self.tree))
        #expect(!LibrarySelection.tag(Self.auto).matchesIgnoringTrash(trashed, in: Self.tree))
        #expect(!LibrarySelection.inbox.matchesIgnoringTrash(trashed, in: Self.tree))
        #expect(LibrarySelection.trash.matchesIgnoringTrash(trashed, in: Self.tree))
        #expect(!LibrarySelection.trash.matchesIgnoringTrash(Self.documents[0], in: Self.tree))
        #expect(LibrarySelection.all.matchesIgnoringTrash(trashed, in: Self.tree))
    }
}
