import Foundation

/// Which of a document's fields a suggestion may fill (plan of #8, Approach 4, T2; maintainer's P2 and P7).
///
/// - **Correspondent, type, tags:** empty by value: none set.
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

    public init(
        title: String, createdAt: Date, modifiedAt: Date, documentDate: Date, hasCorrespondent: Bool,
        hasDocumentType: Bool, hasTags: Bool
    ) {
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.documentDate = documentDate
        self.hasCorrespondent = hasCorrespondent
        self.hasDocumentType = hasDocumentType
        self.hasTags = hasTags
    }

    public var isNeverEdited: Bool { modifiedAt == createdAt }
    public var titleIsEmpty: Bool { normalizedTitle(title).isEmpty || isNeverEdited }
    public var dateIsEmpty: Bool { isNeverEdited && documentDate == createdAt }
    public var correspondentIsEmpty: Bool { !hasCorrespondent }
    public var documentTypeIsEmpty: Bool { !hasDocumentType }
    public var tagsAreEmpty: Bool { !hasTags }

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
