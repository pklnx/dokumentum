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
    /// The processing queue's state, for the detail's status line (#6, P2); the list rows do not show it.
    public var processingState: ProcessingState
    /// The deadline (#12), done or open; `nil` for none.
    public var deadline: DocumentDeadline?
    /// The day up to which due-date suggestions are dismissed (#12); `nil` for none.
    public var dismissedSuggestionDay: DeadlineDay?

    public var id: UUID { instanceID }

    /// In the trash: such a document matches only the trash.
    public var isTrashed: Bool { deletedAt != nil }

    /// The deadline while it is not done: what the Deadlines list shows and counts (#12, part 2a).
    public var openDeadline: DocumentDeadline? {
        guard let deadline, !deadline.isDone else { return nil }
        return deadline
    }

    public init(
        instanceID: UUID, title: String, documentDate: Date, createdAt: Date, isInbox: Bool,
        deletedAt: Date? = nil, correspondent: Reference? = nil, documentType: Reference? = nil,
        tagIDs: Set<UUID> = [], fileState: FileState = .unknown, processingState: ProcessingState = .done,
        deadline: DocumentDeadline? = nil, dismissedSuggestionDay: DeadlineDay? = nil
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
        self.processingState = processingState
        self.deadline = deadline
        self.dismissedSuggestionDay = dismissedSuggestionDay
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

    /// The Deadlines list's order (#12, part 2a): the earliest day first, so overdue deadlines lead; then the title
    /// (`localizedStandardCompare`), then `instanceID`, so the order is the same on every run. A document without a
    /// deadline comes after every one with a deadline (the Deadlines list has none).
    public static func deadlineOrder(_ lhs: LibraryDocument, _ rhs: LibraryDocument) -> Bool {
        switch (lhs.deadline?.day, rhs.deadline?.day) {
        case (let left?, let right?) where left != right: return left < right
        case (nil, _?): return false
        case (_?, nil): return true
        default: break
        }
        switch lhs.title.localizedStandardCompare(rhs.title) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.instanceID.uuidString < rhs.instanceID.uuidString
        }
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
