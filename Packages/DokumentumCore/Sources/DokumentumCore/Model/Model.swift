import DokumentumKit
import Foundation
import SwiftData

// The current schema version's models (`DokumentumMigrationPlan.current`). Features name these, never a
// `DokumentumSchemaV<N>`; a new schema version moves the typealiases.
public typealias Document = DokumentumSchemaV2.Document
public typealias DocumentFile = DokumentumSchemaV2.DocumentFile
public typealias DocumentThumbnail = DokumentumSchemaV2.DocumentThumbnail
public typealias DocumentText = DokumentumSchemaV2.DocumentText
public typealias Tag = DokumentumSchemaV2.Tag
public typealias Correspondent = DokumentumSchemaV2.Correspondent
public typealias DocumentType = DokumentumSchemaV2.DocumentType

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
