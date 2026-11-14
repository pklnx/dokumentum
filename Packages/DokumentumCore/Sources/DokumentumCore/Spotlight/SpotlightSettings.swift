import Foundation

/// Whether this device gives its documents to Spotlight (#13, plan §2; Q2): per device, never synced, **on** by default.
public protocol SpotlightSettingStoring: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool)
}

/// The setting as a `Bool` in a `UserDefaults` suite (#13, plan §2 and §5): this device's suite for the system index,
/// `inMemorySuiteName` (emptied at each such launch, part 2) for the in-memory one.
public struct SpotlightSettings: SpotlightSettingStoring {
    public static let key = "spotlight.enabled"
    /// The suite of every launch that uses the in-memory index (`SpotlightIndexChoice.inMemory`).
    public static let inMemorySuiteName = "Dokumentum.InMemorySpotlightSettings"

    /// `nil` for the standard defaults.
    public let suiteName: String?

    public init(suiteName: String?) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// On when nothing is stored (Q2).
    public var isEnabled: Bool { defaults.object(forKey: Self.key) as? Bool ?? true }

    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.key)
    }

    /// Forgets the stored value: the default (on) again.
    public func reset() {
        defaults.removeObject(forKey: Self.key)
    }
}
