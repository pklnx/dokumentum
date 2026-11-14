import Foundation

/// Which of a document's fields a suggestion may fill (plan of #8, Approach 4, T2; maintainer's P2 and P7).
///
/// - **Correspondent and type:** empty by value: none set.
/// - **Tags (#10, T13, maintainer's P1):** empty unless the document has a **user tag**: a tag that the matching rules
///   do not explain. A document whose only tags are rule tags still gets the classifier's tags, added to its own.
///   No field records who set a tag, so the classification write evaluates the rules of the document's own tags on
///   its text (`hasUserTags`). A tag whose rule is invalid, times out or sits on a tombstone counts as a user tag
///   (review N2), and so does a tag with copies sharing its `instanceID` (#207); a tag the user set by hand that its
///   rule also matches counts as a rule tag (the plan's R8).
/// - **Title and date** always hold an automatic value (the file name or "Scan …", and the import time), which a
///   value cannot tell from the user's own. They count as empty only while the document **has never been edited**:
///   `modifiedAt == createdAt` (the import sets both to the same time, and every edit, inbox change, trash, restore
///   and repair change calls `touch()`); the date also needs `documentDate == createdAt`. An empty title is empty
///   too. Where a non-edit touches the document (a trash and a restore), the rule errs toward not filling.
///
/// The classification write itself never calls `touch()`, so a classified document still counts as never edited;
/// it is in `done` then and never classified again.
public struct ClassificationFields: Equatable, Sendable {
    public var title: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var documentDate: Date
    public var hasCorrespondent: Bool
    public var hasDocumentType: Bool
    public var hasTags: Bool
    /// A tag the matching rules do not explain (T13); `hasTags` when the caller does not tell them apart.
    public var hasUserTags: Bool

    public init(
        title: String, createdAt: Date, modifiedAt: Date, documentDate: Date, hasCorrespondent: Bool,
        hasDocumentType: Bool, hasTags: Bool, hasUserTags: Bool? = nil
    ) {
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.documentDate = documentDate
        self.hasCorrespondent = hasCorrespondent
        self.hasDocumentType = hasDocumentType
        self.hasTags = hasTags
        self.hasUserTags = hasUserTags ?? hasTags
    }

    public var isNeverEdited: Bool { modifiedAt == createdAt }
    public var titleIsEmpty: Bool { normalizedTitle(title).isEmpty || isNeverEdited }
    public var dateIsEmpty: Bool { isNeverEdited && documentDate == createdAt }
    public var correspondentIsEmpty: Bool { !hasCorrespondent }
    public var documentTypeIsEmpty: Bool { !hasDocumentType }
    /// No user tag: the classifier's tags are added to the rule tags the document may have (T13).
    public var tagsAreEmpty: Bool { !hasUserTags }

    /// The stored `documentDate` for a suggested day: the day in `calendar`, at the time of day `keeping` has
    /// there. The detail's date picker (`DatePicker` with `.date`) changes a date the same way: it sets the day and
    /// keeps the time.
    public static func storedDate(_ date: SuggestedDate, keepingTimeOf keeping: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: keeping)
        components.year = date.year
        components.month = date.month
        components.day = date.day
        guard let stored = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: stored)
        guard back.year == date.year, back.month == date.month, back.day == date.day else { return nil }
        return stored
    }
}

/// Whether a document in `classify` that waits for a model that is not ready yet keeps waiting (plan of #8,
/// Approach 2; review N4). The wait counts no attempt and ends once this device's own claim is stale (6 hours by
/// `ProcessingClaimRules.isFresh`): then the document is finished without suggestions.
///
/// **Before the claim's renewal (N4):** `ProcessingClaimRules.decide` renews a stale own claim (`.claim`). The
/// queue asks this first, so a stale claim ends the wait instead of renewing itself for ever.
public enum ClassificationWait {
    public enum Decision: Equatable, Sendable {
        /// Keep waiting; run again at `until` (this device's claim expires then).
        case wait(until: Date)
        /// Claim the document first (no claim, or another device's expired claim), then wait the interval.
        case claimAndWait
        /// The own claim is stale: finish without suggestions.
        case finish
    }

    public static func decide(
        deviceID: String, claimedAt: Date?, thisDevice: String, now: Date,
        interval: TimeInterval = ProcessingClaimRules.takeoverInterval
    ) -> Decision {
        guard deviceID == thisDevice, let claimedAt else { return .claimAndWait }
        guard ProcessingClaimRules.isFresh(claimedAt: claimedAt, now: now, interval: interval) else { return .finish }
        return .wait(until: claimedAt.addingTimeInterval(interval))
    }
}
