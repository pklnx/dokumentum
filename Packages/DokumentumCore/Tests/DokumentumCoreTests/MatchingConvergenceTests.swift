import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// Two devices (plan of #10, §7, T7): two stores seeded with the same documents and rules (the same `instanceID`s),
/// inserted in different orders, reach the same values; a store that receives the other's result writes nothing; the
/// import path and the bulk path agree; a store with an older rule set reaches its own deterministic result.
struct MatchingConvergenceTests {
    struct Rule {
        var id = UUID()
        var kind: MetadataKind
        var name: String
        var mode: MatchMode
        var pattern: String
    }

    struct Seed {
        var documents: [(id: UUID, text: String)]
        var rules: [Rule]
    }

    /// What the rules decide per document, by `instanceID`.
    struct Fields: Equatable {
        var correspondent: UUID?
        var documentType: UUID?
        var tags: Set<UUID>
    }

    static func makeSeed() -> Seed {
        let texts = [
            "Stadtwerke München: Jahresabrechnung Strom 2025",
            "Stadtwerke München und Telekom: Rechnung",  // two correspondents: none (P2)
            "Telekom Deutschland: Ihre Rechnung Mobilfunk",
            "Finanzamt München: Steuerbescheid 2024",
            "Ein Brief ohne Treffer",
            "Gaswerke und Telekom: Mahnung",  // two correspondents only under the older rules
        ]
        let rules = [
            Rule(kind: .correspondent, name: "Stadtwerke", mode: .any, pattern: "Stadtwerke"),
            Rule(kind: .correspondent, name: "Telekom", mode: .regex, pattern: "telekom"),
            Rule(kind: .correspondent, name: "Finanzamt", mode: .exact, pattern: "Finanzamt München"),
            Rule(kind: .documentType, name: "Rechnung", mode: .any, pattern: "Rechnung Jahresabrechnung"),
            Rule(kind: .documentType, name: "Bescheid", mode: .any, pattern: "Steuerbescheid"),
            Rule(kind: .tag, name: "Strom", mode: .all, pattern: "Strom Stadtwerke"),
            Rule(kind: .tag, name: "München", mode: .any, pattern: "München"),
            Rule(kind: .tag, name: "Kaputt", mode: .regex, pattern: "(München"),
        ]
        return Seed(documents: texts.map { (UUID(), $0) }, rules: rules)
    }

    /// Seeds a store; `reversed` inserts records and documents in the opposite order.
    static func seed(_ store: ProcessingStore, _ seed: Seed, reversed: Bool, state: String = "done") throws {
        let context = ModelContext(store.container)
        let created = processingStart.addingTimeInterval(-hour)
        for rule in reversed ? seed.rules.reversed() : seed.rules {
            switch rule.kind {
            case .tag:
                let record = DokumentumCore.Tag(name: rule.name, createdAt: created)
                record.instanceID = rule.id
                record.matchMode = rule.mode
                record.matchPattern = rule.pattern
                context.insert(record)
            case .correspondent:
                let record = Correspondent(name: rule.name, createdAt: created)
                record.instanceID = rule.id
                record.matchMode = rule.mode
                record.matchPattern = rule.pattern
                context.insert(record)
            case .documentType:
                let record = DocumentType(name: rule.name, createdAt: created)
                record.instanceID = rule.id
                record.matchMode = rule.mode
                record.matchPattern = rule.pattern
                context.insert(record)
            }
        }
        for (id, text) in reversed ? seed.documents.reversed() : seed.documents {
            let document = Document(title: "Document", createdAt: processingStart)
            document.instanceID = id
            document.processingStateRaw = state
            document.processingDeviceID = deviceA
            document.processingClaimedAt = processingStart
            context.insert(document)
            let file = DocumentFile(
                documentID: document.id, pdfData: TestPDF.make(contents: [.text(text)]), createdAt: processingStart)
            context.insert(file)
            document.file = file
            let record = DocumentText(
                documentID: document.id, extractedText: state == "done" ? text : "", createdAt: processingStart)
            context.insert(record)
            document.text = record
        }
        try context.save()
    }

    static func dump(_ store: ProcessingStore) throws -> [UUID: Fields] {
        var result: [UUID: Fields] = [:]
        for document in try ModelContext(store.container).fetch(FetchDescriptor<Document>()) {
            result[document.instanceID] = Fields(
                correspondent: document.correspondent?.instanceID, documentType: document.documentType?.instanceID,
                tags: Set((document.tags ?? []).map(\.instanceID)))
        }
        return result
    }

