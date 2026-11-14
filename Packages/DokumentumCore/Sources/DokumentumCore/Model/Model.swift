import DokumentumKit
import Foundation
import SwiftData

// The current schema version's models (`DokumentumMigrationPlan.current`). Features name these, never a
// `DokumentumSchemaV<N>`; a new schema version moves the typealiases.
public typealias Document = DokumentumSchemaV3.Document
public typealias DocumentFile = DokumentumSchemaV3.DocumentFile
public typealias DocumentThumbnail = DokumentumSchemaV3.DocumentThumbnail
public typealias DocumentText = DokumentumSchemaV3.DocumentText
public typealias Tag = DokumentumSchemaV3.Tag
public typealias Correspondent = DokumentumSchemaV3.Correspondent
public typealias DocumentType = DokumentumSchemaV3.DocumentType

extension Document {
    /// How the document came into the archive. An unknown stored value (from a newer build) reads as
    /// `.file`, and setting the value it reads as leaves the stored string alone: a fallback is never
    /// written back.
    public var source: DocumentSource {
        get { DocumentSource(storedValue: sourceRaw) }
        set {
            guard newValue != source else { return }
            sourceRaw = newValue.storedValue
        }
    }

    /// Where the text comes from. An unknown stored value reads as `.unknown`; setting `.unknown`, or the
    /// value it already reads as, writes nothing.
    public var textSource: TextSource {
        get { TextSource(storedValue: textSourceRaw) }
        set {
            guard newValue != textSource, let stored = newValue.storedValue else { return }
            textSourceRaw = stored
        }
    }

    /// Where the document is in the processing queue. An unknown stored value reads as `.unknown`;
    /// setting `.unknown`, or the value it already reads as, writes nothing.
    public var processingState: ProcessingState {
        get { ProcessingState(storedValue: processingStateRaw) }
        set {
            guard newValue != processingState, let stored = newValue.storedValue else { return }
            processingStateRaw = stored
        }
    }

    /// The document's deadline (#12), or `nil` when it has none. **The read rule:** only the first ten characters of
    /// `deadlineDay` are read, as `yyyy-MM-dd` (`DeadlineDay(storedValue:)`), so a later build may append a time; a
    /// value that does not read as a day reads as no deadline, and reading never writes the stored string back.
    public var deadline: DocumentDeadline? {
        guard let day = DeadlineDay(storedValue: deadlineDay) else { return nil }
        return DocumentDeadline(day: day, label: deadlineLabel, setAt: deadlineSetAt, doneAt: deadlineDoneAt)
    }

    /// The day up to which due-date suggestions are dismissed (#12), by the read rule of `deadline`; `nil` for none
    /// or a value it cannot read.
    public var dismissedSuggestionDay: DeadlineDay? {
        DeadlineDay(storedValue: deadlineDismissedDay)
    }

    /// `false` for a deleted document, whose properties must not be read (SwiftData traps), while a view
    /// may still hold the reference for a moment.
    public var isAlive: Bool { !isDeleted && modelContext != nil }

    /// Marks a change: every user edit and every repair change to the document calls it.
    public func touch(_ now: Date = Date()) {
        modifiedAt = now
    }
}

extension Tag {
    /// Not merged away by the repair. Tombstones are hidden from every list and picker.
    public var isLive: Bool { mergedIntoID == nil }

    /// How this record's matching rule compares its pattern (#10). An unknown stored value reads as `.unknown`;
    /// setting `.unknown`, or the value it already reads as, writes nothing.
    public var matchMode: MatchMode {
        get { MatchMode(storedValue: matchModeRaw) }
        set {
            guard newValue != matchMode, let stored = newValue.storedValue else { return }
            matchModeRaw = stored
        }
    }
}

extension Correspondent {
    /// Not merged away by the repair. Tombstones are hidden from every list and picker.
    public var isLive: Bool { mergedIntoID == nil }

    /// How this record's matching rule compares its pattern (#10). An unknown stored value reads as `.unknown`;
    /// setting `.unknown`, or the value it already reads as, writes nothing.
    public var matchMode: MatchMode {
        get { MatchMode(storedValue: matchModeRaw) }
        set {
            guard newValue != matchMode, let stored = newValue.storedValue else { return }
            matchModeRaw = stored
        }
    }
}

extension DocumentType {
    /// Not merged away by the repair. Tombstones are hidden from every list and picker.
    public var isLive: Bool { mergedIntoID == nil }

    /// How this record's matching rule compares its pattern (#10). An unknown stored value reads as `.unknown`;
    /// setting `.unknown`, or the value it already reads as, writes nothing.
    public var matchMode: MatchMode {
        get { MatchMode(storedValue: matchModeRaw) }
        set {
            guard newValue != matchMode, let stored = newValue.storedValue else { return }
            matchModeRaw = stored
        }
    }
}
