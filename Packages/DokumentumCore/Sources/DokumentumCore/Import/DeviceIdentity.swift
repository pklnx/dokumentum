import Foundation

/// This device's `processingDeviceID` (plan of #4, part 2): a random UUID string, stored once in the
/// per-device `UserDefaults` (`ProcessingEnvironment.defaultsSuite`) and never synced. A reinstall gets a new
/// ID; claims of the old one are taken over after 6 hours like any other (part 5).
public enum DeviceIdentity {
    /// The key in the per-device defaults.
    public static let defaultsKey = "processingDeviceID"

    /// The stored ID, or a new one that is stored first.
    public static func processingDeviceID(in defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: defaultsKey), UUID(uuidString: stored) != nil { return stored }
        let id = UUID().uuidString
        defaults.set(id, forKey: defaultsKey)
        return id
    }

    /// The ID in the defaults of `environment` (`defaultsSuite`; `nil` is `UserDefaults.standard`).
    public static func processingDeviceID(environment: ProcessingEnvironment = .current) -> String {
        let defaults = environment.defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        return processingDeviceID(in: defaults)
    }
}