    /// Sets store `to`'s correspondent, type and tags of every document to `fields`, as sync would bring them.
    static func copy(_ fields: [UUID: Fields], to store: ProcessingStore) throws {
        let context = ModelContext(store.container)
        let tags = try context.fetch(FetchDescriptor<DokumentumCore.Tag>())
        let correspondents = try context.fetch(FetchDescriptor<Correspondent>())
        let types = try context.fetch(FetchDescriptor<DocumentType>())
        for document in try context.fetch(FetchDescriptor<Document>()) {
            guard let wanted = fields[document.instanceID] else { continue }
            document.correspondent = correspondents.first { $0.instanceID == wanted.correspondent }
            document.documentType = types.first { $0.instanceID == wanted.documentType }
            document.tags = tags.filter { wanted.tags.contains($0.instanceID) }
        }
        try context.save()
    }

    /// Counter-proof: the first matching record in fetch order instead of none.
    @Test func twoStoresWithTheSameRulesInAnotherOrderReachTheSameValues() async throws {
        let seed = Self.makeSeed()
        let storeA = try ProcessingStore()
        defer { storeA.remove() }
        let storeB = try ProcessingStore()
        defer { storeB.remove() }
        try Self.seed(storeA, seed, reversed: false)
        try Self.seed(storeB, seed, reversed: true)

        let reportA = try #require(await storeA.matchingRun().run())
        let reportB = try #require(await storeB.matchingRun().run())

        #expect(reportA == reportB)
        #expect(reportA.ambiguous == 1)
        let dumpA = try Self.dump(storeA)
        #expect(dumpA == (try Self.dump(storeB)))
        let ambiguous = seed.documents[1].id
        #expect(dumpA[ambiguous]?.correspondent == nil)
        #expect(dumpA[seed.documents[0].id]?.correspondent == seed.rules[0].id)
        #expect(dumpA[seed.documents[3].id]?.correspondent == seed.rules[2].id)
    }

    /// No ping-pong: a store that received the other's result finds nothing to write.
    @Test func aStoreThatReceivedTheOthersResultWritesNothing() async throws {
        let seed = Self.makeSeed()
        let storeA = try ProcessingStore()
        defer { storeA.remove() }
        let storeB = try ProcessingStore()
        defer { storeB.remove() }
        try Self.seed(storeA, seed, reversed: false)
        try Self.seed(storeB, seed, reversed: true)
        _ = try #require(await storeB.matchingRun().run())
        try Self.copy(try Self.dump(storeB), to: storeA)

        let saves = SaveCounter(storeA.container)
        let report = try #require(await storeA.matchingRun().run())

        #expect(report.changed == 0)
        #expect(saves.count == 0)
    }

    /// The text write on store A (documents waiting for their text) and the bulk run on store B (documents with
    /// their text) give the same values.
    @Test func theImportPathAndTheBulkPathGiveTheSameValues() async throws {
        let seed = Self.makeSeed()
        let storeA = try ProcessingStore()
        defer { storeA.remove() }
        let storeB = try ProcessingStore()
        defer { storeB.remove() }
        try Self.seed(storeA, seed, reversed: false, state: "pending")
        try Self.seed(storeB, seed, reversed: true)

        let queue = await storeA.queue(deviceA, clock: TestClock()).run()
        _ = try #require(await storeB.matchingRun().run())

        #expect(queue.done == seed.documents.count)
        for (id, text) in seed.documents { #expect(try storeA.text(of: id).text == text) }
        #expect(try Self.dump(storeA) == (try Self.dump(storeB)))
    }

    /// A device whose rule edit has not arrived yet follows its own rules, deterministically: its result differs from
    /// the other device's, and two stores with the older rules agree with each other (the stale-rule case of §7;
    /// counter-proof: the first matching record in fetch order instead of none).
    @Test func aStoreWithAnOlderRuleSetReachesItsOwnDeterministicResult() async throws {
        let seed = Self.makeSeed()
        var older = seed
        older.rules[0].pattern = "Gaswerke"  // the Stadtwerke rule before the user's edit
        let current = try ProcessingStore()
        defer { current.remove() }
        let stale = try ProcessingStore()
        defer { stale.remove() }
        let staleAgain = try ProcessingStore()
        defer { staleAgain.remove() }
        try Self.seed(current, seed, reversed: false)
        try Self.seed(stale, older, reversed: false)
        try Self.seed(staleAgain, older, reversed: true)

        for store in [current, stale, staleAgain] { _ = try #require(await store.matchingRun().run()) }

        let staleDump = try Self.dump(stale)
        #expect(staleDump == (try Self.dump(staleAgain)))
        #expect(staleDump != (try Self.dump(current)))
        #expect(staleDump[seed.documents[0].id]?.correspondent == nil)
        #expect(staleDump[seed.documents[1].id]?.correspondent == seed.rules[1].id, "only Telekom matches there")
        #expect(staleDump[seed.documents[5].id]?.correspondent == nil, "Gaswerke and Telekom: none")
        #expect(try Self.dump(current)[seed.documents[5].id]?.correspondent == seed.rules[1].id)
    }
}
