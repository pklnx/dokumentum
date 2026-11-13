// Frozen enums: values that sync as raw strings (the `*Raw` fields on the models).
//
// **The rule: raw values never change; new cases may be added.** Another device may run an older or a
// newer build, so a value this build does not know is normal. Reading maps it to a fallback case; the
// stored string stays as it is until someone sets a real new value. Fallbacks are never written back.

/// How a document came into the archive. Unknown values read as `.file`.
public enum DocumentSource: String, Hashable, Sendable, CaseIterable {
    case file
    case scan
    case image

    /// Never fails: an unknown value from a newer build reads as `.file`.
    public init(storedValue: String) {
        self = DocumentSource(rawValue: storedValue) ?? .file
    }

    /// The string to store for this case.
    public var storedValue: String { rawValue }
}

/// Where a document's text comes from. Unknown values read as `.unknown`, which has no stored value.
public enum TextSource: Hashable, Sendable, CaseIterable {
    case none
    case pdfText
    case vision
    /// Read-only: a value from a newer build. It has no raw value, so it can never be written.
    case unknown

    /// Never fails: an unknown value from a newer build reads as `.unknown`.
    public init(storedValue: String) {
        switch storedValue {
        case "": self = .none
        case "pdfText": self = .pdfText
        case "vision": self = .vision
        default: self = .unknown
        }
    }

    /// The string to store for this case; `nil` for `.unknown`, which a setter must leave out.
    public var storedValue: String? {
        switch self {
        case .none: ""
        case .pdfText: "pdfText"
        case .vision: "vision"
        case .unknown: nil
        }
    }
}

/// Where a document is in the processing queue. Unknown values read as `.unknown`, which has no stored
/// value; the queue never touches a document in `.unknown`, so an older build leaves a newer state alone.
public enum ProcessingState: Hashable, Sendable, CaseIterable {
    case pending
    case processing
    /// The text is written and the classification step (#8) has not run yet. Added after step 6: an older build
    /// reads it as `.unknown` and never touches the document.
    case classify
    case done
    case failed
    /// Read-only: a value from a newer build. It has no raw value, so it can never be written.
    case unknown

    /// Never fails: an unknown value from a newer build reads as `.unknown`.
    public init(storedValue: String) {
        switch storedValue {
        case "pending": self = .pending
        case "processing": self = .processing
        case "classify": self = .classify
        case "done": self = .done
        case "failed": self = .failed
        default: self = .unknown
        }
    }

    /// The string to store for this case; `nil` for `.unknown`, which a setter must leave out.
    public var storedValue: String? {
        switch self {
        case .pending: "pending"
        case .processing: "processing"
        case .classify: "classify"
        case .done: "done"
        case .failed: "failed"
        case .unknown: nil
        }
    }
}

/// How a tag's, correspondent's or document type's matching rule compares its pattern with a document's text
/// (#10). Stored on the record (`matchModeRaw`), synced. Unknown values read as `.unknown`, which has no stored
/// value and never matches, so an older build leaves a newer mode alone.
public enum MatchMode: Hashable, Sendable, CaseIterable {
    /// No rule: the default of every record.
    case none
    /// One of the pattern's words or quoted phrases occurs.
    case any
    /// Every one of the pattern's words or quoted phrases occurs, in any order.
    case all
    /// The whole pattern occurs as consecutive words.
    case exact
    /// The pattern is a regular expression, case-insensitive.
    case regex
    /// Read-only: a value from a newer build. It has no raw value, so it can never be written.
    case unknown

    /// Never fails: an unknown value from a newer build reads as `.unknown`.
    public init(storedValue: String) {
        switch storedValue {
        case "": self = .none
        case "any": self = .any
        case "all": self = .all
        case "exact": self = .exact
        case "regex": self = .regex
        default: self = .unknown
        }
    }

    /// The string to store for this case; `nil` for `.unknown`, which a setter must leave out.
    public var storedValue: String? {
        switch self {
        case .none: ""
        case .any: "any"
        case .all: "all"
        case .exact: "exact"
        case .regex: "regex"
        case .unknown: nil
        }
    }
}
