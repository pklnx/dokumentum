import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// Metadata records with copies sharing an `instanceID` meet every background writer that links or checks metadata
/// (#207; plan Revision 1, tests 1–5 and 7). A record with copies is absent for the classification write as it is
/// for matching (#205): never captured, never checked, never linked, and a copied tag counts as a user tag. Every case
/// runs once per copy: the store returns the first-inserted copy first, so in one case the document links the copy
/// that the check (`RowRecords`) keeps and in the other the copy it does not. Every case lands on its first run and
/// leaves nothing for the next. Stub classifier and stub stages; tests wait for reports.
struct CopiedMetadataTests {
    /// Which copy the document links.
    enum Linked: String, CaseIterable, CustomTestStringConvertible {
        case first, second
        var testDescription: String { "\(rawValue)-inserted" }
    }

    private static func row(_ copies: (instanceID: UUID, first: UUID, second: UUID), _ linked: Linked) -> UUID {
        linked == .first ? copies.first : copies.second
    }

    // MARK: 1. Every exit of the step

    enum Exit: String, CaseIterable {
        case answer, declined, shortText, switchOff, unavailable, notReadyAtTheClaimsEnd, gaveUp
    }

    struct ExitRun: Sendable, CustomTestStringConvertible {
        var exit: Exit
        var linked: Linked
        var testDescription: String { "\(exit.rawValue), \(linked.testDescription)" }
        static let all = Exit.allCases.flatMap { exit in Linked.allCases.map { ExitRun(exit: exit, linked: $0) } }
    }

    /// A document in `classify` links one copy of a tag, correspondent or type: every exit of the step leaves
    /// `classify` on its first writing run, the copy stays linked, and the next run writes nothing (counter-proof:
    /// capture every linked record again, as before #207; the cases on the copy the check does not keep back off).
    @Test(arguments: MetadataKind.allCases, ExitRun.all)
    func everyExitLeavesClassifyOnItsFirstRun(kind: MetadataKind, run: ExitRun) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let failures = store.failures(deviceA)
        let counter = store.failures(deviceA)
        let exit = run.exit
        let id = try store.insertClassify(text: exit == .shortText ? "Datum: 13.11.2026" : billText)
        let copies = try store.insertCopies(kind, "Privat")
        let linked = Self.row(copies, run.linked)
        try store.linkCopy(id, kind, row: linked)
        struct Broken: Error {}
        let availability: ClassifierAvailability =
            switch exit {
            case .unavailable: .unavailable(.deviceNotEligible)
            case .notReadyAtTheClaimsEnd: .notReady
            default: .available
            }
        let classifier = StubClassifier(availability: availability) { _ in
            switch exit {
            case .declined: throw ClassificationFailure.declined(.refusal)
            case .gaveUp: throw Broken()
            default: return billSuggestion
            }
        }
        if exit == .switchOff { ClassificationSettings(defaultsSuite: failures.defaultsSuite).isEnabled = false }
        let queue = store.classifyingQueue(
            classifier: classifier, failures: failures, classificationFailures: counter, clock: clock)

        var report = await queue.run()
        // The runs before the exit's own write nothing that could back off.
        let waits: [TimeInterval] =
            switch exit {
            case .notReadyAtTheClaimsEnd: [ProcessingClaimRules.takeoverInterval + 1]
            case .gaveUp: [60, 10 * 60]
            default: []
            }
        for wait in waits {
            #expect(report.done == 0 && report.backedOff == 0, "\(exit): \(report)")
            clock.advance(by: wait)
            report = await queue.run()
        }

        #expect(report.done == 1, "\(exit): \(report)")
        #expect(report.backedOff == 0, "\(exit)")
        #expect(try store.classified(id).stateRaw == "done")
        #expect(try store.linkedRows(id, kind).contains(linked), "the linked copy stays linked")

        clock.advance(by: 60)
        let next = await queue.run()

