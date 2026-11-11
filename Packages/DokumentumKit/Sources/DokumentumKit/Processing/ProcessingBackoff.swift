import Foundation

/// The retry backoff of one document on one device (#97 point 2, B-N4; T9 in the plan of #6): after a failed
/// attempt (thrown or timed out), the next one does not start before 1 minute after the failed one started, the
/// third not before 10 minutes after the second. So two runs from one trigger (an import's insertion and its store
/// change) spend one attempt, and three failures take at least 11 minutes. All on this device's clock; an
/// interrupted attempt is given back and sets no backoff.
public enum ProcessingBackoff {
    /// The waits after the first and after the second failed attempt.
    public static let delays: [TimeInterval] = [60, 10 * 60]

    /// The earliest start of the next attempt, or `nil` when there is nothing to wait for: no failed attempt,
    /// no time of the last one (a counter written before the backoff existed), or the failure limit reached (the
    /// next decision gives up at once instead of waiting).
    ///
    /// A `lastAttemptAt` in the future (the clock was set back) counts from `now` (N9): the retry is never later
    /// than `now` plus the delay. The caller stores that bound, so later calls do not push the retry on.
    public static func retryNotBefore(
        attempts: Int, lastAttemptAt: Date?, now: Date, failureLimit: Int = ProcessingClaimRules.failureLimit
    ) -> Date? {
        guard attempts > 0, attempts < failureLimit, let lastAttemptAt else { return nil }
        let delay = delays[min(attempts, delays.count) - 1]
        return min(lastAttemptAt, now).addingTimeInterval(delay)
    }
}
