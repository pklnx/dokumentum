import DokumentumKit
import Foundation
import SwiftData

// Matching rules on the store (#10, part 1b): the rules as values, and the shared fill of a background write.
// docs/development/index.md, "Matching rules", has the whole picture.

/// The rule records of the store as values.
enum MatchingStore {
    /// The live rule records (a `matchModeRaw` that is not `""`, not merged away), in a context that ends with the
    /// read: one fetch per entity with a predicate, so a store without rules reads no row (review N4). Copies
    /// sharing an `instanceID` keep the first read, as `RowRecords` does.
    static func readRules(in container: ModelContainer) throws -> [MatchingRule] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let none = MatchMode.none.storedValue ?? ""
        let tags = try context.fetch(
            FetchDescriptor<Tag>(predicate: #Predicate { $0.matchModeRaw != none && $0.mergedIntoID == nil }))
        let correspondents = try context.fetch(
            FetchDescriptor<Correspondent>(predicate: #Predicate { $0.matchModeRaw != none && $0.mergedIntoID == nil }))
        let types = try context.fetch(
            FetchDescriptor<DocumentType>(predicate: #Predicate { $0.matchModeRaw != none && $0.mergedIntoID == nil }))
        return unique(tags.map(rule) + correspondents.map(rule) + types.map(rule))
    }

    /// The rules of live records among `records`: what the write context fetched, as values.
    static func rules(of metadata: MetadataFill.Live) -> [MatchingRule] {
        unique(
            metadata.tags.values.compactMap(liveRule) + metadata.correspondents.values.compactMap(liveRule)
                + metadata.documentTypes.values.compactMap(liveRule))
    }

    static func rule(_ record: Tag) -> MatchingRule {
        MatchingRule(
            id: record.instanceID, kind: .tag, name: record.name, mode: record.matchMode, pattern: record.matchPattern)
    }

    static func rule(_ record: Correspondent) -> MatchingRule {
        MatchingRule(
            id: record.instanceID, kind: .correspondent, name: record.name, mode: record.matchMode,
            pattern: record.matchPattern)
    }

    static func rule(_ record: DocumentType) -> MatchingRule {
        MatchingRule(
            id: record.instanceID, kind: .documentType, name: record.name, mode: record.matchMode,
            pattern: record.matchPattern)
    }

    /// The rule of a live record with a rule; `nil` for no rule or a tombstone.
    static func liveRule(_ record: Tag) -> MatchingRule? {
        record.isLive && record.matchMode != .none ? rule(record) : nil
    }

    static func liveRule(_ record: Correspondent) -> MatchingRule? {
        record.isLive && record.matchMode != .none ? rule(record) : nil
    }

    static func liveRule(_ record: DocumentType) -> MatchingRule? {
        record.isLive && record.matchMode != .none ? rule(record) : nil
    }

    private static func unique(_ rules: [MatchingRule]) -> [MatchingRule] {
        var seen: Set<UUID> = []
        return rules.filter { seen.insert($0.id).inserted }
    }
}

/// The text result write's rules (plan of #10, §4, N6): read and evaluated before the write, outside its window.
struct TextWriteRules: Sendable {
    /// The live rules as the snapshot read them.
    var rules: [MatchingRule]
    var outcome: RuleOutcome
    /// The text they were evaluated on: the text the write stores.
    var text: String
    var budget: MatchingBudget
}

/// What a fill did to one document.
struct RuleFill: Equatable, Sendable {
    /// The rules linked something.
    var changed = false
    /// A correspondent or type stayed empty because several records matched (P2).
    var ambiguous = false
    /// Rules skipped as invalid or timed out on this document.
    var invalid = 0
    var timedOut = 0
}

/// **The fill of a document's correspondent, type and tags in a background write** (plan of #10, §3, §4a): the one
/// seam the text result write and the bulk run (`MatchingRun`) share, and #11's detection extends.
///
/// - **One fetch** of the live correspondents, types and tags (`RowRecords.fetchMetadata`, keeper order) in the
///   write's context, only when a step needs it (review N4: a text write without rules fetches nothing).
/// - **Rules first** (`applyRules`): the correspondent and the type only when the document has none, matching tags
///   added; nothing is removed or replaced, `touch()` is never called, and an outcome that changes nothing writes
///   nothing (T4). Only live records are linked.
/// - **Detection second** (#11, part 2) adds its step here, on the row as the rules left it: on the `done` path in
///   the text write, on the `classify` path after the classifier, in both classification exits (#11's Q3).
/// - **One related-row map** (`related`) collects every metadata row a step links. A link writes the record's
///   inverse relationship, so the write's check reads each of them again with the document row
///   (`RowState.read`); a rule edited, renamed or merged in the window makes the write back off. The rows a
///   document had linked before are not in it: no decision of a fill reads them (emptiness is the document row's
///   link, which the check compares).
struct MetadataFill {
    /// The live records of the write's context, by `instanceID`: the first in keeper order (oldest `createdAt`, then
    /// the smaller `instanceID.uuidString`), as the repair keeps them.
    struct Live {
        var tags: [UUID: Tag] = [:]
        var correspondents: [UUID: Correspondent] = [:]
        var documentTypes: [UUID: DocumentType] = [:]
    }

    let context: ModelContext
    /// Every metadata row a step linked, as this context read it.
    private(set) var related: [RowKey: RowState] = [:]
    private var fetched: Live?

    init(context: ModelContext) {
        self.context = context
    }

    /// The live records, fetched once per fill.
    mutating func live() throws -> Live {
        if let fetched { return fetched }
        let metadata = try RowRecords.fetchMetadata(in: context)
        var live = Live()
        for record in keeperOrder(metadata.tags.filter(\.isLive), \.createdAt, \.instanceID)
        where live.tags[record.instanceID] == nil {
            live.tags[record.instanceID] = record
        }
        for record in keeperOrder(metadata.correspondents.filter(\.isLive), \.createdAt, \.instanceID)
        where live.correspondents[record.instanceID] == nil {
            live.correspondents[record.instanceID] = record
        }
        for record in keeperOrder(metadata.documentTypes.filter(\.isLive), \.createdAt, \.instanceID)
        where live.documentTypes[record.instanceID] == nil {
            live.documentTypes[record.instanceID] = record
        }
        fetched = live
        return live
    }

    /// The text write's rules (§4, N6): when the live rules this context fetched differ from the snapshot (a rule
    /// added, edited, merged or removed in between), the outcome is evaluated again on the fetched rules.
    mutating func applyRules(_ rules: TextWriteRules, to document: Document) throws -> RuleFill {
        var outcome = rules.outcome
        let current = MatchingStore.rules(of: try live())
        if Set(current) != Set(rules.rules) {
            outcome = MatchingRules.evaluate(text: rules.text, rules: current, budget: rules.budget)
        }
        return try applyRules(outcome, to: document)
    }

    /// Rules first (§3): applies `outcome` to the document as this context fetched it.
    mutating func applyRules(_ outcome: RuleOutcome, to document: Document) throws -> RuleFill {
        var fill = RuleFill(invalid: outcome.invalid.count, timedOut: outcome.timedOut.count)
        fill.ambiguous =
            (outcome.ambiguous.contains(.correspondent) && document.correspondent == nil)
            || (outcome.ambiguous.contains(.documentType) && document.documentType == nil)
        guard outcome.correspondent != nil || outcome.documentType != nil || !outcome.tags.isEmpty else { return fill }
        let live = try live()
        if document.correspondent == nil, let id = outcome.correspondent, let record = live.correspondents[id] {
            related[RowKey(entity: .correspondent, instanceID: id)] = RowState.capture(record)
            document.correspondent = record
            fill.changed = true
        }
        if document.documentType == nil, let id = outcome.documentType, let record = live.documentTypes[id] {
            related[RowKey(entity: .documentType, instanceID: id)] = RowState.capture(record)
            document.documentType = record
            fill.changed = true
        }
        let tags = document.tags ?? []
        let linked = Set(tags.map(\.instanceID))
        let added = outcome.tags.subtracting(linked).sorted { $0.uuidString < $1.uuidString }.compactMap {
            live.tags[$0]
        }
        if !added.isEmpty {
            for record in added {
                related[RowKey(entity: .tag, instanceID: record.instanceID)] = RowState.capture(record)
            }
            document.tags = tags + added
            fill.changed = true
        }
        return fill
    }
}

/// `records` in the repair's keeper order: oldest `createdAt`, then the smaller `instanceID.uuidString`.
func keeperOrder<T>(_ records: [T], _ createdAt: KeyPath<T, Date>, _ instanceID: KeyPath<T, UUID>) -> [T] {
    records.sorted { lhs, rhs in
        lhs[keyPath: createdAt] != rhs[keyPath: createdAt]
            ? lhs[keyPath: createdAt] < rhs[keyPath: createdAt]
            : lhs[keyPath: instanceID].uuidString < rhs[keyPath: instanceID].uuidString
    }
}
