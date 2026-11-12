import Foundation

// The plain values of the classification step (#8): what the classifier is asked with, what it answers, and how
// it can fail. The classifier itself (Foundation Models, part 2) lives in DokumentumCore; tests use a stub.

/// What a classifier suggests for one document, as it answered: every field optional, nothing checked yet
/// (`SuggestionRules` checks it before anything is written).
public struct ClassificationSuggestion: Equatable, Sendable {
    public var title: String?
    public var correspondent: String?
    public var documentType: String?
    /// Names of known tags.
    public var tags: [String]
    public var issueDate: SuggestedDate?

    public init(
        title: String? = nil, correspondent: String? = nil, documentType: String? = nil, tags: [String] = [],
        issueDate: SuggestedDate? = nil
    ) {
        self.title = title
        self.correspondent = correspondent
        self.documentType = documentType
        self.tags = tags
        self.issueDate = issueDate
    }
}

/// A calendar date as three numbers (P-j of the plan: one string was misread, three integers were not).
public struct SuggestedDate: Equatable, Hashable, Sendable {
    public var day: Int
    public var month: Int
    public var year: Int

    public init(day: Int, month: Int, year: Int) {
        self.day = day
        self.month = month
        self.year = year
    }
}

/// The archive's live records the classifier may reuse, most used first and capped
/// (`ClassificationLimits.knownNames`, `knownTags`).
public struct KnownMetadata: Equatable, Sendable {
    public var correspondents: [String]
    public var documentTypes: [String]
    public var tags: [String]

    public init(correspondents: [String] = [], documentTypes: [String] = [], tags: [String] = []) {
        self.correspondents = correspondents
        self.documentTypes = documentTypes
        self.tags = tags
    }
}

/// Whether the classifier can run on this device now.
public enum ClassifierAvailability: Equatable, Sendable {
    case available
    /// The model is being prepared (downloading). The step waits without counting an attempt (#8, T4).
    case notReady
    /// It will not run here: the step finishes the document without suggestions.
    case unavailable(UnavailableReason)

    public enum UnavailableReason: Equatable, Sendable {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        /// A reason of a newer system.
        case other
    }
}

/// How a classification request can fail in a way the step treats specially (#8, T4). Any other error counts as
/// a failed attempt.
public enum ClassificationFailure: Error, Equatable, Sendable {
    /// The model declined (a refusal, a guardrail, a language it does not support): the document is finished
    /// without suggestions and never asked again. P8: no note on the document, only the log.
    case declined(DeclineReason)
    /// The system limits requests for now (an app in the background): the attempt is given back and the step
    /// tries again at `until`, or after `ClassificationLimits.rateLimitPause`.
    case rateLimited(until: Date?)
    /// The model's assets became unavailable during the request: like `ClassifierAvailability.notReady`.
    case notReady

    public enum DeclineReason: String, Equatable, Sendable {
        case refusal, guardrailViolation, unsupportedLanguage
    }

    /// A fixed code for the log.
    public var code: String {
        switch self {
        case .declined(let reason): "declined.\(reason.rawValue)"
        case .rateLimited: "rateLimited"
        case .notReady: "notReady"
        }
    }
}

/// The numbers of the classification step (plan of #8, Approach 3 and 4).
public enum ClassificationLimits {
    /// A text with fewer non-whitespace characters is not sent to the model (P-h: it invents values).
    public static let minimumTextCharacters = 50
    public static let titleCharacters = 80
    public static let correspondentCharacters = 80
    public static let documentTypeCharacters = 40
    public static let documentTypeWords = 3
    public static let tags = 3
    /// Known correspondents and types in the prompt, each.
    public static let knownNames = 100
    /// Known tags in the schema.
    public static let knownTags = 150
    public static let earliestYear = 1900
    /// How long the step waits after a rate limit without a reset date.
    public static let rateLimitPause: TimeInterval = 15 * 60
    /// The shortest pause after a rate limit, also when its reset date has passed (review B N-1 of #146).
    public static let minimumRateLimitPause: TimeInterval = 60
    /// After a request threw "not ready", the next request waits this long (at most until the claim ends).
    public static let notReadyRetry: TimeInterval = 15 * 60
    /// The most tokens of a document's text the model gets (T8): the head, where the sender, the date and the
    /// subject are. About 3 s per request on the Mac (P-e).
    public static let textTokens = 2000
    /// The longest answer (`maximumResponseTokens`); also kept free of the context for it.
    public static let responseTokens = 300
    /// The first cut of the text is by bytes: fewer than measured for German and English (2.05 to 2.6, P-c), so
    /// the first cut is rarely too long.
    public static let bytesPerToken = 2.0
    /// How often the text is counted at most before it is sent (`TextBudget.fit`).
    public static let budgetRounds = 3
    /// Values a model writes for "unknown": dropped (compared after `MetadataName.normalized`).
    public static let placeholders: Set<String> = [
        "unbekannt", "unklar", "unknown", "n/a", "na", "none", "keine", "keiner", "kein", "-", "--", "?", "null",
        "nil",
    ]

    /// The number of non-whitespace characters of `text` (a decomposed umlaut counts once).
    public static func meaningfulCharacters(in text: String) -> Int {
        text.reduce(0) { count, character in character.isWhitespace ? count : count + 1 }
    }
}
