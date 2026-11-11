import Foundation

/// This device's failure counter per document (plan of #4, part 5, N10): how often processing a document failed
/// here. Kept in the per-device `UserDefaults` (`ProcessingEnvironment.defaultsSuite`), never synced: a synced
/// counter would be one more field both devices write. One dictionary under `defaultsKey`, keyed by the document's
/// `instanceID`. A key is removed when the document reaches `done` (on this device's write, or when the queue sees
/// it `done` or gone), so the keys do not grow.
///
/// Only the processing queue writes it, one document at a time, so it needs no lock.
public struct ProcessingFailures: Sendable {
    /// The key in the per-device defaults.
    public static let defaultsKey = "processingFailures"

    /// The `UserDefaults` suite; `nil` is `UserDefaults.standard`. A name, because `UserDefaults` is not `Sendable`.
    public let defaultsSuite: String?

    public init(defaultsSuite: String?) {
        self.defaultsSuite = defaultsSuite
    }

    /// The counter of `environment`'s defaults (the app's: `UserDefaults.standard`).
    public init(environment: ProcessingEnvironment = .current) {
        self.init(defaultsSuite: environment.defaultsSuite)
    }

    private var defaults: UserDefaults {
        defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    private var counts: [String: Int] {
        get { (defaults.dictionary(forKey: Self.defaultsKey) as? [String: Int]) ?? [:] }
        nonmutating set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.defaultsKey)
            } else {
                defaults.set(newValue, forKey: Self.defaultsKey)
            }
        }
    }

    public func count(for document: UUID) -> Int {
        counts[document.uuidString] ?? 0
    }

    /// Counts one more failure and returns the new count.
    @discardableResult
    public func increment(for document: UUID) -> Int {
        let count = self.count(for: document) + 1
        counts[document.uuidString] = count
        return count
    }

    public func remove(_ document: UUID) {
        guard counts[document.uuidString] != nil else { return }
        counts[document.uuidString] = nil
    }

    /// The documents that have a counter.
    public var documents: [UUID] {
        counts.keys.compactMap(UUID.init(uuidString:))
    }
}
