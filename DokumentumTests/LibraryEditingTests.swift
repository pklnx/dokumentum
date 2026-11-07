import DokumentumCore
import DokumentumKit
import Foundation
import SwiftData
import Testing

@testable import Dokumentum

/// Editing from the info panel (plan of #3, part 3): `LibraryModel` hands each edit to the store's
/// `DocumentEditor` and shows the result at once. In-memory stores only.
@MainActor
struct LibraryEditingTests {
    private func makeModel() throws -> (LibraryModel, ModelContainer) {
        let container = try makeInMemoryContainer()
        FixtureSeeder.seedForUITests(container.mainContext)
        let model = LibraryModel(source: StoreLibrarySource(container: container))
        return (model, container)
    }

    private static let electricityBill = FixtureCatalog.documentID(1)

    @Test func anEditShowsInTheListAtOnce() throws {
        let (model, _) = try makeModel()
        model.selectedDocumentID = Self.electricityBill
        #expect(model.selectedDocument?.title == "Electricity bill October")

        #expect(model.edit(.title("Electricity bill November"), of: Self.electricityBill) == .saved)
        #expect(model.selectedDocument?.title == "Electricity bill November")
        let musterbank = FixtureCatalog.musterbank
        #expect(model.edit(.correspondent(musterbank.instanceID), of: Self.electricityBill) == .saved)
        #expect(model.selectedDocument?.correspondent == musterbank)
        #expect(model.edit(.tag(FixtureCatalog.important.instanceID, true), of: Self.electricityBill) == .saved)
        #expect(model.selectedDocument?.tagIDs == [FixtureCatalog.tax.instanceID, FixtureCatalog.important.instanceID])

        // Out of the Inbox: the Inbox list no longer has it.
        #expect(model.edit(.inbox(false), of: Self.electricityBill) == .saved)
        #expect(!model.documents.contains { $0.instanceID == Self.electricityBill })
        model.selection = .all
        #expect(model.documents.first { $0.instanceID == Self.electricityBill }?.isInbox == false)
    }

    /// Switching "In Inbox" off in the Inbox takes the document out of the list; the selection clears, and the
    /// info panel closes with it instead of showing "No document selected" (reviews of #57).
    @Test func theInfoPanelClosesWhenTheSelectionClears() throws {
        let (model, _) = try makeModel()
        model.selectedDocumentID = Self.electricityBill
        model.isInfoPresented = true
        #expect(model.edit(.inbox(false), of: Self.electricityBill) == .saved)
        #expect(model.selectedDocumentID == nil)
        #expect(!model.isInfoPresented)

        // Another document keeps the panel open; going back (iPhone) closes it.
        model.selectedDocumentID = FixtureCatalog.documentID(2)
        model.isInfoPresented = true
        model.selectedDocumentID = FixtureCatalog.documentID(5)
        #expect(model.isInfoPresented)
        model.selectedDocumentID = nil
        #expect(!model.isInfoPresented)
    }

    @Test func aNewCorrespondentIsCreatedOnceAndSet() throws {
        let (model, container) = try makeModel()
        let before = try container.mainContext.fetchCount(FetchDescriptor<Correspondent>())

        #expect(model.assignMetadata(.correspondent, named: " Neue GmbH ", to: Self.electricityBill) == .saved)
        let created = try #require(model.snapshot.correspondents.first { $0.name == "Neue GmbH" })
        model.selection = .all
        #expect(model.documents.first { $0.instanceID == Self.electricityBill }?.correspondent == created)

        // The same name on another document reuses it.
        let medical = FixtureCatalog.documentID(2)
        #expect(model.assignMetadata(.correspondent, named: "neue gmbh", to: medical) == .saved)
        #expect(model.documents.first { $0.instanceID == medical }?.correspondent == created)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Correspondent>()) == before + 1)

        // An empty name does nothing.
        #expect(model.assignMetadata(.tag, named: "  ", to: medical) == nil)
        #expect(model.tree.tags.count == FixtureCatalog.tags.count)
    }

    @Test func aNewTagIsTopLevelAndAdded() throws {
        let (model, _) = try makeModel()
        // "golf" at the top level is not Auto › Golf.
        #expect(model.assignMetadata(.tag, named: "golf", to: Self.electricityBill) == .saved)
        let created = try #require(model.tree.tags.values.first { $0.name == "golf" })
        #expect(created.parentInstanceID == nil)
        #expect(created.instanceID != FixtureCatalog.golf.instanceID)
        let row = try #require(model.documents.first { $0.instanceID == Self.electricityBill })
        #expect(row.tagIDs == [FixtureCatalog.tax.instanceID, created.instanceID])
        #expect(model.tagChoices.map(\.path) == ["Auto", "Auto › Golf", "golf", "Important", "Tax"])
    }

    /// The fixtures of unit tests take no edits; the info panel shows them read only.
    @Test func aSourceWithoutAnEditorTakesNoEdits() {
        let model = LibraryModel(source: FixtureLibrarySource())
        #expect(!model.canEdit)
        #expect(model.edit(.title("Neu"), of: Self.electricityBill) == nil)
        #expect(model.documents.first { $0.instanceID == Self.electricityBill }?.title == "Electricity bill October")
    }
}
