import DokumentumKit
import Foundation
import SwiftData

// Detection in the processing queue (#11, part 2): the detection step of the shared fill (`MetadataFill`, plan of
// #10 §4a). docs/development/index.md, "The processing queue", part "Detection", has the whole picture.

/// What detection did to one document in a write. Counts only; the log gets fixed codes.
struct DetectionFill: Equatable, Sendable {
    /// The correspondent was filled: an existing record linked, or a new one created (`created`).
    var correspondent = false
    var created = false
    var date = false
    /// The correspondent was still empty, and no stash entry for the document's text record was there.
    var noStash = false
}

/// What detection offers the classification write (#11, Approach 5): it fills after the classifier, only what is
/// still empty.
struct ClassificationDetection: Sendable {
    /// Where the issue date comes from.
    enum DateSource: Sendable {
        /// Detected by the step from the text it read and the document's `createdAt` (`ClassificationInput`).
        case detected(SuggestedDate?)
        /// Recomputed in the write from the text record, by key, only when the date is still empty (`finish`, N6).
        case fromText
    }

    var date: DateSource
    /// This device's stash entry for the document (`DetectionStash`); `nil` after a takeover or a relaunch of a
    /// build without one.
    var stashed: DetectionStash.Entry?
}

extension MetadataFill {
    /// Whether the date counts as empty (#8's rule, `ClassificationFields.dateIsEmpty`): the document was never
    /// edited and its date is still its `createdAt`. Read on the row as this write left it so far, so a date the
    /// classifier filled in this write is not empty.
    static func dateIsEmpty(_ document: Document) -> Bool {
        document.modifiedAt == document.createdAt && document.documentDate == document.createdAt
    }

    /// The sender on `layout` among this write's live correspondents, in the repair's keeper order. Fetches the
    /// metadata (once per fill).
    mutating func detectSender(in layout: PageLayout) throws -> DetectedSender? {
        let live = keeperOrder(Array(try live().correspondents.values), \.createdAt, \.instanceID)
        return SenderDetector.detect(
            in: layout, known: live.map { MetadataMatcher.Record(id: $0.instanceID, name: $0.name) })
    }

    /// **The `done` path** (Approach 4): detection in the text write, on the row as the rules left it. The date
    /// from `text` (the text the write stores) while the date is empty; the sender from `layout` while the
    /// correspondent is empty. Neither empty: no fetch and no detector run (N6).
    mutating func applyDetection(
        text: String, layout: PageLayout?, to document: Document, now: Date, calendar: Calendar
    ) throws -> DetectionFill {
        var fill = DetectionFill()
        if Self.dateIsEmpty(document),
            let date = IssueDateDetector.detect(in: text, createdAt: document.createdAt, calendar: calendar)
        {
            fill.date = fillDate(date, of: document, calendar: calendar)
        }
        if document.correspondent == nil, let layout, let sender = try detectSender(in: layout) {
            try fillSender(sender, of: document, now: now, into: &fill)
        }
        return fill
    }

    /// **The `classify` path** (Approach 5): detection in the classification write, after the classifier applied its
    /// fields. The date while still empty (recomputed, never stashed); the sender from the stash entry when it was
    /// found with the document's current text record. `text` gives the stored text when the date source is
    /// `.fromText`; it is read only when the date is still empty.
    mutating func applyDetection(
        _ detection: ClassificationDetection, text: () -> String?, to document: Document, now: Date,
        calendar: Calendar
    ) throws -> DetectionFill {
        var fill = DetectionFill()
        if Self.dateIsEmpty(document) {
            let date: SuggestedDate? =
                switch detection.date {
                case .detected(let date): date
                case .fromText:
                    text().flatMap {
                        IssueDateDetector.detect(in: $0, createdAt: document.createdAt, calendar: calendar)
                    }
                }
            if let date { fill.date = fillDate(date, of: document, calendar: calendar) }
        }
        if document.correspondent == nil {
            // The text record's key is read only here, when a stash entry could fill something.
            if let entry = detection.stashed, entry.text == document.text?.instanceID {
                if let sender = entry.sender { try fillSender(sender, of: document, now: now, into: &fill) }
            } else {
                fill.noStash = true
            }
        }
        return fill
    }

    /// Stores `date` as #8 stores a suggested date: the day in `calendar`, the time of day kept.
    private func fillDate(_ date: SuggestedDate, of document: Document, calendar: Calendar) -> Bool {
        guard
            let stored = ClassificationFields.storedDate(
                date, keepingTimeOf: document.documentDate, calendar: calendar),
            stored != document.documentDate
        else { return false }
        document.documentDate = stored
        return true
    }

    /// Resolves `sender` against this write's live correspondents and links it, or creates a new correspondent
    /// (the maintainer's Q1): the hinted record while it is still live under that name, else `MetadataMatcher` by
    /// name (an equal normalized name, else the longest word prefix), else a new record. A tombstone or a record
    /// with copies is never linked (`MetadataFill.Live`).
    private mutating func fillSender(
        _ sender: DetectedSender, of document: Document, now: Date, into fill: inout DetectionFill
    ) throws {
        let live = try live()
        let name: String
        switch sender {
        case .existing(let id, let known):
            if let record = live.correspondents[id], record.name == known {
                link(record, to: document)
                fill.correspondent = true
                return
            }
            name = known
        case .name(let found):
            name = found
        }
        let ordered = keeperOrder(Array(live.correspondents.values), \.createdAt, \.instanceID)
        if let id = MetadataMatcher.match(name, among: ordered.map { .init(id: $0.instanceID, name: $0.name) }),
            let record = live.correspondents[id]
        {
            link(record, to: document)
        } else {
            let record = Correspondent(name: name, createdAt: now)
            context.insert(record)
            document.correspondent = record
            fill.created = true
        }
        fill.correspondent = true
    }
}
