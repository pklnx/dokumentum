import DokumentumKit
import Foundation
import Testing

/// The engine's pure parts (#13, plan §1 and §3, part 1): the diff, the batches, the item mapping and the canonical bytes
/// of a fingerprint. Foundation only, so `kit-linux` runs them.
struct SpotlightPlannerTests {
    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
    }

    @Test func newChangedUnchangedAndGoneFingerprints() {
        let live = [Self.id(1): "a", Self.id(2): "b2", Self.id(3): "c"]
        let indexed = [Self.id(2): "b1", Self.id(3): "c", Self.id(4): "d"]
        let plan = SpotlightPlanner.plan(live: live, indexed: indexed)
        #expect(plan.upserts == [Self.id(1), Self.id(2)], "new and changed")
        #expect(plan.deletes == [Self.id(4)], "gone")
        #expect(SpotlightPlanner.plan(live: indexed, indexed: indexed).isEmpty, "unchanged")
    }

    /// The history names a document whose fingerprint is unchanged (a text written later): it is pushed when live, and
    /// never for a document that is gone or trashed.
    @Test func historyNamedDocumentsArePushedWhenLive() {
        let live = [Self.id(1): "a", Self.id(2): "b"]
        let plan = SpotlightPlanner.plan(live: live, indexed: live, changed: [Self.id(2), Self.id(9)])
        #expect(plan == SpotlightPlan(upserts: [Self.id(2)], deletes: []))
    }

    /// A requested identifier (the system's re-index of some items, a stale result opened) is pushed when live and
    /// deleted otherwise, even without a fingerprint.
    @Test func requestedIdentifiersArePushedOrDeleted() {
        let live = [Self.id(1): "a"]
        let plan = SpotlightPlanner.plan(live: live, indexed: live, requested: [Self.id(1), Self.id(7)])
        #expect(plan == SpotlightPlan(upserts: [Self.id(1)], deletes: [Self.id(7)]))
    }

    /// The order is the identifiers' string order, whatever the dictionaries' order.
    @Test func theOrderIsStable() {
        let ids = (0..<50).map { _ in UUID() }
        let live = Dictionary(uniqueKeysWithValues: ids.map { ($0, "x") })
        let first = SpotlightPlanner.plan(live: live, indexed: [:])
        let second = SpotlightPlanner.plan(
            live: Dictionary(uniqueKeysWithValues: ids.reversed().map { ($0, "x") }), indexed: [:])
        #expect(first.upserts == ids.sorted { $0.uuidString < $1.uuidString })
        #expect(first == second)
    }

    @Test func batchesHoldAtMost100ItemsOr4MBOfText() {
        let small = (0..<250).map { Self.item($0, textBytes: 10) }
        #expect(SpotlightPlanner.batches(small).map(\.count) == [100, 100, 50])
        // 200,000 bytes each (the text cap): 20 make 4 MB, the 21st opens the next batch.
        let large = (0..<45).map { Self.item($0, textBytes: SpotlightLimits.textBytes) }
        let batches = SpotlightPlanner.batches(large)
        #expect(batches.map(\.count) == [20, 20, 5])
        #expect(
            batches.allSatisfy { $0.reduce(0) { $0 + $1.textContent.utf8.count } <= SpotlightLimits.batchTextBytes })
        #expect(batches.flatMap { $0 }.map(\.identifier) == large.map(\.identifier), "in order")
        #expect(SpotlightPlanner.batches([]).isEmpty)
        // An item larger than the byte limit on its own is a batch of one.
        #expect(
            SpotlightPlanner.batches((0..<3).map { Self.item($0, textBytes: 50) }, maxTextBytes: 40).map(\.count) == [
                1, 1, 1,
            ])
    }

    @Test func deletesGoInBatchesOf500() {
        let ids = (0..<1_200).map(Self.id)
        let batches = SpotlightPlanner.deleteBatches(ids)
        #expect(batches.map(\.count) == [500, 500, 200])
        #expect(batches.flatMap { $0 } == ids)
    }

    // MARK: The item (plan §1, Q1)

    static let strings = SpotlightItem.Strings(untitledTitle: "Untitled document", locale: Locale(identifier: "en_US"))

    static func noon(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    static let document = SpotlightDocument(
        instanceID: id(1), title: "Stromrechnung", correspondent: "Stadtwerke", documentType: "Rechnung",
        tagPaths: ["Wohnung", "Steuer › 2024"], documentDate: noon(2026, 3, 9), createdAt: noon(2026, 3, 10),
        modifiedAt: noon(2026, 3, 11), isInbox: true)

    @Test func theItemHasEveryAttribute() {
        let thumbnail = Data([0xFF, 0xD8, 0xFF])
        let item = SpotlightItem(Self.document, text: "Zählerstand 4711", thumbnail: thumbnail, strings: Self.strings)
        #expect(item.identifier == Self.id(1).uuidString)
        #expect(item.domainIdentifier == "documents")
        #expect(item.contentType == "com.adobe.pdf")
        #expect(item.expirationDate == .distantFuture)
        #expect(item.title == "Stromrechnung")
        #expect(item.contentDescription == "Stadtwerke · Rechnung · Mar 9, 2026")
        #expect(item.keywords == ["Stadtwerke", "Rechnung", "Steuer › 2024", "Wohnung"])
        #expect(item.textContent == "Zählerstand 4711")
        #expect(item.contentCreationDate == Self.noon(2026, 3, 9))
        #expect(item.addedDate == Self.noon(2026, 3, 10))
        #expect(item.contentModificationDate == Self.noon(2026, 3, 11))
        #expect(item.thumbnailData == thumbnail)
    }

    /// No text of the document in what a result shows, an empty title reads "Untitled document", and empty parts are
    /// left out.
    @Test func theDescriptionNeverHoldsTextAndAnEmptyTitleIsUntitled() {
        var document = Self.document
        document.title = "  "
        document.correspondent = ""
        document.documentType = ""
        document.tagPaths = []
        let item = SpotlightItem(document, text: "Geheimer Inhalt", thumbnail: nil, strings: Self.strings)
        #expect(item.title == "Untitled document")
        #expect(item.contentDescription == "Mar 9, 2026")
        #expect(item.keywords.isEmpty)
        #expect(!item.contentDescription.contains("Geheim"))
        #expect(item.thumbnailData == nil)
    }

    /// A text of 300,000 bytes: `textContent` is its head of at most 200,000 bytes, cut at a line break (N3).
    @Test func theTextIsCutTo200000BytesAtALineBreak() {
        let line = String(repeating: "Wort ", count: 19) + "Ende\n"  // 100 bytes
        let text = String(repeating: line, count: 3_000)
        #expect(text.utf8.count == 300_000)
        let item = SpotlightItem(Self.document, text: text, thumbnail: nil, strings: Self.strings)
        #expect(item.textContent.utf8.count <= SpotlightLimits.textBytes)
        #expect(item.textContent.utf8.count > SpotlightLimits.textBytes - 100)
        #expect(item.textContent.hasSuffix("Ende"), "cut at a line break")
        #expect(text.hasPrefix(item.textContent))
    }

    /// Equal documents give equal bytes; every field and the format version change them.
    @Test func theCanonicalBytesNameEveryField() {
        let base = Self.document.canonicalBytes(formatVersion: 1)
        #expect(base == Self.document.canonicalBytes(formatVersion: 1))
        #expect(base != Self.document.canonicalBytes(formatVersion: 2))
        var reordered = Self.document
        reordered.tagPaths = ["Steuer › 2024", "Wohnung"]
        #expect(reordered.canonicalBytes(formatVersion: 1) == base, "tags are a set")
        let changes: [(inout SpotlightDocument) -> Void] = [
            { $0.title = "Strom" }, { $0.correspondent = "EnBW" }, { $0.documentType = "Brief" },
            { $0.tagPaths = ["Wohnung"] }, { $0.documentDate = Self.noon(2026, 3, 8) },
            { $0.createdAt = Self.noon(2026, 3, 9) }, { $0.modifiedAt = Self.noon(2026, 3, 12) },
            { $0.isInbox = false },
            // A field boundary moved: "ab" + "c" is not "a" + "bc".
            {
                $0.title = "Stromrechnung" + "Stadt"
                $0.correspondent = "werke"
            },
        ]
        for (number, change) in changes.enumerated() {
            var document = Self.document
            change(&document)
            #expect(document.canonicalBytes(formatVersion: 1) != base, "change \(number)")
        }
    }

    static func item(_ number: Int, textBytes: Int) -> SpotlightItem {
        SpotlightItem(
            identifier: id(number).uuidString, title: "\(number)",
            textContent: String(repeating: "a", count: textBytes),
            contentCreationDate: Date(timeIntervalSinceReferenceDate: 0),
            addedDate: Date(timeIntervalSinceReferenceDate: 0),
            contentModificationDate: Date(timeIntervalSinceReferenceDate: 0))
    }
}
