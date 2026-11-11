import Foundation

/// What the processing queue knows about one document when it decides (plan of #4, part 5): read from the
/// document's row only, never from its file or text.
public struct ProcessingClaimInput: Equatable, Sendable {
    public var state: ProcessingState
    /// The claiming device's `processingDeviceID`; `""` for none.
    public var deviceID: String
    /// When that device claimed the document, by its own clock; `nil` for none.
    public var claimedAt: Date?
    public var isTrashed: Bool
    /// Whether the document links a file and a text record (`file != nil`, `text != nil` on its row). Whether the
    /// file's data has arrived is only known when it is loaded; processing never creates a text (#2, Revision 6).
    public var hasFile: Bool
    public var hasText: Bool
    /// When this device first saw the current claim of another device (the same `deviceID` and `claimedAt`), by
    /// its own clock (`ClaimSighting`, kept per device and never synced); `nil` for "first seen now". Ignored for
    /// this device's own claim and for no claim.
    public var claimSeenSince: Date?
    /// The earliest time this device may start its next attempt (`ProcessingBackoff`), by its own clock; `nil`
    /// for no backoff.
    public var retryNotBefore: Date?

    public init(
        state: ProcessingState, deviceID: String, claimedAt: Date?, isTrashed: Bool = false, hasFile: Bool = true,
        hasText: Bool = true, claimSeenSince: Date? = nil, retryNotBefore: Date? = nil
    ) {
        self.state = state
        self.deviceID = deviceID
        self.claimedAt = claimedAt
        self.isTrashed = isTrashed
        self.hasFile = hasFile
        self.hasText = hasText
        self.claimSeenSince = claimSeenSince
        self.retryNotBefore = retryNotBefore
    }
}

/// The queue's decision for one document.
public enum ProcessingDecision: Equatable, Sendable {
    /// Nothing to do, now or later on this device.
    case skip(SkipReason)
    /// Not now: another device holds a fresh claim, or the file or text has not arrived.
    case wait(WaitReason)
    /// Process it; `claim` says what the claim write does first.
    case process(ClaimWrite)

    public enum SkipReason: Equatable, Sendable {
        case done
        /// `failed`, and this device's own failure counter reached the limit.
        case failedOnThisDevice
        /// A state of a newer build (`ProcessingState.unknown`): never written (frozen-enum rule).
        case unknownState
        /// In the trash; processed after a restore.
        case trashed
    }

    public enum WaitReason: Equatable, Sendable {
        /// Another device's claim is fresh. `until` is when it expires by this device's clock: the earlier of the
        /// claim time plus the takeover interval and its first sighting plus the interval.
        case claimedElsewhere(until: Date)
        case noFile
        case noText
        /// This device's last attempt failed and its backoff has not passed (`ProcessingBackoff`): not before
        /// the date, by this device's clock.
        case retryAfter(Date)
    }

    /// The claim write before the work.
    public enum ClaimWrite: Equatable, Sendable {
        /// The claim is already this device's and fresh: no write (a document this device just imported).
        case keep
        /// No claim, this device's own claim gone stale, or a `failed` document this device retries: claim it.
        case claim
        /// Another device's claim expired (6 hours old, or seen by this device for 6 hours): take it over.
        case takeOver
    }

    public var isProcess: Bool {
        if case .process = self { return true }
        return false
    }

    public var isWait: Bool {
        if case .wait = self { return true }
        return false
    }
}

