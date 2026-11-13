import DokumentumKit
import Foundation
import SwiftData

// Matching rules on the store (#10, part 1b): the rules as values, and the shared fill of a background write.
// docs/development/index.md, "Matching rules", has the whole picture.

/// The rule records of the store as values.
enum MatchingStore {
    /// The rule records as values, and how many rule records were left out because their record has copies.
    struct RuleRecords {
        var rules: [MatchingRule] = []
        /// Distinct `instanceID`s of live records with a rule whose record has copies (`withoutCopies`).
        var copied = 0
    }

    /// The live rule records (a `matchModeRaw` that is not `""`, not merged away), in a context that ends with the
    /// read: one fetch per entity with a predicate on the rule field, so a store without rules reads no row (review
    /// N4). A tombstone is never a rule (T10), and neither is a record with **copies sharing its `instanceID`**
    /// (`withoutCopies`, review A of #205, B1). Copies are counted among **all** records of those `instanceID`s, as the
    /// fill counts them (review A of #205, N5): a second fetch by `instanceID`, only when rules exist.
    static func readRules(in container: ModelContainer) throws -> [MatchingRule] {
        try readRuleRecords(in: container).rules
    }

    static func readRuleRecords(in container: ModelContainer) throws -> RuleRecords {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let none = MatchMode.none.storedValue ?? ""
        let tags = try context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.matchModeRaw != none }))
        let correspondents = try context.fetch(
            FetchDescriptor<Correspondent>(predicate: #Predicate { $0.matchModeRaw != none }))
        let types = try context.fetch(
            FetchDescriptor<DocumentType>(predicate: #Predicate { $0.matchModeRaw != none }))
        var records = RuleRecords()
        if !tags.isEmpty {
            let ids = Array(Set(tags.map(\.instanceID)))
            let all = try context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { ids.contains($0.instanceID) }))
            records.add(tags, all: all, rule: rule)
        }
        if !correspondents.isEmpty {
            let ids = Array(Set(correspondents.map(\.instanceID)))
            let all = try context.fetch(
                FetchDescriptor<Correspondent>(predicate: #Predicate { ids.contains($0.instanceID) }))
            records.add(correspondents, all: all, rule: rule)
        }
        if !types.isEmpty {
            let ids = Array(Set(types.map(\.instanceID)))
            let all = try context.fetch(
                FetchDescriptor<DocumentType>(predicate: #Predicate { ids.contains($0.instanceID) }))
            records.add(types, all: all, rule: rule)
        }
        return records
    }

    /// `records` without every record whose `instanceID` another record of `records` shares (review A of #205, B1).
    ///
    /// Why not the first one read, as `RowRecords` keeps it: the order of a fetch without sort descriptors is not
    /// stable between contexts (measured: of two live copies, the write's context read the younger one first in 3 of
    /// 10 runs, the check's context the older one), so the fill would link one copy and the check read the other, and
    /// the write would back off on every attempt. A record with copies is therefore treated like a tombstone in
    /// matching: never a rule, never linked, so no check ever has to meet it. Copies are rare (a copied record, or a
    /// merge's loser and its copy); a copy without a rule next to one with a rule is not fetched here, so the snapshot
    /// keeps that rule, and the text write's re-evaluation on the fill's records drops it.
    static func withoutCopies<T>(_ records: [T], _ instanceID: KeyPath<T, UUID>) -> [T] {
        var counts: [UUID: Int] = [:]
        for record in records { counts[record[keyPath: instanceID], default: 0] += 1 }
        return records.filter { counts[$0[keyPath: instanceID]] == 1 }
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

extension MatchingStore.RuleRecords {
    /// Adds the rules of `ruled` (records with a rule) that are live and whose `instanceID` no other record of `all`
    /// shares; counts the live ones left out for copies.
    fileprivate mutating func add<T: MatchingRuleRecord>(_ ruled: [T], all: [T], rule: (T) -> MatchingRule) {
        var counts: [UUID: Int] = [:]
        for record in all { counts[record.instanceID, default: 0] += 1 }
        var copied: Set<UUID> = []
        var seen: Set<UUID> = []
        for record in ruled where record.isLive && seen.insert(record.instanceID).inserted {
            if counts[record.instanceID, default: 0] > 1 {
                copied.insert(record.instanceID)
            } else {
                rules.append(rule(record))
            }
        }
        self.copied += copied.count
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
    /// The live records of the write's context, by `instanceID`, without records that have copies sharing their
    /// `instanceID` (`MatchingStore.withoutCopies`, review A of #205, B1): for one of those the write's check
    /// (`RowState.read`) could read another copy than the fill linked, and the write would back off for ever.
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
        for record in MatchingStore.withoutCopies(metadata.tags, \.instanceID) where record.isLive {
            live.tags[record.instanceID] = record
        }
        for record in MatchingStore.withoutCopies(metadata.correspondents, \.instanceID) where record.isLive {
            live.correspondents[record.instanceID] = record
        }
        for record in MatchingStore.withoutCopies(metadata.documentTypes, \.instanceID) where record.isLive {
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
