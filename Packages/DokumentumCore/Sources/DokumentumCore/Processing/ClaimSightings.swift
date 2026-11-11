import DokumentumKit
import Foundation

/// When this device first saw each other device's current claim (#97 point 1, T8): per document, in the per-device
/// `UserDefaults` next to `ProcessingFailures`, never synced. The claim rules let a claim expire once this device has
/// seen it unchanged for the takeover interval (`ProcessingClaimRules`), so a claim written by a fast clock is never
/// taken over at once and never waited for longer than the interval of this device's time.
///
/// One dictionary under `defaultsKey`, keyed by the document's `instanceID`. A document's sighting is replaced when
/// its claim changes, removed when the queue sees it without another device's claim, and pruned with the failure
/// counters when the document is `done` or gone. Only the processing queue writes it, one document at a time.
public struct ClaimSightings: Sendable {
    /// The key in the per-device defaults.
    public static let defaultsKey = "processingClaimSightings"

    /// The `UserDefaults` suite; `nil` is `UserDefaults.standard`.
    public let defaultsSuite: String?

    public init(defaultsSuite: String?) {
        self.defaultsSuite = defaultsSuite
    }

    /// Records that this device sees `deviceID`'s claim made at `claimedAt` on `document` at `now`, and returns
    /// since when it has seen this claim (`ClaimSighting.seeing`: a sighting in the future moves to `now`).
    public func see(_ document: UUID, deviceID: String, claimedAt: Date, now: Date) -> Date {
        var all = sightings
        let earlier = all[document.uuidString]
        let sighting = ClaimSighting.seeing(deviceID: deviceID, claimedAt: claimedAt, now: now, after: earlier)
        if sighting != earlier {
            all[document.uuidString] = sighting
            sightings = all
        }
        return sighting.seenAt
    }

    public func sighting(of document: UUID) -> ClaimSighting? {
        sightings[document.uuidString]
    }

    /// Removes the sightings of `documents`, in one write.
    public func forget(_ documents: [UUID]) {
        var all = sightings
        var changed = false
        for document in documents where all.removeValue(forKey: document.uuidString) != nil { changed = true }
        if changed { sightings = all }
    }

    /// The documents that have a sighting.
    public var documents: [UUID] {
        sightings.keys.compactMap(UUID.init(uuidString:))
    }

    private var defaults: UserDefaults {
        defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    private var sightings: [String: ClaimSighting] {
        get {
            let stored = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
            return stored.compactMapValues { value in
                guard let fields = value as? [String: Any], let deviceID = fields["deviceID"] as? String,
                    let claimedAt = fields["claimedAt"] as? Date, let seenAt = fields["seenAt"] as? Date
                else { return nil }
                return ClaimSighting(deviceID: deviceID, claimedAt: claimedAt, seenAt: seenAt)
            }
        }
        nonmutating set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.defaultsKey)
                return
            }
            let stored = newValue.mapValues { sighting -> [String: Any] in
                ["deviceID": sighting.deviceID, "claimedAt": sighting.claimedAt, "seenAt": sighting.seenAt]
            }
            defaults.set(stored, forKey: Self.defaultsKey)
        }
    }
}