/// The one decision for one document (plan of #4, part 5; #97 in the plan of #6, part 1):
///
/// | State | Claim | Decision |
/// |---|---|---|
/// | `done` | any | skip |
/// | `failed` | any | skip, unless this device's own failure counter is below the limit (3): then process (claim) |
/// | `unknown` | any | skip, never written |
/// | `pending`, `processing` | none, or this device | process (keep a fresh own claim, else claim) |
/// | `pending`, `processing` | another device, not expired | wait until it expires |
/// | `pending`, `processing` | another device, expired | take over |
///
/// Before the table: `unknown` is skipped first (even in the trash), then `done`, a trashed document, and a
/// document without its file or its text record (it waits; processing never creates them). After it, every
/// "process" waits while this device's backoff runs (`retryNotBefore`, T9): `wait(.retryAfter(date))`.
///
/// **Another device's claim expires** (T8) when its **age** (this device's clock minus `claimedAt`, which the
/// claiming device wrote with its own clock) is at least the interval, **or** this device has **seen it unchanged**
/// for the interval by its own clock (`claimSeenSince`). The second rule replaces step 3's "a claim more than the
/// interval in the future counts as expired": a future claim is never taken over at once, and waits at most the
/// interval of this device's time, so a device with a fast clock that never comes back cannot keep a document
/// waiting for ever.
///
/// **Clock skew (B2):** if the claiming device's clock is slow, its fresh claim looks old here and is taken over
/// early (an iPhone 7 h behind that claims at its 10:00, real 17:00, looks 7 h old to the Mac, which takes over at
/// once). The slow device then sees the taker's claim in the future and waits until it has seen it for the interval;
/// by then the taker has written its result, which the exact claim keeps. For a takeover at once on both sides, each
/// clock would have to be at least the interval behind the other, so the two devices never take the document from
/// each other in turn (#97, A-N1; `ClaimSkewSimulationTests`). The early takeover costs at most a double
/// processing with the same result, never data.
public enum ProcessingClaimRules {
    /// The takeover interval of the app: 6 hours (plan §3.4). Debug builds can shorten it
    /// (`-ProcessingTakeoverSeconds`).
    public static let takeoverInterval: TimeInterval = 6 * 60 * 60
    /// Failures of one document on one device before it is marked `failed` and this device stops trying it.
    public static let failureLimit = 3

    /// - Parameters:
    ///   - thisDevice: this device's `processingDeviceID`.
    ///   - failures: this device's own failure counter for the document.
    ///   - now: this device's clock.
    public static func decide(
        _ input: ProcessingClaimInput, thisDevice: String, failures: Int, now: Date,
        takeoverInterval interval: TimeInterval = takeoverInterval
    ) -> ProcessingDecision {
        switch input.state {
        case .unknown: return .skip(.unknownState)
        case .done: return .skip(.done)
        case .failed, .pending, .processing: break
        }
        if input.isTrashed { return .skip(.trashed) }
        if input.state == .failed && failures >= failureLimit { return .skip(.failedOnThisDevice) }
        if !input.hasFile { return .wait(.noFile) }
        if !input.hasText { return .wait(.noText) }
        let claim: ProcessingDecision.ClaimWrite
        if input.state == .failed {
            // A `failed` document this device retries: the failing device gave it up, whatever its claim says.
            claim = .claim
        } else if let claimedAt = input.claimedAt, !input.deviceID.isEmpty {
            if input.deviceID == thisDevice {
                claim = isFresh(claimedAt: claimedAt, now: now, interval: interval) ? .keep : .claim
            } else {
                let expiry = expiry(claimedAt: claimedAt, seenSince: input.claimSeenSince, now: now, interval: interval)
                if now < expiry { return .wait(.claimedElsewhere(until: expiry)) }
                claim = .takeOver
            }
        } else {
            claim = .claim
        }
        if let retry = input.retryNotBefore, now < retry { return .wait(.retryAfter(retry)) }
        return .process(claim)
    }

    /// When another device's claim made at `claimedAt`, first seen by this device at `seenSince` (`nil`: now),
    /// expires by this device's clock: the earlier of `claimedAt` plus the interval and the sighting plus the
    /// interval. A sighting in the future (this device's clock was set back) counts from `now`.
    public static func expiry(
        claimedAt: Date, seenSince: Date?, now: Date, interval: TimeInterval = takeoverInterval
    ) -> Date {
        let seen = min(seenSince ?? now, now)
        return min(claimedAt, seen).addingTimeInterval(interval)
    }

    /// Whether this device's own claim made at `claimedAt` still holds at `now`: its age is at least −interval (at
    /// most the interval in the future) and below the interval. A stale own claim is renewed, not waited for.
    public static func isFresh(claimedAt: Date, now: Date, interval: TimeInterval = takeoverInterval) -> Bool {
        let age = now.timeIntervalSince(claimedAt)
        return age >= -interval && age < interval
    }
}
