// Frozen enums: values that sync as raw strings (the `*Raw` fields on `Document`).
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
    case done
    case failed
    /// Read-only: a value from a newer build. It has no raw value, so it can never be written.
    case unknown

    /// Never fails: an unknown value from a newer build reads as `.unknown`.
    public init(storedValue: String) {
        switch storedValue {
        case "pending": self = .pending
        case "processing": self = .processing
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
        case .done: "done"
        case .failed: "failed"
        case .unknown: nil
        }
    }
}