        #expect(next.saves == 0 && next.backedOff == 0 && next.done == 0, "\(next)")
    }

    // MARK: 2. The classifier's names meet copies

    /// The answer's correspondent and type exist only as two live copies each, the younger inserted first or the
    /// older: the names are resolved as if the copies did not exist, so a new correspondent and type are linked and
    /// neither copy is linked or changed (counter-proof: resolve on all live records, copies included; the
    /// younger-first case backs off on every run).
    @Test(arguments: [true, false])
    func aCorrespondentAndATypeThatOnlyCopiesCarryAreCreatedAnew(youngerFirst: Bool) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insertClassify()
        let gap: TimeInterval = youngerFirst ? -60 : 60
        let correspondent = try store.insertCopies(.correspondent, "Stadtwerke München GmbH", gap: gap)
        let type = try store.insertCopies(.documentType, "Abrechnung", gap: gap)

        let report = await store.classifyingQueue(classifier: StubClassifier(), clock: TestClock()).run()

        #expect(report.classified == 1, "\(report)")
        #expect(report.backedOff == 0)
        let row = try store.classified(id)
        #expect(row.stateRaw == "done")
        #expect(row.correspondent == "Stadtwerke München GmbH" && row.documentType == "Abrechnung")
        let document = try #require(try ProcessingStore.fetch(id, in: ModelContext(store.container)))
        #expect(document.correspondent?.instanceID != correspondent.instanceID, "a new correspondent")
        #expect(document.documentType?.instanceID != type.instanceID, "a new type")
        #expect(try store.correspondents() == Array(repeating: "Stadtwerke München GmbH", count: 3))
        #expect(try store.documentTypes() == ["Abrechnung", "Abrechnung", "Abrechnung"])
        try expectUnchanged(store, .correspondent, correspondent, name: "Stadtwerke München GmbH")
        try expectUnchanged(store, .documentType, type, name: "Abrechnung")
    }

    /// The answer's tag exists only as two live copies: no classifier tag, and no new tag (tags are never created).
    /// This case does not catch test 2's mutation (with two same-name candidates `MetadataMatcher.tag` links none
    /// either way); `aDistinctLiveTagNextToCopiesIsLinked` does.
    @Test(arguments: [true, false])
    func aTagThatOnlyCopiesCarryIsNotLinked(youngerFirst: Bool) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insertClassify()
        let tag = try store.insertCopies(.tag, "Strom", gap: youngerFirst ? -60 : 60)

        let report = await store.classifyingQueue(classifier: StubClassifier(), clock: TestClock()).run()

        #expect(report.classified == 1, "\(report)")
        #expect(report.backedOff == 0)
        #expect(try store.classified(id).tags.isEmpty)
        #expect(try store.tagCount() == 2)
        try expectUnchanged(store, .tag, tag, name: "Strom")
    }

    /// Fix round 1 (review B P1, A-N3 = B-N2): two live copies "Strom" and one distinct live "Strom", the younger copy
    /// inserted first or the older. Resolved as if the copies did not exist, the distinct tag is the only candidate
    /// and is linked; the copies stay unlinked (counter-proofs: test 2's mutation, resolve on all live records with
    /// the copies, links none; review A's M2, dedupe the live records by `instanceID` instead of leaving copies out,
    /// keeps a copy as a second "Strom" and links none either).
    @Test(arguments: [true, false])
    func aDistinctLiveTagNextToCopiesIsLinked(youngerFirst: Bool) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insertClassify()
        let copies = try store.insertCopies(.tag, "Strom", gap: youngerFirst ? -60 : 60)
        let distinct = try store.insertMetadata(.tag, "Strom")

        let report = await store.classifyingQueue(classifier: StubClassifier(), clock: TestClock()).run()

        #expect(report.classified == 1, "\(report)")
        #expect(report.backedOff == 0)
        let document = try #require(try ProcessingStore.fetch(id, in: ModelContext(store.container)))
        #expect((document.tags ?? []).map(\.instanceID) == [distinct], "the distinct live tag")
        try expectUnchanged(store, .tag, copies, name: "Strom")
    }

    /// Both copies are still live under `name`, and no document links either.
    private func expectUnchanged(
        _ store: ProcessingStore, _ kind: MetadataKind, _ copies: (instanceID: UUID, first: UUID, second: UUID),
        name: String, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let context = ModelContext(store.container)
        let id = copies.instanceID
        let rows: [(name: String, isLive: Bool, documents: Int)] =
            switch kind {
            case .tag:
                try context.fetch(FetchDescriptor<DokumentumCore.Tag>(predicate: #Predicate { $0.instanceID == id }))
                    .map { ($0.name, $0.isLive, $0.documents?.count ?? 0) }
            case .correspondent:
                try context.fetch(FetchDescriptor<Correspondent>(predicate: #Predicate { $0.instanceID == id }))
                    .map { ($0.name, $0.isLive, $0.documents?.count ?? 0) }
            case .documentType:
                try context.fetch(FetchDescriptor<DocumentType>(predicate: #Predicate { $0.instanceID == id }))
                    .map { ($0.name, $0.isLive, $0.documents?.count ?? 0) }
            }
        #expect(rows.count == 2, sourceLocation: sourceLocation)
        #expect(
            rows.allSatisfy { $0.name == name && $0.isLive && $0.documents == 0 }, "\(rows)",
            sourceLocation: sourceLocation)
    }

    // MARK: 3. T13: a tag with copies is a user tag

    /// The document's tag is one copy of a rule tag whose rule matches the text, alone or next to a live rule tag
    /// whose rule matches too (plan review B1): the copy counts as a user tag, so the classifier's unique live tag
    /// "Strom" is not added (counter-proof A: read the copy's rule, and "Strom" is added in both; counter-proof CP1:
    /// leave copies out of the rules without counting them as user tags, and "Strom" is added next to the live tag).
    @Test(arguments: [false, true], Linked.allCases)
    func aTagWithCopiesIsAUserTag(nextToALiveRuleTag: Bool, linked: Linked) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insertClassify()
        try store.insertMetadata(.tag, "Strom")
        let copies = try store.insertCopies(.tag, "Energie kopiert", rule: (.any, "Stadtwerke"))
        try store.linkCopy(id, .tag, row: Self.row(copies, linked))
        if nextToALiveRuleTag {
            let energie = try store.insertRule(.tag, "Energie", .any, "Stadtwerke")
            try store.link(id, .tag, energie)
        }

        let report = await store.classifyingQueue(classifier: StubClassifier(), clock: TestClock()).run()

        #expect(report.classified == 1, "\(report)")
        #expect(report.backedOff == 0)
        #expect(
            try store.classified(id).tags
                == (nextToALiveRuleTag ? ["Energie", "Energie kopiert"] : ["Energie kopiert"]))
    }

    // MARK: 7. The check still covers the rows without copies

    /// The document links one copy of a tag and the live rule tag "Energie"; a rule edit of "Energie" in the write's
    /// window still makes it back off, and the next run lands with the edit kept (plan review N1, R4; counter-proof:
    /// skip the whole tag capture when any linked tag has copies, and the first run lands over the edit).
    @Test(arguments: Linked.allCases)
    func aRuleEditOfALiveTagNextToACopyInTheWindowBacksOff(linked: Linked) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insertClassify()
        try store.insertMetadata(.tag, "Strom")
        let copies = try store.insertCopies(.tag, "Privat")
        try store.linkCopy(id, .tag, row: Self.row(copies, linked))
        let energie = try store.insertRule(.tag, "Energie", .any, "Stadtwerke")
        try store.link(id, .tag, energie)
        let hooks = ProcessingQueue.Hooks(
            beforeCheck: once({ $0 == ProcessingQueue.Write.classification }) {
                try store.setRule(.tag, energie, .any, "Telekom")
            })
        let queue = store.classifyingQueue(classifier: StubClassifier(), clock: TestClock(), hooks: hooks)

        let first = await queue.run()

        #expect(first.backedOff == 1, "\(first)")
        #expect(first.classified == 0)
        #expect(try store.classified(id).stateRaw == "classify")

        let next = await queue.run()

        #expect(next.classified == 1, "\(next)")
        #expect(next.backedOff == 0)
        #expect(try store.rawRule(.tag, energie)?.pattern == "Telekom", "the edit stays")
        #expect(try store.classified(id).tags == ["Energie", "Privat"])
    }

    /// Fix round 1 (review A P3, A-N1): the document already links a live correspondent or type without copies, and
    /// one copy of a tag. A rename of that record in the write's window still makes the write back off, and the next
    /// run lands with the rename kept (counter-proof: review A's M3, skip the capture of the linked correspondent and
    /// type, and the first run lands over the rename).
    @Test(arguments: [MetadataKind.correspondent, .documentType], Linked.allCases)
    func aRenameOfALinkedRecordNextToACopyInTheWindowBacksOff(kind: MetadataKind, linked: Linked) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insertClassify()
        let known = try store.insertMetadata(kind, "Meine Wahl")
        try store.link(id, kind, known)
        let copies = try store.insertCopies(.tag, "Privat")
        try store.linkCopy(id, .tag, row: Self.row(copies, linked))
        let hooks = ProcessingQueue.Hooks(
            beforeCheck: once({ $0 == ProcessingQueue.Write.classification }) {
                try store.renameMetadata(kind, known, to: "Umbenannt")
            })
        let queue = store.classifyingQueue(classifier: StubClassifier(), clock: TestClock(), hooks: hooks)

        let first = await queue.run()

        #expect(first.backedOff == 1 && first.saves == 0, "\(first)")
        #expect(try store.metadataName(kind, known) == "Umbenannt", "the rename was written over")
        #expect(try store.classified(id).stateRaw == "classify")

        let next = await queue.run()

        #expect(next.classified == 1 && next.backedOff == 0, "\(next)")
        #expect(try store.metadataName(kind, known) == "Umbenannt")
        #expect(try store.detected(id).stateRaw == "done")
    }

    // MARK: A copy that is a tombstone

    /// Fix round 1 (A-N2 = B-N1): the document links the live one of two records sharing an `instanceID`, and the
    /// other is a merge's tombstone (#205's B1 shape), inserted first or second, for every kind. Copies are counted
    /// among all records, tombstones included, so the live one is not captured and the write lands on its first run;
    /// the next run writes nothing (counter-proof: review A's M1 = B's O2, count copies on live records only; with
    /// the tombstone inserted first the check keeps the tombstone, and the write backs off on every run).
    @Test(arguments: MetadataKind.allCases, [true, false])
    func aLiveCopyNextToATombstoneCopyLands(kind: MetadataKind, tombstoneFirst: Bool) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify()
        let keeper = try store.insertMetadata(kind, "Woanders")
        let copies = try store.insertCopies(kind, "Privat")
        let (tombstone, live) = tombstoneFirst ? (copies.first, copies.second) : (copies.second, copies.first)
        try store.mergeCopy(kind, row: tombstone, into: keeper)
        try store.linkCopy(id, kind, row: live)
        let queue = store.classifyingQueue(classifier: StubClassifier(), clock: clock)

        let first = await queue.run()

        #expect(first.done == 1 && first.backedOff == 0, "\(first)")
        #expect(try store.classified(id).stateRaw == "done")
        #expect(try store.linkedRows(id, kind).contains(live), "the live copy stays linked")

        clock.advance(by: 60)
        let next = await queue.run()

        #expect(next.saves == 0 && next.backedOff == 0 && next.done == 0, "\(next)")
    }

    // MARK: 4. The text write and the bulk run

    enum Writer: String, CaseIterable { case textWrite, bulkRun }

    struct WriterRun: Sendable, CustomTestStringConvertible {
        var writer: Writer
        var linked: Linked
        var testDescription: String { "\(writer.rawValue), \(linked.testDescription)" }
        static let all = Writer.allCases.flatMap { writer in
            Linked.allCases.map { WriterRun(writer: writer, linked: $0) }
        }
    }

    /// The document already links one copy of a tag, correspondent or type, and the tag rule "Strom" matches: the text
    /// write and the bulk run land on the first run, the copy stays linked, and the next run changes nothing. They
    /// put only what the fill links into the check, never the document's earlier links (counter-proof: capture the
    /// document's linked rows in `MetadataFill.applyRules`; the cases on the copy the check does not keep back off).
    @Test(arguments: MetadataKind.allCases, WriterRun.all)
    func theTextWriteAndTheBulkRunLandWithALinkedCopy(kind: MetadataKind, run: WriterRun) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        try store.insertRule(.tag, "Strom", .any, "Strom")
        let id =
            switch run.writer {
            case .textWrite: try store.insert(device: deviceA, claimedAt: processingStart)
            case .bulkRun: try store.insertWithText(billText)
            }
        let copies = try store.insertCopies(kind, "Privat")
        let linked = Self.row(copies, run.linked)
        try store.linkCopy(id, kind, row: linked)

        switch run.writer {
        case .textWrite:
            let queue = store.queue(deviceA, stage: textStage(), clock: TestClock())
            let report = await queue.run()
            #expect(report.done == 1, "\(report)")
            #expect(report.backedOff == 0)
            let next = await queue.run()
            #expect(next.saves == 0 && next.backedOff == 0, "\(next)")
        case .bulkRun:
            let report = try #require(await store.matchingRun().run())
            #expect(report.changed == 1 && report.skipped == 0, "\(report)")
            let next = try #require(await store.matchingRun().run())
            #expect(next.changed == 0 && next.skipped == 0, "\(next)")
        }
        #expect(try store.matched(id).tags.contains("Strom"))
        #expect(try store.linkedRows(id, kind).contains(linked), "the copy stays linked")
    }

    // MARK: 5. The repair (no change in #207)

    /// The repair captures and checks through the same `RowRecords`, so linked copies never make a pass meet another
    /// save (plan review N5: both read the metadata first in a fresh context; a failure here without a code change
    /// points at the fetch order first). A copied loser: two live copies "Stadtwerke" and an older distinct
    /// "Stadtwerke", one document on each copy. Run 1 merges the kept copy and moves its document, run 2 repoints the
    /// other copy's document through the new tombstone, run 3 writes nothing (counter-proof: the check reads the
    /// metadata in reverse fetch order, and a pass meets another save).
    @Test func aCopiedLoserIsMergedWithoutMeetingAnotherSave() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let context = ModelContext(store.container)
        let keeper = Correspondent(name: "Stadtwerke", createdAt: processingStart.addingTimeInterval(-3 * hour))
        context.insert(keeper)
        try context.save()
        let keeperID = keeper.instanceID
        let copies = try store.insertCopies(.correspondent, "Stadtwerke")
        let onFirst = try store.insert(title: "On the first copy")
        try store.linkCopy(onFirst, .correspondent, row: copies.first)
        let onSecond = try store.insert(title: "On the second copy")
        try store.linkCopy(onSecond, .correspondent, row: copies.second)

        let reports = try (1...3).map { run in
            try RepairRun.perform(
                in: store.container, now: processingStart.addingTimeInterval(Double(run) * hour),
                hasCompletedImport: true)
        }

        for report in reports {
            #expect(!report.passes.contains { $0.metAnotherSave }, "\(report.passes)")
            #expect(report.skipped.isEmpty, "\(report.passes)")
        }
        #expect(reports[0].saves > 0 && reports[1].saves > 0, "\(reports.map(\.saves))")
        #expect(reports[2].saves == 0 && reports[2].plan.operations.isEmpty, "\(reports[2].plan)")
        for document in [onFirst, onSecond] {
            #expect(try store.detected(document).correspondentID == keeperID)
        }
    }

    /// A copied keeper (plan review N3, R2): the classifier names a correspondent and a type that only two live copies
    /// carry, in either insertion order. The write creates new records; the repair's first run merges them into the
    /// copies without meeting another save, the document ends on a copy for both kinds, the new records are
    /// tombstones, and the next run writes nothing.
    @Test(arguments: [true, false])
    func aCopiedKeeperTakesTheClassifiersNewRecords(youngerFirst: Bool) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insertClassify()
        let gap: TimeInterval = youngerFirst ? -60 : 60
        let correspondent = try store.insertCopies(.correspondent, "Stadtwerke München GmbH", gap: gap)
        let type = try store.insertCopies(.documentType, "Abrechnung", gap: gap)
        let classified = await store.classifyingQueue(classifier: StubClassifier(), clock: TestClock()).run()
        #expect(classified.classified == 1 && classified.backedOff == 0, "\(classified)")

        let reports = try (1...2).map { run in
            try RepairRun.perform(
                in: store.container, now: processingStart.addingTimeInterval(Double(run) * hour),
                hasCompletedImport: true)
        }

        for report in reports {
            #expect(!report.passes.contains { $0.metAnotherSave }, "\(report.passes)")
            #expect(report.skipped.isEmpty, "\(report.passes)")
        }
        #expect(reports[0].plan.operations.count == 2, "\(reports[0].plan)")
        #expect(reports[1].saves == 0 && reports[1].plan.operations.isEmpty, "\(reports[1].plan)")
        let document = try #require(try ProcessingStore.fetch(id, in: ModelContext(store.container)))
        #expect(document.correspondent?.instanceID == correspondent.instanceID)
        #expect(document.documentType?.instanceID == type.instanceID)
        let context = ModelContext(store.container)
        let copiedCorrespondent = correspondent.instanceID
        let copiedType = type.instanceID
        let newCorrespondents = try context.fetch(
            FetchDescriptor<Correspondent>(predicate: #Predicate { $0.instanceID != copiedCorrespondent }))
        let newTypes = try context.fetch(
            FetchDescriptor<DocumentType>(predicate: #Predicate { $0.instanceID != copiedType }))
        #expect(newCorrespondents.count == 1 && newCorrespondents.allSatisfy { !$0.isLive })
        #expect(newTypes.count == 1 && newTypes.allSatisfy { !$0.isLive })
    }
}
