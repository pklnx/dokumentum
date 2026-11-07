import Foundation

/// One row of the library: a plain value, never a model object, so a view can never read a deleted
/// record. Keyed by `instanceID`; `id` of the synced record can repeat until step 16.
public struct LibraryDocument: Sendable, Hashable, Identifiable {
    /// A correspondent or a document type as a row shows it.
    public struct Reference: Sendable, Hashable {
        public let instanceID: UUID
        public let name: String

        public init(instanceID: UUID, name: String) {
            self.instanceID = instanceID
            self.name = name
        }
    }

    /// What the row knows about the PDF without loading it.
    public enum FileState: String, Sendable, Hashable {
        case unknown, missing, present
    }

    public let instanceID: UUID
    public var title: String
    public var documentDate: Date
    public var createdAt: Date
    public var isInbox: Bool
    public var deletedAt: Date?
    public var correspondent: Reference?
    public var documentType: Reference?
    public var tagIDs: Set<UUID>
    public var fileState: FileState

    public var id: UUID { instanceID }

    /// In the trash: such a document matches only the trash.
    public var isTrashed: Bool { deletedAt != nil }

    public init(
        instanceID: UUID, title: String, documentDate: Date, createdAt: Date, isInbox: Bool,
        deletedAt: Date? = nil, correspondent: Reference? = nil, documentType: Reference? = nil,
        tagIDs: Set<UUID> = [], fileState: FileState = .unknown
    ) {
        self.instanceID = instanceID
        self.title = title
        self.documentDate = documentDate
        self.createdAt = createdAt
        self.isInbox = isInbox
        self.deletedAt = deletedAt
        self.correspondent = correspondent
        self.documentType = documentType
        self.tagIDs = tagIDs
        self.fileState = fileState
    }
}

// MARK: Order

extension LibraryDocument {
    /// The list order: newest document date first, then newest `createdAt`, then `instanceID`, so
    /// the order is the same on every run and every device.
    public static func listOrder(_ lhs: LibraryDocument, _ rhs: LibraryDocument) -> Bool {
        if lhs.documentDate != rhs.documentDate { return lhs.documentDate > rhs.documentDate }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.instanceID.uuidString < rhs.instanceID.uuidString
    }
}

// MARK: VoiceOver

extension LibraryDocument {
    /// The words of the VoiceOver label. Kit emits no strings of its own: the app passes them in,
    /// localized.
    public struct AccessibilityStrings: Sendable {
        /// The date as it is read, e.g. "9 May 2026".
        public var date: @Sendable (Date) -> String
        /// The tag paths joined into one phrase, e.g. "tags: Tax and Auto › Golf".
        public var tags: @Sendable ([String]) -> String
        /// "in inbox".
        public var inInbox: String

        public init(
            date: @escaping @Sendable (Date) -> String, tags: @escaping @Sendable ([String]) -> String,
            inInbox: String
        ) {
            self.date = date
            self.tags = tags
            self.inInbox = inInbox
        }
    }

    /// What VoiceOver reads for a row: one sentence instead of every part of it, e.g. "Electricity
    /// bill, 9 May 2026, Stadtwerke, Invoice, tags: Tax and Home, in inbox". Empty parts are left
    /// out. Ported from the predecessor's `DocumentAccessibility.label(for:)` without favourites and
    /// processing.
    /// - Parameters:
    ///   - displayTitle: the title as shown, "Untitled document" already filled in by the caller.
    ///   - tagPaths: the display paths of the document's tags, in the order to read them.
    public func accessibilityLabel(
        displayTitle: String, tagPaths: [String], strings: AccessibilityStrings
    ) -> String {
        var parts = [displayTitle, strings.date(documentDate)]
        parts.append(correspondent?.name ?? "")
        parts.append(documentType?.name ?? "")
        let paths = tagPaths.filter { !isBlank($0) }
        if !paths.isEmpty { parts.append(strings.tags(paths)) }
        if isInbox { parts.append(strings.inInbox) }
        return parts.filter { !isBlank($0) }.joined(separator: ", ")
    }
}

private func isBlank(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
