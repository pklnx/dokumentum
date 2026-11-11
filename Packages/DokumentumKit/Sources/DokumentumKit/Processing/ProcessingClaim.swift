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

    public init(
        state: ProcessingState, deviceID: String, claimedAt: Date?, isTrashed: Bool = false, hasFile: Bool = true,
        hasText: Bool = true
    ) {
        self.state = state
        self.deviceID = deviceID
        self.claimedAt = claimedAt
        self.isTrashed = isTrashed
        self.hasFile = hasFile
        self.hasText = hasText
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
        /// Another device's claim is fresh. `until` is when it expires by this device's clock: the claim time
        /// plus the takeover interval.
        case claimedElsewhere(until: Date)
        case noFile
        case noText
    }

    /// The claim write before the work.
    public enum ClaimWrite: Equatable, Sendable {
        /// The claim is already this device's and fresh: no write (a document this device just imported).
        case keep
        /// No claim, this device's own claim gone stale, or a `failed` document this device retries: claim it.
        case claim
        /// Another device's claim expired (or lies too far in the future): take it over.
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

/// The one decision for one document (plan of #4, part 5):
///
/// | State | Claim | Decision |
/// |---|---|---|
/// | `done` | any | skip |
/// | `failed` | any | skip, unless this device's own failure counter is below the limit (3): then process (claim) |
/// | `unknown` | any | skip, never written |
/// | `pending`, `processing` | none, or this device | process (keep a fresh own claim, else claim) |
/// | `pending`, `processing` | another device, age in [−interval, +interval) | wait until the age reaches the interval |
/// | `pending`, `processing` | another device, age ≥ interval, or more than the interval in the future | take over |
///
/// Before the table: `unknown` is skipped first (even in the trash), then `done`, a trashed document, and a
/// document without its file or its text record (it waits; processing never creates them).
///
/// **The age** is this device's clock minus `claimedAt`, which the claiming device wrote with its own clock.
/// **Clock skew (B2):** if the claiming device's clock is slow, its fresh claim looks old here and is taken over
/// early (an iPhone 7 h behind that claims at its 10:00, real 17:00, looks 7 h old to the Mac, which takes over at
/// once). If it is fast, the claim looks young; a claim more than the interval in the future counts as expired, so
/// a device that never comes back (reinstalled, so a new `DeviceIdentity`, or replaced) cannot keep a document
/// waiting for ever. Both cost at most a double processing, whose results are the same; neither loses data.
/// Exactly the interval in the future still waits ("more than").
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
        // A `failed` document this device retries: the failing device gave it up, whatever its claim says.
        if input.state == .failed { return .process(.claim) }
        guard !input.deviceID.isEmpty, let claimedAt = input.claimedAt else { return .process(.claim) }
        let fresh = isFresh(claimedAt: claimedAt, now: now, interval: interval)
        if input.deviceID == thisDevice { return .process(fresh ? .keep : .claim) }
        return fresh ? .wait(.claimedElsewhere(until: claimedAt.addingTimeInterval(interval))) : .process(.takeOver)
    }

    /// Whether a claim made at `claimedAt` still holds at `now`: its age is at least −interval (at most the
    /// interval in the future) and below the interval.
    public static func isFresh(claimedAt: Date, now: Date, interval: TimeInterval = takeoverInterval) -> Bool {
        let age = now.timeIntervalSince(claimedAt)
        return age >= -interval && age < interval
    }
}
