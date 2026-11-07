import DokumentumCore
import Foundation
import Testing

/// This device's `processingDeviceID`: made once, then read back; per defaults suite.
struct DeviceIdentityTests {
    @Test func theIDIsMadeOnceAndKept() throws {
        let suite = "DokumentumTests-DeviceIdentity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = DeviceIdentity.processingDeviceID(in: defaults)
        #expect(UUID(uuidString: first) != nil)
        #expect(DeviceIdentity.processingDeviceID(in: defaults) == first)
        #expect(defaults.string(forKey: DeviceIdentity.defaultsKey) == first)
        #expect(
            DeviceIdentity.processingDeviceID(environment: ProcessingEnvironment(defaultsSuite: suite)) == first)
    }

    @Test func aValueThatIsNoUUIDIsReplaced() throws {
        let suite = "DokumentumTests-DeviceIdentity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("", forKey: DeviceIdentity.defaultsKey)

        let id = DeviceIdentity.processingDeviceID(in: defaults)
        #expect(UUID(uuidString: id) != nil)
        #expect(defaults.string(forKey: DeviceIdentity.defaultsKey) == id)
    }
}
