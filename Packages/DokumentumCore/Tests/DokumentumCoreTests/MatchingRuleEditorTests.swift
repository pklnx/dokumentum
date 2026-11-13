import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// The model side of the rule sheet (plan of #10, §8): only changed fields, live records only, `unknown` kept, a
/// failed save rolled back, invalid values refused.
@MainActor
struct MatchingRuleEditorTests {
    struct SaveFailed: Error {}

    /// A draft older than the store: another context changed the mode after the sheet opened; saving only the
    /// pattern keeps that mode (counter-proof: write both fields).
    @Test(arguments: MetadataKind.allCases)
    func onlyTheChangedFieldsAreWritten(kind: MetadataKind) throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insertRule(kind, "Stadtwerke", .any, "Stadtwerke")
        let draft = try StoreLibrarySource.matchingRule(of: kind, id, in: ModelContext(store.container))
        #expect(draft == MatchingRuleValue(mode: .any, pattern: "Stadtwerke"))
        try store.setRule(kind, id, .all, "Stadtwerke")
        let editor = MatchingRuleEditor(context: ModelContext(store.container))

        #expect(try editor.save(kind, id, pattern: "Stadtwerke München") == .saved)

        #expect(try store.rawRule(kind, id)! == ("all", "Stadtwerke München"))
        #expect(try editor.save(kind, id, mode: .all, pattern: "Stadtwerke München") == .unchanged)
    }

    @Test func aTombstoneOrAGoneRecordIsNotEdited() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let keeper = try store.insertMetadata(.correspondent, "Stadtwerke")
        let tombstone = try store.insertRule(.correspondent, "Stadtwerke alt", .any, "x", mergedInto: keeper)
        let editor = MatchingRuleEditor(context: ModelContext(store.container))

        #expect(try editor.save(.correspondent, tombstone, pattern: "y") == .noMetadata)
        #expect(try editor.save(.tag, UUID(), mode: .any, pattern: "y") == .noMetadata)
        #expect(try editor.rule(of: .correspondent, tombstone) == nil)
        #expect(try store.rawRule(.correspondent, tombstone)! == ("any", "x"))
    }

    @Test func aFailedSaveIsRolledBack() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insertRule(.tag, "Strom", .any, "Strom")
        let context = ModelContext(store.container)
        let editor = MatchingRuleEditor(context: context, save: { _ in throw SaveFailed() })

        #expect(throws: SaveFailed.self) { try editor.save(.tag, id, mode: .regex, pattern: "Strom\\s+\\d+") }

        #expect(!context.hasChanges, "nothing stays pending for a later save")
        #expect(try editor.rule(of: .tag, id) == MatchingRuleValue(mode: .any, pattern: "Strom"))
        #expect(try store.rawRule(.tag, id)! == ("any", "Strom"))
    }

    /// A newer build's mode is kept unless the user picks one.
    @Test func anUnknownModeIsKeptUnlessAModeIsChosen() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insertRule(.documentType, "Rechnung", .any, "Rechnung")
        try store.setRawMode(.documentType, id, "fuzzy")
        let editor = MatchingRuleEditor(context: ModelContext(store.container))
        #expect(try editor.rule(of: .documentType, id)?.mode == .unknown)

        #expect(try editor.save(.documentType, id, mode: .unknown, pattern: "Rechnungen") == .saved)
        #expect(try store.rawRule(.documentType, id)! == ("fuzzy", "Rechnungen"))

        #expect(try editor.save(.documentType, id, mode: .exact) == .saved)
        #expect(try store.rawRule(.documentType, id)! == ("exact", "Rechnungen"))
    }

    /// T8: what the sheet would not allow is refused here too, on the values the record would hold.
    @Test func invalidValuesAreRefused() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insertRule(.tag, "Strom", .any, "(Strom")
        let editor = MatchingRuleEditor(context: ModelContext(store.container))

        #expect(try editor.save(.tag, id, mode: .regex) == .invalid(.invalidRegularExpression))
        let long = String(repeating: "a", count: MatchingLimits.patternLength + 1)
        #expect(try editor.save(.tag, id, pattern: long) == .invalid(.tooLong))
        #expect(try store.rawRule(.tag, id)! == ("any", "(Strom"))
        #expect(try editor.save(.tag, id, mode: MatchMode.none) == .saved, "no rule: the pattern is not checked")
    }

    /// Review A of #205, N6: a record with copies sharing its `instanceID` is not edited, as matching never uses it
    /// (counter-proof: edit the first live copy).
    @Test func aRecordWithCopiesIsNotEdited() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insertCopiedCorrespondent(tombstoneFirst: false)
        let editor = MatchingRuleEditor(context: ModelContext(store.container))

        #expect(try editor.rule(of: .correspondent, id) == nil)
        #expect(try editor.save(.correspondent, id, pattern: "Telekom") == .noMetadata)
    }
}
