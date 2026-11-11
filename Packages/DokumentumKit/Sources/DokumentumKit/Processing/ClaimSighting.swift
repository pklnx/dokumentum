import Foundation

/// When this device first saw another device's claim on a document (#97 point 1, T8): kept per device and per
/// document, never synced, so the claim rules can let a claim that this device has seen unchanged for the takeover
/// interval expire, whatever time the claim carries.
public struct ClaimSighting: Equatable, Sendable {
    /// The claiming device and its claim time, as this device read them.
    public var deviceID: String
    public var claimedAt: Date
    /// When this device first saw this claim, by its own clock.
    public var seenAt: Date

    public init(deviceID: String, claimedAt: Date, seenAt: Date) {
        self.deviceID = deviceID
        self.claimedAt = claimedAt
        self.seenAt = seenAt
    }

    /// The sighting after seeing the claim (`deviceID`, `claimedAt`) at `now`: the earlier sighting when it is the
    /// same claim, else a new one from `now`. A sighting in the future (the clock was set back) is moved to `now`,
    /// so it never waits longer than the interval from here.
    public static func seeing(
        deviceID: String, claimedAt: Date, now: Date, after earlier: ClaimSighting?
    ) -> ClaimSighting {
        guard let earlier, earlier.deviceID == deviceID, earlier.claimedAt == claimedAt else {
            return ClaimSighting(deviceID: deviceID, claimedAt: claimedAt, seenAt: now)
        }
        return ClaimSighting(deviceID: deviceID, claimedAt: claimedAt, seenAt: min(earlier.seenAt, now))
    }
}
