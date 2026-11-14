import DokumentumKit
import Foundation
import SwiftData

/// A record's matching rule as the editor shows and saves it (plan of #10, §8).
public struct MatchingRuleValue: Sendable, Equatable {
    public var mode: MatchMode
    public var pattern: String

    public init(mode: MatchMode, pattern: String) {
        self.mode = mode
        self.pattern = pattern
    }
}

/// The one place that saves a tag's, correspondent's or document type's matching rule (plan of #10, §8): the model
/// side of the rule sheet (#10, part 2), in the main context, like `DocumentEditor`.
///
/// - **Only the fields the user changed** are written (`nil` leaves a field alone): a draft can be older than the
///   store (review A of #57), and CloudKit's last writer wins per field.
/// - **Only on a live record:** a record merged away or gone meanwhile is left alone (`noMetadata`).
/// - **`unknown`** (a newer build's mode) is kept unless the user picks a mode: passing it writes nothing.
/// - **Validated** (`MatchingRuleValidation.check`) on the values the record will hold; the sheet disables Save
///   before, this refuses what it would not allow.
/// - **One save; a failed save is rolled back**, so nothing stays pending for a later save. No `touch()`: a record
///   has no modification date, and the documents are not changed.
@MainActor
public struct MatchingRuleEditor {
    public enum Outcome: Sendable, Equatable {
        case saved
        /// The record already holds these values: nothing was written.
        case unchanged
        /// No live record with that `instanceID` (gone or merged meanwhile).
        case noMetadata
        /// The values would not be a valid rule; nothing was written.
        case invalid(MatchingRuleValidation.Problem)
    }

    public let context: ModelContext
    private let saveContext: (ModelContext) throws -> Void

    /// - Parameters:
    ///   - context: the main context, so the library's read sees the change at once.
    ///   - save: saves the context; tests pass one that fails.
    public init(context: ModelContext, save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.context = context
        saveContext = save
    }

    /// The rule of the live record of `kind` with `instanceID`, or `nil` when there is none.
    public func rule(of kind: MetadataKind, _ instanceID: UUID) throws -> MatchingRuleValue? {
        try StoreLibrarySource.matchingRule(of: kind, instanceID, in: context)
    }

    /// What the rule sheet (#200) shows for a record.
    public enum RecordState: Sendable, Equatable {
        /// The live record's rule: the sheet edits it.
        case rule(MatchingRuleValue)
        /// A live record whose `instanceID` other records share: matching never applies its rule
        /// (`MatchingStore.withoutCopies`), and `save` refuses it (`noMetadata`), so the sheet says so instead of
        /// offering an edit that would change nothing (review A of #205, N6).
        case copies
        /// No live record with that `instanceID` (gone, or merged away).
        case gone
    }

    /// The state of the record of `kind` with `instanceID`: its rule, `copies`, or `gone`.
    public func state(of kind: MetadataKind, _ instanceID: UUID) throws -> RecordState {
        let records = try Self.records(kind, instanceID, in: context)
        guard records.contains(where: \.isLive) else { return .gone }
        guard records.count == 1 else { return .copies }
        return .rule(MatchingRuleValue(mode: records[0].matchMode, pattern: records[0].matchPattern))
    }

    /// Saves the changed fields of the rule of the live record of `kind` with `instanceID`.
    /// - Parameters:
    ///   - mode: the mode the user picked, `nil` when untouched; `.unknown` writes nothing.
    ///   - pattern: the pattern as typed, `nil` when untouched.
    @discardableResult
    public func save(_ kind: MetadataKind, _ instanceID: UUID, mode: MatchMode? = nil, pattern: String? = nil) throws
        -> Outcome
    {
        guard let record = try Self.live(kind, instanceID, in: context) else { return .noMetadata }
        let mode = mode == .unknown ? nil : mode
        if let problem = MatchingRuleValidation.check(
            mode: mode ?? record.matchMode, pattern: pattern ?? record.matchPattern)
        {
            return .invalid(problem)
        }
        var changed = false
        if let mode, record.matchMode != mode {
            record.matchMode = mode
            changed = true
        }
        if let pattern, record.matchPattern != pattern {
            record.matchPattern = pattern
            changed = true
        }
        guard changed else { return .unchanged }
        do {
            try saveContext(context)
        } catch {
            context.rollback()
            throw error
        }
        return .saved
    }

    /// The live record with `instanceID`, when it has no copies sharing it (review B of #205, N5): the same records
    /// matching uses.
    nonisolated static func live(_ kind: MetadataKind, _ instanceID: UUID, in context: ModelContext) throws
        -> (any MatchingRuleRecord)?
    {
        // Only a record without copies (`MatchingStore.withoutCopies`): matching ignores a record with copies, so
        // editing one copy's rule would do nothing, and which copy a fetch returns first is not stable.
        let records = try records(kind, instanceID, in: context)
        return records.count == 1 && records[0].isLive ? records[0] : nil
    }

    /// Every record of `kind` with `instanceID`, tombstones and copies included.
    private nonisolated static func records(_ kind: MetadataKind, _ instanceID: UUID, in context: ModelContext) throws
        -> [any MatchingRuleRecord]
    {
        switch kind {
        case .tag:
            return try context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.instanceID == instanceID }))
        case .correspondent:
            return try context.fetch(
                FetchDescriptor<Correspondent>(predicate: #Predicate { $0.instanceID == instanceID }))
        case .documentType:
            return try context.fetch(
                FetchDescriptor<DocumentType>(predicate: #Predicate { $0.instanceID == instanceID }))
        }
    }
}

/// A record with a matching rule: a tag, correspondent or document type.
protocol MatchingRuleRecord: AnyObject {
    var instanceID: UUID { get }
    var isLive: Bool { get }
    var matchMode: MatchMode { get set }
    var matchPattern: String { get set }
}

extension Tag: MatchingRuleRecord {}
extension Correspondent: MatchingRuleRecord {}
extension DocumentType: MatchingRuleRecord {}
