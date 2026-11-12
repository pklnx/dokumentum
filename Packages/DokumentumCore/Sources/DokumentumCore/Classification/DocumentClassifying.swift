import DokumentumKit
import Foundation

/// What the processing queue's classification step calls (#8): the on-device model in the app
/// (`FoundationModelsClassifier`, part 2), a stub in tests. Implementations never send anything off the device.
///
/// - `availability` is read at each decision, synchronously.
/// - `classify` throws `ClassificationFailure` for the outcomes the step treats specially (declined, rate
///   limited, not ready); any other error counts as a failed attempt. It is cancelled after `interruptNow()` or
///   the stall timeout and may keep running until it returns; its answer is then dropped.
public protocol DocumentClassifying: Sendable {
    var availability: ClassifierAvailability { get }
    func classify(text: String, known: KnownMetadata) async throws -> ClassificationSuggestion
}

/// This device's classification settings in the per-device defaults (`ProcessingEnvironment.defaultsSuite`), never
/// synced (#8, T16, P3, P4, P9):
/// - `classification.enabled`: the switch, **on** when it was never set. Read at each decision.
/// - `classification.since`: when this device's queue first ran with a classifier. **The cut-off of P9:** a
///   document is classified only if it was created (`Document.createdAt`, the importing device's clock) at or
///   after that moment; documents imported before, also those still waiting for their text and step 3's documents
///   that the re-queue sends through the text step again, finish in `done` as before. Written once, never moved.
public struct ClassificationSettings: Sendable {
    public static let enabledKey = "classification.enabled"
    public static let sinceKey = "classification.since"

    /// The `UserDefaults` suite; `nil` is `UserDefaults.standard`.
    public let defaultsSuite: String?

    public init(defaultsSuite: String?) {
        self.defaultsSuite = defaultsSuite
    }

    private var defaults: UserDefaults {
        defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// The switch (P3: on by default).
    public var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// The cut-off, if the queue has run with a classifier on this device.
    public var since: Date? {
        defaults.object(forKey: Self.sinceKey) as? Date
    }

    /// The cut-off; `now` is stored when there is none yet.
    @discardableResult
    public func recordSince(_ now: Date) -> Date {
        if let since { return since }
        defaults.set(now, forKey: Self.sinceKey)
        return now
    }
}
