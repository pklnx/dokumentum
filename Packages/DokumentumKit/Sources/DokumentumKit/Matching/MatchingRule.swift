import Foundation

// Matching rules (#10, part 1b; plan of #10, Approach 2): a tag's, correspondent's or document type's rule decides
// from a document's text whether that record is set. Foundation only, so `kit-linux` tests it too.

/// The limits of matching (plan of #10, T6 and T8). Constants: nothing is stored per device.
public enum MatchingLimits {
    /// The longest pattern the editor saves, in characters; a longer one that arrives by sync is skipped.
    public static let patternLength = 1_000
    /// The time a regular expression may take on one document (P-2, R-1 of the plan): it then does not match that
    /// document.
    public static let regexBudget: Duration = .milliseconds(100)
    /// Documents per batch of the bulk run (`MatchingRun`): at most about 25 MB of text in memory.
    public static let batchSize = 50
}

/// One record's rule as a value: what `MatchingRules` evaluates. Built from live records only; the store never
/// hands a tombstone's rule over.
public struct MatchingRule: Sendable, Hashable {
    /// The record's `instanceID`.
    public var id: UUID
    public var kind: MetadataKind
    /// The record's name, for the bulk run's result (user data: never logged).
    public var name: String
    public var mode: MatchMode
    public var pattern: String

    public init(id: UUID, kind: MetadataKind, name: String, mode: MatchMode, pattern: String) {
        self.id = id
        self.kind = kind
        self.name = name
        self.mode = mode
        self.pattern = pattern
    }
}

/// What the rules decide for one document (plan of #10, Approach 2).
///
/// - A correspondent or type only when exactly one record of that kind matches; with several the field stays
///   empty and the kind is in `ambiguous` (P2, maintainer), so detection or the classifier may fill it.
/// - Every matching tag.
/// - `invalid` and `timedOut` name the rules that were skipped: they match nothing.
///
/// The outcome is a function of the text and the set of rules, never of their order (T7).
public struct RuleOutcome: Sendable, Equatable {
    public var correspondent: UUID?
    public var documentType: UUID?
    public var tags: Set<UUID> = []
    /// The kinds of which more than one record matched.
    public var ambiguous: Set<MetadataKind> = []
    /// Rules that cannot run: a regular expression that does not compile, or a pattern over the length limit.
    public var invalid: Set<UUID> = []
    /// Regular expressions that ran out of their budget on this text.
    public var timedOut: Set<UUID> = []

    public init(
        correspondent: UUID? = nil, documentType: UUID? = nil, tags: Set<UUID> = [],
        ambiguous: Set<MetadataKind> = [], invalid: Set<UUID> = [], timedOut: Set<UUID> = []
    ) {
        self.correspondent = correspondent
        self.documentType = documentType
        self.tags = tags
        self.ambiguous = ambiguous
        self.invalid = invalid
        self.timedOut = timedOut
    }
}
