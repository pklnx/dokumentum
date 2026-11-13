import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// The classifier's tags next to rule tags (plan of #10, T13; maintainer's P1; re-review N1–N3): the classifier adds
/// its tags unless the document has a user tag, a tag whose own rule does not explain it on the document's text. The
/// stub answers the bill with the tag "Strom", a live tag without a rule; "Energie"'s rule matches the bill.
struct MatchingClassifierTagTests {
    private struct Setup {
        let store: ProcessingStore
        let id: UUID
        let energie: UUID
    }

    private func setUp(linking: Bool = true) throws -> Setup {
        let store = try ProcessingStore()
        let id = try store.insertClassify()
        try store.insertMetadata(.tag, "Strom")
        let energie = try store.insertRule(.tag, "Energie", .any, "Stadtwerke")
        if linking { try store.link(id, .tag, energie) }
        return Setup(store: store, id: id, energie: energie)
    }

    /// Counter-proofs: count every tag as a user tag; replace the tags instead of adding to them.
    @Test func aDocumentWithOnlyRuleTagsGetsTheClassifiersTagsAdded() async throws {
        let setup = try setUp()
        defer { setup.store.remove() }

        let report = await setup.store.classifyingQueue(classifier: StubClassifier(), clock: TestClock()).run()

        #expect(report.classified == 1)
        #expect(try setup.store.classified(setup.id).tags == ["Energie", "Strom"])
    }

    /// A tag no rule explains is the user's: no classifier tags. That holds for a tag without a rule and for one whose
    /// rule does not match this text.
    @Test(arguments: [false, true])
    func aDocumentWithAUserTagGetsNoClassifierTags(tagHasRule: Bool) async throws {
        let setup = try setUp()
        defer { setup.store.remove() }
        let mine =
            tagHasRule
            ? try setup.store.insertRule(.tag, "Gas", .any, "Erdgas") : try setup.store.insertMetadata(.tag, "Mein Tag")
        try setup.store.link(setup.id, .tag, mine)

        let report = await setup.store.classifyingQueue(classifier: StubClassifier(), clock: TestClock()).run()

        #expect(report.classified == 1)
        #expect(try setup.store.classified(setup.id).tags == ["Energie", tagHasRule ? "Gas" : "Mein Tag"])
    }

    @Test func aDocumentWithoutTagsGetsTheClassifiersTags() async throws {
        let setup = try setUp(linking: false)
        defer { setup.store.remove() }

        _ = await setup.store.classifyingQueue(classifier: StubClassifier(), clock: TestClock()).run()

        #expect(try setup.store.classified(setup.id).tags == ["Strom"])
    }

    /// Review N2: a tag whose rule is invalid, or that sits on a tombstone, counts as a user tag.
    @Test(arguments: [false, true])
    func aTagWithAnInvalidRuleOrOnATombstoneIsAUserTag(tombstone: Bool) async throws {
        let setup = try setUp(linking: false)
        defer { setup.store.remove() }
        let tag =
            tombstone
            ? try setup.store.insertRule(.tag, "Energie alt", .any, "Stadtwerke", mergedInto: setup.energie)
            : try setup.store.insertRule(.tag, "Kaputt", .regex, "(Stadtwerke")
        try setup.store.link(setup.id, .tag, tag)

        let report = await setup.store.classifyingQueue(classifier: StubClassifier(), clock: TestClock()).run()

        #expect(report.classified == 1)
        #expect(try setup.store.classified(setup.id).tags == [tombstone ? "Energie alt" : "Kaputt"])
    }

    /// §6: a rule tag the bulk run added to a document waiting in `classify` still lets the classifier add its tags.
    @Test func aBulkRuleTagOnADocumentInClassifyStillLetsTheClassifierAdd() async throws {
        let setup = try setUp(linking: false)
        defer { setup.store.remove() }

        let run = try #require(await setup.store.matchingRun().run())
        #expect(run.changed == 1)
        #expect(try setup.store.classified(setup.id).tags == ["Energie"])
        #expect(try setup.store.classified(setup.id).stateRaw == "classify", "the run never writes the state")

        _ = await setup.store.classifyingQueue(classifier: StubClassifier(), clock: TestClock()).run()

        #expect(try setup.store.classified(setup.id).tags == ["Energie", "Strom"])
    }

    /// A rule edit of one of the document's tags, saved in the classification write's window, makes it back off; the
    /// next run judges by the edited rule (counter-proof, review N3: leave the document's tags out of the related
    /// rows).
    @Test func aRuleEditOfTheDocumentsTagInTheWindowMakesTheWriteBackOff() async throws {
        let setup = try setUp()
        defer { setup.store.remove() }
        let store = setup.store
        let energie = setup.energie
        let hooks = ProcessingQueue.Hooks(
            beforeCheck: once({ $0 == ProcessingQueue.Write.classification }) {
                try store.setRule(.tag, energie, .any, "Telekom")
            })
        let queue = store.classifyingQueue(classifier: StubClassifier(), clock: TestClock(), hooks: hooks)

        let first = await queue.run()

        #expect(first.backedOff == 1)
        #expect(first.classified == 0)
        #expect(try store.classified(setup.id).stateRaw == "classify")

        let next = await queue.run()

        #expect(next.classified == 1)
        #expect(try store.classified(setup.id).tags == ["Energie"], "its rule no longer explains it: a user tag")
    }

    /// Review N1: only the rules of the document's own tags are read, so an edit of another rule in the window does
    /// not make the write back off.
    @Test func anEditOfAnUnrelatedRuleInTheWindowDoesNotMakeTheWriteBackOff() async throws {
        let setup = try setUp()
        defer { setup.store.remove() }
        let store = setup.store
        let gas = try store.insertRule(.tag, "Gas", .any, "Erdgas")
        let hooks = ProcessingQueue.Hooks(
            beforeCheck: once({ $0 == ProcessingQueue.Write.classification }) {
                try store.setRule(.tag, gas, .any, "Stadtwerke")
            })

        let report = await store.classifyingQueue(classifier: StubClassifier(), clock: TestClock(), hooks: hooks).run()

        #expect(report.backedOff == 0)
        #expect(report.classified == 1)
        #expect(try store.classified(setup.id).tags == ["Energie", "Strom"])
    }
}
